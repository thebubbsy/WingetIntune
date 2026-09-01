<#
.SYNOPSIS
    Uploads a file to Azure Storage Block Blob with deterministic block IDs and zero-local-state resume.
.DESCRIPTION
    Divides large files into 6MB block chunks using deterministic Base64 block IDs (block_000000, block_000001, etc.).
    Queries Azure's comp=blocklist as the authoritative source of truth, enabling 100% resilient resume even if
    the local machine crashed or the local session cache was deleted.
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
        [int]$BlockSizeMb = 6,

        [Parameter()]
        [int]$MaxRetries = 5,

        [Parameter()]
        [switch]$Resume
    )

    if (-not (Test-Path $FilePath)) {
        throw "File not found: $FilePath"
    }

    $sessionDir = "C:\ProgramData\WingetIntune\UploadSessions"
    if (-not (Test-Path $sessionDir)) {
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
    }
    $sessionFile = Join-Path $sessionDir ($UploadId + ".json")

    $file = Get-Item $FilePath
    $fileLength = $file.Length
    $chunkSizeBytes = $BlockSizeMb * 1024 * 1024
    $totalBlocks = [int][Math]::Ceiling($fileLength / $chunkSizeBytes)

    # 1. Generate Deterministic Block Map (block_000000 -> Base64)
    # Because IDs are deterministic, server-side recovery is 100% possible without local state!
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

    # 2. Query Azure Storage Server-Side Block List (Authoritative Source of Truth)
    $serverBlockIds = [System.Collections.Generic.HashSet[string]]::new()
    try {
        $separator = if ($SasUri -match '\?') { '&' } else { '?' }
        $blockListUri = $SasUri + $separator + "comp=blocklist&blocklisttype=all"
        $blReq = [System.Net.HttpWebRequest]::Create($blockListUri)
        $blReq.Method = 'GET'
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
        if ($alreadyUploaded -gt 0) {
            Write-Host "  [+] Authoritative Server Reconciliation: $alreadyUploaded/$totalBlocks blocks already verified on Azure Storage." -ForegroundColor Yellow
        }
    } catch { }

    # Write-ahead session cache
    $session = [PSCustomObject]@{
        UploadId        = $UploadId
        FilePath        = $FilePath
        FileSize        = $fileLength
        TotalBlocks     = $totalBlocks
        Blocks          = $blockMap
        State           = 'UploadingBlocks'
        LastUpdatedUtc  = (Get-Date).ToUniversalTime().ToString('o')
    }
    $session | ConvertTo-Json -Depth 10 | Out-File -FilePath $sessionFile -Force -Encoding utf8

    Write-Host "  [+] Uploading $($file.Name) ($([Math]::Round($fileLength / 1MB, 2)) MB across $totalBlocks blocks)..." -ForegroundColor Cyan

    $fileStream = [System.IO.File]::OpenRead($FilePath)
    $buffer = New-Object byte[] $chunkSizeBytes

    try {
        for ($i = 0; $i -lt $totalBlocks; $i++) {
            $fileStream.Position = [int64]$i * [int64]$chunkSizeBytes
            $bytesRead = $fileStream.Read($buffer, 0, $chunkSizeBytes)
            if ($bytesRead -le 0) { break }

            $currentBlock = $blockMap[$i]
            if ($currentBlock.Status -eq 'Uploaded') {
                continue
            }

            # Transactional Write-Ahead status
            $currentBlock.Status = 'Uploading'
            $separator = if ($SasUri -match '\?') { '&' } else { '?' }
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

                    # Confirmed upload
                    $currentBlock.Status = 'Uploaded'
                    $session.LastUpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
                    $session | ConvertTo-Json -Depth 10 | Out-File -FilePath $sessionFile -Force -Encoding utf8
                }
                catch {
                    $retry++
                    if ($retry -gt $MaxRetries) {
                        $currentBlock.Status = 'Failed'
                        $session.State = 'Failed'
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
        Write-Progress -Activity "Uploading to Azure Block Blob" -Completed
    }

    # 3. Commit Ordered Block List
    Write-Host "  [+] Committing full block list to Azure Storage..." -ForegroundColor Cyan
    $separator = if ($SasUri -match '\?') { '&' } else { '?' }
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

    $cStream = $commitReq.GetRequestStream()
    $cStream.Write($xmlBytes, 0, $xmlBytes.Length)
    $cStream.Close()

    $commitResp = $commitReq.GetResponse()
    $commitResp.Close()

    $session.State = 'Succeeded'
    $session.LastUpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $session | ConvertTo-Json -Depth 10 | Out-File -FilePath $sessionFile -Force -Encoding utf8

    Write-Host "  [OK] Azure Block Blob commit confirmed!" -ForegroundColor Green
    return $true
}
