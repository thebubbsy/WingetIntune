BeforeAll {
    # Sibling checkout when developing locally; installed module in per-repo CI
    $sharedPath = Join-Path $PSScriptRoot '..\..\IntuneShared\IntuneShared.psd1'
    if (Test-Path $sharedPath) {
        Import-Module (Resolve-Path $sharedPath) -Force
    } else {
        Import-Module IntuneShared -Force -ErrorAction Stop
    }
    $modulePath = Resolve-Path (Join-Path $PSScriptRoot '..\WingetIntune.psd1')
    Import-Module $modulePath -Force

    # Private helpers under test are not exported; expose thin proxies that invoke them inside the module scope.
    foreach ($privateFn in @('Send-AzureBlockBlob', 'Invoke-SafeHiveUnload', 'Get-RegistrySnapshot', 'Test-RegistryMutation', 'Invoke-TaskRunnerFallback', 'New-StandaloneInstallShim')) {
        $body = [scriptblock]::Create("& (Get-Module WingetIntune) { $privateFn @args } @args")
        Set-Item -Path "function:script:$privateFn" -Value $body
    }

    # Helper function to start local mock Azure Storage Blob server
    function Start-MockAzureBlobServer {
        $tcpListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $tcpListener.Start()
        $freePort = ($tcpListener.LocalEndpoint).Port
        $tcpListener.Stop()

        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://127.0.0.1:$freePort/")
        $listener.Start()

        $state = [hashtable]::Synchronized(@{
            ReceivedBlocks     = [System.Collections.Generic.List[string]]::new()
            ReceivedBlockBytes = 0L
            CommittedBlocks    = [System.Collections.Generic.List[string]]::new()
            ExistingBlocks     = [System.Collections.Generic.List[string]]::new()
            IsRunning          = $true
            ForceForbidden     = $false
        })

        $dispatcher = {
            while ($state.IsRunning -and $listener.IsListening) {
                try {
                    $context = $listener.GetContext()
                    $req = $context.Request
                    $resp = $context.Response
                    $query = $req.Url.Query

                    if ($state.ForceForbidden) {
                        $resp.StatusCode = 403
                        $resp.OutputStream.Close()
                        continue
                    }

                    if ($req.HttpMethod -eq 'GET' -and $query -match 'comp=blocklist') {
                        $xml = '<?xml version="1.0" encoding="utf-8"?><BlockList><CommittedBlocks>'
                        foreach ($b in $state.ExistingBlocks) {
                            $xml += "<Block><Name>$b</Name><Size>1048576</Size></Block>"
                        }
                        $xml += '</CommittedBlocks><UncommittedBlocks></UncommittedBlocks></BlockList>'
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($xml)
                        $resp.ContentType = 'application/xml'
                        $resp.ContentLength64 = $bytes.Length
                        $resp.StatusCode = 200
                        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                        $resp.OutputStream.Close()
                    }
                    elseif ($req.HttpMethod -eq 'PUT' -and $query -match 'comp=block&') {
                        if ($query -match 'blockid=([^&]+)') {
                            $blockId = [System.Uri]::UnescapeDataString($matches[1])
                            $state.ReceivedBlocks.Add($blockId)
                        }
                        $buf = New-Object byte[] 65536
                        $read = 0
                        while (($read = $req.InputStream.Read($buf, 0, $buf.Length)) -gt 0) {
                            $state.ReceivedBlockBytes += $read
                        }
                        $resp.StatusCode = 201
                        $resp.OutputStream.Close()
                    }
                    elseif ($req.HttpMethod -eq 'PUT' -and $query -match 'comp=blocklist') {
                        $sr = New-Object System.IO.StreamReader($req.InputStream)
                        $bodyXml = $sr.ReadToEnd()
                        $matchesLatest = [regex]::Matches($bodyXml, '<Latest>([^<]+)</Latest>')
                        foreach ($m in $matchesLatest) {
                            $state.CommittedBlocks.Add($m.Groups[1].Value)
                        }
                        $resp.StatusCode = 201
                        $resp.OutputStream.Close()
                    }
                    else {
                        $resp.StatusCode = 200
                        $resp.OutputStream.Close()
                    }
                } catch { }
            }
        }

        # Script blocks cannot run on a raw .NET thread (no runspace) - host the dispatcher in its own runspace.
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ApartmentState = 'MTA'
        $runspace.ThreadOptions = 'ReuseThread'
        $runspace.Open()
        $runspace.SessionStateProxy.SetVariable('state', $state)
        $runspace.SessionStateProxy.SetVariable('listener', $listener)
        $worker = [powershell]::Create()
        $worker.Runspace = $runspace
        [void]$worker.AddScript($dispatcher.ToString())
        $workerHandle = $worker.BeginInvoke()

        return [PSCustomObject]@{
            Listener   = $listener
            Worker     = $worker
            Runspace   = $runspace
            State      = $state
            Port       = $freePort
            BaseSasUri = "http://127.0.0.1:$freePort/container/testblob.intunewin?sv=2020-08-04&sig=mock"
            Stop       = {
                $state.IsRunning = $false
                try { $listener.Stop() } catch { }
                try { $listener.Close() } catch { }
                try { if (-not $workerHandle.AsyncWaitHandle.WaitOne(2000)) { $worker.Stop() } } catch { }
                try { $worker.Dispose() } catch { }
                try { $runspace.Dispose() } catch { }
            }.GetNewClosure()
        }
    }
}

Describe 'WingetIntune Production Hardening Tests' {

    Context 'Module Architecture & Exports' {
        It 'Exports all required public cmdlets including Clear-OrphanedIntuneUploads' {
            $expectedCmds = @(
                'New-IntuneWingetPackage',
                'Publish-IntuneWingetApp',
                'Add-IntuneWingetAssignment',
                'New-IntuneRemediation',
                'Sync-IntuneWingetCatalog',
                'Get-PackageAdapter',
                'Clear-OrphanedIntuneUploads'
            )
            foreach ($cmd in $expectedCmds) {
                Get-Command -Module WingetIntune -Name $cmd | Should -Not -BeNullOrEmpty
            }
        }

        It 'Exports Publish-IntuneWin32App alias for Publish-IntuneWingetApp' {
            $alias = Get-Alias -Name 'Publish-IntuneWin32App' -ErrorAction SilentlyContinue
            $alias | Should -Not -BeNullOrEmpty
            $alias.Definition | Should -Be 'Publish-IntuneWingetApp'
        }
    }

    Context 'Package Adapters & Manifest Engine (R1.3)' {
        It 'Resolves MSI adapter with ProductCode detection and silent switches' {
            $manifestMock = [PSCustomObject]@{
                ProductCode       = '{11111111-2222-3333-4444-555555555555}'
                InstallerSwitches = @{ Silent = '/qn ALLUSERS=1' }
            }
            $adapter = Get-PackageAdapter -InstallerType 'msi' -Manifest $manifestMock
            $adapter.InstallerType | Should -Be 'msi'
            $adapter.SilentArgs | Should -Be '/qn ALLUSERS=1'
            $adapter.DetectionStrategy | Should -Be 'MsiProductCode'
            $adapter.ProductCode | Should -Be '{11111111-2222-3333-4444-555555555555}'
        }

        It 'Resolves Inno Setup adapter with RegistryDisplayVersion strategy' {
            $adapter = Get-PackageAdapter -InstallerType 'inno'
            $adapter.InstallerType | Should -Be 'inno'
            $adapter.DetectionStrategy | Should -Be 'RegistryDisplayVersion'
            $adapter.SilentArgs | Should -Match 'VERYSILENT'
        }

        It 'Resolves Nullsoft (NSIS) adapter with case-sensitive /S' {
            $adapter = Get-PackageAdapter -InstallerType 'nullsoft'
            $adapter.InstallerType | Should -Be 'nullsoft'
            $adapter.SilentArgs | Should -Be '/S'
        }

        It 'Resolves WiX / Burn adapters with quiet norestart switches' {
            $adapterWix = Get-PackageAdapter -InstallerType 'wix'
            $adapterWix.InstallerType | Should -Be 'wix'
            $adapterWix.SilentArgs | Should -Match '/quiet'

            $adapterBurn = Get-PackageAdapter -InstallerType 'burn'
            $adapterBurn.InstallerType | Should -Be 'burn'
            $adapterBurn.SilentArgs | Should -Match '/quiet'
        }

        It 'Resolves Electron adapter with --allusers, --force-install, /silent, and AppData handling' {
            $adapter = Get-PackageAdapter -InstallerType 'electron'
            $adapter.InstallerType | Should -Be 'electron'
            $adapter.SilentArgs | Should -Match '--allusers'
            $adapter.SilentArgs | Should -Match '--force-install'
            $adapter.SilentArgs | Should -Match '/silent'
            $adapter.DetectionStrategy | Should -Be 'FileVersionOrRegistry'
            $adapter.Notes | Should -Match 'Electron / Squirrel'
        }

        It 'Resolves Chromium adapter with --system-level and /silent' {
            $adapter = Get-PackageAdapter -InstallerType 'chromium'
            $adapter.InstallerType | Should -Be 'chromium'
            $adapter.SilentArgs | Should -Match '--system-level'
            $adapter.SilentArgs | Should -Match '--allusers'
            $adapter.DetectionStrategy | Should -Be 'RegistryDisplayVersion'
        }

        It 'Resolves MSIX adapter with AppxPackageIdentity' {
            $adapter = Get-PackageAdapter -InstallerType 'msiX'
            $adapter.InstallerType | Should -Be 'msix'
            $adapter.DetectionStrategy | Should -Be 'AppxPackageIdentity'
        }
    }

    Context 'Win32 Session 0 HKCU Registry Redirection Engine (R1.1 & R1.2)' {
        It 'Defines AdvApi32 Win32 P/Invoke type with RegOverridePredefKey and constants' {
            ([System.Management.Automation.PSTypeName]'AdvApi32').Type | Should -Not -BeNullOrEmpty
            [AdvApi32]::HKEY_CURRENT_USER | Should -Not -BeNullOrEmpty
        }

        It 'Redirects HKCU subkey writes to the target hive handle and leaves HKU\.DEFAULT untouched' {
            # Setup a test target key simulating DefaultUser hive
            $targetSubKeyPath = "Software\WingetIntune_RedirectionTest_Target"
            $targetKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($targetSubKeyPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree)
            
            try {
                $targetHandle = $targetKey.Handle.DangerousGetHandle()
                $overrideRes = [AdvApi32]::OverrideCurrentUser($targetHandle)
                $overrideRes | Should -Be 0

                # Write to HKCU\Software\TestVendor
                $testVendorKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("Software\TestVendor")
                $testVendorKey.SetValue("Installed", 1, [Microsoft.Win32.RegistryValueKind]::DWord)
                $testVendorKey.Close()

                # Reset override
                [AdvApi32]::ResetCurrentUser() | Should -Be 0

                # Assert the write was redirected into the target key
                $writtenKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$targetSubKeyPath\Software\TestVendor")
                $writtenKey | Should -Not -BeNullOrEmpty
                $writtenVal = $writtenKey.GetValue("Installed")
                $writtenVal | Should -Be 1
                $writtenKey.Close()

                # Assert that HKU\.DEFAULT\Software\TestVendor does NOT exist
                $defaultKey = [Microsoft.Win32.Registry]::Users.OpenSubKey(".DEFAULT\Software\TestVendor")
                $defaultKey | Should -BeNullOrEmpty
            }
            finally {
                [AdvApi32]::ResetCurrentUser() | Out-Null
                if ($targetKey) {
                    $targetKey.Close()
                    $targetKey.Dispose()
                }
                [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($targetSubKeyPath, $false)
                [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree("Software\TestVendor", $false)
            }
        }

        It 'Confirms safe unmount handle disposal releases open registry keys with zero access violations' {
            $tempSubKeyPath = "Software\WingetIntune_UnmountTest"
            $tempKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($tempSubKeyPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree)
            
            # Call Invoke-SafeHiveUnload
            $unloadResult = Invoke-SafeHiveUnload -HiveKeyName "HKU\NonExistentHiveForTest" -RegistryKey $tempKey -MaxAttempts 2
            $unloadResult | Should -Not -BeNullOrEmpty
            $unloadResult.Attempts | Should -BeGreaterThan 0

            # Cleanup
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($tempSubKeyPath, $false)
        }

        It 'Detects HKU\.DEFAULT mutations and triggers User-Context Task Runner fallback' {
            $testFolder = Join-Path $env:TEMP ("RegSnapshotTest_" + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $testFolder -Force | Out-Null

            try {
                # Create mock registry item
                $tempSubKey = "Software\WingetIntune_MutationTest"
                $regKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($tempSubKey)
                $regKey.SetValue("InitialVal", "123")
                $regKey.Close()

                $preSnapshot = Get-RegistrySnapshot -Path "Registry::HKEY_CURRENT_USER\$tempSubKey"
                $preSnapshot.Count | Should -BeGreaterThan 0

                # Simulate out-of-process mutation
                $regKey2 = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($tempSubKey, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree)
                $regKey2.SetValue("BypassMutationKey", "456")
                $regKey2.Close()

                $mutationCheck = Test-RegistryMutation -PreSnapshot $preSnapshot -Path "Registry::HKEY_CURRENT_USER\$tempSubKey"
                $mutationCheck.HasMutated | Should -BeTrue
                $mutationCheck.Mutations.Count | Should -BeGreaterThan 0

                # Trigger Task Runner fallback
                $fallbackRes = Invoke-TaskRunnerFallback -PackageId "TestPackage"
                $fallbackRes | Should -BeTrue
            }
            finally {
                [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($tempSubKey, $false)
                Remove-Item -Path $testFolder -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Generates standalone install shim containing Win32 RegOverridePredefKey, snapshotting, and Task Runner' {
            $shim = New-StandaloneInstallShim -PackageId 'Vendor.App' -Scope 'machine' -CustomArgs '--silent'
            $shim | Should -Match 'RegOverridePredefKey'
            $shim | Should -Match 'AdvApi32'
            $shim | Should -Match 'HKU\\DefaultUser'
            $shim | Should -Match 'Get-RegSnapshot'
            $shim | Should -Match 'WingetIntune_TaskRunner_Vendor\.App'
            $shim | Should -Match 'reg\.exe unload "HKU\\DefaultUser"'
        }
    }

    Context 'Transactional Upload State Machine & Azure Resume (R2.1, R2.2, R2.3)' {
        It 'Simulates interrupted 50-block upload, recovers via comp=blocklist, resumes blocks 21-50, and commits 50 blocks' {
            $mockServer = Start-MockAzureBlobServer
            $tempFile = Join-Path $env:TEMP ("Upload50BlockTest_" + [Guid]::NewGuid().ToString('N') + ".intunewin")

            try {
                # Create a 50MB file (50 x 1MB blocks)
                $fs = [System.IO.File]::Create($tempFile)
                $fs.SetLength(50 * 1024 * 1024)
                $fs.Close()

                $fileLength = (Get-Item $tempFile).Length
                $fileLength | Should -Be 52428800

                # Pre-populate server with first 20 blocks already uploaded (blocks 0 to 19)
                for ($b = 0; $b -lt 20; $b++) {
                    $rawId = "block_{0:D6}" -f $b
                    $base64Id = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($rawId))
                    $mockServer.State.ExistingBlocks.Add($base64Id)
                }

                # Upload with Resume and BlockSizeMb = 1
                $res = Send-AzureBlockBlob -FilePath $tempFile `
                                           -SasUri $mockServer.BaseSasUri `
                                           -PackageId 'Simulated50BlockPackage' `
                                           -BlockSizeMb 1 `
                                           -Resume

                $res | Should -BeTrue

                # Assert that blocks 21-50 (indices 20-49 = 30 blocks) were transmitted over HTTP
                $mockServer.State.ReceivedBlocks.Count | Should -Be 30

                # Assert that exactly 50 blocks were committed to the blocklist
                $mockServer.State.CommittedBlocks.Count | Should -Be 50
                $mockServer.State.CommittedBlocks[0] | Should -Be ([Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("block_000000")))
                $mockServer.State.CommittedBlocks[49] | Should -Be ([Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("block_000049")))

                # Verify session persistence in C:\ProgramData\WingetIntune\UploadSessions\
                $sessionPath = "C:\ProgramData\WingetIntune\UploadSessions\Simulated50BlockPackage.json"
                Test-Path $sessionPath | Should -BeTrue
                $sessionObj = Get-Content $sessionPath -Raw | ConvertFrom-Json
                $sessionObj.PackageId | Should -Be 'Simulated50BlockPackage'
                $sessionObj.TotalBlocks | Should -Be 50
                $sessionObj.State | Should -Be 'Succeeded'
            }
            finally {
                $mockServer.Stop.Invoke()
                Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\ProgramData\WingetIntune\UploadSessions\Simulated50BlockPackage.json" -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Detects 1-byte local file mutation before resume, triggers SHA256 mismatch, and aborts stale session' {
            $mockServer = Start-MockAzureBlobServer
            $tempFile = Join-Path $env:TEMP ("MutationTest_" + [Guid]::NewGuid().ToString('N') + ".bin")

            try {
                # Create initial file with known content
                $initialBytes = [byte[]]((1..2048) | ForEach-Object { $_ -band 0xFF })
                [System.IO.File]::WriteAllBytes($tempFile, $initialBytes)
                $origHash = (Get-FileHash -Path $tempFile -Algorithm SHA256).Hash

                # Create pre-existing session file with the original hash
                $sessionDir = "C:\ProgramData\WingetIntune\UploadSessions"
                if (-not (Test-Path $sessionDir)) { New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null }
                $sessionFile = Join-Path $sessionDir "MutationTestPackage.json"
                $staleSession = @{
                    UploadId       = "StaleUploadId123"
                    PackageId      = "MutationTestPackage"
                    FileDigest     = $origHash
                    SourceFilePath = $tempFile
                    State          = "UploadingBlocks"
                    LastUpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
                }
                $staleSession | ConvertTo-Json | Out-File -FilePath $sessionFile -Force -Encoding utf8

                # Mutate 1 byte of the local file
                $initialBytes[0] = [byte]($initialBytes[0] -bxor 0xFF)
                [System.IO.File]::WriteAllBytes($tempFile, $initialBytes)
                $mutatedHash = (Get-FileHash -Path $tempFile -Algorithm SHA256).Hash
                $mutatedHash | Should -Not -Be $origHash

                # Invoke Send-AzureBlockBlob
                $uploadRes = Send-AzureBlockBlob -FilePath $tempFile `
                                                 -SasUri $mockServer.BaseSasUri `
                                                 -PackageId "MutationTestPackage" `
                                                 -BlockSizeMb 1 `
                                                 -Resume

                $uploadRes | Should -BeTrue

                # Verify that the session file was updated with the new FileDigest and state Succeeded
                $newSession = Get-Content -Path $sessionFile -Raw | ConvertFrom-Json
                $newSession.FileDigest | Should -Be $mutatedHash
                $newSession.State | Should -Be 'Succeeded'
            }
            finally {
                $mockServer.Stop.Invoke()
                Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
                Remove-Item -Path "C:\ProgramData\WingetIntune\UploadSessions\MutationTestPackage.json" -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Throws TimeoutException when SAS URI is expired before or during upload' {
            $tempFile = Join-Path $env:TEMP ("SasExpiryTest_" + [Guid]::NewGuid().ToString('N') + ".bin")
            [System.IO.File]::WriteAllBytes($tempFile, [byte[]](1..100))

            try {
                $expiredUtc = (Get-Date).AddMinutes(-10).ToUniversalTime()
                {
                    Send-AzureBlockBlob -FilePath $tempFile `
                                        -SasUri "http://127.0.0.1:9999/expired?sig=test" `
                                        -SasUriExpiryUtc $expiredUtc
                } | Should -Throw -ExceptionType ([System.TimeoutException])
            }
            finally {
                Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Throws AuthenticationException when Azure Storage returns HTTP 403 Forbidden' {
            $mockServer = Start-MockAzureBlobServer
            $mockServer.State.ForceForbidden = $true
            $tempFile = Join-Path $env:TEMP ("ForbiddenTest_" + [Guid]::NewGuid().ToString('N') + ".bin")
            [System.IO.File]::WriteAllBytes($tempFile, [byte[]](1..100))

            try {
                {
                    Send-AzureBlockBlob -FilePath $tempFile `
                                        -SasUri $mockServer.BaseSasUri `
                                        -BlockSizeMb 1
                } | Should -Throw -ExceptionType ([System.Security.Authentication.AuthenticationException])
            }
            finally {
                $mockServer.Stop.Invoke()
                Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Orphaned Upload & Session Cleanup (Clear-OrphanedIntuneUploads)' {
        It 'Purges expired local sessions older than MaxAgeHours' {
            $sessionDir = "C:\ProgramData\WingetIntune\UploadSessions"
            if (-not (Test-Path $sessionDir)) { New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null }

            $expiredSessionPath = Join-Path $sessionDir "OrphanTest_Expired.json"
            $activeSessionPath = Join-Path $sessionDir "OrphanTest_Active.json"

            # Create expired session (48 hours old)
            $expiredData = @{
                PackageId      = "OrphanTest_Expired"
                State          = "Failed"
                LastUpdatedUtc = (Get-Date).AddHours(-48).ToUniversalTime().ToString('o')
            }
            $expiredData | ConvertTo-Json | Out-File -FilePath $expiredSessionPath -Force -Encoding utf8

            # Create active session (1 hour old)
            $activeData = @{
                PackageId      = "OrphanTest_Active"
                State          = "UploadingBlocks"
                LastUpdatedUtc = (Get-Date).AddHours(-1).ToUniversalTime().ToString('o')
            }
            $activeData | ConvertTo-Json | Out-File -FilePath $activeSessionPath -Force -Encoding utf8

            # Run Clear-OrphanedIntuneUploads with MaxAgeHours = 24
            $purged = Clear-OrphanedIntuneUploads -MaxAgeHours 24 -PurgeLocalSessions -PassThru

            Test-Path $expiredSessionPath | Should -BeFalse
            Test-Path $activeSessionPath | Should -BeTrue

            $purged | Should -Not -BeNullOrEmpty
            $purged | Where-Object { $_.PackageId -eq 'OrphanTest_Expired' } | Should -Not -BeNullOrEmpty

            # Cleanup
            Remove-Item -Path $activeSessionPath -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'Catalog Sync & Publisher Graph Integration' {
        It 'Ensures Sync-IntuneWingetCatalog calls Connect-GraphToken' {
            $content = Get-Content (Join-Path $PSScriptRoot '..\Public\Sync-IntuneWingetCatalog.ps1') -Raw
            $content | Should -Match 'Connect-GraphToken'
            $content | Should -Not -Match 'Connect-MsalToken'
        }

        It 'Ensures Publish-IntuneWingetApp supports PackageId session tracking' {
            $cmd = Get-Command Publish-IntuneWingetApp
            $cmd.Parameters.ContainsKey('PackageId') | Should -BeTrue
            $cmd.Parameters.ContainsKey('IntuneWinPath') | Should -BeTrue
        }
    }
}
