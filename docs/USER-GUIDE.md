# Azure Landing Zone Assessment Collector User Guide

## 1. Purpose

The collector gathers read-only technical evidence for:

- Azure Landing Zone platform assessment
- Azure Well-Architected Framework assessment
- Well-Architected Reliability Assessment
- Security/WASA-style assessment
- Governance, operations, resilience, and cost review

It does not determine compliance automatically. The output is evidence that an assessor must interpret against the intended architecture, organizational standards, business criticality, and Microsoft guidance.

## 2. Supported environment

- Windows with PowerShell 7.3 or later
- Azure CLI available in `PATH`
- Network access to Azure Resource Manager and Microsoft Graph
- An Azure identity with read access to the selected scope

Confirm the local tools:

```powershell
$PSVersionTable.PSVersion
az version
az account show
```

Run the collector with `pwsh`. Windows PowerShell 5.1 (`powershell.exe`) is not supported.

If authentication is required:

```powershell
az login
```

For tenants requiring an explicit tenant:

```powershell
az login --tenant '<tenant-id>'
```

## 3. Prepare the collection scope

List visible subscriptions:

```powershell
az account list --all `
  --query "[?state=='Enabled'].{Name:name,Id:id,Tenant:tenantId}" `
  --output table
```

Specify subscription IDs whenever possible. Omitting `-SubscriptionId` selects every enabled subscription visible to the current identity and can significantly increase collection time and output size.

Recommended scope workflow:

1. Confirm the tenant.
2. Select platform, production, and security subscriptions.
3. Run the Standard profile.
4. Review collection errors.
5. Configure representative workloads.
6. Run Full only if per-resource diagnostic-setting evidence is required.

## 4. Configure workloads

Copy the example:

```powershell
Copy-Item .\workloads.example.json .\workloads.json
```

Replace every example value:

```json
{
  "workloads": [
    {
      "name": "Payments Production",
      "businessPurpose": "Processes customer payments",
      "owner": "payments-team@example.com",
      "criticality": "Mission-critical",
      "rto": "2 hours",
      "rpo": "15 minutes",
      "subscriptionId": "11111111-1111-1111-1111-111111111111",
      "resourceGroups": [
        "rg-payments-prod",
        "rg-payments-data-prod"
      ],
      "regions": [
        "westeurope",
        "northeurope"
      ],
      "notes": "Customer-facing production workload"
    }
  ]
}
```

Select approximately three to five workloads covering different architectures and business criticalities.

## 5. Select a profile

| Profile | Entra/Microsoft Graph | Subscription diagnostics | Per-resource diagnostics | Use case |
|---|---:|---:|---:|---|
| Fast | No | Yes | No | Initial inventory or limited directory access |
| Standard | Yes | Yes | No | Recommended assessment baseline |
| Full | Yes | Yes | Yes | Deep monitoring and diagnostic-settings review |

Explicit switches override profile behavior only in the direction of skipping data:

- `-SkipDirectoryData`
- `-SkipPerResourceDiagnostics`

## 6. Run the collector

### Recommended Standard run

```powershell
.\Invoke-AlzAssessmentCollection.ps1 `
  -SubscriptionId `
    '11111111-1111-1111-1111-111111111111',
    '22222222-2222-2222-2222-222222222222' `
  -Profile Standard `
  -WorkloadConfigPath '.\workloads.json' `
  -OutputPath '.\output\assessment-2026-10-02'
```

### Fast platform discovery

```powershell
.\Invoke-AlzAssessmentCollection.ps1 `
  -SubscriptionId '11111111-1111-1111-1111-111111111111' `
  -Profile Fast `
  -OutputPath '.\output\discovery'
```

### Full diagnostics collection

```powershell
.\Invoke-AlzAssessmentCollection.ps1 `
  -SubscriptionId '11111111-1111-1111-1111-111111111111' `
  -Profile Full `
  -WorkloadConfigPath '.\workloads.json' `
  -OutputPath '.\output\full-assessment'
```

Full mode makes one diagnostic-settings request per resource. Use it on a deliberate scope.

## 7. Run selected stages

Stages are numbered from 0 through 10.

Run governance through security:

```powershell
.\Invoke-AlzAssessmentCollection.ps1 `
  -SubscriptionId '11111111-1111-1111-1111-111111111111' `
  -StartAtStage 2 `
  -EndAtStage 5 `
  -OutputPath '.\output\focused-assessment'
```

Run only identity:

```powershell
.\Invoke-AlzAssessmentCollection.ps1 `
  -SubscriptionId '11111111-1111-1111-1111-111111111111' `
  -StartAtStage 3 `
  -EndAtStage 3 `
  -OutputPath '.\output\identity-assessment'
```

## 8. Resume an interrupted run

Each completed stage writes `_stage-NN.complete.json`. To continue:

```powershell
.\Invoke-AlzAssessmentCollection.ps1 `
  -SubscriptionId '11111111-1111-1111-1111-111111111111' `
  -Profile Standard `
  -WorkloadConfigPath '.\workloads.json' `
  -OutputPath '.\output\assessment-2026-10-02' `
  -Resume
```

Use the same parameters and output path. Completed stages are skipped; failed or incomplete stages run again.

If collection requirements or scripts changed materially, use a new output directory instead of resuming old evidence.

## 9. Review results

Review in this order:

1. `_run-metadata.json`
2. `_collection-errors.csv`
3. `_collection.log`
4. `10-evidence-index\evidence-index.csv`
5. Stage evidence directories

An empty result can mean:

- No matching resources exist.
- The identity lacks permission.
- The API call failed.
- The selected scope excluded the resource.

Never treat an empty or missing file as proof of compliance without checking the error register and scope.

## 10. Assessment activities not automated

The following still require interviews, workshops, or document review:

- Business ownership and criticality
- Subscription vending and lifecycle
- Emergency access procedures
- Incident response and escalation
- RTO/RPO approval and restoration-test results
- Regulatory and data-residency requirements
- Infrastructure-as-Code and CI/CD maturity
- Operational ownership and support boundaries
- Target-state architecture decisions
- Exception justification and review dates

## 11. Recommended collection lifecycle

1. Record the approved scope and collection date.
2. Run Standard.
3. Resolve required collection failures.
4. Run Full for selected scopes if needed.
5. Copy evidence to the approved assessment repository.
6. Preserve the evidence index and hashes.
7. Restrict access according to organizational policy.
8. Analyze evidence and create findings.
9. Repeat after remediation to validate changes.
