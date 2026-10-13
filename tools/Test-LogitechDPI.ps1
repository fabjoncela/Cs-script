# Static safety and regression checks for Logitech DPI integration.
# No real HID devices or network downloads are used in CI.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$bat=Join-Path $root 'cafe.bat'
$source=[IO.File]::ReadAllText($bat)
$lines=[IO.File]::ReadAllLines($bat)
$marker=[Array]::IndexOf($lines,'# POWERSHELL_GUI')
if($marker -lt 0){throw 'Missing PowerShell marker.'}
$body=[string]::Join([Environment]::NewLine,[string[]]$lines[($marker+1)..($lines.Length-1)])
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($body,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw 'Launcher PowerShell syntax errors.'}
$functions=@{}
foreach($def in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
    $functions[$def.Name]=$def.Extent.Text
}
foreach($name in @('Start-LogihubAsyncDownload','Request-LogitechLiveDPI','Get-LogihubExecutable','Invoke-Logihub','Set-LogitechLiveDPI','Set-LogitechOnboardDPI','Invoke-GamingProfile','Show-ProfileEditor','Import-ProfileValues','Export-ProfileValues')){
    if(-not $functions.ContainsKey($name)){throw ('Missing function: '+$name)}
}
$apply=$functions['Invoke-GamingProfile']
if($apply -notmatch 'Request-LogitechLiveDPI\s+-DPI\s+\(\[int\]\$profile\.LogitechDPI\)'){
    throw 'Profiles must apply their own saved LIVE DPI.'
}
if($apply -match 'Set-LogitechOnboardDPI|onboard.*set-dpi'){throw 'Profile apply must NEVER write onboard memory.'}
if($functions['Set-LogitechLiveDPI'] -match 'onboard\s|Stop-Process|Stop-Service'){
    throw 'Live DPI must never modify onboard memory or stop G HUB.'
}
$onboard=$functions['Set-LogitechOnboardDPI']
foreach($phrase in @('onboard.*dump','onboard.*set-dpi','onboard.*mode','DialogResult]::Yes','Test-Path')){
    if($onboard -notmatch $phrase){throw ('Onboard backup/consent check missing: '+$phrase)}
}
if($onboard.IndexOf("'onboard','dump'",[StringComparison]::Ordinal) -ge
   $onboard.IndexOf("'onboard','set-dpi'",[StringComparison]::Ordinal)){
    throw 'Onboard backup must happen before any onboard write.'
}
if($source -notmatch 'New-Tile "Set DPI 800 \\(Live\\)" 18' -or $source -notmatch '(?m)^# New-Tile "Set DPI 800 \\(Onboard\\)" 19'){
    throw 'Live button must be active; onboard button must be commented out.'
}
if($functions['Start-LogihubAsyncDownload'] -notmatch 'Start-Process' -or $functions['Start-LogihubAsyncDownload'] -notmatch 'LogihubDownloadTimer' -or $functions['Request-LogitechLiveDPI'] -notmatch 'LogihubRequestedDPI'){
    throw 'Hybrid async download or latest DPI pending state missing.'
}
if($functions['Show-ProfileEditor'] -notmatch '\$p\.LogitechDPI=\[int\]\$logitechDpi\.Value'){
    throw 'Profile editor must save Logitech DPI.'
}
if($functions['Export-ProfileValues'] -notmatch 'LogitechDPI=\[int\]\$p\.LogitechDPI' -or
   $functions['Import-ProfileValues'] -notmatch "'LogitechDPI'"){
    throw 'Logitech DPI must support local JSON and GitHub profile sync.'
}
if($source -notmatch 'c876fe0172bb3910c4c6cfee0ef5674ebde4c9d37069b412daffbdf7a2505635'){
    throw 'Portable executable checksum pin missing.'
}
foreach($name in @('FabMode','ArliMode','BrileMode','ArmlMode','OliMode')){
    $profile=Get-Content -LiteralPath (Join-Path $root ('profiles\'+$name+'.json')) -Raw | ConvertFrom-Json
    if([int]$profile.LogitechDPI -ne 800){throw ($name+' must default to 800 DPI.')}
}
Write-Host 'PASS: Logitech DPI presets, local/cloud editor persistence, auto LIVE apply, async shared helper, onboard button disabled.'
