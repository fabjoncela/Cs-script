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
$profileNames=@('FabMode','ArliMode','BrileMode','ArmlMode','OliMode')
foreach($name in $profileNames){
    $file=Join-Path $root ('graphics\'+$name+'.json')
    $json=Get-Content -LiteralPath $file -Raw|ConvertFrom-Json
    if([int]$json.SchemaVersion -ne 1 -or $json.ProfileName -cne $name){throw 'Preset schema/name mismatch.'}
    $values=ConvertTo-VideoGraphicsSettings -Preset $json
    if($values.Count -lt 5){throw ('Too few actual video settings in '+$name+' preset.')}
    if($values.Contains('Width') -or $values.Contains('RefreshHz')){throw 'Starter presets must preserve PC-specific display modes.'}
}
$batText=[IO.File]::ReadAllText($bat)
if($batText -notmatch '\$graphics\.Add_Click' -or $batText -notmatch 'Invoke-GraphicsOnly -ModeName \$selectedProfile'){
    throw 'Apply Graphics GUI button missing.'
}
if($batText -match '(?s)function Invoke-GamingProfile \{.*?Apply-CS2ModeGraphics'){
    throw 'Graphics must never be called inside profile application.'
}
if($batText -match 'Invoke-GamingProfile.+Invoke-GraphicsOnly'){
    throw 'Profile main action must not call the independent graphics loader.'
}
Write-Host 'PASS: all five graphics presets, selective VDF edits, graphics ranges, hardware preservation, and standalone GUI trigger.'
