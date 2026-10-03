param(
    [Parameter(Mandatory)][string]$OutputRoot,
    [AllowEmptyCollection()][string[]]$SubscriptionId = @(),
    [string]$WorkloadConfigPath,
    [switch]$SkipDirectoryData,
    [switch]$SkipPerResourceDiagnostics
)

. (Join-Path $PSScriptRoot '..\Private\Common.ps1')
Initialize-CollectionContext -OutputRoot $OutputRoot -SubscriptionId $SubscriptionId
$stage = '04-network'

Invoke-AzGraphQuery -Stage $stage -Name 'network-resources' -Query @'
resources
| where type startswith 'microsoft.network/'
    or type startswith 'microsoft.cdn/'
    or type startswith 'microsoft.networkcloud/'
| project id, name, type, subscriptionId, resourceGroup, location, zones, sku, tags, properties
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'network-resources.json') | Out-Null

Invoke-AzGraphQuery -Stage $stage -Name 'virtual-networks-and-subnets' -Query @'
resources
| where type =~ 'microsoft.network/virtualnetworks'
| mv-expand subnet=properties.subnets
| project vnetId=id, vnetName=name, subscriptionId, resourceGroup, location,
          vnetAddressSpace=properties.addressSpace.addressPrefixes,
          customDns=properties.dhcpOptions.dnsServers,
          ddosPlan=properties.ddosProtectionPlan,
          subnetName=tostring(subnet.name),
          subnetPrefix=subnet.properties.addressPrefix,
          subnetPrefixes=subnet.properties.addressPrefixes,
          nsgId=subnet.properties.networkSecurityGroup.id,
          routeTableId=subnet.properties.routeTable.id,
          privateEndpointPolicies=subnet.properties.privateEndpointNetworkPolicies,
          privateLinkServicePolicies=subnet.properties.privateLinkServiceNetworkPolicies
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'vnets-subnets.json') | Out-Null

Invoke-AzGraphQuery -Stage $stage -Name 'public-ip-exposure' -Query @'
resources
| where type =~ 'microsoft.network/publicipaddresses'
| project id, name, subscriptionId, resourceGroup, location, sku, zones,
          ipAddress=properties.ipAddress,
          allocationMethod=properties.publicIPAllocationMethod,
          ipConfigurationId=properties.ipConfiguration.id,
          dnsSettings=properties.dnsSettings,
          ddosSettings=properties.ddosSettings
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'public-ip-addresses.json') | Out-Null

Invoke-AzGraphQuery -Stage $stage -Name 'private-endpoints' -Query @'
resources
| where type =~ 'microsoft.network/privateendpoints'
| project id, name, subscriptionId, resourceGroup, location, properties
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'private-endpoints.json') | Out-Null

Invoke-AzGraphQuery -Stage $stage -Name 'network-security-rules' -Query @'
resources
| where type =~ 'microsoft.network/networksecuritygroups'
| mv-expand rule=properties.securityRules
| project nsgId=id, nsgName=name, subscriptionId, resourceGroup, location,
          ruleId=tostring(rule.id),
          ruleName=tostring(rule.name),
          priority=toint(rule.properties.priority),
          direction=tostring(rule.properties.direction),
          access=tostring(rule.properties.access),
          protocol=tostring(rule.properties.protocol),
          sourceAddressPrefix=tostring(rule.properties.sourceAddressPrefix),
          sourceAddressPrefixes=rule.properties.sourceAddressPrefixes,
          sourcePortRange=tostring(rule.properties.sourcePortRange),
          sourcePortRanges=rule.properties.sourcePortRanges,
          destinationAddressPrefix=tostring(rule.properties.destinationAddressPrefix),
          destinationAddressPrefixes=rule.properties.destinationAddressPrefixes,
          destinationPortRange=tostring(rule.properties.destinationPortRange),
          destinationPortRanges=rule.properties.destinationPortRanges
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'network-security-rules.json') | Out-Null

Invoke-AzGraphQuery -Stage $stage -Name 'route-table-routes' -Query @'
resources
| where type =~ 'microsoft.network/routetables'
| mv-expand route=properties.routes
| project routeTableId=id, routeTableName=name, subscriptionId, resourceGroup, location,
          disableBgpRoutePropagation=tobool(properties.disableBgpRoutePropagation),
          routeId=tostring(route.id),
          routeName=tostring(route.name),
          addressPrefix=tostring(route.properties.addressPrefix),
          nextHopType=tostring(route.properties.nextHopType),
          nextHopIpAddress=tostring(route.properties.nextHopIpAddress),
          hasBgpOverride=tobool(route.properties.hasBgpOverride)
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'route-table-routes.json') | Out-Null

Invoke-AzGraphQuery -Stage $stage -Name 'vnet-peerings' -Query @'
resources
| where type =~ 'microsoft.network/virtualnetworks'
| mv-expand peering=properties.virtualNetworkPeerings
| project vnetId=id, vnetName=name, subscriptionId, resourceGroup, location,
          peeringId=tostring(peering.id),
          peeringName=tostring(peering.name),
          peeringState=tostring(peering.properties.peeringState),
          remoteVnetId=tostring(peering.properties.remoteVirtualNetwork.id),
          allowVirtualNetworkAccess=tobool(peering.properties.allowVirtualNetworkAccess),
          allowForwardedTraffic=tobool(peering.properties.allowForwardedTraffic),
          allowGatewayTransit=tobool(peering.properties.allowGatewayTransit),
          useRemoteGateways=tobool(peering.properties.useRemoteGateways)
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'vnet-peerings.json') | Out-Null

Invoke-AzGraphQuery -Stage $stage -Name 'hybrid-connectivity' -Query @'
resources
| where type in~ (
    'microsoft.network/virtualnetworkgateways',
    'microsoft.network/connections',
    'microsoft.network/localnetworkgateways',
    'microsoft.network/expressroutecircuits',
    'microsoft.network/expressroutecircuits/peerings',
    'microsoft.network/expressroutegateways',
    'microsoft.network/virtualwans',
    'microsoft.network/virtualhubs')
| project id, name, type, subscriptionId, resourceGroup, location, sku, zones, properties
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'hybrid-connectivity.json') | Out-Null

Invoke-AzGraphQuery -Stage $stage -Name 'network-flow-logs' -Query @'
resources
| where type =~ 'microsoft.network/networkwatchers/flowlogs'
| project id, name, subscriptionId, resourceGroup, location,
          enabled=tobool(properties.enabled),
          targetResourceId=tostring(properties.targetResourceId),
          storageId=tostring(properties.storageId),
          format=properties.format,
          retentionPolicy=properties.retentionPolicy,
          flowAnalyticsConfiguration=properties.flowAnalyticsConfiguration
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'network-flow-logs.json') | Out-Null

Invoke-AzGraphQuery -Stage $stage -Name 'network-topology-links' -Query @'
resources
| where type in~ (
    'microsoft.network/virtualnetworks',
    'microsoft.network/virtualnetworks/virtualnetworkpeerings',
    'microsoft.network/virtualhubs',
    'microsoft.network/virtualwans',
    'microsoft.network/expressroutecircuits',
    'microsoft.network/expressroutecircuits/peerings',
    'microsoft.network/expressroutegateways',
    'microsoft.network/virtualnetworkgateways',
    'microsoft.network/connections',
    'microsoft.network/localnetworkgateways',
    'microsoft.network/azurefirewalls',
    'microsoft.network/firewallpolicies',
    'microsoft.network/routetables',
    'microsoft.network/networksecuritygroups',
    'microsoft.network/networkwatchers/flowlogs',
    'microsoft.network/privatednszones',
    'microsoft.network/dnsresolvers',
    'microsoft.network/ddosprotectionplans')
| project id, name, type, subscriptionId, resourceGroup, location, properties
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'network-topology.json') | Out-Null
