[CmdletBinding()]
param(
    [string]$BackendRepository = '',
    [string]$BaseUrl = 'https://fabjon-hp.tail681ec9.ts.net:10000',
    [string]$ReleaseNotes = 'Web action ready launcher with shared action cores and verified local caches.',
    [switch]$PreflightOnly
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($BackendRepository)) {
    $BackendRepository = Join-Path (Split-Path -Parent $repoRoot) 'CafeLauncherBackend'
}
$launcherPath = Join-Path $repoRoot 'cafe.bat'
$graphicsPath = Join-Path $repoRoot 'graphics\ApplyGraphics.ps1'
$publisherPath = Join-Path $BackendRepository 'publish.py'
$expectedGraphicsBlob = 'b6fa5619e13df559b40c02cd8a11d9d7cd99d7e8'

function Get-GitBlobShaFromBytes {
    param([byte[]]$Bytes)
    $header = [Text.Encoding]::ASCII.GetBytes("blob $($Bytes.Length)`0")
    $stream = New-Object IO.MemoryStream
    $sha1 = [Security.Cryptography.SHA1]::Create()
    try {
        $stream.Write($header, 0, $header.Length)
        $stream.Write($Bytes, 0, $Bytes.Length)
        return ([BitConverter]::ToString($sha1.ComputeHash($stream.ToArray())) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha1.Dispose()
        $stream.Dispose()
    }
}

function Get-Sha256FromBytes {
    param([byte[]]$Bytes)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha256.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() }
    finally { $sha256.Dispose() }
}

function ConvertTo-GitTextBytes {
    param([byte[]]$Bytes)
    $stream = New-Object IO.MemoryStream
    try {
        for ($index = 0; $index -lt $Bytes.Length; $index++) {
            if ($Bytes[$index] -eq 13 -and $index + 1 -lt $Bytes.Length -and $Bytes[$index + 1] -eq 10) {
                $stream.WriteByte(10)
                $index++
            } else {
                $stream.WriteByte($Bytes[$index])
            }
        }
        return ,$stream.ToArray()
    } finally { $stream.Dispose() }
}

function Assert-BackendPublishToken {
    param([string]$Origin,[string]$Version,[string]$Token)
    $request = [Net.HttpWebRequest]::Create($Origin.TrimEnd('/') + "/v1/admin/releases/$Version/launcher")
    $request.Method = 'PUT'
    $request.ContentType = 'application/octet-stream'
    $request.Headers.Add('Authorization', 'Bearer ' + $Token)
    $request.ContentLength = 1
    $stream = $request.GetRequestStream()
    try { $stream.WriteByte(0) } finally { $stream.Dispose() }
    try {
        $response = [Net.HttpWebResponse]$request.GetResponse()
        try { throw "Unexpected successful response to the non-publishing token check (HTTP $([int]$response.StatusCode))." }
        finally { $response.Dispose() }
    } catch [Net.WebException] {
        $response = $_.Exception.Response
        if (-not $response) { throw 'Could not verify the backend publishing token over HTTPS.' }
        try {
            $status = [int]$response.StatusCode
            $reader = New-Object IO.StreamReader($response.GetResponseStream())
            try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
            if ($status -eq 401) { throw 'The backend rejected this publishing token (HTTP 401). Check that you used the CafeLauncher backend publishing token.' }
            if ($status -ne 422 -or $body -notmatch 'launcher_asset_too_small') {
                throw "The backend token check returned HTTP $status instead of its expected safe size rejection."
            }
        } finally { $response.Dispose() }
    }
}

foreach ($path in @($launcherPath, $graphicsPath, $publisherPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required release file was not found: $path"
    }
}

$launcherBytes = [IO.File]::ReadAllBytes($launcherPath)
if ($launcherBytes.Length -lt 10000 -or $launcherBytes.Length -gt 1000000) {
    throw "Launcher size is outside the backend's supported range: $($launcherBytes.Length) bytes."
}
$launcherText = [Text.Encoding]::UTF8.GetString($launcherBytes)
$releaseMarkers = [regex]::Matches($launcherText, '(?m)^# CAFE_RELEASE=(\d{4}\.\d{1,2}\.\d{1,2}\.\d+)\s*$')
if ($releaseMarkers.Count -ne 1) { throw 'Expected exactly one valid CAFE_RELEASE marker.' }
$version = $releaseMarkers[0].Groups[1].Value
foreach ($entryPoint in @('Invoke-CafeWebApplyProfile', 'Invoke-CafeWebApplyGraphics', 'Invoke-CafeWebPlayExec')) {
    if ($launcherText -notmatch ('function\s+' + [regex]::Escape($entryPoint) + '\b')) {
        throw "Launcher release $version is missing the $entryPoint web action."
    }
}
if ($launcherText -notmatch 'CAFE_WEB_ACTION') { throw 'Launcher web action dispatch marker was not found.' }

$graphicsBytes = ConvertTo-GitTextBytes -Bytes ([IO.File]::ReadAllBytes($graphicsPath))
$graphicsBlob = Get-GitBlobShaFromBytes -Bytes $graphicsBytes
if ($graphicsBlob -cne $expectedGraphicsBlob) {
    throw "The graphics module does not match CafeLauncher's reviewed pin ($expectedGraphicsBlob)."
}
$launcherSha256 = Get-Sha256FromBytes -Bytes $launcherBytes
$graphicsSha256 = Get-Sha256FromBytes -Bytes $graphicsBytes

$latest = Invoke-RestMethod -Uri ($BaseUrl.TrimEnd('/') + '/v1/releases/latest') -Method Get -TimeoutSec 15
$latestVersion = [string]$latest.version
if ($latestVersion) {
    $candidateParts = @($version.Split('.') | ForEach-Object { [int]$_ })
    $latestParts = @($latestVersion.Split('.') | ForEach-Object { [int]$_ })
    $comparison = 0
    for ($index = 0; $index -lt [Math]::Max($candidateParts.Count, $latestParts.Count); $index++) {
        $candidatePart = if ($index -lt $candidateParts.Count) { $candidateParts[$index] } else { 0 }
        $latestPart = if ($index -lt $latestParts.Count) { $latestParts[$index] } else { 0 }
        if ($candidatePart -gt $latestPart) { $comparison = 1; break }
        if ($candidatePart -lt $latestPart) { $comparison = -1; break }
    }
    if ($comparison -lt 0) {
        throw "Launcher version $version is older than the backend's latest release $latestVersion."
    }
    if ($comparison -eq 0) {
        $existing = Invoke-RestMethod -Uri ($BaseUrl.TrimEnd('/') + "/v1/releases/$version/manifest") -Method Get -TimeoutSec 15
        if ([string]$existing.artifacts.launcher.sha256 -eq $launcherSha256 -and
            [int]$existing.artifacts.launcher.size -eq $launcherBytes.Length -and
            [string]$existing.artifacts.graphicsModule.sha256 -eq $graphicsSha256) {
            Write-Host "Backend release $version already contains these exact files."
            exit 0
        }
        throw "Launcher version $version already exists with different files; increment CAFE_RELEASE before publishing."
    }
}

$branch = (& git -C $repoRoot branch --show-current 2>$null).Trim()
if ($LASTEXITCODE -ne 0) { $branch = '(branch unavailable)' }
$dirtyFiles = @(& git -C $repoRoot status --short 2>$null)
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the launcher worktree before publishing.' }
Write-Host ''
Write-Host "Launcher release: $version"
Write-Host "Branch:           $branch"
Write-Host "Backend latest:   $(if ($latestVersion) { $latestVersion } else { '(none)' })"
Write-Host "Launcher size:    $($launcherBytes.Length) bytes"
Write-Host "Launcher SHA-256: $launcherSha256"
Write-Host "Graphics blob:    $graphicsBlob (verified)"
Write-Host "Graphics SHA-256: $graphicsSha256"
Write-Host "Working tree:     $(if ($dirtyFiles.Count) { "$($dirtyFiles.Count) changed file(s)" } else { 'clean' })"
Write-Host "Backend:          $BaseUrl"
Write-Host ''
if ($PreflightOnly) {
    Write-Host 'Preflight passed; no upload was performed.'
    exit 0
}
if ((Read-Host "Type PUBLISH to upload release $version") -cne 'PUBLISH') {
    Write-Host 'Upload canceled.'
    exit 0
}

$oldToken = $env:CAFELAUNCHER_PUBLISH_TOKEN
$secureToken = $null
$tokenPointer = [IntPtr]::Zero
$stagingRoot = Join-Path $env:TEMP ('CafeLauncher-WebRelease-' + [guid]::NewGuid().ToString('N'))
$tokenWasPrompted = [string]::IsNullOrWhiteSpace($oldToken)
try {
    [void](New-Item -ItemType Directory -Path $stagingRoot -Force)
    $stagedLauncherPath = Join-Path $stagingRoot 'cafe.bat'
    $stagedGraphicsPath = Join-Path $stagingRoot 'ApplyGraphics.ps1'
    [IO.File]::WriteAllBytes($stagedLauncherPath, $launcherBytes)
    [IO.File]::WriteAllBytes($stagedGraphicsPath, $graphicsBytes)
    if ((Get-Sha256FromBytes -Bytes ([IO.File]::ReadAllBytes($stagedLauncherPath))) -cne $launcherSha256 -or
        (Get-GitBlobShaFromBytes -Bytes ([IO.File]::ReadAllBytes($stagedGraphicsPath))) -cne $expectedGraphicsBlob) {
        throw 'Staged release files did not match the preflight hashes.'
    }
    if ($tokenWasPrompted) {
        $secureToken = Read-Host 'Backend publishing token' -AsSecureString
        if (-not $secureToken -or $secureToken.Length -lt 32) {
            throw 'The publishing token must contain at least 32 characters.'
        }
        $tokenPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
        $env:CAFELAUNCHER_PUBLISH_TOKEN = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPointer)
    } elseif ($oldToken.Length -lt 32) {
        throw 'CAFELAUNCHER_PUBLISH_TOKEN must contain at least 32 characters.'
    }

    Assert-BackendPublishToken -Origin $BaseUrl -Version $version -Token $env:CAFELAUNCHER_PUBLISH_TOKEN
    Write-Host 'Publishing token accepted; the one-byte probe was rejected before any file could be stored.'

    $python = Get-Command python.exe -ErrorAction Stop
    & $python.Source $publisherPath release `
        --base-url $BaseUrl `
        --version $version `
        --launcher $stagedLauncherPath `
        --graphics-module $stagedGraphicsPath `
        --release-notes $ReleaseNotes
    if ($LASTEXITCODE -ne 0) { throw "Backend release publisher failed with exit code $LASTEXITCODE." }

    $published = Invoke-RestMethod -Uri ($BaseUrl.TrimEnd('/') + "/v1/releases/$version/manifest") -Method Get -TimeoutSec 15
    if ([string]$published.version -cne $version -or
        [string]$published.artifacts.launcher.sha256 -cne $launcherSha256 -or
        [int]$published.artifacts.launcher.size -ne $launcherBytes.Length -or
        [string]$published.artifacts.graphicsModule.sha256 -cne $graphicsSha256) {
        throw 'Backend read-back manifest did not match the launcher and pinned graphics module.'
    }
    Write-Host "Verified backend release $version. The web runner will use this cached, hash-verified launcher package."
}
finally {
    if ($tokenPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPointer)
    }
    if ($tokenWasPrompted) { $env:CAFELAUNCHER_PUBLISH_TOKEN = $oldToken }
    if ($secureToken) { $secureToken.Dispose() }
    if (Test-Path -LiteralPath $stagingRoot -PathType Container) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}
