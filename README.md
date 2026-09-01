# 💼 WingetIntune

> **Enterprise Win32 App Packaging Engine & Microsoft Graph Cloud Publisher with Type-Safe Package Adapters and Durable Azure SAS Upload State Machine for PowerShell 7+ (LTS).**

[![PowerShell Gallery](https://img.shields.io/badge/PowerShell%20Gallery-WingetIntune-blue.svg)](https://www.powershellgallery.com/packages/WingetIntune)
[![PowerShell Version](https://img.shields.io/badge/PowerShell-7.2%2B%20LTS-blue)](https://github.com/PowerShell/PowerShell)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Microsoft%20Intune%20%7C%20Win32-lightgrey.svg)](https://learn.microsoft.com/en-us/mem/intune/apps/apps-win32-app-management)

---

## 🎯 The Problem: Why Standard Intune Win32 Packaging Fails in Production

Deploying third-party applications via Microsoft Intune Win32 Apps (`.intunewin`) is essential for modern enterprise endpoint management. However, the standard packaging and ingestion workflow suffers from severe real-world production pitfalls:

1. **Session 0 Isolation & Silent UI Hangs**:
   Installers executed by the Intune Management Extension (IME) run under `NT AUTHORITY\SYSTEM` in Session 0. Many vendor installers spawn background dialogs (e.g. driver prompts, license acceptances, telemetry checkboxes) that cannot display a window in Session 0. The installation hangs silently until Intune's **60-minute IME timeout** triggers, reporting `0x87D1041C` (Fatal Error).
   *Reference:* [Microsoft Learn — Troubleshoot Win32 app installations in Intune](https://learn.microsoft.com/en-us/mem/intune/apps/apps-win32-troubleshoot)

2. **MSI Mutex Collision (Error `1618`)**:
   If Windows Update or another application installation is active in the background, the global MSI mutex (`_MSIExecute`) is locked. Standard installer wrappers crash immediately with exit code `1618` (`ERROR_INSTALL_ALREADY_RUNNING`).
   *Reference:* [Microsoft Learn — Windows Installer Error Codes](https://learn.microsoft.com/en-us/windows/win32/msi/error-codes)

3. **IME 32-Bit WOW64 Redirection & Infinite Reinstall Loops**:
   The Intune Management Extension (IME) agent runs as a 32-bit service (`C:\Program Files (x86)\Microsoft Intune Management Extension`). When a 32-bit detection script queries `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`, Windows automatically redirects the query to `HKLM:\SOFTWARE\WOW6432Node`. For 64-bit software, standard detection scripts report the app as missing, triggering **infinite re-installation loops** across the entire fleet.
   *Reference:* [Microsoft Learn — Win32 app detection rules](https://learn.microsoft.com/en-us/mem/intune/apps/apps-win32-add#step-4-detection-rules)

4. **Ephemeral SAS Expiry on Large File Uploads**:
   Intune's backend provisions Azure Storage SAS URIs with short lifetimes (typically 1 hour). When uploading large packages (2GB+ games, CAD software, developer toolchains), a network drop or bandwidth throttling causes the SAS token to expire. Generic upload scripts fail with `HTTP 403 AuthenticationFailed` and cannot resume because the underlying Intune `mobileAppContentFile` transaction has timed out.
   *Reference:* [Microsoft Graph API — mobileAppContentFile resource](https://learn.microsoft.com/en-us/graph/api/resources/intune-apps-mobileappcontentfile)

5. **Manual Portal Fatigue**:
   Packaging and deploying a single application manually requires downloading the installer, locating silent switches, crafting custom detection rules, running `IntuneWinAppUtil.exe`, logging into the Intune Admin Portal, and clicking through 15 wizard screens.

---

## 🛡️ How WingetIntune Solves It

`WingetIntune` automates the entire lifecycle—from public Winget community manifests to compiled, encrypted `.intunewin` packages and direct Microsoft Graph cloud deployment.

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                              WINGETINTUNE CLOUD PIPELINE                               │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ 1. MANIFEST   ──► Fetches official Winget YAML (Resolves x64/x86 & declared switches)  │
│ 2. ADAPTER    ──► Maps InstallerType (MSI, Inno, NSIS, WiX/Burn, MSIX, Custom EXE)     │
│ 3. WATCHDOG   ──► Generates Install.ps1 with _MSIExecute lock wait & Session 0 watchdog │
│ 4. DETECTION  ──► Generates Detect.ps1 querying 64-bit & 32-bit views via OpenBaseKey  │
│ 5. COMPILE    ──► Auto-downloads official IntuneWinAppUtil.exe & builds .intunewin     │
│ 6. UPLOAD     ──► 6MB Chunked Azure SAS Uploader with Durable JSON Session Resume Map  │
│ 7. COMMIT     ──► Commits file with XML encryption metadata & binds contentVersion     │
│ 8. ASSIGN     ──► Programmatically assigns to Entra ID Security Groups                 │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 🚀 Quick Start

### 1. Compile a `.intunewin` Package from any Winget ID
```powershell
Import-Module WingetIntune

# Package 7-Zip into a production-ready Intune Win32 App
New-IntuneWingetPackage -PackageId "7zip.7zip" -OutputFolder "C:\dist\7zip"
```

### 2. 1-Click Package & Publish Directly to Microsoft Intune
```powershell
# Compile, upload via chunked SAS, commit, and assign to 'All Devices'
New-IntuneWingetPackage -PackageId "Git.Git" -Publish -AssignTo "All Devices" -Intent Required
```

### 3. Generate Endpoint Analytics Proactive Remediations
```powershell
# Generates paired Detect.ps1 and Remediate.ps1 scripts
New-IntuneRemediation -PackageId "Zoom.Zoom" -MinVersion "6.0.0" -OutputFolder "C:\Remediations\Zoom"
```

---

## 📦 Core Cmdlets & Capabilities

### `New-IntuneWingetPackage`
The primary packaging engine. Automatically fetches manifest metadata, applies type-safe adapter switches, generates detection scripts, and compiles `.intunewin` using official Microsoft tooling.

### `Publish-IntuneWingetApp` (Alias: `Publish-IntuneWin32App`)
Automates the full Microsoft Graph Win32 ingestion state machine:
1. Creates `win32LobApp` entity in Intune Graph.
2. Extracts encryption metadata (`Contents\detection.xml`) from the `.intunewin` archive.
3. Creates `contentVersion` and `mobileAppContentFile` resources.
4. Uploads 6MB block chunks to Azure Storage SAS URI using `Send-AzureBlockBlob`.
5. Commits the file with encryption keys (`fileDigest`, `encryptionKey`, `macKey`, `iv`).
6. Binds `committedContentVersion` to activate the app for deployment.

### `Get-PackageAdapter`
Type-safe adapter dispatcher resolving installer behaviors:
- **MSI Adapter**: Enforces `/qn REBOOT=ReallySuppress` and MSI ProductCode detection.
- **Inno Setup Adapter**: Enforces `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-` and dynamic `unins*.exe` registry resolution.
- **Nullsoft (NSIS) Adapter**: Enforces case-sensitive `/S` and `/D=` destination path handling.
- **WiX / Burn Adapter**: Enforces `/quiet /norestart`.
- **MSIX Provisioning Adapter**: Enforces `DISM /Online /Add-ProvisionedAppxPackage` for machine-wide provisioning.

### `Add-IntuneWingetAssignment`
Assigns deployed Win32 apps to Entra ID security groups, 'All Devices', or 'All Users' with configurable intents (`Required`, `Available`, `Uninstall`).

### `Sync-IntuneWingetCatalog`
Scans tenant Win32 apps and identifies available package updates from the Winget repository for staged deployment rings.

---

## 🔗 Official Microsoft Reference Links & Documentation

- [Win32 app management in Microsoft Intune](https://learn.microsoft.com/en-us/mem/intune/apps/apps-win32-app-management)
- [Add and assign Win32 apps in Microsoft Intune](https://learn.microsoft.com/en-us/mem/intune/apps/apps-win32-add)
- [Microsoft Intune Win32 App Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool)
- [Microsoft Graph API — Win32LobApp Resource](https://learn.microsoft.com/en-us/graph/api/resources/intune-apps-win32lobapp)
- [Intune Endpoint Analytics Proactive Remediations](https://learn.microsoft.com/en-us/mem/analytics/proactive-remediations)
- [Troubleshoot Win32 app installations](https://learn.microsoft.com/en-us/mem/intune/apps/apps-win32-troubleshoot)

---

## 📄 License
MIT © 2026 [Matthew Bubb](https://github.com/thebubbsy) | [OnYaChamp.com](https://onyachamp.com)
