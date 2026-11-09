# Read-only NVIDIA compatibility regression tests on Windows PowerShell 5.1.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$lines=[IO.File]::ReadAllLines((Join-Path (Split-Path -Parent $PSScriptRoot) 'cafe.bat'))
$marker=[Array]::IndexOf($lines,'# POWERSHELL_GUI')
if($marker -lt 0){throw 'Missing launcher marker.'}
$code=[string]::Join([Environment]::NewLine,[string[]]$lines[($marker+1)..($lines.Length-1)])
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($code,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw 'PowerShell parser reported errors.'}
$functions=@{}
foreach($f in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
    $functions[$f.Name]=$f.Extent.Text
}
foreach($name in @('Set-CafeStartupStatus','Get-NvidiaCompatibilityScan','Write-NvidiaCompatibilityScan','Apply-NvidiaGamingSettings','Set-CafePhysxAutoSelect','Get-PCDiagnostics','Invoke-GamingProfile','Import-ProfileValues')){
    if(-not $functions.ContainsKey($name)){throw ('Missing '+$name)}
}
$scanCode=$functions['Get-NvidiaCompatibilityScan']
$cafeSource=[IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'cafe.bat'))
$nvapiStart=$cafeSource.IndexOf('public static class FabNvApi {',[StringComparison]::Ordinal)
$nvapiEnd=$cafeSource.IndexOf('"@',[Math]::Max(0,$nvapiStart),[StringComparison]::Ordinal)
if($nvapiStart -lt 0 -or $nvapiEnd -le $nvapiStart){throw 'Could not locate the embedded NVAPI wrapper source.'}
$nvapiSource=$cafeSource.Substring($nvapiStart,$nvapiEnd-$nvapiStart)
if($nvapiSource -notmatch 'TryCheckNvApiSupport'){
    throw 'NVAPI wrapper must expose a real initialization probe.'
}
if($nvapiSource -notmatch '0x1057EB71' -or $nvapiSource -notmatch '0x00000001  // PREFERRED_PSTATE_PREFER_MAX' -or $nvapiSource -notmatch 'Power management mode = Prefer maximum performance'){
    throw 'Global DRS profile must request and verify Prefer maximum performance.'
}
foreach($required in @('0x1094F157','VRR_GLOBAL_FEATURE_DISABLED','G-SYNC global feature = off')){
    if(-not $nvapiSource.Contains($required)){throw ('Global DRS profile must disable and verify G-SYNC feature: '+$required)}
}
if($nvapiSource -match '0x10835000|0x0005F543'){
    throw 'Unsupported legacy Low Latency settings must not be retained in the NVAPI apply path.'
}
if($nvapiSource -notmatch 'Initialize\(out unload\)' -or
   $nvapiSource -notmatch 'finally\s*\{\s*if\s*\(initialized\s*&&\s*unload\s*!=\s*null\)' -or
   $nvapiSource -notmatch 'NvAPI_Initialize and NvAPI_Unload succeeded'){
    throw 'NVAPI initialization probe must balance a successful initialize with unload.'
}
if($scanCode -notmatch 'TryCheckNvApiSupport' -or
   $scanCode -match '\$result\.NVAPI\s*=.*\$apiFile'){
    throw 'Overall NVAPI availability must come from initialization, not DLL presence.'
}
foreach($required in @('Get-CimInstance Win32_VideoController','DriverVersion','IsAdvertisedMode','GetDisplayModesReport','nvapi64.dll','Get-StartApps','NVIDIA Control Panel')){
    if(-not $scanCode.Contains($required)){throw ('NVIDIA preflight missing '+$required)}
}
if($scanCode -notmatch 'TryCheckHueSupport' -or
   $scanCode -notmatch 'Hue settings will be skipped'){
    throw 'NVIDIA compatibility scan must preflight Hue support and report when it will be skipped.'
}
foreach($required in @('TryCheckDigitalVibranceSupport','TryCheckDriverProfileSupport','TryCheckGpuScalingSupport')){
    if(-not $scanCode.Contains($required)){throw ('NVIDIA capability scan missing '+$required)}
}
$apply=$functions['Apply-NvidiaGamingSettings']
if($apply -notmatch '\[ValidateRange\(0,359\)\]\[int\]\$Hue = 359' -or
   $apply -notmatch 'TrySetHueAngle\(\$Hue' -or
   $functions['Invoke-GamingProfile'] -notmatch 'Apply-NvidiaGamingSettings -Width.*?-Hue \(\[int\]\$profile\.Hue\)'){
    throw 'Profile Apply must pass a valid 0-359 Hue value to the verified NVAPI setter, with a 359-degree default.'
}
$profileDefaultsStart=$cafeSource.IndexOf('$script:GamingProfiles = [ordered]@{',[StringComparison]::Ordinal)
$profileDefaultsEnd=$cafeSource.IndexOf('$script:BackendBaseUrl =',[Math]::Max(0,$profileDefaultsStart),[StringComparison]::Ordinal)
if($profileDefaultsStart -lt 0 -or $profileDefaultsEnd -le $profileDefaultsStart -or
   [regex]::Matches($cafeSource.Substring($profileDefaultsStart,$profileDefaultsEnd-$profileDefaultsStart),'Vibrance=75; Hue=359').Count -ne 6 -or
   $cafeSource.Substring($profileDefaultsStart,$profileDefaultsEnd-$profileDefaultsStart) -notmatch 'RefreshHz=300; Vibrance=75; Hue=359'){
    throw 'All built-in profile defaults must request Hue 359 degrees.'
}
if($functions['Import-ProfileValues'] -notmatch '(?s)if\(\$value -eq -1\).*?\$value=359' -or
   $functions['Import-ProfileValues'] -notmatch 'if \(\$value -lt 0 -or \$value -gt 359\)'){
    throw 'Legacy profile Hue=-1 must migrate to 359 while other hue values remain limited to 0-359.'
}
Invoke-Expression $functions['Import-ProfileValues']
function Write-Log { param([string]$Message,[string]$Level='INFO') }
$script:GamingProfiles=[ordered]@{FabMode=@{Hue=0}}
Import-ProfileValues -ProfileName 'FabMode' -SavedProfile ([pscustomobject]@{Hue=-1}) -SourceLabel 'test'
if($script:GamingProfiles['FabMode'].Hue -ne 359){throw 'A legacy Hue=-1 profile was not migrated to 359.'}
Import-ProfileValues -ProfileName 'FabMode' -SavedProfile ([pscustomobject]@{Hue=45}) -SourceLabel 'test'
if($script:GamingProfiles['FabMode'].Hue -ne 45){throw 'A custom profile hue was changed during migration.'}
if($code -notmatch "-Title 'NVIDIA Hue \(degrees\)'.*-Min 0 -Max 359" -or
   $code -notmatch 'if\(\$historicalHue -eq -1\)\{\$historicalHue=359\}'){
    throw 'The profile and history editors must display the migrated hue in their 0-359 degree range.'
}
if(-not $apply.Contains('$gSyncFeatureVerified=$performanceReport -match') -or
   -not $apply.Contains("-Setting 'G-SYNC Control Panel checkbox'") -or
   -not $apply.Contains("-Status APPLIED -Actual 'Off; global G-SYNC feature flag persisted and verified'") -or
   -not $apply.Contains("-Status SKIPPED -Detail 'The global G-SYNC feature flag did not read back as Off")){
    throw 'G-SYNC result must report APPLIED after persisted read-back, and SKIPPED when unverified.'
}
if($functions['Set-CafePhysxAutoSelect'] -notmatch 'NvCplPhysxAuto' -or
   $functions['Set-CafePhysxAutoSelect'] -notmatch 'RegistryValueKind\]::DWord' -or
   $functions['Set-CafePhysxAutoSelect'] -notmatch 'SetValue\(\$name,\[int\]1' -or
   $functions['Set-CafePhysxAutoSelect'] -notmatch 'GetValue\(\$name' -or
   $functions['Set-CafePhysxAutoSelect'] -notmatch 'RunAs' -or
   $functions['Set-CafePhysxAutoSelect'] -notmatch 'GetRecommendedPhysxGpuId' -or
   $functions['Set-CafePhysxAutoSelect'] -notmatch 'NvAPI_GPU_CudaEnumComputeCapableGpus' -or
   $functions['Set-CafePhysxAutoSelect'] -notmatch 'NvAPI_GetGPUIDfromPhysicalGPU' -or
   $functions['Set-CafePhysxAutoSelect'] -notmatch 'recommendedCount!=1' -or
   $functions['Set-CafePhysxAutoSelect'] -notmatch 'SetValue\(''physxGpuId''' -or
   $functions['Set-CafePhysxAutoSelect'] -notmatch 'actualGpuId.*recommendedGpuId' -or
   $functions['Set-CafePhysxAutoSelect'] -notmatch 'refusing to guess'){
    throw 'PhysX Auto-select must derive a unique recommended GPU ID through NVAPI, write it with the Auto flag, and verify both values.'
}
$physxHelperCode=$functions['Set-CafePhysxAutoSelect']
if($physxHelperCode -notmatch '\$families=@\(' -or
   $physxHelperCode -notmatch 'Nvapi=''SYSTEM\\CurrentControlSet\\Services\\nvlddmkm\\Parameters\\NVAPI''' -or
   $physxHelperCode -notmatch '\$nvapiKey\.GetValueNames\(\).*physxGpuId' -or
   $physxHelperCode -notmatch '\$activeFamilies\.Count -eq 1' -or
   $physxHelperCode -notmatch 'More than one NVIDIA PhysX registry family'){
    throw 'PhysX Auto-select must choose the NVIDIA registry family associated with the existing GPU-selection entry and refuse ambiguous matches.'
}
$helperMatch=[regex]::Match($functions['Set-CafePhysxAutoSelect'], '(?s)\$helper=@''\r?\n(?<script>.*?)\r?\n''@')
if(-not $helperMatch.Success){throw 'PhysX helper script could not be extracted for syntax validation.'}
$helperTokens=$null;$helperErrors=$null
[void][Management.Automation.Language.Parser]::ParseInput($helperMatch.Groups['script'].Value,[ref]$helperTokens,[ref]$helperErrors)
if(@($helperErrors).Count){throw 'PhysX elevated helper script has PowerShell syntax errors.'}
if($apply -notmatch 'Set-CafePhysxAutoSelect' -or
   $apply -notmatch "-Setting 'PhysX processor'.*-Requested 'Auto-select \(recommended\)'.*-Status UNVERIFIED" -or
   $apply -notmatch "-Setting 'PhysX processor'.*-Status FAILED" -or
   $apply -match "-Setting 'PhysX processor'.*-Status SKIPPED"){
    throw 'Profile Apply must report the registry write as UNVERIFIED for the active Control Panel selection, or FAILED when the registry write itself fails.'
}
if($apply -notmatch 'Opening NVIDIA Control Panel.*Confirm the PhysX processor dropdown shows Auto-select' -or
   $apply -notmatch 'active NVIDIA Control Panel selection'){
    throw 'PhysX Apply must explain the verification limit and open NVIDIA Control Panel for a manual selection check.'
}
if($apply -notmatch 'Write-NvidiaCompatibilityScan' -or
   $apply -notmatch '\$compat\.DisplayHelper' -or
   $apply -notmatch '\$compat\.NVAPI'){
    throw 'NVIDIA apply must preflight and gate unsupported display/NVAPI operations.'
}
foreach($required in @('TrySetDisplayMode','TrySetDigitalVibrance','TryApplyPerformanceProfile','TrySetGpuScalingMode')){
    if(-not $apply.Contains($required)){throw ('Must preserve independent apply step '+$required)}
}
foreach($required in @('$compat.Vibrance','$compat.Hue','$compat.DriverProfile','$compat.GpuScaling')){
    if(-not $apply.Contains($required)){throw ('Profile Apply must gate NVIDIA setting on '+$required)}
}
foreach($required in @('TrySetDigitalVibrance','TrySetHueAngle','TryApplyPerformanceProfile','TrySetGpuScalingMode','skipped')){
    if(-not $apply.Contains($required)){throw ('Profile Apply must preserve per-setting fallback/reporting for '+$required)}
}
if($functions['Get-PCDiagnostics'] -notmatch 'Get-NvidiaCompatibilityScan'){throw 'Detect PC must include NVIDIA scan.'}
$profileApply=$functions['Invoke-GamingProfile']
if($profileApply -notmatch 'Apply-NvidiaGamingSettings -Width' -or
   $apply -notmatch 'TrySetDisplayMode' -or
   $code -notmatch 'highest advertised refresh at preferred resolution'){
    throw 'Every enabled profile apply must select the maximum refresh at its configured resolution.'
}
$startupStart=$code.IndexOf('$startupTimer.Add_Tick({',[StringComparison]::Ordinal)
$startupEnd=$code.IndexOf('$form.Add_Shown({',[StringComparison]::Ordinal)
if($startupStart -lt 0 -or $startupEnd -le $startupStart -or
   $code.Substring($startupStart,$startupEnd-$startupStart) -match 'Set-StartupHighestRefreshRate|TrySetDisplayMode'){
    throw 'Opening the launcher must not change display refresh before a profile is applied.'
}
if($code -match '\$script:StartupStatusTimer\s*=|\$script:StartupSpinnerAngle\s*=|\$script:StartupOverlay\s*=\s*New-Object' -or
   $code.Substring($startupStart,$startupEnd-$startupStart) -match 'Get-PCDiagnostics' -or
   $functions['Show-PCDiagnostics'] -notmatch 'Get-PCDiagnostics'){
    throw 'PC inventory must run through Detect PC on demand, without a startup overlay or scan.'
}
if($scanCode -match 'Start-Process|Invoke-WebRequest|Stop-Process|Install-|Update-Driver'){throw 'Compatibility preflight must be read-only.'}
$script:StartupOverlayLabel=$null
$script:StartupInventoryRunning=$false
Invoke-Expression $functions['Set-CafeStartupStatus']
Set-CafeStartupStatus 'NVIDIA compatibility test'
if($script:StartupStatusMessage -ne 'NVIDIA compatibility test'){
    throw 'Startup status helper must retain the current scan phase.'
}
Invoke-Expression $scanCode
$scan=Get-NvidiaCompatibilityScan -Width 1280 -Height 960 -RefreshHz 360
if($null -eq $scan -or $null -eq $scan.Report){throw 'NVIDIA scan did not return diagnostic report.'}
foreach($key in @('NVAPI','DisplayHelper','ExactMode','Vibrance','Hue','DriverProfile','GpuScaling')){
    if($null -eq $scan.$key){throw ('Missing compatibility field: '+$key)}
}
if(@($scan.Report).Count -lt 2){throw 'NVIDIA preflight did not record capability diagnostics.'}
Write-Host ('PASS: profile-triggered max-refresh action, no startup display changes, NVIDIA compatibility inventory, read-only runtime scan and diagnostics; '+@($scan.Report).Count+' lines.')
