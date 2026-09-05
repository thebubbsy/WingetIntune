BeforeAll {
    $sharedPath = Join-Path $PSScriptRoot '..\..\IntuneShared\IntuneShared.psd1'
    if (Test-Path $sharedPath) {
        Import-Module (Resolve-Path $sharedPath) -Force
    } else {
        Import-Module IntuneShared -Force -ErrorAction SilentlyContinue
    }
    $modulePath = Resolve-Path (Join-Path $PSScriptRoot '..\WingetIntune.psd1')
    Import-Module $modulePath -Force
}

Describe 'WingetIntune Architecture Tests' {
    Context 'Module Exports' {
        It 'Exports all public cmdlets' {
            $cmds = @('New-IntuneWingetPackage', 'Publish-IntuneWingetApp', 'Add-IntuneWingetAssignment', 'New-IntuneRemediation', 'Sync-IntuneWingetCatalog', 'Get-PackageAdapter')
            foreach ($c in $cmds) {
                Get-Command -Module WingetIntune -Name $c | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'Package Adapters & Manifest Parsing' {
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
    }

    Context 'Detection Strategy Hierarchy' {
        It 'Emits ProductCode detection script when ProductCode is present' {
            InModuleScope 'WingetIntune' {
                $script = New-StandaloneDetectShim -PackageId 'Test.MSI' -ProductCode '{TEST-GUID}'
                $script | Should -Match 'SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall'
                $script | Should -Match '\{TEST-GUID\}'
            }
        }

        It 'Emits Registry DisplayVersion scan when ProductCode is absent' {
            InModuleScope 'WingetIntune' {
                $script = New-StandaloneDetectShim -PackageId 'Test.Inno' -DisplayName 'Inno App' -MinVersion '1.2.3'
                $script | Should -Match 'DisplayVersion'
                $script | Should -Match '1\.2\.3'
            }
        }
    }
}
