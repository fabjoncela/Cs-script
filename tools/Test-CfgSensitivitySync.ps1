# Windows PowerShell 5.1: tests the real CFG sync logic with mocked GitHub calls.
# Does not access GitHub, require a token, or modify any actual user CFG.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$lines=[IO.File]::ReadAllLines((Join-Path $root 'cafe.bat'))
$marker=[Array]::IndexOf($lines,'# POWERSHELL_GUI')
if($marker -lt 0){throw 'Missing CafeLauncher PowerShell marker.'}
$code=[string]::Join([Environment]::NewLine,[string[]]$lines[($marker+1)..($lines.Length-1)])
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($code,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw ('Launcher syntax failed: '+$errors[0].Message)}
foreach($name in @('Get-CafeVoiceBindingFromCfg','Set-CafeVoiceBindingInCfg','ConvertTo-CafeCS2Sensitivity','Get-CafeCS2CfgSensitivity','Set-CS2CfgSensitivityText','Add-CafeCacheBust','Get-GitHubCfgFromContentsApi','Get-ProfileCfgSensitivity','Get-CafeCS2UserConvarsCapture','Set-CafeCapturedConvarsInCfg','Get-CafeCfgChangePreview','Sync-ProfileToGitHub','Export-ProfileValues','Get-ProfileGraphicsPreset','Get-GitHubJsonFromContentsApi','ConvertTo-CafeGraphicsPreset','Refresh-ProfileFromGitHub','Get-LatestGitHubFileCommit','Compare-GitHubCommitOrder','Import-ProfileValues')){
    $funcs=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true) |
        Where-Object {$_.Name -eq $name})
    if($funcs.Count -ne 1){throw ('Missing or duplicate sync function: '+$name)}
    Invoke-Expression $funcs[0].Extent.Text
}
function Assert-True {param([bool]$Value,[string]$Message);if(-not $Value){throw $Message}}
$lf=[string][char]10
$crlf=[string][char]13+$lf
$cfg='// sensitivity "999"'+$crlf+'bind "r" "+reload"'+$crlf+'    sensitivity "1.2" // keep me'+$crlf+'zoom_sensitivity_ratio "1.0"'+$crlf
$updated=Set-CS2CfgSensitivityText -Content $cfg -Sensitivity '2.4'
Assert-True ($updated.Contains('    sensitivity "2.4" // keep me')) 'Sensitivity was not replaced.'
Assert-True ($updated.Contains('// sensitivity "999"')) 'Commented-out sensitivity was changed.'
Assert-True ($updated.Contains('bind "r" "+reload"')) 'Binds were changed.'
Assert-True ($updated.Contains(('zoom_sensitivity_ratio "1.0"'+$crlf))) 'Other CFG commands / line endings changed.'
Assert-True ($updated -notmatch '(?<!\r)\n') 'CRLF line endings were not preserved.'
Assert-True ((Set-CS2CfgSensitivityText -Content $updated -Sensitivity '2.4') -ceq $updated) 'Same sensitivity should not rewrite CFG.'
$append=Set-CS2CfgSensitivityText -Content ('bind "r" "+reload"'+$lf) -Sensitivity '1.8'
Assert-True ($append -ceq ('bind "r" "+reload"'+$lf+'sensitivity "1.8"'+$lf)) 'CFG sensitivity append did not work.'
foreach($badCfg in @(
    ('sensitivity "1.2"'+$lf+'sensitivity "2.1"'+$lf)
)){
    $failed=$false
    try{[void](Set-CS2CfgSensitivityText -Content $badCfg -Sensitivity '1.1')}catch{$failed=$true}
    Assert-True $failed 'Conflicting sensitivity commands must be rejected.'
}
foreach($bad in @('0','20.1','-1','a','2; quit','1e3')){
    $failed=$false
    try{[void](Set-CS2CfgSensitivityText -Content $cfg -Sensitivity $bad)}catch{$failed=$true}
    Assert-True $failed ('Invalid sensitivity was accepted: '+$bad)
}


# Voice PTT: only replace the selected voice command, retain other binds, and reject collisions.
$voiceCfg='bind "V" "+voicerecord"'+$crlf+'bind "r" "+reload"'+$crlf+'// bind "MOUSE4" "+voicerecord"'+$crlf
Assert-True ((Get-CafeVoiceBindingFromCfg -Content $voiceCfg) -ceq 'V') 'Existing CFG voice bind not detected.'
$newVoice=Set-CafeVoiceBindingInCfg -Content $voiceCfg -Key 'MOUSE4'
Assert-True ($newVoice.Contains('bind "MOUSE4" "+voicerecord"')) 'New voice key missing.'
Assert-True ($newVoice -notmatch '(?m)^bind "V" "\+voicerecord"') 'Old voice binding was not removed.'
Assert-True ($newVoice.Contains('bind "r" "+reload"')) 'Voice update modified an unrelated bind.'
Assert-True ($newVoice -notmatch '(?<!\r)\n') 'Voice update lost CRLF line endings.'
Assert-True ((Set-CafeVoiceBindingInCfg -Content $newVoice -Key 'MOUSE4') -ceq $newVoice) 'Unchanged voice key should not rewrite CFG.'
$previewBefore='cl_crosshairgap_useweaponvalue true'+$crlf+'  cl_crosshairgap "-2"'+$crlf+'cl_crosshair_outlinethickness "1"'+$crlf+'bind "r" "+reload"'+$crlf
$previewAfter='cl_crosshair_gap "-2"'+$crlf+'cl_crosshair_drawoutline "2"'+$crlf+'bind "r" "+reload"'+$crlf
$cfgPreview=Get-CafeCfgChangePreview -CfgName 'fab.cfg' -Before $previewBefore -After $previewAfter
Assert-True ($cfgPreview.Text.Contains('- cl_crosshairgap_useweaponvalue true') -and $cfgPreview.Text.Contains('+ cl_crosshair_gap "-2"')) 'CFG preview did not show exact retired and replacement lines.'
Assert-True ($cfgPreview.HasWarnings -and $cfgPreview.Text.Contains('no replacement') -and $cfgPreview.Text.Contains('cl_crosshair_gap')) 'CFG preview did not warn that weapon-based gap behavior is lost.'
Assert-True ($cfgPreview.Text.Contains('- cl_crosshair_outlinethickness "1"') -and $cfgPreview.Text.Contains('no direct replacement') -and $cfgPreview.Text.Contains('cl_crosshair_drawoutline')) 'CFG preview did not warn that outline thickness has no direct replacement.'
$collisionCfg='bind "V" "+voicerecord"'+$lf+'bind "MOUSE4" "+jump"'+$lf
$voiceConflict=$false
try{[void](Set-CafeVoiceBindingInCfg -Content $collisionCfg -Key 'MOUSE4')}catch{$voiceConflict=$true}
Assert-True $voiceConflict 'Changing voice onto an occupied key must be rejected.'
foreach($badKey in @('MOUSE6','V; quit','', 'WHEELUP')) {
    $voiceConflict=$false
    try{[void](Set-CafeVoiceBindingInCfg -Content $voiceCfg -Key $badKey)}catch{$voiceConflict=$true}
    Assert-True $voiceConflict ('Invalid voice key was accepted: '+$badKey)
}
$duplicateVoice='bind "V" "+voicerecord"'+$lf+'bind "K" "+voicerecord"'+$lf
$voiceConflict=$false
try{[void](Set-CafeVoiceBindingInCfg -Content $duplicateVoice -Key 'MOUSE4')}catch{$voiceConflict=$true}
Assert-True $voiceConflict 'Multiple existing voice bindings must require manual review.'

$script:GithubRepo='fabjoncela/Cs-script'
$script:GithubBranch='main'
# The launcher initializes this during startup; function-only CI tests must mirror it.
$script:CapturedCS2Convars=@{}
$script:PendingCfgSensitivity=@{}
$script:GamingProfiles=[ordered]@{}
$script:PendingSync=@{}
$script:VerifiedProfileState=@{}
$script:ProfileRefreshStatus=@{}
$script:GraphicsPresets=[ordered]@{}
$script:FakeFiles=@{}
$script:FakeWrites=New-Object System.Collections.ArrayList
$script:FakeCalls=New-Object System.Collections.ArrayList
$script:FakeLogs=New-Object System.Collections.ArrayList
$script:FailJsonPut=$false
$script:CorruptProfileReadback=$false
$script:CorruptGraphicsReadback=$false
$script:FakeCommitSha=('b'*40)
$script:FakeLatestCommitSha=$script:FakeCommitSha
$script:FakeCompareStatus='ahead'
function Write-Log {param([string]$Message,[string]$Level='INFO');[void]$script:FakeLogs.Add(($Level+'|'+$Message))}
function Save-ProfileSettings {}
function Get-FakeBlobSha {param([string]$Text);$hash=[Security.Cryptography.SHA1]::Create();try{return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}}
# Sync invalidates history after a successful write. Keep this test isolated
# from the user's real per-profile history cache.
function Clear-ProfileGraphicsHistoryCache {param([string]$ProfileName)}
foreach($name in @('FabMode','ArliMode','BrileMode','ArmlMode','OliMode','Provmode')){
    $cfgName=($name -replace 'Mode$','').ToLowerInvariant()+'.cfg'
    $script:GamingProfiles[$name]=@{
        ConfigFile=$cfgName;VoicePushToTalkKey='';PointerSpeed=10;LogitechDPI=800
        DisableAcceleration=$true;ApplyNvidia=$true;Width=1920;Height=1080
        RefreshHz=360;Vibrance=75;Hue=-1;ScalingMode=2;CfgDownloadUrl='';LaunchApps=$true
    }
    $script:PendingSync[$name]=$true
    $script:PendingCfgSensitivity[$name]='1.5'
    $script:GraphicsPresets[$name]=[pscustomobject]@{
        SchemaVersion=1;ProfileName=$name;DisplayPolicy='ApplyPreset';RefreshPolicy='Highest';ScalingMode=2
        Settings=[ordered]@{Width=1280;Height=960;AspectRatioMode=0;Fullscreen=1;MSAASamples=8;ShadowQuality=0;DynamicShadows=1;TextureDetail=1;ShaderQuality=0;ParticleDetail=0;AmbientOcclusion=0;HDRDetail=3;NvidiaReflex=2;TextureFiltering=0;FSRDetail=0;VSync=0;CMAA=0}
    }
    $profileSensitivity=@{FabMode='1.1';ArliMode='1.0';ArmlMode='1.0';BrileMode='1.2';OliMode='1.2';Provmode='1.2'}[$name]
    $script:FakeFiles[$cfgName]='sensitivity "'+$profileSensitivity+'"'+$crlf+'bind "r" "+reload"'+$crlf
    $script:FakeFiles[('profiles/'+$name+'.json')]='{}'
    $script:FakeFiles[('graphics/'+$name+'.json')]='{}'
}
function Invoke-CafeGitHubRestMethod {
    [CmdletBinding()]
    param([string]$Uri,[string]$Method,[hashtable]$Headers,[int]$TimeoutSec,
        [int]$MaximumRedirection,[string]$ContentType,[string]$Body)
    if($Uri -match '/commits\?path='){
        $commitPath=[regex]::Match($Uri,'path=(?<path>[^&]+)').Groups['path'].Value
        [void]$script:FakeCalls.Add(('CommitGet:'+ $commitPath))
        return ,@([pscustomobject]@{sha=$script:FakeLatestCommitSha})
    }
    if($Uri -match '/compare/'){
        [void]$script:FakeCalls.Add('CommitCompare')
        return [pscustomobject]@{status=$script:FakeCompareStatus}
    }
    $m=[regex]::Match($Uri,'/contents/(?<path>[^?]+)')
    if(-not $m.Success){throw ('Mock caught an unexpected GitHub URL: '+$Uri)}
    $path=$m.Groups['path'].Value
    if(-not $script:FakeFiles.ContainsKey($path)){throw ('Unexpected file in GitHub mock: '+$path)}
    [void]$script:FakeCalls.Add(($Method+':'+$path))
    if($Method -eq 'Get'){
        $text=$script:FakeFiles[$path]
        if($script:CorruptProfileReadback -and $path -like 'profiles/*.json' -and $script:FakeWrites.Contains($path)){
            $stale=$text|ConvertFrom-Json
            $stale.PointerSpeed=1
            $text=$stale|ConvertTo-Json -Depth 5
        }
        if($script:CorruptGraphicsReadback -and $path -like 'graphics/*.json' -and $script:FakeWrites.Contains($path)){
            $stale=$text|ConvertFrom-Json
            $stale.Settings.Width=1024
            $text=$stale|ConvertTo-Json -Depth 6
        }
        return [pscustomobject]@{
            sha=(Get-FakeBlobSha -Text $text)
            type='file'
            path=$path
            encoding='base64'
            content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
            size=[Text.Encoding]::UTF8.GetByteCount($text)
        }
    }
    if($Method -ne 'Put'){throw ('Unexpected request method: '+$Method)}
    if($script:FailJsonPut -and $path -like 'graphics/*.json'){throw 'Simulated GitHub graphics write failure'}
    $payload=$Body|ConvertFrom-Json
    if($payload.sha -ne (Get-FakeBlobSha -Text $script:FakeFiles[$path]) -or $payload.branch -ne 'main'){
        throw ('Missing GitHub SHA / incorrect target branch for '+$path)
    }
    $newText=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload.content))
    $script:FakeFiles[$path]=$newText
    [void]$script:FakeWrites.Add($path)
    $script:FakeLatestCommitSha=$script:FakeCommitSha
    return [pscustomobject]@{commit=[pscustomobject]@{sha=$script:FakeCommitSha}}
}
# Opening Edit reads each selected profile's CFG value through the Contents API.
$expectedProfileSens=@{FabMode='1.1';ArliMode='1';ArmlMode='1';BrileMode='1.2';OliMode='1.2';Provmode='1.2'}
$oldLocalAppData=$env:LOCALAPPDATA
$testLocalAppData=Join-Path $env:TEMP ('Cafe-Cfg-Sensitivity-Test-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testLocalAppData -Force)
$env:LOCALAPPDATA=$testLocalAppData
try{
    foreach($name in $expectedProfileSens.Keys){
        $script:PendingSync[$name]=$false
        [void]$script:PendingCfgSensitivity.Remove($name)
        $loaded=Get-ProfileCfgSensitivity -ProfileName $name
        Assert-True ($loaded.Source -eq 'GitHub' -and $loaded.Sensitivity -ceq $expectedProfileSens[$name]) ($name+' did not load its own CFG sensitivity.')
        $script:PendingSync[$name]=$true
        $script:PendingCfgSensitivity[$name]='1.5'
    }
    foreach($name in $expectedProfileSens.Keys){
        $pending=Get-ProfileCfgSensitivity -ProfileName $name
        Assert-True ($pending.Source -eq 'LocalPending' -and $pending.Sensitivity -ceq '1.5') ($name+' reopened with an older CFG value instead of its local pending draft.')
    }
}finally{
    $env:LOCALAPPDATA=$oldLocalAppData
    Remove-Item -LiteralPath $testLocalAppData -Recurse -Force -ErrorAction SilentlyContinue
}
# Test each profile uses its own matching cfg and JSON, never another player's.
foreach($name in @('FabMode','ArliMode','BrileMode','ArmlMode','OliMode','Provmode')){
    $script:FakeWrites.Clear()
    $script:FakeCalls.Clear()
    Sync-ProfileToGitHub -ProfileName $name -Token ('testtoken-'+'x'*22)
    $cfgName=($name -replace 'Mode$','').ToLowerInvariant()+'.cfg'
    Assert-True ($script:FakeWrites.Count -eq 3) ($name+' should commit CFG, profile JSON, and graphics JSON.')
    Assert-True ($script:FakeWrites[0] -eq $cfgName) ($name+' did not update CFG first.')
    Assert-True ($script:FakeWrites[1] -eq ('profiles/'+$name+'.json')) ($name+' did not save matching profile JSON.')
    Assert-True ($script:FakeWrites[2] -eq ('graphics/'+$name+'.json')) ($name+' did not save matching graphics JSON.')
    Assert-True ($script:FakeFiles[$cfgName].Contains('sensitivity "1.5"')) ($name+' CFG sensitivity not persisted.')
    Assert-True ($script:FakeFiles[$cfgName].Contains('bind "r" "+reload"')) ($name+' CFG binds altered.')
    $profile=$script:FakeFiles[('profiles/'+$name+'.json')]|ConvertFrom-Json
    Assert-True (-not $profile.PSObject.Properties['CS2Sensitivity']) ($name+' JSON still contains legacy sensitivity.')
    $graphics=$script:FakeFiles[('graphics/'+$name+'.json')]|ConvertFrom-Json
    Assert-True ($graphics.ProfileName -eq $name -and $graphics.Settings.Width -eq 1280) ($name+' graphics preset differs.')
    Assert-True ($script:FakeCalls[-2] -eq ('Get:profiles/'+$name+'.json') -and $script:FakeCalls[-1] -eq ('Get:graphics/'+$name+'.json')) ($name+' did not read both saved JSON files back after upload.')
}
# Capture the post-September-2026 CS2 crosshair names from the active-account
# convars file, then verify they are written to that profile's GitHub CFG.
$script:FakeConvarsAccount='12345'
$script:FakeConvarsVideoPath=Join-Path $env:TEMP ('Cafe-CS2-user-convars-'+[guid]::NewGuid().ToString('N')+'\cs2_video.txt')
$script:FakeConvarsPath=Join-Path (Split-Path -Parent $script:FakeConvarsVideoPath) 'cs2_user_convars_0_slot0.vcfg'
[void](New-Item -ItemType Directory -Path (Split-Path -Parent $script:FakeConvarsPath) -Force)
$newConvars=@'
"config"
{
    "convars"
    {
        "sensitivity" "1.1"
        "cl_crosshair_gap" "0"
        "cl_crosshair_length" "3"
        "cl_crosshair_thickness" "3"
        "cl_crosshair_drawoutline" "2"
        "cl_crosshaircolor_a" "255"
        "cl_crosshaircolor_r" "0"
        "cl_crosshaircolor_g" "255"
        "cl_crosshaircolor_b" "255"
        "cl_crosshair_screen_height" "960"
        "cl_crosshair_dynamic_spread_limit" "226"
        "cl_crosshairoutline_a" "255"
        "cl_crosshairoutline_b" "0"
        "cl_crosshairoutline_g" "0"
        "cl_crosshairoutline_r" "0"
        "cl_crosshair_future_option" "7"
        "cl_grenadecrosshair_smoke" "true"
        "cl_crosshairgap" "3"
        "cl_crosshairsize" "2"
        "cl_crosshairthickness" "1"
        "cl_crosshaircolor" "5"
        "cl_crosshairalpha" "200"
        "cl_crosshairusealpha" "true"
        "cl_crosshairgap_useweaponvalue" "false"
        "cl_crosshair_outlinethickness" "1"
    }
}
'@
[IO.File]::WriteAllText($script:FakeConvarsPath,$newConvars)
function Get-Process {
    [CmdletBinding()]
    param([string]$Name)
    return @()
}
function Get-CafeActiveSteamVideoFile {
    return [pscustomobject]@{AccountID=$script:FakeConvarsAccount;Path=$script:FakeConvarsVideoPath}
}
$captured=Get-CafeCS2UserConvarsCapture -Source ([pscustomobject]@{Path=$script:FakeConvarsVideoPath;AccountID=$script:FakeConvarsAccount})
foreach($expected in @{
    cl_crosshair_gap='0';cl_crosshair_length='3';cl_crosshair_thickness='3';cl_crosshaircolor_a='255'
    cl_crosshaircolor_r='0';cl_crosshaircolor_g='255';cl_crosshaircolor_b='255'
    cl_crosshair_screen_height='960';cl_crosshair_dynamic_spread_limit='226';cl_crosshairoutline_a='255'
    cl_crosshair_future_option='7'
}.GetEnumerator()){
    Assert-True ($captured.Values[$expected.Key] -ceq $expected.Value) ('Current CS2 convar was not captured: '+$expected.Key)
}
Assert-True (-not $captured.Values.ContainsKey('cl_grenadecrosshair_smoke')) 'A non-crosshair command was captured.'
$script:CapturedCS2Convars['FabMode']=$captured.Values
$script:FakeFiles['fab.cfg']='sensitivity "1.5"'+$lf+'cl_crosshairgap "-3.7"'+$lf+'cl_crosshairsize "2"'+$lf+'cl_crosshairthickness "1"'+$lf+'cl_crosshaircolor "5"'+$lf+'cl_crosshairalpha "200"'+$lf+'cl_crosshairusealpha "true"'+$lf+'cl_crosshairgap_useweaponvalue "false"'+$lf+'cl_crosshair_outlinethickness "1"'+$lf
$script:FakeWrites.Clear()
Sync-ProfileToGitHub -ProfileName 'FabMode' -Token ('testtoken-'+'x'*22)
$syncedFabCfg=$script:FakeFiles['fab.cfg']
foreach($expected in @{
    'cl_crosshair_gap "0"'=$true;'cl_crosshair_length "3"'=$true
    'cl_crosshair_thickness "3"'=$true;'cl_crosshaircolor_a "255"'=$true
    'cl_crosshair_drawoutline "2"'=$true
    'cl_crosshaircolor_r "0"'=$true;'cl_crosshaircolor_g "255"'=$true;'cl_crosshaircolor_b "255"'=$true
    'cl_crosshair_screen_height "960"'=$true;'cl_crosshair_dynamic_spread_limit "226"'=$true
    'cl_crosshairoutline_a "255"'=$true;'cl_crosshair_future_option "7"'=$true
}.Keys){Assert-True ($syncedFabCfg.Contains($expected)) ('Current CS2 crosshair setting did not sync to fab.cfg: '+$expected)}
Assert-True ($script:FakeWrites[0] -eq 'fab.cfg') 'Captured crosshair values did not update the selected CFG first.'
Assert-True ($syncedFabCfg -notmatch '(?m)^\s*cl_crosshairgap\s' -and $syncedFabCfg -notmatch '(?m)^\s*cl_crosshairsize\s' -and $syncedFabCfg -notmatch '(?m)^\s*cl_crosshairthickness\s') 'New FabMode names left their legacy aliases in fab.cfg.'
Assert-True ($syncedFabCfg -notmatch '(?im)^\s*cl_crosshaircolor\s' -and $syncedFabCfg -notmatch '(?im)^\s*cl_crosshairalpha\s' -and $syncedFabCfg -notmatch '(?im)^\s*cl_crosshairusealpha\s' -and $syncedFabCfg -notmatch '(?im)^\s*cl_crosshairgap_useweaponvalue\s' -and $syncedFabCfg -notmatch '(?im)^\s*cl_crosshair_outlinethickness\s') 'Captured modern crosshair controls left retired commands in fab.cfg.'
$incompleteRetiredCleanup=Set-CafeCapturedConvarsInCfg -Content ('cl_crosshairalpha "200"'+$lf+'cl_crosshair_outlinethickness "1"'+$lf) -Values @{cl_crosshaircolor_r='0'}
Assert-True ($incompleteRetiredCleanup.Contains('cl_crosshairalpha "200"') -and $incompleteRetiredCleanup.Contains('cl_crosshair_outlinethickness "1"')) 'A partial capture removed retired settings without their modern control.'
$script:FakeFiles['fab.cfg']+='cl_crosshairgap_useweaponvalue true'+$lf
$script:CapturedCS2Convars['FabMode']=@{cl_crosshair_gap='0'}
$script:FakeWrites.Clear()
$script:ReceivedCfgPreview=$null
$canceledSync=Sync-ProfileToGitHub -ProfileName 'FabMode' -Token ('testtoken-'+'x'*22) -ConfirmCfgChanges {param($preview);$script:ReceivedCfgPreview=$preview;return $false}
Assert-True ($canceledSync.Canceled -and $script:ReceivedCfgPreview.HasWarnings) 'Rejecting the CFG preview did not cancel the sync.'
Assert-True ($script:FakeWrites.Count -eq 0) 'Canceling the CFG preview still wrote files to GitHub.'
$legacyOnly=Set-CafeCapturedConvarsInCfg -Content ('cl_crosshairgap "-3.7"'+$lf) -Values @{cl_crosshairgap='-2'}
Assert-True ($legacyOnly.Contains('cl_crosshairgap "-2"') -and -not $legacyOnly.Contains('cl_crosshair_gap')) 'A legacy-only capture should remain supported without inventing a modern setting.'

# Updating one profile migrates only that profile's legacy aliases. Exercise
# mixed spacing, quoted/unquoted values, comments, and CRLF in the destination.
$script:FakeFiles['brile.cfg']='sensitivity "1.2"'+$crlf+'bind "r" "+reload"'+$crlf+'  cl_crosshairgap   "-8" // Brile legacy gap'+$crlf+'   cl_crosshair_length  "1" // Brile old length'+$crlf+'cl_crosshair_thickness 1'+$crlf+'  cl_crosshaircolor   5 // old palette'+$crlf+'cl_crosshairalpha 200'+$crlf+' cl_crosshairusealpha true'+$crlf+'cl_crosshairgap_useweaponvalue false'+$crlf+' cl_crosshair_outlinethickness 1'+$crlf
$script:FakeFiles['arli.cfg']='sensitivity "1.0"'+$lf+'cl_crosshairgap "-2"'+$lf+'cl_crosshairsize "1"'+$lf
$script:FakeFiles['oli.cfg']='sensitivity "1.2"'+$crlf+'cl_crosshairgap "1"'+$crlf+'cl_crosshairsize "3"'+$crlf
$arliBefore=$script:FakeFiles['arli.cfg']
$oliBefore=$script:FakeFiles['oli.cfg']
$script:CapturedCS2Convars['BrileMode']=@{
    cl_crosshair_gap='4';cl_crosshairgap='-9'
    cl_crosshair_length='5';cl_crosshairsize='2'
    cl_crosshair_thickness='2';cl_crosshairthickness='1'
    cl_crosshaircolor_r='255';cl_crosshaircolor_g='255';cl_crosshaircolor_b='255';cl_crosshaircolor_a='200'
    cl_crosshair_drawoutline='1'
}
$script:FakeWrites.Clear()
Sync-ProfileToGitHub -ProfileName 'BrileMode' -Token ('testtoken-'+'x'*22)
$syncedBrileCfg=$script:FakeFiles['brile.cfg']
foreach($expected in @('cl_crosshair_gap "4"','cl_crosshair_length "5"','cl_crosshair_thickness "2"')){
    Assert-True ($syncedBrileCfg.Contains($expected)) ('Modern BrileMode crosshair setting missing: '+$expected)
}
Assert-True ($syncedBrileCfg -notmatch '(?m)^\s*cl_crosshairgap\s' -and $syncedBrileCfg -notmatch '(?m)^\s*cl_crosshairsize\s' -and $syncedBrileCfg -notmatch '(?m)^\s*cl_crosshairthickness\s') 'BrileMode kept a legacy alias beside a captured modern name.'
Assert-True ($syncedBrileCfg -notmatch '(?im)^\s*cl_crosshaircolor\s' -and $syncedBrileCfg -notmatch '(?im)^\s*cl_crosshairalpha\s' -and $syncedBrileCfg -notmatch '(?im)^\s*cl_crosshairusealpha\s' -and $syncedBrileCfg -notmatch '(?im)^\s*cl_crosshairgap_useweaponvalue\s' -and $syncedBrileCfg -notmatch '(?im)^\s*cl_crosshair_outlinethickness\s') 'BrileMode kept retired crosshair commands despite capturing their modern controls.'
Assert-True ($syncedBrileCfg.Contains('bind "r" "+reload"')) 'BrileMode crosshair migration changed an unrelated bind.'
Assert-True ($syncedBrileCfg -notmatch '(?<!\r)\n') 'BrileMode crosshair migration lost CRLF line endings.'
Assert-True ($script:FakeFiles['arli.cfg'] -ceq $arliBefore -and $script:FakeFiles['oli.cfg'] -ceq $oliBefore) 'BrileMode crosshair migration changed another profile CFG.'
Assert-True ($script:FakeWrites[0] -eq 'brile.cfg') 'BrileMode crosshair migration did not target brile.cfg first.'
Remove-Item -LiteralPath (Split-Path -Parent $script:FakeConvarsPath) -Recurse -Force

# Ensure per-profile voice binding reaches only the requested CFG and survives JSON sync.
$script:FakeFiles['arli.cfg']='sensitivity "1.0"'+$lf+'bind "V" "+voicerecord"'+$lf+'bind "r" "+reload"'+$lf
$script:GamingProfiles['ArliMode'].VoicePushToTalkKey='MOUSE4'
$script:FakeWrites.Clear()
Sync-ProfileToGitHub -ProfileName 'ArliMode' -Token ('testtoken-'+'x'*22)
Assert-True ($script:FakeFiles['arli.cfg'].Contains('bind "MOUSE4" "+voicerecord"')) 'Voice binding did not sync to arli.cfg.'
Assert-True ($script:FakeFiles['arli.cfg'].Contains('bind "r" "+reload"')) 'Voice sync removed unrelated binds.'
Assert-True ((Get-CafeVoiceBindingFromCfg -Content $script:FakeFiles['arli.cfg']) -ceq 'MOUSE4') 'Synced voice binding readback mismatch.'
Assert-True (($script:FakeFiles['profiles/ArliMode.json']|ConvertFrom-Json).VoicePushToTalkKey -ceq 'MOUSE4') 'Voice binding did not persist in profile JSON.'
Assert-True (-not $script:FakeFiles['fab.cfg'].Contains('bind "MOUSE4" "+voicerecord"')) 'Voice update leaked into FabMode.'

# Reproduce a stale post-sync refresh: a differing file blob must be checked
# against the latest path commit before it can replace verified values.
$script:GamingProfiles['FabMode'].PointerSpeed=16
$script:PendingSync['FabMode']=$true
Sync-ProfileToGitHub -ProfileName 'FabMode' -Token ('testtoken-'+'x'*22)
$script:PendingSync['FabMode']=$false
$staleProfile=$script:FakeFiles['profiles/FabMode.json']|ConvertFrom-Json
$staleProfile.PointerSpeed=2
$script:FakeFiles['profiles/FabMode.json']=$staleProfile|ConvertTo-Json -Depth 5
$script:FakeLatestCommitSha=$script:VerifiedProfileState['FabMode'].CommitSha
$script:FakeLogs.Clear()
Refresh-ProfileFromGitHub -ProfileName 'FabMode'
Assert-True ($script:GamingProfiles['FabMode'].PointerSpeed -eq 16) 'Immediate post-sync refresh replaced the verified pointer speed with stale data.'
Assert-True ($script:FakeCalls[-1] -like 'CommitGet:*') 'A differing profile blob was not checked against the latest path commit.'
Assert-True (($script:FakeLogs -join "`n").Contains('latestCommit='+$script:FakeLatestCommitSha)) 'Verified-cache log must include the returned GitHub commit SHA.'
# GitHub can briefly return the previous path commit after a successful push.
# If that SHA is an ancestor of the verified sync commit, never apply it.
$oldCommitProfile=$script:FakeFiles['profiles/FabMode.json']|ConvertFrom-Json
$oldCommitProfile.PointerSpeed=6
$script:FakeFiles['profiles/FabMode.json']=$oldCommitProfile|ConvertTo-Json -Depth 5
$script:FakeLatestCommitSha=('a'*40)
$script:FakeCompareStatus='behind'
Refresh-ProfileFromGitHub -ProfileName 'FabMode'
Assert-True ($script:GamingProfiles['FabMode'].PointerSpeed -eq 16) 'A stale ancestor commit rolled the profile back after a verified sync.'
Assert-True ($script:VerifiedProfileState['FabMode'].CommitSha -eq $script:FakeCommitSha) 'Stale ancestor commit replaced the last verified GitHub commit metadata.'
Assert-True ($script:FakeCalls[-1] -eq 'CommitCompare') 'A candidate older GitHub commit was not ancestry-checked.'
$staleAncestorLog=[string]$script:FakeLogs[-1]
Assert-True ($staleAncestorLog.StartsWith('INFO|') -and $staleAncestorLog.Contains('No action needed') -and $staleAncestorLog.Contains('decision=ignore-stale-ancestor')) 'An expected stale ancestor should be logged as informational with a clear no-action message.'
# A genuine later profile edit is loaded from the exact immutable commit.
$newerProfile=$script:FakeFiles['profiles/FabMode.json']|ConvertFrom-Json
$newerProfile.PointerSpeed=12
$script:FakeFiles['profiles/FabMode.json']=$newerProfile|ConvertTo-Json -Depth 5
$script:FakeLatestCommitSha=('c'*40)
$script:FakeCompareStatus='ahead'
$script:FakeLogs.Clear()
Refresh-ProfileFromGitHub -ProfileName 'FabMode'
Assert-True ($script:GamingProfiles['FabMode'].PointerSpeed -eq 12) 'A confirmed newer GitHub profile commit was not applied.'
Assert-True ($script:VerifiedProfileState['FabMode'].CommitSha -eq $script:FakeLatestCommitSha) 'The newer immutable commit was not recorded locally.'
Assert-True (($script:FakeLogs -join "`n").Contains('latestCommit='+$script:FakeLatestCommitSha) -and ($script:FakeLogs -join "`n").Contains('pointerBefore=16; pointerLoaded=12')) 'Remote refresh log must include its commit SHA and the pointer value transition.'
# With no pending sensitivity edit, sync validates but preserves the CFG value.
$script:PendingCfgSensitivity.Remove('FabMode')|Out-Null
$script:PendingSync['FabMode']=$true
$cfgBefore=$script:FakeFiles['fab.cfg']
$script:FakeWrites.Clear()
Sync-ProfileToGitHub -ProfileName 'FabMode' -Token ('testtoken-'+'x'*22)
Assert-True ($script:FakeWrites.Count -eq 1 -and $script:FakeWrites[0] -eq 'profiles/FabMode.json') 'No sensitivity draft should sync profile settings without editing the CFG or creating an unchanged graphics revision.'
Assert-True ($cfgBefore -ceq $script:FakeFiles['fab.cfg']) 'Sync without a sensitivity draft modified CFG.'
Assert-True (-not ($script:FakeFiles['profiles/FabMode.json']|ConvertFrom-Json).PSObject.Properties['CS2Sensitivity']) 'Synced profile JSON retained legacy sensitivity.'
# Simulate graphics commit failure after CFG and profile commits.
$script:PendingCfgSensitivity['FabMode']='3.3'
$script:GraphicsPresets['FabMode'].Settings.Width=1366
$beforeJson=$script:FakeFiles['profiles/FabMode.json']
$script:FakeWrites.Clear()
$script:FailJsonPut=$true
$failureMessage=''
try{Sync-ProfileToGitHub -ProfileName 'FabMode' -Token ('testtoken-'+'x'*22)}
catch{$failureMessage=$_.Exception.Message}
$script:FailJsonPut=$false
Assert-True ($failureMessage.Contains('PARTIAL SYNC') -and $failureMessage.Contains('graphics/FabMode.json')) ('Partial upload must identify saved files and the missing graphics file. Actual error: '+$failureMessage)
Assert-True ($script:FakeFiles['fab.cfg'].Contains('sensitivity "3.3"')) 'CFG should be updated before a later JSON failure.'
Assert-True ($script:FakeWrites.Contains('profiles/FabMode.json')) 'Profile upload should be recorded before the simulated graphics failure.'
$script:FakeWrites.Clear()
Sync-ProfileToGitHub -ProfileName 'FabMode' -Token ('testtoken-'+'x'*22)
Assert-True ($script:FakeWrites.Count -eq 2 -and $script:FakeWrites[0] -eq 'profiles/FabMode.json' -and $script:FakeWrites[1] -eq 'graphics/FabMode.json') 'Retry must finish both JSON files without a duplicate CFG commit.'
# A successful PUT response is not enough: stale or mismatched read-back must fail sync.
$script:FakeWrites.Clear()
$script:CorruptProfileReadback=$true
$failureMessage=''
try{Sync-ProfileToGitHub -ProfileName 'FabMode' -Token ('testtoken-'+'x'*22)}catch{$failureMessage=$_.Exception.Message}
$script:CorruptProfileReadback=$false
Assert-True ($failureMessage.Contains('read-back verification failed') -and $failureMessage.Contains('pending')) ('Mismatched remote read-back must leave the sync unconfirmed. Actual error: '+$failureMessage)
$script:GraphicsPresets['FabMode'].Settings.Width=1440
$script:FakeWrites.Clear()
$script:CorruptGraphicsReadback=$true
$failureMessage=''
try{Sync-ProfileToGitHub -ProfileName 'FabMode' -Token ('testtoken-'+'x'*22)}catch{$failureMessage=$_.Exception.Message}
$script:CorruptGraphicsReadback=$false
Assert-True ($failureMessage.Contains('read-back verification failed') -and $failureMessage.Contains('pending')) ('Mismatched graphics read-back must leave the sync unconfirmed. Actual error: '+$failureMessage)
# Reject mismatched or forged CFG filenames and never send a request.
$script:GamingProfiles['OliMode'].ConfigFile='fab.cfg'
$script:FakeWrites.Clear()
$failureMessage=''
try{Sync-ProfileToGitHub -ProfileName 'OliMode' -Token ('testtoken-'+'x'*22)}
catch{$failureMessage=$_.Exception.Message}
Assert-True ($failureMessage.Contains('unexpected CFG')) 'Cross-profile CFG path must be blocked.'
Assert-True ($script:FakeWrites.Count -eq 0) 'Unsafe CFG path must not write anything.'
Write-Host 'PASS: dynamic CS2 crosshair capture and CFG sync; 6 profile/graphics syncs; authenticated read-back; commit-anchored profile refresh; stale profile/graphics rejection; sensitivity and voice handling; retry; partial failure; path validation.'
