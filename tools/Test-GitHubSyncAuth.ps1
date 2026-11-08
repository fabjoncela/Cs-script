# Backend sync authorization contract. Static checks only; no token, network,
# GUI, or repository write is used.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$launcher=Join-Path $root 'cafe.bat'
$lines=[IO.File]::ReadAllLines($launcher)
$marker=[Array]::IndexOf($lines,'# POWERSHELL_GUI')
if($marker -lt 0){throw 'PowerShell marker was not found.'}
$source=[string]::Join([Environment]::NewLine,[string[]]$lines[($marker+1)..($lines.Length-1)])
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw ('Launcher parse failed: '+$errors[0].Message)}
$editor=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-ProfileEditor'},$true)
if(-not $editor){throw 'Profile editor was not found.'}
$tokenDialog=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-CafeBackendSyncToken'},$true)
$sync=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Sync-ProfileToBackend'},$true)
if(-not $tokenDialog -or $tokenDialog.Extent.Text -notmatch 'UseSystemPasswordChar' -or
   $tokenDialog.Extent.Text -notmatch 'script:BackendSyncToken' -or
   $tokenDialog.Extent.Text -notmatch 'at least 32 characters'){
    throw 'Backend authorization must use a masked, session-only token with a minimum length.'
}
if(-not $sync -or $sync.Extent.Text -notmatch 'expectedRevision' -or
   $sync.Extent.Text -notmatch 'Get-CafeBackendSnapshot' -or
   $sync.Extent.Text -notmatch 'Test-CafeBackendBundleMatch' -or
   $sync.Extent.Text -notmatch 'Complete-CafeBackendSync' -or
   $sync.Extent.Text -notmatch 'Authorization=\(\x27Bearer'){
    throw 'Backend sync must send an expected revision and verify the accepted bundle by read-back.'
}
$editorText=$editor.Extent.Text
$localAt=$editorText.IndexOf('$saveLocal.Add_Click({',[StringComparison]::Ordinal)
$syncAt=$editorText.IndexOf('$saveSync.Add_Click({',[StringComparison]::Ordinal)
if($localAt -lt 0 -or $syncAt -le $localAt){throw 'Save handlers were not found.'}
$localHandler=$editorText.Substring($localAt,$syncAt-$localAt)
$syncHandler=$editorText.Substring($syncAt)
if($localHandler -match 'Get-CafeBackendSyncToken|Sync-ProfileToBackend' -or
   $syncHandler -notmatch 'Get-CafeBackendSyncToken' -or
   $syncHandler -notmatch 'Sync-ProfileToBackend' -or
   $syncHandler -notmatch 'already saved locally' -or
   $syncHandler -notmatch 'never be written directly to GitHub'){
    throw 'Save Locally must work without auth; Save & Sync must authorize and write only to the backend.'
}
foreach($required in @('New-CafeBackendPayload','Save-CafeBackendQueue','Read-CafeBackendQueue','expectedRevision','backend-pending')){
    if(-not $source.Contains($required)){throw ('Missing pending backend sync behavior: '+$required)}
}
$legacyWriteCalls=@($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -in @('Sync-ProfileToGitHub','Get-GitHubSyncAuthorization')
},$true))
if($legacyWriteCalls.Count){
    throw 'Production launcher code must not call the retired GitHub profile write or authorization chooser; GitHub is a read-only fallback.'
}
Write-Host 'PASS: backend sync token stays in memory, edits queue locally, and writes verify backend read-back; GitHub is read-only.'
