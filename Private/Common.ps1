Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [version]'7.3') {
    throw "PowerShell 7.3 or later is required. Current version: $($PSVersionTable.PSVersion). Run the collector with 'pwsh', not 'powershell.exe'."
}

function Initialize-CollectionContext {
    param(
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SubscriptionId
    )

    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
    $effectiveSubscriptionId = @($SubscriptionId)
    $scopePath = Join-Path $OutputRoot '00-prerequisites\collection-scope.json'
    if ($effectiveSubscriptionId.Count -eq 0 -and (Test-Path -LiteralPath $scopePath)) {
        $savedScope = Get-Content -LiteralPath $scopePath -Raw | ConvertFrom-Json
        $effectiveSubscriptionId = @($savedScope.Subscriptions)
    }

    $script:CollectionContext = [ordered]@{
        OutputRoot     = $OutputRoot
        SubscriptionId = $effectiveSubscriptionId
        ErrorPath      = Join-Path $OutputRoot '_collection-errors.csv'
        LogPath        = Join-Path $OutputRoot '_collection.log'
    }
}

function Write-CollectionLog {
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )

    $entry = '{0:u} [{1}] {2}' -f (Get-Date), $Level, $Message
    Write-Host $entry
    Add-Content -LiteralPath $script:CollectionContext.LogPath -Value $entry -Encoding utf8
}

function Add-CollectionError {
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][string]$Message,
        [bool]$Required = $false
    )

    [pscustomobject]@{
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        Stage        = $Stage
        Item         = $Item
        Required     = $Required
        Error        = $Message
    } | Export-Csv -LiteralPath $script:CollectionContext.ErrorPath -NoTypeInformation -Append -Encoding utf8

    Write-CollectionLog -Level ERROR -Message "[$Stage/$Item] $Message"
}

function Save-Json {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()]$Data,
        [Parameter(Mandatory)][string]$Path
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    ConvertTo-Json -InputObject $Data -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Invoke-AzCliJson {
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$OutputPath,
        [bool]$Required = $false
    )

    Write-CollectionLog -Level INFO -Message "Collecting $Name"
    $allArguments = @($Arguments) + @('--only-show-errors', '--output', 'json')
    $output = & az @allArguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        Add-CollectionError -Stage $Stage -Item $Name -Message ($output -join [Environment]::NewLine) -Required $Required
        if ($Required) {
            throw "Required collection '$Name' failed."
        }
        return $null
    }

    try {
        $data = ($output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 100 -NoEnumerate
        Save-Json -Data $data -Path $OutputPath
        return $data
    }
    catch {
        Add-CollectionError -Stage $Stage -Item $Name -Message "Azure CLI returned invalid JSON: $($_.Exception.Message)" -Required $Required
        if ($Required) {
            throw
        }
        return $null
    }
}

function Invoke-AzRestPaged {
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutputPath,
        [bool]$Required = $false,
        [switch]$CredentialMetadataOnly,
        [ValidateRange(1, 10)][int]$MaxAttempts = 3
    )

    Write-CollectionLog -Level INFO -Message "Collecting $Name"
    $items = [System.Collections.Generic.List[object]]::new()
    $nextUri = $Uri
    $tokenResource = if ($Uri.StartsWith('https://graph.microsoft.com/', [System.StringComparison]::OrdinalIgnoreCase)) {
        'https://graph.microsoft.com'
    }
    else {
        'https://management.azure.com'
    }
    $accessToken = & az account get-access-token --resource $tokenResource --query accessToken --output tsv --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) {
        Add-CollectionError -Stage $Stage -Item $Name -Message ($accessToken -join [Environment]::NewLine) -Required $Required
        if ($Required) {
            throw "Required collection '$Name' failed."
        }
        return $null
    }
    $headers = @{ Authorization = "Bearer $($accessToken -join '')" }

    while ($nextUri) {
        $attempt = 0
        do {
            $attempt++
            $shouldRetry = $false
            try {
                $page = Invoke-RestMethod -Method Get -Uri $nextUri -Headers $headers -TimeoutSec 120
                $requestError = $null
            }
            catch {
                $requestError = $_
                $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                $shouldRetry = $statusCode -eq 0 -or $statusCode -eq 408 -or $statusCode -eq 429 -or $statusCode -ge 500
                if ($shouldRetry -and $attempt -lt $MaxAttempts) {
                    Write-CollectionLog -Level WARN -Message "REST collection '$Name' attempt $attempt failed; retrying in $($attempt * 5) seconds."
                    Start-Sleep -Seconds ($attempt * 5)
                }
            }
        } while ($requestError -and $shouldRetry -and $attempt -lt $MaxAttempts)

        if ($requestError) {
            Add-CollectionError -Stage $Stage -Item $Name -Message $requestError.Exception.Message -Required $Required
            if ($Required) {
                throw "Required collection '$Name' failed."
            }
            return $null
        }

        $valueProperty = $page.PSObject.Properties['value']
        if ($null -ne $valueProperty) {
            foreach ($item in $valueProperty.Value) {
                if ($CredentialMetadataOnly) {
                    foreach ($credential in @($item.keyCredentials)) {
                        $credential.PSObject.Properties.Remove('key')
                    }
                    foreach ($credential in @($item.passwordCredentials)) {
                        $credential.PSObject.Properties.Remove('secretText')
                    }
                }
                $items.Add($item)
            }
            $odataNextLink = $page.PSObject.Properties['@odata.nextLink']
            $armNextLink = $page.PSObject.Properties['nextLink']
            $nextUri = if ($odataNextLink) { $odataNextLink.Value } elseif ($armNextLink) { $armNextLink.Value } else { $null }
        }
        else {
            $items.Add($page)
            $nextUri = $null
        }
    }

    $result = $items.ToArray()
    Save-Json -Data $result -Path $OutputPath
    return $result
}

function Invoke-AzGraphQuery {
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][string]$OutputPath,
        [bool]$Required = $false,
        [ValidateRange(1, 1000)][int]$PageSize = 500,
        [ValidateRange(1, 10)][int]$MaxAttempts = 3
    )

    Write-CollectionLog -Level INFO -Message "Collecting $Name"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $items = [System.Collections.Generic.List[object]]::new()
    $skipToken = $null
    $queryUri = 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01'

    do {
        $options = [ordered]@{
            '$top'              = $PageSize
            resultFormat        = 'objectArray'
            allowPartialScopes  = $true
        }
        if ($skipToken) {
            $options['$skipToken'] = $skipToken
        }

        $request = [ordered]@{
            subscriptions = @($script:CollectionContext.SubscriptionId)
            query         = $Query
            options       = $options
        }
        $requestPath = Join-Path ([System.IO.Path]::GetTempPath()) "alz-resource-graph-$([guid]::NewGuid().ToString('N')).json"
        $requestJson = ConvertTo-Json -InputObject $request -Depth 20 -Compress
        [System.IO.File]::WriteAllText($requestPath, $requestJson, [System.Text.UTF8Encoding]::new($false))

        $attempt = 0
        try {
            do {
                $attempt++
                $output = & az rest --method post --url $queryUri --headers 'Content-Type=application/json' `
                    --body "@$requestPath" --only-show-errors --output json 2>&1
                $succeeded = $LASTEXITCODE -eq 0
                if (-not $succeeded -and $attempt -lt $MaxAttempts) {
                    Write-CollectionLog -Level WARN -Message "Resource Graph query '$Name' attempt $attempt failed; retrying in $($attempt * 5) seconds."
                    Start-Sleep -Seconds ($attempt * 5)
                }
            } while (-not $succeeded -and $attempt -lt $MaxAttempts)
        }
        finally {
            Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue
        }

        if (-not $succeeded) {
            Add-CollectionError -Stage $Stage -Item $Name -Message ($output -join [Environment]::NewLine) -Required $Required
            if ($Required) {
                throw "Required collection '$Name' failed."
            }
            return $null
        }

        try {
            $page = ($output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 100 -NoEnumerate
            foreach ($item in $page.data) {
                $items.Add($item)
            }
            $dollarToken = $page.PSObject.Properties['$skipToken']
            $skipToken = if ($dollarToken) { $dollarToken.Value } else { $null }
        }
        catch {
            Add-CollectionError -Stage $Stage -Item $Name -Message "Resource Graph returned invalid JSON: $($_.Exception.Message)" -Required $Required
            if ($Required) {
                throw
            }
            return $null
        }
    } while ($skipToken)

    $result = $items.ToArray()
    Save-Json -Data $result -Path $OutputPath
    $stopwatch.Stop()
    Write-CollectionLog -Level INFO -Message "Collected $Name ($($result.Count) records in $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1)) seconds)"
    return $result
}

function Get-StageOutputPath {
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$FileName
    )

    $stagePath = Join-Path $script:CollectionContext.OutputRoot $Stage
    New-Item -ItemType Directory -Path $stagePath -Force | Out-Null
    return Join-Path $stagePath $FileName
}

function Get-Subscriptions {
    if ($script:CollectionContext.SubscriptionId.Count -gt 0) {
        return $script:CollectionContext.SubscriptionId
    }

    $accounts = @(Invoke-AzCliJson -Stage '00-prerequisites' -Name 'enabled-subscriptions' `
        -Arguments @('account', 'list', '--all') `
        -OutputPath (Get-StageOutputPath -Stage '00-prerequisites' -FileName 'subscriptions.json') `
        -Required $true)
    return @($accounts | Where-Object { $_.state -eq 'Enabled' } | ForEach-Object { $_.id })
}

function Invoke-ForEachSubscription {
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    foreach ($subscription in @(Get-Subscriptions)) {
        try {
            & $Action $subscription
        }
        catch {
            Add-CollectionError -Stage $Stage -Item "$Name/$subscription" -Message $_.Exception.Message
        }
    }
}
