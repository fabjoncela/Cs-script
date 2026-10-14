# Windows PowerShell 5.1 smoke test for the real Save-ProfileSettings code and
# the GetNewClosure pending-sync scope regression. No GUI or GPU changes.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$lines=[IO.File]::ReadAllLines((Join-Path (Split-Path -Parent $PSScriptRoot) 'cafe.bat'))
$marker=[Array]::IndexOf($lines,'# POWERSHELL_GUI')
if($marker -lt 0){throw 'Missing PowerShell marker.'}
$code=[string]::Join([Environment]::NewLine,[string[]]$lines[($marker+1)..($lines.Length-1)])
$t=$null;$err=$null
$ast=[System.Management.Automation.Language.Parser]::ParseInput($code,[ref]$t,[ref]$err)
if(@($err).Count){throw 'Launcher has syntax errors.'}
$confirm=@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true) | Where-Object {$_.Name -eq 'Confirm-LocalProfileApply'})
if($confirm.Count -ne 1 -or $confirm[0].Extent.Text -notmatch "'YesNo','Warning','Button2'"){
    throw 'Local profile fallback must require an explicit Yes confirmation with No as the default.'
}
$apply=@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true) | Where-Object {$_.Name -eq 'Invoke-GamingProfile'})
if($apply.Count -ne 1 -or $apply[0].Extent.Text -notmatch '(?s)Refresh-ProfileFromGitHub.*?Confirm-LocalProfileApply.*?\{return\}.*?Clear-RunOutcomes'){
    throw 'Profile Apply must confirm local fallback before starting or clearing run state.'
}
$a=$code.IndexOf('function Show-ProfileEditor {',[StringComparison]::Ordinal)
$b=$code.IndexOf('function Invoke-GamingProfile {',[StringComparison]::Ordinal)
if($a -lt 0 -or $b -le $a){throw 'Editor function not found.'}
$editor=$code.Substring($a,$b-$a)
$c=$editor.IndexOf('$saveEditorValues = {',[StringComparison]::Ordinal)
if($c -lt 0){throw 'Editor save closure not found.'}
$handlers=$editor.Substring($c)
if($handlers -match '\$script:PendingSync\s*\['){throw 'BUG: script-scoped PendingSync in captured click closure.'}
if($editor -notmatch '\$pendingSyncState\s*=\s*\$script:PendingSync'){throw 'Missing captured pending-sync hashtable.'}
if([regex]::Matches($handlers,'\$pendingSyncState\s*\[\s*\$ProfileName\s*\]').Count -ne 2){
    throw 'Both local save and GitHub sync must update captured pending-sync state.'
}
foreach($name in @('Export-ProfileValues','Save-ProfileSettings')){
    $found=@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true) | Where-Object { $_.Name -eq $name })
    if($found.Count -ne 1){throw "Expected one $name definition."}
    Invoke-Expression $found[0].Extent.Text
}
function Write-Log {param([string]$Message,[string]$Level='INFO');Write-Host $Message}
$p=@{PointerSpeed=10;LogitechDPI=800;DisableAcceleration=$true;ApplyNvidia=$true;Width=1920;Height=1080;RefreshHz=360;Vibrance=75;Hue=-1;ScalingMode=2;CS2Sensitivity='';CfgDownloadUrl='';LaunchApps=$true}
$script:GamingProfiles=[ordered]@{FabMode=$p.Clone();OliMode=$p.Clone()}
$script:PendingSync=@{FabMode=$false;OliMode=$false}
$script:VerifiedProfileState=@{OliMode=@{BlobSha=('a'*40);CommitSha=('b'*40)}}
$script:GraphicsPresets=[ordered]@{OliMode=[pscustomobject]@{SchemaVersion=1;ProfileName='OliMode';RefreshPolicy='Highest';ScalingMode=2;Settings=[ordered]@{Width=1280;Height=960;MSAASamples=8}}}
$folder=Join-Path $env:TEMP ('CafeLauncher-SaveTest-'+[guid]::NewGuid().ToString('N'))
$script:ProfileSettingsPath=Join-Path $folder 'profiles.json'
function Test-CapturedSave {
    param([string]$ProfileName,[bool]$Pending)
    $pendingSyncState=$script:PendingSync
    $handler={
        $pendingSyncState[$ProfileName]=$Pending
    }.GetNewClosure()
    # The captured handler checks state binding; persistence itself runs in
    # the test script scope to avoid PowerShell dynamic-module function lookup.
    & $handler
    Save-ProfileSettings
}
try {
    Test-CapturedSave 'OliMode' $true
    $result=Get-Content -LiteralPath $script:ProfileSettingsPath -Raw | ConvertFrom-Json
    if($result.OliMode.SyncPending -ne $true -or $result.OliMode.PointerSpeed -ne 10 -or $result.OliMode.LogitechDPI -ne 800 -or $result.OliMode.GraphicsSettings.Settings.MSAASamples -ne 8 -or $result.OliMode.GitHubVerifiedProfileSha -ne $script:VerifiedProfileState['OliMode'].BlobSha -or $result.OliMode.GitHubVerifiedCommitSha -ne $script:VerifiedProfileState['OliMode'].CommitSha){throw 'Local save did not persist profile, CS2 graphics, and verified GitHub version metadata.'}
    $script:GamingProfiles['OliMode']['LogitechDPI']=1600
    Test-CapturedSave 'OliMode' $false
    $result=Get-Content -LiteralPath $script:ProfileSettingsPath -Raw | ConvertFrom-Json
    if($result.OliMode.SyncPending -ne $false -or $result.OliMode.LogitechDPI -ne 1600){throw 'Synced-state save or edited DPI did not persist.'}
    Write-Host 'PASS: captured profile editor save state and JSON persistence.'
}finally{Remove-Item -LiteralPath $folder -Force -Recurse -ErrorAction SilentlyContinue}
