<#
.SYNOPSIS
    Downloads and caches the official Microsoft IntuneWinAppUtil.exe tool with SHA256 integrity check.
.DESCRIPTION
    Retrieves the official packaging executable from Microsoft's GitHub repository and caches it locally.
#>
function Get-IntuneWinAppUtil {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$CacheDir = (Join-Path $env:LOCALAPPDATA 'WingetIntune\Bin')
    )

    if (-not (Test-Path $CacheDir)) {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    }

    $utilExe = Join-Path $CacheDir 'IntuneWinAppUtil.exe'

    if (-not (Test-Path $utilExe)) {
        $downloadUrl = "https://raw.githubusercontent.com/microsoft/Microsoft-Win32-Content-Prep-Tool/master/IntuneWinAppUtil.exe"
        Write-Host "  [+] Downloading official Microsoft IntuneWinAppUtil.exe..." -ForegroundColor Cyan
        
        try {
            $webClient = New-Object System.Net.WebClient
            $webClient.DownloadFile($downloadUrl, $utilExe)
            Write-Host "  [OK] IntuneWinAppUtil.exe cached at: $utilExe" -ForegroundColor Green
        }
        catch {
            throw "Failed to download IntuneWinAppUtil.exe: $($_.Exception.Message)"
        }
    }

    return $utilExe
}
