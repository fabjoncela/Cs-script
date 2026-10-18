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
    '**Mouse** tab contains Windows mouse controls and the per-profile **CS2 sensitivity** field',
    'three previous versions of `graphics/<ProfileName>.json` from GitHub commit history',
    'cached per profile for 24 hours',
    'GraphicsSettings',
    'profiles/<ProfileName>.json` and `graphics/<ProfileName>.json',
    'Update-Context.ps1 -Check'
)){
    if(-not $context.Contains($required)){throw ('Required Codex context is missing: '+$required)}
}
if(-not $agentInstructions.Contains('context.md')){throw 'AGENTS.md must direct Codex to read context.md.'}
Write-Host 'PASS: context is branch-aware, documents the editor/persistence flow, and README/context release metadata matches the launcher.'
