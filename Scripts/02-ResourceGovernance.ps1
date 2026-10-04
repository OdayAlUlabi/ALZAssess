param(
    [Parameter(Mandatory)][string]$OutputRoot,
    [AllowEmptyCollection()][string[]]$SubscriptionId = @(),
    [string]$WorkloadConfigPath,
    [switch]$SkipDirectoryData,
    [switch]$SkipPerResourceDiagnostics
)

. (Join-Path $PSScriptRoot '..\Private\Common.ps1')
Initialize-CollectionContext -OutputRoot $OutputRoot -SubscriptionId $SubscriptionId
$stage = '02-resource-governance'

Invoke-AzGraphQuery -Stage $stage -Name 'complete-resource-inventory' -Query @'
resources
| project id, name, type, subscriptionId, resourceGroup, location, kind, sku, zones,
          identityType=tostring(identity.type), tags,
          provisioningState=tostring(properties.provisioningState)
| order by subscriptionId asc, resourceGroup asc, type asc, name asc
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'resources.json') -Required $true | Out-Null

Invoke-AzGraphQuery -Stage $stage -Name 'resource-configurations' -Query @'
resources
| project id, name, type, subscriptionId, resourceGroup, location, kind, sku, zones,
          identity, tags, properties
| order by subscriptionId asc, resourceGroup asc, type asc, name asc
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'resource-configurations.json') | Out-Null

Invoke-AzGraphQuery -Stage $stage -Name 'resource-summary' -Query @'
resources
| summarize ResourceCount=count() by subscriptionId, type, location
| order by subscriptionId asc, ResourceCount desc
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'resource-summary.json') | Out-Null

Invoke-AzGraphQuery -Stage $stage -Name 'tag-coverage' -Query @'
resources
| extend tagCount=array_length(bag_keys(tags))
| project id, subscriptionId, resourceGroup, name, type, tags, tagCount
| order by tagCount asc
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'tag-coverage.json') | Out-Null

Invoke-AzGraphQuery -Stage $stage -Name 'policy-resources' -Query @'
policyresources
| project id, name, type, subscriptionId, resourceGroup, properties
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'policy-resources.json') | Out-Null

Invoke-AzGraphQuery -Stage $stage -Name 'policy-compliance-summary' -Query @'
policyresources
| where type =~ 'microsoft.policyinsights/policystates'
| extend complianceState=tostring(properties.complianceState)
| summarize Count=count() by subscriptionId, complianceState
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'policy-compliance-summary.json') | Out-Null

Invoke-ForEachSubscription -Stage $stage -Name 'subscription-governance' -Action {
    param($subscription)
    $suffix = $subscription
    Invoke-AzCliJson -Stage $stage -Name "policy-assignments-$suffix" `
        -Arguments @('policy', 'assignment', 'list', '--subscription', $subscription, '--disable-scope-strict-match') `
        -OutputPath (Get-StageOutputPath -Stage $stage -FileName "policy-assignments-$suffix.json") | Out-Null
    Invoke-AzCliJson -Stage $stage -Name "policy-exemptions-$suffix" `
        -Arguments @('policy', 'exemption', 'list', '--subscription', $subscription) `
        -OutputPath (Get-StageOutputPath -Stage $stage -FileName "policy-exemptions-$suffix.json") | Out-Null
    Invoke-AzCliJson -Stage $stage -Name "resource-locks-$suffix" `
        -Arguments @('lock', 'list', '--subscription', $subscription) `
        -OutputPath (Get-StageOutputPath -Stage $stage -FileName "resource-locks-$suffix.json") | Out-Null
}
