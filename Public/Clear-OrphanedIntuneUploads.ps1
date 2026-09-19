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
        [switch]$PassThru
    )

    Write-Host "`n  [WingetIntune] Orphaned Upload & Session Cleanup Engine" -ForegroundColor Cyan
    Write-Host "  -------------------------------------------------------" -ForegroundColor DarkGray

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
                        Write-Host "  [✔] Purged stale session: $($file.Name) ($reason)" -ForegroundColor Yellow
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
                                            Write-Host "  [✔] Identified dead Graph file: App $appId / Version $verId / File $($f.id) ($($f.uploadState))" -ForegroundColor Yellow
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

    Write-Host "  [OK] Orphan cleanup completed. $($purgedItems.Count) item(s) purged." -ForegroundColor Green

    if ($PassThru) {
        return $purgedItems
    }
}
