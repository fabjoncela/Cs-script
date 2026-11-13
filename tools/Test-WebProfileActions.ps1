# Focused web profile-action checks with PC, backend, and Windows side effects stubbed.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = [IO.File]::ReadAllText((Join-Path $root 'cafe.bat'))
$marker = [regex]::Match($source, '(?m)^# POWERSHELL_GUI\r?\n')
if(-not $marker.Success){throw 'Missing embedded PowerShell marker.'}
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseInput($source.Substring($marker.Index+$marker.Length),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ('Launcher parse failed: '+$errors[0].Message)}
if($source -notmatch 'if\s*\(\s*\$profile\.LaunchApps\s*\)' -or
   $source -notmatch 'Launch-ProfileApps -SkipGHub -ProfileName \$ProfileName' -or
   $source -match 'Web Apply profile intentionally skipped Launch All'){
    throw 'Web and Windows Apply Profile must both honor LaunchApps and use the shared app-launch routine.'
}
$playStart=$source.IndexOf('function Invoke-CafeWebPlayExec {',[StringComparison]::Ordinal)
$playEnd=$source.IndexOf('if($env:CAFE_WEB_ACTION -ceq ''play-exec'')',$playStart,[StringComparison]::Ordinal)
if($playStart -lt 0 -or $playEnd -le $playStart){throw 'Could not isolate the Play + Exec web-action flow.'}
$playSource=$source.Substring($playStart,$playEnd-$playStart)
if($playSource -notmatch 'CAFE_WEB_PROFILE_REVISION' -or
   $playSource -notmatch 'Get-CafeBackendProfileHistoryRevision -ProfileName \$ProfileName -Revision \$revision' -or
   $playSource -match '\$latestResponse=Get-CafeHttpBytes'){
    throw 'Play + Exec must fetch the exact ticket-pinned profile bundle without a separate latest-revision request.'
}
$resultStages=@('Build final action result','Serialize final action result','Write final action result')
$stageOffsets=@($resultStages|ForEach-Object{$source.IndexOf("-Name '$_'",[StringComparison]::Ordinal)})
if(@($stageOffsets|Where-Object{$_ -lt 0}).Count -or $stageOffsets[0] -ge $stageOffsets[1] -or $stageOffsets[1] -ge $stageOffsets[2]){
    throw 'Web profile actions must report result construction, serialization, and result-file writing in order.'
}
foreach($name in @('Test-CafeWebPinnedActionTarget','New-CafeWebProfileActionEnvelope','Get-CafeWebPendingReason','Reset-CafeWebPendingEditsAfterRunnerUpdate','Complete-CafeWebRunnerProfileReset','Request-LogitechLiveDPI','Write-CafeWebProgress','Start-CafeWebProgressStage','Complete-CafeWebProgressStage','Invoke-CafeWebApplyProfile','Invoke-CafeWebApplyGraphics')){
    $definition=@($ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)|Where-Object{$_.Name -eq $name})
    if($definition.Count -ne 1){throw ('Expected one definition for '+$name)}
    Invoke-Expression $definition[0].Extent.Text
}

$script:TargetRoot=Join-Path $env:TEMP ('CafeLauncher-WebProfileTarget-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path (Join-Path $script:TargetRoot 'game\csgo\cfg') -Force
[IO.File]::WriteAllText((Join-Path $script:TargetRoot 'steam.exe'),'test fixture')

function Reset-ProfileActionTest {
    $script:GamingProfiles=[ordered]@{FabMode=@{};ArliMode=@{}}
    $script:PendingSync=@{FabMode=$false};$script:PendingTarget=@{FabMode='Backend'}
    $script:PendingSync['ArliMode']=$false;$script:PendingTarget['ArliMode']='Backend'
    $script:PendingCfgSensitivity=@{};$script:PendingProfileCfgRestore=@{}
    $script:CapturedCS2Convars=@{};$script:CapturedCS2Binds=@{}
    $script:StepResults=New-Object 'System.Collections.Generic.List[object]'
    $script:RunOutcomes=New-Object 'System.Collections.Generic.List[object]'
    $script:SnapshotCalls=0;$script:SnapshotRequestedRevisions=New-Object 'System.Collections.Generic.List[int]';$script:ApplyCalls=0;$script:SteamUser=76561198000000000L
    $script:SteamAvailable=$true;$script:Cs2Available=$true;$script:ThrowSnapshot=$false
    $script:SteamPath=Join-Path $script:TargetRoot 'steam.exe';$script:CfgPath=Join-Path $script:TargetRoot 'game\csgo\cfg'
    $script:QueueClearCalls=0;$script:SaveSettingsCalls=0;$script:ResetMarkerCompleteCalls=0;$script:SnapshotImportCalls=0
    $script:CafeWebProgressSequence=0;$script:CafeWebProgressTimers=@{};$script:CafeWebCurrentProgressStage=$null
    $env:CAFE_WEB_RUNNER_UPDATED=''
    $env:CAFE_WEB_PROFILE_REVISION='3'
}
function Get-CafeBackendQueuePath { return (Join-Path $env:TEMP 'CafeLauncher-profile-action-test-absent.json') }
function Clear-CafeBackendQueue { param([string]$ProfileName);$script:QueueClearCalls++ }
function Save-ProfileSettings { $script:SaveSettingsCalls++ }
function Complete-CafeWebRunnerProfileReset { $script:ResetMarkerCompleteCalls++ }
function Assert-LogitechDPI { param([int]$DPI) }
function Ensure-LogihubWebExecutable { $script:LogihubEnsureCalls++;return 'verified-helper.exe' }
function Set-LogitechLiveDPI { param([int]$DPI,[switch]$WebAction);$script:LiveDpiCalls++;$script:WebLiveDpiSwitch=[bool]$WebAction }
function Get-CafeWebActionSnapshot {
    param([string]$ProfileName,[int]$Revision=0,[switch]$NoCache)
    $script:SnapshotCalls++
    $script:SnapshotRequestedRevisions.Add($Revision)
    if($script:ThrowSnapshot -and $script:SnapshotCalls -ge 2){throw 'Simulated backend failure.'}
    return [pscustomobject]@{Source='Backend';Revision=$(if($Revision){$Revision}else{3});Graphics=[pscustomobject]@{ScalingMode=2}}
}
function Get-CafeVerifiedGraphicsModulePath { return 'verified-graphics.ps1' }
function Invoke-CafeGraphicsPresetCore {
    param([string]$ModeName,$Preset,[switch]$WebAction,[string]$ModulePath='')
    $script:GraphicsPresetRevision=$script:SnapshotRequestedRevisions[$script:SnapshotRequestedRevisions.Count-1]
    return [pscustomobject]@{state='COMPLETED';summary='Graphics settings verified.';steps=@([ordered]@{name='Video settings';status='SUCCESS';detail='Verified.'});data=[pscustomobject]@{executionOutcomeKnown=$true}}
}
function Set-CafeWebActionSnapshot { param([string]$ProfileName,$Snapshot,[switch]$NoSave);$script:SnapshotImportCalls++ }
function Get-PCDiagnostics {
    [pscustomobject]@{
        Steam=[pscustomobject]@{ActiveSessionPresent=$script:SteamAvailable;Executable=$script:SteamPath}
        CS2=[pscustomobject]@{Status=$(if($script:Cs2Available){'DETECTED'}else{'NOT_UNIQUELY_DETECTED'});ConfigPath=$(if($script:Cs2Available){$script:CfgPath}else{$null})}
    }
}
function Get-CafeWebActiveSteamUserId { return $script:SteamUser }
function Invoke-GamingProfile {
    param([string]$ProfileName,[switch]$WebAction,$WebSnapshot,[long]$WebSteamUserId,[string]$WebCfgDirectory,[string]$WebSteamPath)
    $script:ApplyCalls++
    $script:StepResults.Add([pscustomobject]@{Run=$ProfileName;Step='Windows mouse settings';Status='SUCCESS';Detail='Read-back verified.'})
    $script:RunOutcomes.Add([pscustomobject]@{Run=$ProfileName;Setting='Logitech live DPI';Status='APPLIED';Detail='Synchronous read-back verified.';Actual='800';Requested='800';Target='mouse'})
}
function Set-StepResult { param($Run,$Step,$Status,$Detail);$script:StepResults.Add([pscustomobject]@{Run=$Run;Step=$Step;Status=$Status;Detail=$Detail}) }
function Set-RunOutcome { param($Run,$Setting,$Status,$Detail,$Actual,$Requested,$Target);$script:RunOutcomes.Add([pscustomobject]@{Run=$Run;Setting=$Setting;Status=$Status;Detail=$Detail;Actual=$Actual;Requested=$Requested;Target=$Target}) }
function Write-Log { param($Message,$Level) }

Reset-ProfileActionTest
if(-not (Test-CafeWebPinnedActionTarget -SteamUserId $script:SteamUser -SteamPath $script:SteamPath -CfgDirectory $script:CfgPath)){throw 'The focused Steam/CS2 target check rejected its pinned fixture.'}
if(Test-CafeWebPinnedActionTarget -SteamUserId ($script:SteamUser+1) -SteamPath $script:SteamPath -CfgDirectory $script:CfgPath){throw 'The focused target check accepted a different Steam account.'}
if(Test-CafeWebPinnedActionTarget -SteamUserId $script:SteamUser -SteamPath $script:SteamPath -CfgDirectory ($script:CfgPath+'\missing')){throw 'The focused target check accepted a missing config path.'}

Reset-ProfileActionTest
$script:LogihubEnsureCalls=0;$script:LiveDpiCalls=0;$script:WebLiveDpiSwitch=$false
Request-LogitechLiveDPI -DPI 800 -WebAction
if($script:LogihubEnsureCalls -ne 1 -or $script:LiveDpiCalls -ne 1 -or -not $script:WebLiveDpiSwitch){
    throw 'The web Logitech path did not synchronously ensure the pinned helper and invoke live DPI with web-mode verification.'
}

Reset-ProfileActionTest
$result=Invoke-CafeWebApplyProfile -ProfileName FabMode
if($result.state -cne 'COMPLETED' -or -not $result.result.data.executionOutcomeKnown -or $script:ApplyCalls -ne 1 -or
   $script:SnapshotRequestedRevisions.Count -ne 1 -or $script:SnapshotRequestedRevisions[0] -ne 3){throw 'Normal web profile apply did not use the backend-pinned immutable revision.'}
if(@($result.result.steps|Where-Object{$_.name -eq 'Logitech live DPI' -and $_.status -eq 'SUCCESS'}).Count -ne 1){throw 'Verified synchronous Logitech live DPI was not reported as applied.'}

Reset-ProfileActionTest
$result=Invoke-CafeWebApplyGraphics -ProfileName FabMode
if($result.state -cne 'COMPLETED' -or $script:SnapshotRequestedRevisions.Count -ne 1 -or
   $script:SnapshotRequestedRevisions[0] -ne 3 -or $script:GraphicsPresetRevision -ne 3){
    throw 'Web graphics apply did not use the exact backend-pinned profile and graphics revision.'
}

Reset-ProfileActionTest
$script:PendingSync['FabMode']=$true
$result=Invoke-CafeWebApplyProfile -ProfileName FabMode
if($result.state -cne 'SKIPPED' -or $script:SnapshotCalls -ne 0 -or $script:ApplyCalls -ne 0){throw 'Pending local profile changes did not fail closed before action.'}

Reset-ProfileActionTest
$script:PendingSync['FabMode']=$true
$script:PendingSync['ArliMode']=$true
$env:CAFE_WEB_RUNNER_UPDATED='1'
$result=Invoke-CafeWebApplyProfile -ProfileName FabMode
if($result.state -cne 'COMPLETED' -or $script:SnapshotCalls -ne 2 -or $script:QueueClearCalls -ne 2 -or
   $script:SnapshotImportCalls -ne 2 -or $script:SaveSettingsCalls -ne 1 -or $script:ResetMarkerCompleteCalls -ne 1 -or $script:PendingSync['FabMode'] -or $script:PendingSync['ArliMode'] -or $script:ApplyCalls -ne 1){
    throw 'After runner update, all pending local profiles were not reset to verified backend revisions before applying.'
}

Reset-ProfileActionTest
$env:CAFE_WEB_RUNNER_UPDATED='1'
$result=Invoke-CafeWebApplyProfile -ProfileName FabMode
if($result.state -cne 'COMPLETED' -or $script:SnapshotCalls -ne 1 -or $script:ResetMarkerCompleteCalls -ne 1 -or $script:SaveSettingsCalls -ne 0){
    throw 'The one-time update marker was not consumed when there were no local edits to discard.'
}

Reset-ProfileActionTest
$script:SteamAvailable=$false
$result=Invoke-CafeWebApplyProfile -ProfileName FabMode
if($result.state -cne 'SKIPPED' -or $script:ApplyCalls -ne 0){throw 'Missing Steam session did not stop web profile apply before changes.'}

Reset-ProfileActionTest
$script:ThrowSnapshot=$true
$script:PendingSync['FabMode']=$true
$script:PendingSync['ArliMode']=$true
$env:CAFE_WEB_RUNNER_UPDATED='1'
$result=Invoke-CafeWebApplyProfile -ProfileName FabMode
if($result.state -cne 'FAILED' -or -not $result.result.data.executionOutcomeKnown -or $script:ApplyCalls -ne 0 -or
   $script:SnapshotCalls -ne 2 -or $script:SnapshotImportCalls -ne 0 -or $script:PendingSync['FabMode'] -ne $true -or $script:PendingSync['ArliMode'] -ne $true){
    throw 'Backend outage did not preserve every local edit before profile changes.'
}

Reset-ProfileActionTest
$script:PendingSync['FabMode']=$true
$result=Invoke-CafeWebApplyGraphics -ProfileName FabMode
if($result.state -cne 'SKIPPED' -or $script:SnapshotCalls -ne 0){throw 'Pending local edits did not stop web graphics before helper execution.'}

$progressTestDirectory=Join-Path $env:TEMP ('CafeLauncher-WebProgressTest-'+[guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Path $progressTestDirectory | Out-Null
    $env:CAFE_WEB_PROGRESS_DIR=$progressTestDirectory
    $script:CafeWebProgressSequence=0;$script:CafeWebProgressTimers=@{};$script:CafeWebCurrentProgressStage=$null
    Start-CafeWebProgressStage -Name 'Test local step' -Detail 'A mock action stage started.'
    Start-Sleep -Milliseconds 25
    Complete-CafeWebProgressStage -Name 'Test local step' -Status 'SUCCESS' -Detail 'Mock action stage finished.'
    $progressFiles=@(Get-ChildItem -LiteralPath $progressTestDirectory -Filter 'progress-*.json' | Sort-Object Name)
    if($progressFiles.Count -ne 2){throw 'The web action did not write a start and finish progress event.'}
    $started=Get-Content -LiteralPath $progressFiles[0].FullName -Raw|ConvertFrom-Json
    $finished=Get-Content -LiteralPath $progressFiles[1].FullName -Raw|ConvertFrom-Json
    if($started.status -cne 'RUNNING' -or $finished.status -cne 'SUCCESS' -or $finished.detail -notmatch 'Elapsed: [0-9.]+ seconds'){
        throw 'The web progress events did not include the stage result and elapsed time.'
    }
}finally{
    $env:CAFE_WEB_PROGRESS_DIR=''
    if(Test-Path -LiteralPath $progressTestDirectory){Remove-Item -LiteralPath $progressTestDirectory -Recurse -Force}
}

'Web profile action checks passed: result mapping, timed progress, pending-edit and Steam gates, pinned-target recheck, and graphics block.'
Remove-Item -LiteralPath $script:TargetRoot -Recurse -Force
