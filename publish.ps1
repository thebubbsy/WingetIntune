<#
.SYNOPSIS
    Local PowerShell Gallery Publisher for IntuneShared.
.DESCRIPTION
    Sets clean NuGet caches in C:\temp and publishes the module using the PSGALLERY_API_KEY environment variable.
#>
$env:TEMP = "C:\temp"
$env:TMP = "C:\temp"
$env:NUGET_PACKAGES = "C:\temp\nuget_cache"
$env:NUGET_HTTP_CACHE_PATH = "C:\temp\nuget_http_cache"

foreach ($dir in @($env:TEMP, $env:NUGET_PACKAGES, $env:NUGET_HTTP_CACHE_PATH)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

$apiKey = [Environment]::GetEnvironmentVariable("PSGALLERY_API_KEY", "User")
if (-not $apiKey) { $apiKey = [Environment]::GetEnvironmentVariable("PSGALLERY_API_KEY", "Process") }
if (-not $apiKey) { $apiKey = [Environment]::GetEnvironmentVariable("PSGALLERY_API_KEY", "Machine") }
if (-not $apiKey) { $apiKey = $env:PSGALLERY_API_KEY }

if ($apiKey) {
    Write-Host "Publishing module from '$PSScriptRoot' to PowerShell Gallery..." -ForegroundColor Cyan
    Import-Module PowerShellGet -Force
    Publish-Module -Path $PSScriptRoot -NuGetApiKey $apiKey -Force -Verbose
    Write-Host "Publish completed successfully!" -ForegroundColor Green
} else {
    Write-Error "PSGALLERY_API_KEY environment variable not found in User, Process, or Machine scopes."
}
