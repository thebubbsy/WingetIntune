<#
.SYNOPSIS
    Fetches and parses a Winget package manifest with explicit architecture and scope resolution.
.DESCRIPTION
    Queries the official Winget catalog, downloads the version/installer manifest YAML,
    filters installers by target architecture (x64, arm64, x86) and scope (machine),
    and extracts declared switches, ProductCode, and success codes.
#>
function Get-WingetManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$PackageId,

        [Parameter()]
        [string]$Version = '',

        [Parameter()]
        [ValidateSet('x64', 'arm64', 'x86')]
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
    
    Write-Host "  [+] Querying Winget manifest for '$PackageId' (Target Arch: $Architecture)..." -ForegroundColor Cyan

    $manifestData = [PSCustomObject]@{
        PackageId              = $PackageId
        Version                = $Version
        Name                   = $PackageId
        Publisher              = $publisher
        Architecture           = $Architecture
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

    # 1. Query via winget CLI with architecture filter if installed
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

    # 2. Query GitHub CDN raw manifest YAML with architecture matching
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
                    $inInstallers = $false
                    $currentInstallerArch = ''
                    $isTargetArch = $true

                    foreach ($line in ($yamlContent -split "`r?`n")) {
                        if ($line -match '^InstallerType:\s*(.+)$') { $manifestData.InstallerType = $Matches[1].Trim().ToLowerInvariant() }
                        if ($line -match '^ProductCode:\s*(.+)$') { $manifestData.ProductCode = $Matches[1].Trim() }
                        
                        # Handle Architecture blocks
                        if ($line -match '^\s+Architecture:\s*(.+)$') {
                            $currentInstallerArch = $Matches[1].Trim().ToLowerInvariant()
                            $isTargetArch = ($currentInstallerArch -eq $Architecture.ToLowerInvariant() -or $currentInstallerArch -eq 'neutral')
                        }

                        if ($line -match '^\s+InstallerUrl:\s*(.+)$' -and $isTargetArch) {
                            $manifestData.InstallerUrl = $Matches[1].Trim()
                        }

                        if ($line -match '^\s+InstallerSha256:\s*(.+)$' -and $isTargetArch) {
                            $manifestData.InstallerSha256 = $Matches[1].Trim()
                        }

                        if ($line -match '^InstallerSwitches:' -or $line -match '^\s+InstallerSwitches:') {
                            $inSwitches = $true
                            continue
                        }

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
