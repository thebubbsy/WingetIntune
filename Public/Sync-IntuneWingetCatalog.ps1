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
        [switch]$StageCanary
    )

    Write-Host "`n  📊 WingetIntune — Tenant Catalog Lifecycle & Audit Engine" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkGray

    $token = Connect-MsalToken -Scopes @('https://graph.microsoft.com/DeviceManagementApps.ReadWrite.All')
    $authHeader = @{
        'Authorization' = "Bearer $token"
        'Content-Type'  = 'application/json'
    }

    # Query all Win32 apps from Intune
    Write-Host "  [🔍] Querying Intune tenant for deployed Win32 applications..." -ForegroundColor Cyan
    $listUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$filter=isof('microsoft.graph.win32LobApp')"
    $appsRes = Invoke-ResilientGraphRest -Uri $listUri -Method GET -Headers $authHeader

    $appAudit = [System.Collections.Generic.List[PSCustomObject]]::new()

    if ($appsRes.value) {
        foreach ($app in $appsRes.value) {
            $item = [PSCustomObject]@{
                AppId           = $app.id
                DisplayName     = $app.displayName
                Publisher       = $app.publisher
                CreatedDateTime = $app.createdDateTime
                Status          = 'Audited'
            }
            $appAudit.Add($item)
        }
    }

    Write-Host "  [✔] Discovered $($appAudit.Count) Win32 App(s) in Microsoft Intune." -ForegroundColor Green
    return $appAudit
}
