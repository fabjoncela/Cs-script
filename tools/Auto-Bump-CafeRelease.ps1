param(
    [Parameter(Mandatory=$true)]
    [string]$PreviousCommit,
    [switch]$DryRun
)

$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$launcherPath=Join-Path $root 'cafe.bat'
$launcher=[IO.File]::ReadAllText($launcherPath)
$releasePattern='(?m)^# CAFE_RELEASE=(\d{4}\.\d{2}\.\d{2}\.\d+)[ \t]*\r?$'
$currentMatches=[regex]::Matches($launcher,$releasePattern)
if($currentMatches.Count -ne 1){throw 'Expected exactly one valid CAFE_RELEASE marker in cafe.bat.'}

$previousSpec='{0}:cafe.bat' -f $PreviousCommit
$previousLines=& git -C $root show $previousSpec
if($LASTEXITCODE -ne 0){throw "Could not read cafe.bat from previous commit $PreviousCommit."}
$previousLauncher=[string]::Join("`n",[string[]]$previousLines)
$previousMatches=[regex]::Matches($previousLauncher,$releasePattern)
if($previousMatches.Count -ne 1){throw "Previous commit $PreviousCommit does not contain exactly one valid CAFE_RELEASE marker."}

$currentRelease=$currentMatches[0].Groups[1].Value
$previousRelease=$previousMatches[0].Groups[1].Value
if($currentRelease -ceq $previousRelease){
    $parts=$currentRelease.Split('.')
    $releaseDate=[DateTime]::ParseExact(($parts[0..2] -join '.'),'yyyy.MM.dd',[Globalization.CultureInfo]::InvariantCulture)
    $today=[DateTime]::UtcNow.Date
    if($releaseDate -lt $today){
        $nextRelease=$today.ToString('yyyy.MM.dd',[Globalization.CultureInfo]::InvariantCulture)+'.1'
    }else{
        $nextRelease=($parts[0..2] -join '.')+'.'+([int]$parts[3]+1)
    }

    if($DryRun){
        Write-Host ("Would bump CafeLauncher release from {0} to {1}." -f $currentRelease,$nextRelease)
    }else{
        $updated=[regex]::Replace($launcher,$releasePattern,('# CAFE_RELEASE='+$nextRelease),1)
        [IO.File]::WriteAllText($launcherPath,$updated,(New-Object Text.UTF8Encoding($false)))
        Write-Host ("Bumped CafeLauncher release from {0} to {1}." -f $currentRelease,$nextRelease)
    }
}else{
    Write-Host ("CAFE_RELEASE already changed from {0} to {1}; preserving the supplied version." -f $previousRelease,$currentRelease)
}

if(-not $DryRun){
    & (Join-Path $PSScriptRoot 'Update-Context.ps1')
    if($LASTEXITCODE -ne 0){throw 'Could not refresh generated launcher release documentation.'}
}
