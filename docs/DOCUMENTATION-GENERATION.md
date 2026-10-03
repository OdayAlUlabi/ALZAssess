# Documentation Generation

## Purpose

`New-AlzAssessmentDocumentation.ps1` converts an Azure Landing Zone evidence snapshot into:

- A navigable offline HTML documentation site
- Matching Markdown source chapters
- Executive and assessment-domain summaries
- Detailed resource-level appendices
- Generation metadata

The process is local and does not upload evidence to an external service.

## Generate documentation

Run from PowerShell 7 in the repository root:

```powershell
$evidencePath = '.\output\full-platform-assessment'

& '.\New-AlzAssessmentDocumentation.ps1' `
  -EvidencePath $evidencePath `
  -Top 25
```

Open the site:

```powershell
Start-Process (Join-Path $evidencePath 'documentation\html\index.html')
```

## Output structure

```text
documentation\
├── documentation-metadata.json
├── html\
│   ├── index.html
│   ├── 01-executive-summary.html
│   ├── ...
│   └── 95-evidence-index-appendix.html
└── markdown\
    ├── index.md
    ├── 01-executive-summary.md
    ├── ...
    └── 95-evidence-index-appendix.md
```

## Chapters

1. Executive Summary
2. Scope and Evidence Quality
3. Tenant and Platform Organization
4. Governance and Policy
5. Identity and Access
6. Network Architecture
7. Security Posture
8. Operations and Monitoring
9. Resilience and Recovery
10. Cost Optimization
11. Workload Assessment Status
12. Observations and Next Steps

## Detailed appendices

- Subscription inventory
- Complete resource inventory
- Defender assessments
- Azure RBAC assignments
- Collection errors
- Evidence index and SHA-256 hashes

## Important limitations

Generated documentation describes the collected configuration evidence. It does not automatically establish:

- Application-level dependencies
- Runtime traffic flow
- Business processes
- External SaaS dependencies
- Unrepresented on-premises systems
- Approved target-state architecture
- Tested failover and incident-response capability
- Confirmed workload membership

Complete those areas through telemetry analysis, interviews, workshops, runbook review, and recovery exercises.

Automated observations are review candidates, not confirmed findings. Validate applicability, exceptions, compensating controls, business impact, ownership, and final severity.

## Separate output location

```powershell
& '.\New-AlzAssessmentDocumentation.ps1' `
  -EvidencePath '.\output\full-platform-assessment' `
  -DocumentationPath 'D:\ApprovedAssessmentRepository\Documentation' `
  -Top 25
```

The generated site contains sensitive Azure inventory and posture information. Store and distribute it only through approved, access-controlled locations.
