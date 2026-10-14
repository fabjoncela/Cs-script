Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$lines=[IO.File]::ReadAllLines((Join-Path (Split-Path -Parent $PSScriptRoot) 'cafe.bat'))
$index=[Array]::IndexOf($lines,'# POWERSHELL_GUI')
$body=[string]::Join([Environment]::NewLine,[string[]]$lines[($index+1)..($lines.Length-1)])
$t=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($body,[ref]$t,[ref]$errors)
if(@($errors).Count){throw ('Syntax error: '+$errors[0].Message)}
$functions=@{}
foreach($f in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){$functions[$f.Name]=$f.Extent.Text}
foreach($n in @('Set-StepResult','Set-RunOutcome','Clear-RunOutcomes','Start-StepScope','Complete-StepScope','Write-RunSummary','Invoke-GamingProfile','Invoke-GraphicsOnly')){
    if(-not $functions.ContainsKey($n)){throw ('Missing '+$n)}
}
$script:StepResults=New-Object 'System.Collections.Generic.List[object]'
$script:RunOutcomes=New-Object 'System.Collections.Generic.List[object]'
$script:StepScope=$null
$script:StepScopeError=$false
$script:StepScopeWarning=$false
$script:messages=@()
function Write-Log {param([string]$Message,[string]$Level='INFO')
    $script:messages+=("[$Level] "+$Message)
    if($script:StepScope -and $Level -eq 'ERROR'){$script:StepScopeError=$true}
    if($script:StepScope -and $Level -eq 'WARN'){$script:StepScopeWarning=$true}
}
foreach($n in @('Set-StepResult','Set-RunOutcome','Clear-RunOutcomes','Start-StepScope','Complete-StepScope','Get-StepRecoveryAdvice','Write-RunSummary')){Invoke-Expression $functions[$n]}
Start-StepScope -Run FabMode -Step Mouse
Complete-StepScope
Start-StepScope -Run FabMode -Step NVIDIA
Write-Log 'unsupported mode' WARN
Complete-StepScope
Start-StepScope -Run FabMode -Step Config
Write-Log 'file write failed' ERROR
Complete-StepScope
Set-StepResult -Run FabMode -Step DPI -Status PENDING
Set-StepResult -Run FabMode -Step DPI -Status SUCCESS
Set-RunOutcome -Run FabMode -Setting 'Display mode' -Requested '1920x1080 @ highest Hz' -Target 'DISPLAY1' -Status APPLIED -Actual '1920x1080 @ 360Hz' -Detail 'Read-back verified.'
Set-RunOutcome -Run FabMode -Setting 'Digital Vibrance' -Requested '75%' -Target 'NVIDIA display' -Status FALLBACK -Actual 'legacy 47/63' -Detail 'Mapped to the queried legacy range.'
Set-RunOutcome -Run FabMode -Setting 'Hue' -Requested 'driver default' -Target 'DISPLAY1' -Status SKIPPED -Detail 'Unsupported by this driver.'
Write-RunSummary -Run FabMode
$statuses=@{}
foreach($entry in $script:StepResults){$statuses[$entry.Step]=$entry.Status}
if($statuses.Mouse -ne 'SUCCESS' -or $statuses.NVIDIA -ne 'PARTIAL' -or $statuses.Config -ne 'FAILED' -or $statuses.DPI -ne 'SUCCESS'){throw 'Incorrect status'}
if($script:StepResults.Count -ne 4){throw 'Pending result not replaced'}
if(($script:messages -join ' ') -notmatch '1 PARTIAL, 0 SKIPPED, 1 FAILED'){throw 'Summary missing failure'}
if(($script:messages -join ' ') -match '\[RESULT\] RESULT '){throw 'Duplicate RESULT prefix'}
if(-not ($script:messages | Where-Object {$_ -match '\[WARN\] FabMode \| NVIDIA \| PARTIAL: .*Next: .*LIVE LOGS'})){
    throw 'Partial step summary must name the step and direct the user to its warnings.'
}
if(-not ($script:messages | Where-Object {$_ -match '\[ERROR\] FabMode \| Config \| FAILED: .*Next: .*LIVE LOGS'})){
    throw 'Failed step summary must name the failure and include a next step.'
}
if(-not ($script:messages | Where-Object {$_ -match '\[INFO\] FabMode \| Display mode \| APPLIED \| requested: 1920x1080 @ highest Hz \| target: DISPLAY1 \| actual: 1920x1080 @ 360Hz'})){
    throw 'Run summary must include requested, targeted, and verified display values.'
}
if(-not ($script:messages | Where-Object {$_ -match '\[INFO\] FabMode \| Digital Vibrance \| FALLBACK'})){
    throw 'Run summary must distinguish fallback results.'
}
if(-not ($script:messages | Where-Object {$_ -match '\[INFO\] FabMode \| Hue \| SKIPPED'})){
    throw 'Run summary must include skipped settings.'
}
if(-not ($script:messages | Where-Object {$_ -match '\[SUMMARY\] FabMode settings: 1 APPLIED, 1 FALLBACK, 1 SKIPPED'})){
    throw 'Run summary must count per-setting outcomes.'
}
if((Get-StepRecoveryAdvice -Step 'Install CS2 fab.cfg' -Status 'FAILED') -notmatch 'CS2 cfg folder'){
    throw 'CFG installation failures must include actionable recovery advice.'
}
if((Get-StepRecoveryAdvice -Step 'Logitech live DPI' -Status 'PENDING') -notmatch 'still running|helper download'){
    throw 'Pending DPI guidance must explain that helper work may still be running.'
}
if($functions['Invoke-GamingProfile'] -notmatch 'Start-StepScope' -or $functions['Invoke-GamingProfile'] -notmatch 'PENDING'){throw 'Profile not instrumented'}
if($functions['Invoke-GraphicsOnly'] -notmatch 'Complete-StepScope'){throw 'Graphics not instrumented'}
if($functions['Apply-NvidiaGamingSettings'] -notmatch 'Set-RunOutcome' -or
   $functions['Apply-ProfileMouse'] -notmatch 'Set-RunOutcome' -or
   $functions['Set-LogitechLiveDPI'] -notmatch 'Set-RunOutcome'){
    throw 'Profile device/display operations must feed verified outcomes into the run summary.'
}
Write-Host 'PASS: status tracking, per-setting requested/target/actual outcomes, fallbacks, skips, errors, and summary persistence format.'
