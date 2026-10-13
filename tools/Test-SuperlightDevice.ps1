# Windows PowerShell 5.1: Superlight model selection behavior without real hardware.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$lines=[IO.File]::ReadAllLines((Join-Path (Split-Path -Parent $PSScriptRoot) 'cafe.bat'))
$marker=[Array]::IndexOf($lines,'# POWERSHELL_GUI')
$src=[string]::Join([Environment]::NewLine,[string[]]$lines[($marker+1)..($lines.Length-1)])
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($src,[ref]$t,[ref]$e)
if(@($e).Count){throw 'Launcher parse failed'}
$defs=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
$select=@($defs | Where-Object Name -eq 'Select-SuperlightDevice')
if($select.Count -ne 1){throw 'Superlight selector function not found'}
Invoke-Expression $select[0].Extent.Text
function Test-Select([string]$Model,[int]$Index){
    $json=@(@{index=0;type='receiver';model_id=$null;display_name='receiver';status='ok'},
            @{index=$Index;type='wireless device';model_id=$Model;display_name='PRO X SUPERLIGHT';status='ok'}) | ConvertTo-Json
    $v=Select-SuperlightDevice -Json $json
    if($v.Index -ne $Index -or $v.Model -ne $Model){throw "Wrong selected mouse $Model"}
}
Test-Select 'pro_x_wireless_mouse' 3
Test-Select 'pro_x_2_wireless_mouse' 8
# A switched-off Superlight 1 keeps its pairing record but reports unreachable.
$twoDongles=@(
    @{index=1;type='receiver';model_id=$null;status='connected'},
    @{index=2;type='wireless device';model_id='pro_x_wireless_mouse';display_name='PRO X SUPERLIGHT';status='unreachable: HID++ timeout'},
    @{index=3;type='receiver';model_id=$null;status='connected'},
    @{index=4;type='wireless device';model_id='pro_x_2_wireless_mouse';display_name='PRO X SUPERLIGHT 2';status='connected'}
) | ConvertTo-Json
$active=Select-SuperlightDevice -Json $twoDongles
if($active.Index -ne 4 -or $active.Model -ne 'pro_x_2_wireless_mouse'){
    throw 'Powered-off Superlight 1 dongle must not block active Superlight 2.'
}
try {
    $off=@(@{index=2;type='wireless device';model_id='pro_x_wireless_mouse';display_name='PRO X SUPERLIGHT';status='unreachable: HID++ timeout'}) | ConvertTo-Json
    [void](Select-SuperlightDevice -Json $off)
    throw 'Powered-off mouse should not be selected'
}catch{if($_.Exception.Message -notmatch 'No supported'){throw}}

try {
    [void](Select-SuperlightDevice -Json ((@(
        @{index=1;type='wireless device';model_id='pro_x_wireless_mouse';display_name='PRO X SUPERLIGHT';status='ok'},
        @{index=2;type='wireless device';model_id='pro_x_2_wireless_mouse';display_name='PRO X SUPERLIGHT 2';status='ok'}
    )) | ConvertTo-Json))
    throw 'Expected refusal for two connected mice'
}catch{
    if($_.Exception.Message -notmatch 'Multiple Superlight'){throw}
}
try {
    [void](Select-SuperlightDevice -Json '[{"index":1,"type":"direct device","model_id":"g305","display_name":"G305","status":"ok"}]')
    throw 'Expected refusal for unsupported model'
}catch{
    if($_.Exception.Message -notmatch 'No supported'){throw}
}
foreach($functionName in @('Set-LogitechLiveDPI','Set-LogitechOnboardDPI')){
    $def=@($defs | Where-Object Name -eq $functionName)
    if($def.Count -ne 1 -or $def[0].Extent.Text -notmatch 'Get-SelectedSuperlight' -or
       $def[0].Extent.Text -notmatch "'--device'"){
        throw "$functionName must target only selected device"
    }
}
if($src -notmatch '(?m)^# New-Tile "Set DPI 800 \(Onboard\)" 19'){throw 'Onboard UI must remain disabled.'}
Write-Host 'PASS: Superlight 1/2 recognition, explicit indexes, multiple-device refusal and disabled onboard button.'
