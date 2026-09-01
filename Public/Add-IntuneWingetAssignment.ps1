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
        [string]$Intent = 'Required'
    )

    $token = Connect-GraphToken -Scopes @('https://graph.microsoft.com/DeviceManagementApps.ReadWrite.All')
    $authHeader = @{
        'Authorization' = "Bearer $token"
        'Content-Type'  = 'application/json'
    }

    $targetPayload = @{}

    if ($GroupId -eq 'All Devices') {
        $targetPayload = @{
            '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget'
        }
    }
    elseif ($GroupId -eq 'All Users' -or $GroupId -eq 'All Licensed Users') {
        $targetPayload = @{
            '@odata.type' = '#microsoft.graph.allLicensedUsersAssignmentTarget'
        }
    }
    else {
        $resolvedGroupId = $GroupId
        if ($GroupId -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
            $groupSearchUri = "https://graph.microsoft.com/v1.0/groups?`$filter=" + [System.Uri]::EscapeDataString("displayName eq '$GroupId'")
            $gRes = Invoke-ResilientGraphRest -Uri $groupSearchUri -Method GET -Headers $authHeader
            if ($gRes.value -and $gRes.value.Count -gt 0) {
                $resolvedGroupId = $gRes.value[0].id
            } else {
                throw "Could not find Entra ID group matching name: $GroupId"
            }
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
    Write-Host "  [+] Assigning App [$AppId] to target [$GroupId] (Intent: $Intent)..." -ForegroundColor Cyan

    $res = Invoke-ResilientGraphRest -Uri $assignUri -Method POST -Headers $authHeader -Body $assignPayload
    Write-Host "  [OK] Assignment successfully configured!" -ForegroundColor Green
    return $res
}
