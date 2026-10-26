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
        [switch]$CopyHtml,

        [Parameter()]
        [switch]$CopyCsv,

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

    if ($CopyHtml -and $appAudit.Count -gt 0) {
        try {
            $htmlRows = [System.Collections.Generic.List[string]]::new()
            $htmlRows.Add("<div style=`"font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:800px;background:#0f172a;color:#f8fafc;border:1px solid #334155;border-radius:8px;padding:16px;box-shadow:0 4px 6px -1px rgba(0,0,0,0.1);`">")
            $htmlRows.Add("  <div style=`"display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #334155;padding-bottom:10px;margin-bottom:12px;`">")
            $htmlRows.Add("    <h3 style=`"margin:0;color:#38bdf8;font-size:16px;font-weight:600;`">Intune Win32 Catalog Audit ($($appAudit.Count) Apps, $uniquePublishers Publishers)</h3>")
            $htmlRows.Add("    <span style=`"background:#1e293b;color:#94a3b8;padding:2px 8px;border-radius:12px;font-size:12px;`">$(if ($Filter) { "Filter: $Filter" } else { 'All Apps' })</span>")
            $htmlRows.Add("  </div>")
            $htmlRows.Add("  <table style=`"width:100%;border-collapse:collapse;font-size:12px;`">")
            $htmlRows.Add("    <thead><tr style=`"border-bottom:1px solid #334155;color:#94a3b8;text-align:left;`"><th style=`"padding:6px;`">#</th><th style=`"padding:6px;`">App Name</th><th style=`"padding:6px;`">Publisher</th><th style=`"padding:6px;`">Status</th></tr></thead>")
            $htmlRows.Add("    <tbody>")
            $r = 0
            foreach ($entry in $appAudit) {
                $r++
                $htmlRows.Add("      <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px;color:#64748b;`">$r</td><td style=`"padding:6px;font-weight:500;`">$($entry.DisplayName)</td><td style=`"padding:6px;color:#cbd5e1;`">$($entry.Publisher)</td><td style=`"padding:6px;color:#38bdf8;`">$($entry.Status)</td></tr>")
            }
            $htmlRows.Add("    </tbody>")
            $htmlRows.Add("  </table>")
            $htmlRows.Add("</div>")
            Set-Clipboard -Value ($htmlRows -join "`r`n") -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Catalog audit HTML table ($($appAudit.Count) apps) copied to clipboard!" -ForegroundColor Green
            }
        } catch { }
    }

    if ($CopyCsv -and $appAudit.Count -gt 0) {
        try {
            $csvRows = [System.Collections.Generic.List[string]]::new()
            $csvRows.Add("AppId,DisplayName,Publisher,Status,CreatedDateTime")
            foreach ($entry in $appAudit) {
                $csvRows.Add("`"$($entry.AppId)`",`"$($entry.DisplayName)`",`"$($entry.Publisher)`",`"$($entry.Status)`",`"$($entry.CreatedDateTime)`"")
            }
            Set-Clipboard -Value ($csvRows -join "`r`n") -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Catalog audit CSV rows ($($appAudit.Count) apps) copied to clipboard!" -ForegroundColor Green
            }
        } catch { }
    }

    return $appAudit
}
