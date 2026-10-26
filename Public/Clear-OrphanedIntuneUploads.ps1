<#
.SYNOPSIS
    Purges orphaned, stale, and expired Intune upload sessions and uncommitted content versions.
.DESCRIPTION
    Scans C:\ProgramData\WingetIntune\UploadSessions\ for stale or expired session metadata files
    and purges uncommitted or failed Intune mobileAppContentFile and contentVersion resources via Microsoft Graph.
.PARAMETER MaxAgeHours
    Maximum age in hours before a session or uncommitted content file is considered orphaned (default: 24).
.PARAMETER PurgeLocalSessions
    If specified, purges local session files exceeding MaxAgeHours or with terminal/failed states.
.PARAMETER PurgeGraphContentFiles
    If specified, connects to Microsoft Graph and removes dead/timedOut contentVersion and mobileAppContentFile entries.
.PARAMETER PassThru
    Returns the collection of purged session files and Graph resources.
.EXAMPLE
    Clear-OrphanedIntuneUploads -MaxAgeHours 12 -PurgeLocalSessions -PassThru
#>
function Clear-OrphanedIntuneUploads {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [int]$MaxAgeHours = 24,

        [Parameter()]
        [switch]$PurgeLocalSessions,

        [Parameter()]
        [switch]$PurgeGraphContentFiles,

        [Parameter()]
        [switch]$PassThru,

        [Parameter()]
        [switch]$CopyReceipt,

        [Parameter()]
        [switch]$CopyJson,

        [Parameter()]
        [switch]$CopyCsv,

        [Parameter()]
        [switch]$CopyHtml,

        [Parameter()]
        [switch]$Quiet
    )

    if (-not $Quiet) {
        Write-Host "`n  [WingetIntune] Orphaned Upload & Session Cleanup Engine" -ForegroundColor Cyan
        Write-Host "  -------------------------------------------------------" -ForegroundColor DarkGray
    }

    $sessionDir = "C:\ProgramData\WingetIntune\UploadSessions"
    $purgedItems = [System.Collections.Generic.List[PSCustomObject]]::new()
    $nowUtc = [DateTime]::UtcNow

    # 1. Purge Local Session Files (only stale / terminal / SAS-expired ones - never in-flight sessions)
    if ($PurgeLocalSessions -and (Test-Path $sessionDir)) {
        $sessionFiles = @(Get-ChildItem -Path $sessionDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
        Write-Host "  [+] Inspecting $($sessionFiles.Count) local upload session file(s)..." -ForegroundColor Cyan

        foreach ($file in $sessionFiles) {
            $shouldDelete = $false
            $reason = ''
            $sessionData = $null

            try {
                $sessionData = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
            } catch { }

            $fileAgeHours = ($nowUtc - $file.LastWriteTimeUtc).TotalHours

            if ($sessionData) {
                if ($sessionData.LastUpdatedUtc) {
                    try {
                        $lastUpdated = [DateTime]::Parse($sessionData.LastUpdatedUtc).ToUniversalTime()
                        $fileAgeHours = ($nowUtc - $lastUpdated).TotalHours
                    } catch { }
                }

                if ($sessionData.SasUriExpiryUtc) {
                    try {
                        $expiry = [DateTime]::Parse($sessionData.SasUriExpiryUtc).ToUniversalTime()
                        if ($nowUtc -ge $expiry) {
                            $shouldDelete = $true
                            $reason = "SAS URI expired at $($sessionData.SasUriExpiryUtc)"
                        }
                    } catch { }
                }

                if ($sessionData.State -in @('Failed', 'Expired', 'Aborted', 'Succeeded')) {
                    $shouldDelete = $true
                    $reason = "Terminal state '$($sessionData.State)' with age $([Math]::Round($fileAgeHours, 1))h"
                }
            }

            if ($fileAgeHours -ge $MaxAgeHours) {
                $shouldDelete = $true
                $reason = "Exceeded MaxAgeHours ($([Math]::Round($fileAgeHours, 1))h >= $MaxAgeHours h)"
            }

            if ($shouldDelete) {
                if ($PSCmdlet.ShouldProcess($file.FullName, "Purge orphaned upload session ($reason)")) {
                    try {
                        Remove-Item -Path $file.FullName -Force -ErrorAction Stop
                        $purgedItem = [PSCustomObject]@{
                            Type         = 'LocalSessionFile'
                            Path         = $file.FullName
                            PackageId    = if ($sessionData) { $sessionData.PackageId } else { [System.IO.Path]::GetFileNameWithoutExtension($file.Name) }
                            AppId        = if ($sessionData) { $sessionData.AppId } else { $null }
                            Reason       = $reason
                            PurgedUtc    = $nowUtc.ToString('o')
                        }
                        $purgedItems.Add($purgedItem)
                        Write-Host "  [OK] Purged stale session: $($file.Name) ($reason)" -ForegroundColor Yellow
                    }
                    catch {
                        Write-Warning "Failed to delete session file '$($file.FullName)': $($_.Exception.Message)"
                    }
                }
            }
        }
    }

    # 2. Purge Orphaned Graph Content Versions & Files if requested
    if ($PurgeGraphContentFiles) {
        Write-Host "  [+] Querying Microsoft Graph for orphaned uncommitted Win32 app content..." -ForegroundColor Cyan
        try {
            $token = Connect-GraphToken -Scopes @('https://graph.microsoft.com/DeviceManagementApps.ReadWrite.All')
            $authHeader = @{
                'Authorization' = "Bearer $token"
                'Content-Type'  = 'application/json'
            }

            $listUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$filter=isof('microsoft.graph.win32LobApp')"
            $appsRes = Invoke-ResilientGraphRest -Uri $listUri -Method GET -Headers $authHeader

            if ($appsRes.value) {
                foreach ($app in $appsRes.value) {
                    $appId = $app.id
                    $versionsUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$appId/contentVersions"
                    $versionsRes = Invoke-ResilientGraphRest -Uri $versionsUri -Method GET -Headers $authHeader

                    if ($versionsRes.value) {
                        foreach ($ver in $versionsRes.value) {
                            $verId = $ver.id
                            # If content version is not the committed version
                            if ($app.committedContentVersion -ne $verId) {
                                $filesUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$appId/contentVersions/$verId/files"
                                $filesRes = Invoke-ResilientGraphRest -Uri $filesUri -Method GET -Headers $authHeader
                                if ($filesRes.value) {
                                    foreach ($f in $filesRes.value) {
                                        if ($f.uploadState -in @('failed', 'timedOut', 'azureStorageUriRequestFailed')) {
                                            $purgedItem = [PSCustomObject]@{
                                                Type             = 'GraphContentFile'
                                                AppId            = $appId
                                                ContentVersionId = $verId
                                                FileId           = $f.id
                                                State            = $f.uploadState
                                                Reason           = "Failed Graph uploadState: $($f.uploadState)"
                                                PurgedUtc        = $nowUtc.ToString('o')
                                            }
                                            $purgedItems.Add($purgedItem)
                                            Write-Host "  [OK] Identified dead Graph file: App $appId / Version $verId / File $($f.id) ($($f.uploadState))" -ForegroundColor Yellow
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        catch {
            Write-Warning "Graph content file cleanup encountered an error: $($_.Exception.Message)"
        }
    }

    $localPurgedCount = @($purgedItems | Where-Object { $_.Type -eq 'LocalSessionFile' }).Count
    $graphPurgedCount = @($purgedItems | Where-Object { $_.Type -eq 'GraphContentFile' }).Count

    if (-not $Quiet) {
        Write-Host ""
        Write-Host ("  [CLEANUP:ORPHANS] [MAX-AGE:{0}h] [LOCAL-PURGED:{1}] [GRAPH-PURGED:{2}] [TOTAL-PURGED:{3}]" -f $MaxAgeHours, $localPurgedCount, $graphPurgedCount, $purgedItems.Count) -ForegroundColor Green
        Write-Host "  +------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host "  |  [WingetIntune] Orphaned Session & Upload Cleanup Summary        |" -ForegroundColor Cyan
        Write-Host "  +------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host ("  |  Max Age Floor        : {0,-41}|" -f ("$MaxAgeHours hour(s)")) -ForegroundColor Gray
        Write-Host ("  |  Local Sessions Purged: {0,-41}|" -f $localPurgedCount) -ForegroundColor Gray
        Write-Host ("  |  Graph Content Purged : {0,-41}|" -f $graphPurgedCount) -ForegroundColor Gray
        Write-Host ("  |  Total Items Purged   : {0,-41}|" -f $purgedItems.Count) -ForegroundColor Green
        Write-Host ("  |  Completed At (UTC)   : {0,-41}|" -f $nowUtc.ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor Gray
        Write-Host "  +------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host "  [OK] Orphan cleanup completed. $($purgedItems.Count) item(s) purged." -ForegroundColor Green
    }

    if ($CopyReceipt) {
        try {
            $mdReceipt = @(
                "### WingetIntune Orphaned Upload & Session Cleanup Receipt",
                "| Metric | Value |",
                "| :--- | :--- |",
                "| **Max Age Floor** | $MaxAgeHours hour(s) |",
                "| **Local Sessions Purged** | $localPurgedCount |",
                "| **Graph Content Purged** | $graphPurgedCount |",
                "| **Total Items Purged** | $($purgedItems.Count) |",
                "| **Completed At (UTC)** | $($nowUtc.ToString('yyyy-MM-dd HH:mm:ss')) |"
            ) -join "`r`n"
            Set-Clipboard -Value $mdReceipt -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Copied Markdown Orphan Cleanup Receipt to clipboard." -ForegroundColor Green
            }
        } catch {
            Write-Verbose "Clipboard copy failed: $($_.Exception.Message)"
        }
    }

    if ($CopyJson) {
        try {
            $jsonSummary = [PSCustomObject]@{
                MaxAgeHours         = $MaxAgeHours
                LocalSessionsPurged = $localPurgedCount
                GraphContentPurged  = $graphPurgedCount
                TotalItemsPurged    = $purgedItems.Count
                CompletedAtUtc      = $nowUtc.ToString('o')
                PurgedItems         = @($purgedItems)
            } | ConvertTo-Json -Depth 5
            Set-Clipboard -Value $jsonSummary -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Copied Orphan Cleanup Summary JSON to clipboard." -ForegroundColor Green
            }
        } catch {
            Write-Verbose "Clipboard copy failed: $($_.Exception.Message)"
        }
    }

    if ($CopyHtml) {
        try {
            $htmlSummary = @(
                "<div style=`"font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:640px;background:#0f172a;color:#f8fafc;border:1px solid #334155;border-radius:8px;padding:16px;box-shadow:0 4px 6px -1px rgba(0,0,0,0.1);`">",
                "  <div style=`"display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #334155;padding-bottom:10px;margin-bottom:12px;`">",
                "    <h3 style=`"margin:0;color:#38bdf8;font-size:16px;font-weight:600;`">WingetIntune Orphaned Session & Upload Cleanup Receipt</h3>",
                "    <span style=`"background:#166534;color:#4ade80;padding:2px 8px;border-radius:12px;font-size:12px;font-weight:600;`">PURGED</span>",
                "  </div>",
                "  <table style=`"width:100%;border-collapse:collapse;font-size:13px;`">",
                "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Max Age Floor</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;`">$MaxAgeHours hour(s)</td></tr>",
                "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Local Sessions Purged</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;`">$localPurgedCount</td></tr>",
                "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Graph Content Purged</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;`">$graphPurgedCount</td></tr>",
                "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Total Items Purged</td><td style=`"padding:6px 0;text-align:right;color:#4ade80;font-weight:600;`">$($purgedItems.Count)</td></tr>",
                "    <tr><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Completed At (UTC)</td><td style=`"padding:6px 0;text-align:right;color:#94a3b8;font-size:12px;`">$($nowUtc.ToString('yyyy-MM-dd HH:mm:ss'))</td></tr>",
                "  </table>",
                "</div>"
            ) -join [Environment]::NewLine
            Set-Clipboard -Value $htmlSummary -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Copied Orphan Cleanup Summary HTML to clipboard." -ForegroundColor Green
            }
        } catch { }
    }

    if ($CopyCsv) {
        try {
            $csvSummary = @(
                "MaxAgeHours,LocalSessionsPurged,GraphContentPurged,TotalItemsPurged,CompletedAtUtc",
                "$MaxAgeHours,$localPurgedCount,$graphPurgedCount,$($purgedItems.Count),`"$($nowUtc.ToString('o'))`""
            ) -join "`r`n"
            Set-Clipboard -Value $csvSummary -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Copied Orphan Cleanup Summary CSV to clipboard." -ForegroundColor Green
            }
        } catch { }
    }

    if ($PassThru) {
        return $purgedItems
    }
}
