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

# Regression: legacy main-menu shortcut tiles must remain commented out, but
# profile workflows and their underlying functions stay available.
foreach($tile in @('Apply NVIDIA Settings','Install CS2 fab.cfg')){
    $escaped=[regex]::Escape($tile)
    if($psSource -notmatch ('(?m)^# New-Tile "'+$escaped+'" \d+')){
        throw ('Legacy main-menu tile must be commented out: '+$tile)
    }
    if($psSource -match ('(?m)^[ \t]*New-Tile "'+$escaped+'" \d+')){
        throw ('Legacy main-menu tile was inadvertently re-enabled: '+$tile)
    }
}
if($psSource -notmatch '(?m)^#\s+\[void\]\(Install-AtCfg.*-CfgName ''fab\.cfg''' -or
   $psSource -notmatch '(?m)^# \} -Primary'){
    throw 'All lines of the former Install CS2 fab.cfg shortcut must be commented out.'
}
if($psSource -notmatch 'function Apply-NvidiaGamingSettings' -or
   $psSource -notmatch 'function Install-AtCfg' -or
   $psSource -notmatch 'Install-AtCfg -Silent -CfgName \$profileCfgName' -or
   $psSource -notmatch 'Apply-NvidiaGamingSettings -Width'){
    throw 'Profile-level NVIDIA and CS2 CFG functions must remain accessible.'
}

# Launch All button should still start G HUB, but every player-profile
# LaunchApps path must skip it so the external DPI helper stays in control.
$definitions=@{}
foreach($def in $parseTokens){ } # parser already validated full source
foreach($def in $([Management.Automation.Language.Parser]::ParseInput($psSource,[ref]$null,[ref]$null)).FindAll({
    param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]
},$true)){
    $definitions[$def.Name]=$def.Extent.Text
}
if(-not $definitions.ContainsKey('Launch-All') -or -not $definitions.ContainsKey('Invoke-GamingProfile') -or -not $definitions.ContainsKey('Show-ProfileEditor')){
    throw 'Missing expected launcher and editor functions.'
}
if($definitions['Invoke-GamingProfile'] -notmatch 'Launch-All -SkipGHub' -or
   $definitions['Invoke-GamingProfile'] -notmatch 'Request-LogitechLiveDPI -DPI'){
    throw 'Profile actions must skip G HUB while retaining custom live DPI.'
}
if($psSource -notmatch '(?m)^New-Tile "LAUNCH ALL" 0 \{ Launch-All \}' -or
   $psSource -notmatch '(?m)^New-Tile "Logitech G HUB" 5 \{ Open-GHub \}'){
    throw 'Standalone Launch All and G HUB buttons must remain unchanged.'
}
if($definitions['Show-ProfileEditor'] -notmatch 'Mouse Options \(no G HUB\)'){
    throw 'Profile editor must explain that Launch Apps skips G HUB.'
}
$script:TestGHubCalls=0
function Start-DetectedSteam {}
function Launch-App {param([string]$Name,[string[]]$Paths)}
function Open-FaceitMatchmaking {}
function Open-Spotify {}
function Open-GHub {$script:TestGHubCalls++}
function Open-MousePointerOptions {}
function Write-Log {param([string]$Message,[string]$Level='INFO')}
Invoke-Expression $definitions['Launch-All']
Launch-All -SkipGHub
if($script:TestGHubCalls -ne 0){throw 'Profile launch unexpectedly starts G HUB.'}
Launch-All
if($script:TestGHubCalls -ne 1){throw 'Standalone Launch All must still open G HUB.'}

# Opaque WinForms label backgrounds must not overlap the next input/label.
$editorSource=$definitions['Show-ProfileEditor']
function Get-EditorLabelBounds {
    param([string]$Caption)
    $pattern='New-EditorLabel \$dialog '''+[regex]::Escape($Caption)+''' (\d+) (\d+) (\d+)'
    $match=[regex]::Match($editorSource,$pattern)
    if(-not $match.Success){throw ('Missing profile editor label: '+$Caption)}
    return [pscustomobject]@{X=[int]$match.Groups[1].Value;Y=[int]$match.Groups[2].Value;Width=[int]$match.Groups[3].Value}
}
$widthLabel=Get-EditorLabelBounds -Caption 'Resolution width'
$heightLabel=Get-EditorLabelBounds -Caption 'Resolution height'
$refreshLabel=Get-EditorLabelBounds -Caption 'Refresh rate (Hz)'
$dpiLabel=Get-EditorLabelBounds -Caption 'Logitech DPI (live, per profile)'
if($widthLabel.Y -ne $heightLabel.Y -or $heightLabel.Y -ne $refreshLabel.Y){
    throw 'Resolution labels must stay on a common row.'
}
if(($widthLabel.X+$widthLabel.Width) -ge $heightLabel.X -or
   ($heightLabel.X+$heightLabel.Width) -ge $refreshLabel.X){
    throw 'Resolution labels overlap, hiding first letters of their neighbors.'
}
$dpiInput=[regex]::Match($editorSource,'\$logitechDpi = New-EditorNumber \$dialog (\d+) (\d+)')
if(-not $dpiInput.Success){throw 'Profile Logitech DPI numeric input not found.'}
if(($dpiLabel.X+$dpiLabel.Width) -ge [int]$dpiInput.Groups[1].Value){
    throw 'Logitech DPI label overlaps the numeric input.'
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
