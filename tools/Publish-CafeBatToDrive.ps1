Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$repoRoot=Split-Path -Parent $PSScriptRoot
$eventPath=$env:GITHUB_EVENT_PATH
if($env:GITHUB_EVENT_NAME -eq 'push' -and $eventPath -and (Test-Path -LiteralPath $eventPath)){
    $event=Get-Content -LiteralPath $eventPath -Raw | ConvertFrom-Json
    $before=[string]$event.before
    if($before -and $before -notmatch '^0+$'){
        & git -C $repoRoot diff --quiet $before $env:GITHUB_SHA -- cafe.bat
        if($LASTEXITCODE -eq 0){Write-Host 'No cafe.bat change in this push; Drive upload skipped.'; exit 0}
        if($LASTEXITCODE -ne 1){throw 'Could not determine whether cafe.bat changed in this push.'}
    }
}

if([string]::IsNullOrWhiteSpace($env:DRIVE_SYNC_URL) -or [string]::IsNullOrWhiteSpace($env:DRIVE_SYNC_TOKEN)){
    throw 'Set the DRIVE_SYNC_URL and DRIVE_SYNC_TOKEN repository secrets before publishing cafe.bat.'
}

$batPath=Join-Path $repoRoot 'cafe.bat'
$content=[IO.File]::ReadAllText($batPath,[Text.Encoding]::UTF8)
$versionMatch=[regex]::Match($content,'(?m)^# CAFE_RELEASE=(\d{4}\.\d{2}\.\d{2}\.\d+)\s*$')
if(-not $versionMatch.Success){throw 'cafe.bat does not contain a valid CAFE_RELEASE marker.'}
$release=$versionMatch.Groups[1].Value
$payload=@{token=$env:DRIVE_SYNC_TOKEN;release=$release;content=$content} | ConvertTo-Json -Compress -Depth 3

$response=Invoke-RestMethod -Uri $env:DRIVE_SYNC_URL -Method Post -ContentType 'application/json; charset=utf-8' -Body $payload -TimeoutSec 60
$okProperty=$response.PSObject.Properties['ok']
$releaseProperty=$response.PSObject.Properties['release']
if($null -eq $okProperty -or $null -eq $releaseProperty){
    throw "Google Drive updater did not return its expected JSON response for release $release. Check the Apps Script execution log."
}
if(-not [bool]$okProperty.Value){
    $errorProperty=$response.PSObject.Properties['error']
    $detail=if($null -ne $errorProperty -and -not [string]::IsNullOrWhiteSpace([string]$errorProperty.Value)){
        [string]$errorProperty.Value
    } else {
        'The Apps Script endpoint rejected the upload without an error message.'
    }
    throw "Google Drive updater rejected release $release`: $detail"
}
if([string]$releaseProperty.Value -ne $release){
    throw "Google Drive updater returned a different release than $release."
}
Write-Host "Google Drive cafe.bat updated in place to release $release."
