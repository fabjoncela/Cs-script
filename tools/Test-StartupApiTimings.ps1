# Validates the in-memory timing recorder without launching CafeLauncher or making network requests.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$batPath=Join-Path $repoRoot 'cafe.bat'
$lines=[IO.File]::ReadAllLines($batPath)
$marker=[Array]::IndexOf($lines,'# POWERSHELL_GUI')
if($marker -lt 0){throw 'CafeLauncher PowerShell marker was not found.'}
$source=[string]::Join([Environment]::NewLine,[string[]]$lines[($marker+1)..($lines.Length-1)])
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$parseErrors)
if(@($parseErrors).Count){throw ('CafeLauncher PowerShell parse failed: '+$parseErrors[0].Message)}
$traceMatch=[regex]::Match($source,"(?s)Add-Type -Language CSharp -TypeDefinition @'\r?\n(.*?)\r?\n'@")
if(-not $traceMatch.Success){throw 'The in-memory timing recorder definition was not found.'}
Add-Type -TypeDefinition ($traceMatch.Groups[1].Value+@'
public static class CafeTimingMockRequests {
    public static long ParallelElapsedMilliseconds { get; private set; }
    public static void Run(int index) {
        long id = CafeTimingTrace.Start("HTTP", "Mock parallel " + index, "https://private-user:private-password@example.test/api/items/76543210/76561198000000000?access_token=private-secret", "Later");
        System.Threading.Thread.Sleep(120);
        CafeTimingTrace.Complete(id, "Success", 200);
    }
    public static void RunParallel() {
        var clock = System.Diagnostics.Stopwatch.StartNew();
        var first = System.Threading.Tasks.Task.Factory.StartNew(delegate { Run(1); });
        var second = System.Threading.Tasks.Task.Factory.StartNew(delegate { Run(2); });
        System.Threading.Tasks.Task.WaitAll(first, second);
        clock.Stop();
        ParallelElapsedMilliseconds = clock.ElapsedMilliseconds;
    }
}
'@) -Language CSharp
$timingFunctions=@('Start-CafeTimingOperation','Complete-CafeTimingOperation','Get-CafeTimingDelegates','New-CafeLauncherUpdateWorker','Invoke-CafeTimedRequest')
foreach($functionName in $timingFunctions){
    $functionAst=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName},$true)
    if(-not $functionAst){throw ('Timing helper function is missing: '+$functionName)}
    . ([scriptblock]::Create($functionAst.Extent.Text))
}
$sentryFactory=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-CafeSentryLogWorker'},$true)
if(-not $sentryFactory){throw 'Sentry timing worker factory is missing.'}
. ([scriptblock]::Create($sentryFactory.Extent.Text))
$script:SentryDsn='https://public-key@example.test/1'
$script:LogPath=Join-Path $env:TEMP 'CafeLauncher-timing-test.log'
$script:LauncherRunningRelease='test'
$sentryWorker=New-CafeSentryLogWorker
$sentryWorker.Dispose()

[CafeTimingTrace]::MarkDashboardReady()
$startupId=[CafeTimingTrace]::Start('Local','Mock startup inventory','', 'Startup')
Start-Sleep -Milliseconds 30
[CafeTimingTrace]::Complete($startupId,'Success',0)
$script:mockRequestCalls=0
$mockSuccess=Invoke-CafeTimedRequest -Name 'Mock wrapped success' -Uri 'https://example.test/api/wrapped?key=secret' -Group Later -Request {
    $script:mockRequestCalls++
    Start-Sleep -Milliseconds 30
    [pscustomobject]@{StatusCode=201}
}
if([int]$mockSuccess.StatusCode -ne 201){throw 'The timed request wrapper changed a successful response.'}
$wrapperFailure=$false
try{
    Invoke-CafeTimedRequest -Name 'Mock wrapped failure' -Uri 'https://example.test/api/error?key=secret' -Group Later -Request {
        $script:mockRequestCalls++
        Start-Sleep -Milliseconds 20
        throw 'Mocked request failure'
    }|Out-Null
}catch{$wrapperFailure=$true}
if(-not $wrapperFailure -or $script:mockRequestCalls -ne 2){throw 'The timed wrapper must call each request once and preserve request failures.'}
[CafeTimingMockRequests]::RunParallel()
if([CafeTimingMockRequests]::ParallelElapsedMilliseconds -gt 220){throw 'Mock HTTP spans were not exercised concurrently.'}
$failedId=[CafeTimingTrace]::Start('HTTP','Mock failed request','https://example.test/api/fail?code=private-secret','Later')
[CafeTimingTrace]::Complete($failedId,'Failed',503)
[CafeTimingTrace]::MarkStartupComplete()

$entries=@([CafeTimingTrace]::Snapshot())
if($entries.Count -ne 6){throw ('Expected six mocked timing entries; found '+$entries.Count)}
if(@($entries|Where-Object {$_.Group -eq 'Startup'}).Count -ne 1 -or
   @($entries|Where-Object {$_.Group -eq 'Later'}).Count -ne 5){
    throw 'Startup and later timing entries were not separated.'
}
if($entries[0].ElapsedMs -lt 20){throw 'Elapsed time was not recorded for the local startup stage.'}
foreach($entry in @($entries|Where-Object {$_.Name -like 'Mock parallel *'})){
    if(-not $entry.IsComplete -or $entry.HttpStatus -ne 200 -or $entry.ElapsedMs -lt 100){
        throw 'A delayed parallel HTTP operation did not retain its end-to-end elapsed time and status.'
    }
    if($entry.HostPath -ne 'example.test/api/items/[id]/[id]' -or $entry.HostPath -match 'private-secret|access_token|private-user|private-password|76543210|76561198000000000'){
        throw 'The timing trace retained a query string, URI credential, or full account identifier.'
    }
}
$failed=$entries|Where-Object {$_.Id -eq $failedId}
if($failed.Outcome -ne 'Failed' -or $failed.HttpStatus -ne 503 -or $failed.HostPath -ne 'example.test/api/fail'){
    throw 'Failed HTTP operation status or query sanitization was not recorded.'
}
$wrappedSuccess=$entries|Where-Object {$_.Name -eq 'Mock wrapped success'}
$wrappedFailure=$entries|Where-Object {$_.Name -eq 'Mock wrapped failure'}
if($wrappedSuccess.Outcome -ne 'Success' -or $wrappedSuccess.HttpStatus -ne 201 -or
   $wrappedFailure.Outcome -ne 'Failed' -or $wrappedFailure.HostPath -ne 'example.test/api/error'){
    throw 'The timed request wrapper did not capture outcomes/status or strip query data.'
}
if($null -eq [CafeTimingTrace]::DashboardReadyMs -or
   [CafeTimingTrace]::StartupElapsedMs -lt 120 -or
   -not [CafeTimingTrace]::StartupIsComplete){
    throw 'Dashboard readiness or total startup timing is missing.'
}
$uiFunction=[regex]::Match($source,'(?s)function Show-CafeStartupApiTimings \{(.*?)\n\}')
if(-not $uiFunction.Success -or $uiFunction.Groups[1].Value -match 'Invoke-WebRequest|Invoke-RestMethod|WebRequest\.Create'){
    throw 'Opening or refreshing the timing dialog must not make a network request.'
}
if($source -notmatch 'New-Tile "Startup & API Timings" 19 \{ Show-CafeStartupApiTimings \}' -or
   $source -notmatch 'GitHub device sign-in request' -or
   $source -notmatch 'GitHub graphics history' -or
   $source -notmatch "Name 'PC diagnostics inventory' -Group Later" -or
   $source -notmatch "Name 'Automatic launcher update check dispatch' -Group Startup" -or
   $source -notmatch "Name 'Display and NVIDIA helper initialization' -Group Startup" -or
   $source -notmatch "Name 'Local profile settings load' -Group Startup" -or
   $source -notmatch "Name 'Dashboard construction' -Group Startup" -or
   $source -notmatch "Name 'Initial selected profile refresh' -Group Startup"){
    throw 'The timing button or required startup/API instrumentation is missing.'
}
$dashboardTimingNames=@(
    'Dashboard layout','Dashboard helper setup','Dashboard action tiles','Profile card creation',
    'Tools & Apps tiles','Manual DPI controls','LIVE LOGS controls','Dashboard finalization'
)
foreach($timingName in $dashboardTimingNames){
    if($source -notmatch [regex]::Escape("-Name '$timingName' -Group Startup")){
        throw ('Dashboard construction is missing a startup timing phase: '+$timingName)
    }
}
if($source -notmatch "Name 'Retained log load' -Group Later" -or
   $source -notmatch '\$logToggle\.Add_Click\(\{(?s:.*?)Initialize-LiveLogHistory'){
    throw 'Retained log hydration must run only on demand after the dashboard starts.'
}
if($source -notmatch 'Profile commit ''\+\$profileName' -or
   $source -notmatch 'Profile content ''\+\$profileName' -or
   $source -notmatch "Refresh-SelectedProfileCard -Name 'FabMode' -TimingGroup Startup"){
    throw 'Initial profile refresh requests must be named and grouped as startup work.'
}
$updateWorkerMatch=[regex]::Match($source,"(?s)public sealed class CafeLauncherUpdateBackgroundWorker : BackgroundWorker \{(.*?)\n\}")
if(-not $updateWorkerMatch.Success -or
   $updateWorkerMatch.Groups[1].Value -notmatch 'timingStart\("HTTP", "GitHub Get".*"Startup"\)' -or
   $updateWorkerMatch.Groups[1].Value -notmatch 'request\.Timeout = 8000' -or
   $source -match '\$summary\s*=\s*Get-PCDiagnostics\s*\r?\n\s*foreach.*Automatic startup inventory'){
    throw 'Automatic update checks must use a bounded background HTTP worker, and startup must not run PC diagnostics.'
}
$callerThread=[Threading.Thread]::CurrentThread.ManagedThreadId
$updateWorker=New-CafeLauncherUpdateWorker -Uri 'http://127.0.0.1:1/update-check-test'
$updateWorker.RunWorkerAsync()
$workerDeadline=[DateTime]::UtcNow.AddSeconds(5)
while($updateWorker.IsBusy -and [DateTime]::UtcNow -lt $workerDeadline){Start-Sleep -Milliseconds 20}
if($updateWorker.IsBusy -or $updateWorker.WorkerThreadId -eq $callerThread -or -not $updateWorker.ErrorText){
    throw 'The automatic update HTTP request must finish asynchronously on a worker thread and report connection failures.'
}
$updateHttpEntry=@([CafeTimingTrace]::Snapshot()|Where-Object {$_.Name -eq 'GitHub Get' -and $_.Group -eq 'Startup' -and $_.IsComplete})
if(-not $updateHttpEntry.Count -or $updateHttpEntry[-1].Outcome -ne 'Failed'){
    throw 'The background update worker failure was not captured as a completed startup HTTP span.'
}
$updateWorker.Dispose()
for($index=0;$index -lt 510;$index++){
    $id=[CafeTimingTrace]::Start('Local','Bounded trace fixture','', 'Later')
    [CafeTimingTrace]::Complete($id,'Success',0)
}
if(@([CafeTimingTrace]::Snapshot()).Count -ne 500){throw 'Timing trace retention must stay bounded to the latest 500 operations.'}
Write-Host 'Startup/API timing trace tests passed (mocked delays, failure, parallel calls, grouping, privacy, and no extra UI requests).'
