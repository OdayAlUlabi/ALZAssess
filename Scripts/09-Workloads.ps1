param(
    [Parameter(Mandatory)][string]$OutputRoot,
    [AllowEmptyCollection()][string[]]$SubscriptionId = @(),
    [string]$WorkloadConfigPath,
    [switch]$SkipDirectoryData,
    [switch]$SkipPerResourceDiagnostics
)

. (Join-Path $PSScriptRoot '..\Private\Common.ps1')
Initialize-CollectionContext -OutputRoot $OutputRoot -SubscriptionId $SubscriptionId
$stage = '09-workloads'

if (-not (Test-Path -LiteralPath $WorkloadConfigPath)) {
    Add-CollectionError -Stage $stage -Item 'workload-config' -Message "Workload configuration not found: $WorkloadConfigPath"
    return
}

try {
    $config = Get-Content -LiteralPath $WorkloadConfigPath -Raw | ConvertFrom-Json -Depth 20
}
catch {
    throw "Invalid workload configuration '$WorkloadConfigPath': $($_.Exception.Message)"
}

foreach ($workload in $config.workloads) {
    if (-not $workload.name -or -not $workload.subscriptionId -or @($workload.resourceGroups).Count -eq 0) {
        Add-CollectionError -Stage $stage -Item 'workload-config' -Message 'Each workload requires name, subscriptionId, and at least one resource group.'
        continue
    }
    if ($workload.subscriptionId -eq '00000000-0000-0000-0000-000000000000') {
        Add-CollectionError -Stage $stage -Item 'workload-config' -Message "Workload '$($workload.name)' still uses the example subscription ID. Replace workloads.example.json values before collecting workload evidence."
        continue
    }

    $safeName = $workload.name -replace '[^A-Za-z0-9._-]', '-'
    $resourceGroups = @($workload.resourceGroups | ForEach-Object { "'$($_.Replace("'", "''"))'" }) -join ','
    $query = @"
resources
| where subscriptionId =~ '$($workload.subscriptionId)'
| where resourceGroup in~ ($resourceGroups)
| project id, name, type, subscriptionId, resourceGroup, location, zones, sku, identity, tags, properties
"@
    Invoke-AzGraphQuery -Stage $stage -Name "workload-$safeName" -Query $query `
        -OutputPath (Get-StageOutputPath -Stage $stage -FileName "$safeName-resources.json") | Out-Null

    Save-Json -Data ([ordered]@{
        name            = $workload.name
        businessPurpose = $workload.businessPurpose
        owner           = $workload.owner
        criticality     = $workload.criticality
        rto             = $workload.rto
        rpo             = $workload.rpo
        subscriptionId  = $workload.subscriptionId
        resourceGroups  = $workload.resourceGroups
        regions         = $workload.regions
        notes           = $workload.notes
    }) -Path (Get-StageOutputPath -Stage $stage -FileName "$safeName-scope.json")
}
