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

function Get-DocPropertyValue {
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

function Get-ServiceCategory {
    param([Parameter(Mandatory)][string]$ResourceType)

    switch -Regex ($ResourceType.ToLowerInvariant()) {
        '^microsoft\.compute/' { return 'Compute' }
        '^microsoft\.containerservice/|^microsoft\.containerinstance/|^microsoft\.app/containerapps|^microsoft\.app/managedenvironments|^microsoft\.redhatopenshift/' { return 'Containers' }
        '^microsoft\.web/' { return 'App Service and Functions' }
        '^microsoft\.apimanagement/|^microsoft\.logic/|^microsoft\.datafactory/' { return 'Application Integration' }
        '^microsoft\.sql/|^microsoft\.dbforpostgresql/|^microsoft\.dbformysql/|^microsoft\.documentdb/|^microsoft\.cache/|^microsoft\.synapse/|^microsoft\.databricks/' { return 'Databases and Data' }
        '^microsoft\.cognitiveservices/|^microsoft\.machinelearningservices/|^microsoft\.search/|^microsoft\.botservice/' { return 'AI and Machine Learning' }
        '^microsoft\.storage/' { return 'Storage' }
        '^microsoft\.servicebus/|^microsoft\.eventhub/|^microsoft\.eventgrid/|^microsoft\.relay/|^microsoft\.notificationhubs/' { return 'Messaging and Events' }
        '^microsoft\.network/|^microsoft\.cdn/' { return 'Network' }
        '^microsoft\.keyvault/|^microsoft\.security/' { return 'Security' }
        '^microsoft\.insights/|^microsoft\.operationalinsights/|^microsoft\.monitor/|^microsoft\.automation/|^microsoft\.maintenance/' { return 'Operations' }
        '^microsoft\.recoveryservices/|^microsoft\.dataprotection/' { return 'Resilience' }
        default { return 'Other Azure Services' }
    }
}

function Get-ServiceConfigurationSummary {
    param([AllowNull()]$Properties)

    if ($null -eq $Properties) {
        return ''
    }

    $indicators = [System.Collections.Generic.List[string]]::new()
    $propertyMap = [ordered]@{
        'State' = @('provisioningState', 'state', 'status')
        'Public access' = @('publicNetworkAccess')
        'HTTPS only' = @('httpsOnly')
        'Minimum TLS' = @('minimumTlsVersion', 'minTlsVersion')
        'Zone redundant' = @('zoneRedundant')
        'Version' = @('version', 'currentSku')
        'Kind' = @('kind')
    }
    foreach ($entry in $propertyMap.GetEnumerator()) {
        foreach ($propertyName in $entry.Value) {
            $value = Get-DocPropertyValue $Properties $propertyName
            if ($null -ne $value -and [string]$value) {
                $indicators.Add("$($entry.Key): $value")
                break
            }
        }
    }

    $highAvailability = Get-DocPropertyValue $Properties 'highAvailability'
    if ($highAvailability) {
        $mode = Get-DocPropertyValue $highAvailability 'mode'
        $state = Get-DocPropertyValue $highAvailability 'state'
        $haText = @($mode, $state | Where-Object { $_ }) -join '/'
        if ($haText) {
            $indicators.Add("High availability: $haText")
        }
    }

    $networkAcls = Get-DocPropertyValue $Properties 'networkAcls'
    if ($networkAcls) {
        $defaultAction = Get-DocPropertyValue $networkAcls 'defaultAction'
        if ($defaultAction) {
            $indicators.Add("Network default: $defaultAction")
        }
    }

    return @($indicators | Select-Object -Unique) -join '; '
}

function New-ServiceRows {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ConfigurationResources,
        [Parameter(Mandatory)][hashtable]$SubscriptionNames
    )

    return @(
        foreach ($resource in $ConfigurationResources) {
            $properties = Get-DocPropertyValue $resource 'properties'
            $identity = Get-DocPropertyValue $resource 'identity'
            $sku = Get-DocPropertyValue $resource 'sku'
            $privateEndpointConnections = @(Get-DocPropertyValue $properties 'privateEndpointConnections' @())
            [pscustomobject]@{
                Category             = Get-ServiceCategory ([string]$resource.type)
                Name                 = [string]$resource.name
                Type                 = [string]$resource.type
                Subscription         = if ($SubscriptionNames.ContainsKey([string]$resource.subscriptionId)) { $SubscriptionNames[[string]$resource.subscriptionId] } else { [string]$resource.subscriptionId }
                SubscriptionId       = [string]$resource.subscriptionId
                ResourceGroup        = [string]$resource.resourceGroup
                Region               = [string]$resource.location
                Kind                 = [string](Get-DocPropertyValue $resource 'kind' '')
                Sku                  = [string](Get-DocPropertyValue $sku 'name' '')
                Zones                = @(Get-DocPropertyValue $resource 'zones' @()) -join '; '
                Identity             = [string](Get-DocPropertyValue $identity 'type' '')
                PublicNetworkAccess  = [string](Get-DocPropertyValue $properties 'publicNetworkAccess' '')
                PrivateEndpoints     = $privateEndpointConnections.Count
                Configuration        = Get-ServiceConfigurationSummary $properties
                ResourceId           = [string]$resource.id
            }
        }
    )
}

function New-ServiceInventoryBody {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][string]$ScopeDescription,
        [Parameter(Mandatory)][string]$ValidationGuidance,
        [int]$Limit = 20
    )

    $typeSummary = @(
        $Rows | Group-Object Type | Sort-Object Count -Descending |
            ForEach-Object { [pscustomobject]@{ Type = $_.Name; Resources = $_.Count } }
    )
    $subscriptionSummary = @(
        $Rows | Group-Object Subscription | Sort-Object Count -Descending |
            ForEach-Object { [pscustomobject]@{ Subscription = $_.Name; Resources = $_.Count } }
    )
    $publicAccess = @($Rows | Where-Object PublicNetworkAccess -eq 'Enabled').Count
    $privateEndpointCount = 0
    foreach ($row in $Rows) {
        if ($row.PrivateEndpoints) {
            $privateEndpointCount += [int]$row.PrivateEndpoints
        }
    }

    return @"
> $ScopeDescription

## Summary

$(New-MetricList ([ordered]@{
    'Resources' = $Rows.Count
    'Resource types' = $typeSummary.Count
    'Subscriptions represented' = $subscriptionSummary.Count
    'Regions represented' = @($Rows | ForEach-Object { $_.Region } | Where-Object { $_ } | Sort-Object -Unique).Count
    'Public network access enabled' = $publicAccess
    'Private Endpoint connections' = [int]$privateEndpointCount
}))

## Resource types

$(New-MarkdownTable $typeSummary ([ordered]@{
    'Resource type' = { param($r) $r.Type }
    'Resources' = { param($r) $r.Resources }
}))

## Subscription distribution

$(New-MarkdownTable $subscriptionSummary ([ordered]@{
    'Subscription' = { param($r) $r.Subscription }
    'Resources' = { param($r) $r.Resources }
}))

## Configuration overview

$(New-MarkdownTable $Rows ([ordered]@{
    'Name' = { param($r) $r.Name }
    'Resource type' = { param($r) $r.Type }
    'Subscription' = { param($r) $r.Subscription }
    'Resource group' = { param($r) $r.ResourceGroup }
    'Region' = { param($r) $r.Region }
    'Kind' = { param($r) $r.Kind }
    'SKU' = { param($r) $r.Sku }
    'Zones' = { param($r) $r.Zones }
    'Identity' = { param($r) $r.Identity }
    'Public access' = { param($r) $r.PublicNetworkAccess }
    'Private Endpoints' = { param($r) $r.PrivateEndpoints }
    'Configuration indicators' = { param($r) $r.Configuration }
}) -Limit $Limit)

## Assessment interpretation

$ValidationGuidance

The page summarizes properties exposed through Azure Resource Graph. Empty fields mean that the property was absent from the collected representation; they do not prove that a control is disabled or compliant.
"@
}

function Get-NetworkResourceParentId {
    param([AllowEmptyString()][string]$ChildResourceId)

    if (-not $ChildResourceId) {
        return ''
    }
    $segments = @($ChildResourceId -split '/' | Where-Object { $_ })
    $providerIndex = [Array]::IndexOf($segments, 'providers')
    if ($providerIndex -lt 0 -or $segments.Count -le ($providerIndex + 3)) {
        return ''
    }
    return '/' + ($segments[0..($providerIndex + 3)] -join '/')
}

function Get-VnetIdFromSubnetId {
    param([AllowEmptyString()][string]$SubnetId)

    if ($SubnetId -match '^(.*?/virtualNetworks/[^/]+)/subnets/[^/]+$') {
        return $Matches[1]
    }
    return ''
}

function Get-ResourceNameFromId {
    param([AllowEmptyString()][string]$ResourceId)

    if (-not $ResourceId) {
        return ''
    }
    return ($ResourceId -split '/')[-1]
}

function New-NetworkTopologyModel {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$TopologyResources,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AllNetworkResources,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$PublicIpResources
    )

    $nodes = @{}
    $edges = [System.Collections.Generic.List[object]]::new()
    $disconnected = [System.Collections.Generic.List[object]]::new()
    $publicIpById = @{}
    $publicIpAssociation = @{}

    foreach ($publicIp in $PublicIpResources) {
        $publicIpById[[string]$publicIp.id] = $publicIp
        $parentId = Get-NetworkResourceParentId ([string]$publicIp.ipConfigurationId)
        if ($parentId) {
            if (-not $publicIpAssociation.ContainsKey($parentId)) {
                $publicIpAssociation[$parentId] = [System.Collections.Generic.List[string]]::new()
            }
            if ($publicIp.ipAddress) {
                $publicIpAssociation[$parentId].Add([string]$publicIp.ipAddress)
            }
        }
    }

    foreach ($vnet in @($TopologyResources | Where-Object { $_.type -ieq 'microsoft.network/virtualnetworks' })) {
        $properties = Get-DocPropertyValue $vnet 'properties'
        $addressSpace = Get-DocPropertyValue $properties 'addressSpace'
        $prefixes = @(Get-DocPropertyValue $addressSpace 'addressPrefixes' @())
        $nodes[[string]$vnet.id] = [pscustomobject]@{
            Id          = [string]$vnet.id
            Name        = [string]$vnet.name
            Type        = 'Virtual network'
            Region      = [string]$vnet.location
            VnetId      = [string]$vnet.id
            Subnet      = ''
            PrivateIps  = $prefixes -join '; '
            PublicIps   = ''
            Remote      = $false
            Connected   = $true
        }
    }

    $privateEndpointIps = @{}
    foreach ($nic in @($AllNetworkResources | Where-Object { $_.type -ieq 'microsoft.network/networkinterfaces' })) {
        $properties = Get-DocPropertyValue $nic 'properties'
        $privateEndpoint = Get-DocPropertyValue $properties 'privateEndpoint'
        $privateEndpointId = [string](Get-DocPropertyValue $privateEndpoint 'id' '')
        if ($privateEndpointId) {
            $privateEndpointIps[$privateEndpointId] = @(
                Get-DocPropertyValue $properties 'ipConfigurations' @() |
                    ForEach-Object { Get-DocPropertyValue (Get-DocPropertyValue $_ 'properties') 'privateIPAddress' '' } |
                    Where-Object { $_ }
            )
        }
    }

    $deviceTypes = [ordered]@{
        'microsoft.network/azurefirewalls'         = 'Azure Firewall'
        'microsoft.network/virtualnetworkgateways' = 'VPN/ER gateway'
        'microsoft.network/applicationgateways'    = 'Application Gateway'
        'microsoft.network/bastionhosts'           = 'Azure Bastion'
        'microsoft.network/natgateways'             = 'NAT Gateway'
        'microsoft.network/loadbalancers'           = 'Load Balancer'
        'microsoft.network/privateendpoints'        = 'Private Endpoint'
    }

    foreach ($resource in @($AllNetworkResources | Where-Object { $deviceTypes.Contains([string]$_.type) })) {
        $properties = Get-DocPropertyValue $resource 'properties'
        $ipConfigurations = @(
            @(Get-DocPropertyValue $properties 'ipConfigurations' @())) +
            @(Get-DocPropertyValue $properties 'frontendIPConfigurations' @()) +
            @(Get-DocPropertyValue $properties 'gatewayIPConfigurations' @())
        $subnetIds = @(
            $ipConfigurations |
                ForEach-Object { Get-DocPropertyValue (Get-DocPropertyValue $_ 'properties') 'subnet' } |
                ForEach-Object { Get-DocPropertyValue $_ 'id' '' } |
                Where-Object { $_ }
        )
        if ($subnetIds.Count -eq 0) {
            $subnetIds = @(
                Get-DocPropertyValue $properties 'subnets' @() |
                    ForEach-Object { Get-DocPropertyValue $_ 'id' '' } |
                    Where-Object { $_ }
            )
        }
        if ($resource.type -ieq 'microsoft.network/privateendpoints') {
            $subnet = Get-DocPropertyValue $properties 'subnet'
            $subnetIds = @([string](Get-DocPropertyValue $subnet 'id' ''))
        }

        $privateIps = @(
            $ipConfigurations |
                ForEach-Object { Get-DocPropertyValue (Get-DocPropertyValue $_ 'properties') 'privateIPAddress' '' } |
                Where-Object { $_ }
        )
        if ($resource.type -ieq 'microsoft.network/privateendpoints' -and $privateEndpointIps.ContainsKey([string]$resource.id)) {
            $privateIps = @($privateEndpointIps[[string]$resource.id])
        }

        $publicIpIds = @(
            $ipConfigurations |
                ForEach-Object { Get-DocPropertyValue (Get-DocPropertyValue $_ 'properties') 'publicIPAddress' } |
                ForEach-Object { Get-DocPropertyValue $_ 'id' '' } |
                Where-Object { $_ }
        )
        $publicIpIds += @(
            Get-DocPropertyValue $properties 'publicIpAddresses' @() |
                ForEach-Object { Get-DocPropertyValue $_ 'id' '' } |
                Where-Object { $_ }
        )
        $publicIps = @(
            foreach ($publicIpId in $publicIpIds) {
                if ($publicIpById.ContainsKey([string]$publicIpId)) {
                    $publicIpById[[string]$publicIpId].ipAddress
                }
            }
            if ($publicIpAssociation.ContainsKey([string]$resource.id)) {
                $publicIpAssociation[[string]$resource.id]
            }
        ) | Where-Object { $_ } | Sort-Object -Unique

        $subnetId = [string]($subnetIds | Select-Object -First 1)
        $vnetId = Get-VnetIdFromSubnetId $subnetId
        $node = [pscustomobject]@{
            Id          = [string]$resource.id
            Name        = [string]$resource.name
            Type        = [string]$deviceTypes[[string]$resource.type]
            Region      = [string]$resource.location
            VnetId      = $vnetId
            Subnet      = Get-ResourceNameFromId $subnetId
            PrivateIps  = $privateIps -join '; '
            PublicIps   = $publicIps -join '; '
            Remote      = $false
            Connected   = [bool]($vnetId -and $nodes.ContainsKey($vnetId))
        }
        $nodes[$node.Id] = $node

        if ($node.Connected) {
            $edges.Add([pscustomobject]@{
                From   = $vnetId
                To     = $node.Id
                Type   = 'Subnet attachment'
                Status = 'Connected'
            })
        }
        else {
            $disconnected.Add([pscustomobject]@{
                Name       = $node.Name
                Type       = $node.Type
                IpAddresses = (@($node.PrivateIps, $node.PublicIps) | Where-Object { $_ }) -join '; '
                RelatedTo  = if ($subnetId) { $subnetId } else { 'No subnet association collected' }
                State      = 'Unresolved'
                Reason     = if ($subnetId) { 'Referenced VNet is not present in the collected topology.' } else { 'No VNet/subnet attachment was collected.' }
                ResourceId = $node.Id
            })
        }
    }

    foreach ($nic in @($AllNetworkResources | Where-Object { $_.type -ieq 'microsoft.network/networkinterfaces' })) {
        $properties = Get-DocPropertyValue $nic 'properties'
        $privateEndpoint = Get-DocPropertyValue $properties 'privateEndpoint'
        if (Get-DocPropertyValue $privateEndpoint 'id' '') {
            continue
        }
        $virtualMachine = Get-DocPropertyValue $properties 'virtualMachine'
        $virtualMachineId = [string](Get-DocPropertyValue $virtualMachine 'id' '')
        if (-not $virtualMachineId) {
            continue
        }
        $ipConfigurations = @(Get-DocPropertyValue $properties 'ipConfigurations' @())
        $subnetId = [string](
            $ipConfigurations |
                ForEach-Object { Get-DocPropertyValue (Get-DocPropertyValue $_ 'properties') 'subnet' } |
                ForEach-Object { Get-DocPropertyValue $_ 'id' '' } |
                Where-Object { $_ } |
                Select-Object -First 1
        )
        $vnetId = Get-VnetIdFromSubnetId $subnetId
        $privateIps = @(
            $ipConfigurations |
                ForEach-Object { Get-DocPropertyValue (Get-DocPropertyValue $_ 'properties') 'privateIPAddress' '' } |
                Where-Object { $_ }
        )
        $node = [pscustomobject]@{
            Id          = $virtualMachineId
            Name        = Get-ResourceNameFromId $virtualMachineId
            Type        = 'Virtual machine'
            Region      = [string]$nic.location
            VnetId      = $vnetId
            Subnet      = Get-ResourceNameFromId $subnetId
            PrivateIps  = $privateIps -join '; '
            PublicIps   = ''
            Remote      = $false
            Connected   = [bool]($vnetId -and $nodes.ContainsKey($vnetId))
        }
        $nodes[$node.Id] = $node
        if ($node.Connected) {
            $edges.Add([pscustomobject]@{ From = $vnetId; To = $node.Id; Type = 'NIC attachment'; Status = 'Connected' })
        }
        else {
            $disconnected.Add([pscustomobject]@{
                Name = $node.Name; Type = $node.Type; IpAddresses = $node.PrivateIps
                RelatedTo = $subnetId; State = 'Unresolved'
                Reason = 'The VM NIC references a VNet that is not present in the collected topology.'
                ResourceId = $node.Id
            })
        }
    }

    $seenPeerings = @{}
    foreach ($vnet in @($TopologyResources | Where-Object { $_.type -ieq 'microsoft.network/virtualnetworks' })) {
        foreach ($peering in @(Get-DocPropertyValue (Get-DocPropertyValue $vnet 'properties') 'virtualNetworkPeerings' @())) {
            $properties = Get-DocPropertyValue $peering 'properties'
            $remote = Get-DocPropertyValue $properties 'remoteVirtualNetwork'
            $remoteId = [string](Get-DocPropertyValue $remote 'id' '')
            $state = [string](Get-DocPropertyValue $properties 'peeringState' 'Unknown')
            $pairKey = @([string]$vnet.id, $remoteId | Sort-Object) -join '|'
            if ($state -ieq 'Connected' -and $remoteId) {
                if (-not $nodes.ContainsKey($remoteId)) {
                    $nodes[$remoteId] = [pscustomobject]@{
                        Id = $remoteId; Name = Get-ResourceNameFromId $remoteId; Type = 'Remote virtual network'
                        Region = 'Outside collected topology'; VnetId = $remoteId; Subnet = ''
                        PrivateIps = ''; PublicIps = ''; Remote = $true; Connected = $true
                    }
                }
                if (-not $seenPeerings.ContainsKey($pairKey)) {
                    $edges.Add([pscustomobject]@{ From = [string]$vnet.id; To = $remoteId; Type = 'VNet peering'; Status = $state })
                    $seenPeerings[$pairKey] = $true
                }
            }
            else {
                $disconnected.Add([pscustomobject]@{
                    Name = [string](Get-DocPropertyValue $peering 'name' '')
                    Type = 'VNet peering'
                    IpAddresses = ''
                    RelatedTo = "$(Get-ResourceNameFromId ([string]$vnet.id)) -> $(Get-ResourceNameFromId $remoteId)"
                    State = $state
                    Reason = 'The peering is not in Connected state.'
                    ResourceId = [string](Get-DocPropertyValue $peering 'id' '')
                })
            }
        }
    }

    foreach ($publicIp in $PublicIpResources) {
        if (-not $publicIp.ipConfigurationId) {
            $referencedByDevice = @(
                $nodes.Values | Where-Object {
                    $_.PublicIps -and (@($_.PublicIps -split '; ') -contains [string]$publicIp.ipAddress)
                }
            ).Count -gt 0
            if (-not $referencedByDevice) {
                $disconnected.Add([pscustomobject]@{
                    Name = [string]$publicIp.name; Type = 'Public IP address'; IpAddresses = [string]$publicIp.ipAddress
                    RelatedTo = 'No associated IP configuration'; State = 'Unassociated'
                    Reason = 'The Public IP has no collected device or IP-configuration association.'
                    ResourceId = [string]$publicIp.id
                })
            }
        }
    }

    $connectedDeviceIds = @($edges | Where-Object Type -ne 'VNet peering' | ForEach-Object To | Sort-Object -Unique)
    $connectedDevices = @(
        foreach ($nodeId in $connectedDeviceIds) {
            if ($nodes.ContainsKey([string]$nodeId)) {
                $node = $nodes[[string]$nodeId]
                [pscustomobject]@{
                    Name        = $node.Name
                    Type        = $node.Type
                    VNet        = if ($nodes.ContainsKey([string]$node.VnetId)) { $nodes[[string]$node.VnetId].Name } else { Get-ResourceNameFromId $node.VnetId }
                    Subnet      = $node.Subnet
                    PrivateIps  = $node.PrivateIps
                    PublicIps   = $node.PublicIps
                    Region      = $node.Region
                    ResourceId  = $node.Id
                }
            }
        }
    )

    return [pscustomobject]@{
        Nodes               = @($nodes.Values)
        Edges               = @($edges)
        ConnectedDevices    = $connectedDevices
        DisconnectedDevices = @($disconnected)
    }
}

function New-NetworkTopologySvg {
    param([Parameter(Mandatory)]$Model)

    $vnetNodes = @($Model.Nodes | Where-Object { $_.Type -in @('Virtual network', 'Remote virtual network') } | Sort-Object Remote, Name)
    if ($vnetNodes.Count -eq 0) {
        return '<p><em>No virtual-network topology records were collected.</em></p>'
    }

    $positions = @{}
    $rows = [System.Collections.Generic.List[object]]::new()
    $currentY = 55
    foreach ($vnet in $vnetNodes) {
        $devices = @(
            $Model.Edges |
                Where-Object { $_.From -eq $vnet.Id -and $_.Type -ne 'VNet peering' } |
                ForEach-Object {
                    $edge = $_
                    $Model.Nodes | Where-Object Id -eq $edge.To | Select-Object -First 1
                } |
                Where-Object { $_ } |
                Sort-Object Type, Name
        )
        $rowHeight = [Math]::Max(125, 30 + (80 * $devices.Count))
        $rows.Add([pscustomobject]@{ Vnet = $vnet; Devices = $devices; Y = $currentY; Height = $rowHeight })
        $positions[$vnet.Id] = [pscustomobject]@{ X = 80; Y = $currentY; CenterY = $currentY + ($rowHeight / 2) }
        $currentY += $rowHeight + 35
    }

    $height = $currentY + 30
    $svg = [System.Collections.Generic.List[string]]::new()
    $svg.Add("<div class=`"topology-wrap`"><svg class=`"topology-svg`" viewBox=`"0 0 1500 $height`" role=`"img`" aria-label=`"Connected Azure network topology`">")
    $svg.Add('<defs><marker id="arrow" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto"><path d="M0,0 L0,6 L9,3 z" fill="#667085"/></marker></defs>')
    $svg.Add('<rect x="0" y="0" width="1500" height="100%" fill="#f8fbfd"/>')
    $svg.Add('<text x="80" y="30" font-size="17" font-weight="700" fill="#0f2942">Virtual networks</text>')
    $svg.Add('<text x="790" y="30" font-size="17" font-weight="700" fill="#0f2942">Connected devices and collected IP addresses</text>')

    foreach ($edge in @($Model.Edges | Where-Object Type -eq 'VNet peering')) {
        if (-not $positions.ContainsKey([string]$edge.From) -or -not $positions.ContainsKey([string]$edge.To)) {
            continue
        }
        $from = $positions[[string]$edge.From]
        $to = $positions[[string]$edge.To]
        $bendX = 35
        $svg.Add("<path d=`"M $($from.X) $($from.CenterY) C $bendX $($from.CenterY), $bendX $($to.CenterY), $($to.X) $($to.CenterY)`" fill=`"none`" stroke=`"#0078d4`" stroke-width=`"3`" marker-end=`"url(#arrow)`"/>")
    }

    foreach ($row in $rows) {
        $vnet = $row.Vnet
        $vnetFill = if ($vnet.Remote) { '#f2f4f7' } else { '#e8f2fb' }
        $vnetStroke = if ($vnet.Remote) { '#98a2b3' } else { '#0078d4' }
        $name = [System.Net.WebUtility]::HtmlEncode([string]$vnet.Name)
        $region = [System.Net.WebUtility]::HtmlEncode([string]$vnet.Region)
        $prefixes = [System.Net.WebUtility]::HtmlEncode([string]$vnet.PrivateIps)
        $svg.Add("<rect x=`"80`" y=`"$($row.Y)`" width=`"610`" height=`"$($row.Height)`" rx=`"12`" fill=`"$vnetFill`" stroke=`"$vnetStroke`" stroke-width=`"2`"/>")
        $svg.Add("<text x=`"105`" y=`"$($row.Y + 32)`" font-size=`"18`" font-weight=`"700`" fill=`"#0f2942`">$name</text>")
        $svg.Add("<text x=`"105`" y=`"$($row.Y + 57)`" font-size=`"13`" fill=`"#475467`">Region: $region</text>")
        $svg.Add("<text x=`"105`" y=`"$($row.Y + 79)`" font-size=`"13`" fill=`"#475467`">Address space: $prefixes</text>")

        $deviceIndex = 0
        foreach ($device in $row.Devices) {
            $deviceY = $row.Y + 10 + (80 * $deviceIndex)
            $deviceCenterY = $deviceY + 32
            $deviceName = [System.Net.WebUtility]::HtmlEncode([string]$device.Name)
            $deviceType = [System.Net.WebUtility]::HtmlEncode([string]$device.Type)
            $subnet = [System.Net.WebUtility]::HtmlEncode([string]$device.Subnet)
            $privateIps = [System.Net.WebUtility]::HtmlEncode([string]$device.PrivateIps)
            $publicIps = [System.Net.WebUtility]::HtmlEncode([string]$device.PublicIps)
            $ipText = @(
                if ($privateIps) { "Private: $privateIps" }
                if ($publicIps) { "Public: $publicIps" }
            ) -join ' | '
            if (-not $ipText) {
                $ipText = 'IP address not present in collected configuration'
            }
            $svg.Add("<line x1=`"690`" y1=`"$deviceCenterY`" x2=`"790`" y2=`"$deviceCenterY`" stroke=`"#667085`" stroke-width=`"2`" marker-end=`"url(#arrow)`"/>")
            $svg.Add("<rect x=`"790`" y=`"$deviceY`" width=`"650`" height=`"64`" rx=`"9`" fill=`"#ffffff`" stroke=`"#12b76a`" stroke-width=`"2`"/>")
            $svg.Add("<text x=`"810`" y=`"$($deviceY + 23)`" font-size=`"15`" font-weight=`"700`" fill=`"#0f2942`">$deviceName</text>")
            $svg.Add("<text x=`"810`" y=`"$($deviceY + 43)`" font-size=`"12`" fill=`"#475467`">$deviceType | Subnet: $subnet</text>")
            $svg.Add("<text x=`"810`" y=`"$($deviceY + 59)`" font-size=`"11`" fill=`"#175cd3`">$ipText</text>")
            $deviceIndex++
        }
    }
    $svg.Add('</svg></div>')
    return $svg -join [Environment]::NewLine
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
    [pscustomobject]@{ Slug = '13-service-estate'; Title = 'Azure Service Estate' }
    [pscustomobject]@{ Slug = '14-compute-and-containers'; Title = 'Compute and Containers' }
    [pscustomobject]@{ Slug = '15-app-services-and-integration'; Title = 'App Services and Integration' }
    [pscustomobject]@{ Slug = '16-databases-and-data'; Title = 'Databases and Data Platforms' }
    [pscustomobject]@{ Slug = '17-ai-and-machine-learning'; Title = 'AI and Machine Learning' }
    [pscustomobject]@{ Slug = '18-storage-and-messaging'; Title = 'Storage, Messaging, and Events' }
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
.topology-wrap { width:100%; overflow:auto; border:1px solid var(--line); border-radius:8px; background:#f8fbfd; margin:16px 0 24px; }
.topology-svg { display:block; min-width:1100px; width:100%; height:auto; }
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
$resourceConfigurations = @(Get-JsonItems '02-resource-governance\resource-configurations.json' -Optional)
$tagCoverage = @(Get-JsonItems '02-resource-governance\tag-coverage.json' -Optional)
$policyCompliance = @(Get-JsonItems '02-resource-governance\policy-compliance-summary.json' -Optional)
$rbacAssignments = @(Get-JsonItems '03-identity\rbac-role-assignments.json' -Optional)
$managedIdentities = @(Get-JsonItems '03-identity\managed-identities.json' -Optional)
$directoryRoles = @(Get-JsonItems '03-identity\directory-roles.json' -Optional)
$conditionalAccess = @(Get-JsonItems '03-identity\conditional-access-policies.json' -Optional)
$networkResources = @(Get-JsonItems '04-network\network-resources.json' -Optional)
$networkTopologyResources = @(Get-JsonItems '04-network\network-topology.json' -Optional)
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
$availabilityConfigurations = @(Get-JsonItems '07-resilience\availability-configuration.json' -Optional)
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

if ($resourceConfigurations.Count -eq 0) {
    $resourceConfigurations = $availabilityConfigurations
}

$effectiveSubscriptionIds = if ($scope -and $scope.PSObject.Properties['Subscriptions'] -and $scope.Subscriptions) {
    @($scope.Subscriptions)
}
else {
    @($resources.subscriptionId | Where-Object { $_ } | Sort-Object -Unique)
}
$effectiveSubscriptions = @($subscriptions | Where-Object { $_.id -in $effectiveSubscriptionIds })
$subscriptionNames = @{}
foreach ($subscription in $effectiveSubscriptions) {
    $subscriptionNames[[string]$subscription.id] = [string]$subscription.name
}
$serviceRows = @(New-ServiceRows -ConfigurationResources $resourceConfigurations -SubscriptionNames $subscriptionNames)
$serviceSummary = @(
    $serviceRows | Group-Object Category | Sort-Object Count -Descending |
        ForEach-Object {
            [pscustomobject]@{
                Category = $_.Name
                Resources = $_.Count
                Subscriptions = @($_.Group.SubscriptionId | Sort-Object -Unique).Count
                Regions = @($_.Group.Region | Where-Object { $_ } | Sort-Object -Unique).Count
                PublicAccessEnabled = @($_.Group | Where-Object PublicNetworkAccess -eq 'Enabled').Count
                PrivateEndpoints = ($_.Group | Measure-Object PrivateEndpoints -Sum).Sum
            }
        }
)
$computeContainerRows = @($serviceRows | Where-Object Category -in @('Compute', 'Containers'))
$appIntegrationRows = @($serviceRows | Where-Object Category -in @('App Service and Functions', 'Application Integration'))
$databaseDataRows = @($serviceRows | Where-Object Category -eq 'Databases and Data')
$aiRows = @($serviceRows | Where-Object Category -eq 'AI and Machine Learning')
$storageMessagingRows = @($serviceRows | Where-Object Category -in @('Storage', 'Messaging and Events'))
$serviceRows |
    Export-Csv -LiteralPath (Join-Path $documentationRoot 'azure-service-inventory.csv') -NoTypeInformation -Encoding utf8
$workloadScopes = @()
$workloadResourceRecords = @()
$workloadPath = Join-Path $evidenceRoot '09-workloads'
if (Test-Path -LiteralPath $workloadPath) {
    $workloadScopes = @(
        Get-ChildItem -LiteralPath $workloadPath -Filter '*-scope.json' -File -ErrorAction SilentlyContinue |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 30 }
    )
    $workloadResourceRecords = @(
        Get-ChildItem -LiteralPath $workloadPath -Filter '*-resources.json' -File -ErrorAction SilentlyContinue |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 100 }
    )
}
$resourceGroups = @($resourceContainers | Where-Object { $_.type -eq 'microsoft.resources/subscriptions/resourcegroups' })
$untagged = @($tagCoverage | Where-Object { [int]$_.tagCount -eq 0 })
$unhealthyDefender = @($defenderAssessments | Where-Object { $_.status -eq 'Unhealthy' })
$directUserRbac = @($rbacAssignments | Where-Object { $_.principalType -eq 'User' })
$nonCompliantPolicies = 0
foreach ($policyState in @($policyCompliance | Where-Object complianceState -eq 'NonCompliant')) {
    $nonCompliantPolicies += [int]$policyState.Count
}

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
$networkTopologyModel = New-NetworkTopologyModel `
    -TopologyResources $networkTopologyResources `
    -AllNetworkResources $networkResources `
    -PublicIpResources $publicIps
$networkTopologySvg = New-NetworkTopologySvg -Model $networkTopologyModel

[System.IO.File]::WriteAllText(
    (Join-Path $documentationRoot 'network-topology.json'),
    (ConvertTo-Json -InputObject $networkTopologyModel -Depth 15),
    [System.Text.UTF8Encoding]::new($false)
)
$networkTopologyModel.DisconnectedDevices |
    Export-Csv -LiteralPath (Join-Path $documentationRoot 'network-disconnected-devices.csv') -NoTypeInformation -Encoding utf8

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
    'Azure service categories' = $serviceSummary.Count
    'Workloads documented' = $workloadScopes.Count
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
    'Compute and container resources' = $computeContainerRows.Count
    'App and integration resources' = $appIntegrationRows.Count
    'Database and data resources' = $databaseDataRows.Count
    'AI and machine learning resources' = $aiRows.Count
    'Storage and messaging resources' = $storageMessagingRows.Count
    'Workloads documented' = $workloadScopes.Count
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
    'Connected devices shown in topology' = $networkTopologyModel.ConnectedDevices.Count
    'Disconnected or unresolved records' = $networkTopologyModel.DisconnectedDevices.Count
    'Network best-practice review candidates' = $networkFindings.Count
}))

## Connected network topology

> The diagram shows configuration-based connectivity. Blue lines represent VNet peerings in `Connected` state. Green device boxes are attached through a collected subnet reference. IP labels are taken from NIC, frontend IP, gateway, firewall, Private Endpoint, and Public IP configuration evidence.

$networkTopologySvg

## Connected devices and IP addresses

$(New-MarkdownTable $networkTopologyModel.ConnectedDevices ([ordered]@{
    'Device' = { param($r) $r.Name }
    'Type' = { param($r) $r.Type }
    'VNet' = { param($r) $r.VNet }
    'Subnet' = { param($r) $r.Subnet }
    'Private IPs' = { param($r) $r.PrivateIps }
    'Public IPs' = { param($r) $r.PublicIps }
    'Region' = { param($r) $r.Region }
}) -EmptyMessage 'No connected network devices could be derived from the collected relationships.')

## Disconnected, unassociated, or unresolved devices

> These records are intentionally excluded from the connected topology. A disconnected peering can indicate a deleted or unavailable remote VNet, incomplete bidirectional configuration, permissions/scope gaps, or an in-progress deployment. Validate before treating it as a confirmed outage.

$(New-MarkdownTable $networkTopologyModel.DisconnectedDevices ([ordered]@{
    'Device or link' = { param($r) $r.Name }
    'Type' = { param($r) $r.Type }
    'IP addresses' = { param($r) $r.IpAddresses }
    'Related to' = { param($r) $r.RelatedTo }
    'State' = { param($r) $r.State }
    'Reason' = { param($r) $r.Reason }
}) -EmptyMessage 'No disconnected or unresolved network records were identified.')

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

$workloadBody = if ($workloadScopes.Count -gt 0) {
@"
## Workload overview

$(New-MetricList ([ordered]@{
    'Workloads documented' = $workloadScopes.Count
    'Workload resource records' = $workloadResourceRecords.Count
    'Critical workloads' = @($workloadScopes | Where-Object { $_.criticality -match 'critical' }).Count
}))

$(New-MarkdownTable $workloadScopes ([ordered]@{
    'Workload' = { param($r) $r.name }
    'Business purpose' = { param($r) $r.businessPurpose }
    'Owner' = { param($r) $r.owner }
    'Criticality' = { param($r) $r.criticality }
    'RTO' = { param($r) $r.rto }
    'RPO' = { param($r) $r.rpo }
    'Subscription ID' = { param($r) $r.subscriptionId }
    'Resource groups' = { param($r) @($r.resourceGroups) -join '; ' }
    'Regions' = { param($r) @($r.regions) -join '; ' }
}))

## Workload resource types

$(New-MarkdownTable @(
    $workloadResourceRecords | Group-Object type | Sort-Object Count -Descending |
        ForEach-Object { [pscustomobject]@{ Type = $_.Name; Resources = $_.Count } }
) ([ordered]@{
    'Resource type' = { param($r) $r.Type }
    'Resources' = { param($r) $r.Resources }
}) -Limit $Top)

Validate application dependencies, data classification, external services, recovery tests, operational ownership, and WAF/WARA conclusions with workload owners.
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

$serviceEstateBody = @"
## Estate coverage

$(New-MetricList ([ordered]@{
    'Azure resources classified' = $serviceRows.Count
    'Service categories represented' = $serviceSummary.Count
    'Resource types represented' = @($serviceRows | ForEach-Object { $_.Type } | Sort-Object -Unique).Count
    'Subscriptions represented' = @($serviceRows | ForEach-Object { $_.SubscriptionId } | Sort-Object -Unique).Count
    'Regions represented' = @($serviceRows | ForEach-Object { $_.Region } | Where-Object { $_ } | Sort-Object -Unique).Count
    'Resources reporting public network access enabled' = @($serviceRows | Where-Object PublicNetworkAccess -eq 'Enabled').Count
}))

## Azure service categories

$(New-MarkdownTable $serviceSummary ([ordered]@{
    'Category' = { param($r) $r.Category }
    'Resources' = { param($r) $r.Resources }
    'Subscriptions' = { param($r) $r.Subscriptions }
    'Regions' = { param($r) $r.Regions }
    'Public access enabled' = { param($r) $r.PublicAccessEnabled }
    'Private Endpoints' = { param($r) $r.PrivateEndpoints }
}))

## Top resource types

$(New-MarkdownTable $resourceTypes ([ordered]@{
    'Resource type' = { param($r) $r.Type }
    'Resources' = { param($r) $r.Count }
}) -Limit $Top)

## Coverage guide

- [Compute and Containers](14-compute-and-containers.md)
- [App Services and Integration](15-app-services-and-integration.md)
- [Databases and Data Platforms](16-databases-and-data.md)
- [AI and Machine Learning](17-ai-and-machine-learning.md)
- [Storage, Messaging, and Events](18-storage-and-messaging.md)
- [Network Architecture](06-network.md)
- [Security Posture](07-security.md)
- [Operations and Monitoring](08-operations.md)
- [Resilience and Recovery](09-resilience.md)
- [Cost Optimization](10-cost.md)

This is a configuration inventory overview. Service-specific conclusions require validation against approved architecture, business criticality, runtime telemetry, data classification, recovery objectives, and current Microsoft service guidance.
"@
Write-DocumentationPage '13-service-estate' 'Azure Service Estate' $serviceEstateBody

Write-DocumentationPage '14-compute-and-containers' 'Compute and Containers' (
    New-ServiceInventoryBody -Rows $computeContainerRows `
        -ScopeDescription 'Covers virtual machines, disks, scale sets, AKS, Container Apps, Container Instances, managed environments, and related compute/container resources.' `
        -ValidationGuidance 'Validate supported images and runtimes, patching, disk encryption, managed identity, endpoint exposure, autoscaling, availability zones, node-pool design, upgrade policy, backup, Defender coverage, and capacity against workload requirements.' `
        -Limit $Top
)

Write-DocumentationPage '15-app-services-and-integration' 'App Services and Integration' (
    New-ServiceInventoryBody -Rows $appIntegrationRows `
        -ScopeDescription 'Covers App Service, Functions, plans, Static Web Apps, API Management, Logic Apps, and Data Factory resources.' `
        -ValidationGuidance 'Validate HTTPS-only and TLS settings, authentication, managed identity, VNet integration, Private Endpoints, access restrictions, health checks, Always On, deployment slots, scaling, runtime support, API policies, integration dependencies, diagnostics, and recovery design.' `
        -Limit $Top
)

Write-DocumentationPage '16-databases-and-data' 'Databases and Data Platforms' (
    New-ServiceInventoryBody -Rows $databaseDataRows `
        -ScopeDescription 'Covers Azure SQL, PostgreSQL, MySQL, Cosmos DB, Redis, Synapse, Databricks, and related database/data resources.' `
        -ValidationGuidance 'Validate Microsoft Entra authentication, local authentication restrictions, TLS, firewall and private access, auditing, Defender, encryption and key ownership, backup retention, geo-replication, failover, zone redundancy, capacity, maintenance windows, data residency, and tested recovery.' `
        -Limit $Top
)

Write-DocumentationPage '17-ai-and-machine-learning' 'AI and Machine Learning' (
    New-ServiceInventoryBody -Rows $aiRows `
        -ScopeDescription 'Covers Azure AI Services and OpenAI accounts, model-hosting resources, Azure Machine Learning, Azure AI Search, and Bot Service.' `
        -ValidationGuidance 'Validate key-based versus managed-identity authentication, private networking, approved outbound access, model deployments and quotas, content filtering, responsible-AI controls, data handling, prompt and response logging, AI Search replicas/partitions, workspace encryption, endpoint exposure, monitoring, and business continuity.' `
        -Limit $Top
)

Write-DocumentationPage '18-storage-and-messaging' 'Storage, Messaging, and Events' (
    New-ServiceInventoryBody -Rows $storageMessagingRows `
        -ScopeDescription 'Covers Storage accounts, Service Bus, Event Hubs, Event Grid, Relay, Notification Hubs, and related messaging/event resources.' `
        -ValidationGuidance 'Validate public access, firewall defaults, Private Endpoints, shared-key restrictions, minimum TLS, encryption and customer-managed keys, soft delete and versioning, replication, immutability, namespace authorization, local/SAS authentication, zone redundancy, geo-disaster recovery, retention, throughput, dead-letter handling, diagnostics, and consumer recovery.' `
        -Limit $Top
)

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
    ServiceCategories = $serviceSummary.Count
    ComputeAndContainerResources = $computeContainerRows.Count
    AppAndIntegrationResources = $appIntegrationRows.Count
    DatabaseAndDataResources = $databaseDataRows.Count
    AiAndMachineLearningResources = $aiRows.Count
    StorageAndMessagingResources = $storageMessagingRows.Count
    Workloads = $workloadScopes.Count
    ReviewCandidates = $observations.Count
    NetworkReviewCandidates = $networkFindings.Count
    ConnectedNetworkDevices = $networkTopologyModel.ConnectedDevices.Count
    DisconnectedNetworkRecords = $networkTopologyModel.DisconnectedDevices.Count
    NetworkTopologyData = Join-Path $documentationRoot 'network-topology.json'
    DisconnectedNetworkCsv = Join-Path $documentationRoot 'network-disconnected-devices.csv'
    EntryPoint = Join-Path $htmlRoot 'index.html'
}
ConvertTo-Json -InputObject $metadata -Depth 10 |
    Set-Content -LiteralPath (Join-Path $documentationRoot 'documentation-metadata.json') -Encoding utf8

Write-Host "Documentation generated: $(Join-Path $htmlRoot 'index.html')" -ForegroundColor Green
Write-Host "Markdown source: $markdownRoot"
