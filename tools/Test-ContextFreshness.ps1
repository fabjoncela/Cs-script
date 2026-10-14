Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$context=Get-Content -LiteralPath (Join-Path $root 'context.md') -Raw
$agentInstructions=Get-Content -LiteralPath (Join-Path $root 'AGENTS.md') -Raw
$scriptPath=Join-Path $PSScriptRoot 'Update-Context.ps1'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Check
if($LASTEXITCODE -ne 0){throw 'Generated context state is stale.'}
foreach($required in @(
    'main` is the production source',
    'testing/development until merged',
    '**CS2 / Apps** tab contains CFG sensitivity/URL, app launch options, and per-profile CS2 graphics controls',
    'GraphicsSettings',
    'profiles/<ProfileName>.json` and `graphics/<ProfileName>.json',
    'Update-Context.ps1 -Check'
)){
    if(-not $context.Contains($required)){throw ('Required Codex context is missing: '+$required)}
}
if(-not $agentInstructions.Contains('context.md')){throw 'AGENTS.md must direct Codex to read context.md.'}
Write-Host 'PASS: context is branch-aware, documents the editor/persistence flow, and matches the launcher release.'
