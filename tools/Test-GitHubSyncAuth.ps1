# GitHub sync authentication contract and worker compile test.
# No network request, GUI, credential, or repository write is performed.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$launcherPath=Join-Path $repoRoot 'cafe.bat'
$source=[IO.File]::ReadAllText($launcherPath)
$lines=[IO.File]::ReadAllLines($launcherPath)
$marker=[Array]::IndexOf($lines,'# POWERSHELL_GUI')
if($marker -lt 0){throw 'PowerShell marker was not found.'}
$psSource=[string]::Join([Environment]::NewLine,[string[]]$lines[($marker+1)..($lines.Length-1)])
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($psSource,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw ('Launcher parse failed: '+$errors[0].Message)}

foreach($required in @(
    'function Get-GitHubSyncPersonalToken',
    'function Get-GitHubDeviceAuthorization',
    'function Get-GitHubSyncAuthorization',
    'function New-CafeGitHubDeviceFlowWorker',
    '$authorization = Get-GitHubSyncAuthorization -OwnerWindow $dialog',
    'Sync-ProfileToGitHub -ProfileName $ProfileName -Token $token',
    'github.com/login/device',
    'offline_access',
    'api.github.com/user',
    'api.github.com/repos/',
    'ClearAccessToken',
    'repo.Permissions.Push',
    "'Confirm GitHub account'"
)){
    if(-not $psSource.Contains($required)){throw ('Missing GitHub sync auth behavior: '+$required)}
}
if($psSource -match 'Get-GitHubSyncToken\s+-OwnerWindow'){
    throw 'Save & Sync still calls the removed single-method token dialog.'
}

$editorAst=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-ProfileEditor'},$true)|Select-Object -First 1
if(-not $editorAst){throw 'Show-ProfileEditor not found.'}
$editor=$editorAst.Extent.Text
$localStart=$editor.IndexOf('$saveLocal.Add_Click({',[StringComparison]::Ordinal)
$syncStart=$editor.IndexOf('$saveSync.Add_Click({',[StringComparison]::Ordinal)
if($localStart -lt 0 -or $syncStart -le $localStart){throw 'Could not locate local-save and GitHub-sync handlers.'}
$localHandler=$editor.Substring($localStart,$syncStart-$localStart)
$syncHandler=$editor.Substring($syncStart)
if($localHandler -match 'Get-GitHubSyncAuthorization|Get-GitHubDeviceAuthorization|Get-GitHubSyncPersonalToken'){
    throw 'Save Locally must not ask for GitHub authentication.'
}
if($syncHandler -notmatch 'Get-GitHubSyncAuthorization' -or $syncHandler -notmatch 'Sync-ProfileToGitHub'){
    throw 'Save & Sync must authorize then pass its temporary token to the existing sync routine.'
}

$workerFunction=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-CafeGitHubDeviceFlowWorker'},$true)|Select-Object -First 1
if(-not $workerFunction){throw 'Device-flow worker function was not found.'}
. ([scriptblock]::Create($workerFunction.Extent.Text))
$worker=New-CafeGitHubDeviceFlowWorker -ClientId 'public-test-client-id' -Repository 'fabjoncela/Cs-script'
if(-not $worker.WorkerReportsProgress -or -not $worker.WorkerSupportsCancellation){throw 'Device flow worker must report progress and support cancel.'}
if(-not [CafeGitHubDeviceFlowWorker].GetMethod('ClearAccessToken')){throw 'Worker must clear its in-memory token after use/cancel.'}
$json='{"device_code":"test-device","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}'
$bytes=[Text.Encoding]::UTF8.GetBytes($json)
$stream=New-Object IO.MemoryStream(,$bytes)
$serializationPath=Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'System.Runtime.Serialization.dll'
$serializationAssembly=[Reflection.Assembly]::LoadFrom($serializationPath)
$serializerType=$serializationAssembly.GetType('System.Runtime.Serialization.Json.DataContractJsonSerializer',$true)
$serializer=[Activator]::CreateInstance($serializerType,@([CafeGitHubResponse]))
$parsed=[CafeGitHubResponse]$serializer.ReadObject($stream)
$stream.Dispose()
if($parsed.DeviceCode -ne 'test-device' -or $parsed.ExpiresIn -ne 900 -or $parsed.Interval -ne 5){throw 'Built-in JSON reader did not parse the GitHub device-code response.'}
$tokenProperty=[CafeGitHubDeviceFlowWorker].GetProperty('AccessToken')
$tokenProperty.GetSetMethod($true).Invoke($worker,@('test-only-token'))|Out-Null
$worker.ClearAccessToken()
if($tokenProperty.GetValue($worker,$null)){throw 'Clearing the device worker did not clear its in-memory token.'}
$worker.Dispose()

Write-Host 'PASS: token and device-code methods remain available; only Save & Sync authenticates; worker C# compiles; no network or credential used.'
