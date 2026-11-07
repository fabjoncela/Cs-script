# Focused WinForms and callback-wiring checks for asynchronous graphics history.
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
$uiFunction=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-CafeGraphicsHistoryUi'},$true)
$editorFunction=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-ProfileEditor'},$true)
$workerFunction=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-CafeGraphicsHistoryWorker'},$true)
$uriFunction=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-CafeGraphicsHistoryRequestUri'},$true)
if(-not $uiFunction -or -not $editorFunction -or -not $workerFunction -or -not $uriFunction){throw 'Graphics history UI, editor, request builder, or background worker source was not found.'}
Invoke-Expression $uiFunction.Extent.Text
Invoke-Expression $uriFunction.Extent.Text
$expectedUri='https://api.github.com/repos/fabjoncela/Cs-script/commits?path=graphics%2FFabMode.json&per_page=4&sha=main'
if((New-CafeGraphicsHistoryRequestUri -Repo 'fabjoncela/Cs-script' -Branch 'main' -ProfileName FabMode) -cne $expectedUri){
    throw 'The graphics history request URL must include its configured repository and branch.'
}
$editorSource=$editorFunction.Extent.Text
foreach($required in @(
    '$worker.RequestContext=$historyUiContext',
    '$historyRepo=[string]$script:GithubRepo',
    '$historyBranch=[string]$script:GithubBranch',
    '$historyUri=New-CafeGraphicsHistoryRequestUri -Repo $historyRepo -Branch $historyBranch -ProfileName $ProfileName',
    '$request=$sender.RequestContext',
    'Set-CafeGraphicsHistoryUi -Context $request -ErrorMessage $message',
    'Set-CafeGraphicsHistoryUi -Context $request -NoHistory'
)){
    if(-not $editorSource.Contains($required)){throw ('Graphics history callback is missing required behavior: '+$required)}
}
$completionStart=$editorSource.IndexOf('$worker.Add_RunWorkerCompleted({',[StringComparison]::Ordinal)
$completionEnd=$editorSource.IndexOf('$worker.RunWorkerAsync($historyUri)',$completionStart,[StringComparison]::Ordinal)
if($completionStart -lt 0 -or $completionEnd -le $completionStart){throw 'Cannot isolate the graphics-history completion callback.'}
$loadHandlerStart=$editorSource.IndexOf('$loadHistory.Add_Click({',[StringComparison]::Ordinal)
$loadHandlerEnd=$editorSource.IndexOf('}.GetNewClosure())',$loadHandlerStart,[StringComparison]::Ordinal)
if($loadHandlerStart -lt 0 -or $loadHandlerEnd -le $loadHandlerStart){throw 'Cannot isolate the closed-over Load history handler.'}
$loadHandlerSource=$editorSource.Substring($loadHandlerStart,$loadHandlerEnd-$loadHandlerStart)
if($loadHandlerSource -match '\$script:Github(Repo|Branch)'){
    throw 'The closed-over Load history handler must use its captured repository and branch values, not its private script scope.'
}
$completionSource=$editorSource.Substring($completionStart,$completionEnd-$completionStart)
if($completionSource -match '\.GetNewClosure\(\)'){
    throw 'The asynchronous completion callback must not capture editor locals in a nested closure.'
}
if($editorSource -notmatch 'httpStatus=''\+\[string\]\$sender\.HttpStatusCode' -or
   $editorSource -notmatch 'uri=''\+\[string\]\$sender\.RequestUri' -or
   $workerFunction.Extent.Text -notmatch 'public object RequestContext \{ get; set; \}' -or
   $workerFunction.Extent.Text -notmatch 'public int HttpStatusCode \{ get; private set; \}' -or
   $workerFunction.Extent.Text -notmatch 'public string RequestUri \{ get; private set; \}'){
    throw 'The history worker must retain request context, URL, and HTTP status.'
}

$context=@{
    HistoryChoice=(New-Object System.Windows.Forms.ComboBox)
    LoadButton=(New-Object System.Windows.Forms.Button)
    RestoreButton=(New-Object System.Windows.Forms.Button)
    StatusLabel=(New-Object System.Windows.Forms.Label)
    HistoryState=[pscustomobject]@{Loaded=$false}
}
try{
    $context.HistoryChoice.Tag=[object[]]@()
    $context.LoadButton.Enabled=$false
    Set-CafeGraphicsHistoryUi -Context $context -ErrorMessage 'HTTP 503 test failure'
    if($context.StatusLabel.Text -notmatch 'History load failed: HTTP 503' -or
       -not $context.LoadButton.Enabled -or $context.RestoreButton.Enabled){
        throw 'History errors must remain visible, restore Load/Refresh, and leave unavailable restore disabled.'
    }

    $context.LoadButton.Enabled=$false
    Set-CafeGraphicsHistoryUi -Context $context -NoHistory
    if($context.HistoryChoice.Items.Count -ne 1 -or $context.HistoryChoice.Enabled -or
       $context.RestoreButton.Enabled -or -not $context.LoadButton.Enabled -or
       -not $context.HistoryState.Loaded -or $context.StatusLabel.Text -notmatch 'GitHub returned 404'){
        throw 'HTTP 404 must show no earlier versions and restore a retryable Load/Refresh button.'
    }

    $context.HistoryState.Loaded=$false
    $version=[pscustomobject]@{DateUtc='2026-11-01T12:00:00Z';Message='test revision';Sha=('a'*40)}
    Set-CafeGraphicsHistoryUi -Context $context -Versions @($version)
    if($context.HistoryChoice.Items.Count -ne 1 -or -not $context.HistoryChoice.Enabled -or
       -not $context.RestoreButton.Enabled -or -not $context.HistoryState.Loaded){
        throw 'Successful history results must populate and enable selection and restore.'
    }
}finally{
    $context.HistoryChoice.Dispose();$context.LoadButton.Dispose()
    $context.RestoreButton.Dispose();$context.StatusLabel.Dispose()
}
Write-Host 'PASS: graphics-history request configuration, callback wiring, and error, 404, success, retry, and control recovery states.'
