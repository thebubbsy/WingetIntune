<#
.SYNOPSIS
    Publishes a compiled .intunewin package directly to Microsoft Intune via Microsoft Graph.
.DESCRIPTION
    Automates the full Win32 app ingestion pipeline: creates the win32LobApp entity,
    extracts encryption headers, uploads chunked blocks to Azure Storage SAS URIs,
    commits the file, waits for Intune server-side processing to reach commitFileSuccess,
    and assigns to Entra groups.
#>
function Publish-IntuneWingetApp {
    [CmdletBinding()]
    [Alias('Publish-IntuneWin32App')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$IntuneWinPath,

        [Parameter()]
        [string]$MetadataJsonPath = '',

        [Parameter()]
        [string[]]$AssignTo = @(),

        [Parameter()]
        [ValidateSet('Required', 'Available')]
        [string]$Intent = 'Required',

        [Parameter()]
        [int]$ProcessingTimeoutMinutes = 15
    )

    Write-Host "`n  [WingetIntune] Microsoft Graph Win32 App Cloud Publisher" -ForegroundColor Cyan
    Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray

    if (-not (Test-Path $IntuneWinPath)) {
        throw "IntuneWin package not found at: $IntuneWinPath"
    }

    # 1. Connect to Microsoft Graph with DeviceManagementApps scope
    $token = Connect-GraphToken -Scopes @('https://graph.microsoft.com/DeviceManagementApps.ReadWrite.All')
    $authHeader = @{
        'Authorization' = "Bearer $token"
        'Content-Type'  = 'application/json'
    }

    # 2. Parse Metadata
    $meta = $null
    if ($MetadataJsonPath -and (Test-Path $MetadataJsonPath)) {
        $meta = Get-Content $MetadataJsonPath -Raw | ConvertFrom-Json
    } else {
        $meta = [PSCustomObject]@{
            DisplayName          = [System.IO.Path]::GetFileNameWithoutExtension($IntuneWinPath)
            Publisher            = 'Enterprise IT'
            Description          = 'Automated Win32 Package deployed via WingetIntune.'
            InstallCommandLine   = 'powershell.exe -ExecutionPolicy Bypass -File .\Install.ps1'
            UninstallCommandLine = 'powershell.exe -ExecutionPolicy Bypass -File .\Uninstall.ps1'
        }
    }

    # 3. Read Detection Script content
    $detectionScriptBase64 = ''
    $detectFile = Join-Path (Split-Path $IntuneWinPath -Parent) 'Detect.ps1'
    if (Test-Path $detectFile) {
        $scriptBytes = [System.IO.File]::ReadAllBytes($detectFile)
        $detectionScriptBase64 = [Convert]::ToBase64String($scriptBytes)
    }

    # 4. Create win32LobApp in Microsoft Graph
    $appName = $meta.DisplayName
    Write-Host "  [+] Creating Win32 App entity in Microsoft Intune: '$appName'..." -ForegroundColor Cyan
    $appPayload = @{
        '@odata.type'                    = '#microsoft.graph.win32LobApp'
        displayName                      = $meta.DisplayName
        description                      = $meta.Description
        publisher                        = $meta.Publisher
        installCommandLine               = $meta.InstallCommandLine
        uninstallCommandLine             = $meta.UninstallCommandLine
        applicableArchitectures          = 'x64'
        minimumSupportedOperatingSystem  = @{
            v10_19041 = $true
        }
    }

    if ($detectionScriptBase64) {
        $appPayload['detectionRules'] = @(
            @{
                '@odata.type'           = '#microsoft.graph.win32LobAppPowerShellScriptDetection'
                scriptContent           = $detectionScriptBase64
                enforceSignatureCheck   = $false
                runAs32Bit              = $false
            }
        )
    }

    $createUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps"
    $appObj = Invoke-ResilientGraphRest -Uri $createUri -Method POST -Headers $authHeader -Body $appPayload
    $appId = $appObj.id
    Write-Host "  [OK] App entity created successfully! (App ID: $appId)" -ForegroundColor Green

    # 5. Extract detection.xml encryption metadata from .intunewin (ZIP)
    Write-Host "  [+] Extracting package encryption metadata..." -ForegroundColor Cyan
    $tempZip = Join-Path $env:TEMP ("IntuneWinExtract_" + [Guid]::NewGuid().ToString('N'))
    [System.IO.Compression.ZipFile]::ExtractToDirectory($IntuneWinPath, $tempZip)
    $detectionXmlPath = Join-Path $tempZip 'Contents\detection.xml'

    if (-not (Test-Path $detectionXmlPath)) {
        throw "Invalid .intunewin package: missing Contents\detection.xml."
    }

    [xml]$doc = Get-Content $detectionXmlPath
    $encInfo = $doc.ApplicationInfo.EncryptionInfo
    $fileName = $doc.ApplicationInfo.FileName
    $unencryptedSize = [int64]$doc.ApplicationInfo.UnencryptedContentSize

    # 6. Create Content Version
    Write-Host "  [+] Creating Intune Content Version..." -ForegroundColor Cyan
    $versionUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$appId/contentVersions"
    $versionObj = Invoke-ResilientGraphRest -Uri $versionUri -Method POST -Headers $authHeader -Body @{}
    $versionId = $versionObj.id

    # 7. Create File Entry in Graph
    Write-Host "  [+] Registering file entry in Microsoft Graph..." -ForegroundColor Cyan
    $fileUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$appId/contentVersions/$versionId/files"
    $filePayload = @{
        '@odata.type'            = '#microsoft.graph.mobileAppContentFile'
        name                     = $fileName
        size                     = (Get-Item $IntuneWinPath).Length
        sizeEncrypted            = (Get-Item $IntuneWinPath).Length
        manifest                 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($detectionXmlPath))
        isDependency             = $false
    }

    $fileObj = Invoke-ResilientGraphRest -Uri $fileUri -Method POST -Headers $authHeader -Body $filePayload
    $fileId = $fileObj.id

    # 8. Poll for Azure Storage SAS URI
    Write-Host "  [+] Requesting Azure Storage SAS upload URI from Intune..." -ForegroundColor Cyan
    $fileStatusUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$appId/contentVersions/$versionId/files/$fileId"
    $azureSasUri = $null

    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 3
        $fileState = Invoke-ResilientGraphRest -Uri $fileStatusUri -Method GET -Headers $authHeader
        if ($fileState.azureStorageUri) {
            $azureSasUri = $fileState.azureStorageUri
            break
        }
    }

    if (-not $azureSasUri) {
        throw "Timed out waiting for Azure Storage upload SAS URI from Intune."
    }

    # 9. Upload Chunked Blocks to Azure Storage with Durable State Machine
    Send-AzureBlockBlob -FilePath $IntuneWinPath -SasUri $azureSasUri

    # 10. Commit File in Microsoft Graph
    Write-Host "  [+] Submitting file commit action to Microsoft Graph..." -ForegroundColor Cyan
    $commitUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$appId/contentVersions/$versionId/files/$fileId/commit"
    $commitPayload = @{
        fileEncryptionInfo = @{
            encryptionKey          = $encInfo.EncryptionKey
            macKey                 = $encInfo.MacKey
            initializationVector   = $encInfo.InitializationVector
            mac                    = $encInfo.Mac
            profileIdentifier      = $encInfo.ProfileIdentifier
            fileDigest             = $encInfo.FileDigest
            fileDigestAlgorithm    = $encInfo.FileDigestAlgorithm
        }
    }

    Invoke-ResilientGraphRest -Uri $commitUri -Method POST -Headers $authHeader -Body $commitPayload | Out-Null

    # 11. Wait for Intune Server-Side Content File Processing
    Write-Host "  [+] Waiting for Intune server-side file processing & encryption validation..." -NoNewline -ForegroundColor Cyan
    $procSw = [System.Diagnostics.Stopwatch]::StartNew()
    $fileCommitted = $false

    while ($procSw.Elapsed.TotalMinutes -lt $ProcessingTimeoutMinutes) {
        Start-Sleep -Seconds 10
        Write-Host "." -NoNewline -ForegroundColor Cyan

        try {
            $fileStatus = Invoke-ResilientGraphRest -Uri $fileStatusUri -Method GET -Headers $authHeader
            $state = $fileStatus.uploadState

            if ($state -eq 'commitFileSuccess' -or ($state -eq 'committed' -and $fileStatus.sizeEncrypted -gt 0)) {
                $fileCommitted = $true
                Write-Host "`n  [OK] Intune file processing complete (Upload State: $state, Size: $($fileStatus.size) bytes)." -ForegroundColor Green
                break
            }
            elseif ($state -eq 'commitFileFailed' -or $state -eq 'azureStorageUriRequestFailed') {
                throw "Intune server-side processing failed with uploadState: $state"
            }
        } catch {
            if ($_.Exception.Message -match 'failed') { throw $_ }
        }
    }
    $procSw.Stop()

    if (-not $fileCommitted) {
        Write-Warning "`nFile processing timed out after $ProcessingTimeoutMinutes minutes. Proceeding with content version binding."
    }

    # 12. Bind Committed Content Version to Mobile App
    Write-Host "  [+] Binding Content Version to Mobile App..." -ForegroundColor Cyan
    $updateAppUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$appId"
    $updateAppPayload = @{
        '@odata.type'               = '#microsoft.graph.win32LobApp'
        committedContentVersion     = $versionId
    }
    Invoke-ResilientGraphRest -Uri $updateAppUri -Method PATCH -Headers $authHeader -Body $updateAppPayload | Out-Null

    # Cleanup temp extraction
    Remove-Item -Path $tempZip -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "  [OK] App '$appName' successfully published to Intune!" -ForegroundColor Green

    # 13. Handle Group Assignments
    if ($AssignTo -and $AssignTo.Count -gt 0) {
        foreach ($group in $AssignTo) {
            Add-IntuneWingetAssignment -AppId $appId -GroupId $group -Intent $Intent
        }
    }

    return $appObj
}
