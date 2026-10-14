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
foreach($name in @('Get-NvidiaCompatibilityScan','Write-NvidiaCompatibilityScan','Apply-NvidiaGamingSettings','Get-PCDiagnostics','Set-StartupHighestRefreshRate')){
    if(-not $functions.ContainsKey($name)){throw ('Missing '+$name)}
}
$scanCode=$functions['Get-NvidiaCompatibilityScan']
foreach($required in @('Get-CimInstance Win32_VideoController','DriverVersion','IsAdvertisedMode','GetDisplayModesReport','nvapi64.dll','Get-StartApps','NVIDIA Control Panel')){
    if(-not $scanCode.Contains($required)){throw ('NVIDIA preflight missing '+$required)}
}
$apply=$functions['Apply-NvidiaGamingSettings']
if($apply -notmatch 'Write-NvidiaCompatibilityScan' -or
   $apply -notmatch '\$compat\.DisplayHelper' -or
   $apply -notmatch '\$compat\.NVAPI'){
    throw 'NVIDIA apply must preflight and gate unsupported display/NVAPI operations.'
}
foreach($required in @('TrySetDisplayMode','TrySetDigitalVibrance','TryApplyPerformanceProfile','TrySetGpuFullscreenScaling')){
    if(-not $apply.Contains($required)){throw ('Must preserve independent apply step '+$required)}
}
if($functions['Get-PCDiagnostics'] -notmatch 'Get-NvidiaCompatibilityScan'){throw 'Detect PC must include NVIDIA scan.'}
$startup=$functions['Set-StartupHighestRefreshRate']
if($startup -notmatch 'TrySetHighestRefreshAtCurrentResolution' -or
   $code -notmatch '(?s)\$startupTimer\.Add_Tick\(\{.{0,700}Set-StartupHighestRefreshRate'){
    throw 'Startup must select and verify the highest refresh after the hardware inventory.'
}
if($scanCode -match 'Start-Process|Invoke-WebRequest|Stop-Process|Install-|Update-Driver'){throw 'Compatibility preflight must be read-only.'}
Invoke-Expression $scanCode
$scan=Get-NvidiaCompatibilityScan -Width 1280 -Height 960 -RefreshHz 360
if($null -eq $scan -or $null -eq $scan.Report){throw 'NVIDIA scan did not return diagnostic report.'}
foreach($key in @('NVAPI','DisplayHelper','ExactMode')){
    if($null -eq $scan.$key){throw ('Missing compatibility field: '+$key)}
}
if(@($scan.Report).Count -lt 2){throw 'NVIDIA preflight did not record capability diagnostics.'}
Write-Host ('PASS: startup max-refresh action, NVIDIA compatibility inventory, read-only runtime scan, independent driver fallback and diagnostics; '+@($scan.Report).Count+' lines.')
