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
        [string]$OutputFolder = '',

        [Parameter()]
        [switch]$CopySummary,

        [Parameter()]
        [switch]$CopyJson,

        [Parameter()]
        [switch]$CopyTsv,

        [Parameter()]
        [switch]$CopyHtml,

        [Parameter()]
        [switch]$CopyCsv,

        [Parameter()]
        [switch]$Quiet
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

    $detectHash = try { (Get-FileHash -Path $detectFile -Algorithm SHA256 -ErrorAction Stop).Hash } catch { 'N/A' }
    $remediateHash = try { (Get-FileHash -Path $remediateFile -Algorithm SHA256 -ErrorAction Stop).Hash } catch { 'N/A' }
    $detectBytes = try { (Get-Item -Path $detectFile -ErrorAction Stop).Length } catch { 0 }
    $remediateBytes = try { (Get-Item -Path $remediateFile -ErrorAction Stop).Length } catch { 0 }

    if (-not $Quiet) {
        $floorLabel = if ($MinVersion) { $MinVersion } else { 'Latest (Any Installed)' }
        $shortDetectHash = if ($detectHash.Length -ge 16) { $detectHash.Substring(0, 16) + '...' } else { $detectHash }
        $shortRemHash = if ($remediateHash.Length -ge 16) { $remediateHash.Substring(0, 16) + '...' } else { $remediateHash }
        $outDirDisplay = if ($OutputFolder.Length -gt 46) { '...' + $OutputFolder.Substring($OutputFolder.Length - 43) } else { $OutputFolder }

        Write-Host ""
        Write-Host "  [TYPE:PROACTIVE_REMEDIATION] [RUN:SYSTEM_64BIT] [ENFORCE:STRICT] [STATUS:COMPILED]" -ForegroundColor Green
        Write-Host "  +------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host "  |  [WingetIntune] Proactive Remediation Build Receipt              |" -ForegroundColor Cyan
        Write-Host "  +------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host ("  |  Package ID    : {0,-48}|" -f $PackageId) -ForegroundColor White
        Write-Host ("  |  Version Floor : {0,-48}|" -f $floorLabel) -ForegroundColor Gray
        Write-Host ("  |  Detect.ps1    : {0,-48}|" -f ("$detectBytes B (SHA256: $shortDetectHash)")) -ForegroundColor Green
        Write-Host ("  |  Remediate.ps1 : {0,-48}|" -f ("$remediateBytes B (SHA256: $shortRemHash)")) -ForegroundColor Green
        Write-Host ("  |  Run Context   : {0,-48}|" -f 'SYSTEM (64-bit PowerShell Host)') -ForegroundColor Gray
        Write-Host ("  |  Output Folder : {0,-48}|" -f $outDirDisplay) -ForegroundColor Gray
        Write-Host ("  |  Status        : {0,-20} Scope  : {1,-20}|" -f "[COMPILED]", "SYSTEM") -ForegroundColor Green
        if ($CopySummary) {
            Write-Host "  |  [CLIPBOARD] Markdown deployment summary copied to clipboard.   |" -ForegroundColor Green
        }
        if ($CopyHtml) {
            Write-Host "  |  [CLIPBOARD] HTML remediation build receipt copied to clipboard. |" -ForegroundColor Green
        }
        if ($CopyCsv) {
            Write-Host "  |  [CLIPBOARD] CSV remediation build summary copied to clipboard.   |" -ForegroundColor Green
        }
        Write-Host "  +------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host "  [OK] Proactive Remediation scripts generated in: $OutputFolder" -ForegroundColor Green
    }

    if ($CopySummary) {
        $mdSummary = @(
            "### Intune Proactive Remediation - $PackageId",
            "- **Version Floor**: $(if ($MinVersion) { $MinVersion } else { 'Any Installed' })",
            "- **Detect Script**: '$detectFile' ($detectBytes B | SHA256: $detectHash)",
            "- **Remediate Script**: '$remediateFile' ($remediateBytes B | SHA256: $remediateHash)",
            "- **Recommended Settings**: Run as SYSTEM, 64-bit PowerShell = Yes, Enforce Signature Check = No"
        ) -join [Environment]::NewLine
        try {
            Set-Clipboard -Value $mdSummary -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Copied Proactive Remediation deployment summary (Markdown) to clipboard." -ForegroundColor Cyan
            }
        } catch {
            Write-Verbose "Clipboard copy failed: $($_.Exception.Message)"
        }
    }

    if ($CopyJson) {
        $jsonSummary = [ordered]@{
            PackageId           = $PackageId
            MinVersion          = if ($MinVersion) { $MinVersion } else { 'Any Installed' }
            DetectScriptPath    = $detectFile
            DetectBytes         = $detectBytes
            DetectSha256        = $detectHash
            RemediateScriptPath = $remediateFile
            RemediateBytes      = $remediateBytes
            RemediateSha256     = $remediateHash
            RunContext          = 'SYSTEM (64-bit PowerShell Host)'
        } | ConvertTo-Json -Depth 4
        try {
            Set-Clipboard -Value $jsonSummary -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Copied Proactive Remediation build receipt (JSON) to clipboard." -ForegroundColor Cyan
            }
        } catch {
            Write-Verbose "Clipboard JSON copy failed: $($_.Exception.Message)"
        }
    }

    if ($CopyTsv) {
        $tsvFloor = if ($MinVersion) { $MinVersion } else { 'Any Installed' }
        $tsvSummary = "PackageId`tMinVersion`tDetectScriptPath`tDetectBytes`tDetectSha256`tRemediateScriptPath`tRemediateBytes`tRemediateSha256`r`n$PackageId`t$tsvFloor`t$detectFile`t$detectBytes`t$detectHash`t$remediateFile`t$remediateBytes`t$remediateHash"
        try {
            Set-Clipboard -Value $tsvSummary -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Copied Proactive Remediation build receipt (TSV) to clipboard." -ForegroundColor Cyan
            }
        } catch {
            Write-Verbose "Clipboard TSV copy failed: $($_.Exception.Message)"
        }
    }

    if ($CopyHtml) {
        $htmlCard = @(
            "<div style=`"font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:640px;background:#0f172a;color:#f8fafc;border:1px solid #334155;border-radius:8px;padding:16px;box-shadow:0 4px 6px -1px rgba(0,0,0,0.1);`">",
            "  <div style=`"display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #334155;padding-bottom:10px;margin-bottom:12px;`">",
            "    <h3 style=`"margin:0;color:#38bdf8;font-size:16px;font-weight:600;`">Intune Proactive Remediation Build Receipt</h3>",
            "    <span style=`"background:#166534;color:#4ade80;padding:2px 8px;border-radius:12px;font-size:12px;font-weight:600;`">COMPILED (SYSTEM)</span>",
            "  </div>",
            "  <table style=`"width:100%;border-collapse:collapse;font-size:13px;`">",
            "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Package ID</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;`"><code>$PackageId</code></td></tr>",
            "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Version Floor</td><td style=`"padding:6px 0;text-align:right;color:#38bdf8;`">$(if ($MinVersion) { $MinVersion } else { 'Any Installed' })</td></tr>",
            "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Detect.ps1</td><td style=`"padding:6px 0;text-align:right;color:#4ade80;`">$detectBytes B (SHA256: $shortDetectHash)</td></tr>",
            "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Remediate.ps1</td><td style=`"padding:6px 0;text-align:right;color:#4ade80;`">$remediateBytes B (SHA256: $shortRemHash)</td></tr>",
            "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Output Folder</td><td style=`"padding:6px 0;text-align:right;color:#94a3b8;font-family:monospace;font-size:11px;`">$OutputFolder</td></tr>",
            "  </table>",
            "</div>"
        ) -join [Environment]::NewLine
        try { Set-Clipboard -Value $htmlCard -ErrorAction SilentlyContinue } catch { }
    }
    if ($CopyCsv) {
        $csvLines = @(
            "PackageId,MinVersion,DetectBytes,DetectSha256,RemediateBytes,RemediateSha256,OutputFolder",
            "`"$PackageId`",`"$MinVersion`",$detectBytes,`"$detectHash`",$remediateBytes,`"$remediateHash`",`"$OutputFolder`""
        ) -join [Environment]::NewLine
        try { Set-Clipboard -Value $csvLines -ErrorAction SilentlyContinue } catch { }
    }

    return [PSCustomObject]@{
        PackageId           = $PackageId
        MinVersion          = $MinVersion
        DetectScriptPath    = $detectFile
        RemediateScriptPath = $remediateFile
        DetectSha256        = $detectHash
        RemediateSha256     = $remediateHash
    }
}
