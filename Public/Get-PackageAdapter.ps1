<#
.SYNOPSIS
    Returns the type-safe Intune packaging adapter for a given installer type and manifest data.
.DESCRIPTION
    Maps Winget manifest InstallerType and InstallerSwitches to deterministic silent install switches,
    SYSTEM-context execution commands, and detection strategies.
#>
function Get-PackageAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$InstallerType,

        [Parameter()]
        [object]$Manifest
    )

    $normalized = $InstallerType.Trim().ToLowerInvariant()
    
    # Extract switches from manifest if available
    $customSilentArgs = ''
    $successCodes = @(0, 3010, 1641)
    $productCode = ''

    if ($Manifest) {
        if ($Manifest.InstallerSwitches -and $Manifest.InstallerSwitches.Silent) {
            $customSilentArgs = $Manifest.InstallerSwitches.Silent
        }
        if ($Manifest.InstallerSwitches -and $Manifest.InstallerSwitches.Custom) {
            $customSilentArgs += " $($Manifest.InstallerSwitches.Custom)"
        }
        if ($Manifest.InstallerSuccessCodes) {
            $successCodes = $Manifest.InstallerSuccessCodes
        }
        if ($Manifest.ProductCode) {
            $productCode = $Manifest.ProductCode
        }
    }

    switch ($normalized) {
        'msi' {
            $silent = if ($customSilentArgs) { $customSilentArgs } else { '/qn REBOOT=ReallySuppress' }
            return [PSCustomObject]@{
                InstallerType        = 'msi'
                SilentArgs           = $silent
                InstallCommandLine   = "msiexec.exe /i `"installer.msi`" $silent"
                UninstallCommandLine = if ($productCode) { "msiexec.exe /x `"$productCode`" /qn REBOOT=ReallySuppress" } else { "powershell.exe -ExecutionPolicy Bypass -File .\Uninstall.ps1" }
                DetectionStrategy    = 'MsiProductCode'
                SuccessCodes         = $successCodes
                ProductCode          = $productCode
                SupportedUnderSystem = $true
                Notes                = 'Standard Windows Installer MSI'
            }
        }
        'inno' {
            $silent = if ($customSilentArgs) { $customSilentArgs } else { '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' }
            return [PSCustomObject]@{
                InstallerType        = 'inno'
                SilentArgs           = $silent
                InstallCommandLine   = 'powershell.exe -ExecutionPolicy Bypass -File .\Install.ps1'
                UninstallCommandLine = 'powershell.exe -ExecutionPolicy Bypass -File .\Uninstall.ps1'
                DetectionStrategy    = 'RegistryDisplayVersion'
                SuccessCodes         = $successCodes
                SupportedUnderSystem = $true
                Notes                = 'Inno Setup Installer (Dynamic unins*.exe scanner)'
            }
        }
        'nullsoft' {
            $silent = if ($customSilentArgs) { $customSilentArgs } else { '/S' }
            return [PSCustomObject]@{
                InstallerType        = 'nullsoft'
                SilentArgs           = $silent
                InstallCommandLine   = 'powershell.exe -ExecutionPolicy Bypass -File .\Install.ps1'
                UninstallCommandLine = 'powershell.exe -ExecutionPolicy Bypass -File .\Uninstall.ps1'
                DetectionStrategy    = 'RegistryDisplayVersion'
                SuccessCodes         = $successCodes
                SupportedUnderSystem = $true
                Notes                = 'NSIS Nullsoft Installer (/S is case-sensitive)'
            }
        }
        'wix' {
            $silent = if ($customSilentArgs) { $customSilentArgs } else { '/quiet /norestart' }
            return [PSCustomObject]@{
                InstallerType        = 'wix'
                SilentArgs           = $silent
                InstallCommandLine   = 'powershell.exe -ExecutionPolicy Bypass -File .\Install.ps1'
                UninstallCommandLine = 'powershell.exe -ExecutionPolicy Bypass -File .\Uninstall.ps1'
                DetectionStrategy    = 'RegistryDisplayVersion'
                SuccessCodes         = $successCodes
                SupportedUnderSystem = $true
                Notes                = 'WiX Toolset Bootstrapper / Burn'
            }
        }
        'burn' {
            $silent = if ($customSilentArgs) { $customSilentArgs } else { '/quiet /norestart' }
            return [PSCustomObject]@{
                InstallerType        = 'burn'
                SilentArgs           = $silent
                InstallCommandLine   = 'powershell.exe -ExecutionPolicy Bypass -File .\Install.ps1'
                UninstallCommandLine = 'powershell.exe -ExecutionPolicy Bypass -File .\Uninstall.ps1'
                DetectionStrategy    = 'RegistryDisplayVersion'
                SuccessCodes         = $successCodes
                SupportedUnderSystem = $true
                Notes                = 'WiX Burn Chainer'
            }
        }
        'msix' {
            return [PSCustomObject]@{
                InstallerType        = 'msix'
                SilentArgs           = ''
                InstallCommandLine   = 'powershell.exe -ExecutionPolicy Bypass -File .\Install.ps1'
                UninstallCommandLine = 'powershell.exe -ExecutionPolicy Bypass -File .\Uninstall.ps1'
                DetectionStrategy    = 'AppxPackageIdentity'
                SuccessCodes         = @(0)
                SupportedUnderSystem = $true
                Notes                = 'MSIX Provisioned Package (DISM /Online /Add-ProvisionedAppxPackage)'
            }
        }
        Default {
            $silent = if ($customSilentArgs) { $customSilentArgs } else { '/silent /quiet /qn /S' }
            return [PSCustomObject]@{
                InstallerType        = 'exe'
                SilentArgs           = $silent
                InstallCommandLine   = 'powershell.exe -ExecutionPolicy Bypass -File .\Install.ps1'
                UninstallCommandLine = 'powershell.exe -ExecutionPolicy Bypass -File .\Uninstall.ps1'
                DetectionStrategy    = 'FileVersionOrRegistry'
                SuccessCodes         = $successCodes
                SupportedUnderSystem = $true
                Notes                = 'Generic Executable Installer'
            }
        }
    }
}
