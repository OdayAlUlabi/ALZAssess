param(
    [Parameter(Mandatory)][string]$OutputRoot,
    [AllowEmptyCollection()][string[]]$SubscriptionId = @(),
    [string]$WorkloadConfigPath,
    [switch]$SkipDirectoryData,
    [switch]$SkipPerResourceDiagnostics
)

. (Join-Path $PSScriptRoot '..\Private\Common.ps1')
Initialize-CollectionContext -OutputRoot $OutputRoot -SubscriptionId $SubscriptionId
$stage = '07-resilience'

Invoke-AzGraphQuery -Stage $stage -Name 'backup-and-site-recovery' -Query @'
resources
| where type startswith 'microsoft.recoveryservices/'
    or type startswith 'microsoft.dataprotection/'
| project id, name, type, subscriptionId, resourceGroup, location, sku, tags, properties
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'backup-site-recovery.json') | Out-Null

Invoke-AzGraphQuery -Stage $stage -Name 'availability-zone-configuration' -Query @'
resources
| project id, name, type, subscriptionId, resourceGroup, location, zones, sku,
          zoneRedundant=properties.zoneRedundant,
          highAvailability=properties.highAvailability,
          availabilitySet=properties.availabilitySet,
          properties
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'availability-configuration.json') | Out-Null

Invoke-AzGraphQuery -Stage $stage -Name 'advisor-reliability-recommendations' -Query @'
advisorresources
| where type =~ 'microsoft.advisor/recommendations'
| where tostring(properties.category) =~ 'HighAvailability'
| project id, subscriptionId, resourceId=properties.resourceMetadata.resourceId,
          impact=properties.impact, shortDescription=properties.shortDescription,
          recommendationTypeId=properties.recommendationTypeId, properties
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'advisor-reliability.json') | Out-Null

Invoke-AzGraphQuery -Stage $stage -Name 'resource-health' -Query @'
healthresources
| project id, name, type, subscriptionId, resourceGroup, properties
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'resource-health.json') | Out-Null
