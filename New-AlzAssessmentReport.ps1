#requires -Version 7.3

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EvidencePath,
    [string]$ReportPath,
    [string[]]$ExcludeSubscriptionId = @(),
    [ValidateRange(5, 100)][int]$Top = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$evidenceRoot = [System.IO.Path]::GetFullPath($EvidencePath)
if (-not (Test-Path -LiteralPath $evidenceRoot -PathType Container)) {
    throw "Evidence directory not found: $evidenceRoot"
}

. (Join-Path $PSScriptRoot 'Private\Common.ps1')
Assert-NoProhibitedEvidenceData -RootPath $evidenceRoot

if (-not $ReportPath) {
    $ReportPath = Join-Path $evidenceRoot 'reports'
}
$reportRoot = [System.IO.Path]::GetFullPath($ReportPath)
$csvRoot = Join-Path $reportRoot 'csv'
New-Item -ItemType Directory -Path $csvRoot -Force | Out-Null

$excludedSubscriptionIds = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
foreach ($subscriptionId in $ExcludeSubscriptionId) {
    if (-not [string]::IsNullOrWhiteSpace($subscriptionId)) {
        $null = $excludedSubscriptionIds.Add($subscriptionId.Trim())
    }
}

function Test-IsExcludedSubscriptionItem {
    param([AllowNull()]$Item)

    if ($null -eq $Item -or $excludedSubscriptionIds.Count -eq 0) {
        return $false
    }
    foreach ($property in @($Item.PSObject.Properties | Where-Object MemberType -in @('NoteProperty', 'Property'))) {
        if ($property.Value -isnot [string]) {
            continue
        }
        foreach ($subscriptionId in $excludedSubscriptionIds) {
            if ($property.Value.IndexOf($subscriptionId, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return $true
            }
        }
    }
    return $false
}

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
            if (-not (Test-IsExcludedSubscriptionItem $item)) {
                Write-Output $item
            }
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

function Get-PropertyValue {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()]$Default = $null
    )

    if ($null -eq $InputObject) {
        return $Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }
    return $property.Value
}

function Join-NetworkValues {
    param(
        [AllowNull()]$SingleValue,
        [AllowNull()]$MultipleValues
    )

    $values = @($MultipleValues | Where-Object { $_ })
    if ($values.Count -eq 0 -and $SingleValue) {
        $values = @($SingleValue)
    }
    return $values -join ';'
}

function Test-NetworkPortSet {
    param(
        [AllowEmptyString()][string]$PortExpression,
        [Parameter(Mandatory)][int[]]$Ports
    )

    foreach ($entry in @($PortExpression -split ';' | Where-Object { $_ })) {
        if ($entry -eq '*') {
            return $true
        }
        if ($entry -match '^\d+$' -and [int]$entry -in $Ports) {
            return $true
        }
        if ($entry -match '^(\d+)-(\d+)$') {
            $start = [int]$Matches[1]
            $end = [int]$Matches[2]
            if ($Ports | Where-Object { $_ -ge $start -and $_ -le $end }) {
                return $true
            }
        }
    }
    return $false
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

function Add-NetworkFinding {
    param(
        [Parameter(Mandatory)][string]$CheckId,
        [Parameter(Mandatory)][ValidateSet('High', 'Medium', 'Low', 'Info')][string]$SuggestedPriority,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$ResourceName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ResourceId,
        [Parameter(Mandatory)][string]$Detail,
        [Parameter(Mandatory)][string]$Recommendation,
        [Parameter(Mandatory)][string]$Evidence
    )

    $script:networkFindings.Add([pscustomobject]@{
        CheckId          = $CheckId
        SuggestedPriority = $SuggestedPriority
        Category         = $Category
        Finding          = $Title
        ResourceName     = $ResourceName
        ResourceId       = $ResourceId
        Detail           = $Detail
        Recommendation   = $Recommendation
        Evidence         = $Evidence
        Status           = 'ReviewRequired'
    })
}

$scope = @(Get-JsonItems -RelativePath '00-prerequisites\collection-scope.json' -Optional) | Select-Object -First 1
$subscriptions = @(Get-JsonItems -RelativePath '01-tenant-hierarchy\subscriptions.json' -Optional)
$resourceGroups = @(
    Get-ChildItem -LiteralPath (Join-Path $evidenceRoot '01-tenant-hierarchy') -Filter 'resource-groups-*.json' -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 100
        } |
        Where-Object { -not (Test-IsExcludedSubscriptionItem $_) }
)
$resources = @(Get-JsonItems -RelativePath '02-resource-governance\resources.json' -Optional)
$tagCoverage = @(Get-JsonItems -RelativePath '02-resource-governance\tag-coverage.json' -Optional)
$policyCompliance = @(Get-JsonItems -RelativePath '02-resource-governance\policy-compliance-summary.json' -Optional)
$rbacAssignments = @(Get-JsonItems -RelativePath '03-identity\rbac-role-assignments.json' -Optional)
$vnetsSubnets = @(Get-JsonItems -RelativePath '04-network\vnets-subnets.json' -Optional)
$networkTopology = @(Get-JsonItems -RelativePath '04-network\network-topology.json' -Optional)
$collectedNsgRules = @(Get-JsonItems -RelativePath '04-network\network-security-rules.json' -Optional)
$collectedRoutes = @(Get-JsonItems -RelativePath '04-network\route-table-routes.json' -Optional)
$collectedPeerings = @(Get-JsonItems -RelativePath '04-network\vnet-peerings.json' -Optional)
$hybridConnectivity = @(Get-JsonItems -RelativePath '04-network\hybrid-connectivity.json' -Optional)
$networkFlowLogs = @(Get-JsonItems -RelativePath '04-network\network-flow-logs.json' -Optional)
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
$collectionErrors = @(
    if (Test-Path -LiteralPath $errorPath) {
        Import-Csv -LiteralPath $errorPath |
            Where-Object { -not (Test-IsExcludedSubscriptionItem $_) }
    }
)
$diagnosticsPath = Join-Path $evidenceRoot '06-operations\resource-diagnostic-settings.json'

$effectiveSubscriptions = if ($scope -and $scope.Subscriptions) {
    @($scope.Subscriptions | Where-Object { -not $excludedSubscriptionIds.Contains([string]$_) })
}
else {
    @($resources.subscriptionId | Where-Object { $_ } | Sort-Object -Unique)
}

$nsgRuleExport = if ($collectedNsgRules.Count -gt 0) {
    foreach ($rule in $collectedNsgRules) {
        [pscustomobject]@{
            SubscriptionId   = $rule.subscriptionId
            ResourceGroup    = $rule.resourceGroup
            NsgName          = $rule.nsgName
            NsgId            = $rule.nsgId
            RuleName         = $rule.ruleName
            Priority         = $rule.priority
            Direction        = $rule.direction
            Access           = $rule.access
            Protocol         = $rule.protocol
            SourceAddresses  = Join-NetworkValues $rule.sourceAddressPrefix $rule.sourceAddressPrefixes
            SourcePorts      = Join-NetworkValues $rule.sourcePortRange $rule.sourcePortRanges
            Destinations     = Join-NetworkValues $rule.destinationAddressPrefix $rule.destinationAddressPrefixes
            DestinationPorts = Join-NetworkValues $rule.destinationPortRange $rule.destinationPortRanges
            RuleId           = $rule.ruleId
        }
    }
}
else {
    foreach ($nsg in @($networkTopology | Where-Object { $_.type -ieq 'microsoft.network/networksecuritygroups' })) {
        foreach ($rule in @(Get-PropertyValue (Get-PropertyValue $nsg 'properties') 'securityRules' @())) {
            $ruleProperties = Get-PropertyValue $rule 'properties'
            [pscustomobject]@{
                SubscriptionId   = $nsg.subscriptionId
                ResourceGroup    = $nsg.resourceGroup
                NsgName          = $nsg.name
                NsgId            = $nsg.id
                RuleName         = Get-PropertyValue $rule 'name' ''
                Priority         = Get-PropertyValue $ruleProperties 'priority' ''
                Direction        = Get-PropertyValue $ruleProperties 'direction' ''
                Access           = Get-PropertyValue $ruleProperties 'access' ''
                Protocol         = Get-PropertyValue $ruleProperties 'protocol' ''
                SourceAddresses  = Join-NetworkValues (Get-PropertyValue $ruleProperties 'sourceAddressPrefix' '') (Get-PropertyValue $ruleProperties 'sourceAddressPrefixes' @())
                SourcePorts      = Join-NetworkValues (Get-PropertyValue $ruleProperties 'sourcePortRange' '') (Get-PropertyValue $ruleProperties 'sourcePortRanges' @())
                Destinations     = Join-NetworkValues (Get-PropertyValue $ruleProperties 'destinationAddressPrefix' '') (Get-PropertyValue $ruleProperties 'destinationAddressPrefixes' @())
                DestinationPorts = Join-NetworkValues (Get-PropertyValue $ruleProperties 'destinationPortRange' '') (Get-PropertyValue $ruleProperties 'destinationPortRanges' @())
                RuleId           = Get-PropertyValue $rule 'id' ''
            }
        }
    }
}

$routeExport = if ($collectedRoutes.Count -gt 0) {
    foreach ($route in $collectedRoutes) {
        [pscustomobject]@{
            SubscriptionId           = $route.subscriptionId
            ResourceGroup            = $route.resourceGroup
            RouteTableName           = $route.routeTableName
            RouteTableId             = $route.routeTableId
            DisableBgpRoutePropagation = $route.disableBgpRoutePropagation
            RouteName                = $route.routeName
            AddressPrefix            = $route.addressPrefix
            NextHopType              = $route.nextHopType
            NextHopIpAddress         = $route.nextHopIpAddress
            HasBgpOverride           = $route.hasBgpOverride
            RouteId                  = $route.routeId
        }
    }
}
else {
    foreach ($routeTable in @($networkTopology | Where-Object { $_.type -ieq 'microsoft.network/routetables' })) {
        $routeTableProperties = Get-PropertyValue $routeTable 'properties'
        foreach ($route in @(Get-PropertyValue $routeTableProperties 'routes' @())) {
            $routeProperties = Get-PropertyValue $route 'properties'
            [pscustomobject]@{
                SubscriptionId           = $routeTable.subscriptionId
                ResourceGroup            = $routeTable.resourceGroup
                RouteTableName           = $routeTable.name
                RouteTableId             = $routeTable.id
                DisableBgpRoutePropagation = Get-PropertyValue $routeTableProperties 'disableBgpRoutePropagation' ''
                RouteName                = Get-PropertyValue $route 'name' ''
                AddressPrefix            = Get-PropertyValue $routeProperties 'addressPrefix' ''
                NextHopType              = Get-PropertyValue $routeProperties 'nextHopType' ''
                NextHopIpAddress         = Get-PropertyValue $routeProperties 'nextHopIpAddress' ''
                HasBgpOverride           = Get-PropertyValue $routeProperties 'hasBgpOverride' ''
                RouteId                  = Get-PropertyValue $route 'id' ''
            }
        }
    }
}

$peeringExport = if ($collectedPeerings.Count -gt 0) {
    foreach ($peering in $collectedPeerings) {
        [pscustomobject]@{
            SubscriptionId          = $peering.subscriptionId
            ResourceGroup           = $peering.resourceGroup
            VnetName                = $peering.vnetName
            VnetId                  = $peering.vnetId
            PeeringName             = $peering.peeringName
            PeeringState            = $peering.peeringState
            RemoteVnetId            = $peering.remoteVnetId
            AllowVirtualNetworkAccess = $peering.allowVirtualNetworkAccess
            AllowForwardedTraffic   = $peering.allowForwardedTraffic
            AllowGatewayTransit     = $peering.allowGatewayTransit
            UseRemoteGateways       = $peering.useRemoteGateways
            PeeringId               = $peering.peeringId
        }
    }
}
else {
    foreach ($vnet in @($networkTopology | Where-Object { $_.type -ieq 'microsoft.network/virtualnetworks' })) {
        foreach ($peering in @(Get-PropertyValue (Get-PropertyValue $vnet 'properties') 'virtualNetworkPeerings' @())) {
            $properties = Get-PropertyValue $peering 'properties'
            [pscustomobject]@{
                SubscriptionId          = $vnet.subscriptionId
                ResourceGroup           = $vnet.resourceGroup
                VnetName                = $vnet.name
                VnetId                  = $vnet.id
                PeeringName             = Get-PropertyValue $peering 'name' ''
                PeeringState            = Get-PropertyValue $properties 'peeringState' ''
                RemoteVnetId            = Get-PropertyValue (Get-PropertyValue $properties 'remoteVirtualNetwork') 'id' ''
                AllowVirtualNetworkAccess = Get-PropertyValue $properties 'allowVirtualNetworkAccess' ''
                AllowForwardedTraffic   = Get-PropertyValue $properties 'allowForwardedTraffic' ''
                AllowGatewayTransit     = Get-PropertyValue $properties 'allowGatewayTransit' ''
                UseRemoteGateways       = Get-PropertyValue $properties 'useRemoteGateways' ''
                PeeringId               = Get-PropertyValue $peering 'id' ''
            }
        }
    }
}

$connectivitySource = if ($hybridConnectivity.Count -gt 0) { $hybridConnectivity } else { $networkTopology }
$gatewayExport = foreach ($gateway in @($connectivitySource | Where-Object { $_.type -ieq 'microsoft.network/virtualnetworkgateways' })) {
    $properties = Get-PropertyValue $gateway 'properties'
    $sku = Get-PropertyValue $properties 'sku'
    [pscustomobject]@{
        SubscriptionId = $gateway.subscriptionId
        ResourceGroup  = $gateway.resourceGroup
        Name           = $gateway.name
        Location       = $gateway.location
        GatewayType    = Get-PropertyValue $properties 'gatewayType' ''
        VpnType        = Get-PropertyValue $properties 'vpnType' ''
        Sku            = Get-PropertyValue $sku 'name' ''
        ActiveActive   = Get-PropertyValue $properties 'activeActive' ''
        EnableBgp      = Get-PropertyValue $properties 'enableBgp' ''
        Generation     = Get-PropertyValue $properties 'vpnGatewayGeneration' ''
        ResourceId     = $gateway.id
    }
}
$connectionExport = foreach ($connection in @($connectivitySource | Where-Object { $_.type -ieq 'microsoft.network/connections' })) {
    $properties = Get-PropertyValue $connection 'properties'
    [pscustomobject]@{
        SubscriptionId = $connection.subscriptionId
        ResourceGroup  = $connection.resourceGroup
        Name           = $connection.name
        Location       = $connection.location
        ConnectionType = Get-PropertyValue $properties 'connectionType' ''
        ConnectionStatus = Get-PropertyValue $properties 'connectionStatus' ''
        EnableBgp      = Get-PropertyValue $properties 'enableBgp' ''
        RoutingWeight  = Get-PropertyValue $properties 'routingWeight' ''
        ResourceId     = $connection.id
    }
}
$expressRouteExport = foreach ($circuit in @($connectivitySource | Where-Object { $_.type -ieq 'microsoft.network/expressroutecircuits' })) {
    $properties = Get-PropertyValue $circuit 'properties'
    $sku = Get-PropertyValue $circuit 'sku'
    [pscustomobject]@{
        SubscriptionId = $circuit.subscriptionId
        ResourceGroup  = $circuit.resourceGroup
        Name           = $circuit.name
        Location       = $circuit.location
        Tier           = Get-PropertyValue $sku 'tier' ''
        Family         = Get-PropertyValue $sku 'family' ''
        ServiceProvider = Get-PropertyValue (Get-PropertyValue $properties 'serviceProviderProperties') 'serviceProviderName' ''
        BandwidthMbps  = Get-PropertyValue (Get-PropertyValue $properties 'serviceProviderProperties') 'bandwidthInMbps' ''
        CircuitState   = Get-PropertyValue $properties 'circuitProvisioningState' ''
        ProviderState  = Get-PropertyValue $properties 'serviceProviderProvisioningState' ''
        AllowClassicOperations = Get-PropertyValue $properties 'allowClassicOperations' ''
        ResourceId     = $circuit.id
    }
}
$nsgRuleExport = @($nsgRuleExport)
$routeExport = @($routeExport)
$peeringExport = @($peeringExport)
$gatewayExport = @($gatewayExport)
$connectionExport = @($connectionExport)
$expressRouteExport = @($expressRouteExport)

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
        Name           = if ($subscription) { $subscription.name } else { $subscriptionId }
        State          = if ($subscription) { $subscription.state } else { 'Unknown' }
        TenantId       = if ($subscription) { $subscription.tenantId } else { $null }
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
$nsgRuleExport | Export-Csv -LiteralPath (Join-Path $csvRoot 'network-security-rules.csv') -NoTypeInformation -Encoding utf8
$routeExport | Export-Csv -LiteralPath (Join-Path $csvRoot 'network-routes.csv') -NoTypeInformation -Encoding utf8
$gatewayExport | Export-Csv -LiteralPath (Join-Path $csvRoot 'network-gateways.csv') -NoTypeInformation -Encoding utf8
$connectionExport | Export-Csv -LiteralPath (Join-Path $csvRoot 'network-connections.csv') -NoTypeInformation -Encoding utf8
$expressRouteExport | Export-Csv -LiteralPath (Join-Path $csvRoot 'expressroute-circuits.csv') -NoTypeInformation -Encoding utf8
$peeringExport | Export-Csv -LiteralPath (Join-Path $csvRoot 'vnet-peerings.csv') -NoTypeInformation -Encoding utf8

$unsupportedDiagnostics |
    Select-Object resourceId, type, reason |
    Export-Csv -LiteralPath (Join-Path $csvRoot 'diagnostic-settings-unsupported-resources.csv') -NoTypeInformation -Encoding utf8

$advisorCost | Select-Object subscriptionId, resourceId, impact, shortDescription, recommendationTypeId |
    Export-Csv -LiteralPath (Join-Path $csvRoot 'advisor-cost-recommendations.csv') -NoTypeInformation -Encoding utf8

$observationSequence = 0
$observations = [System.Collections.Generic.List[object]]::new()
$networkFindings = [System.Collections.Generic.List[object]]::new()

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

$nonCompliantPolicyCount = 0
foreach ($policyState in @($policyCompliance | Where-Object { $_.complianceState -eq 'NonCompliant' })) {
    $nonCompliantPolicyCount += [int]$policyState.Count
}
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

$broadSourceTokens = @('*', '0.0.0.0/0', '::/0', 'Internet', 'Any')
foreach ($rule in @($nsgRuleExport | Where-Object { $_.Direction -ieq 'Inbound' -and $_.Access -ieq 'Allow' })) {
    $sources = @($rule.SourceAddresses -split ';' | Where-Object { $_ })
    $hasBroadSource = @($sources | Where-Object { $_ -in $broadSourceTokens }).Count -gt 0
    if (-not $hasBroadSource) {
        continue
    }

    Add-NetworkFinding -CheckId 'NET-NSG-001' -SuggestedPriority 'High' -Category 'NSG' `
        -Title 'Broad inbound NSG allow rule' -ResourceName "$($rule.NsgName)/$($rule.RuleName)" `
        -ResourceId $rule.RuleId -Detail "Sources '$($rule.SourceAddresses)' can reach destinations '$($rule.Destinations)' on ports '$($rule.DestinationPorts)'." `
        -Recommendation 'Restrict source prefixes, destination prefixes, protocols, and ports to the minimum approved application requirement.' `
        -Evidence '04-network\network-security-rules.json'

    if (Test-NetworkPortSet -PortExpression $rule.DestinationPorts -Ports @(22, 3389, 5985, 5986)) {
        Add-NetworkFinding -CheckId 'NET-NSG-002' -SuggestedPriority 'High' -Category 'NSG' `
            -Title 'Management ports allowed from a broad source' -ResourceName "$($rule.NsgName)/$($rule.RuleName)" `
            -ResourceId $rule.RuleId -Detail "Broad sources '$($rule.SourceAddresses)' can reach one or more SSH, RDP, WinRM, or all destination ports." `
            -Recommendation 'Remove direct management exposure; use Azure Bastion, JIT access, a controlled management network, or tightly scoped approved source ranges.' `
            -Evidence '04-network\network-security-rules.json'
    }
}

$platformSubnetNames = @('GatewaySubnet', 'AzureFirewallSubnet', 'AzureFirewallManagementSubnet', 'RouteServerSubnet')
foreach ($subnet in @($vnetsSubnets | Where-Object {
    -not $_.nsgId -and $_.subnetName -and $_.subnetName -notin $platformSubnetNames
})) {
    Add-NetworkFinding -CheckId 'NET-NSG-003' -SuggestedPriority 'Medium' -Category 'NSG' `
        -Title 'Subnet has no NSG association' -ResourceName "$($subnet.vnetName)/$($subnet.subnetName)" `
        -ResourceId $subnet.vnetId -Detail 'No subnet-level Network Security Group association was collected.' `
        -Recommendation 'Confirm whether NIC-level controls or another approved segmentation control applies; otherwise associate a least-privilege NSG.' `
        -Evidence '04-network\vnets-subnets.json'
}

foreach ($route in $routeExport) {
    if ($route.AddressPrefix -in @('0.0.0.0/0', '::/0') -and $route.NextHopType -ieq 'Internet') {
        Add-NetworkFinding -CheckId 'NET-UDR-001' -SuggestedPriority 'High' -Category 'Routing' `
            -Title 'Default UDR sends traffic directly to the Internet' -ResourceName "$($route.RouteTableName)/$($route.RouteName)" `
            -ResourceId $route.RouteId -Detail "Default prefix '$($route.AddressPrefix)' uses the Internet next hop." `
            -Recommendation 'Validate the approved egress architecture and route Internet-bound traffic through the designated firewall or secure hub when centralized inspection is required.' `
            -Evidence '04-network\route-table-routes.json'
    }
    if ($route.NextHopType -ieq 'VirtualAppliance' -and -not $route.NextHopIpAddress) {
        Add-NetworkFinding -CheckId 'NET-UDR-002' -SuggestedPriority 'High' -Category 'Routing' `
            -Title 'Virtual-appliance route has no next-hop IP' -ResourceName "$($route.RouteTableName)/$($route.RouteName)" `
            -ResourceId $route.RouteId -Detail "Route '$($route.AddressPrefix)' specifies VirtualAppliance without a next-hop IP address." `
            -Recommendation 'Set the intended reachable virtual-appliance IP and validate symmetric routing and health.' `
            -Evidence '04-network\route-table-routes.json'
    }
}

foreach ($gateway in $gatewayExport) {
    if ($gateway.GatewayType -ieq 'Vpn' -and [string]$gateway.ActiveActive -ieq 'False') {
        Add-NetworkFinding -CheckId 'NET-VPN-001' -SuggestedPriority 'Medium' -Category 'VPN' `
            -Title 'VPN gateway is not active-active' -ResourceName $gateway.Name -ResourceId $gateway.ResourceId `
            -Detail "Gateway SKU '$($gateway.Sku)' is configured with active-active set to false." `
            -Recommendation 'Validate availability requirements and use active-active gateways with redundant on-premises devices and tunnels for critical connectivity.' `
            -Evidence '04-network\hybrid-connectivity.json'
    }
    if ($gateway.GatewayType -ieq 'Vpn' -and $gateway.Sku -and $gateway.Sku -notmatch 'AZ$') {
        Add-NetworkFinding -CheckId 'NET-VPN-002' -SuggestedPriority 'Medium' -Category 'VPN' `
            -Title 'VPN gateway SKU is not zone-redundant' -ResourceName $gateway.Name -ResourceId $gateway.ResourceId `
            -Detail "Gateway uses SKU '$($gateway.Sku)', which is not an AZ SKU." `
            -Recommendation 'Validate regional availability requirements and plan migration to an AZ gateway SKU where Availability Zones are supported.' `
            -Evidence '04-network\hybrid-connectivity.json'
    }
    if ($gateway.Sku -ieq 'Basic') {
        Add-NetworkFinding -CheckId 'NET-VPN-003' -SuggestedPriority 'High' -Category 'VPN' `
            -Title 'Gateway uses Basic SKU' -ResourceName $gateway.Name -ResourceId $gateway.ResourceId `
            -Detail 'Basic gateway SKU has material feature, scale, and resiliency limitations.' `
            -Recommendation 'Migrate to a supported production SKU sized for throughput, tunnel count, BGP, and availability requirements.' `
            -Evidence '04-network\hybrid-connectivity.json'
    }
}

foreach ($connection in @($connectionExport | Where-Object {
    $_.ConnectionStatus -and $_.ConnectionStatus -ine 'Connected'
})) {
    Add-NetworkFinding -CheckId 'NET-CONN-001' -SuggestedPriority 'High' -Category 'Hybrid connectivity' `
        -Title 'Hybrid network connection is not connected' -ResourceName $connection.Name -ResourceId $connection.ResourceId `
        -Detail "Connection status is '$($connection.ConnectionStatus)' for type '$($connection.ConnectionType)'." `
        -Recommendation 'Investigate tunnel, circuit, BGP, shared-key, provider, and on-premises device health, then confirm monitoring and escalation ownership.' `
        -Evidence '04-network\hybrid-connectivity.json'
}

foreach ($circuit in @($expressRouteExport | Where-Object {
    ($_.CircuitState -and $_.CircuitState -ine 'Enabled') -or
    ($_.ProviderState -and $_.ProviderState -ine 'Provisioned')
})) {
    Add-NetworkFinding -CheckId 'NET-ER-001' -SuggestedPriority 'High' -Category 'ExpressRoute' `
        -Title 'ExpressRoute circuit is not fully provisioned' -ResourceName $circuit.Name -ResourceId $circuit.ResourceId `
        -Detail "Circuit state is '$($circuit.CircuitState)' and provider state is '$($circuit.ProviderState)'." `
        -Recommendation 'Confirm Azure and provider provisioning, peering state, BGP sessions, route limits, and monitoring before relying on the circuit.' `
        -Evidence '04-network\hybrid-connectivity.json'
}
if ($expressRouteExport.Count -eq 1) {
    $circuit = $expressRouteExport | Select-Object -First 1
    Add-NetworkFinding -CheckId 'NET-ER-002' -SuggestedPriority 'Medium' -Category 'ExpressRoute' `
        -Title 'Single ExpressRoute circuit requires resiliency review' -ResourceName $circuit.Name -ResourceId $circuit.ResourceId `
        -Detail 'Only one ExpressRoute circuit was collected in the assessment scope.' `
        -Recommendation 'For critical connectivity, validate redundant circuits in diverse peering locations and test failover with the network provider.' `
        -Evidence '04-network\hybrid-connectivity.json'
}

foreach ($peering in @($peeringExport | Where-Object { $_.PeeringState -and $_.PeeringState -ine 'Connected' })) {
    Add-NetworkFinding -CheckId 'NET-PEER-001' -SuggestedPriority 'High' -Category 'VNet peering' `
        -Title 'VNet peering is not connected' -ResourceName "$($peering.VnetName)/$($peering.PeeringName)" `
        -ResourceId $peering.PeeringId -Detail "Peering state is '$($peering.PeeringState)'." `
        -Recommendation 'Validate both peering directions, remote VNet existence and permissions, address spaces, and intended gateway-transit configuration.' `
        -Evidence '04-network\vnet-peerings.json'
}

$flowLogEvidencePath = Join-Path $evidenceRoot '04-network\network-flow-logs.json'
if (Test-Path -LiteralPath $flowLogEvidencePath) {
    $disabledFlowLogs = @($networkFlowLogs | Where-Object { [string]$_.enabled -ieq 'False' })
    foreach ($flowLog in $disabledFlowLogs) {
        Add-NetworkFinding -CheckId 'NET-MON-001' -SuggestedPriority 'Medium' -Category 'Network monitoring' `
            -Title 'Network flow log is disabled' -ResourceName $flowLog.name -ResourceId $flowLog.id `
            -Detail "Flow logging is disabled for target '$($flowLog.targetResourceId)'." `
            -Recommendation 'Enable VNet flow logs for approved critical scopes and configure secure retention and Traffic Analytics when required.' `
            -Evidence '04-network\network-flow-logs.json'
    }
    if ($networkFlowLogs.Count -eq 0 -and $vnetsSubnets.Count -gt 0) {
        Add-NetworkFinding -CheckId 'NET-MON-002' -SuggestedPriority 'Medium' -Category 'Network monitoring' `
            -Title 'No network flow logs were collected' -ResourceName 'Assessment scope' -ResourceId '' `
            -Detail 'The flow-log evidence file is present but contains no flow-log resources.' `
            -Recommendation 'Validate VNet flow-log requirements for critical networks, central storage, retention, Traffic Analytics, and alerting.' `
            -Evidence '04-network\network-flow-logs.json'
    }
}

foreach ($group in @($networkFindings | Group-Object CheckId)) {
    $first = $group.Group | Select-Object -First 1
    Add-Observation -Area 'Network' -SuggestedPriority $first.SuggestedPriority `
        -Title $first.Finding -Count $group.Count -Evidence $first.Evidence `
        -AssessmentAction $first.Recommendation
}

$networkFindings | Export-Csv -LiteralPath (Join-Path $csvRoot 'network-best-practice-findings.csv') -NoTypeInformation -Encoding utf8

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
    $(ConvertTo-HtmlTable -Rows @($errorSummary | Select-Object -First $Top) -Properties @('Stage','Item','Count') -EmptyMessage 'No collection errors were recorded.')
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
      <div class="card"><div class="value">$($nsgRuleExport.Count)</div><div class="label">Custom NSG rules</div></div>
      <div class="card"><div class="value">$($routeExport.Count)</div><div class="label">Custom routes</div></div>
      <div class="card"><div class="value">$($gatewayExport.Count)</div><div class="label">Network gateways</div></div>
      <div class="card"><div class="value">$($expressRouteExport.Count)</div><div class="label">ExpressRoute circuits</div></div>
      <div class="card"><div class="value">$($keyVaults.Count)</div><div class="label">Key Vaults</div></div>
      <div class="card"><div class="value">$($operationsResources.Count)</div><div class="label">Operations resources</div></div>
      <div class="card"><div class="value">$($unsupportedDiagnostics.Count)</div><div class="label">Resources without diagnostic-settings support</div></div>
      <div class="card"><div class="value">$($backupResources.Count)</div><div class="label">Backup/ASR resources</div></div>
      <div class="card"><div class="value">$($advisorCost.Count)</div><div class="label">Advisor cost recommendations</div></div>
    </div>
  </section>

  <section>
    <h2>Network best-practice review</h2>
    $(ConvertTo-HtmlTable -Rows $networkFindings.ToArray() -Properties @('CheckId','SuggestedPriority','Category','Finding','ResourceName','Detail','Recommendation','Status') -EmptyMessage 'No automated network review candidates were identified from the collected configuration.')
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
      <li><code>csv/network-security-rules.csv</code></li>
      <li><code>csv/network-routes.csv</code></li>
      <li><code>csv/network-gateways.csv</code></li>
      <li><code>csv/network-connections.csv</code></li>
      <li><code>csv/expressroute-circuits.csv</code></li>
      <li><code>csv/vnet-peerings.csv</code></li>
      <li><code>csv/network-best-practice-findings.csv</code></li>
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
    NetworkReviewCandidates = $networkFindings.Count
    HtmlReport          = $reportFile
    CsvDirectory        = $csvRoot
}
ConvertTo-Json -InputObject $reportMetadata -Depth 10 |
    Set-Content -LiteralPath (Join-Path $reportRoot 'report-metadata.json') -Encoding utf8

Assert-NoProhibitedEvidenceData -RootPath $reportRoot
Write-Host "Report generated: $reportFile" -ForegroundColor Green
Write-Host "CSV exports: $csvRoot"
