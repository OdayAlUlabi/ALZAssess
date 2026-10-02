# Contributing

Contributions are welcome.

## Before opening a pull request

1. Create a branch from `main`.
2. Keep changes focused on one collection or documentation concern.
3. Do not commit assessment output, tenant identifiers, credentials, tokens, or customer data.
4. Reuse the helpers in `Private\Common.ps1`.
5. Project only fields required for assessment evidence.
6. Update the evidence catalog when outputs change.
7. Validate PowerShell syntax and the example JSON.

## Local validation

```powershell
$errors = @()

Get-ChildItem -Filter '*.ps1' -Recurse |
  ForEach-Object {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
      $_.FullName,
      [ref]$tokens,
      [ref]$parseErrors
    ) | Out-Null
    $errors += $parseErrors
  }

if ($errors.Count -gt 0) {
  $errors
  throw 'PowerShell syntax validation failed.'
}

Get-Content '.\workloads.example.json' -Raw |
  ConvertFrom-Json -ErrorAction Stop |
  Out-Null
```

## Pull request expectations

Describe:

- The assessment requirement being addressed
- New or changed permissions
- New evidence files or fields
- Security and privacy impact
- Validation performed

Do not include real assessment evidence in issues or pull requests.
