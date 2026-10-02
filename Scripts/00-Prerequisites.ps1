param(
    [Parameter(Mandatory)][string]$OutputRoot,
    [AllowEmptyCollection()][string[]]$SubscriptionId = @(),
    [string]$WorkloadConfigPath,
    [switch]$SkipDirectoryData,
    [switch]$SkipPerResourceDiagnostics
)

. (Join-Path $PSScriptRoot '..\Private\Common.ps1')
Initialize-CollectionContext -OutputRoot $OutputRoot -SubscriptionId $SubscriptionId
$stage = '00-prerequisites'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required and was not found in PATH.'
}

$version = Invoke-AzCliJson -Stage $stage -Name 'azure-cli-version' -Arguments @('version') `
    -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'azure-cli-version.json') -Required $true

$account = Invoke-AzCliJson -Stage $stage -Name 'current-account' -Arguments @('account', 'show') `
    -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'current-account.json') -Required $true

Invoke-AzCliJson -Stage $stage -Name 'azure-cli-extensions' -Arguments @('extension', 'list') `
    -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'azure-cli-extensions.json') -Required $true | Out-Null

$subscriptions = @(Get-Subscriptions)
if ($subscriptions.Count -eq 0) {
    throw 'No enabled Azure subscriptions are visible to the signed-in identity.'
}

Save-Json -Data ([ordered]@{
    TenantId       = $account.tenantId
    SignedInAs     = $account.user.name
    Subscriptions  = $subscriptions
    DirectoryData  = -not $SkipDirectoryData
    Diagnostics    = -not $SkipPerResourceDiagnostics
}) -Path (Get-StageOutputPath -Stage $stage -FileName 'collection-scope.json')
