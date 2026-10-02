param(
    [Parameter(Mandatory)][string]$OutputRoot,
    [AllowEmptyCollection()][string[]]$SubscriptionId = @(),
    [string]$WorkloadConfigPath,
    [switch]$SkipDirectoryData,
    [switch]$SkipPerResourceDiagnostics
)

. (Join-Path $PSScriptRoot '..\Private\Common.ps1')
Initialize-CollectionContext -OutputRoot $OutputRoot -SubscriptionId $SubscriptionId
$stage = '10-evidence-index'

$files = Get-ChildItem -LiteralPath $OutputRoot -File -Recurse |
    Where-Object { $_.FullName -notlike '*\10-evidence-index\*' }

$index = foreach ($file in $files) {
    $relativePath = [System.IO.Path]::GetRelativePath($OutputRoot, $file.FullName)
    [pscustomobject]@{
        RelativePath    = $relativePath
        Stage           = ($relativePath -split '[\\/]')[0]
        SizeBytes       = $file.Length
        LastWriteUtc    = $file.LastWriteTimeUtc.ToString('o')
        Sha256          = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
}

$indexPath = Get-StageOutputPath -Stage $stage -FileName 'evidence-index.csv'
$index | Sort-Object Stage, RelativePath | Export-Csv -LiteralPath $indexPath -NoTypeInformation -Encoding utf8
Save-Json -Data $index -Path (Get-StageOutputPath -Stage $stage -FileName 'evidence-index.json')
