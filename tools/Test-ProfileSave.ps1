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
$p=@{PointerSpeed=10;DisableAcceleration=$true;ApplyNvidia=$true;Width=1920;Height=1080;RefreshHz=360;Vibrance=75;CS2Sensitivity='';CfgDownloadUrl='';LaunchApps=$true}
$script:GamingProfiles=[ordered]@{FabMode=$p.Clone();OliMode=$p.Clone()}
$script:PendingSync=@{FabMode=$false;OliMode=$false}
$folder=Join-Path $env:TEMP ('CafeLauncher-SaveTest-'+[guid]::NewGuid().ToString('N'))
$script:ProfileSettingsPath=Join-Path $folder 'profiles.json'
function Test-CapturedSave {
    param([string]$ProfileName,[bool]$Pending)
    $pendingSyncState=$script:PendingSync
    $handler={
        $pendingSyncState[$ProfileName]=$Pending
        Save-ProfileSettings
    }.GetNewClosure()
    & $handler
}
try {
    Test-CapturedSave 'OliMode' $true
    $result=Get-Content -LiteralPath $script:ProfileSettingsPath -Raw | ConvertFrom-Json
    if($result.OliMode.SyncPending -ne $true -or $result.OliMode.PointerSpeed -ne 10){throw 'Local save did not persist expected JSON.'}
    Test-CapturedSave 'OliMode' $false
    $result=Get-Content -LiteralPath $script:ProfileSettingsPath -Raw | ConvertFrom-Json
    if($result.OliMode.SyncPending -ne $false){throw 'Synced-state save did not persist.'}
    Write-Host 'PASS: captured profile editor save state and JSON persistence.'
}finally{Remove-Item -LiteralPath $folder -Force -Recurse -ErrorAction SilentlyContinue}
