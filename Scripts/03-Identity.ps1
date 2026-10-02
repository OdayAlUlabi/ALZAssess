param(
    [Parameter(Mandatory)][string]$OutputRoot,
    [AllowEmptyCollection()][string[]]$SubscriptionId = @(),
    [string]$WorkloadConfigPath,
    [switch]$SkipDirectoryData,
    [switch]$SkipPerResourceDiagnostics
)

. (Join-Path $PSScriptRoot '..\Private\Common.ps1')
Initialize-CollectionContext -OutputRoot $OutputRoot -SubscriptionId $SubscriptionId
$stage = '03-identity'

Invoke-AzGraphQuery -Stage $stage -Name 'rbac-role-assignments' -Query @'
authorizationresources
| where type =~ 'microsoft.authorization/roleassignments'
| extend principalId=tostring(properties.principalId),
         principalType=tostring(properties.principalType),
         roleDefinitionId=tostring(properties.roleDefinitionId),
         scope=tostring(properties.scope),
         condition=tostring(properties.condition)
| project id, subscriptionId, principalId, principalType, roleDefinitionId, scope, condition, properties
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'rbac-role-assignments.json') | Out-Null

Invoke-AzGraphQuery -Stage $stage -Name 'rbac-role-definitions' -Query @'
authorizationresources
| where type =~ 'microsoft.authorization/roledefinitions'
| project id, name, subscriptionId, properties
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'rbac-role-definitions.json') | Out-Null

Invoke-AzGraphQuery -Stage $stage -Name 'managed-identities' -Query @'
resources
| where isnotempty(identity) or type =~ 'microsoft.managedidentity/userassignedidentities'
| project id, name, type, subscriptionId, resourceGroup, location, identity, properties
'@ -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'managed-identities.json') | Out-Null

if (-not $SkipDirectoryData) {
    $graphRoot = 'https://graph.microsoft.com/v1.0'
    Invoke-AzRestPaged -Stage $stage -Name 'directory-roles' `
        -Uri "$graphRoot/directoryRoles?`$select=id,displayName,roleTemplateId" `
        -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'directory-roles.json') | Out-Null
    Invoke-AzRestPaged -Stage $stage -Name 'directory-role-assignments' `
        -Uri "$graphRoot/roleManagement/directory/roleAssignments?`$select=id,principalId,roleDefinitionId,directoryScopeId" `
        -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'directory-role-assignments.json') | Out-Null
    Invoke-AzRestPaged -Stage $stage -Name 'pim-eligible-role-assignments' `
        -Uri "$graphRoot/roleManagement/directory/roleEligibilityScheduleInstances?`$select=id,principalId,roleDefinitionId,directoryScopeId,startDateTime,endDateTime,memberType" `
        -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'pim-eligible-role-assignments.json') | Out-Null
    Invoke-AzRestPaged -Stage $stage -Name 'conditional-access-policies' `
        -Uri "$graphRoot/identity/conditionalAccess/policies" `
        -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'conditional-access-policies.json') | Out-Null
    Invoke-AzRestPaged -Stage $stage -Name 'service-principals' `
        -Uri "$graphRoot/servicePrincipals?`$select=id,appId,displayName,accountEnabled,servicePrincipalType,appOwnerOrganizationId,keyCredentials,passwordCredentials" `
        -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'service-principals-credential-metadata.json') `
        -CredentialMetadataOnly | Out-Null
    Invoke-AzRestPaged -Stage $stage -Name 'applications' `
        -Uri "$graphRoot/applications?`$select=id,appId,displayName,signInAudience,keyCredentials,passwordCredentials" `
        -OutputPath (Get-StageOutputPath -Stage $stage -FileName 'applications-credential-metadata.json') `
        -CredentialMetadataOnly | Out-Null
}
else {
    Write-CollectionLog -Level WARN -Message 'Microsoft Graph directory evidence was skipped by request.'
}
