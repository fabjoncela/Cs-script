param([switch]$Check)

$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$contextPath=Join-Path $root 'context.md'
$launcherPath=Join-Path $root 'cafe.bat'
if(-not(Test-Path -LiteralPath $contextPath -PathType Leaf)){throw 'context.md is missing.'}
if(-not(Test-Path -LiteralPath $launcherPath -PathType Leaf)){throw 'cafe.bat is missing.'}

$launcher=[IO.File]::ReadAllText($launcherPath)
$matches=[regex]::Matches($launcher,'(?m)^# CAFE_RELEASE=(\d{4}\.\d{2}\.\d{2}\.\d+)\s*$')
if($matches.Count -ne 1){throw 'Expected exactly one valid CAFE_RELEASE marker in cafe.bat.'}
$release=$matches[0].Groups[1].Value
$context=[IO.File]::ReadAllText($contextPath)
$newline=if($context.Contains("`r`n")){"`r`n"}else{"`n"}
$block="<!-- BEGIN GENERATED LAUNCHER STATE -->$newline- Launcher release: ``$release``$newline- Generated from the unique ``# CAFE_RELEASE`` marker in ``cafe.bat`` by ``tools/Update-Context.ps1``.$newline<!-- END GENERATED LAUNCHER STATE -->"
$pattern='(?ms)^<!-- BEGIN GENERATED LAUNCHER STATE -->\r?\n.*?^<!-- END GENERATED LAUNCHER STATE -->'
$existing=[regex]::Matches($context,$pattern)
if($existing.Count -ne 1){throw 'context.md must contain exactly one generated-state marker block.'}
$matcher=[regex]$pattern
$updated=$matcher.Replace($context,$block,1)
if($updated -ceq $context){
    Write-Host ("Context is current for launcher release $release.")
    exit 0
}
if($Check){
    Write-Error ("context.md release metadata is stale; expected $release. Run tools/Update-Context.ps1 and commit context.md.")
    exit 1
}
[IO.File]::WriteAllText($contextPath,$updated,(New-Object Text.UTF8Encoding($false)))
Write-Host ("Updated context.md generated release metadata to $release. Review and commit context.md.")
