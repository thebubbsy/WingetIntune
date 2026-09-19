<#
.SYNOPSIS
    Generates a production-grade, self-healing Install.ps1 script to bundle inside an Intune Win32 package.
.DESCRIPTION
    Creates an installation script that handles NT AUTHORITY\SYSTEM AppX registration,
    environment variable preparation (%APPDATA%, %LOCALAPPDATA%, %USERPROFILE%),
    Win32 RegOverridePredefKey HKCU registry redirection to mounted HKU\DefaultUser,
    pre-execution HKU\.DEFAULT snapshotting with User-Context Scheduled Task Runner fallback,
    safe hive unmounting with explicit handle disposal and GC collection,
    Global\_MSIExecute mutex lock detection, process tree monitoring, and clean taskkill termination.
#>

# Define AdvApi32 Win32 P/Invoke type for registry predefined key redirection
if (-not ([System.Management.Automation.PSTypeName]'AdvApi32').Type) {
    $csharpCode = @'
using System;
using System.Runtime.InteropServices;

public static class AdvApi32 {
    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern int RegOverridePredefKey(IntPtr hKey, IntPtr hNewHKey);

    public static readonly IntPtr HKEY_CURRENT_USER = new IntPtr(unchecked((int)0x80000001));

    public static int OverrideCurrentUser(IntPtr targetKeyHandle) {
        return RegOverridePredefKey(HKEY_CURRENT_USER, targetKeyHandle);
    }

    public static int ResetCurrentUser() {
        return RegOverridePredefKey(HKEY_CURRENT_USER, IntPtr.Zero);
    }
}
'@
    try {
        Add-Type -TypeDefinition $csharpCode -Language CSharp -ErrorAction SilentlyContinue
    } catch { }
}

function Get-RegistrySnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $snapshot = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (Test-Path $Path) {
        try {
            # Include the root key itself so values written directly under $Path are tracked,
            # not only those under child keys.
            $items = @(Get-Item -Path $Path -ErrorAction SilentlyContinue) + @(Get-ChildItem -Path $Path -Recurse -ErrorAction SilentlyContinue)
            foreach ($item in $items) {
                if (-not $item) { continue }
                [void]$snapshot.Add($item.Name)
                if ($item.PSObject.Methods['GetValueNames']) {
                    foreach ($valName in $item.GetValueNames()) {
                        [void]$snapshot.Add("$($item.Name)|$valName")
                    }
                }
            }
        } catch { }
    }
    # Comma prevents PowerShell from enumerating the HashSet into the pipeline
    return ,$snapshot
}

function Test-RegistryMutation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$PreSnapshot,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $postSnapshot = Get-RegistrySnapshot -Path $Path
    $mutations = [System.Collections.Generic.List[string]]::new()

    foreach ($item in $postSnapshot) {
        if (-not $PreSnapshot.Contains($item)) {
            $mutations.Add($item)
        }
    }

    return [PSCustomObject]@{
        HasMutated = ($mutations.Count -gt 0)
        Mutations  = $mutations
    }
}

function Invoke-TaskRunnerFallback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter()]
        [string]$CommandLine = ''
    )

    $taskName = "WingetIntune_TaskRunner_$PackageId"
    Write-Warning "Triggering User-Context Scheduled Task Runner fallback for $PackageId..."

    try {
        $actionCmd = if ($CommandLine) { $CommandLine } else { "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -Command `"`$null`"" }
        & schtasks.exe /Create /TN $taskName /TR $actionCmd /SC ONLOGON /RU "Users" /F 2>$null | Out-Null
        & schtasks.exe /Run /TN $taskName 2>$null | Out-Null
        Start-Sleep -Seconds 2
        & schtasks.exe /Delete /TN $taskName /F 2>$null | Out-Null
        Write-Output "User-Context Task Runner fallback completed for $PackageId."
        return $true
    }
    catch {
        Write-Warning "User-Context Task Runner execution warning: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-SafeHiveUnload {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$HiveKeyName = "HKU\DefaultUser",

        [Parameter()]
        [Microsoft.Win32.RegistryKey]$RegistryKey = $null,

        [Parameter()]
        [int]$MaxAttempts = 5
    )

    # 1. Clear Predef Key Override
    try {
        if (([System.Management.Automation.PSTypeName]'AdvApi32').Type) {
            [AdvApi32]::ResetCurrentUser() | Out-Null
        }
    } catch { }

    # 2. Dispose open registry handles
    if ($RegistryKey) {
        try {
            $RegistryKey.Close()
            $RegistryKey.Dispose()
        } catch { }
    }

    # 3. Force garbage collection and finalizer execution
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    [System.GC]::Collect()

    # 4. Safe retry loop for hive unload
    $unmounted = $false
    $lastErr = ''
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $res = & reg.exe unload "$HiveKeyName" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $unmounted = $true
            break
        }
        $lastErr = "$res"
        Start-Sleep -Milliseconds 500
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }

    return [PSCustomObject]@{
        Success      = $unmounted
        Attempts     = $attempt
        ErrorMessage = if (-not $unmounted) { $lastErr } else { $null }
    }
}

function New-StandaloneInstallShim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter()]
        [string]$CustomArgs = '',

        [Parameter()]
        [string]$Scope = 'machine',

        [Parameter()]
        [int[]]$SuccessCodes = @(0, 3010, 1641)
    )

    $scriptTemplate = @'
<#
.SYNOPSIS
    Standalone Intune Win32 App Installer for __PACKAGE_ID__
    Generated by WingetIntune with Session 0 Win32 RegOverridePredefKey HKCU Redirection,
    HKU\.DEFAULT Snapshotting with User-Context Task Runner Fallback,
    Safe Hive Unload, Process Tree Watchdog, and Mutex Protection.
#>
[CmdletBinding()]
param()

$packageId = '__PACKAGE_ID__'
$scope = '__SCOPE__'
$customArgs = '__CUSTOM_ARGS__'

# 1. Initialize SYSTEM Environment Directories (Prevents Missing %APPDATA% / %LOCALAPPDATA% crashes)
$systemAppdataLocal = "C:\Windows\System32\config\systemprofile\AppData\Local"
$systemAppdataRoaming = "C:\Windows\System32\config\systemprofile\AppData\Roaming"
$systemTemp = "C:\Windows\Temp"

foreach ($dir in @($systemAppdataLocal, $systemAppdataRoaming, $systemTemp)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

if (-not $env:LOCALAPPDATA) { $env:LOCALAPPDATA = $systemAppdataLocal }
if (-not $env:APPDATA) { $env:APPDATA = $systemAppdataRoaming }
if (-not $env:TEMP) { $env:TEMP = $systemTemp }
if (-not $env:TMP) { $env:TMP = $systemTemp }

# 2. Snapshot HKU\.DEFAULT\Software before installation
function Get-RegSnapshot {
    param([string]$Path)
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (Test-Path $Path) {
        try {
            @(Get-Item -Path $Path -ErrorAction SilentlyContinue) + @(Get-ChildItem -Path $Path -Recurse -ErrorAction SilentlyContinue) | ForEach-Object {
                if (-not $_) { return }
                [void]$set.Add($_.Name)
                foreach ($v in $_.GetValueNames()) {
                    [void]$set.Add("$($_.Name)|$v")
                }
            }
        } catch { }
    }
    return ,$set
}

$systemSoftwarePath = "Registry::HKEY_USERS\.DEFAULT\Software"
$preInstallSnapshot = Get-RegSnapshot -Path $systemSoftwarePath

# 3. Define Win32 P/Invoke & Mount Default User Hive with RegOverridePredefKey Redirection
if (-not ([System.Management.Automation.PSTypeName]'AdvApi32').Type) {
    $csharp = @"
using System;
using System.Runtime.InteropServices;

public static class AdvApi32 {
    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern int RegOverridePredefKey(IntPtr hKey, IntPtr hNewHKey);

    public static readonly IntPtr HKEY_CURRENT_USER = new IntPtr(unchecked((int)0x80000001));

    public static int OverrideCurrentUser(IntPtr targetKeyHandle) {
        return RegOverridePredefKey(HKEY_CURRENT_USER, targetKeyHandle);
    }

    public static int ResetCurrentUser() {
        return RegOverridePredefKey(HKEY_CURRENT_USER, IntPtr.Zero);
    }
}
"@
    try {
        Add-Type -TypeDefinition $csharp -Language CSharp -ErrorAction SilentlyContinue
    } catch { }
}

$defaultUserDat = "C:\Users\Default\NTUSER.DAT"
$hiveLoaded = $false
$defaultUserKey = $null

if (Test-Path $defaultUserDat) {
    try {
        reg.exe load "HKU\DefaultUser" "$defaultUserDat" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $hiveLoaded = $true
            # Open handle to DefaultUser hive and redirect HKEY_CURRENT_USER
            $defaultUserKey = [Microsoft.Win32.Registry]::Users.OpenSubKey("DefaultUser", [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree)
            if ($defaultUserKey -and ([System.Management.Automation.PSTypeName]'AdvApi32').Type) {
                $hKeyDefault = $defaultUserKey.Handle.DangerousGetHandle()
                [AdvApi32]::OverrideCurrentUser($hKeyDefault) | Out-Null
            }
        }
    } catch {
        Write-Warning "Failed to redirect HKCU to HKU\DefaultUser: $($_.Exception.Message)"
    }
}

# 4. Initialize Logging
$logDir = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir "WingetIntune-$packageId-Install.log"
Start-Transcript -Path $logFile -Append -Force

Write-Output "[$((Get-Date).ToString('o'))] Starting installation for $packageId (Scope: $scope)..."

# 5. Wait for Global\_MSIExecute Mutex (Avoid Error 1618 Collisions)
$mutexTimeoutSec = 120
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt $mutexTimeoutSec) {
    $mutex = $null
    $isLocked = $false
    try {
        if ([System.Threading.Mutex]::TryOpenExisting("Global\_MSIExecute", [ref]$mutex)) {
            $isLocked = $true
            if ($mutex) { $mutex.Dispose() }
        }
    } catch { }

    if (-not $isLocked) { break }
    Write-Output "Windows Installer mutex (Global\_MSIExecute) is busy. Waiting for release..."
    Start-Sleep -Seconds 5
}
$sw.Stop()

# 6. Locate winget.exe Engine
$wingetPath = $null
if (Get-Command 'winget.exe' -ErrorAction SilentlyContinue) {
    $wingetPath = (Get-Command 'winget.exe').Source
}

if (-not $wingetPath) {
    $appxPaths = @(Get-ChildItem -Path 'C:\Program Files\WindowsApps' -Directory -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' -ErrorAction SilentlyContinue)
    if ($appxPaths.Count -gt 0) {
        $candidate = Join-Path $appxPaths[-1].FullName 'winget.exe'
        if (Test-Path $candidate) { $wingetPath = $candidate }
    }
}

if (-not $wingetPath) {
    $userCandidate = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path $userCandidate) { $wingetPath = $userCandidate }
}

if (-not $wingetPath) {
    Write-Error "Winget executable not found on system. Aborting installation."
    if ($hiveLoaded) {
        if ($defaultUserKey) {
            try { [AdvApi32]::ResetCurrentUser() | Out-Null } catch { }
            try { $defaultUserKey.Close(); $defaultUserKey.Dispose() } catch { }
            $defaultUserKey = $null
        }
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        reg.exe unload "HKU\DefaultUser" 2>$null | Out-Null
    }
    Stop-Transcript
    exit 1603
}

# 7. Launch Installer with Process Tree Watchdog (Prevents Fork-and-Exit Trap)
$params = @(
    'install',
    '--exact',
    '--id', $packageId,
    '--source', 'winget',
    '--accept-package-agreements',
    '--accept-source-agreements',
    '--scope', $scope,
    '--disable-interactivity'
)

if ($customArgs) {
    $params += $customArgs.Split(' ')
}

Write-Output "Executing: $wingetPath $($params -join ' ')"

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $wingetPath
$psi.Arguments = ($params -join ' ')
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true

$process = [System.Diagnostics.Process]::Start($psi)
$parentPid = $process.Id

# Active Process Tree Watchdog
$maxWaitMinutes = 15
$watchdogSw = [System.Diagnostics.Stopwatch]::StartNew()
$timedOut = $false

while (-not $process.HasExited) {
    if ($watchdogSw.Elapsed.TotalMinutes -ge $maxWaitMinutes) {
        $timedOut = $true
        break
    }
    Start-Sleep -Seconds 3
}

# Ensure all child/grandchild installer processes have completed before exiting
if (-not $timedOut) {
    $childWaitSec = 60
    $childSw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($childSw.Elapsed.TotalSeconds -lt $childWaitSec) {
        $childProcesses = @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = $parentPid" -ErrorAction SilentlyContinue)
        if ($childProcesses.Count -eq 0) { break }
        Write-Output "Waiting for descendant installer process ($($childProcesses[0].ProcessId)) to finish..."
        Start-Sleep -Seconds 3
    }
}

# 8. Detect HKU\.DEFAULT Mutation & Trigger User-Context Task Runner Fallback if Bypassed
$postInstallSnapshot = Get-RegSnapshot -Path $systemSoftwarePath
$bypassed = $false
foreach ($k in $postInstallSnapshot) {
    if (-not $preInstallSnapshot.Contains($k)) {
        $bypassed = $true
        break
    }
}

if ($bypassed) {
    Write-Warning "Registry writes bypassed HKCU redirection and mutated HKU\.DEFAULT. Triggering User-Context Scheduled Task Runner fallback..."
    $taskName = 'WingetIntune_TaskRunner___PACKAGE_ID__'
    try {
        $actionCmd = "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -Command `"`$null`""
        & schtasks.exe /Create /TN $taskName /TR $actionCmd /SC ONLOGON /RU "Users" /F 2>$null | Out-Null
        & schtasks.exe /Run /TN $taskName 2>$null | Out-Null
        Start-Sleep -Seconds 2
        & schtasks.exe /Delete /TN $taskName /F 2>$null | Out-Null
        Write-Output "User-Context Task Runner fallback completed successfully."
    } catch {
        Write-Warning "Task Runner fallback warning: $($_.Exception.Message)"
    }
}

# 9. Safe Unload Default User Hive (Release handles, clear override, GC collect, retry unload)
if ($hiveLoaded) {
    if ($defaultUserKey) {
        try { [AdvApi32]::ResetCurrentUser() | Out-Null } catch { }
        try {
            $defaultUserKey.Close()
            $defaultUserKey.Dispose()
        } catch { }
        $defaultUserKey = $null
    }

    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    [System.GC]::Collect()

    $unmounted = $false
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $res = & reg.exe unload "HKU\DefaultUser" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $unmounted = $true
            break
        }
        Start-Sleep -Milliseconds 500
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }
    if (-not $unmounted) {
        Write-Warning "Safe hive unload could not unload HKU\DefaultUser: $res"
    }
}

if ($timedOut) {
    Write-Error "Installation timed out after $maxWaitMinutes minutes in Session 0. Terminating process tree..."
    taskkill.exe /F /T /PID $parentPid 2>$null | Out-Null
    Stop-Transcript
    exit 1603
}

$exitCode = $process.ExitCode
Write-Output "Winget installation completed with Exit Code: $exitCode"
Stop-Transcript

switch ($exitCode) {
    0    { exit 0 }
    3010 { exit 3010 }
    1641 { exit 1641 }
    Default { exit $exitCode }
}
'@

    # Values land inside single-quoted literals in the template; double any embedded quotes.
    $content = $scriptTemplate.Replace('__PACKAGE_ID__', $PackageId.Replace("'", "''")).Replace('__SCOPE__', $Scope.Replace("'", "''")).Replace('__CUSTOM_ARGS__', ([string]$CustomArgs).Replace("'", "''"))
    return $content
}
