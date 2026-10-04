Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [version]'7.3') {
    throw "PowerShell 7.3 or later is required. Current version: $($PSVersionTable.PSVersion). Run the collector with 'pwsh', not 'powershell.exe'."
}

$script:ProhibitedEvidenceFieldNames = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
@(
    'secretText'
    'connectionString'
    'connectionStrings'
    'primaryConnectionString'
    'secondaryConnectionString'
    'sharedAccessKey'
    'sharedAccessKeyValue'
    'accountKey'
    'primaryKey'
    'secondaryKey'
    'clientSecret'
    'privateKey'
    'password'
    'accessToken'
    'authorization'
    'authorizationHeader'
    'sasToken'
    'sharedAccessSignature'
) | ForEach-Object { $script:ProhibitedEvidenceFieldNames.Add($_) | Out-Null }

function Test-ProhibitedEvidenceFieldName {
    param([Parameter(Mandatory)][string]$Name)

    return $script:ProhibitedEvidenceFieldNames.Contains($Name)
}

function Protect-SensitiveText {
    param([AllowEmptyString()][AllowNull()][string]$Text)

    if (-not $Text) {
        return $Text
    }

    $protected = $Text
    $fieldAlternation = ($script:ProhibitedEvidenceFieldNames |
        ForEach-Object { [regex]::Escape($_) }) -join '|'
    $assignmentPattern = "(?i)(?:[`"']?(?:$fieldAlternation)[`"']?\s*[:=]\s*)(?:`"[^`"]*`"|'[^']*'|[^\s,;]+)"
    $protected = [regex]::Replace($protected, $assignmentPattern, '[REDACTED]')
    $protected = [regex]::Replace($protected, '(?i)\bBearer\s+[A-Za-z0-9\-._~+/]+=*', 'Bearer [REDACTED]')
    $protected = [regex]::Replace(
        $protected,
        '(?is)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----',
        '[REDACTED PRIVATE KEY]'
    )
    return $protected
}

function Protect-EvidenceData {
    param([AllowNull()]$Data)

    if ($null -eq $Data) {
        return $null
    }
    if ($Data -is [string] -or $Data.GetType().IsPrimitive -or
        $Data -is [decimal] -or $Data -is [datetime] -or
        $Data -is [datetimeoffset] -or $Data -is [guid] -or
        $Data.GetType().IsEnum) {
        return $Data
    }
    if ($Data -is [System.Collections.IDictionary]) {
        $sanitized = [ordered]@{}
        foreach ($entry in $Data.GetEnumerator()) {
            $name = [string]$entry.Key
            if (-not (Test-ProhibitedEvidenceFieldName $name)) {
                $sanitized[$name] = Protect-EvidenceData $entry.Value
            }
        }
        return $sanitized
    }
    if ($Data -is [System.Collections.IEnumerable]) {
        $sanitizedItems = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Data) {
            $sanitizedItems.Add((Protect-EvidenceData $item))
        }
        return ,$sanitizedItems.ToArray()
    }

    $properties = @($Data.PSObject.Properties | Where-Object MemberType -in @('NoteProperty', 'Property'))
    if ($properties.Count -gt 0) {
        $sanitized = [ordered]@{}
        foreach ($property in $properties) {
            if (-not (Test-ProhibitedEvidenceFieldName $property.Name)) {
                $sanitized[$property.Name] = Protect-EvidenceData $property.Value
            }
        }
        return $sanitized
    }
    return $Data
}

function Get-ProhibitedEvidenceFields {
    param(
        [AllowNull()]$Data,
        [string]$Path = '$'
    )

    $findings = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Data -or $Data -is [string] -or $Data -is [System.ValueType]) {
        return $findings.ToArray()
    }
    if ($Data -is [System.Collections.IDictionary]) {
        foreach ($entry in $Data.GetEnumerator()) {
            $name = [string]$entry.Key
            $childPath = "$Path.$name"
            if (Test-ProhibitedEvidenceFieldName $name) {
                $findings.Add($childPath)
            }
            foreach ($finding in @(Get-ProhibitedEvidenceFields -Data $entry.Value -Path $childPath)) {
                $findings.Add($finding)
            }
        }
        return $findings.ToArray()
    }
    if ($Data -is [System.Collections.IEnumerable]) {
        $index = 0
        foreach ($item in $Data) {
            foreach ($finding in @(Get-ProhibitedEvidenceFields -Data $item -Path "$Path[$index]")) {
                $findings.Add($finding)
            }
            $index++
        }
        return $findings.ToArray()
    }
    foreach ($property in @($Data.PSObject.Properties | Where-Object MemberType -in @('NoteProperty', 'Property'))) {
        $childPath = "$Path.$($property.Name)"
        if (Test-ProhibitedEvidenceFieldName $property.Name) {
            $findings.Add($childPath)
        }
        foreach ($finding in @(Get-ProhibitedEvidenceFields -Data $property.Value -Path $childPath)) {
            $findings.Add($finding)
        }
    }
    return $findings.ToArray()
}

function Assert-NoProhibitedEvidenceData {
    param([Parameter(Mandatory)][string]$RootPath)

    $violations = [System.Collections.Generic.List[string]]::new()
    $jsonFiles = Get-ChildItem -LiteralPath $RootPath -File -Recurse -Filter '*.json' -ErrorAction Stop
    foreach ($file in $jsonFiles) {
        try {
            $data = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 100 -NoEnumerate
        }
        catch {
            throw "Unable to validate JSON evidence '$($file.FullName)': $($_.Exception.Message)"
        }
        foreach ($fieldPath in @(Get-ProhibitedEvidenceFields $data)) {
            $violations.Add("$($file.FullName):$fieldPath")
        }
    }

    $secretSignatures = @(
        '(?i)\bBearer\s+(?!\[REDACTED\])[A-Za-z0-9\-._~+/]{20,}=*'
        '(?is)-----BEGIN [A-Z ]*PRIVATE KEY-----'
        '(?i)(?:AccountKey|SharedAccessKey|ClientSecret|AccessToken|SecretText|ConnectionString)\s*[:=]\s*(?!\[REDACTED\])[^,;\r\n]{6,}'
    )
    $textFiles = Get-ChildItem -LiteralPath $RootPath -File -Recurse |
        Where-Object Extension -in @('.csv', '.log', '.txt', '.md', '.html')
    foreach ($file in $textFiles) {
        foreach ($pattern in $secretSignatures) {
            if (Select-String -LiteralPath $file.FullName -Pattern $pattern -Quiet) {
                $violations.Add("$($file.FullName):secret-value-signature")
                break
            }
        }
    }

    if ($violations.Count -gt 0) {
        throw "Prohibited sensitive data was detected. Evidence indexing stopped. Review: $($violations -join '; ')"
    }
}

function Protect-EvidenceFiles {
    param([Parameter(Mandatory)][string]$RootPath)

    $sanitizedFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $RootPath -File -Recurse -Filter '*.json' -ErrorAction Stop)) {
        try {
            $data = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 100 -NoEnumerate
        }
        catch {
            throw "Unable to sanitize JSON evidence '$($file.FullName)': $($_.Exception.Message)"
        }
        if (@(Get-ProhibitedEvidenceFields $data).Count -gt 0) {
            Save-Json -Data $data -Path $file.FullName
            $sanitizedFiles.Add($file.FullName)
        }
    }

    $textFiles = Get-ChildItem -LiteralPath $RootPath -File -Recurse |
        Where-Object Extension -in @('.csv', '.log', '.txt', '.md', '.html')
    foreach ($file in $textFiles) {
        $content = Get-Content -LiteralPath $file.FullName -Raw
        $protected = Protect-SensitiveText $content
        if ($protected -cne $content) {
            [System.IO.File]::WriteAllText(
                $file.FullName,
                $protected,
                [System.Text.UTF8Encoding]::new($false)
            )
            $sanitizedFiles.Add($file.FullName)
        }
    }
    return $sanitizedFiles.ToArray()
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

    $safeMessage = Protect-SensitiveText $Message
    $entry = '{0:u} [{1}] {2}' -f (Get-Date), $Level, $safeMessage
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
        Error        = Protect-SensitiveText $Message
    } | Export-Csv -LiteralPath $script:CollectionContext.ErrorPath -NoTypeInformation -Append -Encoding utf8

    Write-CollectionLog -Level ERROR -Message "[$Stage/$Item] $(Protect-SensitiveText $Message)"
}

function Save-Json {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()]$Data,
        [Parameter(Mandatory)][string]$Path
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $sanitizedData = Protect-EvidenceData $Data
    ConvertTo-Json -InputObject $sanitizedData -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8
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
        $result = Protect-EvidenceData $data
        Save-Json -Data $result -Path $OutputPath
        return $result
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

    $result = Protect-EvidenceData $items.ToArray()
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

    $result = Protect-EvidenceData $items.ToArray()
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
