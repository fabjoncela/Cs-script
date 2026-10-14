# Compile the real NVAPI helper without calling NVAPI or changing display settings.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$lines=[IO.File]::ReadAllLines((Join-Path $root 'cafe.bat'))
$code=[string]::Join([Environment]::NewLine,[string[]]$lines)
$classMarker=$code.IndexOf('if (-not ("FabNvApi" -as [type])) {',[StringComparison]::Ordinal)
if($classMarker -lt 0){throw 'FabNvApi Add-Type block not found.'}
$addStart=$code.IndexOf('Add-Type -ErrorAction Stop @"',$classMarker,[StringComparison]::Ordinal)
if($addStart -lt 0){throw 'FabNvApi Add-Type declaration not found.'}
$bodyStart=$code.IndexOf([Environment]::NewLine,$addStart,[StringComparison]::Ordinal)+[Environment]::NewLine.Length
$bodyEnd=$code.IndexOf('"@',$bodyStart,[StringComparison]::Ordinal)
if($bodyStart -lt [Environment]::NewLine.Length -or $bodyEnd -le $bodyStart){throw 'FabNvApi C# source block is incomplete.'}
$source=$code.Substring($bodyStart,$bodyEnd-$bodyStart)
foreach($required in @(
    'Resolve<NvApiGetDvcInfo>(0x4085DE45)',
    'Resolve<NvApiSetDvcLevel>(0x172409B4)',
    'TrySetDigitalVibranceLegacy(GetDisplayHandle(), percentage, out legacyReport)',
    'getInfo(handle, 0, ref verify)',
    'verify.currentLevel != requested'
)){
    if($source -notmatch [regex]::Escape($required)){throw ('Legacy DVC fallback contract missing: '+$required)}
}
Add-Type -TypeDefinition $source -ErrorAction Stop
foreach($test in @(
    @{Percent=0;Min=[uint32]0;Max=[uint32]63;Expected=[uint32]0},
    @{Percent=50;Min=[uint32]0;Max=[uint32]63;Expected=[uint32]32},
    @{Percent=75;Min=[uint32]0;Max=[uint32]63;Expected=[uint32]47},
    @{Percent=100;Min=[uint32]0;Max=[uint32]63;Expected=[uint32]63},
    @{Percent=75;Min=[uint32]10;Max=[uint32]50;Expected=[uint32]40}
)){
    $actual=[FabNvApi]::MapLegacyDvcPercentage($test.Percent,$test.Min,$test.Max)
    if($actual -ne $test.Expected){throw ("Legacy mapping failed for {0}% in {1}-{2}: got {3}, expected {4}." -f $test.Percent,$test.Min,$test.Max,$actual,$test.Expected)}
}
foreach($invalid in @(
    @{Percent=-1;Min=[uint32]0;Max=[uint32]63},
    @{Percent=101;Min=[uint32]0;Max=[uint32]63},
    @{Percent=50;Min=[uint32]5;Max=[uint32]5}
)){
    $failed=$false
    try{[void][FabNvApi]::MapLegacyDvcPercentage($invalid.Percent,$invalid.Min,$invalid.Max)}catch{$failed=$true}
    if(-not $failed){throw 'Invalid legacy DVC percentage/range was accepted.'}
}
Write-Host 'PASS: legacy DVC fallback queries and verifies the driver value; percentage mapping handles quantized and non-zero ranges without touching hardware.'
