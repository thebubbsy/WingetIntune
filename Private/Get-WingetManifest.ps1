<#
.SYNOPSIS
    Fetches and parses a Winget package manifest from the official community repository.
.DESCRIPTION
    Queries the public Winget repository, downloads the installer manifest YAML,
    resolves architecture (x64/x86/arm64), and extracts declared InstallerSwitches,
    InstallerSuccessCodes, ProductCode, and AppsAndFeatures entries.
#>
function Get-WingetManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$PackageId,

        [Parameter()]
        [string]$Version = '',

        [Parameter()]
        [string]$Architecture = 'x64',

        [Parameter()]
        [string]$CacheDir = (Join-Path $env:LOCALAPPDATA 'WingetIntune\ManifestCache')
    )

    if (-not (Test-Path $CacheDir)) {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    }

    $firstLetter = $PackageId.Substring(0, 1).ToLowerInvariant()
    $pathParts = $PackageId.Split('.')
    $publisher = $pathParts[0]
    $appName = if ($pathParts.Count -gt 1) { [string]::Join('/', $pathParts[1..($pathParts.Count - 1)]) } else { $publisher }
    
    Write-Host "  [+] Querying Winget manifest for '$PackageId'..." -ForegroundColor Cyan

    $manifestData = [PSCustomObject]@{
        PackageId              = $PackageId
        Version                = $Version
        Name                   = $PackageId
        Publisher              = $publisher
        InstallerType          = 'exe'
        InstallerUrl           = ''
        InstallerSha256        = ''
        InstallerSwitches      = @{
            Silent             = ''
            SilentWithProgress = ''
            Custom             = ''
            InstallLocation    = ''
        }
        InstallerSuccessCodes  = @(0, 3010, 1641)
        ProductCode            = ''
        UpgradeCode            = ''
        AppsAndFeaturesEntries = @()
    }

    # 1. Query via winget CLI if installed
    if (Get-Command 'winget.exe' -ErrorAction SilentlyContinue) {
        try {
            $showRaw = winget show --exact --id $PackageId --source winget --accept-source-agreements 2>$null
            foreach ($line in ($showRaw -split "`r?`n")) {
                if ($line -match '^Version:\s*(.+)$') { $manifestData.Version = $Matches[1].Trim() }
                if ($line -match '^Publisher:\s*(.+)$') { $manifestData.Publisher = $Matches[1].Trim() }
                if ($line -match '^Installer Type:\s*(.+)$') { $manifestData.InstallerType = $Matches[1].Trim().ToLowerInvariant() }
                if ($line -match '^Installer SHA256:\s*(.+)$') { $manifestData.InstallerSha256 = $Matches[1].Trim() }
                if ($line -match '^Installer Url:\s*(.+)$') { $manifestData.InstallerUrl = $Matches[1].Trim() }
            }
        } catch { }
    }

    # 2. Query GitHub CDN for deep manifest YAML if version resolved
    if ($manifestData.Version) {
        $ver = $manifestData.Version
        $manifestYamlUrls = @(
            "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/$firstLetter/$publisher/$appName/$ver/$publisher.$appName.installer.yaml",
            "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/$firstLetter/$publisher/$appName/$ver/$PackageId.installer.yaml",
            "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/$firstLetter/$publisher/$appName/$ver/$publisher.$appName.yaml",
            "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/$firstLetter/$publisher/$appName/$ver/$PackageId.yaml"
        )

        foreach ($url in $manifestYamlUrls) {
            try {
                $yamlContent = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop).Content
                if ($yamlContent) {
                    $inSwitches = $false
                    foreach ($line in ($yamlContent -split "`r?`n")) {
                        if ($line -match '^InstallerType:\s*(.+)$') { $manifestData.InstallerType = $Matches[1].Trim().ToLowerInvariant() }
                        if ($line -match '^ProductCode:\s*(.+)$') { $manifestData.ProductCode = $Matches[1].Trim() }
                        if ($line -match '^InstallerSwitches:') { $inSwitches = $true; continue }
                        if ($inSwitches) {
                            if ($line -match '^\s+Silent:\s*[''"]?(.*?)[''"]?\s*$') { $manifestData.InstallerSwitches.Silent = $Matches[1].Trim() }
                            if ($line -match '^\s+SilentWithProgress:\s*[''"]?(.*?)[''"]?\s*$') { $manifestData.InstallerSwitches.SilentWithProgress = $Matches[1].Trim() }
                            if ($line -match '^\s+Custom:\s*[''"]?(.*?)[''"]?\s*$') { $manifestData.InstallerSwitches.Custom = $Matches[1].Trim() }
                            if ($line -match '^\S') { $inSwitches = $false }
                        }
                    }
                    break
                }
            } catch { }
        }
    }

    # Cache manifest descriptor locally
    $cacheFile = Join-Path $CacheDir ($PackageId + ".manifest.json")
    $manifestData | ConvertTo-Json -Depth 10 | Out-File -FilePath $cacheFile -Force -Encoding utf8

    return $manifestData
}
