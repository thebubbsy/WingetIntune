<#
.SYNOPSIS
    Assigns an Intune Win32 App to Entra ID security groups or All Devices/Users.
.DESCRIPTION
    Creates mobileAppAssignment resources in Microsoft Graph to deliver applications to endpoints.
.PARAMETER AppId
    The Microsoft Intune Mobile App ID (GUID).
.PARAMETER GroupId
    Entra ID Group ID, Group Name, 'All Devices', or 'All Users'.
.PARAMETER Intent
    Assignment intent: 'Required', 'Available', or 'Uninstall'.
.EXAMPLE
    Add-IntuneWingetAssignment -AppId "11111111-2222-3333-4444-555555555555" -GroupId "All Devices" -Intent Required
#>
function Add-IntuneWingetAssignment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$AppId,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$GroupId,

        [Parameter()]
        [ValidateSet('Required', 'Available', 'Uninstall')]
        [string]$Intent = 'Required',

        [Parameter()]
        [switch]$CopyReceipt,

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

    $token = Connect-GraphToken -Scopes @('https://graph.microsoft.com/DeviceManagementApps.ReadWrite.All')
    $authHeader = @{
        'Authorization' = "Bearer $token"
        'Content-Type'  = 'application/json'
    }

    $targetPayload = @{}
    $targetScopeLabel = $GroupId

    if ($GroupId -eq 'All Devices') {
        $targetPayload = @{
            '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget'
        }
        $targetScopeLabel = 'All Devices (Tenant-Wide)'
    }
    elseif ($GroupId -eq 'All Users' -or $GroupId -eq 'All Licensed Users') {
        $targetPayload = @{
            '@odata.type' = '#microsoft.graph.allLicensedUsersAssignmentTarget'
        }
        $targetScopeLabel = 'All Licensed Users (Tenant-Wide)'
    }
    else {
        $resolvedGroupId = $GroupId
        if ($GroupId -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
            $groupSearchUri = "https://graph.microsoft.com/v1.0/groups?`$filter=" + [System.Uri]::EscapeDataString("displayName eq '$GroupId'")
            $gRes = Invoke-ResilientGraphRest -Uri $groupSearchUri -Method GET -Headers $authHeader
            if ($gRes.value -and $gRes.value.Count -gt 0) {
                $resolvedGroupId = $gRes.value[0].id
                $targetScopeLabel = "$GroupId ($resolvedGroupId)"
            } else {
                throw "Could not find Entra ID group matching name: $GroupId"
            }
        }
        else {
            $targetScopeLabel = "Entra Group ($resolvedGroupId)"
        }

        $targetPayload = @{
            '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
            groupId       = $resolvedGroupId
        }
    }

    $assignPayload = @{
        '@odata.type' = '#microsoft.graph.mobileAppAssignment'
        intent        = $Intent.ToLowerInvariant()
        target        = $targetPayload
    }

    $assignUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/assignments"
    if (-not $Quiet) {
        Write-Host "  [+] Assigning App [$AppId] to target [$GroupId] (Intent: $Intent)..." -ForegroundColor Cyan
    }

    $res = Invoke-ResilientGraphRest -Uri $assignUri -Method POST -Headers $authHeader -Body $assignPayload
    $assignmentIdDisplay = if ($res -and $res.id) { $res.id } else { 'Created' }

    if ($CopyReceipt) {
        $mdLines = @(
            "### Intune Win32 App Assignment Receipt (``$Intent``)",
            "| Field | Value |",
            "| :--- | :--- |",
            "| **Mobile App ID** | ``$AppId`` |",
            "| **Target Scope** | $targetScopeLabel |",
            "| **Graph Target Type** | ``$($targetPayload['@odata.type'])`` |",
            "| **Assignment ID** | ``$assignmentIdDisplay`` |"
        )
        try { Set-Clipboard -Value ($mdLines -join [Environment]::NewLine) -ErrorAction SilentlyContinue } catch { }
    }
    if ($CopyJson) {
        $jsonObj = [PSCustomObject]@{
            MobileAppId     = $AppId
            Intent          = $Intent
            TargetScope     = $targetScopeLabel
            GraphTargetType = $targetPayload['@odata.type']
            AssignmentId    = $assignmentIdDisplay
        } | ConvertTo-Json -Depth 4
        try { Set-Clipboard -Value $jsonObj -ErrorAction SilentlyContinue } catch { }
    }
    if ($CopyTsv) {
        $tsvLines = @(
            "MobileAppId`tIntent`tTargetScope`tGraphTargetType`tAssignmentId",
            "$AppId`t$Intent`t$targetScopeLabel`t$($targetPayload['@odata.type'])`t$assignmentIdDisplay"
        )
        try { Set-Clipboard -Value ($tsvLines -join [Environment]::NewLine) -ErrorAction SilentlyContinue } catch { }
    }
    if ($CopyHtml) {
        $htmlCard = @(
            "<div style=`"font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:640px;background:#0f172a;color:#f8fafc;border:1px solid #334155;border-radius:8px;padding:16px;box-shadow:0 4px 6px -1px rgba(0,0,0,0.1);`">",
            "  <div style=`"display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #334155;padding-bottom:10px;margin-bottom:12px;`">",
            "    <h3 style=`"margin:0;color:#38bdf8;font-size:16px;font-weight:600;`">Intune Win32 App Assignment Receipt</h3>",
            "    <span style=`"background:#166534;color:#4ade80;padding:2px 8px;border-radius:12px;font-size:12px;font-weight:600;`">ASSIGNED ($intentUpper)</span>",
            "  </div>",
            "  <table style=`"width:100%;border-collapse:collapse;font-size:13px;`">",
            "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Mobile App ID</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;font-family:monospace;font-size:11px;`">$AppId</td></tr>",
            "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Target Scope</td><td style=`"padding:6px 0;text-align:right;color:#38bdf8;`">$targetScopeLabel</td></tr>",
            "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Graph Target Type</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;`">$($targetPayload['@odata.type'])</td></tr>",
            "    <tr><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Assignment ID</td><td style=`"padding:6px 0;text-align:right;color:#4ade80;font-family:monospace;font-size:11px;`">$assignmentIdDisplay</td></tr>",
            "  </table>",
            "</div>"
        ) -join [Environment]::NewLine
        try { Set-Clipboard -Value $htmlCard -ErrorAction SilentlyContinue } catch { }
    }
    if ($CopyCsv) {
        $csvLines = @(
            "MobileAppId,Intent,TargetScope,GraphTargetType,AssignmentId",
            "`"$AppId`",`"$Intent`",`"$targetScopeLabel`",`"$($targetPayload['@odata.type'])`",`"$assignmentIdDisplay`""
        ) -join [Environment]::NewLine
        try { Set-Clipboard -Value $csvLines -ErrorAction SilentlyContinue } catch { }
    }

    if (-not $Quiet) {
        $intentUpper = $Intent.ToUpperInvariant()
        $intentColor = switch ($intentUpper) {
            'REQUIRED'  { 'Green' }
            'AVAILABLE' { 'Yellow' }
            'UNINSTALL' { 'Red' }
            Default     { 'Cyan' }
        }
        Write-Host ""
        $scopeBadge = if ($GroupId -match 'All') { 'TENANT_WIDE' } else { 'SECURITY_GROUP' }
        Write-Host ("  [INTENT:{0}] [TARGET:{1}] [GRAPH:CONNECTED] [STATUS:ASSIGNED]" -f $intentUpper, $scopeBadge) -ForegroundColor Green
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host ("  | INTUNE WIN32 APP ASSIGNMENT RECEIPT                 [{0,-12}] |" -f $intentUpper) -ForegroundColor $intentColor
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host ("  | Mobile App ID : {0,-52} |" -f $AppId) -ForegroundColor White
        Write-Host ("  | Target Scope  : {0,-52} |" -f $targetScopeLabel) -ForegroundColor Cyan
        Write-Host ("  | Graph Target  : {0,-52} |" -f $targetPayload['@odata.type']) -ForegroundColor Gray
        Write-Host ("  | Assignment ID : {0,-52} |" -f $assignmentIdDisplay) -ForegroundColor DarkGray
        Write-Host ("  | Status        : {0,-22} Scope  : {1,-22} |" -f "[ASSIGNED]", $Intent.ToUpper()) -ForegroundColor Green
        if ($CopyReceipt) {
            Write-Host "  | [CLIPBOARD] Markdown assignment receipt table copied to clipboard.   |" -ForegroundColor Green
        }
        if ($CopyJson) {
            Write-Host "  | [CLIPBOARD] JSON assignment receipt copied to clipboard.             |" -ForegroundColor Green
        }
        if ($CopyTsv) {
            Write-Host "  | [CLIPBOARD] TSV assignment receipt copied to clipboard.              |" -ForegroundColor Green
        }
        if ($CopyHtml) {
            Write-Host "  | [CLIPBOARD] HTML assignment receipt card copied to clipboard.        |" -ForegroundColor Green
        }
        if ($CopyCsv) {
            Write-Host "  | [CLIPBOARD] CSV assignment receipt summary copied to clipboard.      |" -ForegroundColor Green
        }
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host ""
    }
    return $res
}
