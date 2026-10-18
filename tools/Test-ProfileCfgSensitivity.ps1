# Windows PowerShell 5.1: every checked-in profile CFG must define one valid sensitivity.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$lines=[IO.File]::ReadAllLines((Join-Path $root 'cafe.bat'))
$marker=[Array]::IndexOf($lines,'# POWERSHELL_GUI')
if($marker -lt 0){throw 'Missing CafeLauncher PowerShell marker.'}
$source=[string]::Join([Environment]::NewLine,[string[]]$lines[($marker+1)..($lines.Length-1)])
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw ('Launcher syntax failed: '+$errors[0].Message)}
foreach($name in @('ConvertTo-CafeCS2Sensitivity','Get-CafeCS2CfgSensitivity')){
    $functions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)|Where-Object {$_.Name -eq $name})
    if($functions.Count -ne 1){throw ('Missing or duplicate CFG sensitivity function: '+$name)}
    Invoke-Expression $functions[0].Extent.Text
}
function Assert-True {param([bool]$Value,[string]$Message);if(-not $Value){throw $Message}}

$expected=[ordered]@{'fab.cfg'='1.2';'arli.cfg'='1';'arml.cfg'='1';'brile.cfg'='1.2';'oli.cfg'='1.2'}
foreach($cfgName in $expected.Keys){
    $path=Join-Path $root $cfgName
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw ('Missing profile CFG: '+$cfgName)}
    $content=[IO.File]::ReadAllText($path)
    $sensitivity=Get-CafeCS2CfgSensitivity -Content $content
    Assert-True ($sensitivity -ceq $expected[$cfgName]) ($cfgName+' sensitivity changed unexpectedly: '+$sensitivity)
}
foreach($invalid in @('', ('bind "r" "+reload"'+"`n"), ('sensitivity "1"'+"`n"+'sensitivity "2"'+"`n"), ('sensitivity "0"'+"`n"), ('sensitivity "20.1"'+"`n"), ('sensitivity'+"`n"), ('sensitivity nope'+"`n"))){
    $failed=$false
    try{[void](Get-CafeCS2CfgSensitivity -Content $invalid)}catch{$failed=$true}
    Assert-True $failed ('Invalid profile CFG sensitivity was accepted: '+$invalid)
}

$export=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Export-ProfileValues'},$true)|Select-Object -First 1)
$import=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Import-ProfileValues'},$true)|Select-Object -First 1)
$install=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Install-ProfileCfg'},$true)|Select-Object -First 1)
if($export.Count -ne 1 -or $export[0].Extent.Text -match 'CS2Sensitivity'){throw 'Profile export must not write the retired JSON sensitivity field.'}
if($import.Count -ne 1 -or $import[0].Extent.Text -match "'CS2Sensitivity'"){throw 'Profile import must ignore the retired JSON sensitivity field.'}
if($install.Count -ne 1 -or $install[0].Extent.Text -notmatch 'Get-CafeCS2CfgSensitivity' -or $install[0].Extent.Text -match '\$CS2Sensitivity'){
    throw 'Profile CFG install must validate and use its own sensitivity without a JSON override.'
}
if($source -match 'Install-ProfileCfg[^\r\n]*-CS2Sensitivity'){throw 'A profile Apply call still passes a JSON sensitivity override to Install-ProfileCfg.'}
foreach($profileJson in @(Get-ChildItem -LiteralPath (Join-Path $root 'profiles') -Filter '*.json' -File)){
    $profile=Get-Content -LiteralPath $profileJson.FullName -Raw|ConvertFrom-Json -ErrorAction Stop
    if($profile.PSObject.Properties['CS2Sensitivity']){throw ($profileJson.Name+' still contains legacy CS2Sensitivity.')}
}
Write-Host 'Profile CFG sensitivity tests passed.'
