# Isolated tests for stale GitHub mirror protection and explicit fallback use.
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
foreach($name in @('Get-CafeCloudSnapshot','Confirm-LocalProfileApply','Invoke-GraphicsOnly')){
    $found=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
    if($found.Count -ne 1){throw ('Expected one '+$name+' definition.')}
    if($name -eq 'Invoke-GraphicsOnly'){$graphicsOnly=$found[0].Extent.Text;continue}
    if($name -eq 'Confirm-LocalProfileApply'){$confirm=$found[0].Extent.Text;continue}
    Invoke-Expression $found[0].Extent.Text
}
$rollbackFunction=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Confirm-CafeBackendRevisionRollback'},$true))
$backendSnapshotFunction=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-CafeBackendSnapshot'},$true))
if($rollbackFunction.Count -ne 1 -or
   $rollbackFunction[0].Extent.Text -notmatch "'YesNo','Warning','Button2'" -or
   $backendSnapshotFunction.Count -ne 1 -or
   $backendSnapshotFunction[0].Extent.Text -notmatch 'Confirm-CafeBackendRevisionRollback'){
    throw 'A primary backend revision rollback must warn with No selected by default before returning the snapshot.'
}
$cloudFunctionText=[string]$ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-CafeCloudSnapshot'},$true)[0].Extent.Text
if($cloudFunctionText -notmatch 'OperationCanceledException'){throw 'Declining the primary rollback warning must not be treated as an outage that triggers mirror fallback.'}

$script:BackendRevisions=@{FabMode=10}
$script:BackendRevisionRollbackApprovals=@{}
$script:BackendSnapshots=@{}
$script:MirrorRevision=9
$script:UseBackend=$false
$script:CancelBackendRead=$false
$script:MirrorRequests=0
$script:ReadSource='Backend'
function Get-CafeBackendSnapshot {
    param([string]$ProfileName)
    if($script:CancelBackendRead){throw [System.OperationCanceledException]::new('mock user declined rollback')}
    if(-not $script:UseBackend){throw 'mock backend outage'}
    return [pscustomobject]@{ProfileName=$ProfileName;Revision=12;Source='Backend'}
}
function Get-CafeMirrorSnapshot {
    param([string]$ProfileName)
    $script:MirrorRequests++
    return [pscustomobject]@{ProfileName=$ProfileName;Revision=$script:MirrorRevision;Source='GitHubMirror'}
}
function Set-CafeCloudReadSourceDisplay {param([string]$Source);$script:ReadSource=$Source}
function Write-Log {param([string]$Message,[string]$Level='INFO')}

$rejected=$false
try{[void](Get-CafeCloudSnapshot -ProfileName 'FabMode' -ForceRefresh)}catch{$rejected=$_.Exception.Message -match 'mirror revision 9 is older than the last accepted revision 10'}
if(-not $rejected){throw ('An older mirror revision was accepted over the last verified revision. Actual error: '+$Error[0].Exception.Message)}
if($script:ReadSource -cne 'LocalFallback' -or $script:BackendSnapshots.ContainsKey('FabMode')){
    throw 'Rejecting a stale mirror must report local fallback and retain the prior snapshot.'
}

$script:MirrorRevision=10
$equal=Get-CafeCloudSnapshot -ProfileName 'FabMode' -ForceRefresh
if($equal.Source -cne 'GitHubMirror' -or $equal.Revision -ne 10){throw 'An equal verified mirror revision should remain usable.'}
$script:MirrorRevision=11
$newer=Get-CafeCloudSnapshot -ProfileName 'FabMode' -ForceRefresh
if($newer.Source -cne 'GitHubMirror' -or $newer.Revision -ne 11){throw 'A newer verified mirror revision should remain usable.'}
$script:UseBackend=$true
$backend=Get-CafeCloudSnapshot -ProfileName 'FabMode' -ForceRefresh
if($backend.Source -cne 'Backend' -or $backend.Revision -ne 12){throw 'A healthy backend must remain the preferred read source.'}

$script:CancelBackendRead=$true
$mirrorRequestsBefore=$script:MirrorRequests
$canceled=$false
try{[void](Get-CafeCloudSnapshot -ProfileName 'FabMode' -ForceRefresh)}catch{$canceled=$_.Exception -is [System.OperationCanceledException]}
if(-not $canceled -or $script:MirrorRequests -ne $mirrorRequestsBefore -or $script:ReadSource -cne 'LocalFallback'){
    throw 'Declining a primary revision rollback must cancel the read without trying the mirror.'
}

if($confirm -notmatch "'GitHubMirror'" -or $confirm -notmatch 'at revision \$revision' -or
   $confirm -notmatch "'YesNo','Warning','Button2'"){
    throw 'Using mirror-sourced profile data must show its revision and require explicit Yes confirmation.'
}
if($graphicsOnly -notmatch 'Get-CafeCloudSnapshot -ProfileName \$ModeName' -or
   $graphicsOnly -notmatch 'Confirm-LocalProfileApply -ProfileName \$ModeName -Source \$cloudSnapshot\.Source' -or
   $graphicsOnly.IndexOf('Confirm-LocalProfileApply -ProfileName $ModeName',[StringComparison]::Ordinal) -gt $graphicsOnly.IndexOf('Apply-CS2ModeGraphics -ModeName $ModeName',[StringComparison]::Ordinal)){
    throw 'Apply Graphics must confirm mirror-sourced presets before changing CS2 settings.'
}
Write-Host 'PASS: stale mirror revisions are rejected; current/newer mirror data requires confirmation before profile actions or Apply Graphics.'
