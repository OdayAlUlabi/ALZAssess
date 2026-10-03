param(
    [Parameter(Mandatory)][string]$OutputRoot,
    [AllowEmptyCollection()][string[]]$SubscriptionId = @(),
    [string]$WorkloadConfigPath,
    [switch]$SkipDirectoryData,
    [switch]$SkipPerResourceDiagnostics
)

. (Join-Path $PSScriptRoot '..\Private\Common.ps1')
Initialize-CollectionContext -OutputRoot $OutputRoot -SubscriptionId $SubscriptionId
$stage = '06-operations'

$operationsInventory = Invoke-AzGraphQuery -Stage $stage -Name 'monitoring-and-operations-resources' -Query @'
resources
| where type startswith 'microsoft.insights/'
    or type startswith 'microsoft.operationalinsights/'
    or type startswith 'microsoft.monitor/'
    or type startswith 'microsoft.alertsmanagement/'
    or type startswith 'microsoft.maintenance/'
    or type startswith 'microsoft.automation/'
    or type startswith 'microsoft.securityinsights/'
| project id, name, type, subscriptionId, resourceGroup, location, tags, properties
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'operations-resources.json')

Invoke-AzGraphQuery -Stage $stage -Name 'activity-log-alerts-and-action-groups' -Query @'
resources
| where type in~ (
    'microsoft.insights/activitylogalerts',
    'microsoft.insights/actiongroups',
    'microsoft.insights/metricalerts',
    'microsoft.insights/scheduledqueryrules',
    'microsoft.insights/datacollectionrules',
    'microsoft.insights/datacollectionendpoints')
| project id, name, type, subscriptionId, resourceGroup, location, properties
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'alerts-action-groups-dcrs.json') | Out-Null

Invoke-ForEachSubscription -Stage $stage -Name 'subscription-activity-log-settings' -Action {
    param($subscription)
    Invoke-AzCliJson -Stage $stage -Name "subscription-diagnostic-settings-$subscription" `
        -Arguments @('monitor', 'diagnostic-settings', 'subscription', 'list', '--subscription', $subscription) `
        -OutputPath (Get-StageOutputPath -Stage $stage -FileName "subscription-diagnostic-settings-$subscription.json") | Out-Null
}

if (-not $SkipPerResourceDiagnostics) {
    $resourceInventoryPath = Join-Path $OutputRoot '02-resource-governance\resources.json'
    if (-not (Test-Path -LiteralPath $resourceInventoryPath)) {
        Add-CollectionError -Stage $stage -Item 'per-resource-diagnostic-settings' -Message "Required inventory not found: $resourceInventoryPath"
    }
    else {
        $resources = @(Get-Content -LiteralPath $resourceInventoryPath -Raw | ConvertFrom-Json -Depth 100)
        $diagnostics = [System.Collections.Generic.List[object]]::new()
        $unsupportedResources = [System.Collections.Generic.List[object]]::new()
        $unsupportedTypes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $knownUnsupportedTypes = @(
            'microsoft.alertsmanagement/actionrules'
            'microsoft.alertsmanagement/smartdetectoralertrules'
            'microsoft.cdn/profiles/afdendpoints'
            'microsoft.compute/restorepointcollections'
            'microsoft.compute/virtualmachines/extensions'
            'microsoft.insights/actiongroups'
            'microsoft.insights/activitylogalerts'
            'microsoft.insights/metricalerts'
            'microsoft.insights/scheduledqueryrules'
            'microsoft.insights/workbooks'
            'microsoft.managedidentity/userassignedidentities'
            'microsoft.network/applicationgatewaywebapplicationfirewallpolicies'
            'microsoft.network/firewallpolicies'
            'microsoft.network/frontdoorwebapplicationfirewallpolicies'
            'microsoft.network/networkwatchers'
            'microsoft.network/privatednszones/virtualnetworklinks'
            'microsoft.network/routetables'
            'microsoft.operationsmanagement/solutions'
            'microsoft.security/automations'
        )
        foreach ($resourceType in $knownUnsupportedTypes) {
            $unsupportedTypes.Add($resourceType) | Out-Null
        }

        $accessToken = & az account get-access-token --resource 'https://management.azure.com' `
            --query accessToken --output tsv --only-show-errors 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to acquire an Azure Resource Manager access token: $($accessToken -join [Environment]::NewLine)"
        }
        $headers = @{ Authorization = "Bearer $($accessToken -join '')" }
        Write-CollectionLog -Level INFO -Message "Loaded $($knownUnsupportedTypes.Count) known resource types that do not support diagnostic settings."

        foreach ($resource in $resources) {
            $resourceType = if ($resource.type) { [string]$resource.type } else { '<unknown>' }
            if ($unsupportedTypes.Contains($resourceType)) {
                $unsupportedResources.Add([pscustomobject]@{
                    resourceId = $resource.id
                    type       = $resourceType
                    reason     = 'ResourceTypeNotSupported'
                })
                continue
            }

            $uri = "https://management.azure.com$($resource.id)/providers/microsoft.insights/diagnosticSettings?api-version=2021-05-01-preview"
            try {
                $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -TimeoutSec 120
                $settings = if ($response.PSObject.Properties['value']) { @($response.value) } else { $response }
                $diagnostics.Add([pscustomobject]@{
                    resourceId = $resource.id
                    settings   = $settings
                })
            }
            catch {
                $message = @(
                    $_.Exception.Message
                    $_.ErrorDetails.Message
                ) | Where-Object { $_ } | Join-String -Separator ([Environment]::NewLine)

                if ($message -match 'ResourceTypeNotSupported|does not support diagnostic settings') {
                    $unsupportedTypes.Add($resourceType) | Out-Null
                    $unsupportedResources.Add([pscustomobject]@{
                        resourceId = $resource.id
                        type       = $resourceType
                        reason     = 'ResourceTypeNotSupported'
                    })
                    Write-CollectionLog -Level INFO -Message "Skipping unsupported diagnostic-settings type: $resourceType"
                    continue
                }

                Add-CollectionError -Stage $stage -Item "diagnostic-settings/$($resource.id)" -Message $message
            }
        }
        Save-Json -Data $diagnostics.ToArray() `
            -Path (Get-StageOutputPath -Stage $stage -FileName 'resource-diagnostic-settings.json')
        Save-Json -Data $unsupportedResources.ToArray() `
            -Path (Get-StageOutputPath -Stage $stage -FileName 'resource-diagnostic-settings-unsupported.json')

        Write-CollectionLog -Level INFO -Message "Collected diagnostic settings for $($diagnostics.Count) resources; $($unsupportedResources.Count) resources matched an unsupported-type registry containing $($unsupportedTypes.Count) types."
    }
}
else {
    Write-CollectionLog -Level WARN -Message 'Per-resource diagnostic settings collection was skipped by request.'
}
