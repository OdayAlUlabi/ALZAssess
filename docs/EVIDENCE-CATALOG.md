# Evidence Catalog

## 1. How to use this catalog

This catalog maps generated evidence to the assessment plan. JSON output is designed for analysis, not as a final finding. Validate evidence freshness, scope, permissions, and business context before recording a conclusion.

## 2. Stage 00: Prerequisites

Directory: `00-prerequisites`

| Output | Evidence |
|---|---|
| `azure-cli-version.json` | Collector tooling version |
| `azure-cli-extensions.json` | Installed CLI extensions |
| `current-account.json` | Active tenant, subscription, cloud, and signed-in identity |
| `subscriptions.json` | Enabled subscriptions used when scope is discovered |
| `collection-scope.json` | Effective tenant, subscription IDs, and collection options |

Assessment use:

- Confirm collector provenance.
- Confirm the intended tenant and subscriptions.
- Detect stale or incorrect Azure CLI context.

## 3. Stage 01: Tenant hierarchy

Directory: `01-tenant-hierarchy`

| Output | Evidence |
|---|---|
| `tenants.json` | Visible Azure tenants |
| `management-groups.json` | Management groups visible to the identity |
| `subscriptions.json` | Subscription metadata |
| `resource-groups-<subscription>.json` | Resource groups by subscription |
| `resource-containers.json` | Cross-subscription container hierarchy data |

Assessment mapping:

- ALZ resource organization
- Platform and workload subscription placement
- Production/non-production separation
- Subscription and resource-group ownership inputs

Limitations:

- Visibility follows caller permissions.
- Subscription vending and lifecycle processes require interviews.

## 4. Stage 02: Resource governance

Directory: `02-resource-governance`

| Output | Evidence |
|---|---|
| `resources.json` | Compact resource inventory: type, location, SKU, zones, identity type, tags, and provisioning state |
| `resource-summary.json` | Counts by subscription, type, and region |
| `tag-coverage.json` | Tags and tag count per resource |
| `policy-resources.json` | Resource Graph Policy records |
| `policy-compliance-summary.json` | Compliance counts by subscription and state |
| `policy-assignments-<subscription>.json` | Policy assignments |
| `policy-exemptions-<subscription>.json` | Policy exemptions |
| `resource-locks-<subscription>.json` | Management locks |

Assessment mapping:

- Allowed regions and SKU governance
- Policy inheritance and consistency
- Required tags
- Preventive, detective, and corrective controls
- Exemption review
- Critical-resource locks

Review questions:

- Are assignments placed at the correct scope?
- Are exemptions justified, owned, and time-bound?
- Are resources outside expected regions or hierarchy?
- Are required tags populated consistently?

## 5. Stage 03: Identity

Directory: `03-identity`

| Output | Evidence |
|---|---|
| `rbac-role-assignments.json` | Azure RBAC principal, type, role-definition ID, scope, and condition |
| `rbac-role-definitions.json` | Visible role definitions |
| `managed-identities.json` | System- and user-assigned identities |
| `directory-roles.json` | Activated Entra directory roles |
| `directory-role-assignments.json` | Directory role assignments |
| `pim-eligible-role-assignments.json` | Eligible PIM directory role assignments |
| `conditional-access-policies.json` | Conditional Access policy configuration |
| `service-principals-credential-metadata.json` | Service principal status and credential expiration metadata |
| `applications-credential-metadata.json` | Application credential expiration metadata |

Assessment mapping:

- Direct-user versus group-based access
- Privileged role assignment
- PIM eligibility
- Least privilege
- Managed identity adoption
- Application and service principal credential lifecycle
- Conditional Access coverage

Sensitive-data behavior:

- Certificate bodies are removed.
- Secret text is removed.
- Credential IDs and validity dates remain.

## 6. Stage 04: Network

Directory: `04-network`

| Output | Evidence |
|---|---|
| `network-resources.json` | Network and CDN resource inventory |
| `vnets-subnets.json` | Address spaces, custom DNS, subnets, NSGs, routes, and Private Endpoint policies |
| `public-ip-addresses.json` | Public IP allocation, association, DNS, zones, and DDoS settings |
| `private-endpoints.json` | Private Endpoint configuration |
| `network-security-rules.json` | Normalized custom NSG rules, prefixes, protocols, ports, direction, access, and priority |
| `route-table-routes.json` | Normalized UDRs, next hops, next-hop IPs, and BGP propagation settings |
| `vnet-peerings.json` | VNet peering state, remote VNet, forwarded traffic, and gateway-transit settings |
| `hybrid-connectivity.json` | VPN/ExpressRoute gateways, connections, circuits, local gateways, vWANs, and virtual hubs |
| `network-flow-logs.json` | Network flow-log targets, enabled state, storage, retention, and Traffic Analytics configuration |
| `network-topology.json` | VNets, peerings, vWAN, ExpressRoute, VPN, Firewall, routes, NSGs, private DNS, resolvers, and DDoS plans |

Assessment mapping:

- Hub/spoke and vWAN implementation
- Address-space overlap analysis
- Internet ingress and egress
- Public exposure
- Private Link adoption
- Route and NSG design
- DNS architecture
- ExpressRoute and VPN connectivity
- DDoS protection
- Broad inbound NSG access and management-port exposure
- Subnet NSG associations
- Direct-Internet and incomplete virtual-appliance UDRs
- VPN gateway availability and SKU indicators
- Hybrid connection, ExpressRoute provisioning, and VNet peering state
- Flow-log availability

The report generator converts these configuration indicators into review candidates. Effective routes, effective NIC-level NSG rules, observed flows, provider diversity, and tested failover still require runtime validation.

## 7. Stage 05: Security

Directory: `05-security`

| Output | Evidence |
|---|---|
| `security-resources.json` | Microsoft.Security Resource Graph records |
| `defender-assessments.json` | Defender assessment status and severity |
| `defender-plans-<subscription>.json` | Defender plan pricing/configuration |
| `public-network-access.json` | Resources reporting enabled public network access or permissive defaults |
| `key-vaults.json` | Key Vault RBAC, purge protection, soft delete, public access, and network ACL configuration |

Assessment mapping:

- Defender for Cloud posture
- Security recommendations
- Public exposure
- Key Vault protection
- Network isolation

The public-network query is a broad indicator. Confirm service-specific exposure before creating a finding.

## 8. Stage 06: Operations

Directory: `06-operations`

| Output | Evidence |
|---|---|
| `operations-resources.json` | Monitor, Log Analytics, Sentinel, Automation, Maintenance, and alerting resources |
| `alerts-action-groups-dcrs.json` | Alert rules, action groups, and data collection rules/endpoints |
| `subscription-diagnostic-settings-<subscription>.json` | Subscription Activity Log diagnostic settings |
| `resource-diagnostic-settings.json` | Diagnostic settings for each resource; Full profile only |
| `resource-diagnostic-settings-unsupported.json` | Resources whose Azure resource type does not support diagnostic settings; informational, not a collection failure |

Assessment mapping:

- Central logging architecture
- Activity Log routing
- Alert and escalation configuration
- Data collection rules
- SIEM integration
- Resource diagnostic coverage

Log flow, alert delivery, ownership, and response must be tested or confirmed operationally.

## 9. Stage 07: Resilience

Directory: `07-resilience`

| Output | Evidence |
|---|---|
| `backup-site-recovery.json` | Recovery Services and Data Protection resources |
| `availability-configuration.json` | Zones and selected availability-related properties |
| `advisor-reliability.json` | Azure Advisor high-availability recommendations |
| `resource-health.json` | Resource Health records |

Assessment mapping:

- Availability Zones
- Backup and Site Recovery
- Single points of failure
- Reliability recommendations
- Current resource health

Backup configuration does not prove successful restoration. Obtain restore-test evidence and approved RTO/RPO values.

## 10. Stage 08: Cost optimization

Directory: `08-cost-optimization`

| Output | Evidence |
|---|---|
| `advisor-cost.json` | Azure Advisor cost recommendations |
| `potential-orphan-resources.json` | Unattached disks, NICs, and public IP candidates |
| `budgets-<subscription>.json` | Subscription budget configuration |

Assessment mapping:

- Budget governance
- Potential orphan resources
- Advisor opportunities
- FinOps ownership inputs

An orphan candidate must be validated before deletion. Some disconnected resources are intentionally retained.

## 11. Stage 09: Workloads

Directory: `09-workloads`

| Output | Evidence |
|---|---|
| `<workload>-scope.json` | Business purpose, owner, criticality, RTO/RPO, subscription, resource groups, and regions |
| `<workload>-resources.json` | Resource inventory for the configured workload scope |

Assessment mapping:

- WAF workload boundary
- WARA scope
- Component and dependency analysis inputs
- Workload-specific security review

The placeholder example subscription ID is rejected and recorded as a collection error.

## 12. Stage 10: Evidence index

Directory: `10-evidence-index`

| Output | Evidence |
|---|---|
| `evidence-index.csv` | Human-readable file list, stage, size, timestamp, and SHA-256 hash |
| `evidence-index.json` | Machine-readable equivalent |

Use the index to:

- Verify evidence integrity.
- Identify missing stage output.
- Register evidence in the final assessment.
- Compare collection snapshots.

## 13. Evidence-to-deliverable mapping

| Assessment deliverable | Primary evidence stages |
|---|---|
| Current-state tenant and ALZ overview | 01, 02 |
| Management-group and subscription hierarchy | 01 |
| Current-state network topology | 04 |
| Governance and Policy matrix | 02 |
| Identity and RBAC findings | 03 |
| WAF workload assessments | 09 plus 03–08 |
| WARA reliability findings | 07, 09 |
| Security/WASA findings | 03, 04, 05, 06 |
| Risk and remediation backlog | Findings derived from all stages |
| Evidence repository/index | 10 |

## 14. Finding traceability

Each assessment finding should reference:

- Evidence file
- Resource ID or scope
- Collection timestamp
- Relevant framework and control
- Observed configuration
- Expected state
- Business and technical impact
- Severity
- Recommendation
- Owner
- Validation method
