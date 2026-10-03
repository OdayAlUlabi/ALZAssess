#requires -Version 7.3

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EvidencePath,
    [string]$ReportPath,
    [ValidateRange(5, 100)][int]$Top = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$evidenceRoot = [System.IO.Path]::GetFullPath($EvidencePath)
if (-not (Test-Path -LiteralPath $evidenceRoot -PathType Container)) {
    throw "Evidence directory not found: $evidenceRoot"
}

if (-not $ReportPath) {
    $ReportPath = Join-Path $evidenceRoot 'reports'
}
$reportRoot = [System.IO.Path]::GetFullPath($ReportPath)
$csvRoot = Join-Path $reportRoot 'csv'
New-Item -ItemType Directory -Path $csvRoot -Force | Out-Null

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

    try {
        $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100
        foreach ($item in @($data)) {
            Write-Output $item
        }
    }
    catch {
        throw "Unable to read evidence file '$path': $($_.Exception.Message)"
    }
}

function ConvertTo-CompactJson {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return ''
    }
    return ConvertTo-Json -InputObject $Value -Depth 20 -Compress
}

function ConvertTo-HtmlEncoded {
    param([AllowNull()]$Value)

    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function ConvertTo-HtmlTable {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][string[]]$Properties,
        [string]$EmptyMessage = 'No records were collected.'
    )

    if ($Rows.Count -eq 0) {
        return "<p class=`"empty`">$(ConvertTo-HtmlEncoded $EmptyMessage)</p>"
    }

    $header = ($Properties | ForEach-Object { "<th>$(ConvertTo-HtmlEncoded $_)</th>" }) -join ''
    $body = foreach ($row in $Rows) {
        $cells = foreach ($property in $Properties) {
            $value = $row.PSObject.Properties[$property].Value
            "<td>$(ConvertTo-HtmlEncoded $value)</td>"
        }
        "<tr>$($cells -join '')</tr>"
    }

    return "<div class=`"table-wrap`"><table><thead><tr>$header</tr></thead><tbody>$($body -join '')</tbody></table></div>"
}

function Add-Observation {
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][ValidateSet('High', 'Medium', 'Low', 'Info')][string]$SuggestedPriority,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)][string]$Evidence,
        [Parameter(Mandatory)][string]$AssessmentAction
    )

    $script:observationSequence++
    $script:observations.Add([pscustomobject]@{
        ID                = 'OBS-{0:D3}' -f $script:observationSequence
        Area              = $Area
        SuggestedPriority = $SuggestedPriority
        Observation       = $Title
        Count             = $Count
        Evidence          = $Evidence
        AssessmentAction  = $AssessmentAction
        Status            = 'ReviewRequired'
    })
}

$scope = @(Get-JsonItems -RelativePath '00-prerequisites\collection-scope.json' -Optional) | Select-Object -First 1
$subscriptions = @(Get-JsonItems -RelativePath '01-tenant-hierarchy\subscriptions.json' -Optional)
$resourceGroups = @(
    Get-ChildItem -LiteralPath (Join-Path $evidenceRoot '01-tenant-hierarchy') -Filter 'resource-groups-*.json' -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 100
        }
)
$resources = @(Get-JsonItems -RelativePath '02-resource-governance\resources.json' -Optional)
$tagCoverage = @(Get-JsonItems -RelativePath '02-resource-governance\tag-coverage.json' -Optional)
$policyCompliance = @(Get-JsonItems -RelativePath '02-resource-governance\policy-compliance-summary.json' -Optional)
$rbacAssignments = @(Get-JsonItems -RelativePath '03-identity\rbac-role-assignments.json' -Optional)
$publicIps = @(Get-JsonItems -RelativePath '04-network\public-ip-addresses.json' -Optional)
$privateEndpoints = @(Get-JsonItems -RelativePath '04-network\private-endpoints.json' -Optional)
$defenderAssessments = @(Get-JsonItems -RelativePath '05-security\defender-assessments.json' -Optional)
$keyVaults = @(Get-JsonItems -RelativePath '05-security\key-vaults.json' -Optional)
$operationsResources = @(Get-JsonItems -RelativePath '06-operations\operations-resources.json' -Optional)
$unsupportedDiagnostics = @(Get-JsonItems -RelativePath '06-operations\resource-diagnostic-settings-unsupported.json' -Optional)
$backupResources = @(Get-JsonItems -RelativePath '07-resilience\backup-site-recovery.json' -Optional)
$advisorReliability = @(Get-JsonItems -RelativePath '07-resilience\advisor-reliability.json' -Optional)
$advisorCost = @(Get-JsonItems -RelativePath '08-cost-optimization\advisor-cost.json' -Optional)
$orphanCandidates = @(Get-JsonItems -RelativePath '08-cost-optimization\potential-orphan-resources.json' -Optional)

$errorPath = Join-Path $evidenceRoot '_collection-errors.csv'
$collectionErrors = if (Test-Path -LiteralPath $errorPath) { @(Import-Csv -LiteralPath $errorPath) } else { @() }
$diagnosticsPath = Join-Path $evidenceRoot '06-operations\resource-diagnostic-settings.json'

$effectiveSubscriptions = if ($scope -and $scope.Subscriptions) {
    @($scope.Subscriptions)
}
else {
    @($resources.subscriptionId | Where-Object { $_ } | Sort-Object -Unique)
}

$resourceExport = foreach ($resource in $resources) {
    [pscustomobject]@{
        SubscriptionId   = $resource.subscriptionId
        ResourceGroup    = $resource.resourceGroup
        Name             = $resource.name
        Type             = $resource.type
        Location         = $resource.location
        Kind             = $resource.kind
        ProvisioningState = $resource.provisioningState
        IdentityType     = $resource.identityType
        Zones            = (@($resource.zones) -join ';')
        Sku              = ConvertTo-CompactJson $resource.sku
        Tags             = ConvertTo-CompactJson $resource.tags
        ResourceId       = $resource.id
    }
}
$resourceExport | Export-Csv -LiteralPath (Join-Path $csvRoot 'resource-inventory.csv') -NoTypeInformation -Encoding utf8

$subscriptionExport = foreach ($subscriptionId in $effectiveSubscriptions) {
    $subscription = $subscriptions | Where-Object { $_.id -eq $subscriptionId } | Select-Object -First 1
    [pscustomobject]@{
        SubscriptionId = $subscriptionId
        Name           = $subscription.name
        State          = $subscription.state
        TenantId       = $subscription.tenantId
        ResourceCount  = @($resources | Where-Object { $_.subscriptionId -eq $subscriptionId }).Count
        ResourceGroups = @($resourceGroups | Where-Object { $_.id -like "/subscriptions/$subscriptionId/*" }).Count
    }
}
$subscriptionExport | Export-Csv -LiteralPath (Join-Path $csvRoot 'subscription-summary.csv') -NoTypeInformation -Encoding utf8

$errorSummary = @(
    $collectionErrors |
        Group-Object Stage, Item |
        ForEach-Object {
            [pscustomobject]@{
                Stage = $_.Group[0].Stage
                Item  = $_.Group[0].Item
                Count = $_.Count
            }
        } |
        Sort-Object @{ Expression = 'Count'; Descending = $true }, Stage, Item
)
$errorSummary | Export-Csv -LiteralPath (Join-Path $csvRoot 'collection-error-summary.csv') -NoTypeInformation -Encoding utf8

$policyExport = foreach ($item in $policyCompliance) {
    [pscustomobject]@{
        SubscriptionId = $item.subscriptionId
        ComplianceState = $item.complianceState
        Count            = $item.Count
    }
}
$policyExport | Export-Csv -LiteralPath (Join-Path $csvRoot 'policy-compliance-summary.csv') -NoTypeInformation -Encoding utf8

$defenderExport = foreach ($item in $defenderAssessments) {
    [pscustomobject]@{
        SubscriptionId = $item.subscriptionId
        ResourceId     = $item.resourceId
        DisplayName    = $item.displayName
        Status         = $item.status
        Severity       = $item.severity
        AssessmentId   = $item.id
    }
}
$defenderExport | Export-Csv -LiteralPath (Join-Path $csvRoot 'defender-assessments.csv') -NoTypeInformation -Encoding utf8

$publicIpExport = foreach ($item in $publicIps) {
    [pscustomobject]@{
        SubscriptionId  = $item.subscriptionId
        ResourceGroup   = $item.resourceGroup
        Name            = $item.name
        Location        = $item.location
        IpAddress       = $item.ipAddress
        AllocationMethod = $item.allocationMethod
        ResourceId      = $item.id
    }
}
$publicIpExport | Export-Csv -LiteralPath (Join-Path $csvRoot 'public-ip-addresses.csv') -NoTypeInformation -Encoding utf8

$unsupportedDiagnostics |
    Select-Object resourceId, type, reason |
    Export-Csv -LiteralPath (Join-Path $csvRoot 'diagnostic-settings-unsupported-resources.csv') -NoTypeInformation -Encoding utf8

$advisorCost | Select-Object subscriptionId, resourceId, impact, shortDescription, recommendationTypeId |
    Export-Csv -LiteralPath (Join-Path $csvRoot 'advisor-cost-recommendations.csv') -NoTypeInformation -Encoding utf8

$observationSequence = 0
$observations = [System.Collections.Generic.List[object]]::new()

if ($collectionErrors.Count -gt 0) {
    Add-Observation -Area 'Evidence coverage' -SuggestedPriority 'High' `
        -Title 'Collection errors require review before drawing conclusions' -Count $collectionErrors.Count `
        -Evidence '_collection-errors.csv' `
        -AssessmentAction 'Resolve permission and API failures, or record each accepted evidence limitation in the final report.'
}

if (-not (Test-Path -LiteralPath $diagnosticsPath)) {
    Add-Observation -Area 'Operations' -SuggestedPriority 'High' `
        -Title 'Per-resource diagnostic settings evidence is unavailable' -Count $resources.Count `
        -Evidence '06-operations\resource-diagnostic-settings.json' `
        -AssessmentAction 'Rerun stage 6 for approved critical scopes or explicitly document that resource-level telemetry routing was not validated.'
}

$untaggedResources = @($tagCoverage | Where-Object { [int]$_.tagCount -eq 0 })
if ($untaggedResources.Count -gt 0) {
    Add-Observation -Area 'Governance' -SuggestedPriority 'Medium' `
        -Title 'Resources have no tags' -Count $untaggedResources.Count `
        -Evidence '02-resource-governance\tag-coverage.json' `
        -AssessmentAction 'Validate the required tag standard, exemptions, ownership, and enforcement policy before confirming a finding.'
}

$nonCompliantPolicyCount = ($policyCompliance |
    Where-Object { $_.complianceState -eq 'NonCompliant' } |
    Measure-Object -Property Count -Sum).Sum
if ($nonCompliantPolicyCount -gt 0) {
    Add-Observation -Area 'Governance' -SuggestedPriority 'Medium' `
        -Title 'Azure Policy reports noncompliant records' -Count ([int]$nonCompliantPolicyCount) `
        -Evidence '02-resource-governance\policy-compliance-summary.json' `
        -AssessmentAction 'Review the underlying policy states, affected resources, exemptions, and remediation ownership.'
}

$unhealthyDefender = @($defenderAssessments | Where-Object { $_.status -eq 'Unhealthy' })
if ($unhealthyDefender.Count -gt 0) {
    Add-Observation -Area 'Security' -SuggestedPriority 'High' `
        -Title 'Defender for Cloud assessments are unhealthy' -Count $unhealthyDefender.Count `
        -Evidence '05-security\defender-assessments.json' `
        -AssessmentAction 'Prioritize by Defender severity and business criticality, then validate applicability and remediation state.'
}

if ($publicIps.Count -gt 0) {
    Add-Observation -Area 'Network' -SuggestedPriority 'High' `
        -Title 'Public IP addresses require exposure review' -Count $publicIps.Count `
        -Evidence '04-network\public-ip-addresses.json' `
        -AssessmentAction 'Confirm association, ingress controls, business justification, DDoS protection, and whether private access is feasible.'
}

$directUserAssignments = @($rbacAssignments | Where-Object { $_.principalType -eq 'User' })
if ($directUserAssignments.Count -gt 0) {
    Add-Observation -Area 'Identity' -SuggestedPriority 'High' `
        -Title 'Direct user RBAC assignments require least-privilege review' -Count $directUserAssignments.Count `
        -Evidence '03-identity\rbac-role-assignments.json' `
        -AssessmentAction 'Validate business need, role privilege, scope, PIM use, and whether group-based assignment should replace direct access.'
}

$publicKeyVaults = @($keyVaults | Where-Object { $_.publicNetworkAccess -eq 'Enabled' })
if ($publicKeyVaults.Count -gt 0) {
    Add-Observation -Area 'Security' -SuggestedPriority 'High' `
        -Title 'Key Vault public network access is enabled' -Count $publicKeyVaults.Count `
        -Evidence '05-security\key-vaults.json' `
        -AssessmentAction 'Validate firewall rules, private endpoint feasibility, trusted-service requirements, and approved exposure.'
}

if ($advisorReliability.Count -gt 0) {
    Add-Observation -Area 'Reliability' -SuggestedPriority 'Medium' `
        -Title 'Azure Advisor reliability recommendations require review' -Count $advisorReliability.Count `
        -Evidence '07-resilience\advisor-reliability.json' `
        -AssessmentAction 'Validate recommendation applicability against workload criticality, architecture, RTO, and RPO.'
}

if ($orphanCandidates.Count -gt 0) {
    Add-Observation -Area 'Cost' -SuggestedPriority 'Medium' `
        -Title 'Potential orphan resources require ownership validation' -Count $orphanCandidates.Count `
        -Evidence '08-cost-optimization\potential-orphan-resources.json' `
        -AssessmentAction 'Confirm ownership, retention need, dependencies, and deletion safety before remediation.'
}

if (-not (Test-Path -LiteralPath (Join-Path $evidenceRoot '09-workloads'))) {
    Add-Observation -Area 'Workloads' -SuggestedPriority 'Info' `
        -Title 'Workload-specific WAF and WARA evidence has not been collected' -Count 1 `
        -Evidence '09-workloads' `
        -AssessmentAction 'Identify representative critical workloads, define their resource groups, and run stages 9 and 10.'
}

$observations | Export-Csv -LiteralPath (Join-Path $csvRoot 'assessment-observations.csv') -NoTypeInformation -Encoding utf8

$stageRows = for ($stage = 0; $stage -le 10; $stage++) {
    $marker = Join-Path $evidenceRoot ('_stage-{0:D2}.complete.json' -f $stage)
    [pscustomobject]@{
        Stage  = $stage
        Status = if (Test-Path -LiteralPath $marker) { 'Completed' } else { 'Not completed' }
    }
}

$resourceTypeRows = @(
    $resources |
        Group-Object type |
        Sort-Object Count -Descending |
        Select-Object -First $Top |
        ForEach-Object { [pscustomobject]@{ ResourceType = $_.Name; Count = $_.Count } }
)
$regionRows = @(
    $resources |
        Group-Object location |
        Sort-Object Count -Descending |
        Select-Object -First $Top |
        ForEach-Object { [pscustomobject]@{ Region = $_.Name; Count = $_.Count } }
)
$defenderRows = @(
    $defenderAssessments |
        Group-Object status, severity |
        Sort-Object Count -Descending |
        ForEach-Object {
            [pscustomobject]@{
                Status   = $_.Group[0].status
                Severity = $_.Group[0].severity
                Count    = $_.Count
            }
        }
)
$policyRows = @(
    $policyCompliance |
        Group-Object complianceState |
        ForEach-Object {
            [pscustomobject]@{
                ComplianceState = $_.Name
                Count = ($_.Group | Measure-Object -Property Count -Sum).Sum
            }
        } |
        Sort-Object Count -Descending
)

$generatedUtc = (Get-Date).ToUniversalTime().ToString('u')
$title = 'Azure Landing Zone Assessment Evidence Report'
$html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<style>
:root { --navy:#0f2942; --blue:#0078d4; --light:#f4f7fa; --line:#d7e0e8; --text:#1f2937; --high:#b42318; --medium:#b54708; --low:#175cd3; }
* { box-sizing:border-box; }
body { margin:0; color:var(--text); background:var(--light); font-family:"Segoe UI",Arial,sans-serif; }
header { background:linear-gradient(120deg,var(--navy),var(--blue)); color:white; padding:32px max(24px,5vw); }
header h1 { margin:0 0 8px; font-size:30px; }
header p { margin:4px 0; opacity:.92; }
main { max-width:1400px; margin:0 auto; padding:24px; }
.notice { background:#fff4ce; border-left:5px solid #ffb900; padding:14px 18px; margin-bottom:20px; }
.cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(180px,1fr)); gap:14px; margin:20px 0; }
.card { background:white; border:1px solid var(--line); border-radius:8px; padding:18px; box-shadow:0 2px 6px rgba(15,41,66,.06); }
.card .value { font-size:30px; font-weight:700; color:var(--navy); }
.card .label { color:#52606d; margin-top:4px; }
section { background:white; border:1px solid var(--line); border-radius:8px; padding:20px; margin:18px 0; }
h2 { margin-top:0; color:var(--navy); }
h3 { color:var(--navy); margin-top:24px; }
.table-wrap { overflow:auto; }
table { border-collapse:collapse; width:100%; font-size:13px; }
th,td { border-bottom:1px solid var(--line); padding:9px 10px; text-align:left; vertical-align:top; }
th { background:#edf4fa; color:var(--navy); position:sticky; top:0; }
tr:hover td { background:#f8fbfd; }
.empty { color:#667085; font-style:italic; }
.files li { margin:6px 0; }
code { background:#eef2f6; padding:2px 5px; border-radius:3px; }
footer { color:#667085; text-align:center; padding:20px; }
</style>
</head>
<body>
<header>
  <h1>$title</h1>
  <p>Evidence root: $(ConvertTo-HtmlEncoded $evidenceRoot)</p>
  <p>Generated UTC: $generatedUtc</p>
</header>
<main>
  <div class="notice"><strong>Assessment note:</strong> Automated observations are review candidates, not confirmed findings. Validate scope, permissions, business context, applicability, ownership, and compensating controls before assigning final severity.</div>
  <div class="cards">
    <div class="card"><div class="value">$($effectiveSubscriptions.Count)</div><div class="label">Subscriptions in scope</div></div>
    <div class="card"><div class="value">$($resources.Count)</div><div class="label">Resources collected</div></div>
    <div class="card"><div class="value">$($resourceGroups.Count)</div><div class="label">Resource groups collected</div></div>
    <div class="card"><div class="value">$($collectionErrors.Count)</div><div class="label">Collection errors</div></div>
    <div class="card"><div class="value">$($unhealthyDefender.Count)</div><div class="label">Unhealthy Defender records</div></div>
    <div class="card"><div class="value">$($observations.Count)</div><div class="label">Review candidates</div></div>
  </div>

  <section>
    <h2>Executive review candidates</h2>
    $(ConvertTo-HtmlTable -Rows $observations.ToArray() -Properties @('ID','Area','SuggestedPriority','Observation','Count','Evidence','AssessmentAction','Status'))
  </section>

  <section>
    <h2>Collection coverage</h2>
    <h3>Stage status</h3>
    $(ConvertTo-HtmlTable -Rows $stageRows -Properties @('Stage','Status'))
    <h3>Collection errors</h3>
    $(ConvertTo-HtmlTable -Rows ($errorSummary | Select-Object -First $Top) -Properties @('Stage','Item','Count') -EmptyMessage 'No collection errors were recorded.')
  </section>

  <section>
    <h2>Estate overview</h2>
    <h3>Subscriptions</h3>
    $(ConvertTo-HtmlTable -Rows $subscriptionExport -Properties @('Name','SubscriptionId','State','ResourceCount','ResourceGroups'))
    <h3>Top resource types</h3>
    $(ConvertTo-HtmlTable -Rows $resourceTypeRows -Properties @('ResourceType','Count'))
    <h3>Top regions</h3>
    $(ConvertTo-HtmlTable -Rows $regionRows -Properties @('Region','Count'))
  </section>

  <section>
    <h2>Governance and security posture</h2>
    <h3>Policy compliance states</h3>
    $(ConvertTo-HtmlTable -Rows $policyRows -Properties @('ComplianceState','Count'))
    <h3>Defender assessment states</h3>
    $(ConvertTo-HtmlTable -Rows $defenderRows -Properties @('Status','Severity','Count'))
  </section>

  <section>
    <h2>Architecture indicators</h2>
    <div class="cards">
      <div class="card"><div class="value">$($publicIps.Count)</div><div class="label">Public IP addresses</div></div>
      <div class="card"><div class="value">$($privateEndpoints.Count)</div><div class="label">Private Endpoints</div></div>
      <div class="card"><div class="value">$($keyVaults.Count)</div><div class="label">Key Vaults</div></div>
      <div class="card"><div class="value">$($operationsResources.Count)</div><div class="label">Operations resources</div></div>
      <div class="card"><div class="value">$($unsupportedDiagnostics.Count)</div><div class="label">Resources without diagnostic-settings support</div></div>
      <div class="card"><div class="value">$($backupResources.Count)</div><div class="label">Backup/ASR resources</div></div>
      <div class="card"><div class="value">$($advisorCost.Count)</div><div class="label">Advisor cost recommendations</div></div>
    </div>
  </section>

  <section>
    <h2>CSV exports</h2>
    <ul class="files">
      <li><code>csv/resource-inventory.csv</code></li>
      <li><code>csv/subscription-summary.csv</code></li>
      <li><code>csv/collection-error-summary.csv</code></li>
      <li><code>csv/assessment-observations.csv</code></li>
      <li><code>csv/policy-compliance-summary.csv</code></li>
      <li><code>csv/defender-assessments.csv</code></li>
      <li><code>csv/public-ip-addresses.csv</code></li>
      <li><code>csv/diagnostic-settings-unsupported-resources.csv</code></li>
      <li><code>csv/advisor-cost-recommendations.csv</code></li>
    </ul>
  </section>
</main>
<footer>Azure Landing Zone Assessment Collector - evidence-based review report</footer>
</body>
</html>
"@

$reportFile = Join-Path $reportRoot 'assessment-report.html'
[System.IO.File]::WriteAllText($reportFile, $html, [System.Text.UTF8Encoding]::new($false))

$reportMetadata = [ordered]@{
    GeneratedUtc        = $generatedUtc
    EvidencePath        = $evidenceRoot
    ReportPath          = $reportRoot
    Subscriptions       = $effectiveSubscriptions.Count
    Resources           = $resources.Count
    CollectionErrors    = $collectionErrors.Count
    ReviewCandidates    = $observations.Count
    HtmlReport          = $reportFile
    CsvDirectory        = $csvRoot
}
ConvertTo-Json -InputObject $reportMetadata -Depth 10 |
    Set-Content -LiteralPath (Join-Path $reportRoot 'report-metadata.json') -Encoding utf8

Write-Host "Report generated: $reportFile" -ForegroundColor Green
Write-Host "CSV exports: $csvRoot"
