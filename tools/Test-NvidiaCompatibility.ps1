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
foreach($name in @('Get-NvidiaCompatibilityScan','Write-NvidiaCompatibilityScan','Apply-NvidiaGamingSettings','Get-PCDiagnostics','Invoke-GamingProfile')){
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
if($scanCode -match 'Start-Process|Invoke-WebRequest|Stop-Process|Install-|Update-Driver'){throw 'Compatibility preflight must be read-only.'}
Invoke-Expression $scanCode
$scan=Get-NvidiaCompatibilityScan -Width 1280 -Height 960 -RefreshHz 360
if($null -eq $scan -or $null -eq $scan.Report){throw 'NVIDIA scan did not return diagnostic report.'}
foreach($key in @('NVAPI','DisplayHelper','ExactMode')){
    if($null -eq $scan.$key){throw ('Missing compatibility field: '+$key)}
}
if(@($scan.Report).Count -lt 2){throw 'NVIDIA preflight did not record capability diagnostics.'}
Write-Host ('PASS: profile-triggered max-refresh action, no startup display changes, NVIDIA compatibility inventory, read-only runtime scan and diagnostics; '+@($scan.Report).Count+' lines.')
