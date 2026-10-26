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
        [switch]$CopyReceipt,

        [Parameter()]
        [switch]$CopyJson,

        [Parameter()]
        [switch]$CopyTsv,

        [Parameter()]
        [switch]$CopyCsv,

        [Parameter()]
        [switch]$CopyHtml
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
        Write-Host ("  [ADAPTER:{0}] [DETECTION:{1}] [SYSTEM:{2}] [CODES:{3}]" -f $adapter.InstallerType.ToUpperInvariant(), $adapter.DetectionStrategy, $adapter.SupportedUnderSystem, $codesText) -ForegroundColor Cyan
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

    if ($CopyJson) {
        try {
            $jsonAdapter = $adapter | ConvertTo-Json -Depth 4
            Set-Clipboard -Value $jsonAdapter -ErrorAction Stop
            Write-Host "  [CLIPBOARD] Winget Intune Adapter Specification (JSON) copied to clipboard." -ForegroundColor Green
        } catch { }
    }

    if ($CopyTsv) {
        try {
            $codesStr = ($adapter.SuccessCodes -join ', ')
            $tsvHeader = "InstallerType`tDetectionStrategy`tSilentArgs`tInstallCommandLine`tUninstallCommandLine`tSuccessCodes`tSupportedUnderSystem`tNotes"
            $tsvRow = "$($adapter.InstallerType)`t$($adapter.DetectionStrategy)`t$($adapter.SilentArgs)`t$($adapter.InstallCommandLine)`t$($adapter.UninstallCommandLine)`t$codesStr`t$($adapter.SupportedUnderSystem)`t$($adapter.Notes)"
            Set-Clipboard -Value ("$tsvHeader`r`n$tsvRow") -ErrorAction Stop
            Write-Host "  [CLIPBOARD] Winget Intune Adapter Specification (TSV) copied to clipboard." -ForegroundColor Green
        } catch { }
    }

    if ($CopyHtml) {
        try {
            $codesStr = ($adapter.SuccessCodes -join ', ')
            $silentStr = if ($adapter.SilentArgs) { $adapter.SilentArgs } else { '<none>' }
            $htmlAdapter = @(
                "<div style=`"font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:640px;background:#0f172a;color:#f8fafc;border:1px solid #334155;border-radius:8px;padding:16px;box-shadow:0 4px 6px -1px rgba(0,0,0,0.1);`">",
                "  <div style=`"display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #334155;padding-bottom:10px;margin-bottom:12px;`">",
                "    <h3 style=`"margin:0;color:#38bdf8;font-size:16px;font-weight:600;`">Winget Intune Adapter Specification</h3>",
                "    <span style=`"background:#166534;color:#4ade80;padding:2px 8px;border-radius:12px;font-size:12px;font-weight:600;`">$($adapter.InstallerType.ToUpperInvariant())</span>",
                "  </div>",
                "  <table style=`"width:100%;border-collapse:collapse;font-size:13px;`">",
                "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Installer Type</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;font-weight:600;`">$($adapter.InstallerType.ToUpperInvariant())</td></tr>",
                "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Detection Strategy</td><td style=`"padding:6px 0;text-align:right;color:#4ade80;`">$($adapter.DetectionStrategy)</td></tr>",
                "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Silent Arguments</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;font-family:monospace;`">$silentStr</td></tr>",
                "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Install Command</td><td style=`"padding:6px 0;text-align:right;color:#38bdf8;font-family:monospace;font-size:11px;`">$($adapter.InstallCommandLine)</td></tr>",
                "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Uninstall Command</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;font-family:monospace;font-size:11px;`">$($adapter.UninstallCommandLine)</td></tr>",
                "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Success Codes</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;`">$codesStr</td></tr>",
                "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">SYSTEM Supported</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;`">$($adapter.SupportedUnderSystem)</td></tr>",
                "    <tr><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Notes</td><td style=`"padding:6px 0;text-align:right;color:#94a3b8;font-size:12px;`">$($adapter.Notes)</td></tr>",
                "  </table>",
                "</div>"
            ) -join [Environment]::NewLine
            Set-Clipboard -Value $htmlAdapter -ErrorAction Stop
            Write-Host "  [CLIPBOARD] Winget Intune Adapter Specification (HTML) copied to clipboard." -ForegroundColor Green
        } catch { }
    }

    if ($CopyCsv) {
        try {
            $codesStr = ($adapter.SuccessCodes -join ', ')
            $csvAdapter = @(
                "InstallerType,DetectionStrategy,SilentArgs,InstallCommandLine,UninstallCommandLine,SuccessCodes,SupportedUnderSystem,Notes",
                "`"$($adapter.InstallerType)`",`"$($adapter.DetectionStrategy)`",`"$($adapter.SilentArgs)`",`"$($adapter.InstallCommandLine)`",`"$($adapter.UninstallCommandLine)`",`"$codesStr`",`"$($adapter.SupportedUnderSystem)`",`"$($adapter.Notes)`""
            ) -join "`r`n"
            Set-Clipboard -Value $csvAdapter -ErrorAction Stop
            Write-Host "  [CLIPBOARD] Winget Intune Adapter Specification (CSV) copied to clipboard." -ForegroundColor Green
        } catch { }
    }

    return $adapter
}
