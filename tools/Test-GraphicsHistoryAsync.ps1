# Exercises the launcher's compiled background HTTP worker against a local
# connection-refused endpoint; no external network or game writes are used.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
$root=Split-Path -Parent $PSScriptRoot
$lines=[IO.File]::ReadAllLines((Join-Path $root 'cafe.bat'))
$marker=[Array]::IndexOf($lines,'# POWERSHELL_GUI')
if($marker -lt 0){throw 'Launcher PowerShell marker not found.'}
$source=[string]::Join([Environment]::NewLine,[string[]]$lines[($marker+1)..($lines.Length-1)])
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw ('Launcher syntax error: '+$errors[0].Message)}
$workerFunction=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-CafeGraphicsHistoryWorker'},$true)
if(-not $workerFunction){throw 'Compiled graphics history worker factory not found.'}
Invoke-Expression $workerFunction.Extent.Text
$uiThread=[Threading.Thread]::CurrentThread.ManagedThreadId
$worker=New-CafeGraphicsHistoryWorker
$worker.RunWorkerAsync('http://127.0.0.1:1/graphics-history-test')
$deadline=[DateTime]::UtcNow.AddSeconds(8)
while($worker.IsBusy -and [DateTime]::UtcNow -lt $deadline){
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 15
}
if($worker.IsBusy){throw 'Background HTTP worker did not complete within eight seconds.'}
if(-not $worker.ErrorText){throw 'Expected the local test endpoint to refuse the HTTP connection.'}
if($worker.WorkerThreadId -eq $uiThread){throw 'HTTP request ran on the UI thread instead of a worker thread.'}
$worker.Dispose()
Write-Host 'PASS: graphics-history HTTP request ran on a worker thread while the UI thread remained available.'
