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
├── azure-service-inventory.csv
├── network-topology.json
├── network-disconnected-devices.csv
├── html\
│   ├── index.html
│   ├── 01-executive-summary.html
│   ├── ...
│   └── 96-network-findings-appendix.html
└── markdown\
    ├── index.md
    ├── 01-executive-summary.md
    ├── ...
    └── 96-network-findings-appendix.md
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
13. Azure Service Estate
14. Compute and Containers
15. App Services and Integration
16. Databases and Data Platforms
17. AI and Machine Learning
18. Storage, Messaging, and Events

## Detailed appendices

- Subscription inventory
- Complete resource inventory
- Defender assessments
- Azure RBAC assignments
- Collection errors
- Evidence index and SHA-256 hashes
- Complete network best-practice finding register

The Network Architecture chapter also includes normalized NSG rules, UDRs, VPN/ExpressRoute gateways, hybrid connections, ExpressRoute circuits, and the associated automated review candidates.

The Azure Service Estate and service chapters classify the collected configuration across subscriptions and regions. They summarize resource type, SKU, kind, zones, managed identity, public access, Private Endpoint counts, and common configuration indicators. The complete normalized cross-service inventory is exported to `azure-service-inventory.csv`.

### Network topology diagram

The Network Architecture HTML page contains an offline SVG diagram generated from the evidence snapshot. It shows:

- VNets and collected address spaces
- VNet peerings whose state is `Connected`
- Firewalls, gateways, Application Gateways, Bastion, NAT Gateways, Load Balancers, Private Endpoints, and VM NICs attached to collected subnets
- Collected private and public IP addresses on each connected device
- Remote connected VNets referenced by peerings but not otherwise present in the collected topology

Disconnected peerings, unassociated Public IPs, devices without a resolvable VNet/subnet relationship, and references outside the collected topology are listed separately below the diagram and exported to `network-disconnected-devices.csv`.

The underlying node and edge model is saved as `network-topology.json`. The diagram represents configuration relationships, not observed packet flow or a live reachability test.

## Important limitations

Generated documentation describes the collected configuration evidence. It does not automatically establish:

- Application-level dependencies
- Runtime traffic flow
- Effective routing, transitive reachability, and packet-level connectivity
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
