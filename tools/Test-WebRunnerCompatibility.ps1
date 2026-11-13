$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'The .NET Framework C# compiler was not found.' }
$repoRoot = Split-Path -Parent $PSScriptRoot
$runnerCode = [IO.File]::ReadAllText((Join-Path $repoRoot 'web-runner\CafeLauncherWebRunner.cs'))
$launcherCode = [IO.File]::ReadAllText((Join-Path $repoRoot 'cafe.bat'))
$requiredRevisionForwarding = 'start.EnvironmentVariables["CAFE_WEB_PROFILE_REVISION"] = profileRevision.ToString(CultureInfo.InvariantCulture);'
if ($runnerCode -notmatch [regex]::Escape($requiredRevisionForwarding) -or
    $runnerCode -notmatch 'The backend did not pin a valid profile revision to this action') {
    throw 'The runner must forward the claimed revision and fail safely when an in-flight ticket has no revision.'
}
$graphicsLoader = [regex]::Match($launcherCode, '(?s)function Get-CafeVerifiedGraphicsModulePath\s*\{(.*?)\r?\n\}\s*\r?\nfunction Invoke-CafeGraphicsPresetCore')
if (-not $graphicsLoader.Success -or
    $graphicsLoader.Groups[1].Value -notmatch "\`$expected='[0-9a-f]{40}'" -or
    $graphicsLoader.Groups[1].Value -notmatch 'https://raw\.githubusercontent\.com/fabjoncela/Cs-script/main/graphics/ApplyGraphics\.ps1' -or
    $runnerCode -notmatch 'The downloaded graphics helper did not match the launcher-pinned Git blob SHA') {
    throw 'The page-open warm-up must find the launcher pin and verify the downloaded graphics helper before caching it.'
}
$helperUrl = [regex]::Match($runnerCode, 'LogitechHelperUrl = "([^"]+)"')
$helperHash = [regex]::Match($runnerCode, 'LogitechHelperSha256 = "([0-9a-f]{64})"')
if (-not $helperUrl.Success -or -not $helperHash.Success -or
    $launcherCode -notmatch [regex]::Escape($helperUrl.Groups[1].Value) -or
    $launcherCode -notmatch [regex]::Escape($helperHash.Groups[1].Value)) {
    throw 'Runner and launcher Logitech helper URL/SHA-256 pins must match.'
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('CafeLauncherCompatibilityTest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $testSource = Join-Path $testRoot 'CompatibilityTests.cs'
    @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;

internal static class CompatibilityTests
{
    private static int Main(string[] args)
    {
        if (args.Length == 2 && args[0] == "--linger")
        {
            File.WriteAllText(args[1], "{\"schemaVersion\":1,\"state\":\"COMPLETED\",\"result\":{\"summary\":\"finished\",\"steps\":[],\"data\":{\"executionOutcomeKnown\":true}}}", new UTF8Encoding(false));
            Thread.Sleep(30000);
            return 0;
        }

        string source = "@echo off\r\n# CAFE_RELEASE=2026.11.12.1\r\n# POWERSHELL_GUI\r\n" +
            "if($env:CAFE_WEB_ACTION -ceq 'detect-pc'){ exit 0 }\r\n" +
            "if($env:CAFE_WEB_ACTION -ceq 'play-exec'){ exit 0 }\r\n" +
            "if($env:CAFE_WEB_ACTION -in @('apply-profile','apply-graphics')){ exit 0 }\r\n# " + new string('x', 12000) + "\r\n";
        byte[] bytes = Encoding.UTF8.GetBytes(source);
        if (!CafeLauncherWebRunner.IsWarmupUri("cafelauncher://v1/warmup") ||
            CafeLauncherWebRunner.IsWarmupUri("cafelauncher://v1/warmup?run=anything") ||
            CafeLauncherWebRunner.IsWarmupUri("https://v1/warmup"))
            throw new Exception("Background warm-up protocol URI validation accepted an invalid link or rejected the valid one.");
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
        if ((int)checkedRelease["size"] != 50000 || !CafeLauncherWebRunner.IsRunnerVersionNewer("0.7.6", "0.7.5") ||
            !CafeLauncherWebRunner.IsRunnerVersionNewer("0.7.0", "0.6.0") || CafeLauncherWebRunner.IsRunnerVersionNewer("0.6.0", "0.7.0"))
            throw new Exception("Runner release metadata validation or update ordering failed.");
        if (!CafeLauncherWebRunner.IsLauncherReleaseVersionNewer("2026.11.13.4", "2026.11.13.3") ||
            CafeLauncherWebRunner.IsLauncherReleaseVersionNewer("2026.11.13.3", "2026.11.13.4") ||
            CafeLauncherWebRunner.IsLauncherReleaseVersionNewer("invalid", "2026.11.13.4"))
            throw new Exception("CafeLauncher release version ordering did not reject older or invalid versions.");
        byte[] olderLauncher = Encoding.UTF8.GetBytes(source.Replace("2026.11.12.1", "2026.11.13.3"));
        byte[] newerLauncher = Encoding.UTF8.GetBytes(source.Replace("2026.11.12.1", "2026.11.13.4"));
        Dictionary<string, object> backendLauncher = new Dictionary<string, object> { { "version", "2026.11.13.3" }, { "bytes", olderLauncher }, { "source", "backend" } };
        Dictionary<string, object> githubLauncher = new Dictionary<string, object> { { "version", "2026.11.13.4" }, { "bytes", newerLauncher }, { "source", "github" } };
        if (!Object.ReferenceEquals(CafeLauncherWebRunner.SelectNewestLauncherSource(backendLauncher, githubLauncher, "apply-graphics"), githubLauncher))
            throw new Exception("A newer action-compatible GitHub launcher was not selected over the older backend package.");
        byte[] incompatibleNewLauncher = Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(newerLauncher).Replace("$env:CAFE_WEB_ACTION -in @('apply-profile','apply-graphics')", "$env:CAFE_WEB_ACTION -ceq 'apply-profile'"));
        Dictionary<string, object> incompatibleGithubLauncher = new Dictionary<string, object> { { "version", "2026.11.13.4" }, { "bytes", incompatibleNewLauncher }, { "source", "github" } };
        if (!Object.ReferenceEquals(CafeLauncherWebRunner.SelectNewestLauncherSource(backendLauncher, incompatibleGithubLauncher, "apply-graphics"), backendLauncher))
            throw new Exception("An incompatible newer GitHub launcher replaced a compatible backend package.");
        if (!Object.ReferenceEquals(CafeLauncherWebRunner.SelectNewestLauncherSource(backendLauncher, backendLauncher, "apply-graphics"), backendLauncher))
            throw new Exception("An equally versioned GitHub launcher unexpectedly replaced the immutable backend package.");
        if (CafeLauncherWebRunner.IsPinnedLogitechHelper(new byte[0]))
            throw new Exception("An unverified Logitech helper was accepted as the pinned helper.");
        bool invalidHelperRejected = false;
        try { CafeLauncherWebRunner.InstallPinnedLogitechHelper(new byte[] { 1, 2, 3 }, Path.Combine(Path.GetTempPath(), "CafeLauncher-invalid-logihub.exe")); }
        catch (InvalidOperationException) { invalidHelperRejected = true; }
        if (!invalidHelperRejected) throw new Exception("A Logitech helper with the wrong SHA-256 was accepted for caching.");
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

        TestCompletedResultStopsLingeringPowerShell();
        TestTimeoutDiagnosticReportsSafeLocalState();

        Console.WriteLine("PASS: GitHub blob/ETag validation, automatic newer-source selection, verified fallback cache, result-file recovery, safe timeout diagnostics, action detection, and tamper rejection.");
        return 0;
    }

    private static void TestCompletedResultStopsLingeringPowerShell()
    {
        string root = Path.Combine(Path.GetTempPath(), "CafeLauncherLingeringProcessTest-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        string resultPath = Path.Combine(root, "result.json");
        Process child = null;
        try
        {
            ProcessStartInfo start = new ProcessStartInfo(Assembly.GetExecutingAssembly().Location, "--linger \"" + resultPath + "\"");
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            child = Process.Start(start);
            DateTime deadline = DateTime.UtcNow.AddSeconds(10);
            while (!File.Exists(resultPath) && DateTime.UtcNow < deadline) Thread.Sleep(25);
            if (!File.Exists(resultPath)) throw new Exception("The lingering result fixture did not write its result.");

            Dictionary<string, object> result;
            if (!CafeLauncherWebRunner.TryStopLauncherAfterCompletedResult(child, resultPath,
                DateTime.UtcNow.AddSeconds(-3), DateTime.UtcNow, out result))
                throw new Exception("A valid final result did not release the lingering PowerShell process.");
            if (!child.HasExited || (string)result["state"] != "COMPLETED")
                throw new Exception("The lingering process result was not safely returned after process cleanup.");
        }
        finally
        {
            if (child != null)
            {
                try { if (!child.HasExited) child.Kill(); } catch { }
                child.Dispose();
            }
            try { Directory.Delete(root, true); } catch { }
        }
    }

    private static void TestTimeoutDiagnosticReportsSafeLocalState()
    {
        string root = Path.Combine(Path.GetTempPath(), "CafeLauncherTimeoutDiagnosticTest-" + Guid.NewGuid().ToString("N"));
        string progress = Path.Combine(root, "progress");
        Directory.CreateDirectory(progress);
        try
        {
            File.WriteAllText(Path.Combine(progress, "progress-0003.json"),
                "{\"name\":\"Apply CS2 video and NVIDIA graphics settings\",\"status\":\"SUCCESS\",\"detail\":\"C:\\\\Users\\\\private\\\\path\"}", new UTF8Encoding(false));
            string diagnostic = CafeLauncherWebRunner.BuildLocalActionTimeoutDiagnostic(Path.Combine(root, "result.json"), progress);
            if (!diagnostic.Contains("result file: not present") ||
                !diagnostic.Contains("Apply CS2 video and NVIDIA graphics settings (SUCCESS)") ||
                diagnostic.Contains("C:\\Users") || diagnostic.Contains("private"))
                throw new Exception("The timeout diagnostic did not report safe local state or exposed progress detail.");
        }
        finally { try { Directory.Delete(root, true); } catch { } }
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
