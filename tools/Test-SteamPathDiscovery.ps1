# Bounded Steam/CS2 path discovery regression tests; all paths are temporary fixtures.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$bat=[IO.File]::ReadAllText((Join-Path $repo 'cafe.bat'))
$marker=$bat.IndexOf('# POWERSHELL_GUI',[StringComparison]::Ordinal)
if($marker -lt 0){throw 'Missing launcher PowerShell marker.'}
$start=$bat.IndexOf("`n",$marker)+1
$source=$bat.Substring($start)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw 'Launcher PowerShell failed to parse.'}
$wanted=@('Find-App','Get-SteamLibraryCachePath','Read-SteamLibraryCache','Write-SteamLibraryCache',
    'Get-SteamLibraryRoots','Find-CS2ConfigInsideInstall','Get-CS2InstallFromManifest',
    'Find-CS2ConfigFolder','Get-SteamExecutable')
$definitions=@{}
foreach($function in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
    if($function.Name -in $wanted){$definitions[$function.Name]=$function.Extent.Text}
}
foreach($name in $wanted){if(-not $definitions.ContainsKey($name)){throw ('Missing function under test: '+$name)}}
foreach($name in $wanted){Invoke-Expression $definitions[$name]}

 $script:TestLogs=New-Object 'System.Collections.Generic.List[string]'
function Write-Log { param([string]$Message,[string]$Level='INFO') $script:TestLogs.Add(($Level+': '+$Message)) }
function Get-ItemProperty {
    [CmdletBinding()]
    param([string]$Path,[string]$LiteralPath,[string]$Name)
    return [pscustomobject]@{SteamPath=$script:TestSteamRoot;InstallPath=$script:TestSteamRoot;SteamExe=(Join-Path $script:TestSteamRoot 'steam.exe')}
}
function Get-Process {
    [CmdletBinding()]
    param([string]$Name)
    if($Name -eq 'steam'){return @([pscustomobject]@{Path=$script:TestSteamExe;Id=88})}
    return @()
}
function Get-PSDrive {
    [CmdletBinding()]
    param([string]$PSProvider)
    return @(
        [pscustomobject]@{Root=($script:TestSandbox.TrimEnd('\')+'\');DisplayRoot=$null},
        [pscustomobject]@{Root='Z:\';DisplayRoot='\\offline-server\steam'}
    )
}

$sandbox=Join-Path $env:TEMP ('CafeLauncher-SteamDiscovery-'+[Guid]::NewGuid().ToString('N'))
$savedLocalAppData=$env:LOCALAPPDATA
$savedProgramFiles=$env:ProgramFiles
$savedProgramFilesX86=${env:ProgramFiles(x86)}
$savedSystemDrive=$env:SystemDrive
try{
    $script:TestSandbox=$sandbox
    $env:LOCALAPPDATA=Join-Path $sandbox 'local'
    $env:ProgramFiles=Join-Path $sandbox 'ProgramFiles'
    ${env:ProgramFiles(x86)}=Join-Path $sandbox 'ProgramFilesX86'
    $env:SystemDrive=$sandbox
    $script:TestSteamRoot=Join-Path $sandbox 'SteamClient'
    $script:TestSteamExe=Join-Path $script:TestSteamRoot 'steam.exe'
    $library=Join-Path $sandbox 'LibraryD'
    $gameName='Counter-Strike Global Offensive'
    $installRoot=Join-Path (Join-Path (Join-Path $library 'steamapps\common') $gameName) ''
    $cfg=Join-Path $installRoot 'game\csgo\cfg'
    $invalidLibrary=Join-Path $sandbox 'InvalidLibrary'
    [void](New-Item -ItemType Directory -Path (Join-Path $script:TestSteamRoot 'steamapps') -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $library 'steamapps') -Force)
    [void](New-Item -ItemType Directory -Path $cfg -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $installRoot 'game\bin') -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $invalidLibrary 'steamapps\common\Wrong Game\game\csgo\cfg') -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $invalidLibrary 'steamapps\common\Wrong Game\game\bin') -Force)
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $script:TestSteamExe) -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $env:ProgramFiles 'Steam') -Force)
    [IO.File]::WriteAllText($script:TestSteamExe,'steam-client')
    $defaultExe=Join-Path $env:ProgramFiles 'Steam\steam.exe'
    [IO.File]::WriteAllText($defaultExe,'stale-client')

    $manifestRoot=Join-Path $library 'steamapps'
    [IO.File]::WriteAllText((Join-Path $manifestRoot 'appmanifest_730.acf'),@'
"AppState"
{
    "appid" "730"
    "installdir" "Counter-Strike Global Offensive"
}
'@)
    $invalidApps=Join-Path $invalidLibrary 'steamapps'
    [IO.File]::WriteAllText((Join-Path $invalidApps 'appmanifest_730.acf'),@'
"AppState"
{
    "appid" "440"
    "installdir" "Wrong Game"
}
'@)
    $escapedLibrary=$library.Replace('\','\\')
    $escapedInvalid=$invalidLibrary.Replace('\','\\')
    [IO.File]::WriteAllText((Join-Path $script:TestSteamRoot 'steamapps\libraryfolders.vdf'),@"
"libraryfolders"
{
    "0"
    {
        "path" "$escapedLibrary"
    }
    "1"
    {
        "path" "$escapedInvalid"
    }
}
"@)

    $roots=@(Get-SteamLibraryRoots)
    if($library -notin $roots -or $script:TestSteamRoot -notin $roots){throw 'Registry/VDF Steam library discovery missed valid roots.'}
    if(@($roots|Where-Object{$_ -like 'Z:*'}).Count){throw 'A disconnected mapped drive was probed as a Steam library.'}
    $cachePath=Get-SteamLibraryCachePath
    if(-not (Test-Path -LiteralPath $cachePath -PathType Leaf)){throw 'Successful Steam roots were not cached.'}
    $cache=Get-Content -LiteralPath $cachePath -Raw|ConvertFrom-Json
    if($library -notin @($cache.Libraries)){throw 'Steam library cache did not contain the discovered non-default library.'}
    $cache.Libraries=@($cache.Libraries)+@((Join-Path $sandbox 'MovedLibrary'))
    [IO.File]::WriteAllText($cachePath,($cache|ConvertTo-Json -Depth 3))
    if((Read-SteamLibraryCache) -contains (Join-Path $sandbox 'MovedLibrary')){throw 'Stale cache path was not revalidated.'}

    $activeExe=Get-SteamExecutable
    if($activeExe -cne $script:TestSteamExe){throw 'Steam executable discovery chose a stale default before the running client.'}
    $detected=Get-CS2InstallFromManifest -LibraryRoot $library
    if(-not $detected){throw ('Validated app 730 install was rejected. Logs: '+($script:TestLogs -join ' | '))}
    if(-not [string]::Equals([string]$detected.ConfigPath,[string]$cfg,[StringComparison]::OrdinalIgnoreCase)){
        throw ('Validated app 730 install resolved unexpected CFG path. Actual: '+$detected.ConfigPath+'; expected: '+$cfg)
    }
    if(Get-CS2InstallFromManifest -LibraryRoot $invalidLibrary){throw 'A stale manifest with the wrong appid was accepted.'}

    # The bounded fallback may locate a relocated matching folder only inside
    # the manifest-confirmed CS2 install; it must never fall back to old roots.
    Remove-Item -LiteralPath $cfg -Recurse -Force
    $relocated=Join-Path $installRoot 'compat\game\csgo\cfg'
    [void](New-Item -ItemType Directory -Path $relocated -Force)
    $found=Get-CS2InstallFromManifest -LibraryRoot $library
    if(-not $found -or $found.ConfigPath -cne $relocated){throw 'Bounded search failed to find the relocated CFG inside the confirmed CS2 install.'}

    $secondLibrary=Join-Path $sandbox 'SecondLibrary'
    $secondInstall=Join-Path $secondLibrary 'steamapps\common\Counter-Strike Global Offensive'
    $secondCfg=Join-Path $secondInstall 'game\csgo\cfg'
    [void](New-Item -ItemType Directory -Path $secondCfg -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $secondInstall 'game\bin') -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $secondLibrary 'steamapps') -Force)
    [IO.File]::WriteAllText((Join-Path $secondLibrary 'steamapps\appmanifest_730.acf'),@'
"AppState"
{
    "appid" "730"
    "installdir" "Counter-Strike Global Offensive"
}
'@)
    $escapedSecond=$secondLibrary.Replace('\','\\')
    [IO.File]::WriteAllText((Join-Path $script:TestSteamRoot 'steamapps\libraryfolders.vdf'),@"
"libraryfolders"
{
    "0"
    {
        "path" "$escapedLibrary"
    }
    "1"
    {
        "path" "$escapedSecond"
    }
}
"@)
    if(Find-CS2ConfigFolder -NoPrompt){throw 'Ambiguous valid CS2 installs must not select the first library silently.'}

    # Without a valid appmanifest, a plausible-looking orphan folder is not an
    # automatic target. Noninteractive profile apply must skip it safely.
    $orphanLibrary=Join-Path $sandbox 'OrphanLibrary'
    $orphanCfg=Join-Path $orphanLibrary 'steamapps\common\Counter-Strike Global Offensive\game\csgo\cfg'
    [void](New-Item -ItemType Directory -Path $orphanCfg -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path (Split-Path -Parent (Split-Path -Parent $orphanCfg)) 'bin') -Force -ErrorAction SilentlyContinue)
    $orphanInstall=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $orphanCfg))
    [void](New-Item -ItemType Directory -Path (Join-Path $orphanInstall 'game\bin') -Force)
    Remove-Item -LiteralPath (Join-Path $manifestRoot 'appmanifest_730.acf') -Force
    Remove-Item -LiteralPath (Join-Path $secondLibrary 'steamapps\appmanifest_730.acf') -Force
    $escapedOrphan=$orphanLibrary.Replace('\','\\')
    [IO.File]::WriteAllText((Join-Path $script:TestSteamRoot 'steamapps\libraryfolders.vdf'),@"
"libraryfolders"
{
    "0"
    {
        "path" "$escapedInvalid"
    }
    "1"
    {
        "path" "$escapedOrphan"
    }
}
"@)
    if(Find-CS2ConfigFolder -NoPrompt){throw 'An unverified manifest-free CS2 folder was accepted automatically.'}

    $fallbackText=(Get-Command Find-CS2ConfigInsideInstall).Definition
    if($fallbackText -notmatch '\$maxDirectories\s*=\s*1200' -or
       $fallbackText -notmatch '\$maxDepth\s*=\s*8' -or
       $fallbackText -notmatch 'ReparsePoint'){
        throw 'CS2 fallback search must remain bounded and avoid traversing reparse points.'
    }
    Write-Host 'PASS: Steam registry/VDF discovery, local-drive bounds, revalidated cache, running-client priority, appmanifest validation, bounded install-only CFG fallback, and orphan rejection.'
}finally{
    $env:LOCALAPPDATA=$savedLocalAppData
    $env:ProgramFiles=$savedProgramFiles
    ${env:ProgramFiles(x86)}=$savedProgramFilesX86
    $env:SystemDrive=$savedSystemDrive
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
