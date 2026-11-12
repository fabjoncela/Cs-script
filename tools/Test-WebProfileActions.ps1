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
foreach($name in @('New-CafeWebProfileActionEnvelope','Get-CafeWebPendingReason','Reset-CafeWebPendingEditsAfterRunnerUpdate','Complete-CafeWebRunnerProfileReset','Request-LogitechLiveDPI','Invoke-CafeWebApplyProfile','Invoke-CafeWebApplyGraphics')){
    $definition=@($ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)|Where-Object{$_.Name -eq $name})
    if($definition.Count -ne 1){throw ('Expected one definition for '+$name)}
    Invoke-Expression $definition[0].Extent.Text
}

function Reset-ProfileActionTest {
    $script:GamingProfiles=[ordered]@{FabMode=@{};ArliMode=@{}}
    $script:PendingSync=@{FabMode=$false};$script:PendingTarget=@{FabMode='Backend'}
    $script:PendingSync['ArliMode']=$false;$script:PendingTarget['ArliMode']='Backend'
    $script:PendingCfgSensitivity=@{};$script:PendingProfileCfgRestore=@{}
    $script:CapturedCS2Convars=@{};$script:CapturedCS2Binds=@{}
    $script:StepResults=New-Object 'System.Collections.Generic.List[object]'
    $script:RunOutcomes=New-Object 'System.Collections.Generic.List[object]'
    $script:SnapshotCalls=0;$script:ApplyCalls=0;$script:SteamUser=76561198000000000L
    $script:SteamAvailable=$true;$script:Cs2Available=$true;$script:ThrowSnapshot=$false
    $script:QueueClearCalls=0;$script:SaveSettingsCalls=0;$script:ResetMarkerCompleteCalls=0;$script:SnapshotImportCalls=0
    $env:CAFE_WEB_RUNNER_UPDATED=''
}
function Get-CafeBackendQueuePath { return (Join-Path $env:TEMP 'CafeLauncher-profile-action-test-absent.json') }
function Clear-CafeBackendQueue { param([string]$ProfileName);$script:QueueClearCalls++ }
function Save-ProfileSettings { $script:SaveSettingsCalls++ }
function Complete-CafeWebRunnerProfileReset { $script:ResetMarkerCompleteCalls++ }
function Assert-LogitechDPI { param([int]$DPI) }
function Ensure-LogihubWebExecutable { $script:LogihubEnsureCalls++;return 'verified-helper.exe' }
function Set-LogitechLiveDPI { param([int]$DPI,[switch]$WebAction);$script:LiveDpiCalls++;$script:WebLiveDpiSwitch=[bool]$WebAction }
function Get-CafeWebActionSnapshot {
    param([string]$ProfileName,[switch]$NoCache)
    $script:SnapshotCalls++
    if($script:ThrowSnapshot -and $script:SnapshotCalls -ge 2){throw 'Simulated backend failure.'}
    return [pscustomobject]@{Source='Backend';Revision=3;Graphics=[pscustomobject]@{ScalingMode=2}}
}
function Set-CafeWebActionSnapshot { param([string]$ProfileName,$Snapshot,[switch]$NoSave);$script:SnapshotImportCalls++ }
function Get-PCDiagnostics {
    [pscustomobject]@{
        Steam=[pscustomobject]@{ActiveSessionPresent=$script:SteamAvailable;Executable='C:\Cafe\Steam.exe'}
        CS2=[pscustomobject]@{Status=$(if($script:Cs2Available){'DETECTED'}else{'NOT_UNIQUELY_DETECTED'});ConfigPath=$(if($script:Cs2Available){'C:\Cafe\CS2\cfg'}else{$null})}
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
$script:LogihubEnsureCalls=0;$script:LiveDpiCalls=0;$script:WebLiveDpiSwitch=$false
Request-LogitechLiveDPI -DPI 800 -WebAction
if($script:LogihubEnsureCalls -ne 1 -or $script:LiveDpiCalls -ne 1 -or -not $script:WebLiveDpiSwitch){
    throw 'The web Logitech path did not synchronously ensure the pinned helper and invoke live DPI with web-mode verification.'
}

Reset-ProfileActionTest
$result=Invoke-CafeWebApplyProfile -ProfileName FabMode
if($result.state -cne 'COMPLETED' -or -not $result.result.data.executionOutcomeKnown -or $script:ApplyCalls -ne 1){throw 'Normal web profile apply did not report its verified steps.'}
if(@($result.result.steps|Where-Object{$_.name -eq 'Logitech live DPI' -and $_.status -eq 'SUCCESS'}).Count -ne 1){throw 'Verified synchronous Logitech live DPI was not reported as applied.'}

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

'Web profile action checks passed: synchronous Logitech web path, verified result mapping, one-time profile reset marker, pending-edit block, Steam preflight, backend outage, and graphics pending-edit block.'
