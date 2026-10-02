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

Invoke-AzGraphQuery -Stage $stage -Name 'network-topology-links' -Query @'
resources
| where type in~ (
    'microsoft.network/virtualnetworks',
    'microsoft.network/virtualnetworks/virtualnetworkpeerings',
    'microsoft.network/virtualhubs',
    'microsoft.network/virtualwans',
    'microsoft.network/expressroutecircuits',
    'microsoft.network/virtualnetworkgateways',
    'microsoft.network/connections',
    'microsoft.network/azurefirewalls',
    'microsoft.network/routetables',
    'microsoft.network/networksecuritygroups',
    'microsoft.network/privatednszones',
    'microsoft.network/dnsresolvers',
    'microsoft.network/ddosprotectionplans')
| project id, name, type, subscriptionId, resourceGroup, location, properties
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'network-topology.json') | Out-Null
