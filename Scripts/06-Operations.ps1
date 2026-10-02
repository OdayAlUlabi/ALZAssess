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
        $resources = Get-Content -LiteralPath $resourceInventoryPath -Raw | ConvertFrom-Json -Depth 100 -NoEnumerate
        $diagnostics = [System.Collections.Generic.List[object]]::new()
        foreach ($resource in $resources) {
            $output = & az monitor diagnostic-settings list --resource $resource.id --only-show-errors --output json 2>&1
            if ($LASTEXITCODE -ne 0) {
                Add-CollectionError -Stage $stage -Item "diagnostic-settings/$($resource.id)" -Message ($output -join [Environment]::NewLine)
                continue
            }
            try {
                $settings = ($output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 100 -NoEnumerate
                $diagnostics.Add([pscustomobject]@{
                    resourceId = $resource.id
                    settings   = $settings
                })
            }
            catch {
                Add-CollectionError -Stage $stage -Item "diagnostic-settings/$($resource.id)" -Message $_.Exception.Message
            }
        }
        Save-Json -Data $diagnostics.ToArray() `
            -Path (Get-StageOutputPath -Stage $stage -FileName 'resource-diagnostic-settings.json')
    }
}
else {
    Write-CollectionLog -Level WARN -Message 'Per-resource diagnostic settings collection was skipped by request.'
}
