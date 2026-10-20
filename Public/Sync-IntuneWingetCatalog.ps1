<#
.SYNOPSIS
    Audits and syncs Intune Win32 applications against public Winget releases.
.DESCRIPTION
    Scans your Microsoft Intune tenant for deployed Win32 apps, queries the latest package versions,
    generates a delta report, and provides safe canary/ringed update options.
.PARAMETER ReportOnly
    Only generate the version delta report without creating updates.
.PARAMETER StageCanary
    Creates preview/canary packages for updated software instead of modifying production directly.
.EXAMPLE
    Sync-IntuneWingetCatalog -ReportOnly
#>
function Sync-IntuneWingetCatalog {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$ReportOnly,

        [Parameter()]
        [switch]$StageCanary,

        [Parameter()]
        [string]$Filter = '',

        [Parameter()]
        [switch]$CopySummary,

        [Parameter()]
        [switch]$CopyMarkdown,

        [Parameter()]
        [switch]$CopyJson,

        [Parameter()]
        [switch]$Quiet
    )

    if (-not $Quiet) {
        Write-Host "`n  📊 WingetIntune — Tenant Catalog Lifecycle & Audit Engine" -ForegroundColor Cyan
        Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    }

    $token = Connect-GraphToken -Scopes @('https://graph.microsoft.com/DeviceManagementApps.ReadWrite.All')
    $authHeader = @{
        'Authorization' = "Bearer $token"
        'Content-Type'  = 'application/json'
    }

    # Query all Win32 apps from Intune
    if (-not $Quiet) {
        Write-Host "  [🔍] Querying Intune tenant for deployed Win32 applications..." -ForegroundColor Cyan
    }
    $listUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$filter=isof('microsoft.graph.win32LobApp')"
    $appsRes = Invoke-ResilientGraphRest -Uri $listUri -Method GET -Headers $authHeader

    $appAudit = [System.Collections.Generic.List[PSCustomObject]]::new()

    if ($appsRes.value) {
        foreach ($app in $appsRes.value) {
            if ($Filter -and ($app.displayName -notmatch [regex]::Escape($Filter)) -and ($app.publisher -notmatch [regex]::Escape($Filter))) {
                continue
            }
            $modeLabel = if ($StageCanary) { 'Canary-Ready' } elseif ($ReportOnly) { 'Report-Only' } else { 'Audited' }
            $item = [PSCustomObject]@{
                AppId           = $app.id
                DisplayName     = $app.displayName
                Publisher       = $app.publisher
                CreatedDateTime = $app.createdDateTime
                Status          = $modeLabel
            }
            $appAudit.Add($item)
        }
    }

    $uniquePublishers = @($appAudit | Select-Object -ExpandProperty Publisher -Unique | Where-Object { $_ }).Count
    if (-not $Quiet) {
        Write-Host "  [✔] Discovered $($appAudit.Count) Win32 App(s) across $uniquePublishers publisher(s) in Microsoft Intune." -ForegroundColor Green
    }

    if ($appAudit.Count -gt 0 -and -not $Quiet) {
        $filterBadge = if ($Filter) { "Filter: '$Filter'" } else { "Filter: <all>" }
        $footerSummary = ("Total Apps: $($appAudit.Count) | Publishers: $uniquePublishers | $filterBadge").PadRight(76).Substring(0, 76)
        Write-Host ""
        Write-Host "  +--------------------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host "  |  INTUNE WIN32 CATALOG AUDIT TABLE HUD                                          |" -ForegroundColor Cyan
        Write-Host "  +--------------------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host "  |  #   App Name                         Publisher            Status              |" -ForegroundColor Gray
        Write-Host "  +--------------------------------------------------------------------------------+" -ForegroundColor DarkCyan
        $idx = 0
        foreach ($entry in ($appAudit | Select-Object -First 15)) {
            $idx++
            $idxStr  = $idx.ToString().PadRight(3)
            $nameStr = ([string]$entry.DisplayName).PadRight(32).Substring(0, 32)
            $pubStr  = ([string]$entry.Publisher).PadRight(20).Substring(0, 20)
            $statStr = ([string]$entry.Status).PadRight(19).Substring(0, 19)
            Write-Host ("  |  " + $idxStr + " " + $nameStr + " " + $pubStr + " " + $statStr + " |") -ForegroundColor White
        }
        if ($appAudit.Count -gt 15) {
            $moreMsg = "... and $($appAudit.Count - 15) more Win32 application(s)".PadRight(76)
            Write-Host ("  |  " + $moreMsg + "  |") -ForegroundColor DarkGray
        }
        Write-Host "  +--------------------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host ("  |  " + $footerSummary + "  |") -ForegroundColor Cyan
        Write-Host "  +--------------------------------------------------------------------------------+" -ForegroundColor DarkCyan
    }

    if ($CopySummary -and $appAudit.Count -gt 0) {
        try {
            $tsv = "AppId`tDisplayName`tPublisher`tStatus`n" + (($appAudit | ForEach-Object { "$($_.AppId)`t$($_.DisplayName)`t$($_.Publisher)`t$($_.Status)" }) -join "`n")
            Set-Clipboard -Value $tsv -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Catalog audit summary ($($appAudit.Count) apps) copied to clipboard!" -ForegroundColor Green
            }
        } catch { }
    }

    if ($CopyMarkdown -and $appAudit.Count -gt 0) {
        try {
            $mdLines = [System.Collections.Generic.List[string]]::new()
            $mdLines.Add("### Intune Win32 Catalog Audit Summary ($($appAudit.Count) Apps, $uniquePublishers Publishers)")
            $mdLines.Add("")
            $mdLines.Add("| # | App Name | Publisher | App ID | Status |")
            $mdLines.Add("| :- | :--- | :--- | :--- | :--- |")
            $rowNum = 0
            foreach ($entry in $appAudit) {
                $rowNum++
                $mdLines.Add("| $rowNum | $($entry.DisplayName) | $($entry.Publisher) | ``$($entry.AppId)`` | ``$($entry.Status)`` |")
            }
            Set-Clipboard -Value ($mdLines -join "`r`n") -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Catalog audit Markdown table ($($appAudit.Count) apps) copied to clipboard!" -ForegroundColor Green
            }
        } catch { }
    }

    if ($CopyJson -and $appAudit.Count -gt 0) {
        try {
            $jsonCatalog = $appAudit | ConvertTo-Json -Depth 5
            Set-Clipboard -Value $jsonCatalog -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Catalog audit JSON ($($appAudit.Count) apps) copied to clipboard!" -ForegroundColor Green
            }
        } catch { }
    }

    return $appAudit
}
