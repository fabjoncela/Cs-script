# Read-only Windows PowerShell 5.1 graphics regression test. No Steam/CS2 writes.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$module=Join-Path $root 'graphics\ApplyGraphics.ps1'
$bat=Join-Path $root 'cafe.bat'
$source=[IO.File]::ReadAllText($module)
$tok=$null;$errors=$null
[void][System.Management.Automation.Language.Parser]::ParseInput($source,[ref]$tok,[ref]$errors)
if(@($errors).Count -gt 0){throw ('Graphics module syntax error: '+$errors[0].Message)}
. $module
function Write-Log {param([string]$Message,[string]$Level='INFO')}
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
    "setting.videocfg_shadow_quality" "2"
    "setting.videocfg_texture_detail" "2"
    "setting.shaderquality" "1"
    "setting.videocfg_hdr_detail" "-1"
    "setting.r_low_latency" "0"
    "setting.custom_unknown" "keep me"
}
'@
$settings=[ordered]@{MSAASamples=2;ShadowQuality=0;TextureDetail=0;NvidiaReflex=1}
$result=Update-CS2VideoGraphicsText -Text $fixture -Settings $settings
if($result.Applied.Count -ne 4 -or -not $result.Changed){throw 'Graphics helper did not update four fields.'}
if($result.Text -notmatch '"setting\.msaa_samples"\s+"2"' -or
   $result.Text -notmatch '"setting\.r_low_latency"\s+"1"'){throw 'Graphics values not edited correctly.'}
foreach($unchanged in @('"VendorID" "4318"','"DeviceID" "12345"','"setting.monitor_index" "2"','"setting.custom_unknown" "keep me"')){
    if(-not $result.Text.Contains($unchanged)){throw ('Unrelated device/video setting changed: '+$unchanged)}
}
if((Update-CS2VideoGraphicsText -Text $result.Text -Settings $settings).Changed){throw 'Re-applying must be idempotent.'}
$display=[ordered]@{Width=1280;Height=960;RefreshHz=240;Fullscreen=1}
$skip=Update-CS2VideoGraphicsText -Text $fixture -Settings $display -SkipDisplay
if($skip.Text -notmatch '"setting.defaultres" "1920"' -or $skip.Text -notmatch '"setting.fullscreen" "1"'){
    throw 'Unsupported resolution must be preserved.'
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
    $proposed=Update-CS2VideoGraphicsText -Text $fixture -Settings ([ordered]@{MSAASamples=2})
    Save-CS2VideoFileWithBackup -VideoPath $target -UpdatedText $proposed.Text -Encoding $encoding -BackupPath $backup
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
    $failed=$false
    try {
        Save-CS2VideoFileWithBackup -VideoPath $target -UpdatedText $fixture -Encoding $encoding -BackupPath $badBackup
    } catch { $failed=$true }
    if (-not $failed -or [IO.File]::ReadAllText($target,$encoding) -cne $preFailure) {
        throw 'Graphics backup failure must not change the existing video file.'
    }
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

$profileNames=@('FabMode','ArliMode','BrileMode','ArmlMode','OliMode')
foreach($name in $profileNames){
    $file=Join-Path $root ('graphics\'+$name+'.json')
    $json=Get-Content -LiteralPath $file -Raw|ConvertFrom-Json
    if([int]$json.SchemaVersion -ne 1 -or $json.ProfileName -cne $name){throw 'Preset schema/name mismatch.'}
    $values=ConvertTo-VideoGraphicsSettings -Preset $json
    if($values.Count -lt 5){throw ('Too few actual video settings in '+$name+' preset.')}
    # FabMode deliberately requests its own CS2 1280x960 @ 360Hz mode.
    # The graphics editor validates this against the actual monitor before writing;
    # unlike other profiles, FabMode must not be forced to keep native resolution.
    if($name -eq 'FabMode'){
        if(-not $values.Contains('Width') -or -not $values.Contains('Height') -or
           -not $values.Contains('RefreshHz') -or
           [int]$values['Width'] -ne 1280 -or [int]$values['Height'] -ne 960 -or
           [int]$values['RefreshHz'] -ne 360 -or
           [int]$values['AspectRatioMode'] -ne 0 -or [int]$values['Fullscreen'] -ne 1){
            throw 'FabMode must specify 1280x960, 4:3, fullscreen, 360Hz.'
        }
    }else{
        if($values.Contains('Width') -or $values.Contains('Height') -or $values.Contains('RefreshHz')){
            throw ($name + ' must preserve PC-specific display modes unless explicitly customized.')
        }
    }
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
   -not [FabDisplayNative].GetMethod('IsAdvertisedMode')){
    throw 'Read-only advertised-mode helper was not compiled.'
}
if([FabDisplayNative]::IsAdvertisedMode(1,1,0)){
    throw 'Invalid resolution must not pass display mode validation.'
}
Write-Host 'PASS: actual Windows File.Replace with backups, safe failure, five graphics presets, selective edits, graphics ranges, hardware preservation, and standalone GUI trigger.'
