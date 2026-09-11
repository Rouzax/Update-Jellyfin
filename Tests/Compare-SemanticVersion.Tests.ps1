#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

<#
.SYNOPSIS
    Unit tests for the version comparison logic in Update-Jellyfin.ps1.

.DESCRIPTION
    Update-Jellyfin.ps1 runs an update as soon as it is loaded, so the suite
    cannot dot-source it. Instead it parses the file and evaluates only the
    version comparison functions, which keeps the production script free of
    test-only entry point guards and keeps the suite side effect free.
#>

BeforeAll {
    $scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Update-Jellyfin.ps1'

    if (-not (Test-Path $scriptPath)) {
        throw "Could not locate Update-Jellyfin.ps1 at $scriptPath"
    }

    # Stub the logger the functions under test call on the unparseable path.
    # Declared before the extracted functions so they resolve against it.
    function Write-UpdateLog {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Message',
            Justification = 'Stub must match the real signature; only the level is asserted on')]
        param([string]$Message, [string]$Level)
        $Script:LastLogLevel = $Level
    }

    $targets = @('ConvertTo-ComparableVersion', 'Compare-SemanticVersion')

    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath, [ref]$null, [ref]$null)

    $found = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -in $targets
        }, $true)

    $missing = $targets | Where-Object { $_ -notin $found.Name }
    if ($missing) {
        throw "Functions not found in Update-Jellyfin.ps1: $($missing -join ', ')"
    }

    foreach ($function in $found) {
        . ([scriptblock]::Create($function.Extent.Text))
    }
}

Describe 'ConvertTo-ComparableVersion' {

    It 'pads <Raw> to the 4 component form <Expected>' -ForEach @(
        @{ Raw = '12.0';            Expected = '12.0.0.0' }
        @{ Raw = '12.0.0';          Expected = '12.0.0.0' }
        @{ Raw = '12.0.0.0';        Expected = '12.0.0.0' }
        @{ Raw = 'v12.0';           Expected = '12.0.0.0' }
        @{ Raw = '10.11.10';        Expected = '10.11.10.0' }
        @{ Raw = '10.10.7+abc1234'; Expected = '10.10.7.0' }
        @{ Raw = '10.10.7-beta.1';  Expected = '10.10.7.0' }
    ) {
        (ConvertTo-ComparableVersion -Raw $Raw).ToString() | Should -Be $Expected
    }

    It 'returns null for the unparseable input <Raw>' -ForEach @(
        @{ Raw = 'unknown' }
        @{ Raw = '' }
        @{ Raw = 'v' }
        @{ Raw = '12' }
    ) {
        ConvertTo-ComparableVersion -Raw $Raw | Should -BeNullOrEmpty
    }
}

Describe 'Compare-SemanticVersion' {

    Context 'component count mismatch' {

        # Regression guard. Jellyfin tagged its 12.0 release as 'v12.0' while
        # jellyfin.dll reports '12.0.0'. The previous 3 component regex could
        # not parse the tag, fell back to a string comparison, and reported an
        # update as available on every run, reinstalling the same build daily.
        It 'treats a 2 component tag as equal to the 3 component installed build' {
            Compare-SemanticVersion -Installed '12.0.0' -Latest '12.0' |
                Should -BeFalse -Because 'v12.0 and 12.0.0 are the same release'
        }

        It 'treats a 2 component installed build as equal to a 3 component tag' {
            Compare-SemanticVersion -Installed '12.0' -Latest '12.0.0' | Should -BeFalse
        }

        It 'does not log a parse warning for a 2 component tag' {
            $Script:LastLogLevel = $null
            Compare-SemanticVersion -Installed '12.0.0' -Latest '12.0' | Out-Null
            $Script:LastLogLevel | Should -BeNullOrEmpty
        }
    }

    Context 'upgrade detection' {

        It 'reports an update for installed <Installed> to latest <Latest>' -ForEach @(
            @{ Installed = '10.11.10'; Latest = '12.0' }
            @{ Installed = '12.0.0';   Latest = '12.0.1' }
            @{ Installed = '12.0.0';   Latest = '12.1' }
            @{ Installed = '12.0.0';   Latest = '13.0' }
            @{ Installed = '10.10.7';  Latest = '10.10.8' }
        ) {
            Compare-SemanticVersion -Installed $Installed -Latest $Latest | Should -BeTrue
        }
    }

    Context 'no update needed' {

        It 'reports no update for installed <Installed> to latest <Latest>' -ForEach @(
            @{ Installed = '10.11.10';       Latest = '10.11.10' }
            @{ Installed = '12.0.1';         Latest = '12.0' }
            @{ Installed = '12.0.0';         Latest = 'v12.0' }
            @{ Installed = '10.10.7+abc123'; Latest = '10.10.7' }
            @{ Installed = '13.0.0';         Latest = '12.0' }
        ) {
            Compare-SemanticVersion -Installed $Installed -Latest $Latest | Should -BeFalse
        }
    }

    Context 'unparseable input' {

        # Get-InstalledVersion returns $null when no version source can be read.
        # Falling back to a string comparison is deliberate: it favours
        # attempting an update over silently skipping one.
        It 'falls back to a string comparison and warns' {
            $Script:LastLogLevel = $null
            Compare-SemanticVersion -Installed 'unknown' -Latest '12.0' | Should -BeTrue
            $Script:LastLogLevel | Should -Be 'WARN'
        }

        It 'reports no update when both sides are equal unparseable strings' {
            Compare-SemanticVersion -Installed 'unknown' -Latest 'unknown' | Should -BeFalse
        }
    }
}
