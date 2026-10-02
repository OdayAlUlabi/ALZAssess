[CmdletBinding()]
param(
    [AllowEmptyCollection()][string[]]$SubscriptionId = @(),
    [string]$OutputPath = (Join-Path $PSScriptRoot ('output\{0:yyyyMMdd-HHmmss}' -f (Get-Date))),
    [string]$WorkloadConfigPath = (Join-Path $PSScriptRoot 'workloads.example.json'),
    [ValidateSet('Fast', 'Standard', 'Full')][string]$Profile = 'Standard',
    [ValidateRange(0, 10)][int]$StartAtStage = 0,
    [ValidateRange(0, 10)][int]$EndAtStage = 10,
    [switch]$Resume,
    [switch]$SkipDirectoryData,
    [switch]$SkipPerResourceDiagnostics,
    [switch]$FailOnCollectionError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null

$effectiveSkipDirectoryData = $SkipDirectoryData -or $Profile -eq 'Fast'
$effectiveSkipPerResourceDiagnostics = $SkipPerResourceDiagnostics -or $Profile -ne 'Full'

$runMetadata = [ordered]@{
    StartedUtc                 = (Get-Date).ToUniversalTime().ToString('o')
    RequestedSubscriptions     = $SubscriptionId
    WorkloadConfigPath         = $WorkloadConfigPath
    Profile                    = $Profile
    StartAtStage               = $StartAtStage
    EndAtStage                 = $EndAtStage
    Resume                     = [bool]$Resume
    SkipDirectoryData          = [bool]$effectiveSkipDirectoryData
    SkipPerResourceDiagnostics = [bool]$effectiveSkipPerResourceDiagnostics
    Host                       = $env:COMPUTERNAME
    PowerShellVersion          = $PSVersionTable.PSVersion.ToString()
    Stages                     = @()
}
$runMetadata | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $resolvedOutput '_run-metadata.json') -Encoding utf8

$stages = @(
    '00-Prerequisites.ps1',
    '01-TenantHierarchy.ps1',
    '02-ResourceGovernance.ps1',
    '03-Identity.ps1',
    '04-Network.ps1',
    '05-Security.ps1',
    '06-Operations.ps1',
    '07-Resilience.ps1',
    '08-CostOptimization.ps1',
    '09-Workloads.ps1',
    '10-BuildEvidenceIndex.ps1'
)

$selectedStages = for ($stageIndex = $StartAtStage; $stageIndex -le $EndAtStage; $stageIndex++) {
    [pscustomobject]@{ Index = $stageIndex; File = $stages[$stageIndex] }
}

foreach ($stage in $selectedStages) {
    $stageNumber = '{0:D2}' -f $stage.Index
    $markerPath = Join-Path $resolvedOutput "_stage-$stageNumber.complete.json"
    if ($Resume -and (Test-Path -LiteralPath $markerPath)) {
        Write-Host "`n=== Skipping completed stage $($stage.File) ===" -ForegroundColor DarkGray
        $runMetadata.Stages += [ordered]@{
            Stage  = $stage.Index
            File   = $stage.File
            Status = 'SkippedCompleted'
        }
        continue
    }

    $stagePath = Join-Path $PSScriptRoot "Scripts\$($stage.File)"
    Write-Host "`n=== Running $($stage.File) ===" -ForegroundColor Cyan
    $stageStarted = Get-Date
    try {
        & $stagePath -OutputRoot $resolvedOutput -SubscriptionId $SubscriptionId `
            -WorkloadConfigPath $WorkloadConfigPath `
            -SkipDirectoryData:$effectiveSkipDirectoryData `
            -SkipPerResourceDiagnostics:$effectiveSkipPerResourceDiagnostics

        $stageResult = [ordered]@{
            Stage           = $stage.Index
            File            = $stage.File
            Status          = 'Completed'
            StartedUtc      = $stageStarted.ToUniversalTime().ToString('o')
            CompletedUtc    = (Get-Date).ToUniversalTime().ToString('o')
            DurationSeconds = [math]::Round(((Get-Date) - $stageStarted).TotalSeconds, 1)
        }
        $stageResult | ConvertTo-Json | Set-Content -LiteralPath $markerPath -Encoding utf8
        $runMetadata.Stages += $stageResult
    }
    catch {
        $runMetadata.Stages += [ordered]@{
            Stage           = $stage.Index
            File            = $stage.File
            Status          = 'Failed'
            StartedUtc      = $stageStarted.ToUniversalTime().ToString('o')
            CompletedUtc    = (Get-Date).ToUniversalTime().ToString('o')
            DurationSeconds = [math]::Round(((Get-Date) - $stageStarted).TotalSeconds, 1)
            Error           = $_.Exception.Message
        }
        $runMetadata['CompletedUtc'] = (Get-Date).ToUniversalTime().ToString('o')
        $runMetadata | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $resolvedOutput '_run-metadata.json') -Encoding utf8
        throw
    }
}

$errorPath = Join-Path $resolvedOutput '_collection-errors.csv'
$errorCount = if (Test-Path -LiteralPath $errorPath) { @(Import-Csv -LiteralPath $errorPath).Count } else { 0 }

$runMetadata['CompletedUtc'] = (Get-Date).ToUniversalTime().ToString('o')
$runMetadata['CollectionErrorCount'] = $errorCount
$runMetadata | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $resolvedOutput '_run-metadata.json') -Encoding utf8

Write-Host "`nCollection completed: $resolvedOutput" -ForegroundColor Green
if ($errorCount -gt 0) {
    Write-Warning "$errorCount collection item(s) failed. Review $errorPath."
    if ($FailOnCollectionError) {
        exit 2
    }
}
