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
if($source -match 'New-Tile "Set DPI 800 \(Live\)" 18'){
    throw 'Old fixed 800 DPI button must be removed.'
}
if($source -notmatch '(?m)^# New-Tile "Set DPI 800 \(Onboard\)" 19'){
    throw 'Onboard button must remain disabled.'
}
foreach($fragment in @(
    '$script:ManualDpiInput=New-Object System.Windows.Forms.TextBox',
    '$script:ManualDpiChangeButton.Text=''Change DPI''',
    'ConvertTo-ManualLogitechDPI -Text $script:ManualDpiInput.Text',
    'Invoke-LogitechDpiButton -DPI $dpi',
    '$script:ManualDpiChangeButton.PerformClick()'
)){
    if(-not $source.Contains($fragment)){throw ('Change DPI UI wiring missing: '+$fragment)}
}
if(-not $functions.ContainsKey('ConvertTo-ManualLogitechDPI')){
    throw 'Manual DPI validation function missing.'
}
$manualButton=$functions['Invoke-LogitechDpiButton']
if($manualButton -notmatch 'Request-LogitechLiveDPI -DPI \$DPI' -or
   $manualButton -notmatch 'Assert-LogitechDPI -DPI \$DPI'){
    throw 'Manual Change DPI button must apply entered value to live DPI routine.'
}
# Test the actual input parser on Windows PowerShell 5.1 (no device required).
Invoke-Expression $functions['Assert-LogitechDPI']
Invoke-Expression $functions['ConvertTo-ManualLogitechDPI']
foreach($inputValue in @('100','300','800','1600','2400','25600',' 800 ')){
    $expect=[int]$inputValue.Trim()
    if((ConvertTo-ManualLogitechDPI -Text $inputValue) -ne $expect){
        throw ('Incorrect manual DPI parsing: '+$inputValue)
    }
}
foreach($invalid in @('',' ','abc','800.5','-800','99','0','25601','999999','1e3')){
    $failed=$false
    try { [void](ConvertTo-ManualLogitechDPI -Text $invalid) }
    catch { $failed=$true }
    if(-not $failed){throw ('Expected manual DPI input rejection: '+$invalid)}
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
if($request -notmatch 'LogihubRequestGeneration\+\+' -or
   $functions['Set-LogitechLiveDPI'] -notmatch 'Test-SameSuperlight' -or
   $functions['Set-LogitechLiveDPI'] -notmatch 'Schedule-LogitechDpiVerification' -or
   $functions['Schedule-LogitechDpiVerification'] -notmatch 'context\.Generation -ne \$script:LogihubRequestGeneration'){
    throw 'Latest DPI request, device revalidation, and delayed read-back protections are required.'
}
Invoke-Expression $functions['Test-SameSuperlight']
$expectedDevice=[pscustomobject]@{Index=2;Model='pro_x_2_wireless_mouse'}
if(-not (Test-SameSuperlight $expectedDevice ([pscustomobject]@{Index=2;Model='pro_x_2_wireless_mouse'})) -or
   (Test-SameSuperlight $expectedDevice ([pscustomobject]@{Index=2;Model='pro_x_wireless_mouse'})) -or
   (Test-SameSuperlight $expectedDevice ([pscustomobject]@{Index=3;Model='pro_x_2_wireless_mouse'}))){
    throw 'DPI target revalidation must reject a changed index or model.'
}
Invoke-Expression $functions['Get-LogitechDPIReadback']
function Invoke-Logihub { param([string[]]$Arguments) return "2 PRO X SUPERLIGHT 2 800`n" }
if((Get-LogitechDPIReadback -DeviceIndex 2) -ne 800){throw 'DPI read-back parser failed.'}
if($source -notmatch 'c54d'){
    throw 'C54D helper integration is missing.'
}
Invoke-Expression $functions['Assert-LogitechDPI']
foreach($name in @('FabMode','ArliMode','BrileMode','ArmlMode','OliMode')){
    $profile=Get-Content -LiteralPath (Join-Path $root ('profiles\'+$name+'.json')) -Raw | ConvertFrom-Json
    $dpi=0
    if(-not $profile.PSObject.Properties['LogitechDPI'] -or
       -not [int]::TryParse([string]$profile.LogitechDPI,[ref]$dpi)){
        throw ($name+' must define LogitechDPI as an integer.')
    }
    try { Assert-LogitechDPI -DPI $dpi }
    catch { throw ($name+' LogitechDPI must be within the supported 100 to 25600 range; found '+$dpi+'.') }
}
Write-Host 'PASS: Logitech DPI presets accept each profile''s supported custom DPI, local/cloud editor persistence, auto LIVE apply, async shared helper, onboard button disabled.'
