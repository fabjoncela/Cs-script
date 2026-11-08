# Backend graphics-history parsing and preset validation. No network or game writes.
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
foreach($name in @('ConvertTo-CafeGraphicsPreset','ConvertFrom-CafeBackendGraphicsHistory','Get-CafeGraphicsHistoryPreset','Set-CafeGraphicsHistoryUi')){
 $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 if(-not $node){throw ('Missing backend history function: '+$name)}
 . ([scriptblock]::Create($node.Extent.Text))
}
$script:GamingProfiles=[ordered]@{FabMode=[pscustomobject]@{ScalingMode=2}}
$current=Get-Content -LiteralPath (Join-Path $root 'graphics/FabMode.json') -Raw|ConvertFrom-Json
$older=$current|ConvertTo-Json -Depth 8|ConvertFrom-Json
$older.Settings.MSAASamples=4
$json=[pscustomobject]@{profile='FabMode';revisions=@(
 [pscustomobject]@{revision=3;createdUtc='2026-11-08T12:00:00Z';graphics=$current},
 [pscustomobject]@{revision=2;createdUtc='2026-11-07T12:00:00Z';graphics=$older},
 [pscustomobject]@{revision=1;createdUtc='2026-11-06T12:00:00Z';graphics=$current}
)}|ConvertTo-Json -Depth 9
$versions=@(ConvertFrom-CafeBackendGraphicsHistory -ProfileName FabMode -ResponseJson $json)
if($versions.Count -ne 2 -or $versions[0].Revision -ne 2 -or $versions[1].Revision -ne 1 -or $versions[0].Message -ne 'Backend revision 2'){
 throw 'History parser must omit current revision and return earlier backend revisions newest first.'
}
$restored=Get-CafeGraphicsHistoryPreset -ProfileName FabMode -Version $versions[0]
if($restored.Settings.MSAASamples -ne 4){throw 'Selected historical preset was not validated and restored.'}
$bad=$json|ConvertFrom-Json;$bad.revisions[2].revision=4
$rejected=$false
try{[void](ConvertFrom-CafeBackendGraphicsHistory -ProfileName FabMode -ResponseJson ($bad|ConvertTo-Json -Depth 9))}catch{$rejected=$true}
if(-not $rejected){throw 'Out-of-order backend history revisions must be rejected.'}
$context=@{HistoryChoice=(New-Object System.Windows.Forms.ComboBox);LoadButton=(New-Object System.Windows.Forms.Button);RestoreButton=(New-Object System.Windows.Forms.Button);StatusLabel=(New-Object System.Windows.Forms.Label);HistoryState=[pscustomobject]@{Loaded=$false}}
try{
 Set-CafeGraphicsHistoryUi -Context $context -Versions $versions
 if(-not $context.RestoreButton.Enabled -or $context.HistoryChoice.Items[0] -notmatch 'Backend revision 2') {throw 'History UI must expose revision labels and restore action.'}
 Set-CafeGraphicsHistoryUi -Context $context -ErrorMessage 'test outage'
 if($context.StatusLabel.Text -notmatch 'test outage' -or -not $context.LoadButton.Enabled){throw 'History outage must remain visible and retryable.'}
}finally{$context.HistoryChoice.Dispose();$context.LoadButton.Dispose();$context.RestoreButton.Dispose();$context.StatusLabel.Dispose()}
Write-Host 'PASS: backend history ordering, validation, restore, outage display, and retry state.'
