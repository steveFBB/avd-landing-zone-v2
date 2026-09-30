<#
.SYNOPSIS
    One-time per-tenant setup: creates the managed identity the landing zone
    uses for Microsoft Entra ID work, and grants it the Graph permissions it
    needs.

.DESCRIPTION
    The Azure portal's deployment flow carries no Microsoft Graph token, so a
    template deployed from a Create blade cannot create Entra groups or finish
    the Entra Kerberos setup on the storage account. A deployment script running
    as a user-assigned managed identity can, because it holds an app-only Graph
    token of its own.

    This script creates that identity once. After it has run, the landing zone
    form takes the identity's resource ID as a parameter and everything else is
    automatic.

    WHO HAS TO RUN THIS
    Granting Microsoft Graph app roles specifically requires Privileged Role
    Administrator or Global Administrator - Application Administrator is not
    enough, which catches people out. Assigning Reader on the subscription also
    needs Owner or User Access Administrator there.

    WHAT IT GRANTS, AND WHY EACH ONE
      Group.ReadWrite.All                     create the AVD access groups, and
                                              read first so redeployment does
                                              not create duplicates
      Application.ReadWrite.All               add the kdc_enable_cloud_group_sids
                                              tag to the storage account's
                                              application
      DelegatedPermissionGrant.ReadWrite.All  grant admin consent on that
                                              application's permissions
      Reader (Azure RBAC, subscription)       not for the work itself. The
                                              deployment script container runs
                                              `az login --identity` before your
                                              script, and that fails when the
                                              identity can see no subscription.

    These are tenant-wide permissions. Read them before running this - they are
    not trivial, and they are the price of doing the Entra work from a portal
    blade rather than by hand.

.EXAMPLE
    .\bootstrap-entra-identity.ps1 -Location northeurope

.EXAMPLE
    .\bootstrap-entra-identity.ps1 -Location westus -IdentityName id-avd-ops -ResourceGroup rg-identity
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Location,

    [string]$ResourceGroup = 'rg-identity',

    [string]$IdentityName = 'id-avd-entra-ops',

    [switch]$SkipReaderAssignment
)

$ErrorActionPreference = 'Stop'

# ErrorActionPreference does not apply to native commands before PowerShell
# 7.3, so a failing `az` call returns a non-zero exit code and the script sails
# on with empty variables. Every az call below is checked with this instead -
# without it the script can print "Bootstrap complete" having granted nothing.
function Assert-LastExitCode {
    param([string]$What)
    if ($LASTEXITCODE -ne 0) {
        throw "$What failed with exit code $LASTEXITCODE."
    }
}

$graphAppId = '00000003-0000-0000-c000-000000000000'
$roles = @(
    'Group.ReadWrite.All',
    'Application.ReadWrite.All',
    'DelegatedPermissionGrant.ReadWrite.All'
)

Write-Host "Subscription:"
az account show --query "{name:name, id:id}" --output tsv

$subscriptionId = az account show --query id --output tsv
Assert-LastExitCode 'az account show'

Write-Host "`nCreating resource group '$ResourceGroup'..."
az group create --name $ResourceGroup --location $Location --output none
Assert-LastExitCode 'az group create'

Write-Host "Creating managed identity '$IdentityName'..."
az identity create `
    --name $IdentityName `
    --resource-group $ResourceGroup `
    --location $Location `
    --output none
Assert-LastExitCode 'az identity create'

$identityId = az identity show --name $IdentityName --resource-group $ResourceGroup --query id --output tsv
Assert-LastExitCode 'az identity show'

# The managed identity resource provider returns 'resourcegroups' in lower
# case. ARM does not care, but anything validating the ID against a
# case-sensitive pattern does - including the portal form - so normalise it
# here rather than leaving the operator to notice a single letter.
$identityId = $identityId -replace '/resourcegroups/', '/resourceGroups/'

$principalId = az identity show --name $IdentityName --resource-group $ResourceGroup --query principalId --output tsv
Assert-LastExitCode 'az identity show'

Write-Host "  resource ID: $identityId"
Write-Host "  principal ID: $principalId"

# Entra replicates the new service principal asynchronously. Granting an app
# role to a principal that has not replicated yet fails with a flat "resource
# does not exist", so wait rather than race it.
Write-Host "`nWaiting 30s for the identity to replicate in Entra ID..."
Start-Sleep -Seconds 30

$graphSpId = az ad sp show --id $graphAppId --query id --output tsv
Assert-LastExitCode 'az ad sp show (Microsoft Graph)'
Write-Host "Microsoft Graph service principal: $graphSpId"

foreach ($role in $roles) {
    # Resolve the app role ID by name at runtime. These GUIDs are stable and
    # published, but transcribing them by hand is a well-known way to grant the
    # wrong permission and not notice.
    $roleId = az ad sp show --id $graphAppId `
        --query "appRoles[?value=='$role' && contains(allowedMemberTypes,'Application')].id | [0]" `
        --output tsv

    if ([string]::IsNullOrWhiteSpace($roleId)) {
        throw "Could not resolve the Graph app role '$role'."
    }

    # No 2>$null here. Redirecting a native command's stderr in Windows
    # PowerShell turns az's routine WARNING lines into terminating errors under
    # ErrorActionPreference Stop, which would abort the bootstrap on the
    # idempotency check rather than skipping a role that is already granted.
    $existing = az rest --method GET `
        --url "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments" `
        --query "value[?appRoleId=='$roleId'] | [0].id" --output tsv

    if (-not [string]::IsNullOrWhiteSpace($existing) -and $existing -ne 'None') {
        Write-Host "  SKIP   $role (already assigned)"
        continue
    }

    $body = @{
        principalId = $principalId
        resourceId  = $graphSpId
        appRoleId   = $roleId
    } | ConvertTo-Json -Compress

    # The body goes through a temp file because quoting JSON through az on
    # Windows PowerShell is unreliable.
    $tempBody = New-TemporaryFile
    Set-Content -Path $tempBody -Value $body -Encoding utf8

    az rest --method POST `
        --url "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments" `
        --headers "Content-Type=application/json" `
        --body "@$tempBody" `
        --output none

    $grantExit = $LASTEXITCODE
    Remove-Item $tempBody -Force
    if ($grantExit -ne 0) {
        throw "Granting '$role' failed with exit code $grantExit. Granting Microsoft Graph app roles needs Global Administrator or Privileged Role Administrator."
    }

    Write-Host "  GRANT  $role"
}

if (-not $SkipReaderAssignment) {
    Write-Host "`nAssigning Reader on the subscription..."
    az role assignment create `
        --assignee-object-id $principalId `
        --assignee-principal-type ServicePrincipal `
        --role Reader `
        --scope "/subscriptions/$subscriptionId" `
        --output none
    Assert-LastExitCode 'az role assignment create (Reader)'
    Write-Host "  done"
}

Write-Host "`nBootstrap complete."
Write-Host "`nPaste this into the landing zone form, on the Entra ID tab."
Write-Host "Printed unindented on purpose - selecting an indented line picks up"
Write-Host "the leading spaces, which the form rejects without saying why:"
Write-Host ""
Write-Host $identityId
Write-Host "`nThe person who runs the deployment also needs Managed Identity Operator"
Write-Host "on that identity (Owner and Contributor on its resource group both include it)."
