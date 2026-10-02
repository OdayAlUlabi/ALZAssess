param(
    [Parameter(Mandatory)][string]$OutputRoot,
    [AllowEmptyCollection()][string[]]$SubscriptionId = @(),
    [string]$WorkloadConfigPath,
    [switch]$SkipDirectoryData,
    [switch]$SkipPerResourceDiagnostics
)

. (Join-Path $PSScriptRoot '..\Private\Common.ps1')
Initialize-CollectionContext -OutputRoot $OutputRoot -SubscriptionId $SubscriptionId
$stage = '08-cost-optimization'

Invoke-AzGraphQuery -Stage $stage -Name 'advisor-cost-recommendations' -Query @'
advisorresources
| where type =~ 'microsoft.advisor/recommendations'
| where tostring(properties.category) =~ 'Cost'
| project id, subscriptionId, resourceId=properties.resourceMetadata.resourceId,
          impact=properties.impact, shortDescription=properties.shortDescription,
          extendedProperties=properties.extendedProperties,
          recommendationTypeId=properties.recommendationTypeId
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'advisor-cost.json') | Out-Null

Invoke-AzGraphQuery -Stage $stage -Name 'potential-orphan-resources' -Query @'
resources
| where (type =~ 'microsoft.compute/disks' and isempty(properties.managedBy))
    or (type =~ 'microsoft.network/networkinterfaces' and isempty(properties.virtualMachine))
    or (type =~ 'microsoft.network/publicipaddresses' and isempty(properties.ipConfiguration))
| project id, name, type, subscriptionId, resourceGroup, location, sku, tags, properties
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'potential-orphan-resources.json') | Out-Null

Invoke-ForEachSubscription -Stage $stage -Name 'budgets' -Action {
    param($subscription)
    Invoke-AzCliJson -Stage $stage -Name "budgets-$subscription" `
        -Arguments @('consumption', 'budget', 'list', '--subscription', $subscription) `
        -OutputPath (Get-StageOutputPath -Stage $stage -FileName "budgets-$subscription.json") | Out-Null
}
