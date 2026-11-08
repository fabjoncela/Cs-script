# Profile + CFG history parsing, validation, and restore staging. No live API writes.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
$root=Split-Path -Parent $PSScriptRoot
$sourcePath=Join-Path $root 'cafe.bat'
$lines=[IO.File]::ReadAllLines($sourcePath)
$marker=[Array]::IndexOf($lines,'# POWERSHELL_GUI')
if($marker -lt 0){throw 'Launcher PowerShell marker not found.'}
$source=[string]::Join([Environment]::NewLine,[string[]]$lines[($marker+1)..($lines.Length-1)])
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw ('Launcher syntax error: '+$errors[0].Message)}
$needed=@('ConvertTo-CafeCS2Sensitivity','Get-CafeCS2CfgSensitivity','ConvertTo-CafeGraphicsPreset',
    'Assert-CafeCloudSnapshot','ConvertFrom-CafeCloudJson','ConvertFrom-CafeBackendProfileHistory',
    'Get-CafeBackendProfileHistoryRevision','Set-CafeProfileHistoryUi','Get-CafeBackendCfgBase')
foreach($name in $needed){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    if(-not $node){throw ('Missing profile history helper: '+$name)}
    . ([scriptblock]::Create($node.Extent.Text))
}
$workerNode=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-CafeProfileHistoryWorker'},$true)
if(-not $workerNode){throw 'Profile history background worker was not found.'}
$workerMatch=[regex]::Match($workerNode.Extent.Text,"(?s)Add-Type -Language CSharp -TypeDefinition @'\r?\n(.*?)\r?\n'@")
if(-not $workerMatch.Success){throw 'Profile history C# worker source was not found.'}
Add-Type -Language CSharp -TypeDefinition $workerMatch.Groups[1].Value
$timingStart=[Func[string,string,string,long]]{param($type,$name,$uri) 1L}
$timingComplete=[Action[long,string,int]]{param($id,$outcome,$status) }
$worker=[CafeProfileHistoryBackgroundWorker]::new($timingStart,$timingComplete)
if($worker.RequestContext -ne $null -or $worker.HttpStatusCode -ne 0){throw 'Profile history worker must expose request context and HTTP status before a request.'}
$worker.Dispose()
$editor=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-ProfileEditor'},$true)
if(-not $editor){throw 'Profile editor source was not found.'}
$editorText=$editor.Extent.Text
foreach($required in @(
    'Profile + CFG history',
    ' -Grid $cs2Grid -Title ''Profile + CFG history''',
    'history?limit=50',
    '$restoreProfileHistory.Add_Click({',
    '$pendingProfileCfgRestoreState[$ProfileName]=[string]$profileHistoryRestoreState.Snapshot.Cfg',
    'graphics stay unchanged'
)){
    if(-not $editorText.Contains($required)){throw ('Profile History editor wiring is missing: '+$required)}
}
$restoreStart=$editorText.IndexOf('$restoreProfileHistory.Add_Click({',[StringComparison]::Ordinal)
$restoreEnd=$editorText.IndexOf('}.GetNewClosure())',$restoreStart,[StringComparison]::Ordinal)
if($restoreStart -lt 0 -or $restoreEnd -le $restoreStart){throw 'Cannot isolate the profile-history restore handler.'}
$restoreText=$editorText.Substring($restoreStart,$restoreEnd-$restoreStart)
if($restoreText -match '\$graphicsPresetState\[|\$gameWidth\.Value\s*=|\$gameHeight\.Value\s*='){
    throw 'Profile and CFG history restore must not change the CS2 graphics preset.'
}

$script:GamingProfiles=[ordered]@{FabMode=[pscustomobject]@{ConfigFile='fab.cfg';ScalingMode=2}}
$script:BackendBaseUrl='https://fabjon-hp.tail681ec9.ts.net:10000'
$script:PendingProfileCfgRestore=@{}
$script:LastHistoryUri=$null
$script:HistoryDetail=$null
function Get-CafeHttpBytes {
    param([string]$Uri,[int]$MaxBytes)
    $script:LastHistoryUri=$Uri
    $bytes=[Text.Encoding]::UTF8.GetBytes($script:HistoryDetail)
    if($bytes.Length -gt $MaxBytes){throw 'test fixture too large'}
    return [pscustomobject]@{Bytes=$bytes;Headers=@{}}
}

$history=[pscustomobject]@{profile='FabMode';hasMore=$false;revisions=@(
    [pscustomobject]@{revision=9;createdUtc='2026-11-08T12:00:00Z'},
    [pscustomobject]@{revision=8;createdUtc='2026-11-07T12:00:00Z'},
    [pscustomobject]@{revision=7;createdUtc='2026-11-06T12:00:00Z'}
)}|ConvertTo-Json -Depth 5
$versions=@(ConvertFrom-CafeBackendProfileHistory -ProfileName FabMode -ResponseJson $history)
if($versions.Count -ne 2 -or $versions[0].Revision -ne 8 -or $versions[1].Revision -ne 7 -or
   $versions[0].Message -ne 'Backend revision 8'){
    throw 'Profile history must omit the latest save and return earlier profile/CFG revisions newest first.'
}
$bad=$history|ConvertFrom-Json;$bad.revisions[2].revision=10
$rejected=$false
try{[void](ConvertFrom-CafeBackendProfileHistory -ProfileName FabMode -ResponseJson ($bad|ConvertTo-Json -Depth 5))}catch{$rejected=$true}
if(-not $rejected){throw 'Out-of-order profile history revisions must be rejected.'}
$wrong=$history|ConvertFrom-Json;$wrong.profile='OtherMode'
$rejected=$false
try{[void](ConvertFrom-CafeBackendProfileHistory -ProfileName FabMode -ResponseJson ($wrong|ConvertTo-Json -Depth 5))}catch{$rejected=$true}
if(-not $rejected){throw 'History for another profile must be rejected.'}

$profile=[pscustomobject]@{
    SchemaVersion=1;ProfileName='FabMode';PointerSpeed=10;LogitechDPI=800;DisableAcceleration=$true;ApplyNvidia=$true
    Width=1920;Height=1080;RefreshHz=360;Vibrance=75;Hue=-1;ScalingMode=2;VoicePushToTalkKey='V'
    CfgDownloadUrl='/v1/cfg/fab.cfg';LaunchApps=$true;LaunchWebsiteEnabled=$true;LaunchWebsiteUrl='https://metastack.gg/'
}
$graphics=[pscustomobject]@{
    SchemaVersion=1;ProfileName='FabMode';DisplayPolicy='ApplyPreset';RefreshPolicy='Highest';ScalingMode=2
    Settings=[pscustomobject]@{
        Width=1280;Height=960;AspectRatioMode=0;Fullscreen=1;MSAASamples=8;ShadowQuality=0;DynamicShadows=1
        TextureDetail=1;ShaderQuality=0;ParticleDetail=0;AmbientOcclusion=0;HDRDetail=3;NvidiaReflex=2
        TextureFiltering=0;FSRDetail=0;VSync=0;CMAA=0
    }
}
$cfg='// older saved config' + "`r`n" + 'sensitivity "1.25"' + "`r`n" + 'bind "SPACE" "+jump"' + "`r`n"
$script:HistoryDetail=[pscustomobject]@{revision=8;createdUtc='2026-11-07T12:00:00Z';profile=$profile;graphics=$graphics;cfg=$cfg}|ConvertTo-Json -Depth 9
$snapshot=Get-CafeBackendProfileHistoryRevision -ProfileName FabMode -Revision 8
if($snapshot.Revision -ne 8 -or $snapshot.Cfg -cne $cfg -or $snapshot.CfgSensitivity -cne '1.25' -or
   $snapshot.Profile.ProfileName -cne 'FabMode'){
    throw 'Historical detail must return a validated matching profile, graphics, and CFG snapshot.'
}
if($script:LastHistoryUri -cne ($script:BackendBaseUrl+'/v1/profiles/FabMode/history/8')){
    throw 'Historical detail must use the backend profile-history route.'
}
$script:HistoryDetail=([pscustomobject]@{revision=9;createdUtc='2026-11-08T12:00:00Z';profile=$profile;graphics=$graphics;cfg=$cfg}|ConvertTo-Json -Depth 9)
$rejected=$false
try{[void](Get-CafeBackendProfileHistoryRevision -ProfileName FabMode -Revision 8)}catch{$rejected=$true}
if(-not $rejected){throw 'A detail response with the wrong revision must be rejected.'}

$script:PendingProfileCfgRestore=@{}
$current=[pscustomobject]@{Cfg='sensitivity "1.5"' + "`n"}
if((Get-CafeBackendCfgBase -ProfileName FabMode -Snapshot $current) -cne $current.Cfg){throw 'Normal sync must use the current backend CFG.'}
$script:PendingProfileCfgRestore['FabMode']=$cfg
if((Get-CafeBackendCfgBase -ProfileName FabMode -Snapshot $current) -cne $cfg){throw 'A staged history restore must become the sync CFG base.'}
$script:PendingProfileCfgRestore['FabMode']='bad cfg'
$rejected=$false
try{[void](Get-CafeBackendCfgBase -ProfileName FabMode -Snapshot $current)}catch{$rejected=$true}
if(-not $rejected){throw 'An invalid staged history CFG must be rejected before sync.'}

$context=@{
    HistoryChoice=(New-Object System.Windows.Forms.ComboBox);LoadButton=(New-Object System.Windows.Forms.Button)
    RestoreButton=(New-Object System.Windows.Forms.Button);StatusLabel=(New-Object System.Windows.Forms.Label)
}
try{
    $context.HistoryChoice.Tag=[object[]]@()
    Set-CafeProfileHistoryUi -Context $context -Versions $versions
    if(-not $context.RestoreButton.Enabled -or $context.HistoryChoice.Items.Count -ne 2){throw 'History UI must list and enable restore for earlier profile/CFG saves.'}
    Set-CafeProfileHistoryUi -Context $context -ErrorMessage 'simulated backend outage'
    if($context.StatusLabel.Text -notmatch 'simulated backend outage' -or -not $context.LoadButton.Enabled -or
       -not $context.RestoreButton.Enabled -or $context.HistoryChoice.Items.Count -ne 2){
        throw 'A failed refresh must remain visible and retryable while preserving the last successfully loaded restore choices.'
    }
    Set-CafeProfileHistoryUi -Context $context -Versions @()
    if($context.RestoreButton.Enabled -or $context.HistoryChoice.Enabled -or $context.StatusLabel.Text -notmatch 'No earlier profile and CFG'){
        throw 'Empty history must disable restore and explain that there are no earlier saves.'
    }
}finally{
    $context.HistoryChoice.Dispose();$context.LoadButton.Dispose();$context.RestoreButton.Dispose();$context.StatusLabel.Dispose()
}
Write-Host 'PASS: profile/CFG history validation, backend-only detail loading, restore CFG staging, and retry UI.'
