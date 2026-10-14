# Mocked GitHub graphics-history test. No network, UI, Steam, or CS2 writes.
class HistoryTestHttpException : System.Exception {
    [object]$Response
    HistoryTestHttpException([int]$Status) : base(('HTTP '+$Status)) {
        $this.Response=[pscustomobject]@{StatusCode=$Status}
    }
}
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$lines=[IO.File]::ReadAllLines((Join-Path $root 'cafe.bat'))
$marker=[Array]::IndexOf($lines,'# POWERSHELL_GUI')
if($marker -lt 0){throw 'Launcher PowerShell marker not found.'}
$source=[string]::Join([Environment]::NewLine,[string[]]$lines[($marker+1)..($lines.Length-1)])
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw ('Launcher syntax error: '+$errors[0].Message)}
$functions=@{}
foreach($node in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
    $functions[$node.Name]=$node.Extent.Text
}
foreach($name in @('ConvertTo-CafeGraphicsPreset','ConvertTo-CafeGraphicsHistoryEntry','Clear-ProfileGraphicsHistoryCache','Get-CachedProfileGraphicsHistory','Get-ProfileGraphicsHistory','Get-ProfileGraphicsVersion')){
    if(-not $functions.ContainsKey($name)){throw ('Missing graphics history function '+$name)}
    Invoke-Expression $functions[$name]
}
function Write-Log {param([string]$Message,[string]$Level='INFO')}
$script:GamingProfiles=[ordered]@{}
foreach($name in @('FabMode','OliMode','ArliMode')){
    $script:GamingProfiles[$name]=@{ScalingMode=2}
}
$script:GithubRepo='fabjoncela/Cs-script'
$script:GithubBranch='main'
$script:HistoryCommitCalls=0
$script:HistoryContentCalls=0
$script:HistoryWrongPath=$false
$script:HistoryOffline=$false
$script:HistoryGone=$false
$currentPreset=Get-Content -LiteralPath (Join-Path $root 'graphics\FabMode.json') -Raw | ConvertFrom-Json
$oldPreset=$currentPreset | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$oldPreset.Settings.MSAASamples=4
$oldJson=$oldPreset | ConvertTo-Json -Depth 8
$script:HistoryBase64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($oldJson))
function New-TestCommit {
    param([string]$Sha,[string]$Message,[string]$Date)
    return [pscustomobject]@{sha=$Sha;commit=[pscustomobject]@{
        message=$Message;author=[pscustomobject]@{date=$Date};committer=[pscustomobject]@{date=$Date}
    }}
}
function Invoke-RestMethod {
    param([string]$Uri,[string]$Method,[hashtable]$Headers,[int]$TimeoutSec,[string]$ErrorAction)
    if($script:HistoryOffline){throw 'mock network unavailable'}
    if($Uri -match '/commits\?'){
        $script:HistoryCommitCalls++
        if($Uri -notmatch 'path=graphics%2F(FabMode|OliMode|ArliMode).json' -or $Uri -notmatch 'per_page=4' -or $Uri -notmatch 'sha=main'){
            throw ('Unexpected history request URI: '+$Uri)
        }
        return @(
            (New-TestCommit ('1'*40) 'Current graphics' '2026-10-14T10:00:00Z'),
            (New-TestCommit ('2'*40) 'Prior settings B' '2026-10-13T10:00:00Z'),
            (New-TestCommit ('3'*40) 'Prior settings A' '2026-10-12T10:00:00Z'),
            (New-TestCommit ('4'*40) 'Oldest shown' '2026-10-11T10:00:00Z')
        )
    }
    if($Uri -match '/contents/'){
        $script:HistoryContentCalls++
        if($script:HistoryGone){throw (New-Object HistoryTestHttpException 404)}
        if($script:HistoryWrongPath){return [pscustomobject]@{path='graphics/OliMode.json';content=$script:HistoryBase64}}
        if($Uri -notmatch ('ref='+('2'*40))){throw ('Unexpected content ref: '+$Uri)}
        return [pscustomobject]@{path='graphics/FabMode.json';content=$script:HistoryBase64}
    }
    throw ('Unexpected mock request URI: '+$Uri)
}
$oldLocalAppData=$env:LOCALAPPDATA
$sandbox=Join-Path $env:TEMP ('CafeLauncher-GraphicsHistory-'+[guid]::NewGuid().ToString('N'))
$env:LOCALAPPDATA=$sandbox
try{
    $versions=@(Get-ProfileGraphicsHistory -ProfileName 'FabMode')
    if($script:HistoryCommitCalls -ne 1 -or $versions.Count -ne 3){throw 'History must request GitHub once and show only the three versions before current.'}
    if($versions[0].Sha -ne ('2'*40) -or $versions[2].Sha -ne ('4'*40) -or $versions[0].Message -ne 'Prior settings B'){
        throw 'History ordering, current-version exclusion, or commit labels are incorrect.'
    }
    [void](Get-ProfileGraphicsHistory -ProfileName 'FabMode')
    if($script:HistoryCommitCalls -ne 1){throw 'Fresh history cache should avoid another API call.'}
    [void](Get-ProfileGraphicsHistory -ProfileName 'FabMode' -ForceRefresh)
    if($script:HistoryCommitCalls -ne 2){throw 'Force refresh must request a fresh GitHub history list.'}

    $cache=Join-Path $sandbox 'CafeLauncher\graphics-history\FabMode.json'
    $cached=Get-Content -LiteralPath $cache -Raw|ConvertFrom-Json
    $cached.CachedAtUtc=[DateTimeOffset]::UtcNow.AddDays(-2).ToString('o')
    [IO.File]::WriteAllText($cache,($cached|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
    [void](Get-ProfileGraphicsHistory -ProfileName 'FabMode')
    if($script:HistoryCommitCalls -ne 3){throw 'Expired history cache must be refreshed.'}
    $otherProfileVersions=@(Get-ProfileGraphicsHistory -ProfileName 'OliMode')
    if($otherProfileVersions.Count -ne 3 -or $script:HistoryCommitCalls -ne 4){throw 'Each profile must keep an independent history cache.'}
    [void](Get-ProfileGraphicsHistory -ProfileName 'FabMode')
    if($script:HistoryCommitCalls -ne 4){throw 'Refreshing one profile must not invalidate another profile cache.'}

    $restored=Get-ProfileGraphicsVersion -ProfileName 'FabMode' -Version $versions[0]
    if($script:HistoryContentCalls -ne 1 -or [int]$restored.Settings.MSAASamples -ne 4){
        throw 'Selected historical file was not fetched and validated correctly.'
    }
    $invalidSha=$false
    try{[void](Get-ProfileGraphicsVersion -ProfileName 'FabMode' -Version ([pscustomobject]@{Sha='bad'}))}catch{$invalidSha=$true}
    if(-not $invalidSha -or $script:HistoryContentCalls -ne 1){throw 'Invalid commit IDs must be rejected before requesting content.'}

    $wrongPath=$false
    $script:HistoryWrongPath=$true
    try{[void](Get-ProfileGraphicsVersion -ProfileName 'FabMode' -Version $versions[0])}catch{$wrongPath=$_.Exception.Message -match 'different graphics profile file'}
    if(-not $wrongPath){throw 'A response for a different profile must be rejected.'}

    $script:HistoryWrongPath=$false
    $script:HistoryGone=$true
    $goneMessage=''
    try{[void](Get-ProfileGraphicsVersion -ProfileName 'FabMode' -Version $versions[0])}catch{$goneMessage=$_.Exception.Message}
    if($goneMessage -notmatch 'no longer available.*Refresh history'){
        throw 'A deleted history commit must explain that it is unavailable and suggest refreshing history.'
    }
    $script:HistoryGone=$false

    if(-not (Test-Path -LiteralPath $cache -PathType Leaf)){throw 'Expected history cache before invalidation test.'}
    Clear-ProfileGraphicsHistoryCache -ProfileName 'FabMode'
    if(Test-Path -LiteralPath $cache -PathType Leaf){throw 'A successful graphics sync must be able to invalidate the cached history file.'}
    [void](Get-ProfileGraphicsHistory -ProfileName 'FabMode')
    if($script:HistoryCommitCalls -ne 5){throw 'History must refetch after its cache is invalidated.'}

    $script:HistoryWrongPath=$false
    $script:HistoryOffline=$true
    $cache=$null
    $offlineFailure=$false
    try{[void](Get-ProfileGraphicsHistory -ProfileName 'ArliMode')}catch{$offlineFailure=$_.Exception.Message -match 'network unavailable'}
    if(-not $offlineFailure){throw 'Unavailable GitHub history should fail clearly for the UI to report.'}
    if($source -notmatch 'Earlier GitHub file revisions \(commit ID shown\)' -or
       $source -notmatch 'Not saved or applied' -or $source -notmatch '\$version\.Sha\.Substring\(0,7\)'){
        throw 'History UI must identify commit revisions and make restore save/apply behavior explicit.'
    }
    Write-Host 'PASS: history caching/invalidation, prior commit fetch/validation, unavailable commit messaging, and explicit restore behavior.'
}finally{
    $env:LOCALAPPDATA=$oldLocalAppData
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
