param([switch]$Check)

$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$contextPath=Join-Path $root 'context.md'
$readmePath=Join-Path $root 'README.md'
$launcherPath=Join-Path $root 'cafe.bat'
if(-not(Test-Path -LiteralPath $contextPath -PathType Leaf)){throw 'context.md is missing.'}
if(-not(Test-Path -LiteralPath $readmePath -PathType Leaf)){throw 'README.md is missing.'}
if(-not(Test-Path -LiteralPath $launcherPath -PathType Leaf)){throw 'cafe.bat is missing.'}

$launcher=[IO.File]::ReadAllText($launcherPath)
$matches=[regex]::Matches($launcher,'(?m)^# CAFE_RELEASE=(\d{4}\.\d{2}\.\d{2}\.\d+)\s*$')
if($matches.Count -ne 1){throw 'Expected exactly one valid CAFE_RELEASE marker in cafe.bat.'}
$release=$matches[0].Groups[1].Value

$definitions=@(
    [pscustomobject]@{
        Path=$contextPath
        Name='context.md'
        Pattern='(?ms)^<!-- BEGIN GENERATED LAUNCHER STATE -->\r?\n.*?^<!-- END GENERATED LAUNCHER STATE -->'
        BlockFactory={ param($newline) "<!-- BEGIN GENERATED LAUNCHER STATE -->$newline- Launcher release: ``$release``$newline- Generated from the unique ``# CAFE_RELEASE`` marker in ``cafe.bat`` by ``tools/Update-Context.ps1``.$newline<!-- END GENERATED LAUNCHER STATE -->" }
    }
    [pscustomobject]@{
        Path=$readmePath
        Name='README.md'
        Pattern='(?ms)^<!-- BEGIN GENERATED LAUNCHER RELEASE -->\r?\n.*?^<!-- END GENERATED LAUNCHER RELEASE -->'
        BlockFactory={ param($newline) "<!-- BEGIN GENERATED LAUNCHER RELEASE -->$newline> Launcher release: **$release**. Features depend on the PC's hardware, installed programs and user permissions.$newline<!-- END GENERATED LAUNCHER RELEASE -->" }
    }
)

$staleFiles=New-Object 'System.Collections.Generic.List[string]'
foreach($definition in $definitions){
    $content=[IO.File]::ReadAllText($definition.Path)
    $existing=[regex]::Matches($content,$definition.Pattern)
    if($existing.Count -ne 1){throw "$($definition.Name) must contain exactly one generated release marker block."}
    $newline=if($content.Contains("`r`n")){"`r`n"}else{"`n"}
    $block=& $definition.BlockFactory $newline
    $matcher=[regex]$definition.Pattern
    $updated=$matcher.Replace($content,$block,1)
    if($updated -ceq $content){continue}

    if($Check){
        $staleFiles.Add($definition.Name)
        continue
    }

    [IO.File]::WriteAllText($definition.Path,$updated,(New-Object Text.UTF8Encoding($false)))
    Write-Host ("Updated {0} generated release metadata to {1}." -f $definition.Name,$release)
}

if($staleFiles.Count -gt 0){
    Write-Error ("Generated release metadata is stale in {0}; run tools/Update-Context.ps1 and review the changes." -f ($staleFiles -join ', '))
}
if($Check){Write-Host ("README.md and context.md are current for launcher release $release.")}
