$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'The .NET Framework C# compiler was not found.' }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('CafeLauncherInstallTest-' + [guid]::NewGuid().ToString('N'))
$previousTestRoot = [Environment]::GetEnvironmentVariable('CAFELAUNCHER_INSTALL_TEST_ROOT', 'Process')
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $testSource = Join-Path $testRoot 'InstallTests.cs'
    @'
using System;
using System.IO;

internal static class InstallTests
{
    private static int Main()
    {
        string root = Environment.GetEnvironmentVariable("CAFELAUNCHER_INSTALL_TEST_ROOT");
        string source = Path.Combine(root, "download.exe");
        string destination = Path.Combine(root, "LocalAppData", "CafeLauncher", "Runner", "CafeLauncherWebRunner.exe");
        byte[] first = new byte[12000];
        new Random(42).NextBytes(first);
        File.WriteAllBytes(source, first);

        CafeLauncherWebRunner.InstallExecutable(source, destination);
        if (!Equal(first, File.ReadAllBytes(destination))) throw new Exception("Initial install bytes differ.");
        File.SetLastWriteTimeUtc(destination, DateTime.UtcNow.AddDays(-1));
        DateTime firstWrite = File.GetLastWriteTimeUtc(destination);
        CafeLauncherWebRunner.InstallExecutable(source, destination);
        if (File.GetLastWriteTimeUtc(destination) != firstWrite) throw new Exception("Identical reinstall should be a no-op.");

        byte[] updated = new byte[14000];
        new Random(84).NextBytes(updated);
        File.WriteAllBytes(source, updated);
        CafeLauncherWebRunner.InstallExecutable(source, destination);
        if (!Equal(updated, File.ReadAllBytes(destination))) throw new Exception("Updated install bytes differ.");
        Console.WriteLine("PASS: install, identical reinstall, and atomic replacement.");
        return 0;
    }

    private static bool Equal(byte[] left, byte[] right)
    {
        if (left.Length != right.Length) return false;
        for (int i = 0; i < left.Length; i++) if (left[i] != right[i]) return false;
        return true;
    }
}
'@ | Set-Content -LiteralPath $testSource -Encoding ASCII
    $testExe = Join-Path $testRoot 'InstallTests.exe'
    $runnerSource = Join-Path $PSScriptRoot '..\web-runner\CafeLauncherWebRunner.cs'
    & $compiler /nologo /target:exe /optimize+ "/main:InstallTests" "/out:$testExe" /reference:System.dll /reference:System.Core.dll /reference:System.Web.Extensions.dll /reference:System.Windows.Forms.dll $runnerSource $testSource
    if ($LASTEXITCODE -ne 0) { throw "Could not compile runner install tests (exit $LASTEXITCODE)." }
    $env:CAFELAUNCHER_INSTALL_TEST_ROOT = $testRoot
    & $testExe
    if ($LASTEXITCODE -ne 0) { throw "Runner install tests failed (exit $LASTEXITCODE)." }
}
finally {
    if ($null -eq $previousTestRoot) { Remove-Item Env:\CAFELAUNCHER_INSTALL_TEST_ROOT -ErrorAction SilentlyContinue }
    else { $env:CAFELAUNCHER_INSTALL_TEST_ROOT = $previousTestRoot }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
