param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'build\CafeLauncherWebRunner.exe')
)

$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    throw 'The .NET Framework C# compiler was not found on this build PC.'
}
$source = Join-Path $PSScriptRoot 'CafeLauncherWebRunner.cs'
$manifest = Join-Path $PSScriptRoot 'CafeLauncherWebRunner.manifest'
if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
    throw 'The explicit CafeLauncher Web Runner Windows manifest is missing.'
}
$manifestText = [IO.File]::ReadAllText($manifest)
if ($manifestText -notmatch '<requestedExecutionLevel\s+level="asInvoker"\s+uiAccess="false"\s*/>') {
    throw 'The runner manifest must explicitly declare asInvoker to prevent Windows installer detection.'
}
$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}
& $compiler /nologo /target:winexe /optimize+ "/win32manifest:$manifest" "/out:$OutputPath" /reference:System.dll /reference:System.Core.dll /reference:System.Web.Extensions.dll /reference:System.Windows.Forms.dll $source
if ($LASTEXITCODE -ne 0) {
    throw "CafeLauncher Web Runner compilation failed with exit code $LASTEXITCODE."
}
Write-Output "Built $OutputPath"
