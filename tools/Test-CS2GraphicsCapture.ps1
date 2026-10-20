# Windows PowerShell 5.1 fixture tests for importing CS2's saved graphics.
# Does not launch CS2/Steam, write game files, or contact GitHub.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$bat=[IO.File]::ReadAllText((Join-Path $repo 'cafe.bat'))
$marker=$bat.IndexOf('# POWERSHELL_GUI',[StringComparison]::Ordinal)
if($marker -lt 0){throw 'Missing launcher PowerShell marker.'}
$start=$bat.IndexOf("`n",$marker)+1
$source=$bat.Substring($start)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw ('Launcher PowerShell failed to parse: '+$errors[0].Message)}
$wanted=@('ConvertTo-CafeGraphicsPreset','Get-CafeActiveSteamVideoFile','ConvertFrom-CafeCS2VideoText','Get-CafeCS2GraphicsCapture','Get-CafeCS2ConvarGroup','ConvertFrom-CafeCS2UserConvarsText','Get-CafeCS2UserConvarsCapture','Get-CafeCS2BindGroup','Set-CafeCS2PendingVoiceBind','Remove-CafeCS2PendingVoiceBindActions','ConvertFrom-CafeCS2UserKeysText','Get-CafeCS2UserKeysCapture','Get-CafeCS2CaptureDisplayName','Format-CafeCS2CaptureValue','Get-CafeCS2CfgConvarValue','Get-CafeCS2CfgConvarMap','Get-CafeCS2CfgBindMap','Get-CafeCS2CaptureReviewRows','Show-CafeCS2CaptureOptionsDialog','Show-CafeCS2CaptureReviewDialog','Show-CafeCS2ExtrasDialog','Invoke-CafeCS2CaptureReview')
$definitions=@{}
foreach($function in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
    if($function.Name -in $wanted){$definitions[$function.Name]=$function.Extent.Text}
}
foreach($name in $wanted){if(-not $definitions.ContainsKey($name)){throw ('Missing function under test: '+$name)};Invoke-Expression $definitions[$name]}

$script:GamingProfiles=@{FabMode=@{ScalingMode=2};BrileMode=@{ScalingMode=5}}
$base=Get-Content -LiteralPath (Join-Path $repo 'graphics\FabMode.json') -Raw|ConvertFrom-Json
$base=ConvertTo-CafeGraphicsPreset -ProfileName FabMode -Preset $base
$base.RefreshPolicy='Highest'
if($base.Settings.Contains('RefreshHz')){[void]$base.Settings.Remove('RefreshHz')}

$video=@'
"video.cfg"
{
    "setting.defaultres" "1280"
    "setting.defaultresheight" "960"
    "setting.refreshrate_numerator" "165003"
    "setting.refreshrate_denominator" "1000"
    "setting.aspectratiomode" "0"
    "setting.fullscreen" "1"
    "setting.msaa_samples" "8"
    "setting.videocfg_shadow_quality" "0"
    "setting.videocfg_dynamic_shadows" "1"
    "setting.videocfg_texture_detail" "1"
    "setting.shaderquality" "0"
    "setting.videocfg_particle_detail" "0"
    "setting.videocfg_ao_detail" "0"
    "setting.videocfg_hdr_detail" "3"
    "setting.r_low_latency" "2"
    "setting.r_texturefilteringquality" "0"
    "setting.videocfg_fsr_detail" "0"
    "setting.mat_vsync" "0"
    "setting.r_csgo_cmaa_enable" "0"
}
'@
$capture=ConvertFrom-CafeCS2VideoText -ProfileName FabMode -Text $video -BasePreset $base -Path 'fixture\cs2_video.txt' -AccountID '12345'
$expectedFsrProfileValue=@{0=0;1=4;2=3;3=2;4=1}
foreach($cs2FsrValue in 0..4){
    $variant=$video.Replace('"setting.videocfg_fsr_detail" "0"','"setting.videocfg_fsr_detail" "'+$cs2FsrValue+'"')
    $fsrCapture=ConvertFrom-CafeCS2VideoText -ProfileName FabMode -Text $variant -BasePreset $base
    if([int]$fsrCapture.Preset.Settings.FSRDetail -ne [int]$expectedFsrProfileValue[$cs2FsrValue]){
        throw ('CS2 FSR value '+$cs2FsrValue+' did not map back to profile value '+$expectedFsrProfileValue[$cs2FsrValue]+'.')
    }
}
if($capture.Preset.Settings.Width -ne 1280 -or $capture.Preset.Settings.Height -ne 960 -or $capture.Preset.Settings.AspectRatioMode -ne 0){throw 'Capture did not import resolution and aspect ratio.'}
if($capture.Preset.Settings.RefreshHz -ne 165 -or $capture.Preset.RefreshPolicy -ne 'Exact' -or -not $capture.RefreshWasRounded){throw 'Capture did not convert the rational refresh rate accurately.'}
if($capture.Preset.Settings.MSAASamples -ne 8 -or $capture.Preset.Settings.CMAA -ne 0 -or $capture.Preset.Settings.NvidiaReflex -ne 2 -or $capture.Preset.ScalingMode -ne 2){throw 'Capture did not import both anti-aliasing fields or preserve the profile scaling mode.'}
if($capture.MissingFields.Count -ne 0){throw 'Complete fixture was reported as missing values.'}

$partial=$video -replace '(?m)^\s*"setting\.videocfg_hdr_detail".*\r?\n','' -replace '(?m)^\s*"setting\.refreshrate_(numerator|denominator)".*\r?\n',''
$partialCapture=ConvertFrom-CafeCS2VideoText -ProfileName FabMode -Text $partial -BasePreset $base
if($partialCapture.Preset.RefreshPolicy -ne 'Highest' -or $partialCapture.MissingFields -notcontains 'HDRDetail' -or $partialCapture.MissingFields -notcontains 'RefreshHz'){
    throw 'Missing values were not reported or did not retain the profile refresh policy.'
}
if($partialCapture.Preset.Settings.HDRDetail -ne $base.Settings.HDRDetail){throw 'A missing quality value did not preserve the existing profile value.'}

$expectFailure={param([string]$Text,[string]$Name)
    $failed=$false
    try{[void](ConvertFrom-CafeCS2VideoText -ProfileName FabMode -Text $Text -BasePreset $base)}catch{$failed=$true}
    if(-not $failed){throw ('Invalid capture input was accepted: '+$Name)}
}
& $expectFailure 'not a CS2 video file' 'unrecognized format'
& $expectFailure ($video -replace '"setting.defaultres" "1280"','"setting.defaultres" "20000"') 'out-of-range resolution'
& $expectFailure ($video.Replace('"setting.fullscreen" "1"',('"setting.fullscreen" "1"'+[Environment]::NewLine+'    "setting.fullscreen" "1"'))) 'duplicate key'
& $expectFailure ($video -replace '"setting.refreshrate_denominator" "1000"','"setting.refreshrate_denominator" "0"') 'invalid refresh denominator'

$script:CaptureTestSteamRoot=Join-Path $env:TEMP ('Cafe-CS2-Capture-'+[guid]::NewGuid().ToString('N'))
$script:CaptureTestActiveUser=12345
$script:CaptureTestRegistryRead=0
$script:CaptureTestAccountChanges=$false
$script:CaptureTestGameRunning=$false
$steamExe=Join-Path $script:CaptureTestSteamRoot 'steam.exe'
$videoPath=Join-Path $script:CaptureTestSteamRoot 'userdata\12345\730\local\cfg\cs2_video.txt'
$convarsPath=Join-Path (Split-Path -Parent $videoPath) 'cs2_user_convars_0_slot0.vcfg'
$keysPath=Join-Path (Split-Path -Parent $videoPath) 'cs2_user_keys_0_slot0.vcfg'
[void](New-Item -ItemType Directory -Path (Split-Path -Parent $videoPath) -Force)
[IO.File]::WriteAllText($steamExe,'fixture')
[IO.File]::WriteAllText($videoPath,$video)
[IO.File]::WriteAllText($convarsPath,('{'+[Environment]::NewLine+'"sensitivity" "1.8"'+[Environment]::NewLine+'"viewmodel_fov" "68"'+[Environment]::NewLine+'"cl_radar_scale" "0.7"'+[Environment]::NewLine+'}'))
[IO.File]::WriteAllText($keysPath,('"bindings"'+[Environment]::NewLine+'{'+[Environment]::NewLine+'"SPACE" "+jump"'+[Environment]::NewLine+'"V" "+voicerecord"'+[Environment]::NewLine+'"MWHEELDOWN" ""'+[Environment]::NewLine+'}'))
function Get-Process {
    [CmdletBinding()]
    param([string]$Name)
    if($Name -eq 'steam'){return @([pscustomobject]@{Path=$script:CaptureTestSteamRoot+'\steam.exe'})}
    if($Name -eq 'cs2' -and $script:CaptureTestGameRunning){return @([pscustomobject]@{Path='cs2.exe'})}
    return @()
}
function Get-ItemProperty {
    [CmdletBinding()]
    param([string]$LiteralPath)
    if($LiteralPath -ne 'HKCU:\Software\Valve\Steam\ActiveProcess'){throw ('Unexpected registry path: '+$LiteralPath)}
    $script:CaptureTestRegistryRead++
    $id=$script:CaptureTestActiveUser
    if($script:CaptureTestAccountChanges -and $script:CaptureTestRegistryRead -gt 1){$id=54321}
    return [pscustomobject]@{ActiveUser=$id}
}
$diskCapture=Get-CafeCS2GraphicsCapture -ProfileName FabMode -BasePreset $base
$source=[pscustomobject]@{Path=$videoPath;AccountID='12345'}
$diskConvars=Get-CafeCS2UserConvarsCapture -Source $source -Groups @('Sensitivity','Viewmodel')
$diskBinds=Get-CafeCS2UserKeysCapture -Source $source -Groups @('Jump','Scroll wheel')
if($diskConvars.Values['sensitivity'] -cne '1.8' -or -not $diskConvars.Values.ContainsKey('viewmodel_fov')){throw 'Saved convar file was not captured for the active Steam account.'}
if(-not $diskBinds.Values.ContainsKey('SPACE') -or -not $diskBinds.Values.ContainsKey('MWHEELDOWN')){throw 'Saved key file was not captured for the active Steam account.'}
if($diskCapture.AccountID -ne '12345' -or $diskCapture.Path -cne $videoPath){throw 'Capture selected the wrong active-account video file.'}
$script:CaptureTestGameRunning=$true
$failed=$false
try{[void](Get-CafeCS2GraphicsCapture -ProfileName FabMode -BasePreset $base)}catch{$failed=$_.Exception.Message -match 'Close CS2'}
if(-not $failed){throw 'Capture was allowed while CS2 was running.'}
$failed=$false
try{[void](Get-CafeCS2UserConvarsCapture -Source $source)}catch{$failed=$_.Exception.Message -match 'Close CS2'}
if(-not $failed){throw 'Convar capture was allowed while CS2 was running.'}
$failed=$false
try{[void](Get-CafeCS2UserKeysCapture -Source $source)}catch{$failed=$_.Exception.Message -match 'Close CS2'}
if(-not $failed){throw 'Key capture was allowed while CS2 was running.'}
$script:CaptureTestGameRunning=$false
$script:CaptureTestRegistryRead=0
$script:CaptureTestAccountChanges=$true
$failed=$false
try{[void](Get-CafeCS2GraphicsCapture -ProfileName FabMode -BasePreset $base)}catch{$failed=$_.Exception.Message -match 'account changed'}
if(-not $failed){throw 'Capture was allowed to continue after the active Steam account changed.'}
$script:CaptureTestRegistryRead=0;$script:CaptureTestActiveUser=54321;$failed=$false
try{[void](Get-CafeCS2UserConvarsCapture -Source $source)}catch{$failed=$_.Exception.Message -match 'account changed'}
if(-not $failed){throw 'Convar capture was allowed to continue after the active Steam account changed.'}
$script:CaptureTestRegistryRead=0;$script:CaptureTestActiveUser=12345;$failed=$false
$script:CaptureTestActiveUser=54321
try{[void](Get-CafeCS2UserKeysCapture -Source $source)}catch{$failed=$_.Exception.Message -match 'account changed'}
if(-not $failed){throw 'Key capture was allowed to continue after the active Steam account changed.'}
$script:CaptureTestActiveUser=12345

$editor=$definitions= $null
$editorAst=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-ProfileEditor'},$true)|Select-Object -First 1
$editor=$editorAst.Extent.Text
foreach($required in @('$cs2Grid=New-EditorTabGrid -Page $cs2Page -Rows 29','$captureGraphics.Text=''Capture from CS2''','$editExtras.Text=''Edit Extras''','$editExtras.Add_Click({','Show-CafeCS2ExtrasDialog -ProfileName $ProfileName','$capturedCS2BindsState[$ProfileName]=$extras.Binds','Set-CafeCS2PendingVoiceBind -ProfileName $ProfileName -Key $selectedVoiceKey -BindsByProfile $extrasPendingBinds','Remove-CafeCS2PendingVoiceBindActions -ProfileName $ProfileName -BindsByProfile $capturedCS2BindsState')){
    if($editor -notmatch [regex]::Escape($required)){throw ('Profile editor capture workflow is missing: '+$required)}
}
$extrasDialog=$definitions['Show-CafeCS2ExtrasDialog']
foreach($required in @('Reset section to defaults','Reset selected to default','Reset selected group','Stage Extras','blank = default','CafeCS2ResetToDefaultMarker','Review bind changes:','Push-to-talk will move to ','binding(s) will be removed.')){if($extrasDialog -notmatch [regex]::Escape($required)){throw ('CS2 Extras editor behavior is missing: '+$required)}}
$sensitivityField="Add-EditorTabField -Grid `$mouseGrid -Title 'CS2 sensitivity (profile CFG source)' -Control `$sens -Column 0 -Row 1"
foreach($required in @('$mouseGrid=New-EditorTabGrid -Page $mousePage -Rows 5',$sensitivityField,'Get-ProfileCfgSensitivity -ProfileName $ProfileName','$sens.Text=[string]$cfgSensitivity.Sensitivity','$pendingCfgSensitivityState[$ProfileName]=$sensValue','ConvertTo-CafeCS2Sensitivity -Value ([string]$result.Sensitivity.Value)')){
    if($editor -notmatch [regex]::Escape($required)){throw ('CS2 sensitivity Mouse tab workflow is missing: '+$required)}
}
if($editor -match [regex]::Escape("Add-EditorTabField -Grid `$cs2Grid -Title 'CS2 sensitivity")){
    throw 'CS2 sensitivity input must no longer be on the CS2 / Apps tab.'
}
foreach($required in @('$invokeCS2Capture={','$captureGraphics.Add_Click($invokeCS2Capture)','Show-CafeCS2CaptureOptionsDialog','Invoke-CafeCS2CaptureReview','Choose groups, review changes, then save or sync','pendingSyncState[$ProfileName]=$true','No game files were changed or synced.')){
    if($editor -notmatch [regex]::Escape($required)){throw ('Review capture action is missing: '+$required)}
}
$options=$definitions['Show-CafeCS2CaptureOptionsDialog']
foreach($group in @('Graphics','Sensitivity','Crosshair','Viewmodel','HUD and Radar','Audio','Movement','Jump','Crouch','Walk','Use','Voice','Reload','Inspect','Scoreboard','Attack','Secondary attack','Drop','Weapon slots','Grenade keys','Scroll wheel')){if($options -notmatch [regex]::Escape($group)){throw ('Capture group is missing: '+$group)}}
$review=$definitions['Show-CafeCS2CaptureReviewDialog']
foreach($label in @('Import selected','Current profile','Saved in CS2','Will replace')){if($review -notmatch [regex]::Escape($label)){throw ('Capture review UI is missing: '+$label)}}
$captureReview=$definitions['Invoke-CafeCS2CaptureReview']
if($captureReview -notmatch [regex]::Escape("if(`$voiceRow){foreach(`$key in @(`$stagedBinds.Keys))")){throw 'A newly captured push-to-talk key must replace any older pending key in the same profile.'}

Remove-Item -LiteralPath $script:CaptureTestSteamRoot -Recurse -Force
Write-Host 'CS2 graphics capture tests passed.'
