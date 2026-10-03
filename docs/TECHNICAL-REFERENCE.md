# Technical Reference

## 1. Architecture

```text
Invoke-AlzAssessmentCollection.ps1
        |
        +-- resolves profile and stage range
        +-- runs stages sequentially
        +-- writes completion markers and run metadata
        |
        +-- Scripts\00-Prerequisites.ps1
        +-- Scripts\01-TenantHierarchy.ps1
        +-- Scripts\02-ResourceGovernance.ps1
        +-- Scripts\03-Identity.ps1
        +-- Scripts\04-Network.ps1
        +-- Scripts\05-Security.ps1
        +-- Scripts\06-Operations.ps1
        +-- Scripts\07-Resilience.ps1
        +-- Scripts\08-CostOptimization.ps1
        +-- Scripts\09-Workloads.ps1
        +-- Scripts\10-BuildEvidenceIndex.ps1
                    |
                    +-- Private\Common.ps1
```

Stages execute sequentially to preserve predictable dependencies. Individual queries inside a stage use the shared collection helpers.

## 2. Data sources

| Source | Method | Purpose |
|---|---|---|
| Azure Resource Manager | Azure CLI and `az rest` | Subscription configuration and provider APIs |
| Azure Resource Graph | Direct REST POST | Cross-subscription inventory, Policy, security, Advisor, and health queries |
| Microsoft Graph | OAuth token plus `Invoke-RestMethod` | Entra roles, PIM, Conditional Access, applications, and service principals |
| Local filesystem | PowerShell | JSON/CSV output, logs, stage markers, and SHA-256 evidence index |

Resource Graph requests use:

```text
POST https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01
```

The implementation sends explicit subscription IDs, requests object-array output, follows skip tokens, and permits partial scopes. Assessors must compare returned evidence with the requested scope.

## 3. Orchestrator parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `SubscriptionId` | `string[]` | All visible enabled subscriptions | Explicit collection scope |
| `OutputPath` | `string` | Timestamped directory | Persistent evidence location |
| `WorkloadConfigPath` | `string` | `workloads.example.json` | Workload definition file |
| `Profile` | `Fast`, `Standard`, `Full` | `Standard` | Evidence depth |
| `StartAtStage` | `int` | `0` | First stage, inclusive |
| `EndAtStage` | `int` | `10` | Last stage, inclusive |
| `Resume` | switch | Off | Skip stages with completion markers |
| `SkipDirectoryData` | switch | Off | Disable Microsoft Graph collection |
| `SkipPerResourceDiagnostics` | switch | Off | Disable resource-by-resource diagnostics |
| `FailOnCollectionError` | switch | Off | Exit with code 2 when optional errors exist |

`StartAtStage` must not be greater than `EndAtStage`.

## 4. Profile resolution

```text
Fast:
  Directory data = skipped
  Per-resource diagnostics = skipped

Standard:
  Directory data = included
  Per-resource diagnostics = skipped

Full:
  Directory data = included
  Per-resource diagnostics = included
```

The explicit skip switches can suppress data from any profile.

## 5. Shared helper behavior

### Azure CLI JSON

`Invoke-AzCliJson`:

- Adds `--only-show-errors --output json`.
- Parses JSON without enumerating empty arrays.
- Saves normalized JSON.
- Records failures in `_collection-errors.csv`.
- Throws only for required evidence.

### Resource Graph

`Invoke-AzGraphQuery`:

- Uses the direct Resource Graph REST API.
- Defaults to 500 records per page.
- Follows `$skipToken`.
- Retries transient failures up to three times.
- Logs record count and elapsed time.
- Writes one normalized JSON array.

### REST and Microsoft Graph

`Invoke-AzRestPaged`:

- Gets an access token for Microsoft Graph or Azure Resource Manager.
- Follows `@odata.nextLink` and ARM `nextLink`.
- Retries timeouts, throttling, and server errors.
- Does not retry permanent 4xx authorization failures.
- Removes certificate `key` and password `secretText` fields in credential-metadata mode.

### Resource diagnostic settings

Full-profile per-resource diagnostic collection:

- Preloads a registry of resource types known not to support diagnostic settings.
- Records those resources without making an unsupported API request.
- Uses direct authenticated Azure Resource Manager REST requests for other resources.
- Avoids Azure CLI command-wrapper parsing problems for resource IDs containing characters such as parentheses.
- Dynamically caches any additional resource type that returns `ResourceTypeNotSupported`.

### Error handling

Independent optional failures are logged and collection continues. Required failures stop the current run.

Required evidence currently includes:

- Azure CLI version and authentication checks
- Subscription discovery
- Compact resource inventory

## 6. Stage lifecycle

For each selected stage, the orchestrator:

1. Checks the completion marker when `-Resume` is used.
2. Records the stage start time.
3. Invokes the stage script.
4. Writes `_stage-NN.complete.json` after success.
5. Adds status and duration to `_run-metadata.json`.
6. Records failure metadata and rethrows required failures.

A completion marker means the stage script returned successfully. Optional collection errors can still exist for that stage and must be reviewed separately.

## 7. Run-level files

| File | Purpose |
|---|---|
| `_run-metadata.json` | Scope, profile, flags, timestamps, stage status, duration, and error count |
| `_collection.log` | Human-readable chronological log |
| `_collection-errors.csv` | Structured failed-item register |
| `_stage-NN.complete.json` | Resume marker and stage timing |

## 8. Exit behavior

| Condition | Result |
|---|---|
| Successful run, no errors | Exit code 0 |
| Optional errors without `-FailOnCollectionError` | Exit code 0 with warning |
| Optional errors with `-FailOnCollectionError` | Exit code 2 |
| Required collection or script failure | Nonzero terminating error |

Automation should use `-FailOnCollectionError` when incomplete evidence must fail the pipeline.

## 9. Performance characteristics

Performance depends on:

- Number of subscriptions and resources
- Microsoft Graph directory size
- Azure API throttling
- Network latency
- Full-profile diagnostic calls

Observed validation for three subscriptions and 179 resources:

- Compact Resource Graph inventory: approximately 2.6 seconds
- Governance stage: approximately 45 seconds
- Complete Standard sequence: approximately 3 minutes 40 seconds

These measurements are examples, not service-level objectives.

## 10. Extending the collector

When adding evidence:

1. Add the query to the stage representing its assessment area.
2. Reuse `Invoke-AzGraphQuery`, `Invoke-AzRestPaged`, or `Invoke-AzCliJson`.
3. Avoid exporting an entire `properties` bag unless necessary.
4. Project only assessment-relevant fields.
5. Do not export secret values, tokens, private keys, or certificate bodies.
6. Mark evidence required only when the whole assessment cannot proceed without it.
7. Update the evidence catalog and permission matrix.
8. Validate syntax and run the smallest affected stage.

## 11. Official references

- [Azure Resource Graph overview and permissions](https://learn.microsoft.com/azure/governance/resource-graph/overview#permissions-in-azure-resource-graph)
- [Azure Resource Graph query language](https://learn.microsoft.com/azure/governance/resource-graph/concepts/query-language)
- [Azure Resource Graph sample queries](https://learn.microsoft.com/azure/governance/resource-graph/samples/samples-by-category)
- [Azure CLI sign in](https://learn.microsoft.com/cli/azure/authenticate-azure-cli)
- [Microsoft Graph permissions reference](https://learn.microsoft.com/graph/permissions-reference)
- [Azure Monitor diagnostic settings](https://learn.microsoft.com/azure/azure-monitor/essentials/diagnostic-settings)
