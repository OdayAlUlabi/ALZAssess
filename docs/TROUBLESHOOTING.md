# Troubleshooting and Operations

## 1. Triage workflow

When a run reports errors:

1. Open `_run-metadata.json`.
2. Identify failed or incomplete stages.
3. Open `_collection-errors.csv`.
4. Classify each error as authentication, authorization, throttling, API, scope, configuration, or script failure.
5. Correct the root cause.
6. Rerun with the same output path and `-Resume`, or run the affected stage into a new directory.
7. Confirm the evidence index after completion.

## 2. Authentication failures

Symptoms:

- `Please run 'az login'`
- `AADSTS...`
- Expired refresh token
- Incorrect tenant

Resolution:

```powershell
az logout
az login --tenant '<tenant-id>'
az account show
```

For a specific subscription:

```powershell
az account set --subscription '<subscription-id>'
```

The orchestrator still uses the explicit `-SubscriptionId` scope for Resource Graph.

## 3. Collection stops at `Collecting tenants`

Cause:

- The Azure CLI `account` extension is missing. The `az account tenant list` command can otherwise display an interactive dynamic-install prompt that makes unattended collection appear stuck.

Resolution:

```powershell
az extension add --name account --yes --only-show-errors
az account tenant list --only-show-errors --output json
```

The collector disables Azure CLI dynamic-extension installation and stage 00 checks for this extension, so current versions fail with a clear prerequisite error instead of prompting.

## 4. Too many subscriptions

Symptom:

- The run starts collecting dozens of subscriptions.

Cause:

- `-SubscriptionId` was omitted.

Resolution:

```powershell
az account list --all `
  --query "[?state=='Enabled'].{Name:name,Id:id}" `
  --output table
```

Restart with an explicit list. Preserve the original output only if it is needed for troubleshooting.

## 5. Authorization failures

### Azure Resource Manager or Resource Graph 403

Confirm Reader access:

```powershell
az role assignment list `
  --assignee '<object-id-or-upn>' `
  --all `
  --output table
```

Access inherited through groups or management groups may need separate validation.

### PIM 403

Typical missing permission:

```text
RoleEligibilitySchedule.Read.Directory
```

Options:

- Request approved read permission.
- Accept the evidence gap and document it.
- Run with `-SkipDirectoryData` if no directory evidence is authorized.

The collector does not retry permanent 403 responses.

### Defender evidence missing

Request Security Reader at the relevant scope and rerun stage 5:

```powershell
.\Invoke-AlzAssessmentCollection.ps1 `
  -SubscriptionId '<subscription-id>' `
  -StartAtStage 5 `
  -EndAtStage 5 `
  -OutputPath '.\output\security-retry'
```

### Budget evidence missing

Confirm Cost Management Reader or equivalent access, then rerun stage 8.

## 6. Resource Graph failures

The collector uses direct REST requests, 500-row pages, and bounded retries.

Transient symptoms:

- Connection reset
- Timeout
- HTTP 429
- HTTP 5xx

Use `-Resume` after the condition clears:

```powershell
.\Invoke-AlzAssessmentCollection.ps1 `
  -SubscriptionId '<subscription-id>' `
  -OutputPath '.\output\assessment' `
  -Resume
```

If a query repeatedly fails:

1. Run only the affected stage.
2. Reduce subscription scope.
3. Confirm Azure service health and network connectivity.
4. Inspect the exact error in `_collection-errors.csv`.

## 7. Microsoft Graph pagination failures

Symptoms:

- Only the first page exists.
- Service principal or application evidence is missing.
- A next-link URL is interpreted by the shell.

Current implementation follows `@odata.nextLink` through `Invoke-RestMethod`, avoiding shell interpretation of `$skiptoken`.

If the error persists:

1. Confirm access to `https://graph.microsoft.com`.
2. Check tenant Conditional Access requirements.
3. Reauthenticate.
4. Run only stage 3.

## 8. Workload placeholder error

Error:

```text
Workload still uses the example subscription ID.
```

Copy and edit the example configuration:

```powershell
Copy-Item .\workloads.example.json .\workloads.json
notepad .\workloads.json
```

Then rerun stage 9 and rebuild the evidence index:

```powershell
.\Invoke-AlzAssessmentCollection.ps1 `
  -SubscriptionId '<subscription-id>' `
  -WorkloadConfigPath '.\workloads.json' `
  -StartAtStage 9 `
  -EndAtStage 10 `
  -OutputPath '.\output\assessment'
```

Do not use `-Resume` for stages 9 and 10 if their previous completion markers exist and the workload configuration changed.

## 9. Full profile is slow

Cause:

- Full mode requests diagnostic settings separately for every resource.

Resolution:

- Use Standard for the tenant-wide baseline.
- Use Full on selected subscriptions or workload scopes.
- Run stage 6 separately.

```powershell
.\Invoke-AlzAssessmentCollection.ps1 `
  -SubscriptionId '<critical-subscription-id>' `
  -Profile Full `
  -StartAtStage 6 `
  -EndAtStage 6 `
  -OutputPath '.\output\critical-diagnostics'
```

### Resource type does not support diagnostic settings

Azure does not expose diagnostic settings for every resource type. Examples include some alert resources, action groups, restore point collections, and Network Watcher resources.

The collector preloads known unsupported types and records these resources without calling the diagnostic-settings API:

```text
06-operations\resource-diagnostic-settings-unsupported.json
```

They are informational coverage records and are not written to `_collection-errors.csv`. If Azure returns `ResourceTypeNotSupported` for an additional type, the collector dynamically caches it for the rest of the run.

Per-resource requests use Azure Resource Manager REST rather than the Azure CLI diagnostic-settings command. This allows resource IDs containing characters such as parentheses, including Operations Management solution names, to be processed without command-wrapper parsing errors.

If an older collector version recorded `ResourceTypeNotSupported` as an error, update the repository and rerun stage 6 into a new output directory, or remove the existing stage 6 completion marker and stale stage 6 error rows before resuming.

## 10. Empty output

Do not assume an empty JSON array means no gap exists.

Check:

1. Requested subscription IDs.
2. `_collection-errors.csv`.
3. Caller access.
4. Resource provider availability.
5. Query support for the resource type.
6. Whether the resource exists in another tenant or subscription.

## 11. Resume behavior

`-Resume` trusts `_stage-NN.complete.json`.

Remove only the specific stage marker when a stage must be recollected:

```powershell
Remove-Item `
  -LiteralPath '.\output\assessment\_stage-05.complete.json'
```

Then run with `-Resume`.

Use a new output directory when:

- Scope changed.
- Profile changed materially.
- Collection scripts changed.
- Evidence must represent a clean point-in-time snapshot.

## 12. Pipeline use

For automation:

```powershell
.\Invoke-AlzAssessmentCollection.ps1 `
  -SubscriptionId '<subscription-id>' `
  -Profile Standard `
  -OutputPath '.\output\assessment' `
  -FailOnCollectionError

if ($LASTEXITCODE -ne 0) {
    throw "Assessment evidence collection failed with exit code $LASTEXITCODE."
}
```

Archive the output directory only after stage 10 succeeds.

## 13. Performance monitoring

Review stage duration:

```powershell
$metadata = Get-Content '.\output\assessment\_run-metadata.json' -Raw |
  ConvertFrom-Json

$metadata.Stages |
  Select-Object Stage, File, Status, DurationSeconds |
  Format-Table -AutoSize
```

Find slow query logs:

```powershell
Select-String `
  -Path '.\output\assessment\_collection.log' `
  -Pattern 'records in'
```

## 14. Operational checklist

Before collection:

- [ ] Scope approved
- [ ] Output repository approved
- [ ] Azure CLI authenticated to the correct tenant
- [ ] Subscription IDs confirmed
- [ ] Required roles active
- [ ] Workload configuration reviewed

After collection:

- [ ] Required stages completed
- [ ] Error register reviewed
- [ ] Workload placeholders removed
- [ ] Evidence index generated
- [ ] Output access restricted
- [ ] Evidence transferred securely
- [ ] Local retention requirement recorded
