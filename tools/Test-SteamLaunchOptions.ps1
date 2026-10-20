# Windows PowerShell 5.1 regression: Play + Exec must launch CS2 with a
# one-time argument and MUST NOT edit Steam's localconfig.vdf.
# Mocks Steam operations; only the baseline writer's isolated temp fixture is changed.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$bat = Join-Path (Split-Path -Parent $PSScriptRoot) 'cafe.bat'
$lines = [IO.File]::ReadAllLines($bat)
$marker = [Array]::IndexOf($lines,'# POWERSHELL_GUI')
if($marker -lt 0){throw 'Missing launcher marker.'}
$source=[string]::Join([Environment]::NewLine,[string[]]$lines[($marker+1)..($lines.Length-1)])
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if(@($errors).Count -gt 0){throw "Launcher has syntax errors: $($errors[0].Message)"}
$names=@('Get-CS2ProfileBaselineCfgText','Install-CS2ProfileBaselineCfg','Get-CS2SteamLaunchArguments','Start-CS2WithProfileCfg')
foreach($name in $names){
    $found=@($ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true) |
             Where-Object { $_.Name -eq $name })
    if($found.Count -ne 1){throw "Expected exactly one function: $name"}
    Invoke-Expression $found[0].Extent.Text
}
if($source -match '\b(Set-CS2SteamLaunchOptions|Update-CS2LaunchOptionsVdfText|Get-ActiveCS2SteamConfigPath)\b'){
    throw 'The old Steam launch-options file writer must be absent.'
}
$baseline=Get-CS2ProfileBaselineCfgText
foreach($required in @(
    'bind "MWHEELDOWN" "invnext"','unbind "CAPSLOCK"','unbind "ALT"',
    'cl_radar_scale "0.7"','sensitivity "1.25"'
)){
    if($baseline -notmatch [regex]::Escape($required)){throw "Baseline CFG is missing captured CS2 reset value: $required"}
}
if($baseline -match '(?i)\bcl_crosshair[a-z0-9_]*\b'){throw 'The profile baseline must leave crosshair settings to the selected profile CFG.'}
if($baseline -match '(?i)\bunbindall\b'){throw 'The profile baseline must restore specific defaults, not use unbindall.'}
$apply=$source.IndexOf('function Invoke-GamingProfile {',[StringComparison]::Ordinal)
$applyEnd=$source.IndexOf('function Get-CS2SteamLaunchArguments {',[StringComparison]::Ordinal)
if($apply -lt 0 -or $applyEnd -le $apply){throw 'Profile apply function missing.'}
$applyText=$source.Substring($apply,$applyEnd-$apply)
if($applyText -notmatch 'Install-ProfileCfg' -or $applyText -match '(?i)-applaunch|LaunchOptions|Set-CS2SteamLaunchOptions'){
    throw 'Normal profile application must only install the CFG, not modify Steam launch options.'
}
foreach($name in @('FabMode','ArliMode','BrileMode','ArmlMode','OliMode','Provmode')){
    if($source -notmatch ('New-Tile "'+[regex]::Escape($name)+'"')){throw "Missing main tile: $name"}
}
if($source -notmatch '\$play\.Add_Click' -or $source -notmatch 'Start-CS2WithProfileCfg -ProfileName \$selectedProfile'){
    throw 'Missing independent Play + Exec profile button handler.'
}
$script:GamingProfiles=[ordered]@{
    FabMode=@{ConfigFile='fab.cfg';CfgDownloadUrl='https://raw.githubusercontent.com/fabjoncela/Cs-script/main/fab.cfg'}
    ArliMode=@{ConfigFile='arli.cfg';CfgDownloadUrl='https://raw.githubusercontent.com/fabjoncela/Cs-script/main/arli.cfg'}
    BrileMode=@{ConfigFile='brile.cfg';CfgDownloadUrl='https://raw.githubusercontent.com/fabjoncela/Cs-script/main/brile.cfg'}
    ArmlMode=@{ConfigFile='arml.cfg';CfgDownloadUrl='https://raw.githubusercontent.com/fabjoncela/Cs-script/main/arml.cfg'}
    OliMode=@{ConfigFile='oli.cfg';CfgDownloadUrl='https://raw.githubusercontent.com/fabjoncela/Cs-script/main/oli.cfg'}
    Provmode=@{ConfigFile='prov.cfg';CfgDownloadUrl='https://raw.githubusercontent.com/fabjoncela/Cs-script/main/prov.cfg'}
}
$script:FabCfgCloudUrl='https://raw.githubusercontent.com/fabjoncela/Cs-script/main/fab.cfg'
$script:Installed=@()
$script:InstalledUrls=@()
$script:CloudPreferredFlags=@()
$script:Launched=@()
$script:Events=@()
$script:ShouldInstall=$true
function Write-Log {param([string]$Message,[string]$Level='INFO')}
function Refresh-ProfileFromGitHub {param([string]$ProfileName)}
function Resolve-PendingProfileChanges {param([string]$ProfileName);return $true}
function Confirm-LocalProfileApply {param([string]$ProfileName,[string]$Source,[string]$Action='apply');return $true}
function Get-Process {[CmdletBinding()] param([string]$Name); return $null}
function Get-SteamExecutable {return 'C:\Dummy\Steam\steam.exe'}
function Find-CS2ConfigFolder {[CmdletBinding()] param([switch]$NoPrompt);return $script:BaselineFixture}
$script:BaselineFixture=Join-Path $env:TEMP ('CafeLauncher-BaselineTest-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:BaselineFixture -ErrorAction Stop | Out-Null
try{
    if(-not (Install-CS2ProfileBaselineCfg)){throw 'Baseline CFG installation failed in the isolated fixture.'}
    $baselinePath=Join-Path $script:BaselineFixture 'cafelauncher_profile_baseline.cfg'
    if(-not (Test-Path -LiteralPath $baselinePath -PathType Leaf)){throw 'Baseline CFG was not written to the selected CS2 folder.'}
    if((Get-Content -LiteralPath $baselinePath -Raw) -cne $baseline){throw 'Installed baseline CFG content differs from the captured reset snapshot.'}
    [IO.File]::WriteAllText($baselinePath,'preexisting user file')
    if(-not (Install-CS2ProfileBaselineCfg)){throw 'Baseline CFG replacement failed in the isolated fixture.'}
    $backups=@(Get-ChildItem -LiteralPath $script:BaselineFixture -Filter 'cafelauncher_profile_baseline.cfg.backup-*' -File)
    if($backups.Count -ne 1 -or [IO.File]::ReadAllText($backups[0].FullName) -cne 'preexisting user file'){
        throw 'Existing baseline CFG was not preserved in a verified backup.'
    }
}finally{
    Remove-Item -LiteralPath $script:BaselineFixture -Recurse -Force -ErrorAction SilentlyContinue
}
function Install-CS2ProfileBaselineCfg {$script:Events+='baseline';return $true}
function Install-ProfileCfg {
    param([switch]$Silent,[string]$CfgName,[string]$DownloadUrl,[switch]$CloudPreferred)
    $script:Installed+= $CfgName
    $script:InstalledUrls+=$DownloadUrl
    $script:CloudPreferredFlags+=[bool]$CloudPreferred
    $script:Events+='profile-cfg'
    return $script:ShouldInstall
}
function Start-Process {
    [CmdletBinding()]
    param([string]$FilePath,[string[]]$ArgumentList)
    $script:Launched+= @{ FilePath=$FilePath; Arguments=@($ArgumentList) }
    $script:Events+='launch'
}
foreach($name in @('FabMode','ArliMode','BrileMode','ArmlMode','OliMode','Provmode')){
    Start-CS2WithProfileCfg -ProfileName $name
}
if($script:Launched.Count -ne 6 -or $script:Installed.Count -ne 6){throw 'Expected exactly six installs and Steam launch requests.'}
if(@($script:CloudPreferredFlags | Where-Object { -not $_ }).Count -ne 0){throw 'Play + Exec must prefer the selected profile CFG from GitHub.'}
if(@($script:InstalledUrls | Where-Object { $_ -notmatch '^https://raw\.githubusercontent\.com/.+\.cfg$' }).Count -ne 0){
    throw 'Play + Exec did not pass the selected GitHub profile CFG URL to the installer.'
}
if($script:Events.Count -ne 18){throw 'Expected baseline install, profile CFG install, then launch for each profile.'}
for($i=0;$i -lt 6;$i++){
    if($script:Events[$i*3] -ne 'baseline' -or $script:Events[$i*3+1] -ne 'profile-cfg' -or $script:Events[$i*3+2] -ne 'launch'){
        throw 'Play + Exec did not install the reset baseline before the selected profile CFG and launch.'
    }
}
foreach($launch in $script:Launched){
    if($launch.FilePath -ne 'C:\Dummy\Steam\steam.exe'){throw 'Incorrect Steam executable.'}
    if($launch.Arguments.Count -ne 6){throw 'Expected six Steam arguments including baseline and profile execs.'}
    if($launch.Arguments[0] -ne '-applaunch' -or $launch.Arguments[1] -ne '730' -or
       $launch.Arguments[2] -ne '+exec' -or $launch.Arguments[3] -ne 'cafelauncher_profile_baseline.cfg' -or
       $launch.Arguments[4] -ne '+exec'){
        throw 'Incorrect Steam app launch sequence; baseline must execute before the profile CFG.'
    }
}
for($i=0;$i -lt 6;$i++){
    if($script:Launched[$i].Arguments[5] -ne $script:Installed[$i]){
        throw 'Wrong CFG sent to Steam for selected profile.'
    }
}
$failed=$false
try {[void](Get-CS2SteamLaunchArguments -CfgName 'oli.cfg && powershell.exe')}catch{$failed=$true}
if(-not $failed){throw 'Invalid CFG name was accepted.'}
Write-Host 'PASS: Six Play + Exec buttons install the baseline first, preserve GitHub CFG priority, and send ordered one-time Steam exec arguments; normal Apply never edits Steam.'
