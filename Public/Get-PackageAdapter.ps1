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
        [object]$Manifest,

        [Parameter()]
        [switch]$ShowCard,

        [Parameter()]
        [switch]$CopyReceipt
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

    $adapter = switch ($normalized) {
        'msi' {
            $silent = if ($customSilentArgs) { $customSilentArgs } else { '/qn REBOOT=ReallySuppress' }
            [PSCustomObject]@{
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
            [PSCustomObject]@{
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
            [PSCustomObject]@{
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
            [PSCustomObject]@{
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
            [PSCustomObject]@{
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
        'electron' {
            $silent = if ($customSilentArgs) { $customSilentArgs } else { '--allusers --force-install /silent /VERYSILENT /SUPPRESSMSGBOXES /NORESTART' }
            [PSCustomObject]@{
                InstallerType        = 'electron'
                SilentArgs           = $silent
                InstallCommandLine   = 'powershell.exe -ExecutionPolicy Bypass -File .\Install.ps1'
                UninstallCommandLine = 'powershell.exe -ExecutionPolicy Bypass -File .\Uninstall.ps1'
                DetectionStrategy    = 'FileVersionOrRegistry'
                SuccessCodes         = $successCodes
                SupportedUnderSystem = $true
                Notes                = 'Electron / Squirrel Framework Installer (--allusers and AppData redirection)'
            }
        }
        'chromium' {
            $silent = if ($customSilentArgs) { $customSilentArgs } else { '--system-level --allusers --force-install /silent /qn' }
            [PSCustomObject]@{
                InstallerType        = 'chromium'
                SilentArgs           = $silent
                InstallCommandLine   = 'powershell.exe -ExecutionPolicy Bypass -File .\Install.ps1'
                UninstallCommandLine = 'powershell.exe -ExecutionPolicy Bypass -File .\Uninstall.ps1'
                DetectionStrategy    = 'RegistryDisplayVersion'
                SuccessCodes         = $successCodes
                SupportedUnderSystem = $true
                Notes                = 'Chromium-based Application Installer (--system-level / silent)'
            }
        }
        'msix' {
            [PSCustomObject]@{
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
            [PSCustomObject]@{
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

    if ($ShowCard) {
        $codesText = ($adapter.SuccessCodes -join ', ')
        $sysBadge = if ($adapter.SupportedUnderSystem) { '[SYSTEM READY]' } else { '[USER CONTEXT]' }
        Write-Host ""
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host ("  | WINGET INTUNE ADAPTER SPECIFICATION                 {0,16} |" -f $sysBadge) -ForegroundColor Cyan
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host ("  | Installer Type : {0,-51} |" -f $adapter.InstallerType.ToUpperInvariant()) -ForegroundColor White
        Write-Host ("  | Detection Mode : {0,-51} |" -f $adapter.DetectionStrategy) -ForegroundColor Green
        Write-Host ("  | Silent Args    : {0,-51} |" -f $(if ($adapter.SilentArgs) { $adapter.SilentArgs } else { '<none>' })) -ForegroundColor Yellow
        Write-Host ("  | Success Codes  : {0,-51} |" -f $codesText) -ForegroundColor Gray
        Write-Host ("  | Notes          : {0,-51} |" -f $adapter.Notes) -ForegroundColor DarkGray
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host ""
    }

    if ($CopyReceipt) {
        try {
            $codesStr = ($adapter.SuccessCodes -join ', ')
            $silentStr = if ($adapter.SilentArgs) { $adapter.SilentArgs } else { '<none>' }
            $mdAdapter = @(
                "### WingetIntune Installer Adapter Specification"
                ""
                "| Field | Value |"
                "| :--- | :--- |"
                "| **Installer Type** | ``$($adapter.InstallerType.ToUpperInvariant())`` |"
                "| **Detection Strategy** | ``$($adapter.DetectionStrategy)`` |"
                "| **Silent Arguments** | ``$silentStr`` |"
                "| **Install Command** | ``$($adapter.InstallCommandLine)`` |"
                "| **Uninstall Command** | ``$($adapter.UninstallCommandLine)`` |"
                "| **Success Codes** | ``$codesStr`` |"
                "| **SYSTEM Supported** | ``$($adapter.SupportedUnderSystem)`` |"
                "| **Notes** | $($adapter.Notes) |"
            ) -join "`r`n"
            Set-Clipboard -Value $mdAdapter -ErrorAction Stop
            Write-Host "  [CLIPBOARD] Winget Intune Adapter Specification (Markdown) copied to clipboard." -ForegroundColor Green
        } catch { }
    }

    return $adapter
}
