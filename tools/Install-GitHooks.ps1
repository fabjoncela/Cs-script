$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$hooks=Join-Path $root '.githooks'
foreach($hook in @('check-context','pre-commit','pre-merge-commit','pre-push')){
    if(-not(Test-Path -LiteralPath (Join-Path $hooks $hook) -PathType Leaf)){
        throw ("Required repository hook is missing: "+$hook)
    }
}
$top=(git -C $root rev-parse --show-toplevel 2>$null)
if($LASTEXITCODE -ne 0 -or [IO.Path]::GetFullPath($top) -ne [IO.Path]::GetFullPath($root)){
    throw 'Could not verify the Git repository root.'
}
git -C $root config --local core.hooksPath .githooks
if($LASTEXITCODE -ne 0){throw 'Could not configure this repository to use .githooks.'}
Write-Host 'Installed repository-local hooks for context refresh before commits, merge commits, and pushes.'
