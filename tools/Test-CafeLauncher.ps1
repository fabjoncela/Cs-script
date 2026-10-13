# Runs on Windows PowerShell 5.1. Does not launch CafeLauncher or modify PC settings.
# Run locally: powershell.exe -NoProfile -File .\tools\Test-CafeLauncher.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$batPath = Join-Path $repoRoot 'cafe.bat'
if (-not (Test-Path -LiteralPath $batPath -PathType Leaf)) {
    throw ('CafeLauncher not found: {0}' -f $batPath)
}

$bytes = [System.IO.File]::ReadAllBytes($batPath)
if ($bytes.Length -lt 100) { throw 'cafe.bat is empty or too small.' }

# The launcher is a hybrid BAT/PowerShell file. Preserve Windows line endings
# so cmd.exe reads the BAT header predictably after downloads from GitHub.
$lineFeeds = 0
for ($i = 0; $i -lt $bytes.Length; $i++) {
    if ($bytes[$i] -eq 10) {
        $lineFeeds++
        if ($i -eq 0 -or $bytes[$i - 1] -ne 13) {
            throw ('cafe.bat has non-Windows (LF-only) line ending at byte {0}.' -f $i)
        }
    }
}
if ($lineFeeds -lt 10) { throw 'cafe.bat does not contain enough lines.' }

$lines = [System.IO.File]::ReadAllLines($batPath)
if ($lines[0] -cne '@echo off') { throw 'cafe.bat must begin with @echo off.' }

$markers = @(
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -ceq '# POWERSHELL_GUI') { $i }
    }
)
if ($markers.Count -ne 1) { throw ('Expected one PowerShell marker, found {0}.' -f $markers.Count) }
$marker = [int]$markers[0]
if ($marker -ge $lines.Length - 2) { throw 'PowerShell section is missing.' }

$versions = @($lines | Where-Object { $_ -match '^# CAFE_RELEASE=\d{4}\.\d{2}\.\d{2}\.\d+$' })
if ($versions.Count -ne 1) { throw 'Expected exactly one valid # CAFE_RELEASE=YYYY.MM.DD.N metadata line.' }

$psSource = [string]::Join([Environment]::NewLine, [string[]]$lines[($marker + 1)..($lines.Length - 1)])
$parseTokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput(
    $psSource, [ref]$parseTokens, [ref]$parseErrors
)
if (@($parseErrors).Count -gt 0) {
    foreach ($parseError in @($parseErrors)) {
        $absoluteLine = $marker + 1 + $parseError.Extent.StartLineNumber
        $column = $parseError.Extent.StartColumnNumber
        $message = $parseError.Message.Replace([string][char]13, ' ').Replace([string][char]10, ' ')
        Write-Host ('::error file=cafe.bat,line={0},col={1}::{2}' -f $absoluteLine, $column, $message)
    }
    throw ('PowerShell syntax check failed: {0} error(s). First error at cafe.bat line {1}, column {2}: {3}; text: {4}' -f @($parseErrors).Count, ($marker + 1 + $parseErrors[0].Extent.StartLineNumber), $parseErrors[0].Extent.StartColumnNumber, $parseErrors[0].Message, $parseErrors[0].Extent.Text)
}

# Sanity check: this test must reject the precise interpolation bug that broke
# the October 13 launcher: "$name:" without braces around the variable name.
$badExample = 'throw "Cannot save $name: exporter returned nothing"'
$badTokens = $null
$badErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput(
    $badExample, [ref]$badTokens, [ref]$badErrors
)
if (@($badErrors).Count -lt 1) {
    throw 'Validator self-test failed: invalid $name: interpolation was not detected.'
}

Write-Host ('PASS: {0} | Windows CRLF | {1} BAT lines | embedded PowerShell parses in PS {2}.' -f $versions[0], $lines.Length, $PSVersionTable.PSVersion)
