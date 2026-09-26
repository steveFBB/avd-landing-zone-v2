<#
.SYNOPSIS
    Prints the resource ID of the Entra bootstrap managed identity, and copies
    it to the clipboard.

.DESCRIPTION
    The landing zone form asks for the managed identity's full resource ID on
    its Entra ID tab. That value is awkward to find in the portal and easy to
    confuse with the template spec's own resource ID, so this fetches it.

    Casing is normalised on the way out: the managed identity resource provider
    returns 'resourcegroups' in lower case, which ARM does not care about but
    which has tripped up validation before.

.EXAMPLE
    .\get-identity-id.ps1

.EXAMPLE
    .\get-identity-id.ps1 -IdentityName id-avd-entra-ops -ResourceGroup rg-identity
#>

[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-identity',
    [string]$IdentityName = 'id-avd-entra-ops'
)

$ErrorActionPreference = 'Stop'

$identityId = az identity show `
    --name $IdentityName `
    --resource-group $ResourceGroup `
    --query id `
    --output tsv

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($identityId)) {
    Write-Host ""
    Write-Host "No managed identity '$IdentityName' found in resource group '$ResourceGroup'." -ForegroundColor Yellow
    Write-Host "Create it with:  .\bootstrap-entra-identity.ps1 -Location <region>"
    exit 1
}

$identityId = $identityId -replace '/resourcegroups/', '/resourceGroups/'

try {
    Set-Clipboard -Value $identityId
    $copied = ' (copied to clipboard)'
} catch {
    # Set-Clipboard is unavailable in some hosts. Printing is the point; the
    # clipboard is a convenience.
    $copied = ''
}

Write-Host ""
Write-Host "Paste this into the landing zone form, on the Entra ID tab$copied`:"
Write-Host ""
Write-Host $identityId
Write-Host ""
