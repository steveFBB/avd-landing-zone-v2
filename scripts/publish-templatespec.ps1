<#
.SYNOPSIS
    Publishes the AVD landing zone as a Template Spec with its portal form.

.DESCRIPTION
    A Template Spec stores the compiled template in Azure. Attaching the
    uiFormDefinition gives it a Create blade in the portal, so the wizard is
    used instead of editing a .bicepparam file.

    VERSIONS ARE NOT IMMUTABLE. Microsoft's guidance is that you "can either
    update an existing version (for hotfixes) or publish a new version", and
    the version is just a text string — any scheme will do.

    So the default here is 'dev'. Publish over it as often as you like while
    iterating, and deploy from it. Pass -Version explicitly only when you have
    something worth keeping, and record that one in CHANGELOG.md.

    Cutting a numbered version for every change produces a long list of
    versions nobody will ever deploy from again.

    The Template Spec itself lives in an ordinary resource group. It has no
    connection to the resource groups the template later creates.

.EXAMPLE
    .\publish-templatespec.ps1 -Location northeurope

.EXAMPLE
    .\publish-templatespec.ps1 -Location westus -Version 1.1.0 -TemplateSpecResourceGroup rg-templatespecs
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Location,

    [string]$TemplateSpecResourceGroup = 'rg-templatespecs',

    [string]$TemplateSpecName = 'avd-landing-zone',

    [string]$Version = 'dev',

    [string]$DisplayName = 'AVD Landing Zone'
)

$ErrorActionPreference = 'Stop'

# Resolve paths relative to this script, so it runs from anywhere.
$repoRoot = Split-Path -Parent $PSScriptRoot
$mainBicep = Join-Path $repoRoot 'main.bicep'
$uiForm    = Join-Path $repoRoot 'uiFormDefinition.json'

foreach ($f in @($mainBicep, $uiForm)) {
    if (-not (Test-Path $f)) {
        throw "Not found: $f. Run this from the repository, with main.bicep and uiFormDefinition.json at the root."
    }
}

Write-Host "Subscription:" -NoNewline
az account show --query "{name:name, id:id}" --output tsv

Write-Host "`nCreating resource group '$TemplateSpecResourceGroup' if needed..."
az group create `
    --name $TemplateSpecResourceGroup `
    --location $Location `
    --output none

Write-Host "Publishing template spec '$TemplateSpecName' version $Version..."
az ts create `
    --name $TemplateSpecName `
    --version $Version `
    --resource-group $TemplateSpecResourceGroup `
    --location $Location `
    --display-name $DisplayName `
    --template-file $mainBicep `
    --ui-form-definition $uiForm `
    --yes `
    --output none

$specId = az ts show `
    --name $TemplateSpecName `
    --version $Version `
    --resource-group $TemplateSpecResourceGroup `
    --query id `
    --output tsv

Write-Host "`nPublished."
Write-Host "Template spec version ID:"
Write-Host "  $specId"
Write-Host "`nTo use it: Azure portal -> search 'Template specs' -> $TemplateSpecName -> Deploy."
Write-Host "The portal renders the wizard from uiFormDefinition.json rather than a plain parameter list."
