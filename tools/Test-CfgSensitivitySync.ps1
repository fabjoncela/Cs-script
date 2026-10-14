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
foreach($name in @('Set-CS2CfgSensitivityText','Sync-ProfileToGitHub','Export-ProfileValues','Get-ProfileGraphicsPreset','Get-GitHubJsonFromContentsApi','ConvertTo-CafeGraphicsPreset')){
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

$script:GithubRepo='fabjoncela/Cs-script'
$script:GithubBranch='main'
$script:GamingProfiles=[ordered]@{}
$script:PendingSync=@{}
$script:GraphicsPresets=[ordered]@{}
$script:FakeFiles=@{}
$script:FakeWrites=New-Object System.Collections.ArrayList
$script:FakeCalls=New-Object System.Collections.ArrayList
$script:FailJsonPut=$false
$script:CorruptProfileReadback=$false
$script:CorruptGraphicsReadback=$false
$script:FakeSha=('a'*40)
function Write-Log {param([string]$Message,[string]$Level='INFO')}
# Sync invalidates history after a successful write. Keep this test isolated
# from the user's real per-profile history cache.
function Clear-ProfileGraphicsHistoryCache {param([string]$ProfileName)}
foreach($name in @('FabMode','ArliMode','BrileMode','ArmlMode','OliMode')){
    $cfgName=($name -replace 'Mode$','').ToLowerInvariant()+'.cfg'
    $script:GamingProfiles[$name]=@{
        ConfigFile=$cfgName;CS2Sensitivity='1.5';PointerSpeed=10;LogitechDPI=800
        DisableAcceleration=$true;ApplyNvidia=$true;Width=1920;Height=1080
        RefreshHz=360;Vibrance=75;Hue=-1;ScalingMode=2;CfgDownloadUrl='';LaunchApps=$true
    }
    $script:PendingSync[$name]=$true
    $script:GraphicsPresets[$name]=[pscustomobject]@{
        SchemaVersion=1;ProfileName=$name;DisplayPolicy='ApplyPreset';RefreshPolicy='Highest';ScalingMode=2
        Settings=[ordered]@{Width=1280;Height=960;AspectRatioMode=0;Fullscreen=1;MSAASamples=8;ShadowQuality=0;DynamicShadows=1;TextureDetail=1;ShaderQuality=0;ParticleDetail=0;AmbientOcclusion=0;HDRDetail=3;NvidiaReflex=2;TextureFiltering=0;FSRDetail=0;VSync=0;CMAA=0}
    }
    $script:FakeFiles[$cfgName]=$cfg
    $script:FakeFiles[('profiles/'+$name+'.json')]='{}'
    $script:FakeFiles[('graphics/'+$name+'.json')]='{}'
}
function Invoke-RestMethod {
    [CmdletBinding()]
    param([string]$Uri,[string]$Method,[hashtable]$Headers,[int]$TimeoutSec,
        [int]$MaximumRedirection,[string]$ContentType,[string]$Body)
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
            sha=$script:FakeSha
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
    if($payload.sha -ne $script:FakeSha -or $payload.branch -ne 'main'){
        throw ('Missing GitHub SHA / incorrect target branch for '+$path)
    }
    $newText=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload.content))
    $script:FakeFiles[$path]=$newText
    [void]$script:FakeWrites.Add($path)
    return [pscustomobject]@{commit=[pscustomobject]@{sha='mock-commit'}}
}
# Test each profile uses its own matching cfg and JSON, never another player's.
foreach($name in @('FabMode','ArliMode','BrileMode','ArmlMode','OliMode')){
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
    Assert-True ($profile.CS2Sensitivity -eq '1.5') ($name+' JSON sensitivity differs.')
    $graphics=$script:FakeFiles[('graphics/'+$name+'.json')]|ConvertFrom-Json
    Assert-True ($graphics.ProfileName -eq $name -and $graphics.Settings.Width -eq 1280) ($name+' graphics preset differs.')
    Assert-True ($script:FakeCalls[-2] -eq ('Get:profiles/'+$name+'.json') -and $script:FakeCalls[-1] -eq ('Get:graphics/'+$name+'.json')) ($name+' did not read both saved JSON files back after upload.')
}
# Blank means "leave original CFG unchanged".
$script:GamingProfiles['FabMode'].CS2Sensitivity=''
$cfgBefore=$script:FakeFiles['fab.cfg']
$script:FakeWrites.Clear()
Sync-ProfileToGitHub -ProfileName 'FabMode' -Token ('testtoken-'+'x'*22)
Assert-True ($script:FakeWrites.Count -eq 1 -and $script:FakeWrites[0] -eq 'profiles/FabMode.json') 'Blank sensitivity should sync profile settings without editing the CFG or creating an unchanged graphics revision.'
Assert-True ($cfgBefore -ceq $script:FakeFiles['fab.cfg']) 'Blank sensitivity modified CFG.'
# Simulate graphics commit failure after CFG and profile commits.
$script:GamingProfiles['FabMode'].CS2Sensitivity='3.3'
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
Assert-True ($script:FakeFiles['profiles/FabMode.json'] -cne $beforeJson) 'Profile upload should be recorded before the simulated graphics failure.'
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
Write-Host 'PASS: 5 profile, graphics, and CFG syncs; authenticated profile/graphics read-back; mismatch rejection; safe sensitivity rewrite; blank override; retry; partial failure; path validation.'
