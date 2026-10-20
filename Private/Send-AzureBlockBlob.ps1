<#
.SYNOPSIS
    Uploads a file to Azure Storage Block Blob with deterministic block IDs, SHA256 integrity verification, and transactional resume.
.DESCRIPTION
    Divides large files into 6MB block chunks using deterministic Base64 block IDs (block_000000, block_000001, etc.).
    Persists session state in C:\ProgramData\WingetIntune\UploadSessions\<PackageId>.json with full metadata:
    AppId, ContentVersionId, FileId, FileDigest (SHA256), SourceFilePath, SasUriExpiryUtc, Blocks, and State.
    Performs pre-resume SHA256 integrity verification to detect file modifications, aborting stale sessions if corrupted.
    Queries Azure's comp=blocklist as the authoritative source of truth for seamless multi-part upload recovery.
#>
function Send-AzureBlockBlob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string]$SasUri,

        [Parameter()]
        [string]$UploadId = ([Guid]::NewGuid().ToString('N')),

        [Parameter()]
        [string]$PackageId = '',

        [Parameter()]
        [string]$AppId = '',

        [Parameter()]
        [string]$ContentVersionId = '',

        [Parameter()]
        [string]$FileId = '',

        [Parameter()]
        [string]$FileDigest = '',

        [Parameter()]
        [datetime]$SasUriExpiryUtc = [datetime]::MinValue,

        [Parameter()]
        [int]$BlockSizeMb = 6,

        [Parameter()]
        [int]$MaxRetries = 5,

        [Parameter()]
        [switch]$Resume,

        [Parameter()]
        [switch]$CopyReceipt,

        [Parameter()]
        [switch]$CopyJson,

        [Parameter()]
        [switch]$CopyTsv,

        [Parameter()]
        [switch]$Quiet
    )

    if (-not (Test-Path $FilePath)) {
        throw "File not found: $FilePath"
    }

    # 1. Compute SHA256 Digest of Local File
    $resolvedPath = (Resolve-Path $FilePath).Path
    $fileHash = (Get-FileHash -Path $resolvedPath -Algorithm SHA256).Hash
    $fileItem = Get-Item $resolvedPath
    $fileLength = $fileItem.Length

    # 2. Session Directory and File Resolution
    $sessionDir = "C:\ProgramData\WingetIntune\UploadSessions"
    if (-not (Test-Path $sessionDir)) {
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
    }

    $sessionKey = if ($PackageId) { $PackageId } else { $UploadId }
    $sessionFile = Join-Path $sessionDir "$sessionKey.json"

    # 3. Check SAS URI Expiration
    if ($SasUriExpiryUtc -ne [datetime]::MinValue -and [DateTime]::UtcNow -ge $SasUriExpiryUtc) {
        throw [System.TimeoutException]"Azure Storage SAS upload URI has expired at $($SasUriExpiryUtc.ToString('o'))."
    }

    $chunkSizeBytes = $BlockSizeMb * 1024 * 1024
    $totalBlocks = [int][Math]::Ceiling($fileLength / $chunkSizeBytes)

    # 4. Generate Deterministic Block Map (block_000000 -> Base64)
    $blockMap = [System.Collections.Generic.List[PSCustomObject]]::new()
    for ($i = 0; $i -lt $totalBlocks; $i++) {
        $rawId = "block_{0:D6}" -f $i
        $base64Id = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($rawId))
        $blockMap.Add([PSCustomObject]@{
            Index  = $i
            RawId  = $rawId
            Id     = $base64Id
            Status = 'Pending'
        })
    }

    # 5. Pre-Resume SHA256 Integrity Verification
    $existingSession = $null
    if (Test-Path $sessionFile) {
        try {
            $existingSession = Get-Content $sessionFile -Raw | ConvertFrom-Json
            if ($existingSession.FileDigest) {
                if ($existingSession.FileDigest -ne $fileHash) {
                    Write-Warning "Pre-Resume SHA256 Mismatch: Session digest ($($existingSession.FileDigest)) does not match local file ($fileHash). Aborting stale session and initiating fresh transaction."
                    Remove-Item -Path $sessionFile -Force -ErrorAction SilentlyContinue
                    $existingSession = $null
                } else {
                    if (-not $Quiet) {
                        Write-Host "  [+] Pre-Resume SHA256 integrity verified ($fileHash). Resuming transaction..." -ForegroundColor Green
                    }
                }
            }
        } catch {
            Write-Warning "Failed reading existing session file: $($_.Exception.Message)"
            $existingSession = $null
        }
    }

    # 6. Query Authoritative Azure Server-Side Block List (comp=blocklist&blocklisttype=all)
    $serverBlockIds = [System.Collections.Generic.HashSet[string]]::new()
    $separator = if ($SasUri -match '\?') { '&' } else { '?' }
    $blockListUri = $SasUri + $separator + "comp=blocklist&blocklisttype=all"
    $alreadyUploaded = 0

    try {
        $blReq = [System.Net.HttpWebRequest]::Create($blockListUri)
        $blReq.Method = 'GET'
        $blReq.Timeout = 30000
        $blResp = $blReq.GetResponse()
        $sr = New-Object System.IO.StreamReader($blResp.GetResponseStream())
        [xml]$serverBlocksXml = $sr.ReadToEnd()
        $blResp.Close()

        if ($serverBlocksXml.BlockList.UncommittedBlocks.Block) {
            foreach ($b in $serverBlocksXml.BlockList.UncommittedBlocks.Block) {
                [void]$serverBlockIds.Add($b.Name)
            }
        }
        if ($serverBlocksXml.BlockList.CommittedBlocks.Block) {
            foreach ($b in $serverBlocksXml.BlockList.CommittedBlocks.Block) {
                [void]$serverBlockIds.Add($b.Name)
            }
        }

        # Reconcile server blocks against deterministic IDs
        foreach ($bm in $blockMap) {
            if ($serverBlockIds.Contains($bm.Id)) {
                $bm.Status = 'Uploaded'
            }
        }

        $alreadyUploaded = @($blockMap | Where-Object { $_.Status -eq 'Uploaded' }).Count
        if ($alreadyUploaded -gt 0 -and -not $Quiet) {
            Write-Host "  [+] Authoritative Server Reconciliation: $alreadyUploaded/$totalBlocks blocks already verified on Azure Storage." -ForegroundColor Yellow
        }
    }
    catch [System.Net.WebException] {
        $webEx = $_.Exception
        if ($webEx.Response -and [int]$webEx.Response.StatusCode -eq 404) {
            # 404 is normal for a fresh blob with 0 uploaded blocks
            Write-Verbose "Blob block list returned 404 (fresh blob upload)."
        }
        elseif ($webEx.Response -and ([int]$webEx.Response.StatusCode -eq 403 -or [int]$webEx.Response.StatusCode -eq 401)) {
            throw [System.Security.Authentication.AuthenticationException]"Azure Storage SAS token is invalid or expired (HTTP $([int]$webEx.Response.StatusCode))."
        }
        else {
            Write-Warning "Azure blocklist query warning: $($webEx.Message)"
        }
    }
    catch {
        Write-Warning "Block reconciliation notice: $($_.Exception.Message)"
    }

    # 7. Write-Ahead Session Persistence
    $session = [PSCustomObject]@{
        UploadId         = $UploadId
        PackageId        = $PackageId
        AppId            = if ($AppId) { $AppId } elseif ($existingSession) { $existingSession.AppId } else { '' }
        ContentVersionId = if ($ContentVersionId) { $ContentVersionId } elseif ($existingSession) { $existingSession.ContentVersionId } else { '' }
        FileId           = if ($FileId) { $FileId } elseif ($existingSession) { $existingSession.FileId } else { '' }
        FileDigest       = $fileHash
        SourceFilePath   = $resolvedPath
        FileSize         = $fileLength
        SasUriExpiryUtc  = if ($SasUriExpiryUtc -ne [datetime]::MinValue) { $SasUriExpiryUtc.ToUniversalTime().ToString('o') } elseif ($existingSession) { $existingSession.SasUriExpiryUtc } else { '' }
        TotalBlocks      = $totalBlocks
        Blocks           = $blockMap
        State            = 'UploadingBlocks'
        LastUpdatedUtc   = (Get-Date).ToUniversalTime().ToString('o')
    }

    $session | ConvertTo-Json -Depth 10 | Out-File -FilePath $sessionFile -Force -Encoding utf8

    if (-not $Quiet) {
        Write-Host "  [+] Uploading $($fileItem.Name) ($([Math]::Round($fileLength / 1MB, 2)) MB across $totalBlocks blocks)..." -ForegroundColor Cyan
    }

    # 8. Upload Pending Blocks
    $fileStream = [System.IO.File]::OpenRead($resolvedPath)
    $buffer = New-Object byte[] $chunkSizeBytes
    $uploadSw = [System.Diagnostics.Stopwatch]::StartNew()
    $bytesTransferredThisRun = [int64]0

    try {
        for ($i = 0; $i -lt $totalBlocks; $i++) {
            # Skip before touching the disk so a resumed upload does not re-read blocks already on the server
            $currentBlock = $blockMap[$i]
            if ($currentBlock.Status -eq 'Uploaded') {
                continue
            }

            $fileStream.Position = [int64]$i * [int64]$chunkSizeBytes
            $bytesRead = $fileStream.Read($buffer, 0, $chunkSizeBytes)
            if ($bytesRead -le 0) { break }

            # Check SAS Expiration mid-upload
            if ($SasUriExpiryUtc -ne [datetime]::MinValue -and [DateTime]::UtcNow -ge $SasUriExpiryUtc) {
                $session.State = 'Expired'
                $session.LastUpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
                $session | ConvertTo-Json -Depth 10 | Out-File -FilePath $sessionFile -Force -Encoding utf8
                throw [System.TimeoutException]"Azure Storage SAS upload URI expired during block upload."
            }

            # Transactional Write-Ahead status
            $currentBlock.Status = 'Uploading'
            $blockUri = $SasUri + $separator + "comp=block&blockid=" + [System.Uri]::EscapeDataString($currentBlock.Id)

            $retry = 0
            $uploaded = $false

            while (-not $uploaded -and $retry -le $MaxRetries) {
                try {
                    $request = [System.Net.HttpWebRequest]::Create($blockUri)
                    $request.Method = 'PUT'
                    $request.ContentLength = $bytesRead
                    $request.Headers.Add('x-ms-blob-type', 'BlockBlob')
                    $request.Timeout = 120000

                    $reqStream = $request.GetRequestStream()
                    $reqStream.Write($buffer, 0, $bytesRead)
                    $reqStream.Close()

                    $response = $request.GetResponse()
                    $response.Close()
                    $uploaded = $true
                    $bytesTransferredThisRun += $bytesRead

                    # Confirmed upload
                    $currentBlock.Status = 'Uploaded'
                    $session.LastUpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
                    $session | ConvertTo-Json -Depth 10 | Out-File -FilePath $sessionFile -Force -Encoding utf8
                }
                catch [System.Net.WebException] {
                    $webEx = $_.Exception
                    if ($webEx.Response -and ([int]$webEx.Response.StatusCode -eq 403 -or [int]$webEx.Response.StatusCode -eq 401)) {
                        $session.State = 'Expired'
                        $session.LastUpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
                        $session | ConvertTo-Json -Depth 10 | Out-File -FilePath $sessionFile -Force -Encoding utf8
                        throw [System.Security.Authentication.AuthenticationException]"Azure Storage SAS token is invalid or expired during block upload (HTTP $([int]$webEx.Response.StatusCode))."
                    }

                    $retry++
                    if ($retry -gt $MaxRetries) {
                        $currentBlock.Status = 'Failed'
                        $session.State = 'Failed'
                        $session.LastUpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
                        $session | ConvertTo-Json -Depth 10 | Out-File -FilePath $sessionFile -Force -Encoding utf8
                        throw "Failed to upload block $i after $MaxRetries retries: $($webEx.Message)"
                    }
                    $delay = [Math]::Pow(2, $retry)
                    Write-Warning "Block $i failed ($($webEx.Message)). Retrying in $delay seconds..."
                    Start-Sleep -Seconds $delay
                }
                catch {
                    $retry++
                    if ($retry -gt $MaxRetries) {
                        $currentBlock.Status = 'Failed'
                        $session.State = 'Failed'
                        $session.LastUpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
                        $session | ConvertTo-Json -Depth 10 | Out-File -FilePath $sessionFile -Force -Encoding utf8
                        throw "Failed to upload block $i after $MaxRetries retries: $($_.Exception.Message)"
                    }
                    $delay = [Math]::Pow(2, $retry)
                    Write-Warning "Block $i failed ($($_.Exception.Message)). Retrying in $delay seconds..."
                    Start-Sleep -Seconds $delay
                }
            }

            $percent = [int]((($i + 1) / $totalBlocks) * 100)
            Write-Progress -Activity "Uploading to Azure Block Blob" -Status "$percent% Complete (Block $($i + 1) of $totalBlocks)" -PercentComplete $percent
        }
    }
    finally {
        $fileStream.Close()
        $uploadSw.Stop()
        Write-Progress -Activity "Uploading to Azure Block Blob" -Completed
    }

    # 9. Commit Ordered Block List
    if (-not $Quiet) {
        Write-Host "  [+] Committing full block list to Azure Storage..." -ForegroundColor Cyan
    }
    $commitUri = $SasUri + $separator + "comp=blocklist"

    $xmlBuilder = New-Object System.Text.StringBuilder
    [void]$xmlBuilder.Append('<?xml version="1.0" encoding="utf-8"?><BlockList>')
    foreach ($bm in $blockMap) {
        [void]$xmlBuilder.Append("<Latest>$($bm.Id)</Latest>")
    }
    [void]$xmlBuilder.Append('</BlockList>')

    $xmlBytes = [System.Text.Encoding]::UTF8.GetBytes($xmlBuilder.ToString())

    $commitReq = [System.Net.HttpWebRequest]::Create($commitUri)
    $commitReq.Method = 'PUT'
    $commitReq.ContentType = 'application/xml'
    $commitReq.ContentLength = $xmlBytes.Length
    $commitReq.Timeout = 60000

    $cStream = $commitReq.GetRequestStream()
    $cStream.Write($xmlBytes, 0, $xmlBytes.Length)
    $cStream.Close()

    $commitResp = $commitReq.GetResponse()
    $commitResp.Close()

    $session.State = 'Succeeded'
    $session.LastUpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $session | ConvertTo-Json -Depth 10 | Out-File -FilePath $sessionFile -Force -Encoding utf8

    $elapsedSec = [Math]::Max(0.1, $uploadSw.Elapsed.TotalSeconds)
    $mbps = [Math]::Round(($bytesTransferredThisRun / 1MB) / $elapsedSec, 2)
    $totalMb = [Math]::Round($fileLength / 1MB, 2)
    $newBlocks = $totalBlocks - $alreadyUploaded
    $shortHash = if ($fileHash.Length -ge 16) { $fileHash.Substring(0, 16) + '...' } else { $fileHash }

    if ($CopyReceipt) {
        try {
            $mdBlob = @(
                "### Azure Storage Block Blob Commit Receipt"
                ""
                "| Field | Value |"
                "| :--- | :--- |"
                "| **File Name** | ``$($fileItem.Name)`` |"
                "| **Payload Size** | $totalMb MB ($fileLength bytes) |"
                "| **Block Summary** | $totalBlocks total ($newBlocks uploaded, $alreadyUploaded resumed) |"
                "| **Throughput** | $mbps MB/s ($([Math]::Round($elapsedSec, 1))s transfer) |"
                "| **SHA-256** | ``$fileHash`` |"
            ) -join "`r`n"
            Set-Clipboard -Value $mdBlob -ErrorAction Stop
        } catch { }
    }

    if ($CopyJson) {
        try {
            $jsonBlob = [ordered]@{
                FileName      = $fileItem.Name
                FileLength    = $fileLength
                PayloadMb     = $totalMb
                TotalBlocks   = $totalBlocks
                UploadedBlocks= $newBlocks
                ResumedBlocks = $alreadyUploaded
                ThroughputMbps= $mbps
                ElapsedSec    = [Math]::Round($elapsedSec, 1)
                Sha256        = $fileHash
                State         = 'Committed'
            } | ConvertTo-Json -Depth 4
            Set-Clipboard -Value $jsonBlob -ErrorAction Stop
        } catch { }
    }

    if ($CopyTsv) {
        try {
            $tsvBlob = "FileName`tFileLength`tPayloadMb`tTotalBlocks`tUploadedBlocks`tResumedBlocks`tThroughputMbps`tElapsedSec`tSha256`r`n$($fileItem.Name)`t$fileLength`t$totalMb`t$totalBlocks`t$newBlocks`t$alreadyUploaded`t$mbps`t$([Math]::Round($elapsedSec, 1))`t$fileHash"
            Set-Clipboard -Value $tsvBlob -ErrorAction Stop
        } catch { }
    }

    if (-not $Quiet) {
        Write-Host "  [##########] 100% | Azure Block Blob Commit Confirmed ($totalBlocks/$totalBlocks blocks, $mbps MB/s)" -ForegroundColor Green
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkGreen
        Write-Host "  | AZURE STORAGE BLOCK BLOB COMMIT RECEIPT                 [COMMITTED]  |" -ForegroundColor Green
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkGreen
        Write-Host ("  | File Name     : {0,-52} |" -f $fileItem.Name) -ForegroundColor White
        Write-Host ("  | Payload Size  : {0,-52} |" -f "$totalMb MB ($fileLength bytes)") -ForegroundColor Gray
        Write-Host ("  | Block Summary : {0,-52} |" -f "$totalBlocks total ($newBlocks uploaded, $alreadyUploaded resumed)") -ForegroundColor Cyan
        Write-Host ("  | Throughput    : {0,-52} |" -f "$mbps MB/s ($([Math]::Round($elapsedSec, 1))s transfer)") -ForegroundColor Gray
        Write-Host ("  | SHA-256       : {0,-52} |" -f $shortHash) -ForegroundColor Gray
        if ($CopyReceipt) {
            Write-Host "  | [CLIPBOARD] Commit receipt (Markdown) copied to clipboard.           |" -ForegroundColor Green
        }
        if ($CopyJson) {
            Write-Host "  | [CLIPBOARD] Commit receipt (JSON) copied to clipboard.               |" -ForegroundColor Green
        }
        if ($CopyTsv) {
            Write-Host "  | [CLIPBOARD] Commit receipt (TSV) copied to clipboard.                |" -ForegroundColor Green
        }
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkGreen
    }
    return $true
}
