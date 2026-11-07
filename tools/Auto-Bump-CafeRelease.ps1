param(
    [Parameter(Mandatory=$true)]
    [string]$PreviousCommit,
    [Parameter(Mandatory=$true)]
    [string]$EventCommit,
    [switch]$DryRun
)

$ErrorActionPreference='Stop'
$global:LASTEXITCODE=0
$root=Split-Path -Parent $PSScriptRoot
$launcherPath=Join-Path $root 'cafe.bat'
$launcher=[IO.File]::ReadAllText($launcherPath)
$releasePattern='(?m)^# CAFE_RELEASE=(\d{4}\.\d{2}\.\d{2}\.\d+)[ \t]*\r?$'
$currentMatches=[regex]::Matches($launcher,$releasePattern)
if($currentMatches.Count -ne 1){throw 'Expected exactly one valid CAFE_RELEASE marker in cafe.bat.'}

function Get-CafeReleaseFromCommit {
    param([Parameter(Mandatory=$true)][string]$Commit)
    $commitLauncher=& git -C $root show ('{0}:cafe.bat' -f $Commit)
    if($LASTEXITCODE -ne 0){throw "Could not read cafe.bat from commit $Commit."}
    $commitText=[string]::Join("`n",[string[]]$commitLauncher)
    $commitMatches=[regex]::Matches($commitText,$releasePattern)
    if($commitMatches.Count -ne 1){throw "Commit $Commit does not contain exactly one valid CAFE_RELEASE marker."}
    return $commitMatches[0].Groups[1].Value
}

function Compare-CafeRelease {
    param([string]$Left,[string]$Right)
    $leftParts=$Left.Split('.');$rightParts=$Right.Split('.')
    $leftDate=[DateTime]::ParseExact(($leftParts[0..2] -join '.'),'yyyy.MM.dd',[Globalization.CultureInfo]::InvariantCulture)
    $rightDate=[DateTime]::ParseExact(($rightParts[0..2] -join '.'),'yyyy.MM.dd',[Globalization.CultureInfo]::InvariantCulture)
    if($leftDate -gt $rightDate){return 1}
    if($leftDate -lt $rightDate){return -1}
    return [Math]::Sign(([int]$leftParts[3]) - ([int]$rightParts[3]))
}

$currentRelease=$currentMatches[0].Groups[1].Value
if(-not [string]::IsNullOrWhiteSpace($PreviousCommit) -and -not [string]::IsNullOrWhiteSpace($EventCommit)){
    & git -C $root diff --quiet $PreviousCommit $EventCommit -- cafe.bat
    if($LASTEXITCODE -eq 0){$launcherChanged=$false}
    elseif($LASTEXITCODE -eq 1){$launcherChanged=$true}
    else{throw 'Could not determine whether cafe.bat changed in the push.'}
    $previousRelease=Get-CafeReleaseFromCommit -Commit $PreviousCommit
    $eventRelease=Get-CafeReleaseFromCommit -Commit $EventCommit
    $eventBumpedRelease=(-not $launcherChanged) -or ((Compare-CafeRelease -Left $eventRelease -Right $previousRelease) -gt 0)
    if(-not $launcherChanged){Write-Host 'cafe.bat did not change in this push; release marker will be preserved.'}
}else{
    $previousRelease=$currentRelease
    $eventRelease=$currentRelease
    $eventBumpedRelease=$true
    Write-Host 'No push range was supplied; preserving the current release marker.'
}

if(-not $eventBumpedRelease){
    $baseRelease=if((Compare-CafeRelease -Left $currentRelease -Right $previousRelease) -gt 0){$currentRelease}else{$previousRelease}
    $parts=$baseRelease.Split('.')
    $releaseDate=[DateTime]::ParseExact(($parts[0..2] -join '.'),'yyyy.MM.dd',[Globalization.CultureInfo]::InvariantCulture)
    $today=[DateTime]::UtcNow.Date
    if($releaseDate -lt $today){
        $nextRelease=$today.ToString('yyyy.MM.dd',[Globalization.CultureInfo]::InvariantCulture)+'.1'
    }else{
        $nextRelease=($parts[0..2] -join '.')+'.'+([int]$parts[3]+1)
    }

    if($DryRun){
        Write-Host ("Would bump CafeLauncher release from {0} to {1}." -f $baseRelease,$nextRelease)
    }else{
        $carriageReturn=if($launcher.Contains("`r`n")){"`r"}else{''}
        $updated=[regex]::Replace($launcher,$releasePattern,('# CAFE_RELEASE='+$nextRelease+$carriageReturn),1)
        [IO.File]::WriteAllText($launcherPath,$updated,(New-Object Text.UTF8Encoding($false)))
        Write-Host ("Bumped CafeLauncher release from {0} to {1}." -f $baseRelease,$nextRelease)
    }
}else{
    Write-Host ("The push already advanced CAFE_RELEASE from {0} to {1}; preserving {2}." -f $previousRelease,$eventRelease,$currentRelease)
}

if(-not $DryRun){
    & (Join-Path $PSScriptRoot 'Update-Context.ps1')
    if($LASTEXITCODE -ne 0){throw 'Could not refresh generated launcher release documentation.'}
}
$global:LASTEXITCODE=0
