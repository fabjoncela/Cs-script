# Read-only Windows PowerShell 5.1 graphics regression test. No Steam/CS2 writes.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$module=Join-Path $root 'graphics\ApplyGraphics.ps1'
$bat=Join-Path $root 'cafe.bat'
$source=[IO.File]::ReadAllText($module)
$moduleBytes=[Text.Encoding]::UTF8.GetBytes(($source -replace "`r`n","`n"))
$hashHeader=[Text.Encoding]::UTF8.GetBytes(('blob '+$moduleBytes.Length+[char]0))
$hashInput=New-Object byte[] ($hashHeader.Length+$moduleBytes.Length)
[Array]::Copy($hashHeader,0,$hashInput,0,$hashHeader.Length)
[Array]::Copy($moduleBytes,0,$hashInput,$hashHeader.Length,$moduleBytes.Length)
$sha1=[Security.Cryptography.SHA1]::Create()
try{$moduleBlobHash=([BitConverter]::ToString($sha1.ComputeHash($hashInput))).Replace('-','').ToLowerInvariant()}finally{$sha1.Dispose()}
$launcher=[IO.File]::ReadAllText((Join-Path $root 'cafe.bat'))
$pinPattern=[regex]::Escape('$expected=')+[char]39+[regex]::Escape($moduleBlobHash)+[char]39
if($launcher -notmatch $pinPattern){
    throw 'Launcher graphics-module pin does not match the reviewed local module blob.'
}
if($source -notmatch 'api\.github\.com/repos/fabjoncela/Cs-script/contents/graphics/\$ModeName\.json\?ref=main&fresh=\$fresh' -or
   $source -notmatch 'FromBase64String' -or $source -notmatch 'Cache-Control.*no-cache' -or
   $source -notmatch 'Invoke-CafeGitHubRestMethod' -or $source -match 'Invoke-RestMethod' -or
   $launcher -notmatch 'raw\.githubusercontent\.com/fabjoncela/Cs-script/main/graphics/ApplyGraphics\.ps1'){
    throw 'Graphics presets must use validated GitHub Contents API data; the pinned module source must follow main.'
}
if($source -notmatch 'Apply Graphics \| ' -or $source -notmatch 'Set-RunOutcome' -or
   $source -notmatch '\$appliedDetails'){
    throw 'CS2 graphics results must be written to the live/file logs with requested and confirmed values.'
}
$tok=$null;$errors=$null
[void][System.Management.Automation.Language.Parser]::ParseInput($source,[ref]$tok,[ref]$errors)
if(@($errors).Count -gt 0){throw ('Graphics module syntax error: '+$errors[0].Message)}
. $module
function Write-Log {param([string]$Message,[string]$Level='INFO')}
$script:AllowLocalGraphics=$true
$script:LocalGraphicsConfirmCalls=New-Object System.Collections.ArrayList
function Confirm-CS2GraphicsPresetUse {
    param([string]$ModeName,[string]$Path,[switch]$Unsynced)
    [void]$script:LocalGraphicsConfirmCalls.Add([pscustomobject]@{ModeName=$ModeName;Path=$Path;Unsynced=[bool]$Unsynced})
    return [bool]$script:AllowLocalGraphics
}
$fixture=@'
"video.cfg"
{
    "Version" "16"
    "VendorID" "4318"
    "DeviceID" "12345"
    "setting.monitor_index" "2"
    "setting.defaultres" "1920"
    "setting.defaultresheight" "1080"
    "setting.refreshrate_numerator" "165003"
    "setting.refreshrate_denominator" "1000"
    "setting.fullscreen" "1"
    "setting.aspectratiomode" "1"
    "setting.msaa_samples" "8"
    "setting.r_csgo_cmaa_enable" "0"
    "setting.videocfg_shadow_quality" "2"
    "setting.videocfg_texture_detail" "2"
    "setting.shaderquality" "1"
    "setting.videocfg_hdr_detail" "-1"
    "setting.videocfg_fsr_detail" "0"
    "setting.r_low_latency" "0"
    "setting.custom_unknown" "keep me"
}
'@
$settings=[ordered]@{MSAASamples=2;ShadowQuality=0;TextureDetail=0;NvidiaReflex=1}
$result=Update-CS2VideoGraphicsText -Text $fixture -Settings $settings
if($result.Applied.Count -ne 4 -or -not $result.Changed){throw 'Graphics helper did not update four fields.'}
if($result.Text -notmatch '"setting\.msaa_samples"\s+"2"' -or
   $result.Text -notmatch '"setting\.r_low_latency"\s+"1"'){throw 'Graphics values not edited correctly.'}
$cmaaResult=Update-CS2VideoGraphicsText -Text $fixture -Settings ([ordered]@{MSAASamples=0;CMAA=1})
if($cmaaResult.Text -notmatch '"setting\.msaa_samples"\s+"0"' -or
   $cmaaResult.Text -notmatch '"setting\.r_csgo_cmaa_enable"\s+"1"'){
    throw 'The combined CMAA2 menu option did not update both established video settings.'
}
$fsrExpected=@{0='0';1='4';2='3';3='2';4='1'}
foreach($profileFsrValue in 0..4){
    $fsrResult=Update-CS2VideoGraphicsText -Text $fixture -Settings ([ordered]@{FSRDetail=$profileFsrValue})
    $expectedGameValue=$fsrExpected[$profileFsrValue]
    if($fsrResult.Text -notmatch ('"setting\.videocfg_fsr_detail"\s+"'+$expectedGameValue+'"')){
        throw ('FSR profile value '+$profileFsrValue+' did not map to CS2 value '+$expectedGameValue+'.')
    }
}
foreach($unchanged in @('"VendorID" "4318"','"DeviceID" "12345"','"setting.monitor_index" "2"','"setting.custom_unknown" "keep me"')){
    if(-not $result.Text.Contains($unchanged)){throw ('Unrelated device/video setting changed: '+$unchanged)}
}
if((Update-CS2VideoGraphicsText -Text $result.Text -Settings $settings).Changed){throw 'Re-applying must be idempotent.'}
$display=[ordered]@{Width=1280;Height=960;RefreshHz=240;AspectRatioMode=0;Fullscreen=1}
$fallbackDisplay=[ordered]@{Width=1280;Height=960;RefreshHz=360;AspectRatioMode=0;Fullscreen=0}
$skip=Update-CS2VideoGraphicsText -Text $fixture -Settings $fallbackDisplay -SkipDisplay
if($skip.Text -notmatch '"setting.defaultres" "1920"' -or $skip.Text -notmatch '"setting.fullscreen" "1"'){
    throw 'Unsupported resolution fallback must preserve every existing CS2 display setting.'
}
$applied=Update-CS2VideoGraphicsText -Text $fixture -Settings $display
if($applied.Text -notmatch '"setting.refreshrate_numerator" "240"' -or
   $applied.Text -notmatch '"setting.refreshrate_denominator" "1"'){
    throw 'Supported refresh numerator/denominator edit failed.'
}
$bad=0
foreach($value in @(-10,7,100)){
    try{
        [void](ConvertTo-VideoGraphicsSettings -Preset ([pscustomobject]@{Settings=[pscustomobject]@{MSAASamples=$value}}))
    }catch{$bad++}
}
if($bad -ne 3){throw 'MSAA validation accepted invalid values.'}
# Regression for real .NET Framework File.Replace (Windows PowerShell 5.1):
# exercise the exact production saver using isolated temporary files.
$sandbox=Join-Path $env:TEMP ('CafeLauncher-Graphics-ReplaceTest-'+[guid]::NewGuid().ToString('N'))
$videoFolder=Join-Path $sandbox 'userdata\123\730\local\cfg'
$backups=Join-Path $sandbox 'user-backups'
[void](New-Item -Path $videoFolder -ItemType Directory -Force)
[void](New-Item -Path $backups -ItemType Directory -Force)
try {
    $target=Join-Path $videoFolder 'cs2_video.txt'
    $backup=Join-Path $backups 'cs2_video-original.txt'
    $encoding=New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($target,$fixture,$encoding)
    $script:TestSteamVideoPath=$target
    $script:TestSteamAccountID='123'
    function Get-ActiveSteamCS2Video {
        return [pscustomobject]@{Path=$script:TestSteamVideoPath;AccountID=$script:TestSteamAccountID}
    }
    $proposed=Update-CS2VideoGraphicsText -Text $fixture -Settings ([ordered]@{MSAASamples=2})
    Save-CS2VideoFileWithBackup -VideoPath $target -ExpectedAccountID '123' -UpdatedText $proposed.Text -Encoding $encoding -BackupPath $backup
    if ([IO.File]::ReadAllText($target,$encoding) -cne $proposed.Text) {
        throw 'The real Windows replacement did not save the new video text.'
    }
    if (-not (Test-Path -LiteralPath $backup -PathType Leaf) -or
        [IO.File]::ReadAllText($backup,$encoding) -cne $fixture) {
        throw 'The original CS2 graphics backup was not preserved.'
    }
    $orphans=@(Get-ChildItem -LiteralPath $videoFolder -File -ErrorAction Stop |
        Where-Object { $_.Name -like 'cs2_video.cafe-*' })
    if ($orphans.Count -gt 0) { throw 'Temporary/swap-backup files remain after successful graphics replacement.' }

    # Refuse a backup in a missing directory before touching the video file.
    $badBackup=Join-Path $sandbox 'missing-parent\backup.txt'
    $preFailure=[IO.File]::ReadAllText($target,$encoding)
    $accountFailure=$false
    try {
        Save-CS2VideoFileWithBackup -VideoPath $target -ExpectedAccountID '456' -UpdatedText $fixture -Encoding $encoding -BackupPath (Join-Path $backups 'wrong-account.txt')
    } catch { $accountFailure=$_.Exception.Message -match 'active Steam account changed' }
    if (-not $accountFailure -or [IO.File]::ReadAllText($target,$encoding) -cne $preFailure) {
        throw 'A Steam account change must refuse the graphics write and preserve the existing video file.'
    }
    $failed=$false
    try {
        Save-CS2VideoFileWithBackup -VideoPath $target -ExpectedAccountID '123' -UpdatedText $fixture -Encoding $encoding -BackupPath $badBackup
    } catch { $failed=$true }
    if (-not $failed -or [IO.File]::ReadAllText($target,$encoding) -cne $preFailure) {
        throw 'Graphics backup failure must not change the existing video file.'
    }
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

# Synced profile files are user data and may be customized. Validate identity,
# schema, policy, and supported values without pinning them to preset defaults.
$profileNames=@('FabMode','ArliMode','BrileMode','ArmlMode','OliMode','Provmode')
foreach($name in $profileNames){
    $file=Join-Path $root ('graphics\'+$name+'.json')
    $json=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    if([int]$json.SchemaVersion -ne 1 -or $json.ProfileName -cne $name){throw 'Preset schema/name mismatch.'}
    [void](Assert-CS2GraphicsDisplayPolicy -Preset $json)
    $values=ConvertTo-VideoGraphicsSettings -Preset $json
    if($values.Count -lt 1){throw ('No recognized graphics settings in '+$name+' profile.')}
}
# Prove a valid customization is accepted independently for every profile.
foreach($name in $profileNames){
    $custom=Get-Content -LiteralPath (Join-Path $root ('graphics\'+$name+'.json')) -Raw | ConvertFrom-Json
    $custom.Settings.MSAASamples=4
    $customValues=ConvertTo-VideoGraphicsSettings -Preset $custom
    if([int]$customValues['MSAASamples'] -ne 4){throw ($name+' customized graphics value was rejected.')}
}
# Keep baseline preset expectations in test data, separate from the live,
# user-customizable graphics/<Profile>.json files.
$presetFixtures=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\graphics-presets.json') -Raw | ConvertFrom-Json
$fabFixture=$presetFixtures.FabMode
$fabFixtureValues=ConvertTo-VideoGraphicsSettings -Preset $fabFixture
if([int]$fabFixtureValues['Width'] -ne 1280 -or [int]$fabFixtureValues['Height'] -ne 960 -or
   [int]$fabFixtureValues['AspectRatioMode'] -ne 0 -or [int]$fabFixtureValues['Fullscreen'] -ne 1 -or
   $fabFixture.RefreshPolicy -cne 'Highest'){
    throw 'FabMode baseline fixture must describe 1280x960 4:3 fullscreen with highest refresh.'
}
$brilePreset=$presetFixtures.BrileMode
$brileSettings=ConvertTo-VideoGraphicsSettings -Preset $brilePreset
if((Assert-CS2GraphicsDisplayPolicy -Preset $brilePreset) -cne 'ApplyPreset' -or
   [int]$brileSettings['Width'] -ne 1920 -or [int]$brileSettings['Height'] -ne 1080 -or
   [int]$brileSettings['AspectRatioMode'] -ne 1 -or [int]$brileSettings['Fullscreen'] -ne 1 -or
   $brileSettings.Contains('RefreshHz') -or $brilePreset.RefreshPolicy -cne 'Highest'){
    throw 'BrileMode baseline fixture must describe native 1920x1080 fullscreen 16:9 with highest refresh.'
}
$legacyBrile=[pscustomobject]@{ProfileName='BrileMode';Settings=[pscustomobject]@{Width=$null;Height=$null;RefreshHz=$null;AspectRatioMode=$null;Fullscreen=$null}}
if((Assert-CS2GraphicsDisplayPolicy -Preset $legacyBrile) -cne 'PreserveCurrent'){
    throw 'Previously cached BrileMode presets with null display values must remain safe.'
}
$brileEdit=Update-CS2VideoGraphicsText -Text $fixture -Settings $brileSettings
foreach($displayValue in @('"setting.defaultres" "1920"','"setting.defaultresheight" "1080"',
    '"setting.aspectratiomode" "1"','"setting.fullscreen" "1"',
    '"setting.refreshrate_numerator" "165003"','"setting.refreshrate_denominator" "1000"')){
    if(-not $brileEdit.Text.Contains($displayValue)){throw ('BrileMode failed to apply/preserve CS2 display setting '+$displayValue)}
}
if(-not $brileEdit.Changed -or $brileEdit.Text -notmatch '"setting.msaa_samples"\s+"2"'){
    throw 'BrileMode must apply native 1080p fullscreen 16:9 and quality settings.'
}
$batText=[IO.File]::ReadAllText($bat)
if($batText -notmatch '\$graphics\.Add_Click' -or $batText -notmatch 'Invoke-GraphicsOnly -ModeName \$selectedProfile'){
    throw 'Apply Graphics GUI button missing.'
}
$applyBegin=$batText.IndexOf('function Invoke-GamingProfile {',[StringComparison]::Ordinal)
$applyEnd=$batText.IndexOf('function Get-CS2SteamLaunchArguments {',[StringComparison]::Ordinal)
if($applyBegin -lt 0 -or $applyEnd -le $applyBegin){throw 'Cannot identify profile application function boundaries.'}
$applyBody=$batText.Substring($applyBegin,$applyEnd-$applyBegin)
if($applyBody -match 'Apply-CS2ModeGraphics|Invoke-GraphicsOnly|Get-CS2ModeGraphicsPreset'){
    throw 'Graphics must never be called inside profile application.'
}
if($batText -match 'Invoke-GamingProfile.+Invoke-GraphicsOnly'){
    throw 'Profile main action must not call the independent graphics loader.'
}
# Compile the actual inline C# display helper without touching monitor settings.
# PowerShell parsing alone cannot detect C# compilation regressions.
$begin=$batText.IndexOf('Add-Type -ErrorAction Stop @"',[StringComparison]::Ordinal)
if($begin -lt 0){throw 'Embedded C# display helper not found.'}
$csharpStart=$batText.IndexOf([char]10,$begin)+1
$csharpEnd=$batText.IndexOf('"@',$csharpStart,[StringComparison]::Ordinal)
if($csharpEnd -lt $csharpStart){throw 'Could not extract C# helper.'}
$csharp=$batText.Substring($csharpStart,$csharpEnd-$csharpStart)
Add-Type -TypeDefinition $csharp -ErrorAction Stop
if(-not ('FabDisplayNative' -as [type]) -or
   -not [FabDisplayNative].GetMethod('IsAdvertisedMode') -or
   -not [FabDisplayNative].GetMethod('GetHighestRefreshForResolution') -or
   -not [FabDisplayNative].GetMethod('GetHighestRefreshAtResolution') -or
   -not [FabDisplayNative].GetMethod('TrySetDisplayMode')){
    throw 'Read-only advertised-mode helper was not compiled.'
}
if([FabDisplayNative]::IsAdvertisedMode(1,1,0)){
    throw 'Invalid resolution must not pass display mode validation.'
}
foreach($testCase in @(
    @{Widths=[int[]]@(1920,1920,1920);Heights=[int[]]@(1080,1080,1080);Rates=[int[]]@(60,120,240);Expected=240},
    @{Widths=[int[]]@(1920,1920,1920);Heights=[int[]]@(1080,1080,1080);Rates=[int[]]@(60,120,360);Expected=360},
    @{Widths=[int[]]@(1920,1920,1920,1280);Heights=[int[]]@(1080,1080,1080,960);Rates=[int[]]@(60,240,540,1000);Expected=540},
    @{Widths=[int[]]@(1920);Heights=[int[]]@(1080);Rates=[int[]]@(360);Expected=360}
)){
    $selected=[FabDisplayNative]::GetHighestRefreshAtResolution(1920,1080,[int[]]$testCase.Widths,[int[]]$testCase.Heights,[int[]]$testCase.Rates)
    if($selected -ne $testCase.Expected){throw ('Highest refresh selection expected '+$testCase.Expected+'Hz but returned '+$selected+'Hz.')}
}
$gameRefresh=[FabDisplayNative]::GetHighestRefreshAtResolution(1280,960,[int[]]@(1920,1280,1280),[int[]]@(1080,960,960),[int[]]@(540,240,360))
if($gameRefresh -ne 360){throw 'CS2 refresh selection must use the highest rate for the preset game resolution, independently of desktop resolution.'}
$gameDisplay=[ordered]@{Width=1280;Height=960;RefreshHz=$gameRefresh;AspectRatioMode=0;Fullscreen=1}
$gameEdit=Update-CS2VideoGraphicsText -Text $fixture -Settings $gameDisplay
if($gameEdit.Text -notmatch '"setting.defaultres" "1280"' -or
   $gameEdit.Text -notmatch '"setting.defaultresheight" "960"' -or
   $gameEdit.Text -notmatch '"setting.refreshrate_numerator" "360"' -or
   $gameEdit.Text -notmatch '"setting.refreshrate_denominator" "1"'){
    throw 'A 1920x1080 desktop with FabMode 1280x960 CS2 must write the maximum game-resolution refresh.'
}
$applyGraphicsStart=$source.IndexOf('function Apply-CS2ModeGraphics {',[StringComparison]::Ordinal)
if($applyGraphicsStart -lt 0 -or $source.Substring($applyGraphicsStart) -notmatch 'GetHighestRefreshForResolution\(\$w,\$h\)' -or
   $source.Substring($applyGraphicsStart) -notmatch '\$settings\[''RefreshHz''\]=\$hz'){
    throw 'Apply Graphics must select and save the maximum advertised rate for its own CS2 resolution.'
}
$displaySource=[IO.File]::ReadAllText($bat)
if($displaySource -notmatch '(?s)function Apply-NvidiaGamingSettings.*?TrySetDisplayMode' -or
   $displaySource -notmatch 'highest advertised refresh at preferred resolution'){
    throw 'The profile display apply must choose the maximum refresh at the profile resolution.'
}
Write-Host 'PASS: Windows File.Replace backups, Steam account guard, desktop and CS2-resolution refresh selection, six graphics presets, and graphics ranges.'

# Locally saved, unsynced graphics must be applied before any cloud/cache fetch.
$oldLocalAppData=$env:LOCALAPPDATA
$oldCafeScript=$env:CAFE_SCRIPT
$localSandbox=Join-Path $env:TEMP ('CafeLauncher-GraphicsLocal-'+[guid]::NewGuid().ToString('N'))
try{
    $env:LOCALAPPDATA=$localSandbox
    $env:CAFE_SCRIPT=(Join-Path $root 'cafe.bat')
    [void](New-Item -ItemType Directory -Path (Join-Path $localSandbox 'CafeLauncher') -Force)
    $localSettings=[ordered]@{FabMode=@{SyncPending=$true;GraphicsSettings=[pscustomobject]@{
        SchemaVersion=1;ProfileName='FabMode';DisplayPolicy='ApplyPreset';RefreshPolicy='Highest';ScalingMode=2
        Settings=[pscustomobject]@{Width=1280;Height=960;MSAASamples=4}
    }}}
    $localSettings|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $localSandbox 'CafeLauncher\profiles.json') -Encoding UTF8
    $localApplied=Get-CS2ModeGraphicsPreset -ModeName 'FabMode'
    if([int]$localApplied.Settings.MSAASamples -ne 4){throw 'Unsynced local graphics edits were not preferred.'}
    if(-not $script:LocalGraphicsConfirmCalls[-1].Unsynced){throw 'Unsynced local graphics path did not request explicit confirmation.'}
    $script:AllowLocalGraphics=$false
    $cancelled=$false
    try{[void](Get-CS2ModeGraphicsPreset -ModeName 'FabMode')}catch{$cancelled=$_.Exception.Message -like '*canceled*'}
    if(-not $cancelled){throw 'Declining local graphics confirmation must cancel Apply Graphics.'}
}finally{
    $env:LOCALAPPDATA=$oldLocalAppData
    $env:CAFE_SCRIPT=$oldCafeScript
    Remove-Item -LiteralPath $localSandbox -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'PASS: unsynced local CS2 graphics require confirmation and cancellation prevents application.'

# A current cloud graphics preset must come from the Contents API, with the
# exact path and base64 payload validated before cache/application.
$oldLocalAppData=$env:LOCALAPPDATA
$oldCafeScript=$env:CAFE_SCRIPT
$cloudSandbox=Join-Path $env:TEMP ('CafeLauncher-GraphicsApi-'+[guid]::NewGuid().ToString('N'))
try{
    $env:LOCALAPPDATA=$cloudSandbox
    $env:CAFE_SCRIPT=(Join-Path $root 'cafe.bat')
    $cloudPresetJson=Get-Content -LiteralPath (Join-Path $root 'graphics\FabMode.json') -Raw
    $cloudFixture=[pscustomobject]@{
        type='file';path='graphics/FabMode.json';encoding='base64';sha=('b'*40)
        size=[Text.Encoding]::UTF8.GetByteCount($cloudPresetJson)
        content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cloudPresetJson))
    }
    $script:GraphicsApiFixture=$cloudFixture
    $script:GraphicsApiRequest=$null
    function Invoke-CafeGitHubRestMethod {
        [CmdletBinding()]
        param([string]$Uri,[string]$Method,[int]$TimeoutSec,[int]$MaximumRedirection,$Headers)
        $script:GraphicsApiRequest=[pscustomobject]@{Uri=$Uri;Method=$Method;Headers=$Headers}
        return $script:GraphicsApiFixture
    }
    $cloudApplied=Get-CS2ModeGraphicsPreset -ModeName 'FabMode'
    if($cloudApplied.ProfileName -cne 'FabMode' -or
       $script:GraphicsApiRequest.Uri -notmatch '/contents/graphics/FabMode\.json\?ref=main&fresh=[0-9a-f]{32}$' -or
       $script:GraphicsApiRequest.Headers['Cache-Control'] -ne 'no-cache'){
        throw 'Cloud graphics preset did not use the validated GitHub Contents API response.'
    }
}finally{
    $env:LOCALAPPDATA=$oldLocalAppData
    $env:CAFE_SCRIPT=$oldCafeScript
    Remove-Item -LiteralPath $cloudSandbox -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'PASS: CS2 graphics cloud presets use the validated Contents API and no-cache headers.'
