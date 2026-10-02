# Reporting Guide

## Purpose

`New-AlzAssessmentReport.ps1` transforms collected evidence into:

- A portable HTML dashboard
- Analysis-ready CSV exports
- A structured observation register
- Report-generation metadata

The generator runs locally and does not send evidence to an external service.

## Generate a report

From the repository root:

```powershell
pwsh -File .\New-AlzAssessmentReport.ps1 `
  -EvidencePath '.\output\full-platform-assessment'
```

The default output is:

```text
output\full-platform-assessment\reports\
├── assessment-report.html
├── report-metadata.json
└── csv\
    ├── advisor-cost-recommendations.csv
    ├── assessment-observations.csv
    ├── collection-error-summary.csv
    ├── defender-assessments.csv
    ├── policy-compliance-summary.csv
    ├── public-ip-addresses.csv
    ├── resource-inventory.csv
    └── subscription-summary.csv
```

Open the HTML report:

```powershell
Start-Process '.\output\full-platform-assessment\reports\assessment-report.html'
```

## Select a separate report location

```powershell
pwsh -File .\New-AlzAssessmentReport.ps1 `
  -EvidencePath '.\output\full-platform-assessment' `
  -ReportPath 'D:\ApprovedAssessmentRepository\Reports'
```

Use an approved access-controlled location. The report and CSV exports contain sensitive Azure inventory and posture information.

## Control table size

`-Top` controls the number of rows shown in ranked HTML tables:

```powershell
pwsh -File .\New-AlzAssessmentReport.ps1 `
  -EvidencePath '.\output\full-platform-assessment' `
  -Top 25
```

CSV files retain the complete exported dataset.

## Report contents

### Executive metrics

- Subscriptions in scope
- Resources and resource groups collected
- Collection errors
- Unhealthy Defender assessment records
- Automated review candidates

### Collection coverage

- Stage completion status
- Collection errors grouped by stage and item

### Estate overview

- Subscription resource counts
- Top resource types
- Top regions

### Governance and security

- Azure Policy compliance-state totals
- Defender assessment status and severity totals

### Architecture indicators

- Public IP addresses
- Private Endpoints
- Key Vaults
- Operations resources
- Backup and Site Recovery resources
- Advisor cost recommendations

## Automated observations

`assessment-observations.csv` contains review candidates such as:

- Collection evidence gaps
- Missing per-resource diagnostic evidence
- Untagged resources
- Noncompliant Policy records
- Unhealthy Defender assessments
- Public IP exposure candidates
- Direct user RBAC assignments
- Key Vault public access
- Advisor reliability recommendations
- Potential orphan resources
- Missing workload-specific evidence

These are not automatically confirmed findings. An assessor must validate:

- Scope and data freshness
- API and permission coverage
- Business context and criticality
- Control applicability
- Exceptions and compensating controls
- Ownership
- Final severity and recommendation

## Convert observations into findings

Use `assessment-observations.csv` as a starting backlog. For each confirmed finding, add:

- Finding description
- Affected resource IDs
- Expected state
- Business and technical impact
- Framework mapping
- Final severity
- Recommendation
- Owner
- Target date
- Validation method
- Status

## Regenerate after remediation

1. Collect evidence into a new dated directory.
2. Generate a new report.
3. Compare the CSV exports and observations.
4. Validate remediated findings against new evidence.

Do not overwrite the original assessment snapshot if it is needed for audit or traceability.
