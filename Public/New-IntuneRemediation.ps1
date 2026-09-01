<#
.SYNOPSIS
    Generates paired Detection and Remediation scripts for Intune Endpoint Analytics Proactive Remediations.
.DESCRIPTION
    Creates standard Proactive Remediation scripts to audit and automatically update software across
    the tenant without full Win32 app repackaging.
.PARAMETER PackageId
    The Winget package ID to audit (e.g. 'Zoom.Zoom', 'Google.Chrome').
.PARAMETER MinVersion
    The minimum required version floor (e.g. '6.0.0').
.PARAMETER OutputFolder
    Destination directory for Detect.ps1 and Remediate.ps1.
.EXAMPLE
    New-IntuneRemediation -PackageId "Zoom.Zoom" -MinVersion "6.0.0" -OutputFolder ".\Remediations\Zoom"
#>
function New-IntuneRemediation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$PackageId,

        [Parameter()]
        [string]$MinVersion = '',

        [Parameter()]
        [string]$OutputFolder = ''
    )

    if (-not $OutputFolder) {
        $OutputFolder = Join-Path (Get-Location) ("Remediations\" + $PackageId)
    }

    if (-not (Test-Path $OutputFolder)) {
        New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    }

    # 1. Detection Script
    $detectLines = @(
        "# Intune Proactive Remediation - Detection for $PackageId",
        "`$packageId = '$PackageId'",
        "`$minVersion = '$MinVersion'",
        "`$wingetCmd = Get-Command 'winget.exe' -ErrorAction SilentlyContinue",
        "`$wingetPath = if (`$wingetCmd) { `$wingetCmd.Source } else { 'winget.exe' }",
        "if (-not `$wingetPath) {",
        "    Write-Warning 'Winget not available.'",
        "    exit 1",
        "}",
        "`$listOutput = & `$wingetPath list --exact --id `$packageId --source winget --accept-source-agreements 2>`$null",
        "if (`$listOutput -match [regex]::Escape(`$packageId)) {",
        "    Write-Output 'Compliant: $PackageId is installed.'",
        "    exit 0",
        "} else {",
        "    Write-Warning 'Non-Compliant: $PackageId is missing or outdated.'",
        "    exit 1",
        "}"
    )

    # 2. Remediation Script
    $remediateLines = @(
        "# Intune Proactive Remediation - Remediation for $PackageId",
        "`$packageId = '$PackageId'",
        "`$wingetCmd = Get-Command 'winget.exe' -ErrorAction SilentlyContinue",
        "`$wingetPath = if (`$wingetCmd) { `$wingetCmd.Source } else { 'winget.exe' }",
        "if (-not `$wingetPath) {",
        "    Write-Error 'Winget not found. Remediation failed.'",
        "    exit 1",
        "}",
        "Write-Output 'Upgrading/Installing $PackageId silently via Winget...'",
        "`$params = @('upgrade', '--exact', '--id', `$packageId, '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements', '--silent', '--scope', 'machine')",
        "`$process = Start-Process -FilePath `$wingetPath -ArgumentList `$params -Wait -PassThru -NoNewWindow",
        "if (`$process.ExitCode -eq 0 -or `$process.ExitCode -eq 3010) {",
        "    Write-Output 'Remediation Successful: $PackageId updated.'",
        "    exit 0",
        "} else {",
        "    Write-Error 'Remediation Failed with Exit Code: ' + `$process.ExitCode",
        "    exit `$process.ExitCode",
        "}"
    )

    $detectFile = Join-Path $OutputFolder 'Detect.ps1'
    $remediateFile = Join-Path $OutputFolder 'Remediate.ps1'

    $detectLines | Out-File -FilePath $detectFile -Force -Encoding utf8
    $remediateLines | Out-File -FilePath $remediateFile -Force -Encoding utf8

    Write-Host "  [OK] Proactive Remediation scripts generated in: $OutputFolder" -ForegroundColor Green
    return [PSCustomObject]@{
        PackageId           = $PackageId
        MinVersion          = $MinVersion
        DetectScriptPath    = $detectFile
        RemediateScriptPath = $remediateFile
    }
}
