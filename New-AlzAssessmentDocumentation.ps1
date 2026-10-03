#requires -Version 7.3

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EvidencePath,
    [string]$DocumentationPath,
    [ValidateRange(5, 100)][int]$Top = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$evidenceRoot = [System.IO.Path]::GetFullPath($EvidencePath)
if (-not (Test-Path -LiteralPath $evidenceRoot -PathType Container)) {
    throw "Evidence directory not found: $evidenceRoot"
}

if (-not $DocumentationPath) {
    $DocumentationPath = Join-Path $evidenceRoot 'documentation'
}
$documentationRoot = [System.IO.Path]::GetFullPath($DocumentationPath)
$markdownRoot = Join-Path $documentationRoot 'markdown'
$htmlRoot = Join-Path $documentationRoot 'html'
New-Item -ItemType Directory -Path $markdownRoot -Force | Out-Null
New-Item -ItemType Directory -Path $htmlRoot -Force | Out-Null

function Get-JsonItems {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [switch]$Optional
    )

    $path = Join-Path $evidenceRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path)) {
        if ($Optional) {
            return
        }
        throw "Required evidence file not found: $path"
    }

    $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100
    foreach ($item in @($data)) {
        Write-Output $item
    }
}

function Get-CsvItems {
    param([Parameter(Mandatory)][string]$RelativePath)

    $path = Join-Path $evidenceRoot $RelativePath
    if (Test-Path -LiteralPath $path) {
        Import-Csv -LiteralPath $path
    }
}

function ConvertTo-MarkdownValue {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return ''
    }
    $text = if ($Value -is [string]) { $Value } else { [string]$Value }
    return $text.Replace('|', '\|').Replace("`r`n", '<br>').Replace("`n", '<br>')
}

function New-MarkdownTable {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Columns,
        [int]$Limit = 0,
        [string]$EmptyMessage = 'No records were collected.'
    )

    if ($Rows.Count -eq 0) {
        return "_${EmptyMessage}_"
    }

    $selectedRows = if ($Limit -gt 0) { @($Rows | Select-Object -First $Limit) } else { $Rows }
    $headers = @($Columns.Keys)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('| ' + ($headers -join ' | ') + ' |')
    $lines.Add('| ' + (($headers | ForEach-Object { '---' }) -join ' | ') + ' |')

    foreach ($row in $selectedRows) {
        $values = foreach ($entry in $Columns.GetEnumerator()) {
            try {
                $value = & $entry.Value $row
            }
            catch {
                $value = ''
            }
            ConvertTo-MarkdownValue $value
        }
        $lines.Add('| ' + ($values -join ' | ') + ' |')
    }

    if ($Limit -gt 0 -and $Rows.Count -gt $Limit) {
        $lines.Add('')
        $lines.Add("_Showing $Limit of $($Rows.Count) records. See the relevant appendix or CSV export for the complete dataset._")
    }
    return $lines -join [Environment]::NewLine
}

function New-MetricList {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Metrics)

    return ($Metrics.GetEnumerator() | ForEach-Object {
        "- **$($_.Key):** $(ConvertTo-MarkdownValue $_.Value)"
    }) -join [Environment]::NewLine
}

$pages = @(
    [pscustomobject]@{ Slug = 'index'; Title = 'Documentation Home' }
    [pscustomobject]@{ Slug = '01-executive-summary'; Title = 'Executive Summary' }
    [pscustomobject]@{ Slug = '02-scope-and-evidence-quality'; Title = 'Scope and Evidence Quality' }
    [pscustomobject]@{ Slug = '03-tenant-and-platform'; Title = 'Tenant and Platform Organization' }
    [pscustomobject]@{ Slug = '04-governance'; Title = 'Governance and Policy' }
    [pscustomobject]@{ Slug = '05-identity'; Title = 'Identity and Access' }
    [pscustomobject]@{ Slug = '06-network'; Title = 'Network Architecture' }
    [pscustomobject]@{ Slug = '07-security'; Title = 'Security Posture' }
    [pscustomobject]@{ Slug = '08-operations'; Title = 'Operations and Monitoring' }
    [pscustomobject]@{ Slug = '09-resilience'; Title = 'Resilience and Recovery' }
    [pscustomobject]@{ Slug = '10-cost'; Title = 'Cost Optimization' }
    [pscustomobject]@{ Slug = '11-workloads'; Title = 'Workload Assessment Status' }
    [pscustomobject]@{ Slug = '12-observations-and-next-steps'; Title = 'Observations and Next Steps' }
    [pscustomobject]@{ Slug = '90-subscription-appendix'; Title = 'Appendix: Subscription Inventory' }
    [pscustomobject]@{ Slug = '91-resource-appendix'; Title = 'Appendix: Resource Inventory' }
    [pscustomobject]@{ Slug = '92-defender-appendix'; Title = 'Appendix: Defender Assessments' }
    [pscustomobject]@{ Slug = '93-rbac-appendix'; Title = 'Appendix: RBAC Assignments' }
    [pscustomobject]@{ Slug = '94-collection-errors-appendix'; Title = 'Appendix: Collection Errors' }
    [pscustomobject]@{ Slug = '95-evidence-index-appendix'; Title = 'Appendix: Evidence Index' }
    [pscustomobject]@{ Slug = '96-network-findings-appendix'; Title = 'Appendix: Network Best-Practice Findings' }
)

$navigationHtml = ($pages | ForEach-Object {
    "<a href=`"$($_.Slug).html`">$([System.Net.WebUtility]::HtmlEncode($_.Title))</a>"
}) -join [Environment]::NewLine

$style = @'
:root { --navy:#0f2942; --blue:#0078d4; --light:#f4f7fa; --line:#d7e0e8; --text:#1f2937; }
* { box-sizing:border-box; }
body { margin:0; color:var(--text); background:var(--light); font-family:"Segoe UI",Arial,sans-serif; }
header { background:linear-gradient(120deg,var(--navy),var(--blue)); color:white; padding:26px 32px; }
header h1 { margin:0 0 7px; }
.layout { display:grid; grid-template-columns:280px minmax(0,1fr); min-height:calc(100vh - 105px); }
nav { background:white; border-right:1px solid var(--line); padding:18px; }
nav a { display:block; color:var(--navy); text-decoration:none; padding:7px 9px; border-radius:4px; font-size:13px; }
nav a:hover { background:#e8f2fb; color:var(--blue); }
main { min-width:0; max-width:1500px; padding:28px 36px 60px; }
article { background:white; border:1px solid var(--line); border-radius:8px; padding:26px; box-shadow:0 2px 6px rgba(15,41,66,.06); }
h1,h2,h3 { color:var(--navy); }
table { border-collapse:collapse; width:100%; display:block; overflow:auto; font-size:13px; }
th,td { border:1px solid var(--line); padding:7px 9px; text-align:left; vertical-align:top; }
th { background:#edf4fa; }
code { background:#eef2f6; padding:2px 5px; border-radius:3px; }
blockquote { border-left:5px solid #ffb900; background:#fff7d6; margin:18px 0; padding:10px 16px; }
footer { color:#667085; text-align:center; padding:16px; }
@media (max-width:900px) { .layout { grid-template-columns:1fr; } nav { border-right:0; border-bottom:1px solid var(--line); } }
'@

function Write-DocumentationPage {
    param(
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Body
    )

    $markdown = "# $Title`n`n$Body`n"
    [System.IO.File]::WriteAllText(
        (Join-Path $markdownRoot "$Slug.md"),
        $markdown,
        [System.Text.UTF8Encoding]::new($false)
    )

    $fragment = (ConvertFrom-Markdown -InputObject $markdown).Html
    $fragment = $fragment -replace '\.md"', '.html"'
    $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$([System.Net.WebUtility]::HtmlEncode($Title))</title>
<style>$style</style>
</head>
<body>
<header><h1>Azure Landing Zone Assessment Documentation</h1><div>Generated from collected Azure evidence</div></header>
<div class="layout">
<nav>$navigationHtml</nav>
<main><article>$fragment</article></main>
</div>
<footer>Evidence-based current-state documentation. Automated observations require assessor validation.</footer>
</body>
</html>
"@
    [System.IO.File]::WriteAllText(
        (Join-Path $htmlRoot "$Slug.html"),
        $html,
        [System.Text.UTF8Encoding]::new($false)
    )
}

$reportGenerator = Join-Path $PSScriptRoot 'New-AlzAssessmentReport.ps1'
if (-not (Test-Path -LiteralPath $reportGenerator)) {
    throw "Report generator not found: $reportGenerator"
}
& $reportGenerator -EvidencePath $evidenceRoot -ReportPath (Join-Path $evidenceRoot 'reports') -Top $Top

$scope = @(Get-JsonItems '00-prerequisites\collection-scope.json' -Optional) | Select-Object -First 1
$tenants = @(Get-JsonItems '01-tenant-hierarchy\tenants.json' -Optional)
$managementGroups = @(Get-JsonItems '01-tenant-hierarchy\management-groups.json' -Optional)
$subscriptions = @(Get-JsonItems '01-tenant-hierarchy\subscriptions.json' -Optional)
$resourceContainers = @(Get-JsonItems '01-tenant-hierarchy\resource-containers.json' -Optional)
$resources = @(Get-JsonItems '02-resource-governance\resources.json' -Optional)
$tagCoverage = @(Get-JsonItems '02-resource-governance\tag-coverage.json' -Optional)
$policyCompliance = @(Get-JsonItems '02-resource-governance\policy-compliance-summary.json' -Optional)
$rbacAssignments = @(Get-JsonItems '03-identity\rbac-role-assignments.json' -Optional)
$managedIdentities = @(Get-JsonItems '03-identity\managed-identities.json' -Optional)
$directoryRoles = @(Get-JsonItems '03-identity\directory-roles.json' -Optional)
$conditionalAccess = @(Get-JsonItems '03-identity\conditional-access-policies.json' -Optional)
$networkResources = @(Get-JsonItems '04-network\network-resources.json' -Optional)
$vnets = @(Get-JsonItems '04-network\vnets-subnets.json' -Optional)
$publicIps = @(Get-JsonItems '04-network\public-ip-addresses.json' -Optional)
$privateEndpoints = @(Get-JsonItems '04-network\private-endpoints.json' -Optional)
$defenderAssessments = @(Get-JsonItems '05-security\defender-assessments.json' -Optional)
$keyVaults = @(Get-JsonItems '05-security\key-vaults.json' -Optional)
$publicNetwork = @(Get-JsonItems '05-security\public-network-access.json' -Optional)
$operationsResources = @(Get-JsonItems '06-operations\operations-resources.json' -Optional)
$resourceDiagnostics = @(Get-JsonItems '06-operations\resource-diagnostic-settings.json' -Optional)
$unsupportedDiagnostics = @(Get-JsonItems '06-operations\resource-diagnostic-settings-unsupported.json' -Optional)
$backupResources = @(Get-JsonItems '07-resilience\backup-site-recovery.json' -Optional)
$advisorReliability = @(Get-JsonItems '07-resilience\advisor-reliability.json' -Optional)
$resourceHealth = @(Get-JsonItems '07-resilience\resource-health.json' -Optional)
$advisorCost = @(Get-JsonItems '08-cost-optimization\advisor-cost.json' -Optional)
$orphanCandidates = @(Get-JsonItems '08-cost-optimization\potential-orphan-resources.json' -Optional)
$observations = @(Get-CsvItems 'reports\csv\assessment-observations.csv')
$networkFindings = @(Get-CsvItems 'reports\csv\network-best-practice-findings.csv')
$networkSecurityRules = @(Get-CsvItems 'reports\csv\network-security-rules.csv')
$networkRoutes = @(Get-CsvItems 'reports\csv\network-routes.csv')
$networkGateways = @(Get-CsvItems 'reports\csv\network-gateways.csv')
$networkConnections = @(Get-CsvItems 'reports\csv\network-connections.csv')
$expressRouteCircuits = @(Get-CsvItems 'reports\csv\expressroute-circuits.csv')
$vnetPeerings = @(Get-CsvItems 'reports\csv\vnet-peerings.csv')
$collectionErrors = @(Get-CsvItems '_collection-errors.csv')
$evidenceIndex = @(Get-CsvItems '10-evidence-index\evidence-index.csv')

$effectiveSubscriptionIds = if ($scope -and $scope.PSObject.Properties['Subscriptions'] -and $scope.Subscriptions) {
    @($scope.Subscriptions)
}
else {
    @($resources.subscriptionId | Where-Object { $_ } | Sort-Object -Unique)
}
$effectiveSubscriptions = @($subscriptions | Where-Object { $_.id -in $effectiveSubscriptionIds })
$resourceGroups = @($resourceContainers | Where-Object { $_.type -eq 'microsoft.resources/subscriptions/resourcegroups' })
$untagged = @($tagCoverage | Where-Object { [int]$_.tagCount -eq 0 })
$unhealthyDefender = @($defenderAssessments | Where-Object { $_.status -eq 'Unhealthy' })
$directUserRbac = @($rbacAssignments | Where-Object { $_.principalType -eq 'User' })
$nonCompliantPolicies = ($policyCompliance | Where-Object complianceState -eq 'NonCompliant' | Measure-Object Count -Sum).Sum

$resourceTypes = @(
    $resources | Group-Object type | Sort-Object Count -Descending |
        ForEach-Object { [pscustomobject]@{ Type = $_.Name; Count = $_.Count } }
)
$regions = @(
    $resources | Group-Object location | Sort-Object Count -Descending |
        ForEach-Object { [pscustomobject]@{ Region = $_.Name; Count = $_.Count } }
)
$defenderSummary = @(
    $defenderAssessments | Group-Object status, severity | Sort-Object Count -Descending |
        ForEach-Object {
            [pscustomobject]@{
                Status = $_.Group[0].status
                Severity = $_.Group[0].severity
                Count = $_.Count
            }
        }
)
$policySummary = @(
    $policyCompliance | Group-Object complianceState |
        ForEach-Object {
            [pscustomobject]@{
                State = $_.Name
                Count = ($_.Group | Measure-Object Count -Sum).Sum
            }
        } | Sort-Object Count -Descending
)
$rbacSummary = @(
    $rbacAssignments | Group-Object principalType | Sort-Object Count -Descending |
        ForEach-Object { [pscustomobject]@{ PrincipalType = $_.Name; Count = $_.Count } }
)
$unsupportedTypeSummary = @(
    $unsupportedDiagnostics | Group-Object type | Sort-Object Count -Descending |
        ForEach-Object { [pscustomobject]@{ ResourceType = $_.Name; Resources = $_.Count } }
)

$generatedUtc = (Get-Date).ToUniversalTime().ToString('u')
$contents = ($pages | Where-Object Slug -ne 'index' | ForEach-Object {
    "- [$($_.Title)]($($_.Slug).md)"
}) -join [Environment]::NewLine

$homeBody = @"
> This documentation is generated from a point-in-time Azure evidence snapshot. It describes observed configuration and automated review candidates. It does not replace stakeholder interviews, runtime dependency analysis, recovery testing, or formal architecture approval.

## Assessment snapshot

$(New-MetricList ([ordered]@{
    'Generated UTC' = $generatedUtc
    'Evidence path' = $evidenceRoot
    'Tenant records' = $tenants.Count
    'Subscriptions in scope' = $effectiveSubscriptionIds.Count
    'Resources' = $resources.Count
    'Resource groups' = $resourceGroups.Count
    'Collection errors' = $collectionErrors.Count
    'Review candidates' = $observations.Count
}))

## Contents

$contents
"@
Write-DocumentationPage 'index' 'Documentation Home' $homeBody

$executiveBody = @"
## Purpose

This chapter summarizes the Azure Landing Zone platform evidence across governance, identity, networking, security, operations, resilience, and cost. Workload-specific WAF and WARA conclusions remain pending until workloads and business owners are identified.

## Estate summary

$(New-MetricList ([ordered]@{
    'Subscriptions' = $effectiveSubscriptionIds.Count
    'Resources' = $resources.Count
    'Regions represented' = $regions.Count
    'Resource types represented' = $resourceTypes.Count
    'Untagged resources' = $untagged.Count
    'Noncompliant Policy records' = [int]$nonCompliantPolicies
    'Unhealthy Defender assessments' = $unhealthyDefender.Count
    'Public IP addresses' = $publicIps.Count
    'Private Endpoints' = $privateEndpoints.Count
    'Potential orphan resources' = $orphanCandidates.Count
}))

## Priority review candidates

$(New-MarkdownTable $observations ([ordered]@{
    'ID' = { param($r) $r.ID }
    'Area' = { param($r) $r.Area }
    'Suggested priority' = { param($r) $r.SuggestedPriority }
    'Observation' = { param($r) $r.Observation }
    'Count' = { param($r) $r.Count }
    'Assessment action' = { param($r) $r.AssessmentAction }
}) -Limit $Top)

## Interpretation

Automated observations are not confirmed findings. Confirm applicability, business impact, exceptions, compensating controls, ownership, and final severity before adding an item to the remediation backlog.
"@
Write-DocumentationPage '01-executive-summary' 'Executive Summary' $executiveBody

$stageRows = for ($stage = 0; $stage -le 10; $stage++) {
    [pscustomobject]@{
        Stage = $stage
        Status = if (Test-Path (Join-Path $evidenceRoot ('_stage-{0:D2}.complete.json' -f $stage))) { 'Completed' } else { 'Not completed' }
    }
}
$scopeBody = @"
## Effective scope

$(New-MarkdownTable $effectiveSubscriptions ([ordered]@{
    'Subscription' = { param($r) $r.name }
    'Subscription ID' = { param($r) $r.id }
    'State' = { param($r) $r.state }
    'Tenant ID' = { param($r) $r.tenantId }
}))

## Stage completion

$(New-MarkdownTable $stageRows ([ordered]@{
    'Stage' = { param($r) $r.Stage }
    'Status' = { param($r) $r.Status }
}))

## Evidence quality

$(New-MetricList ([ordered]@{
    'Evidence files indexed' = $evidenceIndex.Count
    'Collection errors' = $collectionErrors.Count
    'Resources with diagnostic settings queried successfully' = $resourceDiagnostics.Count
    'Resources whose types do not support diagnostic settings' = $unsupportedDiagnostics.Count
}))

See [Collection Errors Appendix](94-collection-errors-appendix.md) and [Evidence Index Appendix](95-evidence-index-appendix.md).
"@
Write-DocumentationPage '02-scope-and-evidence-quality' 'Scope and Evidence Quality' $scopeBody

$tenantBody = @"
## Tenant records

$(New-MarkdownTable $tenants ([ordered]@{
    'Tenant ID' = { param($r) $r.tenantId }
    'Display name' = { param($r) $r.displayName }
    'Default domain' = { param($r) $r.defaultDomain }
}))

## Management groups

$(New-MarkdownTable $managementGroups ([ordered]@{
    'Name' = { param($r) $r.name }
    'Display name' = { param($r) $r.displayName }
    'ID' = { param($r) $r.id }
}) -Limit $Top)

## Resource organization

$(New-MetricList ([ordered]@{
    'Subscriptions in scope' = $effectiveSubscriptionIds.Count
    'Resource groups collected' = $resourceGroups.Count
    'Resources collected' = $resources.Count
}))

See [Subscription Inventory Appendix](90-subscription-appendix.md) and [Resource Inventory Appendix](91-resource-appendix.md).
"@
Write-DocumentationPage '03-tenant-and-platform' 'Tenant and Platform Organization' $tenantBody

$governanceBody = @"
## Policy compliance

$(New-MarkdownTable $policySummary ([ordered]@{
    'Compliance state' = { param($r) $r.State }
    'Records' = { param($r) $r.Count }
}))

## Tagging

$(New-MetricList ([ordered]@{
    'Resources evaluated' = $tagCoverage.Count
    'Resources without tags' = $untagged.Count
    'Tag coverage percentage' = if ($tagCoverage.Count) { '{0:N1}%' -f (100 * ($tagCoverage.Count - $untagged.Count) / $tagCoverage.Count) } else { 'Not available' }
}))

## Top resource types

$(New-MarkdownTable $resourceTypes ([ordered]@{
    'Resource type' = { param($r) $r.Type }
    'Count' = { param($r) $r.Count }
}) -Limit $Top)

Policy state, tag requirements, exemption justification, and lock requirements must be compared with the approved organizational standard.
"@
Write-DocumentationPage '04-governance' 'Governance and Policy' $governanceBody

$identityBody = @"
## Identity summary

$(New-MetricList ([ordered]@{
    'Azure RBAC assignments' = $rbacAssignments.Count
    'Direct user RBAC assignments' = $directUserRbac.Count
    'Managed identity records' = $managedIdentities.Count
    'Directory roles' = $directoryRoles.Count
    'Conditional Access policies' = $conditionalAccess.Count
}))

## RBAC principal types

$(New-MarkdownTable $rbacSummary ([ordered]@{
    'Principal type' = { param($r) $r.PrincipalType }
    'Assignments' = { param($r) $r.Count }
}))

Review direct user assignments, privileged scopes, custom roles, group-based access, PIM coverage, and credential expiration with the identity team.

See [RBAC Assignments Appendix](93-rbac-appendix.md).
"@
Write-DocumentationPage '05-identity' 'Identity and Access' $identityBody

$networkBody = @"
## Network inventory

$(New-MetricList ([ordered]@{
    'Network resources' = $networkResources.Count
    'VNet/subnet records' = $vnets.Count
    'Custom NSG rules' = $networkSecurityRules.Count
    'Custom routes' = $networkRoutes.Count
    'VNet peerings' = $vnetPeerings.Count
    'VPN/ER gateways' = $networkGateways.Count
    'VPN/ER connections' = $networkConnections.Count
    'ExpressRoute circuits' = $expressRouteCircuits.Count
    'Public IP addresses' = $publicIps.Count
    'Private Endpoints' = $privateEndpoints.Count
    'Network best-practice review candidates' = $networkFindings.Count
}))

## Best-practice review candidates

$(New-MarkdownTable $networkFindings ([ordered]@{
    'Check' = { param($r) $r.CheckId }
    'Priority' = { param($r) $r.SuggestedPriority }
    'Category' = { param($r) $r.Category }
    'Finding' = { param($r) $r.Finding }
    'Resource' = { param($r) $r.ResourceName }
    'Detail' = { param($r) $r.Detail }
    'Recommendation' = { param($r) $r.Recommendation }
}) -Limit $Top -EmptyMessage 'No automated network review candidates were identified from the collected configuration.')

See [Network Best-Practice Findings Appendix](96-network-findings-appendix.md) for the complete finding register.

## Network Security Group rules

$(New-MarkdownTable $networkSecurityRules ([ordered]@{
    'NSG' = { param($r) $r.NsgName }
    'Rule' = { param($r) $r.RuleName }
    'Priority' = { param($r) $r.Priority }
    'Direction' = { param($r) $r.Direction }
    'Access' = { param($r) $r.Access }
    'Sources' = { param($r) $r.SourceAddresses }
    'Destinations' = { param($r) $r.Destinations }
    'Ports' = { param($r) $r.DestinationPorts }
}) -Limit $Top)

## Route tables and UDRs

$(New-MarkdownTable $networkRoutes ([ordered]@{
    'Route table' = { param($r) $r.RouteTableName }
    'Route' = { param($r) $r.RouteName }
    'Prefix' = { param($r) $r.AddressPrefix }
    'Next hop' = { param($r) $r.NextHopType }
    'Next-hop IP' = { param($r) $r.NextHopIpAddress }
    'BGP propagation disabled' = { param($r) $r.DisableBgpRoutePropagation }
}) -Limit $Top)

## VPN and ExpressRoute gateways

$(New-MarkdownTable $networkGateways ([ordered]@{
    'Gateway' = { param($r) $r.Name }
    'Region' = { param($r) $r.Location }
    'Type' = { param($r) $r.GatewayType }
    'VPN type' = { param($r) $r.VpnType }
    'SKU' = { param($r) $r.Sku }
    'Active-active' = { param($r) $r.ActiveActive }
    'BGP enabled' = { param($r) $r.EnableBgp }
    'Generation' = { param($r) $r.Generation }
}) -Limit $Top)

## Hybrid connections

$(New-MarkdownTable $networkConnections ([ordered]@{
    'Connection' = { param($r) $r.Name }
    'Region' = { param($r) $r.Location }
    'Type' = { param($r) $r.ConnectionType }
    'Status' = { param($r) $r.ConnectionStatus }
    'BGP enabled' = { param($r) $r.EnableBgp }
}) -Limit $Top)

## ExpressRoute circuits

$(New-MarkdownTable $expressRouteCircuits ([ordered]@{
    'Circuit' = { param($r) $r.Name }
    'Region' = { param($r) $r.Location }
    'Tier' = { param($r) $r.Tier }
    'Bandwidth Mbps' = { param($r) $r.BandwidthMbps }
    'Circuit state' = { param($r) $r.CircuitState }
    'Provider state' = { param($r) $r.ProviderState }
}) -Limit $Top)

## Public IP addresses

$(New-MarkdownTable $publicIps ([ordered]@{
    'Name' = { param($r) $r.name }
    'Subscription ID' = { param($r) $r.subscriptionId }
    'Resource group' = { param($r) $r.resourceGroup }
    'Region' = { param($r) $r.location }
    'IP address' = { param($r) $r.ipAddress }
    'Allocation' = { param($r) $r.allocationMethod }
}) -Limit $Top)

## Regional distribution

$(New-MarkdownTable $regions ([ordered]@{
    'Region' = { param($r) $r.Region }
    'Resources' = { param($r) $r.Count }
}) -Limit $Top)

Configuration evidence supports current-state topology modeling. Runtime traffic flows and application dependencies require flow logs, distributed tracing, and stakeholder validation.

The automated checks cover broad inbound NSG rules, exposed management ports, subnet NSG associations, direct-Internet default UDRs, incomplete virtual-appliance routes, VPN gateway availability/SKU indicators, disconnected hybrid connections, ExpressRoute provisioning and circuit-count indicators, VNet peering state, and flow-log availability. Effective routes, effective NIC-level security rules, observed traffic, provider diversity, and tested failover still require runtime validation.
"@
Write-DocumentationPage '06-network' 'Network Architecture' $networkBody

$securityBody = @"
## Security summary

$(New-MetricList ([ordered]@{
    'Defender assessment records' = $defenderAssessments.Count
    'Unhealthy Defender assessments' = $unhealthyDefender.Count
    'Resources reporting public network access' = $publicNetwork.Count
    'Key Vaults' = $keyVaults.Count
}))

## Defender states

$(New-MarkdownTable $defenderSummary ([ordered]@{
    'Status' = { param($r) $r.Status }
    'Severity' = { param($r) $r.Severity }
    'Count' = { param($r) $r.Count }
}))

Prioritize unhealthy recommendations by Defender severity, resource exposure, workload criticality, and remediation applicability.

See [Defender Assessments Appendix](92-defender-appendix.md).
"@
Write-DocumentationPage '07-security' 'Security Posture' $securityBody

$operationsBody = @"
## Operations summary

$(New-MetricList ([ordered]@{
    'Monitoring and operations resources' = $operationsResources.Count
    'Resources queried successfully for diagnostic settings' = $resourceDiagnostics.Count
    'Resources with unsupported diagnostic-settings types' = $unsupportedDiagnostics.Count
}))

## Unsupported diagnostic-settings resource types

$(New-MarkdownTable $unsupportedTypeSummary ([ordered]@{
    'Resource type' = { param($r) $r.ResourceType }
    'Resources' = { param($r) $r.Resources }
}) -Limit $Top)

Unsupported types are informational and are not monitoring failures. For supported resources, validate enabled categories, approved destinations, retention, alert ownership, and tested escalation paths.
"@
Write-DocumentationPage '08-operations' 'Operations and Monitoring' $operationsBody

$resilienceBody = @"
## Resilience evidence

$(New-MetricList ([ordered]@{
    'Backup and Site Recovery resources' = $backupResources.Count
    'Advisor reliability recommendations' = $advisorReliability.Count
    'Resource Health records' = $resourceHealth.Count
}))

## Advisor reliability recommendations

$(New-MarkdownTable $advisorReliability ([ordered]@{
    'Subscription ID' = { param($r) $r.subscriptionId }
    'Impact' = { param($r) $r.impact }
    'Recommendation' = {
        param($r)
        if ($r.shortDescription -and $r.shortDescription.PSObject.Properties['problem']) {
            $r.shortDescription.problem
        }
    }
    'Resource ID' = { param($r) $r.resourceId }
}) -Limit $Top)

Backup configuration does not prove recoverability. Validate approved RTO/RPO, restoration tests, failover/failback runbooks, dependency startup order, and actual exercise results.
"@
Write-DocumentationPage '09-resilience' 'Resilience and Recovery' $resilienceBody

$costBody = @"
## Cost evidence

$(New-MetricList ([ordered]@{
    'Advisor cost recommendations' = $advisorCost.Count
    'Potential orphan resources' = $orphanCandidates.Count
}))

## Potential orphan resources

$(New-MarkdownTable $orphanCandidates ([ordered]@{
    'Name' = { param($r) $r.name }
    'Type' = { param($r) $r.type }
    'Subscription ID' = { param($r) $r.subscriptionId }
    'Resource group' = { param($r) $r.resourceGroup }
    'Region' = { param($r) $r.location }
    'Resource ID' = { param($r) $r.id }
}) -Limit $Top)

Orphan candidates require ownership and dependency validation before deletion. Review budgets, reservations, savings plans, utilization, and nonproduction shutdown schedules with FinOps and workload owners.
"@
Write-DocumentationPage '10-cost' 'Cost Optimization' $costBody

$workloadPath = Join-Path $evidenceRoot '09-workloads'
$workloadBody = if (Test-Path -LiteralPath $workloadPath) {
@"
## Workload evidence

Workload evidence exists under `09-workloads`. Validate each workload's business purpose, owner, criticality, dependencies, RTO/RPO, data classification, and external services before completing WAF and WARA conclusions.
"@
}
else {
@"
## Current status

Workload-specific evidence has not been collected. The current documentation covers the tenant and platform baseline only.

## Required follow-up

1. Identify approximately three to five representative or critical workloads.
2. Confirm business owner, technical owner, service criticality, RTO, and RPO.
3. Map subscription and resource-group scope.
4. Document application, SaaS, and on-premises dependencies.
5. Run collector stages 9 and 10.
6. Regenerate the report and documentation.
"@
}
Write-DocumentationPage '11-workloads' 'Workload Assessment Status' $workloadBody

$observationsBody = @"
## Automated review candidates

$(New-MarkdownTable $observations ([ordered]@{
    'ID' = { param($r) $r.ID }
    'Area' = { param($r) $r.Area }
    'Suggested priority' = { param($r) $r.SuggestedPriority }
    'Observation' = { param($r) $r.Observation }
    'Count' = { param($r) $r.Count }
    'Evidence' = { param($r) $r.Evidence }
    'Assessment action' = { param($r) $r.AssessmentAction }
}))

## Required validation

For every candidate, document the affected scope, expected target state, business and technical impact, final severity, recommendation, owner, target date, and validation method.

## Suggested roadmap

1. **P0 Immediate risk:** exposed resources, critical identity risk, severe recovery gaps, and unmonitored high-risk services.
2. **P1 Landing Zone foundation:** management groups, Policy, networking, RBAC, centralized monitoring, and security controls.
3. **P2 Workload remediation:** reliability, backup, disaster recovery, scaling, and architecture changes.
4. **P3 Optimization:** cost, automation, Infrastructure as Code, and operational maturity.
"@
Write-DocumentationPage '12-observations-and-next-steps' 'Observations and Next Steps' $observationsBody

$subscriptionRows = foreach ($subscription in $effectiveSubscriptions) {
    [pscustomobject]@{
        Name = $subscription.name
        Id = $subscription.id
        State = $subscription.state
        TenantId = $subscription.tenantId
        Resources = @($resources | Where-Object subscriptionId -eq $subscription.id).Count
        ResourceGroups = @($resourceGroups | Where-Object subscriptionId -eq $subscription.id).Count
    }
}
Write-DocumentationPage '90-subscription-appendix' 'Appendix: Subscription Inventory' @"
$(New-MarkdownTable $subscriptionRows ([ordered]@{
    'Subscription' = { param($r) $r.Name }
    'Subscription ID' = { param($r) $r.Id }
    'State' = { param($r) $r.State }
    'Tenant ID' = { param($r) $r.TenantId }
    'Resources' = { param($r) $r.Resources }
    'Resource groups' = { param($r) $r.ResourceGroups }
}))
"@

Write-DocumentationPage '91-resource-appendix' 'Appendix: Resource Inventory' @"
$(New-MarkdownTable $resources ([ordered]@{
    'Subscription ID' = { param($r) $r.subscriptionId }
    'Resource group' = { param($r) $r.resourceGroup }
    'Name' = { param($r) $r.name }
    'Type' = { param($r) $r.type }
    'Region' = { param($r) $r.location }
    'State' = { param($r) $r.provisioningState }
    'Resource ID' = { param($r) $r.id }
}))
"@

Write-DocumentationPage '92-defender-appendix' 'Appendix: Defender Assessments' @"
$(New-MarkdownTable $defenderAssessments ([ordered]@{
    'Subscription ID' = { param($r) $r.subscriptionId }
    'Status' = { param($r) $r.status }
    'Severity' = { param($r) $r.severity }
    'Assessment' = { param($r) $r.displayName }
    'Resource ID' = { param($r) $r.resourceId }
}))
"@

Write-DocumentationPage '93-rbac-appendix' 'Appendix: RBAC Assignments' @"
$(New-MarkdownTable $rbacAssignments ([ordered]@{
    'Subscription ID' = { param($r) $r.subscriptionId }
    'Principal ID' = { param($r) $r.principalId }
    'Principal type' = { param($r) $r.principalType }
    'Role definition ID' = { param($r) $r.roleDefinitionId }
    'Scope' = { param($r) $r.scope }
    'Condition' = { param($r) $r.condition }
}))
"@

Write-DocumentationPage '94-collection-errors-appendix' 'Appendix: Collection Errors' @"
$(New-MarkdownTable $collectionErrors ([ordered]@{
    'Timestamp UTC' = { param($r) $r.TimestampUtc }
    'Stage' = { param($r) $r.Stage }
    'Item' = { param($r) $r.Item }
    'Required' = { param($r) $r.Required }
    'Error' = { param($r) $r.Error }
}))
"@

Write-DocumentationPage '95-evidence-index-appendix' 'Appendix: Evidence Index' @"
$(New-MarkdownTable $evidenceIndex ([ordered]@{
    'Stage' = { param($r) $r.Stage }
    'Relative path' = { param($r) $r.RelativePath }
    'Size bytes' = { param($r) $r.SizeBytes }
    'Last write UTC' = { param($r) $r.LastWriteUtc }
    'SHA-256' = { param($r) $r.Sha256 }
}))
"@

Write-DocumentationPage '96-network-findings-appendix' 'Appendix: Network Best-Practice Findings' @"
> These are configuration-based review candidates. Confirm intent, effective routes and rules, observed traffic, exceptions, compensating controls, business impact, and tested failover before assigning final severity.

$(New-MarkdownTable $networkFindings ([ordered]@{
    'Check' = { param($r) $r.CheckId }
    'Suggested priority' = { param($r) $r.SuggestedPriority }
    'Category' = { param($r) $r.Category }
    'Finding' = { param($r) $r.Finding }
    'Resource' = { param($r) $r.ResourceName }
    'Detail' = { param($r) $r.Detail }
    'Recommendation' = { param($r) $r.Recommendation }
    'Evidence' = { param($r) $r.Evidence }
    'Status' = { param($r) $r.Status }
}))
"@

$metadata = [ordered]@{
    GeneratedUtc = $generatedUtc
    EvidencePath = $evidenceRoot
    DocumentationPath = $documentationRoot
    MarkdownPath = $markdownRoot
    HtmlPath = $htmlRoot
    Pages = $pages.Count
    Subscriptions = $effectiveSubscriptionIds.Count
    Resources = $resources.Count
    ReviewCandidates = $observations.Count
    NetworkReviewCandidates = $networkFindings.Count
    EntryPoint = Join-Path $htmlRoot 'index.html'
}
ConvertTo-Json -InputObject $metadata -Depth 10 |
    Set-Content -LiteralPath (Join-Path $documentationRoot 'documentation-metadata.json') -Encoding utf8

Write-Host "Documentation generated: $(Join-Path $htmlRoot 'index.html')" -ForegroundColor Green
Write-Host "Markdown source: $markdownRoot"
