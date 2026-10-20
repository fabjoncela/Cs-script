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
$rateLimitFunctionNames=@('Set-CafeGitHubRateLimitDisplay','Update-CafeGitHubRateLimitFromHeaders','Invoke-CafeGitHubRestMethod')
foreach($functionName in $rateLimitFunctionNames){
    $functionAst=@($psAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName},$true))
    if($functionAst.Count -ne 1){throw ('Missing or duplicate GitHub rate-limit function: '+$functionName)}
    Invoke-Expression $functionAst[0].Extent.Text
}
if($psSource -match '(?i)Invoke-RestMethod\s+-Uri\s+(?!''https://api\.steampowered\.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/''|"https://api\.steampowered\.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/"|\$workshopUri)'){
    throw 'GitHub REST requests must use the response-header tracking wrapper.'
}

# Regression: the retired standalone NVIDIA shortcut stays absent while
# profile workflows and their underlying function remain available.
if($psSource -match '(?m)^[ \t]*#?[ \t]*New-Tile "Apply NVIDIA Settings" \d+'){
    throw 'Retired standalone NVIDIA tile must be removed from the dashboard source.'
}
if($psSource -match '(?i)at\.cfg|Install-AtCfg|Get-AtCfgSource|EmbeddedAtCfgBase64'){
    throw 'The retired standalone at.cfg workflow must be removed.'
}
if($psSource -notmatch 'function Apply-NvidiaGamingSettings' -or
   $psSource -notmatch 'function Install-ProfileCfg' -or
   $psSource -notmatch 'Install-ProfileCfg -Silent -CfgName \$profileCfgName' -or
   $psSource -notmatch 'Apply-NvidiaGamingSettings -Width'){
    throw 'Profile-level NVIDIA and CS2 CFG functions must remain accessible.'
}
foreach($requiredEditorFeature in @(
    '$pointerSpeedValues=@(1,2,4,6,8,10,12,14,16,18,20)',
    'New-EditorTabChoice -Grid $mouseGrid -Title ''Windows pointer speed (11 levels)''',
    '$pointer.add_SelectionChangeCommitted',
    '$pointerSpeedSelectionState.UserChanged',
    '$p.PointerSpeed=$pointerSpeedOriginalValue',
    '$cs2Page.Text=''CS2 / Apps''',
    '$cs2Grid=New-EditorTabGrid -Page $cs2Page -Rows 28',
    'function Add-EditorTabFullRowField',
    'function New-EditorTabFullRowChoice',
    '$captureGraphics.Text=''Capture from CS2''',
    'Get-CafeCS2GraphicsCapture -ProfileName $ProfileName -BasePreset $graphicsPreset',
    'New-EditorTabNumber -Grid $cs2Grid -Title ''CS2 resolution width'' -Column 0 -Row 21',
    'New-EditorTabChoice -Grid $cs2Grid -Title ''Stretch / scaling''',
    'Stretch / scaling',
    'Earlier GitHub file revisions (commit ID shown)',
    'Restore selected version',
    'Get-ProfileGraphicsHistory -ProfileName $ProfileName -ForceRefresh -ResponseJson ([string]$worker.ResultText)',
    'Get-ProfileGraphicsVersion -ProfileName $ProfileName -Version $version',
    '$graphicsPresetState[$ProfileName]=$graphicsPreset',
    'GraphicsSettings',
    'graphics/$ProfileName.json'
)){
    if($psSource -notmatch [regex]::Escape($requiredEditorFeature)){
        throw ('CS2 Graphics editor/local/cloud persistence feature missing: '+$requiredEditorFeature)
    }
}
$framePacingIndex=$psSource.IndexOf("-Title 'Frame Pacing'",[StringComparison]::Ordinal)
$presetsIndex=$psSource.IndexOf("-Title 'Presets'",[StringComparison]::Ordinal)
if($framePacingIndex -lt 0 -or $presetsIndex -le $framePacingIndex){
    throw 'CS2 Frame Pacing section must appear before Presets.'
}
foreach($requiredGraphicsCaption in @(
    "-Title 'V-Sync'",
    "-Title 'NVIDIA Reflex Low Latency'",
    "-Title 'Multisampling Anti-Aliasing Mode'",
    "-Title 'Global Shadow Quality'",
    "-Title 'Dynamic Shadows'",
    "-Title 'Model / Texture Detail'",
    "-Title 'Texture Filtering Mode'",
    "-Title 'Shader Detail'",
    "-Title 'Particle Detail'",
    "-Title 'Ambient Occlusion'",
    "-Title 'High Dynamic Range'",
    "-Title 'FidelityFX Super Resolution'",
    '$vsyncChoice=',
    '$reflexChoice=',
    '$msaaChoice=',
    '$shadowChoice=',
    '$dynamicShadowChoice=',
    '$textureChoice=',
    '$filterChoice=',
    '$shaderChoice=',
    '$particleChoice=',
    '$aoChoice=',
    '$hdrChoice=',
    '$fsrChoice=',
    'function Get-CafeCS2AntiAliasingOptions',
    'function ConvertTo-CafeCS2AntiAliasingChoiceValue',
    'function ConvertFrom-CafeCS2AntiAliasingChoiceValue',
    '$msaaOptions=@(Get-CafeCS2AntiAliasingOptions)',
    "-Title 'V-Sync' -Row 8 -Labels @('Disabled','Enabled')",
    "-Title 'NVIDIA Reflex Low Latency' -Row 9 -Labels @('Disabled','Enabled','Enabled + Boost')",
    "-Title 'Global Shadow Quality' -Row 12 -Labels @('Low','Medium','High','Very High')",
    "-Title 'Dynamic Shadows' -Row 13 -Labels @('Sun Only','All')",
    "-Title 'Model / Texture Detail' -Row 14 -Labels @('Low','Medium','High')",
    "-Title 'Texture Filtering Mode' -Row 15 -Labels @('Bilinear','Trilinear','Anisotropic 2X','Anisotropic 4X','Anisotropic 8X','Anisotropic 16X')",
    "-Title 'Shader Detail' -Row 16 -Labels @('Low','High')",
    "-Title 'Particle Detail' -Row 17 -Labels @('Low','Medium','High','Very High')",
    "-Title 'Ambient Occlusion' -Row 18 -Labels @('Disabled','Medium','High')",
    "-Title 'High Dynamic Range' -Row 19 -Labels @('Performance','Quality')",
    "-Title 'FidelityFX Super Resolution' -Row 20 -Labels @('Performance','Balanced','Quality','Ultra Quality','Disabled (Highest Quality)')",
    'Saved value (preserved):',
    'ConvertTo-CafeCS2AntiAliasingChoiceValue -MSAASamples ([int]$values.MSAASamples) -CMAA ([int]$values.CMAA)',
    '$graphicsSettings[''MSAASamples'']=[int]$antiAliasing.MSAASamples',
    '$graphicsSettings[''CMAA'']=[int]$antiAliasing.CMAA'
)){
    if(-not $psSource.Contains($requiredGraphicsCaption)){
        throw ('CS2 graphics UI caption or setting variable missing: '+$requiredGraphicsCaption)
    }
}
foreach($expectedFullRowField in @(
    "-Title 'V-Sync' -Row 8",
    "-Title 'NVIDIA Reflex Low Latency' -Row 9",
    "-Title 'Multisampling Anti-Aliasing Mode' -Row 11",
    "-Title 'Global Shadow Quality' -Row 12",
    "-Title 'Dynamic Shadows' -Row 13",
    "-Title 'Model / Texture Detail' -Row 14",
    "-Title 'Texture Filtering Mode' -Row 15",
    "-Title 'Shader Detail' -Row 16",
    "-Title 'Particle Detail' -Row 17",
    "-Title 'Ambient Occlusion' -Row 18",
    "-Title 'High Dynamic Range' -Row 19",
    "-Title 'FidelityFX Super Resolution' -Row 20"
)){
    if($psSource -notmatch [regex]::Escape("New-EditorTabFullRowChoice -Grid `$cs2Grid $expectedFullRowField")){
        throw ('CS2 Frame Pacing/Presets field is not assigned its own full-width row: '+$expectedFullRowField)
    }
}
if($psSource -match "-Title 'CMAA'" -or $psSource -match "-Labels @\('Off','2×','4×','8×','16×'\)"){
    throw 'CS2 anti-aliasing must use one menu-matched control without a separate CMAA row or extra sample choices.'
}
$antiAliasingFunctionNames=@('Get-CafeCS2AntiAliasingOptions','ConvertTo-CafeCS2AntiAliasingChoiceValue','ConvertFrom-CafeCS2AntiAliasingChoiceValue')
foreach($functionName in $antiAliasingFunctionNames){
    $functionAst=@($psAst.FindAll({param($node)$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName},$true))
    if($functionAst.Count -ne 1){throw ('Expected one anti-aliasing mapping function: '+$functionName)}
    Invoke-Expression $functionAst[0].Extent.Text
}
$antiAliasingOptions=@(Get-CafeCS2AntiAliasingOptions)
$expectedAntiAliasingLabels=@('None','CMAA2','2X MSAA','4X MSAA','8X MSAA')
$expectedAntiAliasingValues=@('0|0','0|1','2|0','4|0','8|0')
if($antiAliasingOptions.Count -ne $expectedAntiAliasingLabels.Count){throw 'The CS2 anti-aliasing menu must expose exactly five options.'}
for($i=0;$i -lt $antiAliasingOptions.Count;$i++){
    if($antiAliasingOptions[$i].Label -cne $expectedAntiAliasingLabels[$i] -or $antiAliasingOptions[$i].Value -cne $expectedAntiAliasingValues[$i]){
        throw ('CS2 anti-aliasing menu mapping mismatch at option '+$expectedAntiAliasingLabels[$i]+'.')
    }
    $decoded=ConvertFrom-CafeCS2AntiAliasingChoiceValue -Value $antiAliasingOptions[$i].Value
    $encoded=ConvertTo-CafeCS2AntiAliasingChoiceValue -MSAASamples $decoded.MSAASamples -CMAA $decoded.CMAA
    if($encoded -cne $expectedAntiAliasingValues[$i]){throw ('CS2 anti-aliasing round trip failed for '+$antiAliasingOptions[$i].Label+'.')}
}
$legacyPair=ConvertTo-CafeCS2AntiAliasingChoiceValue -MSAASamples 16 -CMAA 0
$legacyDecoded=ConvertFrom-CafeCS2AntiAliasingChoiceValue -Value $legacyPair
if($legacyDecoded.MSAASamples -ne 16 -or $legacyDecoded.CMAA -ne 0){throw 'An older anti-aliasing value was not preserved through the editor mapping.'}
$pointerValuesAst=@($psAst.FindAll({
    param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$pointerSpeedValues'
},$true))
$pointerLabelsAst=@($psAst.FindAll({
    param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$pointerSpeedLabels'
},$true))
if($pointerValuesAst.Count -ne 1 -or $pointerLabelsAst.Count -ne 1){
    throw 'The pointer-speed dropdown must define one value list and one label list.'
}
$pointerValues=@(Invoke-Expression $pointerValuesAst[0].Right.Extent.Text)
$pointerLabels=@(Invoke-Expression $pointerLabelsAst[0].Right.Extent.Text)
if($pointerValues.Count -ne 11 -or $pointerLabels.Count -ne 11 -or
   [string]::Join(',', [string[]]$pointerValues) -ne '1,2,4,6,8,10,12,14,16,18,20' -or
   [Array]::IndexOf([int[]]$pointerValues,10) -ne 5){
    throw 'Pointer speed dropdown must have the 11 classic Windows levels and map its default 6/11 position to value 10.'
}
$cacheBustFunctions=@($psAst.FindAll({
    param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Add-CafeCacheBust'
},$true))
if($cacheBustFunctions.Count -ne 1){throw 'Expected one cache-busting helper for mutable GitHub raw reads.'}
Invoke-Expression $cacheBustFunctions[0].Extent.Text
$freshUrlOne=Add-CafeCacheBust -Uri 'https://raw.githubusercontent.com/owner/repo/main/profiles/FabMode.json'
$freshUrlTwo=Add-CafeCacheBust -Uri 'https://raw.githubusercontent.com/owner/repo/main/profiles/FabMode.json'
if($freshUrlOne -notmatch '\?fresh=[a-f0-9]{32}$' -or $freshUrlTwo -notmatch '\?fresh=[a-f0-9]{32}$' -or $freshUrlOne -ceq $freshUrlTwo){
    throw 'Cache-busting URLs must include a unique per-request token.'
}
$rateLimitHelper=@($psAst.FindAll({
    param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-CafeUpdateRateLimitMessage'
},$true))
if($rateLimitHelper.Count -ne 1){throw 'Expected a specific updater API rate-limit classifier.'}
Invoke-Expression $rateLimitHelper[0].Extent.Text
$quotaMessage=Get-CafeUpdateRateLimitMessage -StatusCode 403 -ResponseBody '{"message":"API rate limit exceeded"}' -RateLimitRemaining '0'
$secondaryMessage=Get-CafeUpdateRateLimitMessage -StatusCode 403 -ResponseBody '{"message":"You have exceeded a secondary rate limit"}' -RateLimitRemaining ''
$forbiddenMessage=Get-CafeUpdateRateLimitMessage -StatusCode 403 -ResponseBody '{"message":"Resource not accessible by integration"}' -RateLimitRemaining '12'
if($quotaMessage -notmatch 'API quota limit reached' -or
   $secondaryMessage -notmatch 'temporarily rate-limiting' -or
   $null -ne $forbiddenMessage){
    throw 'Updater must identify confirmed API rate limits without mislabeling other 403 failures.'
}
foreach($freshReadFunctionName in @(
    'Install-ProfileCfg',
    'Check-CafeLauncherUpdates','Invoke-GraphicsOnly'
)){
    $freshReadFunction=@($psAst.FindAll({
        param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $freshReadFunctionName
    },$true))
    if($freshReadFunction.Count -ne 1 -or $freshReadFunction[0].Extent.Text -notmatch 'Add-CafeCacheBust'){
        throw ("$freshReadFunctionName must bypass stale raw GitHub CDN responses.")
    }
}
$profileApiFunction=@($psAst.FindAll({
    param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-GitHubJsonFromContentsApi'
},$true))
if($profileApiFunction.Count -ne 1){throw 'Expected one GitHub Contents API JSON reader.'}
$profileApiSource=$profileApiFunction[0].Extent.Text
if($profileApiSource -notmatch 'api\.github\.com/repos/\$Repo/contents/\$\{encodedPath\}' -or
   $profileApiSource -notmatch 'Cache-Control.*no-cache' -or
   $profileApiSource -notmatch 'Add-CafeCacheBust' -or
   $profileApiSource -notmatch 'FromBase64String' -or
   $profileApiSource -notmatch 'file\.path -cne \$Path' -or
   $profileApiSource -match 'raw\.githubusercontent\.com'){
    throw 'The shared JSON reader must validate GitHub Contents API data and never read mutable profile JSON from raw CDN.'
}
$profileRefreshFunction=@($psAst.FindAll({
    param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Refresh-ProfileFromGitHub'
},$true))
if($profileRefreshFunction.Count -ne 1 -or
   $profileRefreshFunction[0].Extent.Text -notmatch 'Get-GitHubJsonFromContentsApi' -or
   $profileRefreshFunction[0].Extent.Text -notmatch 'decision=local-fallback' -or
   $profileRefreshFunction[0].Extent.Text -notmatch 'pointerKept='){
    throw 'Profile refresh must use the validated API reader and retain local values when it fails.'
}
$graphicsPresetFunction=@($psAst.FindAll({
    param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-ProfileGraphicsPreset'
},$true))
if($graphicsPresetFunction.Count -ne 1 -or
   $graphicsPresetFunction[0].Extent.Text -notmatch 'Get-GitHubJsonFromContentsApi' -or
   $graphicsPresetFunction[0].Extent.Text -match 'raw\.githubusercontent\.com'){
    throw 'CS2 graphics presets must also use the validated Contents API instead of mutable raw CDN reads.'
}

# Exercise the extracted API reader against a mocked Contents API response.
$script:ProfileApiFixture=$null
$script:ProfileApiRequest=$null
function Invoke-CafeGitHubRestMethod {
    [CmdletBinding()]
    param([string]$Uri,[string]$Method,$Headers,[int]$TimeoutSec,[int]$MaximumRedirection)
    $script:ProfileApiRequest=[pscustomobject]@{Uri=$Uri;Headers=$Headers;Method=$Method}
    return $script:ProfileApiFixture
}
Invoke-Expression $profileApiFunction[0].Extent.Text
$profileFixtureJson='{"SchemaVersion":1,"ProfileName":"FabMode","PointerSpeed":18}'
$script:ProfileApiFixture=[pscustomobject]@{
    type='file';path='profiles/FabMode.json';encoding='base64';sha=('a'*40)
    size=[Text.Encoding]::UTF8.GetByteCount($profileFixtureJson)
    content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($profileFixtureJson))
}
$profileFixture=Get-GitHubJsonFromContentsApi -Repo 'owner/repo' -Branch 'main' -Path 'profiles/FabMode.json'
if([int]$profileFixture.PointerSpeed -ne 18 -or
   $script:ProfileApiRequest.Uri -notmatch '/contents/profiles/FabMode\.json\?ref=main&fresh=[0-9a-f]{32}$' -or
   $script:ProfileApiRequest.Headers['Cache-Control'] -ne 'no-cache'){
    throw 'The profile reader did not decode the current validated API fixture or send no-cache headers.'
}
$script:ProfileApiFixture.path='graphics/FabMode.json'
$graphicsFixture=Get-GitHubJsonFromContentsApi -Repo 'owner/repo' -Branch 'main' -Path 'graphics/FabMode.json' -MaxBytes 1048576
if([int]$graphicsFixture.PointerSpeed -ne 18 -or
   $script:ProfileApiRequest.Uri -notmatch '/contents/graphics/FabMode\.json\?ref=main&fresh=[0-9a-f]{32}$'){
    throw 'The shared Contents API reader did not load the graphics preset path.'
}
$script:ProfileApiFixture.path='profiles/OliMode.json'
$invalidProfileRejected=$false
try{[void](Get-GitHubJsonFromContentsApi -Repo 'owner/repo' -Branch 'main' -Path 'profiles/FabMode.json')}catch{$invalidProfileRejected=$true}
if(-not $invalidProfileRejected){throw 'The profile reader must reject a mismatched GitHub path.'}
$copyHandlerStart=$psSource.IndexOf('$copyGraphics.Add_Click({')
$copyHandlerEnd=$psSource.IndexOf('$restoreHistory.Add_Click({',$copyHandlerStart)
if($copyHandlerStart -lt 0 -or $copyHandlerEnd -le $copyHandlerStart){
    throw 'Copy/reset graphics event handlers could not be located for PowerShell compatibility checks.'
}
$copyAndResetHandlers=$psSource.Substring($copyHandlerStart,$copyHandlerEnd-$copyHandlerStart)
if($copyAndResetHandlers -match '\[void\]\(& \$applyGraphicsPresetToEditor' -or
   $copyAndResetHandlers -match '\[void\]\[System\.Windows\.Forms\.MessageBox\]::Show'){
    throw 'Copy/reset event handlers must avoid void-typed expressions inside try/catch because Windows PowerShell can fail compiling them at click time.'
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
if(-not $definitions.ContainsKey('Get-CafeLauncherRelease')){throw 'Dynamic launcher release lookup is missing.'}
Invoke-Expression $definitions['Get-CafeLauncherRelease']
$env:CAFE_SCRIPT=$batPath
$expectedRelease=[regex]::Match($versions[0], '\d{4}\.\d{2}\.\d{2}\.\d+').Value
$script:LauncherRunningRelease='2026.10.14.15'
if((Get-CafeLauncherRelease) -ne $script:LauncherRunningRelease){throw 'Launcher release lookup must retain the version captured by the running process even if the BAT on disk is replaced.'}
$script:LauncherRunningRelease=$expectedRelease
if((Get-CafeLauncherRelease) -ne $expectedRelease){throw 'Launcher release lookup must use the active CAFE_RELEASE marker captured at startup.'}
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
foreach($historyFunction in @('ConvertTo-CafeGraphicsHistoryEntry','Get-CachedProfileGraphicsHistory','Get-ProfileGraphicsHistory','Get-ProfileGraphicsVersion','New-CafeGraphicsHistoryWorker')){
    if(-not $definitions.ContainsKey($historyFunction)){
        throw ('GitHub graphics history helper missing: '+$historyFunction)
    }
}
$historyLoadStart=$editorSource.IndexOf('$loadHistory.Add_Click({',[StringComparison]::Ordinal)
$historyLoadEnd=$editorSource.IndexOf('}.GetNewClosure())',$historyLoadStart,[StringComparison]::Ordinal)
if($historyLoadStart -lt 0 -or $historyLoadEnd -le $historyLoadStart){throw 'Cannot identify graphics history load handler.'}
$historyLoadBody=$editorSource.Substring($historyLoadStart,$historyLoadEnd-$historyLoadStart)
if(-not $editorSource.Contains('$pollTimer.Add_Tick({') -or
   $editorSource -notmatch '\$worker\.RunWorkerAsync\(\$historyUri\)' -or
   $editorSource -notmatch '\$worker\.IsBusy' -or
   $definitions['New-CafeGraphicsHistoryWorker'] -notmatch 'class CafeGraphicsHistoryBackgroundWorker : BackgroundWorker'){
    throw 'Graphics history must load in the background without blocking its button handler.'
}
if($editorSource -notmatch 'You can continue using the editor' -or
   $editorSource -notmatch '\$dialog\.IsDisposed -or \$dialog\.Disposing'){
    throw 'Background history loading must keep the editor responsive and ignore completion after close.'
}
$restoreStart=$editorSource.IndexOf('$restoreHistory.Add_Click({',[StringComparison]::Ordinal)
$restoreEnd=$editorSource.IndexOf('}.GetNewClosure())',$restoreStart,[StringComparison]::Ordinal)
if($restoreStart -lt 0 -or $restoreEnd -le $restoreStart){throw 'Cannot identify graphics history restore handler.'}
$restoreBody=$editorSource.Substring($restoreStart,$restoreEnd-$restoreStart)
if($restoreBody -notmatch 'Get-ProfileGraphicsVersion' -or $restoreBody -notmatch 'applyGraphicsPresetToEditor' -or
   $restoreBody -match 'Save-ProfileSettings|Sync-ProfileToGitHub|Invoke-GraphicsOnly'){
    throw 'History restore must validate and load into the editor without saving or applying graphics.'
}
foreach($tabLabel in @('Mouse','NVIDIA / Display','CS2 / Apps')){
    if(-not $editorSource.Contains("'"+$tabLabel+"'")){
        throw ('Profile editor tab missing: '+$tabLabel)
    }
}
foreach($field in @('Resolution width','Resolution height','Refresh rate (Hz)',
    'Logitech DPI (live, per profile)')){
    if(-not $editorSource.Contains($field)){throw ('Editor field missing: '+$field)}
}
if($editorSource -match 'CfgDownloadUrl|CFG URL|\.cfg URL'){
    throw 'CFG download URL must remain hidden from the profile editor.'
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
if($psSource -notmatch '(?s)Add-Type -ReferencedAssemblies @\(''System.Windows.Forms'',''System.Drawing''\) -TypeDefinition @''\r?\n(?<editorControls>.*?)\r?\n''@'){
    throw 'Profile editor wheel-aware controls were not found.'
}
Add-Type -ReferencedAssemblies @('System.Windows.Forms','System.Drawing') -TypeDefinition $Matches['editorControls']
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
   $dashboardSource -match 'Refresh-DashboardProfiles' -or
   $dashboardSource -notmatch "Refresh-SelectedProfileCard -Name 'FabMode'" -or
   $dashboardSource -notmatch 'Refresh-SelectedProfileCard -Name \$selectedProfile' -or
   $dashboardSource -notmatch 'Show Logs' -or
   $dashboardSource -notmatch 'Tools & Apps'){
    throw 'Main dashboard, selected-profile GitHub refresh, profile summary, tools, or collapsible logs are missing, or dashboard still refreshes every profile.'
}
if($editorSource -notmatch 'Refresh-ProfileFromGitHub -ProfileName \$ProfileName' -or
   $editorSource -notmatch 'Get-ProfileGraphicsPreset -ProfileName \$ProfileName -RequireGitHub' -or
   $editorSource -notmatch 'Resolve-PendingProfileChanges -ProfileName \$ProfileName' -or
   $editorSource -notmatch 'Confirm-LocalProfileApply -ProfileName \$ProfileName -Source \$profileSource -Action edit' -or
   $editorSource -notmatch '\[void\]\$dialog\.ShowDialog\(\$form\)'){
    throw 'Opening the profile editor must refresh its profile and graphics from GitHub and require explicit local fallback confirmation.'
}
$graphicsReader=@($psAst.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ProfileGraphicsPreset'},$true))
if($graphicsReader.Count -ne 1 -or $graphicsReader[0].Extent.Text -notmatch '\[switch\]\$RequireGitHub' -or
   $graphicsReader[0].Extent.Text -notmatch 'if\(\$RequireGitHub\)\{throw'){
    throw 'Editor GitHub graphics refresh must fail closed so local fallback requires a separate user confirmation.'
}
$startupTimerMatch=[regex]::Match($dashboardSource,'\$startupTimer\s*=\s*New-Object System\.Windows\.Forms\.Timer')
if(-not $startupTimerMatch.Success){throw 'Startup update timer is missing.'}
$startupSource=$dashboardSource.Substring($startupTimerMatch.Index)
if($startupSource -match 'Refresh-DashboardProfiles|Refresh-ProfileFromGitHub'){
    throw 'Dashboard startup must not spend GitHub requests refreshing all profiles.'
}
$pendingChoiceUi=@($psAst.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-PendingProfileChoice'},$true))
$pendingResolver=@($psAst.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-PendingProfileChanges'},$true))
$confirmationAt=-1
$authorizationAt=-1
if($pendingResolver.Count -eq 1){
    $confirmationAt=$pendingResolver[0].Extent.Text.IndexOf('$confirmUpload=',[StringComparison]::Ordinal)
    $authorizationAt=$pendingResolver[0].Extent.Text.IndexOf('$authorization=Get-GitHubSyncAuthorization',[StringComparison]::Ordinal)
}
if($pendingChoiceUi.Count -ne 1 -or
   $pendingChoiceUi[0].Extent.Text -notmatch 'Use GitHub settings' -or
   $pendingChoiceUi[0].Extent.Text -notmatch 'Upload local edits to GitHub' -or
   $pendingChoiceUi[0].Extent.Text -notmatch 'Cancel' -or
   $pendingResolver.Count -ne 1 -or
   $pendingResolver[0].Extent.Text -notmatch 'Show-PendingProfileChoice' -or
   $pendingResolver[0].Extent.Text -notmatch 'Sync-ProfileToGitHub' -or
   -not $pendingResolver[0].Extent.Text.Contains('Upload the local profile, graphics, and CFG sensitivity edits') -or
   -not $pendingResolver[0].Extent.Text.Contains('Button2') -or
   -not $pendingResolver[0].Extent.Text.Contains('$confirmUpload -ne [System.Windows.Forms.DialogResult]::Yes') -or
   $confirmationAt -lt 0 -or $authorizationAt -lt $confirmationAt -or
   -not $pendingResolver[0].Extent.Text.Contains('Refresh-ProfileFromGitHub -ProfileName $ProfileName -NoSave -ForceLoad') -or
   -not $pendingResolver[0].Extent.Text.Contains('Get-ProfileGraphicsPreset -ProfileName $ProfileName -RequireGitHub') -or
   -not $pendingResolver[0].Extent.Text.Contains('$script:PendingSync[$ProfileName]=$true')){
    throw 'Pending edits must offer GitHub-first choices, confirm uploads before authorization, and retain local state if fresh GitHub reads fail.'
}
$profileApply=@($psAst.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-GamingProfile'},$true))
$graphicsApply=@($psAst.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-GraphicsOnly'},$true))
if($profileApply.Count -ne 1 -or $profileApply[0].Extent.Text -notmatch 'Resolve-PendingProfileChanges' -or
   $graphicsApply.Count -ne 1 -or $graphicsApply[0].Extent.Text -notmatch 'Resolve-PendingProfileChanges'){
    throw 'Profile and graphics apply actions must resolve unsynced edits before using cloud settings.'
}
$profileApplyBody=$profileApply[0].Extent.Text
$graphicsRefreshAt=$profileApplyBody.IndexOf('Get-ProfileGraphicsPreset -ProfileName $ProfileName -RequireGitHub',[StringComparison]::Ordinal)
$routineStartAt=$profileApplyBody.IndexOf('full routine started',[StringComparison]::Ordinal)
if($graphicsRefreshAt -lt 0 -or $routineStartAt -le $graphicsRefreshAt -or
   $profileApplyBody -notmatch '\$script:GamingProfiles\[\$ProfileName\]\.ScalingMode=\[int\]\$graphicsPreset\.ScalingMode' -or
   $profileApplyBody -notmatch 'No profile actions were applied' -or
   $profileApplyBody -notmatch 'GitHub Graphics Refresh Failed'){
    throw 'Normal profile Apply must verify the GitHub graphics preset, use its ScalingMode, and cancel before all actions if verification fails.'
}
if($dashboardSource -match "New-CafeLabel -Text 'v\d{4}\.\d{2}\.\d{2}\.\d+'" -or
   $dashboardSource -notmatch "New-CafeLabel -Text \('v'\+\(Get-CafeLauncherRelease\)\)" -or
   $psSource -notmatch 'Check-CafeLauncherUpdates -Manual'){
    throw 'Version badge must use the active CAFE_RELEASE marker and manual update checks must remain wired.'
}
if($psSource -match 'CAFE_PREVIEW_BRANCH|\$script:PreviewBranch|UI PREVIEW' -or
   $definitions['Check-CafeLauncherUpdates'] -notmatch 'Test-LauncherIsCurrent -CurrentPath \$source -RemoteBlobSha \$remote\.sha' -or
    $definitions['Check-CafeLauncherUpdates'] -notmatch '\$remoteRelease -lt \$runningRelease' -or
   $definitions['Check-CafeLauncherUpdates'] -notmatch 'CafeLauncher Update Available'){
    throw 'Production dashboard must use normal verified main-branch updates without preview restrictions.'
}
if($definitions['Check-CafeLauncherUpdates'] -notmatch '\$runningReleaseText=Get-CafeLauncherRelease' -or
   $definitions['Check-CafeLauncherUpdates'] -notmatch 'Newer Build Already Installed' -or
   $definitions['Check-CafeLauncherUpdates'] -notmatch 'Click OK to restart' -or
   $definitions['Check-CafeLauncherUpdates'] -notmatch 'Restart-CafeLauncherAfterUpdate -Path \$source' -or
   $definitions['Restart-CafeLauncherAfterUpdate'] -notmatch 'Start-Process -FilePath \$Path' -or
   $definitions['Restart-CafeLauncherAfterUpdate'] -notmatch '\[System\.Windows\.Forms\.Application\]::Exit\(\)'){
    throw 'Update confirmation must relaunch the installed BAT and close the old launcher.'
}
$startupAt=$psSource.IndexOf('$startupTimer.Add_Tick({')
if($startupAt -lt 0){throw 'Startup inventory timer is missing.'}
$startupSource=$psSource.Substring($startupAt)
$startupInventoryAt=$startupSource.IndexOf('Get-PCDiagnostics',[StringComparison]::Ordinal)
if($startupSource -match 'Get-PCDiagnostics' -or
   $startupSource -notmatch 'Start-CafeLauncherUpdateCheckAsync' -or
   $definitions['Start-CafeLauncherUpdateCheckAsync'] -notmatch 'RunWorkerAsync\(\)' -or
   $definitions['Start-CafeLauncherUpdateCheckAsync'] -notmatch 'Check-CafeLauncherUpdates -RemoteMetadata \$remote' -or
   $startupInventoryAt -ge 0){
    throw 'Startup must defer PC diagnostics and dispatch the launcher update check asynchronously.'
}
if($definitions['Show-PCDiagnostics'] -notmatch "Name 'PC diagnostics inventory' -Group Later" -or
   $definitions['Check-CafeLauncherUpdates'] -notmatch 'CafeLauncher is up to date \(\$runningRelease\)' -or
   $definitions['Check-CafeLauncherUpdates'] -notmatch 'if \(\$Manual\).*CafeLauncher is up to date'){
    throw 'PC inventory must be timed on demand, and a manual up-to-date check must still show its information dialog.'
}
if($editorSource -notmatch 'Sync-ProfileToGitHub -ProfileName \$ProfileName -Token \$token' -or
   $editorSource -notmatch 'Confirm GitHub sync'){
    throw 'Production editor must retain confirmed JSON and CFG GitHub synchronization.'
}

# Construct the production dashboard in memory. No GUI is shown and none
# of the profile / tool button actions are clicked, so no devices are changed.
$dashboardStart=$psSource.IndexOf('# Modern CafeLauncher dashboard.')
$dashboardEnd=$psSource.IndexOf('# PC detection remains available on demand',$dashboardStart)
if($dashboardStart -lt 0 -or $dashboardEnd -le $dashboardStart){
    throw 'Production dashboard code region not found.'
}
$BG=[System.Drawing.Color]::FromArgb(20,23,30)
$PANEL=[System.Drawing.Color]::FromArgb(31,36,46)
$BLUE=[System.Drawing.Color]::FromArgb(35,125,245)
$MUTED=[System.Drawing.Color]::FromArgb(160,170,185)
$script:GamingProfiles=[ordered]@{}
foreach($name in @('FabMode','ArliMode','BrileMode','ArmlMode','OliMode','Provmode')){
    $script:GamingProfiles[$name]=@{LogitechDPI=800;PointerSpeed=10;Width=1920;Height=1080;RefreshHz=360;ConfigFile=($name.ToLower()+'.cfg')}
}
$script:PendingSync=@{}
$script:ProfileRefreshStatus=@{}
$script:ProfileRefreshCalls=New-Object System.Collections.ArrayList
foreach($name in @($script:GamingProfiles.Keys)){$script:PendingSync[$name]=$false}
function Start-CafeTimingOperation { param([string]$Type,[string]$Name,[string]$Uri,[string]$Group) return 1L }
function Complete-CafeTimingOperation { param([long]$Id,[string]$Outcome,[int]$HttpStatus) }
function Refresh-ProfileFromGitHub {
    param([string]$ProfileName)
    [void]$script:ProfileRefreshCalls.Add($ProfileName)
    $script:ProfileRefreshStatus[$ProfileName]='GitHub'
    return 'GitHub'
}
$script:LogPath=Join-Path $env:TEMP ('CafeLauncher-dashboard-CI-'+[Guid]::NewGuid().ToString('N')+'.log')
$script:GitHubRateLimitSnapshot=$null
$script:GitHubRateLimitLabel=$null
# Load the production palette explicitly: this CI test evaluates the dashboard
# separately from the editor, where ProfileAccentColors is normally initialized.
$paletteMatch=[regex]::Match($psSource,'(?ms)^\$script:ProfileAccentColors\s*=\s*@\{.*?^\}')
if(-not $paletteMatch.Success){throw 'Production profile color palette missing.'}
Invoke-Expression $paletteMatch.Value
$form=$null
try {
    Invoke-Expression $psSource.Substring($dashboardStart,$dashboardEnd-$dashboardStart)
    if($tabs.TabPages.Count -ne 2 -or $profilesGrid.Controls.Count -ne 7){
        throw 'Dashboard must construct two tabs and exactly six profile cards.'
    }
    $pageOneProfiles=@(for($row=1;$row -le 5;$row++){
        $card=$profilesGrid.GetControlFromPosition(0,$row)
        if($card -and $card.Tag){[string]$card.Tag}
    })
    if($script:ProfileDashboardPageLabel.Text -ne 'Page 1 of 2' -or
       -not $script:ProfileDashboardNext.Enabled -or
       $script:ProfileDashboardPrevious.Enabled -or
       $pageOneProfiles.Count -ne 5 -or
       $pageOneProfiles -contains 'Provmode'){
        throw 'Dashboard page 1 must show five profiles and leave Provmode for page 2.'
    }
    Set-ProfileDashboardPage -PageIndex 1
    $pageTwoProfiles=@(for($row=1;$row -le 5;$row++){
        $card=$profilesGrid.GetControlFromPosition(0,$row)
        if($card -and $card.Tag){[string]$card.Tag}
    })
    if($script:ProfileDashboardPageLabel.Text -ne 'Page 2 of 2' -or
       $script:ProfileDashboardNext.Enabled -or
       -not $script:ProfileDashboardPrevious.Enabled -or
       $pageTwoProfiles.Count -ne 1 -or
       $pageTwoProfiles[0] -cne 'Provmode' -or
       $script:ProfileRefreshCalls.Count -ne 1){
        throw 'Dashboard page 2 must show only Provmode without refreshing profile data.'
    }
    Set-ProfileDashboardPage -PageIndex 0
    if($script:SelectedProfileTitle.Text -ne 'FabMode' -or
       $script:ManualDpiInput.Text -ne '' -or
       $toolsFlow.Controls.Count -lt 9){
        throw 'Dashboard summary, manual DPI or utility buttons were not created correctly.'
    }
    if($script:ProfileRefreshCalls.Count -ne 1 -or $script:ProfileRefreshCalls[0] -cne 'FabMode' -or
       $script:SelectedProfileHint.Text -ne 'Profile values verified from GitHub.'){
        throw 'Dashboard startup must refresh and display only its initially selected profile.'
    }
    $script:PendingSync['FabMode']=$true
    Update-SelectedProfileCard -Name 'FabMode'
    if($script:SelectedProfileHint.Text -ne 'Showing local values; changes are pending sync.'){
        throw 'Dashboard must identify selected-profile values with pending local changes.'
    }
    $script:PendingSync['FabMode']=$false
    $script:ProfileRefreshStatus['FabMode']='LocalFallback'
    Update-SelectedProfileCard -Name 'FabMode'
    if($script:SelectedProfileHint.Text -ne 'GitHub refresh failed; showing local values.'){
        throw 'Dashboard must identify local values shown after a failed GitHub refresh.'
    }
    if(-not $script:GitHubRateLimitLabel -or $script:GitHubRateLimitLabel.Text -ne 'GitHub API: waiting for request'){
        throw 'Dashboard must show the API allowance next to the launcher version.'
    }
    Update-CafeGitHubRateLimitFromHeaders -Headers @{
        'X-RateLimit-Remaining'='42';'X-RateLimit-Limit'='60';'X-RateLimit-Reset'='1792000000';'X-RateLimit-Resource'='core'
    }
    if($script:GitHubRateLimitLabel.Text -notmatch '^GitHub API: 42/60 left\r?\nLast checked \d{2}:\d{2}:\d{2}$' -or
       $script:GitHubRateLimitLabel.Height -lt 36){
        throw ('The dashboard did not display the latest remaining count from response headers. Actual label="'+$script:GitHubRateLimitLabel.Text+'"; snapshot='+[string]$script:GitHubRateLimitSnapshot.Remaining)
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
