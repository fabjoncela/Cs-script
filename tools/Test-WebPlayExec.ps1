# Unit-style web Play + Exec checks. All machine, network, filesystem, and
# process interactions are stubbed so this cannot change a real CS2 install.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$launcherPath = Join-Path $repoRoot 'cafe.bat'
$launcher = [IO.File]::ReadAllText($launcherPath)
$marker = '# POWERSHELL_GUI'+"`r`n"
$markerIndex = $launcher.IndexOf($marker,[StringComparison]::Ordinal)
if($markerIndex -lt 0){throw 'Missing launcher PowerShell marker.'}
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($launcher.Substring($markerIndex+$marker.Length),[ref]$tokens,[ref]$parseErrors)
if(@($parseErrors).Count){throw ('Launcher PowerShell failed to parse: '+$parseErrors[0].Message)}

foreach($name in @('New-CafeWebPlayExecEnvelope','Reset-CafeWebPendingEditsAfterRunnerUpdate','Invoke-CafeWebPlayExec')){
    $definitions=@($ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true) |
        Where-Object {$_.Name -eq $name})
    if($definitions.Count -ne 1){throw ('Expected exactly one function definition: '+$name)}
    Invoke-Expression $definitions[0].Extent.Text
}

function Reset-WebPlayTestState {
    $script:TestProfileName='FabMode'
    $script:TestSteamPath='C:\CafeTest\Steam\steam.exe'
    $script:TestCfgPath='C:\CafeTest\SteamLibrary\steamapps\common\Counter-Strike Global Offensive\game\csgo\cfg'
    $script:TestRevision=7
    $script:TestRevisionFloor=7
    $script:TestRollbackApproved=$true
    $script:TestPending=$false
    $script:TestSteamActive=$true
    $script:TestCs2Detected=$true
    $script:TestCs2Running=$false
    $script:TestBackendUnavailable=$false
    $script:TestProfileInstallResult=$true
    $script:TestBaselineInstallResult=$true
    $script:TestLaunchThrows=$false
    $script:TestPathChanges=$false
    $script:TestDiagnosticsCalls=0
    $script:TestSteamUserCalls=0
    $script:TestSteamUserIds=@(76561198000000000L,76561198000000000L,76561198000000000L)
    $script:TestInstallTargets=New-Object 'System.Collections.Generic.List[string]'
    $script:TestInstalledCfgs=New-Object 'System.Collections.Generic.List[string]'
    $script:TestLaunchArguments=New-Object 'System.Collections.Generic.List[object]'
    $script:TestSaveCount=0
    $script:TestHistoryRevision=0
    $script:ResetProfileStateCalls=0
    $env:CAFE_WEB_RUNNER_UPDATED=''
    $script:BackendBaseUrl='https://cafelauncher.example'
    $script:FabCfgCloudUrl='https://cafelauncher.example/v1/cfg/fab.cfg'
    $script:GamingProfiles=[ordered]@{FabMode=@{ConfigFile='fab.cfg';CfgDownloadUrl=$script:FabCfgCloudUrl}}
    $script:PendingSync=@{FabMode=$script:TestPending}
    $script:PendingTarget=@{FabMode='Backend'}
    $script:PendingCfgSensitivity=@{}
    $script:PendingProfileCfgRestore=@{}
    $script:CapturedCS2Convars=@{}
    $script:CapturedCS2Binds=@{}
    $script:GraphicsPresets=@{}
    $script:BackendRevisions=@{FabMode=$script:TestRevisionFloor}
    $script:BackendRevisionRollbackApprovals=@{}
    $script:BackendSnapshots=@{}
    $script:ProfileRefreshStatus=@{}
}

function Get-CafeBackendQueuePath { return (Join-Path $env:TEMP 'CafeLauncher-web-play-test-no-queue.json') }
function Reset-CafeWebPendingEditsAfterRunnerUpdate { param([string]$ProfileName);$script:ResetProfileStateCalls++;return $null }
function Get-PCDiagnostics {
    [CmdletBinding()]
    param([switch]$AsObject)
    $script:TestDiagnosticsCalls++
    [pscustomobject]@{
        Steam=[pscustomobject]@{Executable=$script:TestSteamPath;ActiveSessionPresent=$script:TestSteamActive;Status=$(if($script:TestSteamActive){'DETECTED'}else{'NOT_DETECTED'})}
        CS2=[pscustomobject]@{
            Status=$(if($script:TestCs2Detected){'DETECTED'}else{'NOT_UNIQUELY_DETECTED'})
            ConfigPath=$(if($script:TestPathChanges -and $script:TestDiagnosticsCalls -ge 2){$script:TestCfgPath+'-changed'}else{$script:TestCfgPath})
        }
    }
}
function Get-CafeWebActiveSteamUserId {
    $index=[Math]::Min($script:TestSteamUserCalls,$script:TestSteamUserIds.Count-1)
    $script:TestSteamUserCalls++
    return $script:TestSteamUserIds[$index]
}
function Get-CafeHttpBytes {
    [CmdletBinding()]
    param([string]$Uri,[int]$MaxBytes=2097152)
    if($script:TestBackendUnavailable){throw 'Simulated backend outage.'}
    [pscustomobject]@{Headers=@{'X-Profile-Revision'=[string]$script:TestRevision};Bytes=[byte[]]@()}
}
function Get-CafeBackendProfileHistoryRevision {
    [CmdletBinding()]
    param([string]$ProfileName,[int]$Revision)
    $script:TestHistoryRevision=$Revision
    [pscustomobject]@{
        Source='Backend'
        Revision=$Revision
        Profile=[pscustomobject]@{ProfileName=$ProfileName;CfgDownloadUrl=('/v1/cfg/'+$script:GamingProfiles[$ProfileName].ConfigFile)}
        Graphics=[pscustomobject]@{ScalingMode=2}
    }
}
function Confirm-CafeBackendRevisionRollback { return $script:TestRollbackApproved }
function Import-ProfileValues { param([string]$ProfileName,$SavedProfile,[string]$SourceLabel); return $true }
function Save-ProfileSettings { $script:TestSaveCount++ }
function Set-CafeCloudReadSourceDisplay { param([string]$Source) }
function Write-Log { param([string]$Message,[string]$Level='INFO') }
function Get-SteamExecutable { return $script:TestSteamPath }
function Get-CS2SteamLaunchArguments { param([string]$CfgName); return @('+exec cafelauncher_profile_baseline.cfg','+exec '+$CfgName) }
function Get-Process {
    [CmdletBinding()]
    param([string]$Name)
    if($Name -eq 'cs2' -and $script:TestCs2Running){return @([pscustomobject]@{ProcessName='cs2';Id=42})}
    return @()
}
function Install-CS2ProfileBaselineCfg {
    param([string]$CfgDirectory='')
    $script:TestInstallTargets.Add($CfgDirectory)
    return $script:TestBaselineInstallResult
}
function Install-ProfileCfg {
    [CmdletBinding()]
    param([switch]$Silent,[string]$CfgName,[string]$DownloadUrl,[switch]$CloudPreferred,$CloudSnapshot,[switch]$UseSnapshotOnly,[string]$CfgDirectory='')
    $script:TestInstallTargets.Add($CfgDirectory)
    $script:TestInstalledCfgs.Add($CfgName)
    return $script:TestProfileInstallResult
}
function Start-Process {
    [CmdletBinding()]
    param([string]$FilePath,[string[]]$ArgumentList)
    if($script:TestLaunchThrows){throw 'Simulated Steam launch failure.'}
    $script:TestLaunchArguments.Add(@($FilePath)+@($ArgumentList))
}

function Assert-WebPlayResult {
    param($Result,[string]$State,[bool]$Known)
    if($Result.state -cne $State){throw "Expected web Play + Exec state $State; received $($Result.state)."}
    if([bool]$Result.result.data.executionOutcomeKnown -ne $Known){throw 'Web Play + Exec outcome certainty did not match the expected state.'}
}

Reset-WebPlayTestState
$success=Invoke-CafeWebPlayExec -ProfileName 'FabMode'
Assert-WebPlayResult $success 'COMPLETED' $true
if($script:ResetProfileStateCalls -ne 1){throw 'Play + Exec did not check the one-time runner update profile reset state.'}
if(-not $success.result.data.steamLaunchRequested -or $script:TestLaunchArguments.Count -ne 1){throw 'Successful Play + Exec did not request exactly one Steam launch.'}
if($script:TestHistoryRevision -ne 7 -or $script:TestInstallTargets.Count -ne 2 -or
   $script:TestInstallTargets[0] -cne $script:TestCfgPath -or $script:TestInstallTargets[1] -cne $script:TestCfgPath){
    throw 'Play + Exec did not use the single current revision and one pinned CFG target.'
}

Reset-WebPlayTestState
$script:TestCs2Running=$true
$alreadyRunning=Invoke-CafeWebPlayExec -ProfileName 'FabMode'
Assert-WebPlayResult $alreadyRunning 'PARTIAL' $true
if($alreadyRunning.result.data.steamLaunchRequested -or $script:TestLaunchArguments.Count -ne 0 -or
   ($alreadyRunning.result.data.consoleCommands -join '|') -cne 'exec cafelauncher_profile_baseline.cfg|exec fab.cfg'){
    throw 'The already-running CS2 result did not preserve the no-relaunch/console-command behavior.'
}

Reset-WebPlayTestState
$script:PendingSync['FabMode']=$true
$pending=Invoke-CafeWebPlayExec -ProfileName 'FabMode'
Assert-WebPlayResult $pending 'SKIPPED' $true
if($script:TestInstallTargets.Count -ne 0 -or $script:TestLaunchArguments.Count -ne 0){throw 'Pending local edits must stop before CFG or Steam changes.'}

Reset-WebPlayTestState
$script:TestRevision=6
$script:TestRevisionFloor=7
$script:TestRollbackApproved=$false
$rollback=Invoke-CafeWebPlayExec -ProfileName 'FabMode'
Assert-WebPlayResult $rollback 'SKIPPED' $true
if($script:TestInstallTargets.Count -ne 0 -or $script:TestLaunchArguments.Count -ne 0){throw 'A backend rollback must stop before CFG or Steam changes.'}

Reset-WebPlayTestState
$script:TestPathChanges=$true
$changedPath=Invoke-CafeWebPlayExec -ProfileName 'FabMode'
Assert-WebPlayResult $changedPath 'SKIPPED' $true
if($script:TestInstallTargets.Count -ne 0 -or $script:TestLaunchArguments.Count -ne 0){throw 'A changed CS2 path must stop before writing a CFG.'}

Reset-WebPlayTestState
$script:TestSteamActive=$false
$noSteam=Invoke-CafeWebPlayExec -ProfileName 'FabMode'
Assert-WebPlayResult $noSteam 'SKIPPED' $true
if($script:TestInstallTargets.Count -ne 0 -or $script:TestLaunchArguments.Count -ne 0){throw 'A missing active Steam session must stop before CFG or Steam changes.'}

Reset-WebPlayTestState
$script:TestCs2Detected=$false
$noCs2=Invoke-CafeWebPlayExec -ProfileName 'FabMode'
Assert-WebPlayResult $noCs2 'SKIPPED' $true
if($script:TestInstallTargets.Count -ne 0 -or $script:TestLaunchArguments.Count -ne 0){throw 'An unvalidated CS2 path must stop before CFG or Steam changes.'}

Reset-WebPlayTestState
$script:TestSteamUserIds=@(76561198000000000L,76561198000000001L,76561198000000001L)
$changedAccount=Invoke-CafeWebPlayExec -ProfileName 'FabMode'
Assert-WebPlayResult $changedAccount 'SKIPPED' $true
if($script:TestInstallTargets.Count -ne 0 -or $script:TestLaunchArguments.Count -ne 0){throw 'A changed Steam account must stop before CFG or Steam changes.'}

Reset-WebPlayTestState
$script:TestBackendUnavailable=$true
$backendFailure=Invoke-CafeWebPlayExec -ProfileName 'FabMode'
Assert-WebPlayResult $backendFailure 'FAILED' $true
if($script:TestInstallTargets.Count -ne 0 -or $script:TestLaunchArguments.Count -ne 0){throw 'An unavailable primary backend must stop before CFG or Steam changes.'}

Reset-WebPlayTestState
$script:TestProfileInstallResult=$false
$uncertainCfg=Invoke-CafeWebPlayExec -ProfileName 'FabMode'
Assert-WebPlayResult $uncertainCfg 'INTERRUPTED' $false
if($script:TestLaunchArguments.Count -ne 0){throw 'A failed profile CFG install must not start Steam.'}

Reset-WebPlayTestState
$script:TestLaunchThrows=$true
$uncertainLaunch=Invoke-CafeWebPlayExec -ProfileName 'FabMode'
Assert-WebPlayResult $uncertainLaunch 'INTERRUPTED' $false

Write-Output 'Web Play + Exec checks passed: verified revision and pinned CFG target; Steam/CS2/account gates; pending edits; rollback; already-running CS2; backend outage; and uncertain CFG/launch outcomes.'
