$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'The .NET Framework C# compiler was not found.' }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('CafeLauncherCompatibilityTest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $testSource = Join-Path $testRoot 'CompatibilityTests.cs'
    @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

internal static class CompatibilityTests
{
    private static int Main()
    {
        string source = "@echo off\r\n# CAFE_RELEASE=2026.11.12.1\r\n# POWERSHELL_GUI\r\n" +
            "if($env:CAFE_WEB_ACTION -ceq 'detect-pc'){ exit 0 }\r\n" +
            "if($env:CAFE_WEB_ACTION -ceq 'play-exec'){ exit 0 }\r\n" +
            "if($env:CAFE_WEB_ACTION -in @('apply-profile','apply-graphics')){ exit 0 }\r\n# " + new string('x', 12000) + "\r\n";
        byte[] bytes = Encoding.UTF8.GetBytes(source);
        Dictionary<string, object> metadata = Payload(bytes);
        byte[] validated = CafeLauncherWebRunner.ValidateGithubLauncherPayload(metadata);
        if (validated.Length != bytes.Length || CafeLauncherWebRunner.GitBlobSha(validated) != CafeLauncherWebRunner.GitBlobSha(bytes))
            throw new Exception("Verified GitHub payload bytes differ.");
        if (!CafeLauncherWebRunner.LauncherSupportsAction(validated, "detect-pc") ||
            !CafeLauncherWebRunner.LauncherSupportsAction(validated, "play-exec") ||
            !CafeLauncherWebRunner.LauncherSupportsAction(validated, "apply-profile") ||
            !CafeLauncherWebRunner.LauncherSupportsAction(validated, "apply-graphics"))
            throw new Exception("Web action capability detection failed.");
        Dictionary<string, object> release = new Dictionary<string, object> {
            { "version", "0.7.0" }, { "sha256", new string('a', 64) }, { "size", 50000 }
        };
        Dictionary<string, object> checkedRelease = CafeLauncherWebRunner.ValidateRunnerReleaseMetadata(release);
        if ((int)checkedRelease["size"] != 50000 || !CafeLauncherWebRunner.IsRunnerVersionNewer("0.7.0", "0.6.0") ||
            CafeLauncherWebRunner.IsRunnerVersionNewer("0.6.0", "0.7.0"))
            throw new Exception("Runner release metadata validation or update ordering failed.");
        release["sha256"] = "not-a-sha";
        bool invalidReleaseRejected = false;
        try { CafeLauncherWebRunner.ValidateRunnerReleaseMetadata(release); }
        catch (InvalidOperationException) { invalidReleaseRejected = true; }
        if (!invalidReleaseRejected) throw new Exception("Malformed runner release metadata was accepted.");
        if (CafeLauncherWebRunner.LauncherSupportsAction(Encoding.UTF8.GetBytes("# legacy launcher"), "detect-pc"))
            throw new Exception("A legacy launcher was incorrectly marked compatible.");

        metadata["sha"] = new string('0', 40);
        bool rejected = false;
        try { CafeLauncherWebRunner.ValidateGithubLauncherPayload(metadata); }
        catch (InvalidOperationException) { rejected = true; }
        if (!rejected) throw new Exception("A mismatched Git blob SHA was accepted.");
        DateTime now = new DateTime(2026, 11, 12, 12, 0, 0, DateTimeKind.Utc);
        string sha = CafeLauncherWebRunner.GitBlobSha(bytes);
        if (!CafeLauncherWebRunner.IsGithubLauncherMetadataCacheFresh(now.AddMinutes(-2), now) ||
            CafeLauncherWebRunner.IsGithubLauncherMetadataCacheFresh(now.AddMinutes(-4), now) ||
            CafeLauncherWebRunner.IsGithubLauncherMetadataCacheFresh(now.AddMinutes(1), now))
            throw new Exception("GitHub fallback metadata cache freshness was incorrect.");
        if (!CafeLauncherWebRunner.IsValidGithubLauncherCache("2026.11.12.1", sha, bytes.Length, bytes) ||
            CafeLauncherWebRunner.IsValidGithubLauncherCache("2026.11.12.1", sha, bytes.Length + 1, bytes) ||
            CafeLauncherWebRunner.IsValidGithubLauncherCache("2026.11.12.9", sha, bytes.Length, bytes))
            throw new Exception("Cached launcher size, hash, or release-marker validation failed.");
        if (!CafeLauncherWebRunner.CanReuseGithubLauncherAfterNotModified(304, "\"etag-1\"", "\"etag-1\"", true) ||
            CafeLauncherWebRunner.CanReuseGithubLauncherAfterNotModified(304, "\"etag-1\"", "\"etag-2\"", true) ||
            CafeLauncherWebRunner.CanReuseGithubLauncherAfterNotModified(200, "\"etag-1\"", "\"etag-1\"", true) ||
            CafeLauncherWebRunner.CanReuseGithubLauncherAfterNotModified(304, "\"etag-1\"", "\"etag-1\"", false))
            throw new Exception("Conditional GitHub ETag response handling was incorrect.");

        Console.WriteLine("PASS: GitHub blob/ETag validation, verified fallback cache, action detection, and tamper rejection.");
        return 0;
    }

    private static Dictionary<string, object> Payload(byte[] bytes)
    {
        return new Dictionary<string, object> {
            { "path", "cafe.bat" }, { "encoding", "base64" },
            { "sha", CafeLauncherWebRunner.GitBlobSha(bytes) }, { "size", bytes.Length },
            { "content", Convert.ToBase64String(bytes, Base64FormattingOptions.InsertLineBreaks) }
        };
    }
}
'@ | Set-Content -LiteralPath $testSource -Encoding ASCII
    $testExe = Join-Path $testRoot 'CompatibilityTests.exe'
    $runnerSource = Join-Path $PSScriptRoot '..\web-runner\CafeLauncherWebRunner.cs'
    & $compiler /nologo /target:exe /optimize+ "/main:CompatibilityTests" "/out:$testExe" /reference:System.dll /reference:System.Core.dll /reference:System.Web.Extensions.dll /reference:System.Windows.Forms.dll $runnerSource $testSource
    if ($LASTEXITCODE -ne 0) { throw "Could not compile runner compatibility tests (exit $LASTEXITCODE)." }
    & $testExe
    if ($LASTEXITCODE -ne 0) { throw "Runner compatibility tests failed (exit $LASTEXITCODE)." }
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
