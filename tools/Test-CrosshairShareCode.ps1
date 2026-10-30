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
Add-Type -AssemblyName System.Drawing
foreach($name in @('ConvertFrom-CafeCS2CrosshairShareCode','Get-CafeCS2ConvarGroup','Set-CafeCapturedConvarsInCfg','Set-CafeProfileCrosshairImportStage','ConvertTo-CafeCS2CrosshairPreviewModel','New-CafeCS2StaticQuadrantRaster','Draw-CafeCS2CrosshairPreview')){
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

# Preview mapping uses the decoder output and validates display-only values.
$staticPreviewValues=@{};foreach($key in $current.Values.Keys){$staticPreviewValues[$key]=$current.Values[$key]};$staticPreviewValues['cl_crosshairdot']='0'
$previewModel=ConvertTo-CafeCS2CrosshairPreviewModel -Values $staticPreviewValues
Assert-True ($previewModel.Style -eq 2 -and $previewModel.Length -eq 5 -and $previewModel.Gap -eq 0) 'Current share-code values mapped incorrectly to the preview model.'
Assert-True ($previewModel.Color.R -eq 255 -and $previewModel.Color.G -eq 0 -and $previewModel.Color.B -eq 0 -and $previewModel.Color.A -eq 255) 'Current share-code color/alpha mapped incorrectly.'
Assert-True ($previewModel.SourceHeight -ge 240 -and $previewModel.Warnings.Count -eq 0) 'Current source-resolution data was not preserved for preview scaling.'
$colorValues=@{};foreach($key in $staticPreviewValues.Keys){$colorValues[$key]=$staticPreviewValues[$key]};$colorValues['cl_crosshaircolor_r']='0';$colorValues['cl_crosshaircolor_g']='128';$colorValues['cl_crosshaircolor_b']='255';$colorValues['cl_crosshaircolor_a']='96'
$colorModel=ConvertTo-CafeCS2CrosshairPreviewModel -Values $colorValues
Assert-True ($colorModel.Color.R -eq 0 -and $colorModel.Color.G -eq 128 -and $colorModel.Color.B -eq 255 -and $colorModel.Color.A -eq 96) 'The preview did not preserve unusual color and alpha values.'
$invalidAlphaValues=@{};foreach($key in $staticPreviewValues.Keys){$invalidAlphaValues[$key]=$staticPreviewValues[$key]};$invalidAlphaValues['cl_crosshaircolor_a']='256'
$invalidAlphaRejected=$false
try{[void](ConvertTo-CafeCS2CrosshairPreviewModel -Values $invalidAlphaValues)}catch{$invalidAlphaRejected=$_.Exception.Message -match 'invalid cl_crosshaircolor_a'}
Assert-True $invalidAlphaRejected 'The preview accepted out-of-range alpha.'
$missingPreviewField=$false
$incompleteValues=@{};foreach($key in $staticPreviewValues.Keys){$incompleteValues[$key]=$staticPreviewValues[$key]};$incompleteValues.Remove('cl_crosshair_length')
try{[void](ConvertTo-CafeCS2CrosshairPreviewModel -Values $incompleteValues)}catch{$missingPreviewField=$_.Exception.Message -match 'missing cl_crosshair_length'}
Assert-True $missingPreviewField 'The preview silently accepted a missing required length value.'
$badPreviewField=$false
$invalidValues=@{};foreach($key in $staticPreviewValues.Keys){$invalidValues[$key]=$staticPreviewValues[$key]};$invalidValues['cl_crosshair_length']='256'
try{[void](ConvertTo-CafeCS2CrosshairPreviewModel -Values $invalidValues)}catch{$badPreviewField=$_.Exception.Message -match 'invalid cl_crosshair_length'}
Assert-True $badPreviewField 'The preview accepted an out-of-range length value.'
$fractionalStyleRejected=$false
$fractionalStyleValues=@{};foreach($key in $staticPreviewValues.Keys){$fractionalStyleValues[$key]=$staticPreviewValues[$key]};$fractionalStyleValues['cl_crosshairstyle']='2.5'
try{[void](ConvertTo-CafeCS2CrosshairPreviewModel -Values $fractionalStyleValues)}catch{$fractionalStyleRejected=$_.Exception.Message -match 'invalid cl_crosshairstyle'}
Assert-True $fractionalStyleRejected 'The preview rounded a fractional crosshair style instead of rejecting it.'

# The built-in GDI renderer draws the expected color, respects a pixel gap, and honors T-shape.
$bitmap=[System.Drawing.Bitmap]::new(320,220)
$graphics=[System.Drawing.Graphics]::FromImage($bitmap)
try{
    $gapValues=@{};foreach($key in $staticPreviewValues.Keys){$gapValues[$key]=$staticPreviewValues[$key]};$gapValues['cl_crosshair_gap']='3'
    $gapModel=ConvertTo-CafeCS2CrosshairPreviewModel -Values $gapValues
    Draw-CafeCS2CrosshairPreview -Graphics $graphics -Bounds ([System.Drawing.Rectangle]::new(0,0,320,220)) -Model $gapModel -Background Dark
    Assert-True ($bitmap.GetPixel(200,110).R -eq 255) 'The preview renderer did not draw the expected crosshair arm.'
    Assert-True ($bitmap.GetPixel(160,110).R -ne 255) 'The preview renderer filled the center gap unexpectedly.'
    $tValues=@{};foreach($key in $current.Values.Keys){$tValues[$key]=$current.Values[$key]};$tValues['cl_crosshair_t']='1'
    $tModel=ConvertTo-CafeCS2CrosshairPreviewModel -Values $tValues
    Draw-CafeCS2CrosshairPreview -Graphics $graphics -Bounds ([System.Drawing.Rectangle]::new(0,0,320,220)) -Model $tModel -Background Foliage
    Assert-True ($bitmap.GetPixel(160,60).R -lt 200) 'The preview renderer drew the upper arm for a T-shaped crosshair.'
}finally{$graphics.Dispose();$bitmap.Dispose()}

# Static Quadrant uses short diagonal arcs and a square center dot.
$quadrant=ConvertFrom-CafeCS2CrosshairShareCode 'CShaXdKBo9S7q5HVUqoW2JvcJodRzmSaGBFN7TTUr6OVPH'
$quadrantModel=ConvertTo-CafeCS2CrosshairPreviewModel -Values $quadrant.Values
Assert-True ($quadrantModel.Style -eq 9 -and [Math]::Abs($quadrantModel.QuadrantSize-0.15) -lt 0.001 -and $quadrantModel.Dot) 'Static Quadrant settings were not mapped from the decoded code.'
$incompleteQuadrant=@{};foreach($key in $quadrant.Values.Keys){$incompleteQuadrant[$key]=$quadrant.Values[$key]};$incompleteQuadrant.Remove('cl_crosshair_dynamic_maxdist_splitratio')
$missingQuadrantRejected=$false
try{[void](ConvertTo-CafeCS2CrosshairPreviewModel -Values $incompleteQuadrant)}catch{$missingQuadrantRejected=$_.Exception.Message -match 'missing cl_crosshair_dynamic_maxdist_splitratio'}
Assert-True $missingQuadrantRejected 'Static Quadrant silently guessed a missing size ratio.'
$bitmap=[System.Drawing.Bitmap]::new(320,220)
$graphics=[System.Drawing.Graphics]::FromImage($bitmap)
try{
    Draw-CafeCS2CrosshairPreview -Graphics $graphics -Bounds ([System.Drawing.Rectangle]::new(0,0,320,220)) -Model $quadrantModel -Background Dark
    Assert-True ($bitmap.GetPixel(160,110).R -gt 200) 'Static Quadrant lost its center dot.'
    Assert-True ($bitmap.GetPixel(138,88).B -gt 200) 'Static Quadrant did not draw a diagonal arc.'
    Assert-True ($bitmap.GetPixel(160,80).R -eq 42) 'Static Quadrant incorrectly drew a vertical cross arm.'
    Assert-True ($bitmap.GetPixel(100,50).R -eq 42) 'Static Quadrant incorrectly used crosshair length as its arc radius.'
    # 16x16 native pixels checked against crosshair.club's public
    # September 30, 2026 CS2 shader reconstruction on the stone background.
    $native=New-CafeCS2StaticQuadrantRaster -Model $quadrantModel -BackgroundColor ([System.Drawing.Color]::FromArgb(183,170,164))
    try{
        Assert-True ($native.Width -eq 16 -and $native.Height -eq 16) 'Static Quadrant raster has the wrong native pixel size.'
        $rgba=New-Object byte[] ($native.Width*$native.Height*4)
        for($y=0;$y -lt $native.Height;$y++){for($x=0;$x -lt $native.Width;$x++){
            $pixel=$native.GetPixel($x,$y);$index=($y*$native.Width+$x)*4
            $rgba[$index]=[byte]$pixel.R;$rgba[$index+1]=[byte]$pixel.G;$rgba[$index+2]=[byte]$pixel.B;$rgba[$index+3]=[byte]$pixel.A
        }}
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$hash=[BitConverter]::ToString($sha.ComputeHash($rgba)).Replace('-','')}finally{$sha.Dispose()}
        Assert-True ($hash -eq '4A18C35AE2BCAF09835CCBA044278D0FA385702254CB540B80E5AB97C8E6AAD6') 'Static Quadrant native pixels differ from the shader reference.'
    }finally{$native.Dispose()}
    $wideValues=@{};foreach($key in $quadrant.Values.Keys){$wideValues[$key]=$quadrant.Values[$key]};$wideValues['cl_crosshair_dynamic_maxdist_splitratio']='1'
    $wideModel=ConvertTo-CafeCS2CrosshairPreviewModel -Values $wideValues
    Draw-CafeCS2CrosshairPreview -Graphics $graphics -Bounds ([System.Drawing.Rectangle]::new(0,0,320,220)) -Model $wideModel -Background Dark
    Assert-True ($bitmap.GetPixel(160,80).R -ne 42) 'Quadrant size had no effect on the rendered shape.'
    $longValues=@{};foreach($key in $quadrant.Values.Keys){$longValues[$key]=$quadrant.Values[$key]};$longValues['cl_crosshair_length']='100'
    $longModel=ConvertTo-CafeCS2CrosshairPreviewModel -Values $longValues
    Draw-CafeCS2CrosshairPreview -Graphics $graphics -Bounds ([System.Drawing.Rectangle]::new(0,0,320,220)) -Model $longModel -Background Dark
    Assert-True ($bitmap.GetPixel(100,50).R -eq 42) 'Static Quadrant length unexpectedly changed its arc radius.'
    $dynamicValues=@{};foreach($key in $quadrant.Values.Keys){$dynamicValues[$key]=$quadrant.Values[$key]};$dynamicValues['cl_crosshairstyle']='7'
    $dynamicModel=ConvertTo-CafeCS2CrosshairPreviewModel -Values $dynamicValues
    Draw-CafeCS2CrosshairPreview -Graphics $graphics -Bounds ([System.Drawing.Rectangle]::new(0,0,320,220)) -Model $dynamicModel -Background Dark
    Assert-True ($bitmap.GetPixel(185,110).B -gt 200) 'Dynamic Quadrant at rest should draw a straight cross arm.'
}finally{$graphics.Dispose();$bitmap.Dispose()}

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
$legacyPreview=$null
$previousCulture=[Threading.Thread]::CurrentThread.CurrentCulture
try{[Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('fr-FR');$legacyPreview=ConvertTo-CafeCS2CrosshairPreviewModel -Values $legacyV1.Values}finally{[Threading.Thread]::CurrentThread.CurrentCulture=$previousCulture}
Assert-True ($legacyPreview.Length -eq 3.5 -and $legacyPreview.Gap -eq -1 -and ($legacyPreview.Warnings -join ' ') -match 'no source resolution' -and ($legacyPreview.Warnings -join ' ') -match 'Negative gaps') 'Legacy fractional values or preview limitation notes were not handled invariantly.'

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

# Share-code import overlays decoded settings while preserving other staged profile settings.
$script:GamingProfiles=@{FabMode=@{};ArliMode=@{}}
$stages=@{FabMode=@{sensitivity='1.7';viewmodel_fov='68';cl_crosshair_gap='77'};ArliMode=@{sensitivity='1.4';cl_crosshair_gap='-2'}}
$otherProfileBefore=@{};foreach($key in $stages['ArliMode'].Keys){$otherProfileBefore[$key]=$stages['ArliMode'][$key]}
$staged=Set-CafeProfileCrosshairImportStage -ProfileName FabMode -Values $current.Values -State $stages
Assert-True ($stages['FabMode']['sensitivity'] -ceq '1.7') 'Crosshair import discarded the selected profile sensitivity.'
Assert-True ($stages['FabMode']['viewmodel_fov'] -ceq '68') 'Crosshair import discarded a previously staged Extras setting.'
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
    'Show-CafeCS2CrosshairPreviewDialog -Decoded $decoded -ProfileName $ProfileName',
    'Set-CafeProfileCrosshairImportStage -ProfileName $ProfileName',
    '$capturedCS2ConvarsState'
)){
    Assert-True ($editor.Extent.Text.Contains($required)) ('Crosshair import UI contract is missing: '+$required)
}
if($editor.Extent.Text.IndexOf('Show-CafeCS2CrosshairPreviewDialog -Decoded $decoded') -gt $editor.Extent.Text.IndexOf('Set-CafeProfileCrosshairImportStage -ProfileName $ProfileName')){throw 'Crosshair import staging must occur only after the visual preview dialog.'}
$previewDialog=$ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-CafeCS2CrosshairPreviewDialog'},$true)|Select-Object -First 1
foreach($required in @('$heading.Dock=''None''','$backgroundLabel.Dock=''None''','$note.Dock=''None''')){
    Assert-True ($previewDialog.Extent.Text.Contains($required)) ('Crosshair preview layout must keep fixed-position labels undocked: '+$required)
}
if($ast.Extent.Text -notmatch 'Add_Paint\(\$paintPreview\)' -or $ast.Extent.Text -notmatch 'System\.Drawing\.Graphics'){throw 'Crosshair visual preview must use the WinForms paint event and built-in System.Drawing renderer.'}

Write-Host 'PASS: legacy-v1/v3/v4 and current CS2 share-code decode, preview model/rendering, scope-dot CFG sync, and selected-profile staging.'
