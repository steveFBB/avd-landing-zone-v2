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

.NOTES
    Every publish increments a build number, stamps it into the template spec's
    version description with a UTC timestamp and the git commit, and writes it to
    BUILD at the repository root. The version itself stays 'dev'; the build number
    is what tells you which code is actually in Azure.

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

    [string]$DisplayName = 'AVD Landing Zone',

    [int]$BuildNumber = 0
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

# --------------------------------------------------------------------------
# Build number
# --------------------------------------------------------------------------
# Every publish overwrites the same 'dev' version, so nothing in Azure says
# which build you are looking at. This increments a counter, stamps it into the
# version description, and writes it to BUILD at the repository root.
#
# The file is committed, so the number keeps going up across machines and
# matches what is in Azure. Pass -BuildNumber to set it explicitly.
$buildFile = Join-Path $repoRoot 'BUILD'

if ($BuildNumber -gt 0) {
    $build = $BuildNumber
} elseif (Test-Path $buildFile) {
    $previous = 0
    if (-not [int]::TryParse((Get-Content $buildFile -Raw).Trim(), [ref]$previous)) {
        throw "BUILD does not contain a number. Fix it, or pass -BuildNumber."
    }
    $build = $previous + 1
} else {
    $build = 1
}

$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')
$description = "build $build - published $stamp UTC"

# Include the commit when this is a git working copy, so a build number can be
# traced back to source. Silently skipped when git is absent or this is not a repo.
$commit = ''
try {
    $commit = (git -C $repoRoot rev-parse --short HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) { $commit = '' }
} catch { $commit = '' }

if ($commit) {
    $dirty = (git -C $repoRoot status --porcelain 2>$null)
    $suffix = if ($dirty) { ' (uncommitted changes)' } else { '' }
    $description = "$description - commit $commit$suffix"
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
    --version-description $description `
    --yes `
    --output none

# Written only after the publish succeeds, so a failed run does not burn a
# number and leave the file ahead of what is actually in Azure.
Set-Content -Path $buildFile -Value $build -NoNewline

$specId = az ts show `
    --name $TemplateSpecName `
    --version $Version `
    --resource-group $TemplateSpecResourceGroup `
    --query id `
    --output tsv

Write-Host "`nPublished build $build." -ForegroundColor Green
Write-Host "  $description"
Write-Host "Template spec version ID:"
Write-Host "  $specId"
Write-Host "`nTo use it: Azure portal -> search 'Template specs' -> $TemplateSpecName -> Deploy."
Write-Host "The portal renders the wizard from uiFormDefinition.json rather than a plain parameter list."
Write-Host "`nThe build number shows on the template spec's Versions blade, and with:"
Write-Host "  az ts show --name $TemplateSpecName --version $Version --resource-group $TemplateSpecResourceGroup --query description -o tsv"
