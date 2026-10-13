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
if($source -notmatch 'New-Tile "Set DPI 800 \(Live\)" 18' -or $source -notmatch '(?m)^# New-Tile "Set DPI 800 \(Onboard\)" 19'){
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
$releaseUrl='https://github.com/fabjoncela/better-logihub/releases/download/v0.1.0-c54d.1/logihub.exe'
$expectedSha='dc30e45d4ba1df7d043c7c9a0aacda4257e09f5f23bb980466b985b77aa7dda4'
if($source -notmatch [regex]::Escape($releaseUrl) -or $source -notmatch [regex]::Escape($expectedSha)){
    throw 'Pinned C54D helper URL or executable checksum missing.'
}
if($source -match [regex]::Escape('https://github.com/cUDGk/better-logihub/releases/download/v0.1.0/logihub.exe')){
    throw 'Upstream helper URL must not be used by the launcher.'
}
if($functions['Get-LogihubExecutable'] -notmatch 'Get-FileHash' -or $functions['Get-LogihubExecutable'] -notmatch 'checksum mismatch'){
    throw 'Cached helper must be SHA-256 verified before execution.'
}
$request=$functions['Request-LogitechLiveDPI']
if($request -notmatch 'cacheReady' -or $request -notmatch 'checksum mismatch' -or $request -notmatch 'Start-LogihubAsyncDownload'){
    throw 'Outdated cached helpers must trigger an async verified replacement.'
}
if($functions['Start-LogihubAsyncDownload'] -notmatch [regex]::Escape($releaseUrl) -or
   $functions['Start-LogihubAsyncDownload'] -notmatch 'Downloaded Logitech helper SHA-256 verification failed'){
    throw 'Async helper download must use pinned fork URL and verify its SHA-256.'
}
if($request -match 'Remove-Item\s+-LiteralPath\s+\$script:LogihubExe'){
    throw 'Do not delete the existing helper before a replacement is verified.'
}
if($source -notmatch 'c54d'){
    throw 'C54D helper integration is missing.'
}
foreach($name in @('FabMode','ArliMode','BrileMode','ArmlMode','OliMode')){
    $profile=Get-Content -LiteralPath (Join-Path $root ('profiles\'+$name+'.json')) -Raw | ConvertFrom-Json
    if([int]$profile.LogitechDPI -ne 800){throw ($name+' must default to 800 DPI.')}
}
Write-Host 'PASS: Logitech DPI presets, local/cloud editor persistence, auto LIVE apply, async shared helper, onboard button disabled.'
