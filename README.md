# Azure Landing Zone Assessment Data Collector

This PowerShell suite collects read-only Azure Landing Zone, WAF, WARA, security, operations, resilience, network, and cost evidence. It produces JSON evidence, logs, an error register, a SHA-256 evidence index, CSV exports, an HTML dashboard, and complete offline HTML/Markdown documentation.

[![Validate](https://github.com/OdayAlUlabi/ALZAssess/actions/workflows/validate.yml/badge.svg)](https://github.com/OdayAlUlabi/ALZAssess/actions/workflows/validate.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> [!IMPORTANT]
> Generated output can contain sensitive tenant, identity, network, and security information. Never commit `output/` or a real workload configuration file.

## Quick start

Run these commands from the repository root in **PowerShell 7.3 or later**.

### 1. Sign in and select subscriptions

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
az login

$subscriptionIds = @(
  '11111111-1111-1111-1111-111111111111'
  '22222222-2222-2222-2222-222222222222'
)

$outputPath = '.\output\assessment-2026-10-04'
```

Verify the selected subscriptions:

```powershell
$visibleSubscriptions = @(az account list --all --output json | ConvertFrom-Json)
$visibleSubscriptions |
  Where-Object id -in $subscriptionIds |
  Format-Table name, id, state, tenantId -AutoSize

$missingIds = @($subscriptionIds | Where-Object { $_ -notin $visibleSubscriptions.id })
if ($missingIds.Count) {
  throw "Subscriptions are not visible: $($missingIds -join ', ')"
}
```

Omit `-SubscriptionId $subscriptionIds` from the next command only when all enabled subscriptions visible to the signed-in identity are intentionally in scope.

### 2. Collect the evidence

```powershell
& '.\Invoke-AlzAssessmentCollection.ps1' `
  -SubscriptionId $subscriptionIds `
  -Profile Standard `
  -OutputPath $outputPath
```

Use the call operator `&`. Without it, PowerShell treats the quoted script path as text and reports `Unexpected token '-SubscriptionId'`.

### 3. Generate and open the documentation

```powershell
& '.\New-AlzAssessmentDocumentation.ps1' `
  -EvidencePath $outputPath `
  -Top 25

Start-Process (Join-Path $outputPath 'documentation\html\index.html')
```

Open the network topology directly:

```powershell
Start-Process (Join-Path $outputPath 'documentation\html\06-network.html')
```

The documentation generator also creates the HTML dashboard and CSV exports. You do not need to run `New-AlzAssessmentReport.ps1` separately.

## Optional workloads

The platform assessment does not require a workload file. To add workload-specific evidence:

```powershell
Copy-Item '.\workloads.example.json' '.\workloads.json'
notepad '.\workloads.json'

& '.\Invoke-AlzAssessmentCollection.ps1' `
  -SubscriptionId $subscriptionIds `
  -WorkloadConfigPath '.\workloads.json' `
  -Profile Standard `
  -OutputPath $outputPath `
  -StartAtStage 9 `
  -EndAtStage 10
```

Each workload must specify a subscription ID and at least one resource group.

## Common options

| Requirement | Option |
|---|---|
| Fast inventory without Entra or per-resource diagnostics | `-Profile Fast` |
| Recommended platform assessment | `-Profile Standard` |
| Include diagnostic settings for every resource | `-Profile Full` |
| Continue an interrupted run | `-Resume` with the same output path |
| Run only selected stages | `-StartAtStage <n> -EndAtStage <n>` |
| Stop automation when collection errors occur | `-FailOnCollectionError` |
| Skip Microsoft Graph/Entra evidence | `-SkipDirectoryData` |
| Skip per-resource diagnostic settings | `-SkipPerResourceDiagnostics` |

For large estates, start with `Standard`. `Full` can take several hours because it queries diagnostic settings for every resource.

Resume an interrupted run:

```powershell
& '.\Invoke-AlzAssessmentCollection.ps1' `
  -SubscriptionId $subscriptionIds `
  -Profile Standard `
  -OutputPath $outputPath `
  -Resume
```

## Output

Important files:

```text
<outputPath>\
├── _run-metadata.json
├── _collection.log
├── _collection-errors.csv
├── 00-prerequisites\ ... 10-evidence-index\
├── reports\
│   ├── assessment-report.html
│   └── csv\
└── documentation\
    ├── html\index.html
    ├── html\06-network.html
    ├── markdown\
    ├── network-topology.json
    └── network-disconnected-devices.csv
```

The Network Architecture page includes:

- An offline SVG topology diagram
- Connected VNets, peerings, and devices
- Collected private and public IP addresses
- NSG, UDR, VPN, ExpressRoute, Firewall, Private Endpoint, and flow-log evidence
- A separate disconnected or unresolved device/link register
- Network best-practice review candidates

The diagram represents collected configuration relationships, not live packet reachability. Validate effective routes, effective security rules, observed traffic, provider diversity, and tested failover separately.

## Collection stages

1. Prerequisites and scope
2. Tenant hierarchy
3. Resource inventory and governance
4. Identity and access
5. Network architecture and rules
6. Security posture
7. Operations and monitoring
8. Resilience and recovery
9. Cost optimization
10. Workload evidence
11. Evidence index and SHA-256 hashes

An empty or missing evidence file is not proof of compliance. Review `_collection-errors.csv` and confirm that the signed-in identity has the required permissions.

## Prerequisites and permissions

- PowerShell 7.3 or later
- Azure CLI
- `Reader` on assessed Azure scopes
- `Security Reader` for complete Defender evidence
- `Directory Readers` or equivalent Microsoft Graph permissions for Entra evidence
- `Cost Management Reader` for complete cost evidence

The collector does not export secret or certificate values. Microsoft Graph evidence includes credential identifiers and expiration metadata only.

## Detailed guides

- [User guide](docs/USER-GUIDE.md)
- [Technical reference](docs/TECHNICAL-REFERENCE.md)
- [Evidence catalog](docs/EVIDENCE-CATALOG.md)
- [Reporting guide](docs/REPORTING.md)
- [Documentation generation](docs/DOCUMENTATION-GENERATION.md)
- [Security and permissions](docs/SECURITY-AND-PERMISSIONS.md)
- [Troubleshooting and operations](docs/TROUBLESHOOTING.md)

## Contributing and security

- Review [CONTRIBUTING.md](CONTRIBUTING.md) before submitting changes.
- Report vulnerabilities according to [SECURITY.md](SECURITY.md).
- Licensed under the [MIT License](LICENSE).
