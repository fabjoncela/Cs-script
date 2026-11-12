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
foreach($name in @('New-CafeWebProfileActionEnvelope','Get-CafeWebPendingReason','Invoke-CafeWebApplyProfile','Invoke-CafeWebApplyGraphics')){
    $definition=@($ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)|Where-Object{$_.Name -eq $name})
    if($definition.Count -ne 1){throw ('Expected one definition for '+$name)}
    Invoke-Expression $definition[0].Extent.Text
}

function Reset-ProfileActionTest {
    $script:PendingSync=@{FabMode=$false};$script:PendingTarget=@{FabMode='Backend'}
    $script:PendingCfgSensitivity=@{};$script:PendingProfileCfgRestore=@{}
    $script:CapturedCS2Convars=@{};$script:CapturedCS2Binds=@{}
    $script:StepResults=New-Object 'System.Collections.Generic.List[object]'
    $script:RunOutcomes=New-Object 'System.Collections.Generic.List[object]'
    $script:SnapshotCalls=0;$script:ApplyCalls=0;$script:SteamUser=76561198000000000L
    $script:SteamAvailable=$true;$script:Cs2Available=$true;$script:ThrowSnapshot=$false
}
function Get-CafeBackendQueuePath { return (Join-Path $env:TEMP 'CafeLauncher-profile-action-test-absent.json') }
function Get-CafeWebActionSnapshot {
    param([string]$ProfileName)
    $script:SnapshotCalls++
    if($script:ThrowSnapshot){throw 'Simulated backend failure.'}
    return [pscustomobject]@{Source='Backend';Revision=3;Graphics=[pscustomobject]@{ScalingMode=2}}
}
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
    $script:RunOutcomes.Add([pscustomobject]@{Run=$ProfileName;Setting='Logitech live DPI';Status='SKIPPED';Detail='Async helper omitted.';Actual='';Requested='800';Target='mouse'})
}
function Set-StepResult { param($Run,$Step,$Status,$Detail);$script:StepResults.Add([pscustomobject]@{Run=$Run;Step=$Step;Status=$Status;Detail=$Detail}) }
function Set-RunOutcome { param($Run,$Setting,$Status,$Detail,$Actual,$Requested,$Target);$script:RunOutcomes.Add([pscustomobject]@{Run=$Run;Setting=$Setting;Status=$Status;Detail=$Detail;Actual=$Actual;Requested=$Requested;Target=$Target}) }
function Write-Log { param($Message,$Level) }

Reset-ProfileActionTest
$result=Invoke-CafeWebApplyProfile -ProfileName FabMode
if($result.state -cne 'PARTIAL' -or -not $result.result.data.executionOutcomeKnown -or $script:ApplyCalls -ne 1){throw 'Normal web profile apply did not report its verified/skipped steps.'}
if(@($result.result.steps|Where-Object{$_.name -eq 'Logitech live DPI' -and $_.status -eq 'SKIPPED'}).Count -ne 1){throw 'The intentionally deferred asynchronous DPI helper was not reported as skipped.'}

Reset-ProfileActionTest
$script:PendingSync['FabMode']=$true
$result=Invoke-CafeWebApplyProfile -ProfileName FabMode
if($result.state -cne 'SKIPPED' -or $script:SnapshotCalls -ne 0 -or $script:ApplyCalls -ne 0){throw 'Pending local profile changes did not fail closed before action.'}

Reset-ProfileActionTest
$script:SteamAvailable=$false
$result=Invoke-CafeWebApplyProfile -ProfileName FabMode
if($result.state -cne 'SKIPPED' -or $script:ApplyCalls -ne 0){throw 'Missing Steam session did not stop web profile apply before changes.'}

Reset-ProfileActionTest
$script:ThrowSnapshot=$true
$result=Invoke-CafeWebApplyProfile -ProfileName FabMode
if($result.state -cne 'FAILED' -or -not $result.result.data.executionOutcomeKnown -or $script:ApplyCalls -ne 0){throw 'Backend outage did not fail closed before profile changes.'}

Reset-ProfileActionTest
$script:PendingSync['FabMode']=$true
$result=Invoke-CafeWebApplyGraphics -ProfileName FabMode
if($result.state -cne 'SKIPPED' -or $script:SnapshotCalls -ne 0){throw 'Pending local edits did not stop web graphics before helper execution.'}

'Web profile action checks passed: verified result mapping, pending-edit block, Steam preflight, backend outage, and graphics pending-edit block.'
