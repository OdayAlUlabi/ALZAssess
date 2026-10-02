param(
    [Parameter(Mandatory)][string]$OutputRoot,
    [AllowEmptyCollection()][string[]]$SubscriptionId = @(),
    [string]$WorkloadConfigPath,
    [switch]$SkipDirectoryData,
    [switch]$SkipPerResourceDiagnostics
)

. (Join-Path $PSScriptRoot '..\Private\Common.ps1')
Initialize-CollectionContext -OutputRoot $OutputRoot -SubscriptionId $SubscriptionId
$stage = '01-tenant-hierarchy'

Invoke-AzCliJson -Stage $stage -Name 'tenants' -Arguments @('account', 'tenant', 'list') `
    -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'tenants.json') | Out-Null
Invoke-AzCliJson -Stage $stage -Name 'management-groups' `
    -Arguments @('account', 'management-group', 'list') `
    -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'management-groups.json') | Out-Null
Invoke-AzCliJson -Stage $stage -Name 'subscriptions' -Arguments @('account', 'list', '--all') `
    -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'subscriptions.json') -Required $true | Out-Null

Invoke-ForEachSubscription -Stage $stage -Name 'resource-groups' -Action {
    param($subscription)
    Invoke-AzCliJson -Stage $stage -Name "resource-groups-$subscription" `
        -Arguments @('group', 'list', '--subscription', $subscription) `
        -OutputPath (Get-StageOutputPath -Stage $stage -FileName "resource-groups-$subscription.json") | Out-Null
}

Invoke-AzGraphQuery -Stage $stage -Name 'subscription-and-resource-group-containers' -Query @'
resourcecontainers
| where type in~ ('microsoft.management/managementgroups', 'microsoft.resources/subscriptions', 'microsoft.resources/subscriptions/resourcegroups')
| project id, name, type, subscriptionId, tenantId, location, tags, properties
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'resource-containers.json') | Out-Null
