# Azure Landing Zone Assessment Data Collector

This PowerShell suite collects read-only evidence for the ALZ, WAF, WARA, and Security/WASA assessment plan. It runs in a fixed sequence and writes JSON evidence, an error register, logs, and a SHA-256 evidence index.

[![Validate](https://github.com/OdayAlUlabi/ALZAssess/actions/workflows/validate.yml/badge.svg)](https://github.com/OdayAlUlabi/ALZAssess/actions/workflows/validate.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> [!IMPORTANT]
> Collector output can contain sensitive tenant, identity, network, and security information. Never commit the `output/` directory or real workload configuration files.

## Documentation

- [User guide](docs/USER-GUIDE.md): installation, configuration, profiles, execution, and resume procedures.
- [Technical reference](docs/TECHNICAL-REFERENCE.md): architecture, parameters, stages, APIs, retry behavior, and exit handling.
- [Evidence catalog](docs/EVIDENCE-CATALOG.md): every evidence area, output, assessment mapping, and interpretation guidance.
- [Reporting guide](docs/REPORTING.md): generate the HTML dashboard, CSV exports, and observation register.
- [Security and permissions](docs/SECURITY-AND-PERMISSIONS.md): least privilege, Microsoft Graph permissions, sensitive-data handling, and retention.
- [Troubleshooting and operations](docs/TROUBLESHOOTING.md): common failures, recovery procedures, performance guidance, and operational runbook.

## Prerequisites

- PowerShell 7.3 or later
- Azure CLI
- An authenticated Azure CLI session:

  ```powershell
  az login
  ```

- `Reader` on all Azure scopes being assessed
- Additional permissions for complete evidence:
  - `Security Reader` for Defender for Cloud evidence
  - `Directory Readers` or equivalent Microsoft Graph application permissions for Entra evidence
  - `Cost Management Reader` for budget and cost evidence

The collector does not export secret or certificate values. Microsoft Graph exports include credential identifiers and expiration metadata only.

## Configure workloads

Copy `workloads.example.json`, then define three to five representative workloads. Each workload must have a subscription ID and at least one resource group.

## Run the complete sequence

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

pwsh -File .\Invoke-AlzAssessmentCollection.ps1 `
  -SubscriptionId '11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222' `
  -WorkloadConfigPath '.\workloads.json' `
  -Profile Standard `
  -OutputPath '.\output\assessment-2026-10-02'
```

Use `pwsh`, not Windows PowerShell (`powershell.exe`). `ConvertFrom-Json` and other collector operations require PowerShell 7.3 or later.

Omit `-SubscriptionId` to collect all enabled subscriptions visible to the signed-in identity.

## End-to-end Full assessment when workloads are not known

Use this workflow to validate prerequisites, collect the tenant and platform baseline from all visible subscriptions, verify the evidence, build the evidence index, and generate the HTML and CSV reports.

Run every command from PowerShell 7 (`pwsh`) in the repository root.

> [!WARNING]
> Omitting `-SubscriptionId` includes every enabled subscription visible to the signed-in identity. Full mode queries diagnostic settings for every resource, so large estates can take several hours and generate sensitive evidence. Use an approved, access-controlled output location and never commit it to Git.

### Step 1: Validate PowerShell, Azure CLI, and Git

```powershell
if ($PSVersionTable.PSVersion -lt [version]'7.3') {
  throw "PowerShell 7.3 or later is required. Current version: $($PSVersionTable.PSVersion)"
}

foreach ($command in 'az','git') {
  if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
    throw "Required command '$command' was not found in PATH."
  }
}

Write-Host "PowerShell: $($PSVersionTable.PSVersion)" -ForegroundColor Green
Write-Host "Azure CLI: $(az version --query '"azure-cli"' --output tsv)" -ForegroundColor Green
Write-Host "Git: $(git --version)" -ForegroundColor Green
```

### Step 2: Validate the collector

```powershell
$requiredFiles = @(
  '.\Invoke-AlzAssessmentCollection.ps1'
  '.\New-AlzAssessmentReport.ps1'
  '.\Private\Common.ps1'
  '.\Scripts\00-Prerequisites.ps1'
  '.\Scripts\10-BuildEvidenceIndex.ps1'
)

$missingFiles = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath $_) })
if ($missingFiles.Count -gt 0) {
  throw "Required collector files are missing: $($missingFiles -join ', ')"
}

$parseErrors = @()
Get-ChildItem -Filter '*.ps1' -Recurse |
  Where-Object { $_.FullName -notlike '*\output\*' } |
  ForEach-Object {
    $tokens = $null
    $fileErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
      $_.FullName,
      [ref]$tokens,
      [ref]$fileErrors
    ) | Out-Null
    $parseErrors += $fileErrors
  }

if ($parseErrors.Count -gt 0) {
  $parseErrors | Format-List
  throw 'PowerShell syntax validation failed.'
}

Write-Host 'Collector validation passed.' -ForegroundColor Green
```

### Step 3: Sign in and confirm the Azure scope

```powershell
az login

az account show `
  --query '{User:user.name,TenantId:tenantId,Subscription:name,SubscriptionId:id}' `
  --output table

$subscriptions = @(
  az account list --all `
    --query "[?state=='Enabled'].{Name:name,Id:id,TenantId:tenantId}" `
    --output json |
    ConvertFrom-Json
)

$subscriptions | Sort-Object Name | Format-Table Name, Id, TenantId -AutoSize
Write-Host "Enabled subscriptions in scope: $($subscriptions.Count)" -ForegroundColor Cyan
```

Stop here if the tenant or subscription list is not the approved assessment scope.

### Step 4: Create a dated evidence directory

```powershell
$assessmentDate = Get-Date -Format 'yyyyMMdd-HHmmss'
$outputPath = Join-Path (Get-Location) "output\full-platform-assessment-$assessmentDate"
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

Write-Host "Evidence path: $outputPath" -ForegroundColor Cyan
```

Keep `$outputPath` in the same PowerShell session for the remaining steps.

### Step 5: Collect stages 0 through 8

Workload-specific stage 9 is intentionally excluded until workloads are identified.

```powershell
pwsh -NoProfile -File '.\Invoke-AlzAssessmentCollection.ps1' `
  -Profile Full `
  -StartAtStage 0 `
  -EndAtStage 8 `
  -OutputPath $outputPath
```

To resume an interrupted collection, use the same output path:

```powershell
pwsh -NoProfile -File '.\Invoke-AlzAssessmentCollection.ps1' `
  -Profile Full `
  -StartAtStage 0 `
  -EndAtStage 8 `
  -OutputPath $outputPath `
  -Resume
```

Use `-FailOnCollectionError` in automation when any optional evidence failure must return exit code 2. For interactive assessments, review the error register before deciding whether each gap blocks the assessment.

### Step 6: Validate stages and review errors

```powershell
$stageStatus = foreach ($stage in 0..8) {
  $marker = Join-Path $outputPath ('_stage-{0:D2}.complete.json' -f $stage)
  [pscustomobject]@{
    Stage  = $stage
    Status = if (Test-Path -LiteralPath $marker) { 'Completed' } else { 'Missing' }
  }
}

$stageStatus | Format-Table -AutoSize

$incompleteStages = @($stageStatus | Where-Object Status -ne 'Completed')
if ($incompleteStages.Count -gt 0) {
  Write-Warning "Incomplete stages: $($incompleteStages.Stage -join ', ')"
}

$errorPath = Join-Path $outputPath '_collection-errors.csv'
if (Test-Path -LiteralPath $errorPath) {
  $collectionErrors = @(Import-Csv -LiteralPath $errorPath)
  Write-Host "Collection errors: $($collectionErrors.Count)" -ForegroundColor Yellow

  $collectionErrors |
    Group-Object Stage, Item |
    ForEach-Object {
      [pscustomobject]@{
        Stage = $_.Group[0].Stage
        Item  = $_.Group[0].Item
        Count = $_.Count
      }
    } |
    Sort-Object Count -Descending |
    Format-Table -AutoSize
}
else {
  Write-Host 'No collection errors were recorded.' -ForegroundColor Green
}
```

An empty or missing evidence file is not proof of compliance. Resolve required permission or API failures, or record them as explicit assessment limitations.

### Step 7: Build and validate the evidence index

```powershell
pwsh -NoProfile -File '.\Invoke-AlzAssessmentCollection.ps1' `
  -StartAtStage 10 `
  -EndAtStage 10 `
  -OutputPath $outputPath

$indexPath = Join-Path $outputPath '10-evidence-index\evidence-index.csv'
if (-not (Test-Path -LiteralPath $indexPath)) {
  throw "Evidence index was not generated: $indexPath"
}

$evidenceIndex = @(Import-Csv -LiteralPath $indexPath)
Write-Host "Indexed evidence files: $($evidenceIndex.Count)" -ForegroundColor Green
```

### Step 8: Generate the HTML dashboard and CSV exports

```powershell
pwsh -NoProfile -File '.\New-AlzAssessmentReport.ps1' `
  -EvidencePath $outputPath `
  -Top 25
```

### Step 9: Validate and open the report

```powershell
$reportPath = Join-Path $outputPath 'reports\assessment-report.html'
$reportMetadataPath = Join-Path $outputPath 'reports\report-metadata.json'
$observationPath = Join-Path $outputPath 'reports\csv\assessment-observations.csv'

$missingReports = @(
  @($reportPath, $reportMetadataPath, $observationPath) |
    Where-Object { -not (Test-Path -LiteralPath $_) }
)

if ($missingReports.Count -gt 0) {
  throw "Report generation is incomplete: $($missingReports -join ', ')"
}

$reportMetadata = Get-Content -LiteralPath $reportMetadataPath -Raw |
  ConvertFrom-Json
$reportMetadata | Format-List

$observations = @(Import-Csv -LiteralPath $observationPath)
Write-Host "Review candidates: $($observations.Count)" -ForegroundColor Yellow

$observations |
  Group-Object Area, SuggestedPriority |
  Sort-Object Count -Descending |
  Select-Object Count, Name |
  Format-Table -AutoSize

Start-Process $reportPath
```

Automated observations are review candidates, not confirmed findings. Validate evidence completeness, business criticality, control applicability, exceptions, compensating controls, ownership, and final severity.

### Step 10: Add workloads later

After reviewing the inventory, work with platform and application owners to identify approximately three to five representative or critical workloads:

```powershell
Copy-Item '.\workloads.example.json' '.\workloads.json'
notepad '.\workloads.json'

pwsh -NoProfile -File '.\Invoke-AlzAssessmentCollection.ps1' `
  -WorkloadConfigPath '.\workloads.json' `
  -StartAtStage 9 `
  -EndAtStage 10 `
  -OutputPath $outputPath

pwsh -NoProfile -File '.\New-AlzAssessmentReport.ps1' `
  -EvidencePath $outputPath `
  -Top 25
```

Useful switches:

- `-Profile Fast`: skips Entra/Microsoft Graph and per-resource diagnostics for rapid platform inventory.
- `-Profile Standard`: default; includes Entra evidence but skips the slow per-resource diagnostics sweep.
- `-Profile Full`: collects all evidence, including diagnostic settings for every resource.
- `-StartAtStage 2 -EndAtStage 5`: run only a contiguous stage range.
- `-Resume`: skip stages that have a successful completion marker in the output directory.
- `-SkipDirectoryData`: skip Microsoft Graph/Entra collections.
- `-SkipPerResourceDiagnostics`: skip the slower diagnostic-settings request for every resource.
- `-FailOnCollectionError`: return exit code 2 if any optional evidence item fails.

For large estates, start with `Standard`. Use `Full` only when per-resource diagnostic-setting evidence is required:

```powershell
.\Invoke-AlzAssessmentCollection.ps1 `
  -SubscriptionId '<subscription-id>' `
  -Profile Standard `
  -OutputPath '.\output\assessment' `
  -Resume
```

Each completed stage writes `_stage-NN.complete.json` with its duration. Reusing the same output path with `-Resume` avoids recollecting completed stages after a transient failure.

## Generate the assessment report

After collection and evidence indexing:

```powershell
pwsh -File .\New-AlzAssessmentReport.ps1 `
  -EvidencePath '.\output\full-platform-assessment'
```

Open the generated dashboard:

```powershell
Start-Process '.\output\full-platform-assessment\reports\assessment-report.html'
```

The report directory includes the HTML dashboard, report metadata, complete CSV inventory exports, and an automated observation register. Observations are review candidates and must be validated before they become formal assessment findings.

## Sequence

1. `00-Prerequisites.ps1`: validates Azure CLI, login, and scope.
2. `01-TenantHierarchy.ps1`: tenants, management groups, subscriptions, and resource groups.
3. `02-ResourceGovernance.ps1`: inventory, regions, SKUs, state, tags, Policy, exemptions, compliance, and locks.
4. `03-Identity.ps1`: RBAC, managed identities, privileged directory roles, PIM eligibility, Conditional Access, applications, and service principal credential metadata.
5. `04-Network.ps1`: VNets, subnets, peerings, NSGs, routes, public IPs, Private Endpoints, Firewall, ER/VPN, DNS, vWAN, and DDoS.
6. `05-Security.ps1`: Defender plans, assessments, Key Vault configuration, and public-network configuration.
7. `06-Operations.ps1`: Log Analytics, Azure Monitor, alerts, action groups, DCRs, Sentinel, Automation, Maintenance, and diagnostic settings.
8. `07-Resilience.ps1`: Backup, ASR, Data Protection, availability configuration, Advisor reliability, and Resource Health.
9. `08-CostOptimization.ps1`: budgets, Advisor cost recommendations, and potential orphan resources.
10. `09-Workloads.ps1`: workload-specific resource and configuration evidence.
11. `10-BuildEvidenceIndex.ps1`: file inventory and SHA-256 hashes.

## Outputs and interpretation

Every stage has its own output directory. Review these run-level files first:

- `_run-metadata.json`: collection parameters, timestamps, and error count.
- `_collection.log`: chronological execution log.
- `_collection-errors.csv`: explicit API, permission, unsupported-resource, and collection failures.
- `10-evidence-index\evidence-index.csv`: evidence inventory and hashes.

An empty or missing evidence file must not be interpreted as compliance. Check `_collection-errors.csv` and verify the signed-in identity has the required permissions.

This suite captures technical configuration evidence. Interviews and document review are still required for ownership, subscription vending, emergency access procedures, incident response, RTO/RPO validation, restoration tests, regulatory requirements, IaC/CI/CD maturity, and escalation paths.

## Contributing and security

- Review [CONTRIBUTING.md](CONTRIBUTING.md) before submitting changes.
- Report vulnerabilities according to [SECURITY.md](SECURITY.md).
- Licensed under the [MIT License](LICENSE).
