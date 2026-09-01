@{
    RootModule = 'WingetIntune.psm1'
    ModuleVersion = '1.0.0'
    GUID = '4b1e9c2a-8d7f-402a-9f5e-1c3d5a7b9e20'
    Author = 'Matthew Bubb'
    CompanyName = 'OnYaChamp.com'
    Copyright = '(c) 2026 Matthew Bubb. All rights reserved.'
    Description = 'Enterprise Win32 packaging engine and Microsoft Graph cloud publisher with type-safe package adapters and durable Azure Block Blob upload state machines for PowerShell 7+.'
    PowerShellVersion = '7.2'
    RequiredModules = @()
    FunctionsToExport = @(
        'New-IntuneWingetPackage',
        'Publish-IntuneWingetApp',
        'Add-IntuneWingetAssignment',
        'New-IntuneRemediation',
        'Sync-IntuneWingetCatalog',
        'Get-PackageAdapter'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @('Publish-IntuneWin32App')
    PrivateData = @{
        PSData = @{
            Tags = @('intune', 'winget', 'win32-app', 'intunewin', 'packaging', 'graph-api', 'pwsh7', 'proactive-remediations', 'enterprise')
            LicenseUri = 'https://github.com/thebubbsy/WingetIntune/blob/main/LICENSE'
            ProjectUri = 'https://github.com/thebubbsy/WingetIntune'
        }
    }
}
