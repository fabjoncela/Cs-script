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
foreach($name in @('Set-CafeStartupStatus','Get-NvidiaCompatibilityScan','Write-NvidiaCompatibilityScan','Apply-NvidiaGamingSettings','Get-PCDiagnostics','Invoke-GamingProfile')){
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
$startupEnd=$code.IndexOf('$form.Add_Shown({ $startupTimer.Start() })',[StringComparison]::Ordinal)
if($startupStart -lt 0 -or $startupEnd -le $startupStart -or
   $code.Substring($startupStart,$startupEnd-$startupStart) -match 'Set-StartupHighestRefreshRate|TrySetDisplayMode'){
    throw 'Opening the launcher must not change display refresh before a profile is applied.'
}
if($code -notmatch '\$script:StartupStatusTimer\.Interval=33' -or
   $code -notmatch '\$script:StartupStatusTimer\.Add_Tick\(\{' -or
   $code -notmatch '\$script:StartupSpinnerAngle=\(\$script:StartupSpinnerAngle\+18\)%360' -or
   $code -notmatch '\$script:StartupStatusTimer\.Start\(\)'){
    throw 'The startup spinner must animate on its timer while inventory runs.'
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
