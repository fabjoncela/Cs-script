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
$wanted=@('ConvertTo-CafeGraphicsPreset','Get-CafeActiveSteamVideoFile','ConvertFrom-CafeCS2VideoText','Get-CafeCS2GraphicsCapture')
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
if($capture.Preset.Settings.Width -ne 1280 -or $capture.Preset.Settings.Height -ne 960 -or $capture.Preset.Settings.AspectRatioMode -ne 0){throw 'Capture did not import resolution and aspect ratio.'}
if($capture.Preset.Settings.RefreshHz -ne 165 -or $capture.Preset.RefreshPolicy -ne 'Exact' -or -not $capture.RefreshWasRounded){throw 'Capture did not convert the rational refresh rate accurately.'}
if($capture.Preset.Settings.MSAASamples -ne 8 -or $capture.Preset.Settings.NvidiaReflex -ne 2 -or $capture.Preset.ScalingMode -ne 2){throw 'Capture did not import video quality or preserve the profile scaling mode.'}
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
[void](New-Item -ItemType Directory -Path (Split-Path -Parent $videoPath) -Force)
[IO.File]::WriteAllText($steamExe,'fixture')
[IO.File]::WriteAllText($videoPath,$video)
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
if($diskCapture.AccountID -ne '12345' -or $diskCapture.Path -cne $videoPath){throw 'Capture selected the wrong active-account video file.'}
$script:CaptureTestGameRunning=$true
$failed=$false
try{[void](Get-CafeCS2GraphicsCapture -ProfileName FabMode -BasePreset $base)}catch{$failed=$_.Exception.Message -match 'Close CS2'}
if(-not $failed){throw 'Capture was allowed while CS2 was running.'}
$script:CaptureTestGameRunning=$false
$script:CaptureTestRegistryRead=0
$script:CaptureTestAccountChanges=$true
$failed=$false
try{[void](Get-CafeCS2GraphicsCapture -ProfileName FabMode -BasePreset $base)}catch{$failed=$_.Exception.Message -match 'account changed'}
if(-not $failed){throw 'Capture was allowed to continue after the active Steam account changed.'}

$editor=$definitions= $null
$editorAst=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-ProfileEditor'},$true)|Select-Object -First 1
$editor=$editorAst.Extent.Text
foreach($required in @('$cs2Grid=New-EditorTabGrid -Page $cs2Page -Rows 20','$captureGraphics.Text=''Capture from CS2''','Get-CafeCS2GraphicsCapture -ProfileName $ProfileName -BasePreset $graphicsPreset','Save & Sync to publish')){
    if($editor -notmatch [regex]::Escape($required)){throw ('Profile editor capture workflow is missing: '+$required)}
}
foreach($required in @('$invokeCS2Capture={','$captureGraphics.Add_Click($invokeCS2Capture)','if($CaptureOnOpen)','$dialog.Add_Shown({ & $invokeCS2Capture }','$capturedCS2ConvarsState = $script:CapturedCS2Convars','$capturedCS2ConvarsState[$ProfileName]=$convars.Values','[void]$capturedCS2ConvarsState.Remove($ProfileName)','$capturedCS2ConvarsState.ContainsKey($ProfileName)')){
    if($editor -notmatch [regex]::Escape($required)){throw ('Shared CS2 capture action is missing: '+$required)}
}

Remove-Item -LiteralPath $script:CaptureTestSteamRoot -Recurse -Force
Write-Host 'CS2 graphics capture tests passed.'
