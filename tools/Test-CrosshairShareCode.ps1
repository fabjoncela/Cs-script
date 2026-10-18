# Windows PowerShell 5.1: crosshair share-code decoder and selected-profile staging contract.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$bat=[IO.File]::ReadAllText((Join-Path $root 'cafe.bat'))
$marker=$bat.IndexOf('# POWERSHELL_GUI',[StringComparison]::Ordinal)
if($marker -lt 0){throw 'Missing CafeLauncher PowerShell marker.'}
$source=$bat.Substring($bat.IndexOf("`n",$marker)+1)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw ('Launcher PowerShell syntax failed: '+$errors[0].Message)}
foreach($name in @('ConvertFrom-CafeCS2CrosshairShareCode','Set-CafeCapturedConvarsInCfg','Set-CafeProfileCrosshairImportStage')){
    $matches=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
    if($matches.Count -ne 1){throw ('Missing or duplicate function: '+$name)}
    Invoke-Expression $matches[0].Extent.Text
}
function Assert-True {param([bool]$Value,[string]$Message);if(-not $Value){throw $Message}}
function New-LegacyFixtureCode {
    param([byte[]]$Bytes)
    $sum=0;for($i=1;$i -lt $Bytes.Length;$i++){$sum+=[int]$Bytes[$i]};$Bytes[0]=[byte]($sum -band 0xff)
    $little=New-Object byte[] ($Bytes.Length+1)
    for($i=0;$i -lt $Bytes.Length;$i++){$little[$Bytes.Length-1-$i]=$Bytes[$i]}
    $number=[Numerics.BigInteger]::new($little)
    $alphabet='ABCDEFGHJKLMNOPQRSTUVWXYZabcdefhijkmnopqrstuvwxyz23456789'
    $encoded=''
    while($number -gt [Numerics.BigInteger]::Zero){
        $remainder=[int][Numerics.BigInteger]::Remainder($number,[Numerics.BigInteger]57)
        $encoded+=$alphabet[$remainder]
        $number=[Numerics.BigInteger]::Divide($number,[Numerics.BigInteger]57)
    }
    $encoded=$encoded.PadRight(25,'A')
    return 'CSGO-'+$encoded.Substring(0,5)+'-'+$encoded.Substring(5,5)+'-'+$encoded.Substring(10,5)+'-'+$encoded.Substring(15,5)+'-'+$encoded.Substring(20,5)
}

# Maintainer-published cs2-v1 example.
$current=ConvertFrom-CafeCS2CrosshairShareCode 'CSvbPubOq37zTGqtsPTP5QTrp5CB4xFXiKRLfzJsm49ZRe'
Assert-True ($current.Format -ceq 'cs2-v1') 'Current CS2 format was not identified.'
foreach($expected in @{
    cl_crosshairstyle='2';cl_crosshair_gap='0';cl_crosshair_length='5';cl_crosshair_thickness='1'
    cl_crosshaircolor_r='255';cl_crosshaircolor_g='0';cl_crosshaircolor_b='0';cl_crosshaircolor_a='255'
    cl_crosshairoutline_a='255';cl_ironsight_dot_scale='1';cl_ironsight_usecrosshaircolor='0'
}.GetEnumerator()){
    Assert-True ($current.Values[$expected.Key] -ceq $expected.Value) ('Current code decoded the wrong '+$expected.Key+'.')
}
Assert-True ($current.Warnings.Count -eq 0) 'Valid current code produced an unexpected warning.'

# The exact CSGO-prefixed example the user supplied; it is a CS2-era legacy-v4 code.
$legacy=ConvertFrom-CafeCS2CrosshairShareCode 'CSGO-v6fV6-wZ3a8-rj4qS-6rDsY-JcP6H'
Assert-True ($legacy.Format -ceq 'legacy-v4') 'User CSGO code was not identified as legacy-v4.'
foreach($expected in @{
    cl_crosshair_drawoutline='2';cl_crosshairstyle='4';cl_crosshair_screen_height='1080'
    cl_crosshair_gap='3';cl_crosshair_length='3';cl_crosshair_thickness='1'
    cl_crosshaircolor_r='242';cl_crosshaircolor_g='0';cl_crosshaircolor_b='255'
}.GetEnumerator()){
    Assert-True ($legacy.Values[$expected.Key] -ceq $expected.Value) ('Legacy code decoded the wrong '+$expected.Key+'.')
}

# Older CS:GO-era legacy-v1 code: fractional sizing, alpha toggle and loss notes.
$v1=New-Object byte[] 18
$v1[1]=1;$v1[2]=246;$v1[3]=4;$v1[4]=10;$v1[5]=20;$v1[6]=30;$v1[7]=220
$v1[8]=131;$v1[9]=246;$v1[10]=93;$v1[11]=104;$v1[12]=15;$v1[13]=120;$v1[14]=35
$legacyV1=ConvertFrom-CafeCS2CrosshairShareCode (New-LegacyFixtureCode -Bytes $v1)
Assert-True ($legacyV1.Format -ceq 'legacy-v1') 'Legacy-v1 format was not identified.'
Assert-True ($legacyV1.Values['cl_crosshair_gap'] -ceq '-1') 'Legacy-v1 signed fractional gap decoded incorrectly.'
Assert-True ($legacyV1.Values['cl_crosshair_length'] -ceq '3.5') 'Legacy-v1 fractional length decoded incorrectly.'
Assert-True ($legacyV1.Values['cl_crosshaircolor_a'] -ceq '220') 'Legacy-v1 alpha toggle/value decoded incorrectly.'
Assert-True ($legacyV1.Warnings.Count -ge 2) 'Legacy-v1 limitations were not disclosed.'

# Legacy-v3 (pixel sizes and source resolution) gets its own format dispatch.
$v3=New-Object byte[] 18
$v3[1]=3;$v3[2]=247;$v3[3]=40;$v3[4]=50;$v3[5]=60;$v3[6]=200;$v3[7]=6;$v3[8]=8;$v3[9]=70
$bits=[long]12 -bor ([long]10 -shl 7) -bor ([long]4 -shl 12) -bor ([long]25 -shl 16) -bor ([long]2 -shl 23)
for($i=0;$i -lt 4;$i++){$v3[10+$i]=[byte](($bits -shr ($i*8)) -band 255)}
$v3[14]=192;$v3[15]=3
$legacyV3=ConvertFrom-CafeCS2CrosshairShareCode (New-LegacyFixtureCode -Bytes $v3)
Assert-True ($legacyV3.Format -ceq 'legacy-v3') 'Legacy-v3 format was not identified.'
Assert-True ($legacyV3.Values['cl_crosshair_screen_height'] -ceq '960') 'Legacy-v3 source resolution was not retained.'
Assert-True ($legacyV3.Values['cl_crosshair_drawoutline'] -ceq '1') 'Legacy-v3 outline flag was not converted.'

$badChecksum='CSvbPubOq37zTGqtsPTP5QTrp5CB4xFXiKRLfzJsm49ZRe'
$badChecksum=$badChecksum.Substring(0,$badChecksum.Length-1)+'A'
$failed=$false;try{[void](ConvertFrom-CafeCS2CrosshairShareCode $badChecksum)}catch{$failed=$_.Exception.Message -match 'checksum'}
Assert-True $failed 'A corrupted share-code checksum was accepted.'
$failed=$false;try{[void](ConvertFrom-CafeCS2CrosshairShareCode 'not-a-share-code')}catch{$failed=$true}
Assert-True $failed 'An unsupported share-code shape was accepted.'

# The CFG sync writer accepts the current scope-dot settings and keeps unrelated lines.
$lf=[string][char]10
$cfg=Set-CafeCapturedConvarsInCfg -Content ('bind "r" "+reload"'+$lf) -Values @{
    cl_ironsight_dot_scale='1.25';cl_ironsight_usecrosshaircolor='1';cl_grenadecrosshair_smoke='1'
}
Assert-True ($cfg.Contains('cl_ironsight_dot_scale "1.25"') -and $cfg.Contains('cl_ironsight_usecrosshaircolor "1"')) 'Current scope-dot settings were not written to the CFG.'
Assert-True (-not $cfg.Contains('cl_grenadecrosshair_smoke')) 'The CFG writer accepted an unrelated grenade crosshair command.'
Assert-True ($cfg.Contains('bind "r" "+reload"')) 'Import changed an unrelated bind.'

# Staging replaces only crosshair fields for the selected profile and preserves its sensitivity.
$script:GamingProfiles=@{FabMode=@{};ArliMode=@{}}
$stages=@{FabMode=@{sensitivity='1.7';cl_crosshair_gap='77'};ArliMode=@{sensitivity='1.4';cl_crosshair_gap='-2'}}
$otherProfileBefore=@{};foreach($key in $stages['ArliMode'].Keys){$otherProfileBefore[$key]=$stages['ArliMode'][$key]}
$staged=Set-CafeProfileCrosshairImportStage -ProfileName FabMode -Values $current.Values -State $stages
Assert-True ($stages['FabMode']['sensitivity'] -ceq '1.7') 'Crosshair import discarded the selected profile sensitivity.'
Assert-True (-not $stages['FabMode'].ContainsKey('cl_crosshair_gap') -or $stages['FabMode']['cl_crosshair_gap'] -cne '77') 'Crosshair import left the selected profile old crosshair value staged.'
foreach($key in $otherProfileBefore.Keys){Assert-True ($stages['ArliMode'][$key] -ceq $otherProfileBefore[$key]) 'Crosshair import changed another profile.'}
$failed=$false;try{[void](Set-CafeProfileCrosshairImportStage -ProfileName FabMode -Values @{cl_crosshair_gap='1;quit'} -State $stages)}catch{$failed=$true}
Assert-True $failed 'Staging accepted an unsafe share-code value.'

# UI wiring routes previewed values through the selected-profile staging helper.
$editor=$ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-ProfileEditor'},$true)|Select-Object -First 1
foreach($required in @(
    '$mouseGrid=New-EditorTabGrid -Page $mousePage -Rows 5',
    "'Paste a CS2 crosshair share code'",
    "'Preview & Import'",
    'Set-CafeProfileCrosshairImportStage -ProfileName $ProfileName',
    'Nothing is saved or synced until you choose Save & Sync',
    '$capturedCS2ConvarsState'
)){
    Assert-True ($editor.Extent.Text.Contains($required)) ('Crosshair import UI contract is missing: '+$required)
}

Write-Host 'PASS: legacy-v1/v3/v4 and current CS2 share-code decode, validation, scope-dot CFG sync, and selected-profile staging.'
