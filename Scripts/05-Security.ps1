param(
    [Parameter(Mandatory)][string]$OutputRoot,
    [AllowEmptyCollection()][string[]]$SubscriptionId = @(),
    [string]$WorkloadConfigPath,
    [switch]$SkipDirectoryData,
    [switch]$SkipPerResourceDiagnostics
)

. (Join-Path $PSScriptRoot '..\Private\Common.ps1')
Initialize-CollectionContext -OutputRoot $OutputRoot -SubscriptionId $SubscriptionId
$stage = '05-security'

Invoke-AzGraphQuery -Stage $stage -Name 'defender-security-resources' -Query @'
securityresources
| project id, name, type, subscriptionId, resourceGroup, location, properties
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'security-resources.json') | Out-Null

Invoke-AzGraphQuery -Stage $stage -Name 'defender-assessments' -Query @'
securityresources
| where type =~ 'microsoft.security/assessments'
| extend status=tostring(properties.status.code),
         severity=tostring(properties.metadata.severity),
         displayName=tostring(properties.displayName),
         resourceId=tostring(properties.resourceDetails.Id)
| project id, subscriptionId, resourceId, displayName, status, severity, properties
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'defender-assessments.json') | Out-Null

Invoke-AzGraphQuery -Stage $stage -Name 'public-network-access' -Query @'
resources
| where tostring(properties.publicNetworkAccess) =~ 'Enabled'
    or tostring(properties.networkAcls.defaultAction) =~ 'Allow'
| project id, name, type, subscriptionId, resourceGroup, location,
          publicNetworkAccess=properties.publicNetworkAccess,
          networkDefaultAction=properties.networkAcls.defaultAction,
          properties
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'public-network-access.json') | Out-Null

Invoke-AzGraphQuery -Stage $stage -Name 'key-vaults' -Query @'
resources
| where type =~ 'microsoft.keyvault/vaults'
| project id, name, subscriptionId, resourceGroup, location, tags,
          enableRbacAuthorization=properties.enableRbacAuthorization,
          enablePurgeProtection=properties.enablePurgeProtection,
          enableSoftDelete=properties.enableSoftDelete,
          publicNetworkAccess=properties.publicNetworkAccess,
          networkAcls=properties.networkAcls,
          properties
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'key-vaults.json') | Out-Null

Invoke-ForEachSubscription -Stage $stage -Name 'defender-plans' -Action {
    param($subscription)
    $uri = "https://management.azure.com/subscriptions/$subscription/providers/Microsoft.Security/pricings?api-version=2024-01-01"
    Invoke-AzRestPaged -Stage $stage -Name "defender-plans-$subscription" -Uri $uri `
        -OutputPath (Get-StageOutputPath -Stage $stage -FileName "defender-plans-$subscription.json") | Out-Null
}
