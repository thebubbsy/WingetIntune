<#
.SYNOPSIS
    Converts a Winget package into a compiled Microsoft Intune Win32 App package (.intunewin).
.DESCRIPTION
    Uses real Winget manifest metadata, type-safe package adapters, and official IntuneWinAppUtil
    to compile production-ready Intune Win32 application packages.
.PARAMETER PackageId
    The Winget package identifier (e.g., 'Git.Git', 'Google.Chrome').
.PARAMETER OutputFolder
    Destination folder for the compiled .intunewin and script assets.
.PARAMETER CustomArgs
    Additional custom arguments to pass to installer.
.PARAMETER Scope
    Installation scope: 'machine' (default for Intune) or 'user'.
.PARAMETER Publish
    Immediately publish the compiled package to Microsoft Intune via Microsoft Graph.
.PARAMETER AssignTo
    Entra ID group names or IDs to assign the published app to.
.PARAMETER Intent
    Assignment intent: 'Required' (default) or 'Available'.
.EXAMPLE
    New-IntuneWingetPackage -PackageId "Git.Git" -OutputFolder ".\dist"
#>
function New-IntuneWingetPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$PackageId,

        [Parameter()]
        [string]$DisplayName = '',

        [Parameter()]
        [string]$OutputFolder = '',

        [Parameter()]
        [string]$CustomArgs = '',

        [Parameter()]
        [ValidateSet('machine', 'user')]
        [string]$Scope = 'machine',

        [Parameter()]
        [switch]$Publish,

        [Parameter()]
        [string[]]$AssignTo = @(),

        [Parameter()]
        [ValidateSet('Required', 'Available')]
        [string]$Intent = 'Required',

        [Parameter()]
        [switch]$CopyPublishCommand,

        [Parameter()]
        [switch]$CopyReceipt,

        [Parameter()]
        [switch]$CopyJson,

        [Parameter()]
        [switch]$CopyTsv,

        [Parameter()]
        [switch]$CopyHtml,

        [Parameter()]
        [switch]$CopyCsv,

        [Parameter()]
        [switch]$CopyXml,

        [Parameter()]
        [switch]$Quiet
    )

    if (-not $Quiet) {
        Write-Host "`n  [WingetIntune] Enterprise Win32 App Packager" -ForegroundColor Cyan
        Write-Host "  --------------------------------------------" -ForegroundColor DarkGray
        Write-Host "  [1/5] [#----] Resolving Winget manifest & installer adapter for '$PackageId'..." -ForegroundColor Cyan
    }
    # 1. Fetch Manifest and Resolve Adapter
    $manifest = Get-WingetManifest -PackageId $PackageId
    $adapter = Get-PackageAdapter -InstallerType $manifest.InstallerType -Manifest $manifest

    if (-not $DisplayName) {
        $DisplayName = if ($manifest.Name) { $manifest.Name } else { $PackageId }
    }

    if (-not $OutputFolder) {
        $OutputFolder = Join-Path (Get-Location) ("IntunePackages\" + $PackageId)
    }

    $srcFolder = Join-Path $OutputFolder 'src'
    if (-not (Test-Path $srcFolder)) {
        New-Item -ItemType Directory -Path $srcFolder -Force | Out-Null
    }

    # 2. Generate Install.ps1
    $adapterType = $adapter.InstallerType
    if (-not $Quiet) {
        Write-Host "  [2/5] [##---] Generating self-healing SYSTEM install shim for $adapterType adapter..." -ForegroundColor Cyan
    }
    $effectiveArgs = if ($CustomArgs) { $adapter.SilentArgs + " " + $CustomArgs } else { $adapter.SilentArgs }
    $installCode = New-StandaloneInstallShim -PackageId $PackageId -CustomArgs $effectiveArgs -Scope $Scope -SuccessCodes $adapter.SuccessCodes
    $installPath = Join-Path $srcFolder 'Install.ps1'
    $installCode | Out-File -FilePath $installPath -Force -Encoding utf8

    # 3. Generate Uninstall.ps1
    if (-not $Quiet) {
        Write-Host "  [3/5] [###--] Generating uninstall script..." -ForegroundColor Cyan
    }
    $uninstallLines = @(
        "# Standalone Uninstall Script for $PackageId",
        "`$wingetCmd = Get-Command 'winget.exe' -ErrorAction SilentlyContinue",
        "`$wingetPath = if (`$wingetCmd) { `$wingetCmd.Source } else { 'winget.exe' }",
        "& `$wingetPath uninstall --exact --id '$PackageId' --silent --disable-interactivity",
        "exit `$LASTEXITCODE"
    )
    $uninstallPath = Join-Path $srcFolder 'Uninstall.ps1'
    $uninstallLines | Out-File -FilePath $uninstallPath -Force -Encoding utf8

    # 4. Generate Detect.ps1
    if (-not $Quiet) {
        Write-Host "  [4/5] [####-] Generating detection script ($($adapter.DetectionStrategy))..." -ForegroundColor Cyan
    }
    $detectCode = New-StandaloneDetectShim -PackageId $PackageId -DisplayName $DisplayName -ProductCode $adapter.ProductCode -MinVersion $manifest.Version -DetectionStrategy $adapter.DetectionStrategy
    $detectPath = Join-Path $OutputFolder 'Detect.ps1'
    $detectCode | Out-File -FilePath $detectPath -Force -Encoding utf8

    # 5. Fetch IntuneWinAppUtil and Compile .intunewin
    $utilPath = Get-IntuneWinAppUtil
    if (-not $Quiet) {
        Write-Host "  [5/5] [#####] Compiling $PackageId.intunewin package..." -ForegroundColor Cyan
    }
    
    $proc = Start-Process -FilePath $utilPath -ArgumentList "-c `"$srcFolder`" -s `"Install.ps1`" -o `"$OutputFolder`" -q" -Wait -PassThru -NoNewWindow
    
    $intuneWinFile = Join-Path $OutputFolder "Install.intunewin"
    $renamedIntuneWin = Join-Path $OutputFolder ($PackageId + ".intunewin")

    if (Test-Path $intuneWinFile) {
        Move-Item -Path $intuneWinFile -Destination $renamedIntuneWin -Force
    }

    if (-not (Test-Path $renamedIntuneWin)) {
        throw "Packaging failed. IntuneWinAppUtil did not produce an output package."
    }

    $packageSizeMb = [Math]::Round((Get-Item $renamedIntuneWin).Length / 1MB, 2)
    $sha256Short = try {
        $fullHash = (Get-FileHash -Path $renamedIntuneWin -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($fullHash.Length -ge 16) { $fullHash.Substring(0, 16) + "..." } else { $fullHash }
    } catch { 'N/A' }

    # 6. Emit Metadata JSON
    $metadata = [PSCustomObject]@{
        PackageId            = $PackageId
        DisplayName          = $DisplayName
        Publisher            = $manifest.Publisher
        InstallerType        = $adapter.InstallerType
        DetectionStrategy    = $adapter.DetectionStrategy
        InstallCommandLine   = 'powershell.exe -ExecutionPolicy Bypass -File .\Install.ps1'
        UninstallCommandLine = 'powershell.exe -ExecutionPolicy Bypass -File .\Uninstall.ps1'
        IntuneWinPath        = $renamedIntuneWin
        DetectionScriptPath  = $detectPath
        PackageSizeMb        = $packageSizeMb
        CompiledAt           = (Get-Date).ToString('o')
    }

    $metaPath = Join-Path $OutputFolder 'IntuneAppMetadata.json'
    $metadata | ConvertTo-Json -Depth 5 | Out-File -FilePath $metaPath -Force -Encoding utf8

    $publishCmd = "Publish-IntuneWingetApp -IntuneWinPath `"$renamedIntuneWin`" -MetadataJsonPath `"$metaPath`" -Intent $Intent"
    if ($CopyPublishCommand) {
        try { Set-Clipboard -Value $publishCmd -ErrorAction SilentlyContinue } catch { }
    }

    if ($CopyReceipt) {
        $mdLines = @(
            "### WingetIntune ``.intunewin`` Build Receipt",
            "| Property | Value |",
            "| :--- | :--- |",
            "| **Package** | $DisplayName (``$PackageId``) |",
            "| **Installer Adapter** | ``$($adapter.InstallerType)`` |",
            "| **Detection Strategy** | ``$($adapter.DetectionStrategy)`` |",
            "| **Payload Size** | $packageSizeMb MB |",
            "| **SHA-256 Prefix** | ``$sha256Short`` |",
            "| **Output Package** | ``$renamedIntuneWin`` |"
        )
        try { Set-Clipboard -Value ($mdLines -join [Environment]::NewLine) -ErrorAction SilentlyContinue } catch { }
    }
    if ($CopyJson) {
        try { Set-Clipboard -Value ($metadata | ConvertTo-Json -Depth 5) -ErrorAction SilentlyContinue } catch { }
    }
    if ($CopyHtml) {
        $htmlCard = @(
            "<div style=`"font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:640px;background:#0f172a;color:#f8fafc;border:1px solid #334155;border-radius:8px;padding:16px;box-shadow:0 4px 6px -1px rgba(0,0,0,0.1);`">",
            "  <div style=`"display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #334155;padding-bottom:10px;margin-bottom:12px;`">",
            "    <h3 style=`"margin:0;color:#38bdf8;font-size:16px;font-weight:600;`">WingetIntune .intunewin Build Receipt</h3>",
            "    <span style=`"background:#166534;color:#4ade80;padding:2px 8px;border-radius:12px;font-size:12px;font-weight:600;`">COMPILED ($($Scope.ToUpper()))</span>",
            "  </div>",
            "  <table style=`"width:100%;border-collapse:collapse;font-size:13px;`">",
            "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Package</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;`">$DisplayName (<code>$PackageId</code>)</td></tr>",
            "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Installer Adapter</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;`"><code>$($adapter.InstallerType)</code></td></tr>",
            "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Detection Strategy</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;`"><code>$($adapter.DetectionStrategy)</code></td></tr>",
            "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Payload Size</td><td style=`"padding:6px 0;text-align:right;color:#4ade80;`">$packageSizeMb MB (SHA256: $sha256Short)</td></tr>",
            "    <tr><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Output Path</td><td style=`"padding:6px 0;text-align:right;color:#94a3b8;font-family:monospace;font-size:11px;`">$renamedIntuneWin</td></tr>",
            "  </table>",
            "</div>"
        ) -join [Environment]::NewLine
        try { Set-Clipboard -Value $htmlCard -ErrorAction SilentlyContinue } catch { }
    }
    if ($CopyCsv) {
        $csvLines = @(
            "PackageId,DisplayName,InstallerType,DetectionStrategy,PackageSizeMb,Sha256Prefix,IntuneWinPath",
            "`"$PackageId`",`"$DisplayName`",`"$($adapter.InstallerType)`",`"$($adapter.DetectionStrategy)`",$packageSizeMb,`"$sha256Short`",`"$renamedIntuneWin`""
        ) -join [Environment]::NewLine
        try { Set-Clipboard -Value $csvLines -ErrorAction SilentlyContinue } catch { }
    }
    if ($CopyTsv) {
        $tsvLines = @(
            "PackageId`tDisplayName`tInstallerType`tDetectionStrategy`tPackageSizeMb`tSha256Prefix`tIntuneWinPath",
            "$PackageId`t$DisplayName`t$($adapter.InstallerType)`t$($adapter.DetectionStrategy)`t$packageSizeMb`t$sha256Short`t$renamedIntuneWin"
        )
        try { Set-Clipboard -Value ($tsvLines -join [Environment]::NewLine) -ErrorAction SilentlyContinue } catch { }
    }
    if ($CopyXml) {
        $xmlCard = @(
            '<?xml version="1.0" encoding="utf-8"?>',
            "<WingetIntunePackage packageId=`"$([Security.SecurityElement]::Escape([string]$PackageId))`" scope=`"$Scope`">",
            "  <DisplayName>$([Security.SecurityElement]::Escape([string]$DisplayName))</DisplayName>",
            "  <InstallerAdapter>$([Security.SecurityElement]::Escape([string]$adapter.InstallerType))</InstallerAdapter>",
            "  <DetectionStrategy>$([Security.SecurityElement]::Escape([string]$adapter.DetectionStrategy))</DetectionStrategy>",
            "  <PayloadSizeMb>$packageSizeMb</PayloadSizeMb>",
            "  <Sha256Digest>$sha256Short</Sha256Digest>",
            "  <IntuneWinPath>$([Security.SecurityElement]::Escape([string]$renamedIntuneWin))</IntuneWinPath>",
            "</WingetIntunePackage>"
        ) -join [Environment]::NewLine
        try { Set-Clipboard -Value $xmlCard -ErrorAction SilentlyContinue } catch { }
    }

    if (-not $Quiet) {
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host "  | WINGETINTUNE .INTUNEWIN BUILD RECEIPT                                |" -ForegroundColor Cyan
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host ("  | Package     : {0,-54} |" -f "$DisplayName ($PackageId)") -ForegroundColor Gray
        Write-Host ("  | Adapter     : {0,-22} Detect : {1,-22} |" -f $adapter.InstallerType, $adapter.DetectionStrategy) -ForegroundColor Gray
        Write-Host ("  | Payload     : {0,-22} SHA256 : {1,-22} |" -f "$packageSizeMb MB (.intunewin)", $sha256Short) -ForegroundColor Green
        Write-Host ("  | Output Path : {0,-54} |" -f $renamedIntuneWin) -ForegroundColor Gray
        Write-Host ("  | Status      : {0,-22} Scope  : {1,-22} |" -f "[COMPILED]", $Scope.ToUpper()) -ForegroundColor Green
        if ($CopyHtml) {
            Write-Host "  | [CLIPBOARD] HTML .intunewin build card copied to clipboard.          |" -ForegroundColor Green
        }
        if ($CopyCsv) {
            Write-Host "  | [CLIPBOARD] CSV .intunewin build summary copied to clipboard.        |" -ForegroundColor Green
        }
        if ($CopyPublishCommand) {
            Write-Host "  | [CLIPBOARD] Publish-IntuneWingetApp command copied to clipboard.     |" -ForegroundColor Green
        }
        if ($CopyReceipt) {
            Write-Host "  | [CLIPBOARD] Markdown .intunewin build receipt copied to clipboard.   |" -ForegroundColor Green
        }
        if ($CopyJson) {
            Write-Host "  | [CLIPBOARD] JSON .intunewin build metadata copied to clipboard.      |" -ForegroundColor Green
        }
        if ($CopyHtml) {
        $htmlCard = @(
            "<div style=`"font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:640px;background:#0f172a;color:#f8fafc;border:1px solid #334155;border-radius:8px;padding:16px;box-shadow:0 4px 6px -1px rgba(0,0,0,0.1);`">",
            "  <div style=`"display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #334155;padding-bottom:10px;margin-bottom:12px;`">",
            "    <h3 style=`"margin:0;color:#38bdf8;font-size:16px;font-weight:600;`">WingetIntune .intunewin Build Receipt</h3>",
            "    <span style=`"background:#166534;color:#4ade80;padding:2px 8px;border-radius:12px;font-size:12px;font-weight:600;`">COMPILED ($($Scope.ToUpper()))</span>",
            "  </div>",
            "  <table style=`"width:100%;border-collapse:collapse;font-size:13px;`">",
            "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Package</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;`">$DisplayName (<code>$PackageId</code>)</td></tr>",
            "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Installer Adapter</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;`"><code>$($adapter.InstallerType)</code></td></tr>",
            "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Detection Strategy</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;`"><code>$($adapter.DetectionStrategy)</code></td></tr>",
            "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Payload Size</td><td style=`"padding:6px 0;text-align:right;color:#4ade80;`">$packageSizeMb MB (SHA256: $sha256Short)</td></tr>",
            "    <tr><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Output Path</td><td style=`"padding:6px 0;text-align:right;color:#94a3b8;font-family:monospace;font-size:11px;`">$renamedIntuneWin</td></tr>",
            "  </table>",
            "</div>"
        ) -join [Environment]::NewLine
        try { Set-Clipboard -Value $htmlCard -ErrorAction SilentlyContinue } catch { }
    }
    if ($CopyCsv) {
        $csvLines = @(
            "PackageId,DisplayName,InstallerType,DetectionStrategy,PackageSizeMb,Sha256Prefix,IntuneWinPath",
            "`"$PackageId`",`"$DisplayName`",`"$($adapter.InstallerType)`",`"$($adapter.DetectionStrategy)`",$packageSizeMb,`"$sha256Short`",`"$renamedIntuneWin`""
        ) -join [Environment]::NewLine
        try { Set-Clipboard -Value $csvLines -ErrorAction SilentlyContinue } catch { }
    }
    if ($CopyTsv) {
            Write-Host "  | [CLIPBOARD] TSV .intunewin build summary copied to clipboard.        |" -ForegroundColor Green
        }
        if ($CopyXml) {
            Write-Host "  | [CLIPBOARD] XML .intunewin build metadata copied to clipboard.       |" -ForegroundColor Green
        }
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
    }

    # 7. Publish if requested
    if ($Publish) {
        return (Publish-IntuneWingetApp -IntuneWinPath $renamedIntuneWin -MetadataJsonPath $metaPath -AssignTo $AssignTo -Intent $Intent)
    }

    return $metadata
}
