# WingetIntune Module Loader
$sharedPsd1 = Join-Path (Split-Path $PSScriptRoot -Parent) 'IntuneShared\IntuneShared.psd1'
if (Test-Path $sharedPsd1) {
    Import-Module $sharedPsd1 -Global -Force -ErrorAction SilentlyContinue
}

$publicDir = Join-Path $PSScriptRoot 'Public'
$privateDir = Join-Path $PSScriptRoot 'Private'

$Public = @(Get-ChildItem -Path $publicDir -Filter '*.ps1' -ErrorAction SilentlyContinue)
$Private = @(Get-ChildItem -Path $privateDir -Filter '*.ps1' -ErrorAction SilentlyContinue)

foreach ($file in $Private) {
    . $file.FullName
}

foreach ($file in $Public) {
    . $file.FullName
}

Export-ModuleMember -Function @(
    'New-IntuneWingetPackage',
    'Publish-IntuneWingetApp',
    'Add-IntuneWingetAssignment',
    'New-IntuneRemediation',
    'Sync-IntuneWingetCatalog',
    'Get-PackageAdapter'
) -Alias @(
    'Publish-IntuneWin32App'
)
