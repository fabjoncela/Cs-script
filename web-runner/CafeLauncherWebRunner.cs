// Minimal .NET Framework runner for the CafeLauncher web-action protocol.
// State-changing actions are bound to short-lived backend tickets and the
// verified CafeLauncher release.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

internal static class CafeLauncherWebRunner
{
    private const string BackendOrigin = "https://fabjon-hp.tail681ec9.ts.net:10000";
    private const string RunnerVersion = "0.7.0";
    private const int MaxLauncherBytes = 1000000;
    private const int MaxRunnerBytes = 8 * 1024 * 1024;
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 2 * 1024 * 1024 };
    private sealed class ActionCanceledException : Exception { }

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 0) return InstallForCurrentUser();
            if (args.Length == 1 && args[0] == "--register") return RegisterProtocol(Process.GetCurrentProcess().MainModule.FileName);
            if (args.Length == 1 && args[0] == "--unregister") return UnregisterProtocol();
            if (args.Length < 1 || args.Length > 2 || (args.Length == 2 && args[1] != "--after-update"))
                throw new InvalidOperationException("Open CafeLauncher from the CafeLauncher website on this PC.");

            string requestId = ParseRequestUri(args[0]);
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            ServicePointManager.Expect100Continue = false;
            bool startedAfterUpdate = args.Length == 2;
            bool profileResetPending = File.Exists(PendingProfileResetPath());
            if (!startedAfterUpdate)
            {
                string updatedRunner = TryUpdateRunner(requestId);
                if (updatedRunner != null)
                {
                    StartUpdatedRunner(updatedRunner, requestId);
                    return 0;
                }
            }

            string claimCapability = RandomToken();
            Dictionary<string, object> claimBody = new Dictionary<string, object>
            {
                { "runnerVersion", RunnerVersion },
                { "protocolVersion", 1 },
                { "claimCapability", claimCapability }
            };
            Dictionary<string, object> ticket = ClaimWithRetry(requestId, claimBody);
            string action = RequiredString(ticket, "action");
            string profile = OptionalString(ticket, "profile");
            if (RequiredString(ticket, "state") != "CLAIMED")
                throw new InvalidOperationException("CafeLauncher returned a request that was not newly claimed.");
            if (!String.Equals(RequiredString(ticket, "requestId"), requestId, StringComparison.Ordinal))
                throw new InvalidOperationException("CafeLauncher returned a different action request.");
            if (!IsSupportedAction(action))
                throw new InvalidOperationException("This CafeLauncher action is not supported by the installed runner.");
            if (action == "detect-pc" && profile != null)
                throw new InvalidOperationException("Detect PC must not include a profile.");
            if (action != "detect-pc") ProfileCfg(profile);
            return ExecuteClaimedAction(requestId, action, profile, claimCapability, startedAfterUpdate || profileResetPending);
        }
        catch (Exception error)
        {
            MessageBox.Show(SafeMessage(error), "CafeLauncher", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 1;
        }
    }

    private static int InstallForCurrentUser()
    {
        string source = Process.GetCurrentProcess().MainModule.FileName;
        string destination = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CafeLauncher", "Runner", "CafeLauncherWebRunner.exe");
        string installedPath = Path.GetFullPath(destination);
        if (!String.Equals(Path.GetFullPath(source), installedPath, StringComparison.OrdinalIgnoreCase))
            InstallExecutable(source, installedPath);
        RegisterProtocol(installedPath);
        MessageBox.Show("CafeLauncher is ready for this Windows user. Return to the website and click an action.", "CafeLauncher installed", MessageBoxButtons.OK, MessageBoxIcon.Information);
        return 0;
    }

    // Kept free of registry and environment access so copy/replace behavior can
    // be exercised using temporary files without changing the test machine.
    internal static void InstallExecutable(string source, string destination)
    {
        string sourcePath = Path.GetFullPath(source);
        string destinationPath = Path.GetFullPath(destination);
        if (String.Equals(sourcePath, destinationPath, StringComparison.OrdinalIgnoreCase)) return;
        if (!File.Exists(sourcePath)) throw new InvalidOperationException("The downloaded CafeLauncher installer could not be found.");

        byte[] sourceBytes = File.ReadAllBytes(sourcePath);
        if (sourceBytes.Length < 10000) throw new InvalidOperationException("The CafeLauncher installer file is incomplete. Download it again and retry.");
        Directory.CreateDirectory(Path.GetDirectoryName(destinationPath));
        if (File.Exists(destinationPath) && String.Equals(Hash(File.ReadAllBytes(destinationPath)), Hash(sourceBytes), StringComparison.Ordinal)) return;

        string temporaryPath = destinationPath + ".installing-" + Guid.NewGuid().ToString("N");
        try
        {
            File.WriteAllBytes(temporaryPath, sourceBytes);
            if (!String.Equals(Hash(File.ReadAllBytes(temporaryPath)), Hash(sourceBytes), StringComparison.Ordinal))
                throw new InvalidOperationException("CafeLauncher could not verify the copied installer. Try again.");
            if (File.Exists(destinationPath)) File.Replace(temporaryPath, destinationPath, null);
            else File.Move(temporaryPath, destinationPath);
        }
        catch (IOException)
        {
            throw new InvalidOperationException("CafeLauncher could not update its installed file. Close any CafeLauncher window and try again.");
        }
        finally
        {
            if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
        }
    }

    private static int RegisterProtocol(string executable)
    {
        return WriteProtocolRegistration(executable, true);
    }

    private static int WriteProtocolRegistration(string executable, bool showMessage)
    {
        executable = Path.GetFullPath(executable);
        string expectedCommand = "\"" + executable + "\" \"%1\"";
        using (RegistryKey existing = Registry.CurrentUser.OpenSubKey(@"Software\Classes\cafelauncher\shell\open\command", false))
        {
            string registeredCommand = existing == null ? null : existing.GetValue(null) as string;
            if (registeredCommand != null && !String.Equals(registeredCommand, expectedCommand, StringComparison.OrdinalIgnoreCase) &&
                !IsManagedRunnerCommand(registeredCommand))
                throw new InvalidOperationException("Another CafeLauncher protocol handler is already registered for this Windows user. Remove or update that registration before installing this runner.");
        }
        using (RegistryKey protocol = Registry.CurrentUser.CreateSubKey(@"Software\Classes\cafelauncher"))
        {
            if (protocol == null) throw new InvalidOperationException("Could not create the current-user protocol registration.");
            protocol.SetValue(null, "URL:CafeLauncher Protocol");
            protocol.SetValue("URL Protocol", String.Empty);
            using (RegistryKey command = protocol.CreateSubKey(@"shell\open\command"))
            {
                if (command == null) throw new InvalidOperationException("Could not create the protocol command registration.");
                command.SetValue(null, expectedCommand);
            }
        }
        if (showMessage) MessageBox.Show("CafeLauncher web links are registered for this Windows user.", "CafeLauncher", MessageBoxButtons.OK, MessageBoxIcon.Information);
        return 0;
    }

    private static bool IsManagedRunnerCommand(string command)
    {
        const string suffix = "\" \"%1\"";
        if (String.IsNullOrEmpty(command) || !command.StartsWith("\"", StringComparison.Ordinal) || !command.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) return false;
        string path;
        try { path = Path.GetFullPath(command.Substring(1, command.Length - suffix.Length - 1)); }
        catch { return false; }
        if (!String.Equals(Path.GetFileName(path), "CafeLauncherWebRunner.exe", StringComparison.OrdinalIgnoreCase)) return false;
        string root = Path.GetFullPath(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CafeLauncher", "Runner"));
        string prefix = root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
        return path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
    }

    internal static Dictionary<string, object> ValidateRunnerReleaseMetadata(Dictionary<string, object> metadata)
    {
        if (metadata == null) throw new InvalidOperationException("GitHub returned no runner release metadata.");
        string version = RequiredString(metadata, "version");
        string hash = RequiredString(metadata, "sha256").ToLowerInvariant();
        int size;
        try { size = Convert.ToInt32(metadata["size"]); }
        catch { throw new InvalidOperationException("GitHub returned an invalid runner size."); }
        Version parsed;
        if (!Regex.IsMatch(version, @"^\d+\.\d+\.\d+$", RegexOptions.CultureInvariant) || !Version.TryParse(version, out parsed) ||
            size < 10000 || size > MaxRunnerBytes || !Regex.IsMatch(hash, @"^[0-9a-f]{64}$", RegexOptions.CultureInvariant))
            throw new InvalidOperationException("GitHub returned invalid runner release metadata.");
        return new Dictionary<string, object> { { "version", version }, { "sha256", hash }, { "size", size } };
    }

    internal static bool IsRunnerVersionNewer(string candidate, string current)
    {
        Version candidateVersion, currentVersion;
        return Version.TryParse(candidate, out candidateVersion) && Version.TryParse(current, out currentVersion) && candidateVersion > currentVersion;
    }

    private static string TryUpdateRunner(string requestId)
    {
        const string metadataUrl = "https://github.com/fabjoncela/Cs-script/releases/latest/download/CafeLauncherWebRunner.release.json";
        byte[] metadataBytes;
        try { metadataBytes = GetGithubReleaseAssetBytes(new Uri(metadataUrl), 4096); }
        catch (WebException) { return null; } // Keep the installed runner usable when GitHub is temporarily unavailable.
        Dictionary<string, object> metadata = ValidateRunnerReleaseMetadata(ParseJson(Encoding.UTF8.GetString(metadataBytes)));
        string version = (string)metadata["version"];
        if (!IsRunnerVersionNewer(version, RunnerVersion)) return null;

        string runnerRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CafeLauncher", "Runner");
        string versionDirectory = Path.Combine(runnerRoot, "releases", version);
        Directory.CreateDirectory(versionDirectory);
        string destination = Path.Combine(versionDirectory, "CafeLauncherWebRunner.exe");
        bool cached = false;
        if (File.Exists(destination))
        {
            byte[] local = File.ReadAllBytes(destination);
            cached = local.Length == (int)metadata["size"] && String.Equals(Hash(local), (string)metadata["sha256"], StringComparison.Ordinal);
        }
        if (!cached)
        {
            Uri releaseAsset = new Uri("https://github.com/fabjoncela/Cs-script/releases/download/cafelauncher-web-runner-v" + version + "/CafeLauncherWebRunner.exe");
            byte[] bytes;
            try { bytes = GetGithubReleaseAssetBytes(releaseAsset, MaxRunnerBytes); }
            catch (WebException) { return null; }
            if (bytes.Length != (int)metadata["size"] || !String.Equals(Hash(bytes), (string)metadata["sha256"], StringComparison.Ordinal))
                throw new InvalidOperationException("The latest CafeLauncher runner failed its published size or SHA-256 check.");
            string temporary = destination + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.WriteAllBytes(temporary, bytes);
                if (File.Exists(destination)) File.Replace(temporary, destination, null);
                else File.Move(temporary, destination);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        WriteProtocolRegistration(destination, false);
        string resetMarker = PendingProfileResetPath();
        string resetTemporary = resetMarker + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(resetTemporary, version, new UTF8Encoding(false));
            if (File.Exists(resetMarker)) File.Replace(resetTemporary, resetMarker, null);
            else File.Move(resetTemporary, resetMarker);
        }
        finally { if (File.Exists(resetTemporary)) File.Delete(resetTemporary); }
        return destination;
    }

    private static string PendingProfileResetPath()
    {
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CafeLauncher", "Runner", "pending-profile-reset.txt");
    }

    private static byte[] GetGithubReleaseAssetBytes(Uri uri, int maximum)
    {
        if (uri == null || uri.Scheme != Uri.UriSchemeHttps ||
            !String.Equals(uri.Host, "github.com", StringComparison.OrdinalIgnoreCase) ||
            !uri.AbsolutePath.StartsWith("/fabjoncela/Cs-script/releases/", StringComparison.Ordinal) ||
            uri.Query.Length != 0 || uri.Fragment.Length != 0 || uri.UserInfo.Length != 0)
            throw new InvalidOperationException("CafeLauncher refused a runner download outside the fixed GitHub release path.");
        HttpWebRequest request = (HttpWebRequest)WebRequest.Create(uri);
        request.Method = "GET";
        request.UserAgent = "CafeLauncher-WebRunner/" + RunnerVersion;
        request.Timeout = 20000;
        request.ReadWriteTimeout = 20000;
        request.AllowAutoRedirect = true;
        request.MaximumResponseHeadersLength = 32;
        using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
        using (Stream stream = response.GetResponseStream())
        using (MemoryStream memory = new MemoryStream())
        {
            string host = response.ResponseUri.Host;
            if (host != "github.com" && host != "release-assets.githubusercontent.com" && host != "objects.githubusercontent.com")
                throw new InvalidOperationException("GitHub redirected the runner download to an untrusted host.");
            byte[] buffer = new byte[8192];
            int read;
            while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
            {
                if (memory.Length + read > maximum) throw new InvalidOperationException("The CafeLauncher runner download exceeded its size limit.");
                memory.Write(buffer, 0, read);
            }
            return memory.ToArray();
        }
    }

    private static void StartUpdatedRunner(string executable, string requestId)
    {
        string uri = "cafelauncher://v1/run/" + requestId;
        ProcessStartInfo start = new ProcessStartInfo(executable, "\"" + uri + "\" --after-update");
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.WorkingDirectory = Path.GetDirectoryName(executable);
        using (Process process = Process.Start(start))
        {
            if (process == null) throw new InvalidOperationException("The updated CafeLauncher runner could not be started.");
        }
    }

    private static int UnregisterProtocol()
    {
        string executable = Process.GetCurrentProcess().MainModule.FileName;
        string expectedCommand = "\"" + executable + "\" \"%1\"";
        using (RegistryKey existing = Registry.CurrentUser.OpenSubKey(@"Software\Classes\cafelauncher\shell\open\command", false))
        {
            string registeredCommand = existing == null ? null : existing.GetValue(null) as string;
            if (registeredCommand != null && String.Equals(registeredCommand, expectedCommand, StringComparison.OrdinalIgnoreCase))
                Registry.CurrentUser.DeleteSubKeyTree(@"Software\Classes\cafelauncher", false);
        }
        MessageBox.Show("This runner's CafeLauncher web-link registration was removed if it matched this executable.", "CafeLauncher", MessageBoxButtons.OK, MessageBoxIcon.Information);
        return 0;
    }

    private static string ParseRequestUri(string raw)
    {
        Uri uri;
        if (raw == null || raw.Length > 128 || !Uri.TryCreate(raw, UriKind.Absolute, out uri) ||
            !String.Equals(uri.Scheme, "cafelauncher", StringComparison.OrdinalIgnoreCase) ||
            !String.Equals(uri.Host, "v1", StringComparison.Ordinal) || uri.UserInfo.Length != 0 ||
            uri.Port != -1 || uri.Query.Length != 0 || uri.Fragment.Length != 0)
            throw new InvalidOperationException("The CafeLauncher link is invalid. Return to the website and try again.");

        Match match = Regex.Match(uri.AbsolutePath, @"^/run/([A-Za-z0-9_-]{43})$", RegexOptions.CultureInvariant);
        if (!match.Success) throw new InvalidOperationException("The CafeLauncher link is invalid. Return to the website and try again.");
        return match.Groups[1].Value;
    }

    private static int ExecuteClaimedAction(string requestId, string action, string profile, string capability, bool runnerUpdated)
    {
        SendEvent(requestId, capability, "RUNNING", "Runner claimed request", "SUCCESS", "CafeLauncher runner is ready on this Windows session.", null);
        if (!IsSupportedAction(action))
        {
            SendEvent(requestId, capability, "FAILED", null, null, null, FailureResult(action, profile, "This action is not supported by the installed runner."));
            return 1;
        }
        if (action != "detect-pc") ProfileCfg(profile);

        bool actionMayHaveRun = false;
        bool localPlayOutcomeKnown = false;
        try
        {
            Dictionary<string, object> release = GetLatestVerifiedLauncher();
            bool githubCompatibilityFallback = false;
            if (!LauncherSupportsAction((byte[])release["bytes"], action))
            {
                SendEvent(requestId, capability, "RUNNING", "Launcher compatibility", "PENDING",
                    "The server package predates web actions. Fetching the current CafeLauncher source and verifying its GitHub blob hash.", null);
                release = GetLatestGithubLauncher();
                githubCompatibilityFallback = true;
                if (!LauncherSupportsAction((byte[])release["bytes"], action))
                    throw new InvalidOperationException("The current CafeLauncher source does not support this web action yet.");
            }
            string launcherPath = (string)release["path"];
            string verificationDetail = githubCompatibilityFallback
                ? "The current CafeLauncher source matched the official GitHub Contents API size and Git blob SHA."
                : "Downloaded launcher size and SHA-256 match the immutable release manifest.";
            SendEvent(requestId, capability, "RUNNING", "Launcher verification", "SUCCESS", verificationDetail, null);
            if (action != "detect-pc" && IsCancellationRequested(requestId, capability))
            {
                SendEvent(requestId, capability, "CANCELED", null, null, null, CancellationResult(action, profile));
                return 1;
            }
            actionMayHaveRun = action != "detect-pc";
            Dictionary<string, object> detection = RunLauncherAction(launcherPath, requestId, action, profile, runnerUpdated, capability);
            if (action != "detect-pc")
            {
                if (Convert.ToInt32(detection["schemaVersion"]) != 1)
                    throw new InvalidOperationException("The launcher action result used an unsupported schema.");
                string terminalState = RequiredString(detection, "state");
                if (terminalState != "COMPLETED" && terminalState != "PARTIAL" && terminalState != "SKIPPED" && terminalState != "FAILED" && terminalState != "INTERRUPTED")
                    throw new InvalidOperationException("The launcher returned an unsupported Play + Exec result state.");
                Dictionary<string, object> playResult = GetDictionary(detection, "result");
                if (action == "play-exec") ValidatePlayResult(playResult, profile, terminalState);
                else ValidateProfileActionResult(playResult, terminalState);
                actionMayHaveRun = false;
                localPlayOutcomeKnown = true;
                SendEvent(requestId, capability, terminalState, null, null, null, playResult);
                return terminalState == "FAILED" ? 1 : 0;
            }
            Dictionary<string, object> steam = GetDictionary(detection, "Steam");
            Dictionary<string, object> cs2 = GetDictionary(detection, "CS2");
            Dictionary<string, object> normalized = new Dictionary<string, object>
            {
                { "steam", new Dictionary<string, object> {
                    { "status", RequiredString(steam, "Status") },
                    { "executable", steam.ContainsKey("Executable") ? steam["Executable"] : null },
                    { "libraries", steam.ContainsKey("Libraries") ? steam["Libraries"] : new object[0] },
                    { "activeSessionPresent", RequiredBoolean(steam, "ActiveSessionPresent") }
                } },
                { "cs2", new Dictionary<string, object> {
                    { "status", RequiredString(cs2, "Status") },
                    { "installPath", cs2.ContainsKey("InstallPath") ? cs2["InstallPath"] : null },
                    { "configPath", cs2.ContainsKey("ConfigPath") ? cs2["ConfigPath"] : null }
                } }
            };
            string steamStatus = (string)((Dictionary<string, object>)normalized["steam"])["status"];
            string cs2Status = (string)((Dictionary<string, object>)normalized["cs2"])["status"];
            object[] steps = new object[] {
                Step("Steam discovery", steamStatus == "DETECTED" ? "SUCCESS" : "SKIPPED", steamStatus == "DETECTED" ? "Steam was detected." : "Steam was not detected."),
                Step("CS2 path discovery", cs2Status == "DETECTED" ? "SUCCESS" : "SKIPPED", cs2Status == "DETECTED" ? "A unique validated CS2 config path was detected." : "No unique validated CS2 install was found.")
            };
            Dictionary<string, object> result = new Dictionary<string, object>
            {
                { "summary", "PC detection completed for the current Windows user." },
                { "steps", steps },
                { "data", normalized }
            };
            SendEvent(requestId, capability, "RUNNING", "PC discovery", "SUCCESS", "Local Steam and CS2 discovery finished.", null);
            SendEvent(requestId, capability, "COMPLETED", null, null, null, result);
            return 0;
        }
        catch (ActionCanceledException)
        {
            if (actionMayHaveRun)
            {
                Dictionary<string, object> interrupted = FailureResult(action, profile,
                    "Stop was requested and Windows PowerShell was stopped. Some changes may already have happened; check this PC before retrying.");
                GetDictionary(interrupted, "data")["executionOutcomeKnown"] = false;
                SendEvent(requestId, capability, "INTERRUPTED", null, null, null, interrupted);
            }
            else SendEvent(requestId, capability, "CANCELED", null, null, null, CancellationResult(action, profile));
            return 1;
        }
        catch (Exception error)
        {
            if (localPlayOutcomeKnown) return 1;
            if (actionMayHaveRun)
            {
                Dictionary<string, object> interrupted = FailureResult(action, profile,
                    "The runner could not confirm whether CFG files or Steam changed. Check this PC before retrying.");
                GetDictionary(interrupted, "data")["executionOutcomeKnown"] = false;
                SendEvent(requestId, capability, "INTERRUPTED", null, null, null, interrupted);
                return 1;
            }
            SendEvent(requestId, capability, "FAILED", null, null, null, FailureResult(action, profile, SafeMessage(error)));
            return 1;
        }
    }

    private static Dictionary<string, object> GetLatestVerifiedLauncher()
    {
        Dictionary<string, object> manifest = GetJson("/v1/releases/latest");
        string version = RequiredString(manifest, "version");
        if (!Regex.IsMatch(version, @"^\d{4}\.\d{1,2}\.\d{1,2}\.\d+$", RegexOptions.CultureInvariant))
            throw new InvalidOperationException("The CafeLauncher release version is invalid.");
        Dictionary<string, object> artifacts = GetDictionary(manifest, "artifacts");
        Dictionary<string, object> launcher = GetDictionary(artifacts, "launcher");
        string relativeUrl = RequiredString(launcher, "url");
        int expectedSize = Convert.ToInt32(launcher["size"]);
        string expectedHash = RequiredString(launcher, "sha256").ToLowerInvariant();
        if (expectedSize < 10000 || expectedSize > MaxLauncherBytes || !Regex.IsMatch(expectedHash, @"^[0-9a-f]{64}$"))
            throw new InvalidOperationException("The CafeLauncher release manifest contains invalid file metadata.");

        Uri assetUri;
        if (!Uri.TryCreate(new Uri(BackendOrigin + "/"), relativeUrl, out assetUri) ||
            !String.Equals(assetUri.GetLeftPart(UriPartial.Authority), BackendOrigin, StringComparison.OrdinalIgnoreCase) ||
            !Regex.IsMatch(assetUri.AbsolutePath, "^/v1/releases/" + Regex.Escape(version) + "/launcher$", RegexOptions.CultureInvariant) ||
            assetUri.Query.Length != 0 || assetUri.Fragment.Length != 0)
            throw new InvalidOperationException("The CafeLauncher release URL is outside the trusted backend origin.");

        string cacheDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CafeLauncher", "Runner", "releases", version);
        Directory.CreateDirectory(cacheDir);
        string cachePath = Path.Combine(cacheDir, "cafe.bat");
        byte[] bytes = null;
        if (File.Exists(cachePath))
        {
            byte[] cached = File.ReadAllBytes(cachePath);
            if (cached.Length == expectedSize && Hash(cached) == expectedHash) bytes = cached;
        }
        if (bytes == null)
        {
            bytes = GetBytes(assetUri, MaxLauncherBytes);
            if (bytes.Length != expectedSize || Hash(bytes) != expectedHash)
                throw new InvalidOperationException("The downloaded CafeLauncher file did not match the release size and SHA-256.");
            string temp = cachePath + "." + Guid.NewGuid().ToString("N") + ".tmp";
            File.WriteAllBytes(temp, bytes);
            if (File.Exists(cachePath)) File.Delete(cachePath);
            File.Move(temp, cachePath);
        }
        string source = Encoding.UTF8.GetString(bytes);
        Match releaseMarker = Regex.Match(source, @"(?m)^# CAFE_RELEASE=(\d{4}\.\d{1,2}\.\d{1,2}\.\d+)\s*$", RegexOptions.CultureInvariant);
        if (!releaseMarker.Success || releaseMarker.Groups[1].Value != version)
            throw new InvalidOperationException("The launcher release marker did not match its manifest.");
        return new Dictionary<string, object> { { "path", cachePath }, { "bytes", bytes } };
    }

    private static Dictionary<string, object> GetLatestGithubLauncher()
    {
        const string endpoint = "https://api.github.com/repos/fabjoncela/Cs-script/contents/cafe.bat?ref=main";
        Dictionary<string, object> metadata = ParseJson(Encoding.UTF8.GetString(GetBytes(CreateGithubRequest(new Uri(endpoint), "GET"), 2 * MaxLauncherBytes)));
        byte[] bytes = ValidateGithubLauncherPayload(metadata);
        Match version = Regex.Match(Encoding.UTF8.GetString(bytes), @"(?m)^# CAFE_RELEASE=(\d{4}\.\d{1,2}\.\d{1,2}\.\d+)\s*$", RegexOptions.CultureInvariant);
        string sha = RequiredString(metadata, "sha").ToLowerInvariant();
        string cacheDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CafeLauncher", "Runner", "github", sha);
        Directory.CreateDirectory(cacheDir);
        string cachePath = Path.Combine(cacheDir, "cafe.bat");
        if (File.Exists(cachePath) && !String.Equals(GitBlobSha(File.ReadAllBytes(cachePath)), sha, StringComparison.Ordinal))
            File.Delete(cachePath);
        if (!File.Exists(cachePath))
        {
            string temporaryPath = cachePath + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.WriteAllBytes(temporaryPath, bytes);
                if (!String.Equals(GitBlobSha(File.ReadAllBytes(temporaryPath)), sha, StringComparison.Ordinal))
                    throw new InvalidOperationException("The cached CafeLauncher source failed its GitHub blob hash check.");
                File.Move(temporaryPath, cachePath);
            }
            finally
            {
                if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
            }
        }
        return new Dictionary<string, object> { { "path", cachePath }, { "bytes", bytes }, { "version", version.Groups[1].Value } };
    }

    // Validate the public GitHub Contents API response independently of any
    // network or filesystem access, so malformed and tampered payloads can be
    // covered by temp-only tests.
    internal static byte[] ValidateGithubLauncherPayload(Dictionary<string, object> metadata)
    {
        if (metadata == null || RequiredString(metadata, "path") != "cafe.bat" || RequiredString(metadata, "encoding") != "base64")
            throw new InvalidOperationException("GitHub returned unexpected CafeLauncher file metadata.");
        string expectedBlob = RequiredString(metadata, "sha").ToLowerInvariant();
        int expectedSize = Convert.ToInt32(metadata["size"]);
        string content = RequiredString(metadata, "content");
        if (expectedSize < 10000 || expectedSize > MaxLauncherBytes || !Regex.IsMatch(expectedBlob, @"^[0-9a-f]{40}$", RegexOptions.CultureInvariant))
            throw new InvalidOperationException("GitHub returned invalid CafeLauncher file metadata.");

        byte[] bytes;
        try { bytes = Convert.FromBase64String(Regex.Replace(content, @"\s", String.Empty)); }
        catch (FormatException error) { throw new InvalidOperationException("GitHub returned invalid CafeLauncher file content.", error); }
        if (bytes.Length != expectedSize || !String.Equals(GitBlobSha(bytes), expectedBlob, StringComparison.Ordinal))
            throw new InvalidOperationException("The current CafeLauncher source failed its GitHub size and blob hash checks.");
        string source = Encoding.UTF8.GetString(bytes);
        Match release = Regex.Match(source, @"(?m)^# CAFE_RELEASE=(\d{4}\.\d{1,2}\.\d{1,2}\.\d+)\s*$", RegexOptions.CultureInvariant);
        if (!source.StartsWith("@echo off", StringComparison.OrdinalIgnoreCase) ||
            !Regex.IsMatch(source, @"(?m)^# POWERSHELL_GUI\s*$", RegexOptions.CultureInvariant) || !release.Success)
            throw new InvalidOperationException("The current GitHub file is not a valid CafeLauncher release.");
        return bytes;
    }

    internal static bool LauncherSupportsAction(byte[] bytes, string action)
    {
        if (bytes == null || !IsSupportedAction(action)) return false;
        string source = Encoding.UTF8.GetString(bytes);
        string branch = @"(?m)^\s*if\s*\(\$env:CAFE_WEB_ACTION\s+-ceq\s+'" + Regex.Escape(action) + @"'\)\s*\{";
        if (Regex.IsMatch(source, branch, RegexOptions.CultureInvariant)) return true;
        return (action == "apply-profile" || action == "apply-graphics") &&
            Regex.IsMatch(source, @"\$env:CAFE_WEB_ACTION\s+-in\s+@\('apply-profile','apply-graphics'\)", RegexOptions.CultureInvariant);
    }

    private static bool IsSupportedAction(string action)
    {
        return action == "detect-pc" || action == "play-exec" || action == "apply-profile" || action == "apply-graphics";
    }

    internal static string GitBlobSha(byte[] bytes)
    {
        byte[] header = Encoding.ASCII.GetBytes("blob " + bytes.Length + "\0");
        byte[] blob = new byte[header.Length + bytes.Length];
        Buffer.BlockCopy(header, 0, blob, 0, header.Length);
        Buffer.BlockCopy(bytes, 0, blob, header.Length, bytes.Length);
        using (SHA1 sha = SHA1.Create())
        {
            StringBuilder value = new StringBuilder(40);
            foreach (byte item in sha.ComputeHash(blob)) value.Append(item.ToString("x2"));
            return value.ToString();
        }
    }

    private static Dictionary<string, object> RunLauncherAction(string launcherPath, string requestId, string action, string profile, bool runnerUpdated, string capability)
    {
        byte[] sourceBytes = File.ReadAllBytes(launcherPath);
        string source = Encoding.UTF8.GetString(sourceBytes);
        Match marker = Regex.Match(source, @"(?m)^# POWERSHELL_GUI\r?\n", RegexOptions.CultureInvariant);
        if (!marker.Success) throw new InvalidOperationException("The verified launcher does not contain its PowerShell entry point.");
        string script = source.Substring(marker.Index + marker.Length);
        string workDir = Path.Combine(Path.GetTempPath(), "CafeLauncher-Web-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(workDir);
        string scriptPath = Path.Combine(workDir, "launcher.ps1");
        string resultPath = Path.Combine(workDir, "result.json");
        string progressDirectory = Path.Combine(workDir, "progress");
        Directory.CreateDirectory(progressDirectory);
        // Windows PowerShell 5.1 treats BOM-less scripts as the active ANSI
        // code page; preserve the verified launcher's Unicode source exactly.
        File.WriteAllText(scriptPath, script, new UTF8Encoding(true));
        try
        {
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            ProcessStartInfo start = new ProcessStartInfo(powershell,
                "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + scriptPath + "\"");
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.WorkingDirectory = workDir;
            start.EnvironmentVariables["CAFE_SCRIPT"] = launcherPath;
            start.EnvironmentVariables["CAFE_WEB_ACTION"] = action;
            start.EnvironmentVariables["CAFE_WEB_REQUEST_ID"] = requestId;
            start.EnvironmentVariables["CAFE_WEB_RESULT_FILE"] = resultPath;
            start.EnvironmentVariables["CAFE_WEB_PROGRESS_DIR"] = progressDirectory;
            if (runnerUpdated) start.EnvironmentVariables["CAFE_WEB_RUNNER_UPDATED"] = "1";
            if (profile != null) start.EnvironmentVariables["CAFE_WEB_PROFILE"] = profile;
            using (Process process = Process.Start(start))
            {
                if (process == null) throw new InvalidOperationException("Windows PowerShell could not be started.");
                DateTime deadline = DateTime.UtcNow.AddMilliseconds(120000);
                DateTime nextControlCheck = DateTime.MinValue;
                int nextProgressIndex = 1;
                while (!process.WaitForExit(500))
                {
                    ForwardProgressEvents(progressDirectory, requestId, capability, ref nextProgressIndex);
                    if (DateTime.UtcNow >= nextControlCheck)
                    {
                        nextControlCheck = DateTime.UtcNow.AddSeconds(2);
                        if (IsCancellationRequested(requestId, capability))
                        {
                            try { process.Kill(); } catch { }
                            process.WaitForExit(5000);
                            ForwardProgressEvents(progressDirectory, requestId, capability, ref nextProgressIndex);
                            throw new ActionCanceledException();
                        }
                    }
                    if (DateTime.UtcNow >= deadline)
                    {
                        try { process.Kill(); } catch { }
                        process.WaitForExit(5000);
                        ForwardProgressEvents(progressDirectory, requestId, capability, ref nextProgressIndex);
                        throw new TimeoutException("The CafeLauncher action took too long and was stopped.");
                    }
                }
                ForwardProgressEvents(progressDirectory, requestId, capability, ref nextProgressIndex);
                if (process.ExitCode != 0 || !File.Exists(resultPath) || new FileInfo(resultPath).Length > 64 * 1024)
                    throw new InvalidOperationException("The verified launcher could not return the PC detection result.");
            }
            Dictionary<string, object> result = Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(resultPath, Encoding.UTF8));
            if (result == null) throw new InvalidOperationException("The launcher returned an invalid action result.");
            return result;
        }
        finally
        {
            try { Directory.Delete(workDir, true); } catch { }
        }
    }

    private static void ForwardProgressEvents(string progressDirectory, string requestId, string capability, ref int nextProgressIndex)
    {
        // Leave event capacity for the runner milestones and one terminal result.
        while (nextProgressIndex <= 48)
        {
            string path = Path.Combine(progressDirectory, "progress-" + nextProgressIndex.ToString("D4", CultureInfo.InvariantCulture) + ".json");
            if (!File.Exists(path)) return;
            try
            {
                Dictionary<string, object> progress = Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(path, Encoding.UTF8));
                string name = RequiredString(progress, "name");
                string status = RequiredString(progress, "status");
                string detail = RequiredString(progress, "detail");
                TrySendProgressEvent(requestId, capability, name, status, detail);
            }
            catch
            {
                // Progress is best-effort. A diagnostic write must never stop the local action.
            }
            finally
            {
                nextProgressIndex++;
            }
        }
    }

    private static void TrySendProgressEvent(string requestId, string capability, string name, string status, string detail)
    {
        try
        {
            Dictionary<string, object> value = new Dictionary<string, object>
            {
                { "eventId", Guid.NewGuid().ToString("D") },
                { "state", "RUNNING" },
                { "step", Step(name, status, detail) }
            };
            PostRaw("/v1/actions/" + requestId + "/events", Json.Serialize(value), capability);
        }
        catch
        {
            // Skip an unavailable progress upload and keep running the user-requested action.
        }
    }

    private static void ValidatePlayResult(Dictionary<string, object> result, string profile, string state)
    {
        if (!result.ContainsKey("summary") || !(result["summary"] is string) ||
            !result.ContainsKey("steps") || !result.ContainsKey("data"))
            throw new InvalidOperationException("The launcher returned an incomplete Play + Exec result.");
        Dictionary<string, object> data = GetDictionary(result, "data");
        if (RequiredString(data, "cfgName") != ProfileCfg(profile))
            throw new InvalidOperationException("The launcher result CFG does not match the selected profile.");
        bool launchRequested = RequiredBoolean(data, "steamLaunchRequested");
        bool cs2Running = RequiredBoolean(data, "cs2AlreadyRunning");
        bool outcomeKnown = RequiredBoolean(data, "executionOutcomeKnown");
        object rawCommands;
        if (!data.TryGetValue("consoleCommands", out rawCommands))
            throw new InvalidOperationException("The launcher returned incomplete console command data.");
        IList commands = rawCommands as IList;
        if (commands == null || commands.Count > 2)
            throw new InvalidOperationException("The launcher returned invalid console command data.");
        if (commands.Count != 0 && (commands.Count != 2 ||
            !Object.Equals(commands[0], "exec cafelauncher_profile_baseline.cfg") ||
            !Object.Equals(commands[1], "exec " + ProfileCfg(profile))))
            throw new InvalidOperationException("The launcher returned unexpected console commands.");
        if (state == "COMPLETED" && !launchRequested)
            throw new InvalidOperationException("The launcher reported success without requesting Steam launch.");
        if (state == "INTERRUPTED" && outcomeKnown)
            throw new InvalidOperationException("The launcher interruption state must report an unknown execution outcome.");
        if (state != "INTERRUPTED" && !outcomeKnown)
            throw new InvalidOperationException("The launcher returned an unknown outcome without the interrupted state.");
        if (cs2Running && commands.Count == 0)
            throw new InvalidOperationException("CS2 is already running but the launcher did not return its console commands.");
    }

    private static void ValidateProfileActionResult(Dictionary<string, object> result, string state)
    {
        if (!result.ContainsKey("summary") || !(result["summary"] is string) ||
            !result.ContainsKey("steps") || !result.ContainsKey("data"))
            throw new InvalidOperationException("The launcher returned an incomplete profile action result.");
        Dictionary<string, object> data = GetDictionary(result, "data");
        if (data.Count != 1 || RequiredBoolean(data, "executionOutcomeKnown") == (state == "INTERRUPTED"))
            throw new InvalidOperationException("The launcher profile action outcome certainty did not match its result state.");
    }

    private static void SendEvent(string requestId, string capability, string state, string stepName, string stepStatus, string detail, Dictionary<string, object> result)
    {
        Dictionary<string, object> value = new Dictionary<string, object>
        {
            { "eventId", Guid.NewGuid().ToString("D") },
            { "state", state }
        };
        if (stepName != null) value["step"] = Step(stepName, stepStatus, detail);
        if (result != null) value["result"] = result;
        string body = Json.Serialize(value);
        string path = "/v1/actions/" + requestId + "/events";
        Exception lastError = null;
        for (int attempt = 0; attempt < 4; attempt++)
        {
            try
            {
                PostRaw(path, body, capability);
                return;
            }
            catch (Exception error)
            {
                lastError = error;
                System.Threading.Thread.Sleep(500 * (attempt + 1));
            }
        }
        throw new InvalidOperationException("CafeLauncher could not confirm an action result with the backend.", lastError);
    }

    private static Dictionary<string, object> FailureResult(string action, string profile, string summary)
    {
        if (action == "play-exec")
        {
            return new Dictionary<string, object>
            {
                { "summary", summary },
                { "steps", new object[] { Step("Play + Exec", "FAILED", "The runner did not receive a local result. Check this PC before retrying.") } },
                { "data", new Dictionary<string, object> { { "steamLaunchRequested", false }, { "cs2AlreadyRunning", false }, { "executionOutcomeKnown", true }, { "cfgName", ProfileCfg(profile) }, { "consoleCommands", new object[0] } } }
            };
        }
        if (action == "apply-profile" || action == "apply-graphics")
        {
            return new Dictionary<string, object>
            {
                { "summary", summary },
                { "steps", new object[] { Step(action == "apply-profile" ? "Apply profile" : "Apply game graphics", "FAILED", "The runner did not receive a local result. Check this PC before retrying.") } },
                { "data", new Dictionary<string, object> { { "executionOutcomeKnown", true } } }
            };
        }
        return new Dictionary<string, object>
        {
            { "summary", summary },
            { "steps", new object[] { Step("PC detection", "FAILED", "Detection did not complete.") } },
            { "data", new Dictionary<string, object> {
                { "steam", new Dictionary<string, object> { { "status", "NOT_DETECTED" }, { "executable", null }, { "libraries", new object[0] }, { "activeSessionPresent", false } } },
                { "cs2", new Dictionary<string, object> { { "status", "NOT_UNIQUELY_DETECTED" }, { "installPath", null }, { "configPath", null } } }
            } }
        };
    }

    private static Dictionary<string, object> CancellationResult(string action, string profile)
    {
        Dictionary<string, object> result = FailureResult(action, profile, "Canceled before the Windows action started.");
        result["steps"] = new object[0];
        return result;
    }

    private static bool IsCancellationRequested(string requestId, string capability)
    {
        try
        {
            HttpWebRequest request = CreateRequest(new Uri(BackendOrigin + "/v1/actions/" + requestId + "/control"), "GET");
            request.Timeout = 2000;
            request.ReadWriteTimeout = 2000;
            request.Headers[HttpRequestHeader.Authorization] = "Bearer " + capability;
            Dictionary<string, object> control = ParseJson(Encoding.UTF8.GetString(GetBytes(request, 4096)));
            object value;
            return control.TryGetValue("cancelRequested", out value) && value is bool && (bool)value;
        }
        catch (Exception) { return false; }
    }

    private static Dictionary<string, object> Step(string name, string status, string detail)
    {
        return new Dictionary<string, object> { { "name", name }, { "status", status }, { "detail", detail ?? String.Empty } };
    }

    private static string ProfileCfg(string profile)
    {
        Dictionary<string, string> map = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            { "FabMode", "fab.cfg" }, { "ArliMode", "arli.cfg" }, { "BrileMode", "brile.cfg" },
            { "ArmlMode", "arml.cfg" }, { "OliMode", "oli.cfg" }, { "Provmode", "prov.cfg" }
        };
        string cfg;
        if (!map.TryGetValue(profile ?? String.Empty, out cfg)) throw new InvalidOperationException("The action used an unknown CafeLauncher profile.");
        return cfg;
    }

    private static string RandomToken()
    {
        byte[] bytes = new byte[32];
        using (RandomNumberGenerator rng = RandomNumberGenerator.Create()) rng.GetBytes(bytes);
        return Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }

    private static Dictionary<string, object> ClaimWithRetry(string requestId, Dictionary<string, object> body)
    {
        Exception lastError = null;
        for (int attempt = 0; attempt < 4; attempt++)
        {
            try { return PostJson("/v1/actions/" + requestId + "/claim", body, null); }
            catch (Exception error)
            {
                lastError = error;
                System.Threading.Thread.Sleep(500 * (attempt + 1));
            }
        }
        throw new InvalidOperationException("CafeLauncher could not claim this action with the backend.", lastError);
    }

    private static Dictionary<string, object> GetJson(string path)
    {
        return ParseJson(Encoding.UTF8.GetString(GetBytes(new Uri(BackendOrigin + path), 2 * 1024 * 1024)));
    }

    private static Dictionary<string, object> PostJson(string path, Dictionary<string, object> body, string bearer)
    {
        return ParseJson(PostRaw(path, Json.Serialize(body), bearer));
    }

    private static string PostRaw(string path, string body, string bearer)
    {
        HttpWebRequest request = CreateRequest(new Uri(BackendOrigin + path), "POST");
        request.ContentType = "application/json; charset=utf-8";
        if (!String.IsNullOrEmpty(bearer)) request.Headers[HttpRequestHeader.Authorization] = "Bearer " + bearer;
        byte[] bytes = Encoding.UTF8.GetBytes(body);
        request.ContentLength = bytes.Length;
        using (Stream stream = request.GetRequestStream()) stream.Write(bytes, 0, bytes.Length);
        using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
        using (StreamReader reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8)) return reader.ReadToEnd();
    }

    private static byte[] GetBytes(Uri uri, int maximum)
    {
        return GetBytes(CreateRequest(uri, "GET"), maximum);
    }

    private static byte[] GetBytes(HttpWebRequest request, int maximum)
    {
        using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
        using (Stream stream = response.GetResponseStream())
        using (MemoryStream memory = new MemoryStream())
        {
            byte[] buffer = new byte[8192];
            int read;
            while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
            {
                if (memory.Length + read > maximum) throw new InvalidOperationException("A CafeLauncher download exceeded its size limit.");
                memory.Write(buffer, 0, read);
            }
            return memory.ToArray();
        }
    }

    private static HttpWebRequest CreateRequest(Uri uri, string method)
    {
        if (!String.Equals(uri.GetLeftPart(UriPartial.Authority), BackendOrigin, StringComparison.OrdinalIgnoreCase) || uri.Scheme != Uri.UriSchemeHttps)
            throw new InvalidOperationException("CafeLauncher refused a request outside its trusted HTTPS backend.");
        HttpWebRequest request = (HttpWebRequest)WebRequest.Create(uri);
        request.Method = method;
        request.UserAgent = "CafeLauncher-WebRunner/" + RunnerVersion;
        request.Timeout = 15000;
        request.ReadWriteTimeout = 15000;
        request.AllowAutoRedirect = false;
        request.MaximumResponseHeadersLength = 32;
        return request;
    }

    private static HttpWebRequest CreateGithubRequest(Uri uri, string method)
    {
        if (uri.Scheme != Uri.UriSchemeHttps || !String.Equals(uri.GetLeftPart(UriPartial.Authority), "https://api.github.com", StringComparison.OrdinalIgnoreCase) ||
            uri.AbsolutePath != "/repos/fabjoncela/Cs-script/contents/cafe.bat" || uri.Query != "?ref=main" || uri.Fragment.Length != 0 || uri.UserInfo.Length != 0)
            throw new InvalidOperationException("CafeLauncher refused a request outside the trusted GitHub source endpoint.");
        HttpWebRequest request = (HttpWebRequest)WebRequest.Create(uri);
        request.Method = method;
        request.UserAgent = "CafeLauncher-WebRunner/" + RunnerVersion;
        request.Accept = "application/vnd.github+json";
        request.Timeout = 15000;
        request.ReadWriteTimeout = 15000;
        request.AllowAutoRedirect = false;
        request.MaximumResponseHeadersLength = 32;
        return request;
    }

    private static Dictionary<string, object> ParseJson(string text)
    {
        Dictionary<string, object> value = Json.Deserialize<Dictionary<string, object>>(text);
        if (value == null) throw new InvalidOperationException("The CafeLauncher backend returned an invalid response.");
        return value;
    }

    private static Dictionary<string, object> GetDictionary(Dictionary<string, object> value, string key)
    {
        object nested;
        Dictionary<string, object> result;
        if (!value.TryGetValue(key, out nested) || (result = nested as Dictionary<string, object>) == null)
            throw new InvalidOperationException("The CafeLauncher backend returned incomplete action data.");
        return result;
    }

    private static string RequiredString(Dictionary<string, object> value, string key)
    {
        object item;
        string result;
        if (!value.TryGetValue(key, out item) || (result = item as string) == null)
            throw new InvalidOperationException("The CafeLauncher backend returned incomplete action data.");
        return result;
    }

    private static string OptionalString(Dictionary<string, object> value, string key)
    {
        object item;
        if (!value.TryGetValue(key, out item) || item == null) return null;
        string result = item as string;
        if (result == null) throw new InvalidOperationException("The CafeLauncher backend returned invalid action data.");
        return result;
    }

    private static bool RequiredBoolean(Dictionary<string, object> value, string key)
    {
        object item;
        if (!value.TryGetValue(key, out item) || !(item is bool)) throw new InvalidOperationException("The PC detection result is invalid.");
        return (bool)item;
    }

    private static string Hash(byte[] bytes)
    {
        using (SHA256 sha = SHA256.Create())
        {
            StringBuilder value = new StringBuilder(64);
            foreach (byte item in sha.ComputeHash(bytes)) value.Append(item.ToString("x2"));
            return value.ToString();
        }
    }

    private static string SafeMessage(Exception error)
    {
        // Do not display request IDs, bearer capabilities, or response bodies.
        return error is WebException
            ? "CafeLauncher could not reach its secure backend. Check the connection and retry from the website."
            : error is TimeoutException
                ? error.Message
                : error is InvalidOperationException ? error.Message
                : "CafeLauncher could not complete this local action. Check the CafeLauncher log and retry.";
    }
}
