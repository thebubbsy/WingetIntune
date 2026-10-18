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
        [switch]$CopyPublishCommand
    )

    Write-Host "`n  [WingetIntune] Enterprise Win32 App Packager" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

    # 1. Fetch Manifest and Resolve Adapter
    Write-Host "  [1/5] [#----] Resolving Winget manifest & installer adapter for '$PackageId'..." -ForegroundColor Cyan
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
    Write-Host "  [2/5] [##---] Generating self-healing SYSTEM install shim for $adapterType adapter..." -ForegroundColor Cyan
    $effectiveArgs = if ($CustomArgs) { $adapter.SilentArgs + " " + $CustomArgs } else { $adapter.SilentArgs }
    $installCode = New-StandaloneInstallShim -PackageId $PackageId -CustomArgs $effectiveArgs -Scope $Scope -SuccessCodes $adapter.SuccessCodes
    $installPath = Join-Path $srcFolder 'Install.ps1'
    $installCode | Out-File -FilePath $installPath -Force -Encoding utf8

    # 3. Generate Uninstall.ps1
    Write-Host "  [3/5] [###--] Generating uninstall script..." -ForegroundColor Cyan
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
    Write-Host "  [4/5] [####-] Generating detection script ($($adapter.DetectionStrategy))..." -ForegroundColor Cyan
    $detectCode = New-StandaloneDetectShim -PackageId $PackageId -DisplayName $DisplayName -ProductCode $adapter.ProductCode -MinVersion $manifest.Version -DetectionStrategy $adapter.DetectionStrategy
    $detectPath = Join-Path $OutputFolder 'Detect.ps1'
    $detectCode | Out-File -FilePath $detectPath -Force -Encoding utf8

    # 5. Fetch IntuneWinAppUtil and Compile .intunewin
    $utilPath = Get-IntuneWinAppUtil
    Write-Host "  [5/5] [#####] Compiling $PackageId.intunewin package..." -ForegroundColor Cyan
    
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

    Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host "  | WINGETINTUNE .INTUNEWIN BUILD RECEIPT                                |" -ForegroundColor Cyan
    Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ("  | Package     : {0,-54} |" -f "$DisplayName ($PackageId)") -ForegroundColor Gray
    Write-Host ("  | Adapter     : {0,-22} Detect : {1,-22} |" -f $adapter.InstallerType, $adapter.DetectionStrategy) -ForegroundColor Gray
    Write-Host ("  | Payload     : {0,-22} SHA256 : {1,-22} |" -f "$packageSizeMb MB (.intunewin)", $sha256Short) -ForegroundColor Green
    Write-Host ("  | Output Path : {0,-54} |" -f $renamedIntuneWin) -ForegroundColor Gray
    if ($CopyPublishCommand) {
        Write-Host "  | [CLIPBOARD] Publish-IntuneWingetApp command copied to clipboard.     |" -ForegroundColor Green
    }
    Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan

    # 7. Publish if requested
    if ($Publish) {
        return (Publish-IntuneWingetApp -IntuneWinPath $renamedIntuneWin -MetadataJsonPath $metaPath -AssignTo $AssignTo -Intent $Intent)
    }

    return $metadata
}
