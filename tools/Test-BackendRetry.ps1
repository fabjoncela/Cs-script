# Isolated regression for pending backend writes. Network health and sync are mocked.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$lines=[IO.File]::ReadAllLines((Join-Path $root 'cafe.bat'))
$marker=[Array]::IndexOf($lines,'# POWERSHELL_GUI')
if($marker -lt 0){throw 'Launcher PowerShell marker not found.'}
$source=[string]::Join([Environment]::NewLine,[string[]]$lines[($marker+1)..($lines.Length-1)])
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw ('Launcher syntax failed: '+$errors[0].Message)}
$retryFunction=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-CafeBackendRetryHealthCheck'},$true))
if($retryFunction.Count -ne 1){throw 'Pending backend retry coordinator is missing or duplicated.'}
Invoke-Expression $retryFunction[0].Extent.Text

$script:GamingProfiles=[ordered]@{FabMode=@{ConfigFile='fab.cfg'}}
$script:PendingSync=@{FabMode=$true}
$script:PendingTarget=@{FabMode='Backend'}
$script:BackendRetryBlocked=@{}
$script:BackendRetryWorker=$null
$script:BackendSyncToken='mock-token-not-a-credential'
$script:BackendBaseUrl='https://backend.invalid'
$script:SelectedProfile='FabMode'
$script:MockHealthOk=$false
$script:MockSyncFailure=$false
$script:RetryAttempts=0
$script:RetryLogs=New-Object 'System.Collections.Generic.List[string]'
$script:Workers=New-Object 'System.Collections.Generic.List[object]'
$script:FakeQueuePath=Join-Path $env:TEMP ('CafeLauncher-BackendRetry-'+[Guid]::NewGuid().ToString('N')+'.json')
[IO.File]::WriteAllText($script:FakeQueuePath,'isolated pending bundle fixture')

function Get-CafeBackendQueuePath {param([string]$ProfileName)return $script:FakeQueuePath}
function New-CafeBackendHealthWorker {
    $worker=[pscustomobject]@{RequestContext=$null;Healthy=$false;IsBusy=$false;Callback=$null;Disposed=$false;Url=$null;TokenObserved=$null}
    Add-Member -InputObject $worker -MemberType ScriptMethod -Name Add_RunWorkerCompleted -Value {param($callback)$this.Callback=$callback} -Force
    Add-Member -InputObject $worker -MemberType ScriptMethod -Name RunWorkerAsync -Value {
        param($uri)
        $this.Url=[string]$uri
        $this.Healthy=[bool]$script:MockHealthOk
        if($this.RequestContext -is [System.Collections.IDictionary]){$this.TokenObserved=[string]$this.RequestContext['Token']}
        $callback=$this.Callback
        $eventArgs=[System.ComponentModel.RunWorkerCompletedEventArgs]::new($null,$null,$false)
        & $callback $this $eventArgs
    } -Force
    Add-Member -InputObject $worker -MemberType ScriptMethod -Name Dispose -Value {$this.Disposed=$true} -Force
    [void]$script:Workers.Add($worker)
    return $worker
}
function Sync-ProfileToBackend {
    param([string]$ProfileName,[string]$Token)
    $script:RetryAttempts++
    if($Token -cne 'mock-token-not-a-credential'){throw 'Retry did not use the in-memory session token.'}
    if($script:MockSyncFailure){throw 'mock transient write failure'}
    $script:PendingSync[$ProfileName]=$false
    return [pscustomobject]@{Canceled=$false;Revision=7}
}
function Write-Log {param([string]$Message,[string]$Level='INFO');[void]$script:RetryLogs.Add(($Level+': '+$Message))}
function Update-SelectedProfileCard {param([string]$Name)}

try{
    # Unhealthy backend: the queued local edit remains untouched and no sync is attempted.
    Start-CafeBackendRetryHealthCheck
    if($script:RetryAttempts -ne 0 -or -not $script:PendingSync['FabMode']){throw 'An unhealthy backend must leave the pending edit queued.'}
    if($script:Workers.Count -ne 1 -or $script:Workers[0].Url -cne 'https://backend.invalid/v1/health'){
        throw 'Retry must health-check the configured backend endpoint.'
    }
    if(-not $script:Workers[0].Disposed -or $script:Workers[0].RequestContext -ne $null -or $script:BackendRetryWorker -ne $null){
        throw 'Health-check completion must clear worker context and release the worker.'
    }

    # Healthy backend but a transient write error: keep pending and retry next interval.
    $script:MockHealthOk=$true
    $script:MockSyncFailure=$true
    Start-CafeBackendRetryHealthCheck
    if($script:RetryAttempts -ne 1 -or -not $script:PendingSync['FabMode'] -or $script:BackendRetryBlocked['FabMode']){
        throw 'A transient backend write failure must remain pending and retryable.'
    }
    if($script:Workers[1].TokenObserved -cne 'mock-token-not-a-credential' -or $script:Workers[1].RequestContext -ne $null){
        throw 'The session token must be passed in memory for the retry and cleared after completion.'
    }

    # A later successful health+sync clears the local pending state.
    $script:MockSyncFailure=$false
    Start-CafeBackendRetryHealthCheck
    if($script:RetryAttempts -ne 2 -or $script:PendingSync['FabMode'] -or $script:BackendRetryBlocked['FabMode']){
        throw 'A later successful backend retry must clear the pending state without blocking the profile.'
    }
    if(-not ($script:RetryLogs -join "`n" -match 'automatically synced to backend revision 7')){
        throw 'Successful retry must report the verified backend revision.'
    }
    Write-Host 'PASS: mocked outage preserves queued edits; transient write retries later with session auth; success clears pending state and worker context.'
}finally{Remove-Item -LiteralPath $script:FakeQueuePath -Force -ErrorAction SilentlyContinue}
