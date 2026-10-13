# Windows PowerShell 5.1 regression: Play + Exec must launch CS2 with a
# one-time argument and MUST NOT edit Steam's localconfig.vdf.
# Uses mocked external operations; never starts Steam or modifies any files.
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
$names=@('Get-CS2SteamLaunchArguments','Start-CS2WithProfileCfg')
foreach($name in $names){
    $found=@($ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true) |
             Where-Object { $_.Name -eq $name })
    if($found.Count -ne 1){throw "Expected exactly one function: $name"}
    Invoke-Expression $found[0].Extent.Text
}
if($source -match '\b(Set-CS2SteamLaunchOptions|Update-CS2LaunchOptionsVdfText|Get-ActiveCS2SteamConfigPath)\b'){
    throw 'The old Steam launch-options file writer must be absent.'
}
$apply=$source.IndexOf('function Invoke-GamingProfile {',[StringComparison]::Ordinal)
$applyEnd=$source.IndexOf('function Get-CS2SteamLaunchArguments {',[StringComparison]::Ordinal)
if($apply -lt 0 -or $applyEnd -le $apply){throw 'Profile apply function missing.'}
$applyText=$source.Substring($apply,$applyEnd-$apply)
if($applyText -notmatch 'Install-AtCfg' -or $applyText -match '(?i)-applaunch|LaunchOptions|Set-CS2SteamLaunchOptions'){
    throw 'Normal profile application must only install the CFG, not modify Steam launch options.'
}
foreach($name in @('FabMode','ArliMode','BrileMode','ArmlMode','OliMode')){
    if($source -notmatch ('New-Tile "'+[regex]::Escape($name)+'"')){throw "Missing main tile: $name"}
}
if($source -notmatch '\$play\.Add_Click' -or $source -notmatch 'Start-CS2WithProfileCfg -ProfileName \$selectedProfile'){
    throw 'Missing independent Play + Exec profile button handler.'
}
$script:GamingProfiles=[ordered]@{
    FabMode=@{ConfigFile='fab.cfg';CfgDownloadUrl='https://raw.githubusercontent.com/fabjoncela/Cs-script/main/fab.cfg';CS2Sensitivity=''}
    ArliMode=@{ConfigFile='arli.cfg';CfgDownloadUrl='';CS2Sensitivity=''}
    BrileMode=@{ConfigFile='brile.cfg';CfgDownloadUrl='';CS2Sensitivity=''}
    ArmlMode=@{ConfigFile='arml.cfg';CfgDownloadUrl='';CS2Sensitivity=''}
    OliMode=@{ConfigFile='oli.cfg';CfgDownloadUrl='';CS2Sensitivity=''}
}
$script:FabCfgCloudUrl='https://raw.githubusercontent.com/fabjoncela/Cs-script/main/fab.cfg'
$script:Installed=@()
$script:Launched=@()
$script:ShouldInstall=$true
function Write-Log {param([string]$Message,[string]$Level='INFO')}
function Refresh-ProfileFromGitHub {param([string]$ProfileName)}
function Get-Process {[CmdletBinding()] param([string]$Name); return $null}
function Get-SteamExecutable {return 'C:\Dummy\Steam\steam.exe'}
function Install-AtCfg {
    param([switch]$Silent,[string]$CfgName,[string]$DownloadUrl,[switch]$CloudPreferred,[string]$CS2Sensitivity)
    $script:Installed+= $CfgName
    return $script:ShouldInstall
}
function Start-Process {
    [CmdletBinding()]
    param([string]$FilePath,[string[]]$ArgumentList)
    $script:Launched+= @{ FilePath=$FilePath; Arguments=@($ArgumentList) }
}
foreach($name in @('FabMode','ArliMode','BrileMode','ArmlMode','OliMode')){
    Start-CS2WithProfileCfg -ProfileName $name
}
if($script:Launched.Count -ne 5 -or $script:Installed.Count -ne 5){throw 'Expected exactly five installs and Steam launch requests.'}
foreach($launch in $script:Launched){
    if($launch.FilePath -ne 'C:\Dummy\Steam\steam.exe'){throw 'Incorrect Steam executable.'}
    if($launch.Arguments.Count -ne 4){throw 'Expected four Steam arguments.'}
    if($launch.Arguments[0] -ne '-applaunch' -or $launch.Arguments[1] -ne '730' -or $launch.Arguments[2] -ne '+exec'){
        throw 'Incorrect Steam app launch prefix.'
    }
}
for($i=0;$i -lt 5;$i++){
    if($script:Launched[$i].Arguments[3] -ne $script:Installed[$i]){
        throw 'Wrong CFG sent to Steam for selected profile.'
    }
}
$script:ShouldInstall=$false
Start-CS2WithProfileCfg -ProfileName 'FabMode'
if($script:Launched.Count -ne 5){throw 'CS2 was launched despite a failed CFG install.'}
$failed=$false
try {[void](Get-CS2SteamLaunchArguments -CfgName 'oli.cfg && powershell.exe')}catch{$failed=$true}
if(-not $failed){throw 'Invalid CFG name was accepted.'}
Write-Host 'PASS: Five Play + Exec buttons send correct one-time Steam arguments; normal Apply never edits Steam; failures do not launch CS2.'
