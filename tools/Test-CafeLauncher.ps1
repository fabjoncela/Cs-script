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
$psAst=[System.Management.Automation.Language.Parser]::ParseInput(
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
foreach($def in $psAst.FindAll({
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

# Preview UI: fixed-coordinate label overlays have been replaced by isolated
# table cells on distinct tabs, so labels cannot cover neighboring inputs.
$editorSource=$definitions['Show-ProfileEditor']
foreach($tabLabel in @('Mouse','NVIDIA / Display','CS2 / Apps')){
    if(-not $editorSource.Contains("'"+$tabLabel+"'")){
        throw ('Profile editor tab missing: '+$tabLabel)
    }
}
foreach($field in @('Resolution width','Resolution height','Refresh rate (Hz)',
    'Logitech DPI (live, per profile)','GitHub .cfg URL')){
    if(-not $editorSource.Contains($field)){throw ('Editor field missing: '+$field)}
}
if($editorSource -notmatch 'New-EditorTabGrid' -or
   $editorSource -notmatch 'New-EditorTabNumber' -or
   $editorSource -notmatch 'SetColumnSpan' -or
   $editorSource -notmatch 'Add-EditorTabField'){
    throw 'Tab layout must use separate responsive table-layout field cells.'
}
if($editorSource -match 'New-EditorLabel \$dialog ''Resolution (?:width|height)'''){
    throw 'Old overlapping absolute-positioned resolution labels are still present.'
}
if($editorSource -notmatch '\$saveEditorValues = \{' -or
   $editorSource -notmatch 'Save-ProfileSettings' -or
   $editorSource -notmatch 'Sync-ProfileToGitHub'){
    throw 'Tab redesign must preserve existing profile Save Locally and GitHub Sync.'
}
foreach($fn in @('New-EditorTabGrid','Add-EditorTabField','New-EditorTabNumber','Add-EditorTabWide')){
    if(-not $definitions.ContainsKey($fn)){throw ('Tab layout helper missing: '+$fn)}
}
# Construct the field layout without opening CafeLauncher or touching devices.
Add-Type -AssemblyName System.Windows.Forms
$WHITE=[System.Drawing.Color]::White
foreach($fn in @('New-EditorTabGrid','Add-EditorTabField','New-EditorTabNumber','Add-EditorTabWide')){
    Invoke-Expression $definitions[$fn]
}
$page=New-Object System.Windows.Forms.TabPage
$page.Size=New-Object System.Drawing.Size(660,330)
$grid=New-EditorTabGrid -Page $page -Rows 2
$n1=New-EditorTabNumber -Grid $grid -Title 'Resolution width' -Column 0 -Row 0 -Min 640 -Max 7680 -Value 1920
$n2=New-EditorTabNumber -Grid $grid -Title 'Resolution height' -Column 1 -Row 0 -Min 480 -Max 4320 -Value 1080
if($grid.ColumnCount -ne 2 -or $n1.Value -ne 1920 -or $n2.Value -ne 1080){
    throw 'Tabbed editor layout or numeric values were not built correctly.'
}
$page.Dispose()
$dashboardSource=$psSource.Substring($psSource.IndexOf('# Modern CafeLauncher dashboard.'))
if($dashboardSource -notmatch 'New-Object System.Windows.Forms.TabControl' -or
   $dashboardSource -notmatch 'Update-SelectedProfileCard' -or
   $dashboardSource -notmatch 'Show Logs' -or
   $dashboardSource -notmatch 'Tools & Apps'){
    throw 'Main dashboard, profile summary, tools, or collapsible logs are missing.'
}
if($psSource -match 'CAFE_PREVIEW_BRANCH|\$script:PreviewBranch|UI PREVIEW' -or
   $definitions['Check-CafeLauncherUpdates'] -notmatch 'GitHub main release is' -or
   $definitions['Check-CafeLauncherUpdates'] -notmatch 'CafeLauncher Update Available'){
    throw 'Production dashboard must use normal verified main-branch updates without preview restrictions.'
}
if($editorSource -notmatch 'Sync-ProfileToGitHub -ProfileName \$ProfileName -Token \$token' -or
   $editorSource -notmatch 'Confirm GitHub sync'){
    throw 'Production editor must retain confirmed JSON and CFG GitHub synchronization.'
}

# Construct the production dashboard in memory. No GUI is shown and none
# of the profile / tool button actions are clicked, so no devices are changed.
$dashboardStart=$psSource.IndexOf('# Modern CafeLauncher dashboard.')
$dashboardEnd=$psSource.IndexOf('# On first display, automatically inventory the machine',$dashboardStart)
if($dashboardStart -lt 0 -or $dashboardEnd -le $dashboardStart){
    throw 'Production dashboard code region not found.'
}
$BG=[System.Drawing.Color]::FromArgb(20,23,30)
$PANEL=[System.Drawing.Color]::FromArgb(31,36,46)
$BLUE=[System.Drawing.Color]::FromArgb(35,125,245)
$MUTED=[System.Drawing.Color]::FromArgb(160,170,185)
$script:GamingProfiles=[ordered]@{}
foreach($name in @('FabMode','ArliMode','BrileMode','ArmlMode','OliMode')){
    $script:GamingProfiles[$name]=@{LogitechDPI=800;PointerSpeed=10;Width=1920;Height=1080;RefreshHz=360;ConfigFile=($name.ToLower()+'.cfg')}
}
$script:LogPath=Join-Path $env:TEMP ('CafeLauncher-dashboard-CI-'+[Guid]::NewGuid().ToString('N')+'.log')
try {
    Invoke-Expression $psSource.Substring($dashboardStart,$dashboardEnd-$dashboardStart)
    if($tabs.TabPages.Count -ne 2 -or $profilesGrid.Controls.Count -ne 6){
        throw 'Dashboard must construct two tabs and exactly five profile cards.'
    }
    if($script:SelectedProfileTitle.Text -ne 'FabMode' -or
       $script:ManualDpiInput.Text -ne '800' -or
       $toolsFlow.Controls.Count -lt 9){
        throw 'Dashboard summary, manual DPI or utility buttons were not created correctly.'
    }
    if($root.RowStyles[2].Height -ne 44){
        throw 'LIVE LOGS must start collapsed.'
    }
} finally {
    if($form){$form.Dispose()}
    Remove-Item -LiteralPath $script:LogPath -Force -ErrorAction SilentlyContinue
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
