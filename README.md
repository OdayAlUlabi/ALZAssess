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
