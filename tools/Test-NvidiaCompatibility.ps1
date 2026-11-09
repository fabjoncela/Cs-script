# Read-only NVIDIA compatibility regression tests on Windows PowerShell 5.1.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$lines=[IO.File]::ReadAllLines((Join-Path (Split-Path -Parent $PSScriptRoot) 'cafe.bat'))
$marker=[Array]::IndexOf($lines,'# POWERSHELL_GUI')
if($marker -lt 0){throw 'Missing launcher marker.'}
$code=[string]::Join([Environment]::NewLine,[string[]]$lines[($marker+1)..($lines.Length-1)])
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($code,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw 'PowerShell parser reported errors.'}
$functions=@{}
foreach($f in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
    $functions[$f.Name]=$f.Extent.Text
}
foreach($name in @('Set-CafeStartupStatus','Get-NvidiaCompatibilityScan','Write-NvidiaCompatibilityScan','Apply-NvidiaGamingSettings','Set-CafePhysxAutoSelect','Get-PCDiagnostics','Invoke-GamingProfile')){
    if(-not $functions.ContainsKey($name)){throw ('Missing '+$name)}
}
$scanCode=$functions['Get-NvidiaCompatibilityScan']
$cafeSource=[IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'cafe.bat'))
$nvapiStart=$cafeSource.IndexOf('public static class FabNvApi {',[StringComparison]::Ordinal)
$nvapiEnd=$cafeSource.IndexOf('"@',[Math]::Max(0,$nvapiStart),[StringComparison]::Ordinal)
if($nvapiStart -lt 0 -or $nvapiEnd -le $nvapiStart){throw 'Could not locate the embedded NVAPI wrapper source.'}
$nvapiSource=$cafeSource.Substring($nvapiStart,$nvapiEnd-$nvapiStart)
if($nvapiSource -notmatch 'TryCheckNvApiSupport'){
    throw 'NVAPI wrapper must expose a real initialization probe.'
}
if($nvapiSource -notmatch '0x1057EB71' -or $nvapiSource -notmatch '0x00000001  // PREFERRED_PSTATE_PREFER_MAX' -or $nvapiSource -notmatch 'Power management mode = Prefer maximum performance'){
    throw 'Global DRS profile must request and verify Prefer maximum performance.'
}
foreach($required in @('0x1094F157','VRR_GLOBAL_FEATURE_DISABLED','G-SYNC global feature = off')){
    if(-not $nvapiSource.Contains($required)){throw ('Global DRS profile must disable and verify G-SYNC feature: '+$required)}
}
if($nvapiSource -match '0x10835000|0x0005F543'){
    throw 'Unsupported legacy Low Latency settings must not be retained in the NVAPI apply path.'
}
if($nvapiSource -notmatch 'Initialize\(out unload\)' -or
   $nvapiSource -notmatch 'finally\s*\{\s*if\s*\(initialized\s*&&\s*unload\s*!=\s*null\)' -or
   $nvapiSource -notmatch 'NvAPI_Initialize and NvAPI_Unload succeeded'){
    throw 'NVAPI initialization probe must balance a successful initialize with unload.'
}
if($scanCode -notmatch 'TryCheckNvApiSupport' -or
   $scanCode -match '\$result\.NVAPI\s*=.*\$apiFile'){
    throw 'Overall NVAPI availability must come from initialization, not DLL presence.'
}
foreach($required in @('Get-CimInstance Win32_VideoController','DriverVersion','IsAdvertisedMode','GetDisplayModesReport','nvapi64.dll','Get-StartApps','NVIDIA Control Panel')){
    if(-not $scanCode.Contains($required)){throw ('NVIDIA preflight missing '+$required)}
}
if($scanCode -notmatch 'TryCheckHueSupport' -or
   $scanCode -notmatch 'Hue settings will be skipped'){
    throw 'NVIDIA compatibility scan must preflight Hue support and report when it will be skipped.'
}
foreach($required in @('TryCheckDigitalVibranceSupport','TryCheckDriverProfileSupport','TryCheckGpuScalingSupport')){
    if(-not $scanCode.Contains($required)){throw ('NVIDIA capability scan missing '+$required)}
}
$apply=$functions['Apply-NvidiaGamingSettings']
if(-not $apply.Contains('$gSyncFeatureVerified=$performanceReport -match') -or
   -not $apply.Contains("-Setting 'G-SYNC Control Panel checkbox'") -or
   -not $apply.Contains("-Status APPLIED -Actual 'Off; global G-SYNC feature flag persisted and verified'") -or
   -not $apply.Contains("-Status SKIPPED -Detail 'The global G-SYNC feature flag did not read back as Off")){
    throw 'G-SYNC result must report APPLIED after persisted read-back, and SKIPPED when unverified.'
}
if($functions['Set-CafePhysxAutoSelect'] -notmatch 'NvCplPhysxAuto' -or
   $functions['Set-CafePhysxAutoSelect'] -notmatch 'RegistryValueKind\]::DWord' -or
   $functions['Set-CafePhysxAutoSelect'] -notmatch 'SetValue\(\$name,\[int\]1' -or
   $functions['Set-CafePhysxAutoSelect'] -notmatch 'GetValue\(\$name' -or
   $functions['Set-CafePhysxAutoSelect'] -notmatch 'RunAs' -or
   $functions['Set-CafePhysxAutoSelect'] -match 'SetValue\([^\r\n]*physxGpuId' -or
   $functions['Set-CafePhysxAutoSelect'] -notmatch 'GPU ID.*left unchanged'){
    throw 'PhysX Auto-select must elevate only its helper, set and verify the Auto flag, and leave the GPU identifier unchanged.'
}
$helperMatch=[regex]::Match($functions['Set-CafePhysxAutoSelect'], '(?s)\$helper=@''\r?\n(?<script>.*?)\r?\n''@')
if(-not $helperMatch.Success){throw 'PhysX helper script could not be extracted for syntax validation.'}
$helperTokens=$null;$helperErrors=$null
[void][Management.Automation.Language.Parser]::ParseInput($helperMatch.Groups['script'].Value,[ref]$helperTokens,[ref]$helperErrors)
if(@($helperErrors).Count){throw 'PhysX elevated helper script has PowerShell syntax errors.'}
if($apply -notmatch 'Set-CafePhysxAutoSelect' -or
   $apply -notmatch "-Setting 'PhysX processor'.*-Requested 'Auto-select \(recommended\)'.*-Status APPLIED" -or
   $apply -notmatch "-Setting 'PhysX processor'.*-Status FAILED" -or
   $apply -match "-Setting 'PhysX processor'.*-Status SKIPPED"){
    throw 'Profile Apply must report PhysX Auto-select as APPLIED after registry read-back or FAILED when it could not be verified.'
}
if($apply -notmatch 'Write-NvidiaCompatibilityScan' -or
   $apply -notmatch '\$compat\.DisplayHelper' -or
   $apply -notmatch '\$compat\.NVAPI'){
    throw 'NVIDIA apply must preflight and gate unsupported display/NVAPI operations.'
}
foreach($required in @('TrySetDisplayMode','TrySetDigitalVibrance','TryApplyPerformanceProfile','TrySetGpuScalingMode')){
    if(-not $apply.Contains($required)){throw ('Must preserve independent apply step '+$required)}
}
foreach($required in @('$compat.Vibrance','$compat.Hue','$compat.DriverProfile','$compat.GpuScaling')){
    if(-not $apply.Contains($required)){throw ('Profile Apply must gate NVIDIA setting on '+$required)}
}
foreach($required in @('TrySetDigitalVibrance','TrySetHueAngle','TryApplyPerformanceProfile','TrySetGpuScalingMode','skipped')){
    if(-not $apply.Contains($required)){throw ('Profile Apply must preserve per-setting fallback/reporting for '+$required)}
}
if($functions['Get-PCDiagnostics'] -notmatch 'Get-NvidiaCompatibilityScan'){throw 'Detect PC must include NVIDIA scan.'}
$profileApply=$functions['Invoke-GamingProfile']
if($profileApply -notmatch 'Apply-NvidiaGamingSettings -Width' -or
   $apply -notmatch 'TrySetDisplayMode' -or
   $code -notmatch 'highest advertised refresh at preferred resolution'){
    throw 'Every enabled profile apply must select the maximum refresh at its configured resolution.'
}
$startupStart=$code.IndexOf('$startupTimer.Add_Tick({',[StringComparison]::Ordinal)
$startupEnd=$code.IndexOf('$form.Add_Shown({',[StringComparison]::Ordinal)
if($startupStart -lt 0 -or $startupEnd -le $startupStart -or
   $code.Substring($startupStart,$startupEnd-$startupStart) -match 'Set-StartupHighestRefreshRate|TrySetDisplayMode'){
    throw 'Opening the launcher must not change display refresh before a profile is applied.'
}
if($code -match '\$script:StartupStatusTimer\s*=|\$script:StartupSpinnerAngle\s*=|\$script:StartupOverlay\s*=\s*New-Object' -or
   $code.Substring($startupStart,$startupEnd-$startupStart) -match 'Get-PCDiagnostics' -or
   $functions['Show-PCDiagnostics'] -notmatch 'Get-PCDiagnostics'){
    throw 'PC inventory must run through Detect PC on demand, without a startup overlay or scan.'
}
if($scanCode -match 'Start-Process|Invoke-WebRequest|Stop-Process|Install-|Update-Driver'){throw 'Compatibility preflight must be read-only.'}
$script:StartupOverlayLabel=$null
$script:StartupInventoryRunning=$false
Invoke-Expression $functions['Set-CafeStartupStatus']
Set-CafeStartupStatus 'NVIDIA compatibility test'
if($script:StartupStatusMessage -ne 'NVIDIA compatibility test'){
    throw 'Startup status helper must retain the current scan phase.'
}
Invoke-Expression $scanCode
$scan=Get-NvidiaCompatibilityScan -Width 1280 -Height 960 -RefreshHz 360
if($null -eq $scan -or $null -eq $scan.Report){throw 'NVIDIA scan did not return diagnostic report.'}
foreach($key in @('NVAPI','DisplayHelper','ExactMode','Vibrance','Hue','DriverProfile','GpuScaling')){
    if($null -eq $scan.$key){throw ('Missing compatibility field: '+$key)}
}
if(@($scan.Report).Count -lt 2){throw 'NVIDIA preflight did not record capability diagnostics.'}
Write-Host ('PASS: profile-triggered max-refresh action, no startup display changes, NVIDIA compatibility inventory, read-only runtime scan and diagnostics; '+@($scan.Report).Count+' lines.')
