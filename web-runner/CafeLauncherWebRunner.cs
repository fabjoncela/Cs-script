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
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("CafeLauncher Web Runner")]
[assembly: AssemblyDescription("Per-user Windows companion for CafeLauncher web actions.")]
[assembly: AssemblyCompany("CafeLauncher")]
[assembly: AssemblyProduct("CafeLauncher Web Runner")]
[assembly: AssemblyVersion("0.7.6.0")]
[assembly: AssemblyFileVersion("0.7.6.0")]

internal static class CafeLauncherWebRunner
{
    private const string BackendOrigin = "https://fabjon-hp.tail681ec9.ts.net:10000";
    private const string RunnerVersion = "0.7.6";
    private const string RunnerUninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\CafeLauncherWebRunner";
    private const int MaxLauncherBytes = 1000000;
    private const int MaxRunnerBytes = 8 * 1024 * 1024;
    private const int MaxLogitechHelperBytes = 10 * 1024 * 1024;
    private const int MaxGraphicsModuleBytes = 8 * 1024 * 1024;
    private const string LogitechHelperUrl = "https://github.com/fabjoncela/better-logihub/releases/download/v0.1.0-c54d.1/logihub.exe";
    private const string LogitechHelperSha256 = "dc30e45d4ba1df7d043c7c9a0aacda4257e09f5f23bb980466b985b77aa7dda4";
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 2 * 1024 * 1024 };
    private static readonly object RunnerLogLock = new object();
    private sealed class ActionCanceledException : Exception { }

    [STAThread]
    private static int Main(string[] args)
    {
        bool warmupRequested = args != null && args.Length > 0 && IsWarmupUri(args[0]);
        try
        {
            if (args.Length == 0) return InstallForCurrentUser();
            if (args.Length == 1 && args[0] == "--register") return RegisterProtocol(Process.GetCurrentProcess().MainModule.FileName);
            if (args.Length == 1 && args[0] == "--unregister") return UnregisterProtocol();
            if (args.Length == 1 && args[0] == "--uninstall") return UninstallForCurrentUser();
            if (args.Length < 1 || args.Length > 2 || (args.Length == 2 && args[1] != "--after-update"))
                throw new InvalidOperationException("Open CafeLauncher from the CafeLauncher website on this PC.");

            string requestId = warmupRequested ? null : ParseRequestUri(args[0]);
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            ServicePointManager.Expect100Continue = false;
            WriteRunnerLog("Accepted a CafeLauncher web action link.");
            bool startedAfterUpdate = args.Length == 2;
            WriteUninstallRegistrationIfInstalled(Process.GetCurrentProcess().MainModule.FileName);
            bool profileResetPending = File.Exists(PendingProfileResetPath());
            if (!startedAfterUpdate)
            {
                string updatedRunner = TryUpdateRunner();
                if (updatedRunner != null)
                {
                    StartUpdatedRunner(updatedRunner, args[0]);
                    return 0;
                }
            }

            if (warmupRequested)
            {
                WarmupRunner();
                return 0;
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
            WriteRunnerLog("Claimed web action " + action + ".");
            if (RequiredString(ticket, "state") != "CLAIMED")
                throw new InvalidOperationException("CafeLauncher returned a request that was not newly claimed.");
            if (!String.Equals(RequiredString(ticket, "requestId"), requestId, StringComparison.Ordinal))
                throw new InvalidOperationException("CafeLauncher returned a different action request.");
            if (!IsSupportedAction(action))
                throw new InvalidOperationException("This CafeLauncher action is not supported by the installed runner.");
            if (action == "detect-pc" && profile != null)
                throw new InvalidOperationException("Detect PC must not include a profile.");
            if (action != "detect-pc") ProfileCfg(profile);
            int profileRevision = 0;
            if (action != "detect-pc")
            {
                if (!ticket.ContainsKey("profileRevision") || ticket["profileRevision"] == null ||
                    !Int32.TryParse(Convert.ToString(ticket["profileRevision"], CultureInfo.InvariantCulture), NumberStyles.None, CultureInfo.InvariantCulture, out profileRevision) ||
                    profileRevision < 1)
                {
                    SendEvent(requestId, claimCapability, "FAILED", null, null, null,
                        FailureResult(action, profile, "The backend did not pin a valid profile revision to this action. Update the backend before retrying."));
                    return 1;
                }
            }
            return ExecuteClaimedAction(requestId, action, profile, profileRevision, claimCapability, startedAfterUpdate || profileResetPending);
        }
        catch (Exception error)
        {
            WriteRunnerLog("Runner stopped before completing the action handler (" + error.GetType().Name + ").");
            if (!warmupRequested) MessageBox.Show(SafeMessage(error), "CafeLauncher", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 1;
        }
    }

    internal static bool IsWarmupUri(string raw)
    {
        Uri uri;
        return raw != null && raw.Length <= 128 && Uri.TryCreate(raw, UriKind.Absolute, out uri) &&
            String.Equals(uri.Scheme, "cafelauncher", StringComparison.OrdinalIgnoreCase) &&
            String.Equals(uri.Host, "v1", StringComparison.Ordinal) && uri.UserInfo.Length == 0 && uri.Port == -1 &&
            uri.Query.Length == 0 && uri.Fragment.Length == 0 && uri.AbsolutePath == "/warmup";
    }

    private static void WarmupRunner()
    {
        WriteRunnerLog("Starting background preparation requested by the CafeLauncher page.");
        try
        {
            Dictionary<string, object> launcher = GetLatestActionLauncher("apply-graphics");
            WriteRunnerLog("Prepared verified CafeLauncher " + RequiredString(launcher, "version") + " (" + RequiredString(launcher, "source") + ") for the next action.");
            try
            {
                bool graphicsDownloaded = WarmupGraphicsModule((byte[])launcher["bytes"]);
                WriteRunnerLog(graphicsDownloaded ? "Downloaded and pinned-hash verified the graphics helper for the next action." : "The cached graphics helper passed its pinned Git blob check.");
            }
            catch (Exception error)
            {
                WriteRunnerLog("Could not prefetch the graphics helper (" + error.GetType().Name + "); Apply Game Graphics will retry it.");
            }
            try
            {
                bool helperDownloaded = EnsurePinnedLogitechHelper();
                WriteRunnerLog(helperDownloaded ? "Downloaded and SHA-256 verified the Logitech helper for the next action." : "The cached Logitech helper passed its pinned SHA-256 check.");
            }
            catch (Exception error)
            {
                WriteRunnerLog("Could not prefetch the Logitech helper (" + error.GetType().Name + "); Apply Profile will retry it.");
            }
        }
        catch (Exception error)
        {
            WriteRunnerLog("Could not prefetch CafeLauncher during background preparation (" + error.GetType().Name + "); the next action will retry.");
        }
    }

    private static bool WarmupGraphicsModule(byte[] launcherBytes)
    {
        if (launcherBytes == null || launcherBytes.Length == 0) throw new InvalidOperationException("The verified launcher source was empty.");
        string source = Encoding.UTF8.GetString(launcherBytes);
        Match function = Regex.Match(source,
            @"(?s)function Get-CafeVerifiedGraphicsModulePath\s*\{(.*?)\r?\n\}\s*\r?\nfunction Invoke-CafeGraphicsPresetCore",
            RegexOptions.CultureInvariant);
        if (!function.Success) throw new InvalidOperationException("The verified launcher has no supported graphics helper loader.");
        Match hash = Regex.Match(function.Groups[1].Value, @"\$expected='([0-9a-f]{40})'", RegexOptions.CultureInvariant);
        Match url = Regex.Match(function.Groups[1].Value,
            @"https://raw\.githubusercontent\.com/fabjoncela/Cs-script/main/graphics/ApplyGraphics\.ps1",
            RegexOptions.CultureInvariant);
        if (!hash.Success || !url.Success) throw new InvalidOperationException("The verified launcher has invalid graphics helper pins.");
        string destination = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CafeLauncher", "graphics-module.ps1");
        if (File.Exists(destination) && new FileInfo(destination).Length <= MaxGraphicsModuleBytes &&
            String.Equals(GitBlobSha(File.ReadAllBytes(destination)), hash.Groups[1].Value, StringComparison.Ordinal)) return false;

        Uri uri = new Uri(url.Value);
        HttpWebRequest request = (HttpWebRequest)WebRequest.Create(uri);
        request.Method = "GET";
        request.UserAgent = "CafeLauncher-WebRunner/" + RunnerVersion;
        request.Timeout = 20000;
        request.ReadWriteTimeout = 20000;
        request.AllowAutoRedirect = true;
        request.MaximumResponseHeadersLength = 32;
        byte[] bytes;
        using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
        using (Stream input = response.GetResponseStream())
        using (MemoryStream output = new MemoryStream())
        {
            if (!String.Equals(response.ResponseUri.Host, "raw.githubusercontent.com", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("GitHub redirected the graphics helper to an untrusted host.");
            byte[] buffer = new byte[8192];
            int read;
            while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
            {
                if (output.Length + read > MaxGraphicsModuleBytes) throw new InvalidOperationException("The graphics helper exceeded its size limit.");
                output.Write(buffer, 0, read);
            }
            bytes = output.ToArray();
        }
        if (!String.Equals(GitBlobSha(bytes), hash.Groups[1].Value, StringComparison.Ordinal))
            throw new InvalidOperationException("The downloaded graphics helper did not match the launcher-pinned Git blob SHA.");
        Directory.CreateDirectory(Path.GetDirectoryName(destination));
        string temporary = destination + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllBytes(temporary, bytes);
            if (!String.Equals(GitBlobSha(File.ReadAllBytes(temporary)), hash.Groups[1].Value, StringComparison.Ordinal))
                throw new InvalidOperationException("The cached graphics helper failed its Git blob SHA check.");
            if (File.Exists(destination)) File.Replace(temporary, destination, null);
            else File.Move(temporary, destination);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
        return true;
    }

    private static int InstallForCurrentUser()
    {
        string source = Process.GetCurrentProcess().MainModule.FileName;
        string destination = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CafeLauncher", "Runner", "CafeLauncherWebRunner.exe");
        string installedPath = Path.GetFullPath(destination);
        if (!String.Equals(Path.GetFullPath(source), installedPath, StringComparison.OrdinalIgnoreCase))
            InstallExecutable(source, installedPath);
        RegisterProtocol(installedPath);
        WriteUninstallRegistration(installedPath);
        string helperStatus;
        try
        {
            bool downloaded = EnsurePinnedLogitechHelper();
            helperStatus = downloaded ? " The pinned Logitech helper was downloaded and verified." : " The pinned Logitech helper is already verified and ready.";
        }
        catch (Exception error)
        {
            helperStatus = " The helper could not be cached now; Apply Profile will retry it when needed. " + SafeMessage(error);
        }
        MessageBox.Show("CafeLauncher is ready for this Windows user. Return to the website and click an action." + helperStatus, "CafeLauncher installed", MessageBoxButtons.OK, MessageBoxIcon.Information);
        return 0;
    }

    internal static void WriteUninstallRegistration(RegistryKey parent, string executable)
    {
        if (parent == null) throw new ArgumentNullException("parent");
        executable = Path.GetFullPath(executable);
        string directory = Path.GetDirectoryName(executable);
        Version version = new Version(RunnerVersion);
        // The per-user uninstall record also tells Windows' compatibility
        // assistant that this self-installing runner completed successfully.
        using (RegistryKey entry = parent.CreateSubKey("CafeLauncherWebRunner"))
        {
            if (entry == null) throw new InvalidOperationException("Could not register CafeLauncher in Windows installed apps.");
            entry.SetValue("DisplayName", "CafeLauncher Web Runner", RegistryValueKind.String);
            entry.SetValue("DisplayVersion", RunnerVersion, RegistryValueKind.String);
            entry.SetValue("Publisher", "CafeLauncher", RegistryValueKind.String);
            entry.SetValue("Language", 1033, RegistryValueKind.DWord);
            entry.SetValue("InstallLocation", directory, RegistryValueKind.String);
            entry.SetValue("DisplayIcon", "\"" + executable + "\",0", RegistryValueKind.String);
            entry.SetValue("UninstallString", "\"" + executable + "\" --uninstall", RegistryValueKind.String);
            entry.SetValue("NoModify", 1, RegistryValueKind.DWord);
            entry.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            entry.SetValue("VersionMajor", version.Major, RegistryValueKind.DWord);
            entry.SetValue("VersionMinor", version.Minor, RegistryValueKind.DWord);
        }
    }

    private static void WriteUninstallRegistration(string executable)
    {
        using (RegistryKey parent = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall"))
        {
            if (parent == null) throw new InvalidOperationException("Could not register CafeLauncher in Windows installed apps.");
            WriteUninstallRegistration(parent, executable);
        }
    }

    private static void WriteUninstallRegistrationIfInstalled(string executable)
    {
        if (IsManagedRunnerExecutable(executable)) WriteUninstallRegistration(executable);
    }

    private static int UninstallForCurrentUser()
    {
        string executable = Path.GetFullPath(Process.GetCurrentProcess().MainModule.FileName);
        if (!IsManagedRunnerExecutable(executable))
            throw new InvalidOperationException("Run CafeLauncher uninstall from its installed Windows account location.");

        ScheduleRunnerRemoval(executable);

        RemoveManagedProtocolRegistration();
        Registry.CurrentUser.DeleteSubKeyTree(RunnerUninstallKey, false);
        MessageBox.Show("CafeLauncher was removed for this Windows account.", "CafeLauncher removed", MessageBoxButtons.OK, MessageBoxIcon.Information);
        return 0;
    }

    private static void ScheduleRunnerRemoval(string executable)
    {
        string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(powershell)) throw new InvalidOperationException("Windows PowerShell was not found, so CafeLauncher could not finish uninstalling.");
        int parentProcessId = Process.GetCurrentProcess().Id;
        string runnerRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CafeLauncher", "Runner");
        string safeReleases = Path.Combine(runnerRoot, "releases").Replace("'", "''");
        string safeInstalledRunner = Path.Combine(runnerRoot, "CafeLauncherWebRunner.exe").Replace("'", "''");
        string script = "$parent = Get-Process -Id " + parentProcessId + " -ErrorAction SilentlyContinue; if ($null -ne $parent) { $parent.WaitForExit() }; Remove-Item -LiteralPath '" + safeReleases + "' -Force -Recurse -ErrorAction SilentlyContinue; Remove-Item -LiteralPath '" + safeInstalledRunner + "' -Force -ErrorAction Stop";
        string encodedScript = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
        ProcessStartInfo start = new ProcessStartInfo(powershell, "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand " + encodedScript);
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.WindowStyle = ProcessWindowStyle.Hidden;
        using (Process process = Process.Start(start))
        {
            if (process == null) throw new InvalidOperationException("Windows PowerShell could not finish uninstalling CafeLauncher.");
        }
    }

    private static void RemoveManagedProtocolRegistration()
    {
        using (RegistryKey existing = Registry.CurrentUser.OpenSubKey(@"Software\Classes\cafelauncher\shell\open\command", false))
        {
            string registeredCommand = existing == null ? null : existing.GetValue(null) as string;
            if (IsManagedRunnerCommand(registeredCommand))
                Registry.CurrentUser.DeleteSubKeyTree(@"Software\Classes\cafelauncher", false);
        }
    }

    private static bool IsManagedRunnerExecutable(string executable)
    {
        if (String.IsNullOrWhiteSpace(executable) || !String.Equals(Path.GetFileName(executable), "CafeLauncherWebRunner.exe", StringComparison.OrdinalIgnoreCase)) return false;
        string fullPath;
        try { fullPath = Path.GetFullPath(executable); }
        catch { return false; }
        string root = Path.GetFullPath(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CafeLauncher", "Runner"));
        string baseExecutable = Path.Combine(root, "CafeLauncherWebRunner.exe");
        if (String.Equals(fullPath, baseExecutable, StringComparison.OrdinalIgnoreCase)) return true;
        string releases = Path.Combine(root, "releases");
        string prefix = releases.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
        return fullPath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
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

    private static string TryUpdateRunner()
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
        WriteUninstallRegistration(destination);
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

    internal static bool IsPinnedLogitechHelper(byte[] bytes)
    {
        return bytes != null && String.Equals(Hash(bytes), LogitechHelperSha256, StringComparison.Ordinal);
    }

    internal static bool InstallPinnedLogitechHelper(byte[] bytes, string destination)
    {
        if (!IsPinnedLogitechHelper(bytes))
            throw new InvalidOperationException("The downloaded Logitech helper did not match its pinned SHA-256.");
        string destinationPath = Path.GetFullPath(destination);
        Directory.CreateDirectory(Path.GetDirectoryName(destinationPath));
        if (File.Exists(destinationPath) && new FileInfo(destinationPath).Length <= MaxLogitechHelperBytes &&
            IsPinnedLogitechHelper(File.ReadAllBytes(destinationPath))) return false;

        string temporaryPath = destinationPath + ".installing-" + Guid.NewGuid().ToString("N");
        try
        {
            File.WriteAllBytes(temporaryPath, bytes);
            if (!IsPinnedLogitechHelper(File.ReadAllBytes(temporaryPath)))
                throw new InvalidOperationException("CafeLauncher could not verify the cached Logitech helper.");
            if (File.Exists(destinationPath)) File.Replace(temporaryPath, destinationPath, null);
            else File.Move(temporaryPath, destinationPath);
            return true;
        }
        finally { if (File.Exists(temporaryPath)) File.Delete(temporaryPath); }
    }

    private static string LogitechHelperPath()
    {
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CafeLauncher", "logihub", "logihub.exe");
    }

    private static bool EnsurePinnedLogitechHelper()
    {
        string destination = LogitechHelperPath();
        if (File.Exists(destination) && new FileInfo(destination).Length <= MaxLogitechHelperBytes &&
            IsPinnedLogitechHelper(File.ReadAllBytes(destination))) return false;

        Uri uri = new Uri(LogitechHelperUrl);
        if (uri.Scheme != Uri.UriSchemeHttps || !String.Equals(uri.Host, "github.com", StringComparison.OrdinalIgnoreCase) ||
            uri.AbsolutePath != "/fabjoncela/better-logihub/releases/download/v0.1.0-c54d.1/logihub.exe" ||
            uri.Query.Length != 0 || uri.Fragment.Length != 0 || uri.UserInfo.Length != 0)
            throw new InvalidOperationException("CafeLauncher refused a Logitech helper URL outside the pinned release.");

        ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
        HttpWebRequest request = (HttpWebRequest)WebRequest.Create(uri);
        request.Method = "GET";
        request.UserAgent = "CafeLauncher-WebRunner/" + RunnerVersion;
        request.Timeout = 30000;
        request.ReadWriteTimeout = 30000;
        request.AllowAutoRedirect = true;
        request.MaximumResponseHeadersLength = 32;
        byte[] bytes;
        using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
        using (Stream stream = response.GetResponseStream())
        using (MemoryStream memory = new MemoryStream())
        {
            string host = response.ResponseUri.Host;
            if (host != "github.com" && host != "release-assets.githubusercontent.com" && host != "objects.githubusercontent.com")
                throw new InvalidOperationException("GitHub redirected the Logitech helper download to an untrusted host.");
            byte[] buffer = new byte[8192];
            int read;
            while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
            {
                if (memory.Length + read > MaxLogitechHelperBytes)
                    throw new InvalidOperationException("The Logitech helper download exceeded its size limit.");
                memory.Write(buffer, 0, read);
            }
            bytes = memory.ToArray();
        }
        return InstallPinnedLogitechHelper(bytes, destination);
    }

    private static void StartUpdatedRunner(string executable, string protocolUri)
    {
        ProcessStartInfo start = new ProcessStartInfo(executable, "\"" + protocolUri + "\" --after-update");
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

    private static int ExecuteClaimedAction(string requestId, string action, string profile, int profileRevision, string capability, bool runnerUpdated)
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
            if (action == "apply-profile")
            {
                SendEvent(requestId, capability, "RUNNING", "Logitech helper setup", "RUNNING",
                    "Checking the pinned Logitech helper cache before starting the profile action.", null);
                try
                {
                    bool downloaded = EnsurePinnedLogitechHelper();
                    SendEvent(requestId, capability, "RUNNING", "Logitech helper setup", "SUCCESS",
                        downloaded ? "The pinned Logitech helper was downloaded, SHA-256 verified, and cached." : "The cached Logitech helper passed its pinned SHA-256 check.", null);
                }
                catch (Exception error)
                {
                    SendEvent(requestId, capability, "RUNNING", "Logitech helper setup", "FAILED", SafeMessage(error), null);
                    throw new InvalidOperationException("The Logitech helper could not be prepared. Profile settings were not started.", error);
                }
                if (IsCancellationRequested(requestId, capability))
                {
                    SendEvent(requestId, capability, "CANCELED", null, null, null, CancellationResult(action, profile));
                    return 1;
                }
            }

            Dictionary<string, object> release = GetLatestActionLauncher(action);
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
            string releaseSource = OptionalString(release, "source");
            string verificationDetail = githubCompatibilityFallback
                ? "The current CafeLauncher source matched the official GitHub Contents API size and Git blob SHA."
                : releaseSource == "github"
                    ? "The newer GitHub main launcher matched its official Git blob SHA; the backend package is older."
                    : "Downloaded launcher size and SHA-256 match the immutable release manifest.";
            SendEvent(requestId, capability, "RUNNING", "Launcher verification", "SUCCESS", verificationDetail, null);
            if (action != "detect-pc" && IsCancellationRequested(requestId, capability))
            {
                SendEvent(requestId, capability, "CANCELED", null, null, null, CancellationResult(action, profile));
                return 1;
            }
            actionMayHaveRun = action != "detect-pc";
            Dictionary<string, object> detection = RunLauncherAction(launcherPath, requestId, action, profile, profileRevision, runnerUpdated, capability);
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
                    "The runner could not confirm whether the local action completed. " + SafeMessage(error) + " Check this PC before retrying.");
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
        return new Dictionary<string, object> { { "path", cachePath }, { "bytes", bytes }, { "version", version }, { "source", "backend" } };
    }

    private static Dictionary<string, object> GetLatestActionLauncher(string action)
    {
        Dictionary<string, object> backend = GetLatestVerifiedLauncher();
        try
        {
            Dictionary<string, object> github = GetLatestGithubLauncher();
            Dictionary<string, object> selected = SelectNewestLauncherSource(backend, github, action);
            if (Object.ReferenceEquals(selected, github))
                WriteRunnerLog("Using a newer hash-verified CafeLauncher from GitHub main.");
            return selected;
        }
        catch
        {
            WriteRunnerLog("Could not check GitHub for a newer CafeLauncher; continuing with the hash-verified backend package.");
            return backend;
        }
    }

    internal static Dictionary<string, object> SelectNewestLauncherSource(Dictionary<string, object> backend, Dictionary<string, object> github, string action)
    {
        if (backend == null) throw new ArgumentNullException("backend");
        if (github == null) return backend;
        string backendVersion = RequiredString(backend, "version");
        string githubVersion = RequiredString(github, "version");
        byte[] githubBytes = github.ContainsKey("bytes") ? github["bytes"] as byte[] : null;
        if (IsLauncherReleaseVersionNewer(githubVersion, backendVersion) && LauncherSupportsAction(githubBytes, action))
            return github;
        return backend;
    }

    internal static bool IsLauncherReleaseVersionNewer(string candidate, string current)
    {
        if (!Regex.IsMatch(candidate ?? String.Empty, @"^\d{4}\.\d{1,2}\.\d{1,2}\.\d+$", RegexOptions.CultureInvariant) ||
            !Regex.IsMatch(current ?? String.Empty, @"^\d{4}\.\d{1,2}\.\d{1,2}\.\d+$", RegexOptions.CultureInvariant)) return false;
        Version candidateVersion;
        Version currentVersion;
        return Version.TryParse(candidate, out candidateVersion) && Version.TryParse(current, out currentVersion) && candidateVersion > currentVersion;
    }

    private static Dictionary<string, object> GetLatestGithubLauncher()
    {
        const string endpoint = "https://api.github.com/repos/fabjoncela/Cs-script/contents/cafe.bat?ref=main";
        string cacheRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CafeLauncher", "Runner", "github");
        Directory.CreateDirectory(cacheRoot);
        string latestPath = Path.Combine(cacheRoot, "latest.json");
        string cachedEtag = null;
        string cachedVersion = null;
        string cachedSha = null;
        int cachedSize = 0;
        byte[] cachedBytes = null;
        Dictionary<string, object> cachedResult = null;
        Dictionary<string, object> latestMetadata = null;
        DateTime lastWriteUtc = DateTime.MinValue;
        if (File.Exists(latestPath))
        {
            try
            {
                lastWriteUtc = File.GetLastWriteTimeUtc(latestPath);
                latestMetadata = ParseJson(File.ReadAllText(latestPath, Encoding.UTF8));
                cachedVersion = RequiredString(latestMetadata, "version");
                cachedSha = RequiredString(latestMetadata, "sha").ToLowerInvariant();
                cachedSize = Convert.ToInt32(latestMetadata["size"]);
                cachedEtag = OptionalString(latestMetadata, "etag");
                if (Regex.IsMatch(cachedVersion, @"^\d{4}\.\d{1,2}\.\d{1,2}\.\d+$", RegexOptions.CultureInvariant) &&
                    cachedSize >= 10000 && cachedSize <= MaxLauncherBytes && Regex.IsMatch(cachedSha, @"^[0-9a-f]{40}$", RegexOptions.CultureInvariant))
                {
                    string cachedPath = Path.Combine(cacheRoot, cachedSha, "cafe.bat");
                    if (File.Exists(cachedPath)) cachedBytes = File.ReadAllBytes(cachedPath);
                    if (IsValidGithubLauncherCache(cachedVersion, cachedSha, cachedSize, cachedBytes))
                        cachedResult = new Dictionary<string, object> { { "path", cachedPath }, { "bytes", cachedBytes }, { "version", cachedVersion }, { "source", "github" } };
                }
                if (cachedResult == null) cachedEtag = null;
            }
            catch
            {
                cachedEtag = null;
                cachedResult = null;
            }
        }
        if (cachedResult != null && IsGithubLauncherMetadataCacheFresh(lastWriteUtc, DateTime.UtcNow))
            return cachedResult;

        HttpWebRequest request = CreateGithubRequest(new Uri(endpoint), "GET", 5000);
        if (cachedResult != null && !String.IsNullOrEmpty(cachedEtag))
            request.Headers[HttpRequestHeader.IfNoneMatch] = cachedEtag;
        HttpWebResponse response = null;
        try
        {
            response = (HttpWebResponse)request.GetResponse();
        }
        catch (WebException error)
        {
            HttpWebResponse failedResponse = error.Response as HttpWebResponse;
            if (failedResponse == null)
                throw;
            string notModifiedEtag = error.Response.Headers[HttpResponseHeader.ETag];
            bool reusable = CanReuseGithubLauncherAfterNotModified((int)failedResponse.StatusCode, cachedEtag, notModifiedEtag, cachedResult != null);
            failedResponse.Dispose();
            if (!reusable) throw;
            string retainedEtag = String.IsNullOrEmpty(notModifiedEtag) ? cachedEtag : notModifiedEtag;
            WriteGithubLauncherLatestCache(latestPath, cachedVersion, cachedSha, cachedSize, retainedEtag);
            return cachedResult;
        }

        using (response)
        {
            if (CanReuseGithubLauncherAfterNotModified((int)response.StatusCode, cachedEtag, response.Headers[HttpResponseHeader.ETag], cachedResult != null))
            {
                string retainedEtag = response.Headers[HttpResponseHeader.ETag];
                if (String.IsNullOrEmpty(retainedEtag)) retainedEtag = cachedEtag;
                WriteGithubLauncherLatestCache(latestPath, cachedVersion, cachedSha, cachedSize, retainedEtag);
                return cachedResult;
            }
            if (response.StatusCode != HttpStatusCode.OK)
                throw new InvalidOperationException("GitHub returned an unexpected status while checking the latest CafeLauncher source.");
            using (Stream input = response.GetResponseStream())
            using (MemoryStream output = new MemoryStream())
            {
                byte[] buffer = new byte[8192];
                int read;
                while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
                {
                    if (output.Length + read > 2 * MaxLauncherBytes)
                        throw new InvalidOperationException("A GitHub launcher response exceeded its size limit.");
                    output.Write(buffer, 0, read);
                }
                latestMetadata = ParseJson(Encoding.UTF8.GetString(output.ToArray()));
            }
            string responseEtag = response.Headers[HttpResponseHeader.ETag];
            byte[] bytes = ValidateGithubLauncherPayload(latestMetadata);
            Match version = Regex.Match(Encoding.UTF8.GetString(bytes), @"(?m)^# CAFE_RELEASE=(\d{4}\.\d{1,2}\.\d{1,2}\.\d+)\s*$", RegexOptions.CultureInvariant);
            if (!version.Success) throw new InvalidOperationException("The current CafeLauncher source has no valid release marker.");
            string sha = RequiredString(latestMetadata, "sha").ToLowerInvariant();
            string cachePath = Path.Combine(cacheRoot, sha, "cafe.bat");
            Directory.CreateDirectory(Path.GetDirectoryName(cachePath));
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
            WriteGithubLauncherLatestCache(latestPath, version.Groups[1].Value, sha, bytes.Length, responseEtag);
            return new Dictionary<string, object> { { "path", cachePath }, { "bytes", bytes }, { "version", version.Groups[1].Value }, { "source", "github" } };
        }
    }

    private static void WriteGithubLauncherLatestCache(string latestPath, string version, string sha, int size, string etag)
    {
        Dictionary<string, object> latestMetadata = new Dictionary<string, object>
        {
            { "version", version }, { "sha", sha }, { "size", size }
        };
        if (!String.IsNullOrEmpty(etag)) latestMetadata["etag"] = etag;
        string temporaryPath = latestPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporaryPath, Json.Serialize(latestMetadata), new UTF8Encoding(false));
            if (File.Exists(latestPath)) File.Delete(latestPath);
            File.Move(temporaryPath, latestPath);
        }
        finally
        {
            if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
        }
    }

    internal static bool IsValidGithubLauncherCache(string version, string sha, int size, byte[] bytes)
    {
        if (bytes == null || bytes.Length != size || size < 10000 || size > MaxLauncherBytes ||
            !Regex.IsMatch(sha ?? String.Empty, @"^[0-9a-f]{40}$", RegexOptions.CultureInvariant) ||
            !Regex.IsMatch(version ?? String.Empty, @"^\d{4}\.\d{1,2}\.\d{1,2}\.\d+$", RegexOptions.CultureInvariant) ||
            !String.Equals(GitBlobSha(bytes), sha, StringComparison.Ordinal)) return false;
        Match marker = Regex.Match(Encoding.UTF8.GetString(bytes), @"(?m)^# CAFE_RELEASE=(\d{4}\.\d{1,2}\.\d{1,2}\.\d+)\s*$", RegexOptions.CultureInvariant);
        return marker.Success && marker.Groups[1].Value == version;
    }

    internal static bool CanReuseGithubLauncherAfterNotModified(int statusCode, string cachedEtag, string responseEtag, bool cacheValid)
    {
        if (statusCode != 304 || !cacheValid) return false;
        return String.IsNullOrEmpty(responseEtag) || String.IsNullOrEmpty(cachedEtag) ||
            String.Equals(responseEtag, cachedEtag, StringComparison.Ordinal);
    }

    internal static bool IsGithubLauncherMetadataCacheFresh(DateTime lastWriteUtc, DateTime nowUtc)
    {
        TimeSpan age = nowUtc - lastWriteUtc;
        return age >= TimeSpan.Zero && age < TimeSpan.FromMinutes(3);
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

    private static Dictionary<string, object> RunLauncherAction(string launcherPath, string requestId, string action, string profile, int profileRevision, bool runnerUpdated, string capability)
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
            if (action != "detect-pc") start.EnvironmentVariables["CAFE_WEB_PROFILE_REVISION"] = profileRevision.ToString(CultureInfo.InvariantCulture);
            if (runnerUpdated) start.EnvironmentVariables["CAFE_WEB_RUNNER_UPDATED"] = "1";
            if (profile != null) start.EnvironmentVariables["CAFE_WEB_PROFILE"] = profile;
            using (Process process = Process.Start(start))
            {
                if (process == null) throw new InvalidOperationException("Windows PowerShell could not be started.");
                WriteRunnerLog("Started the local PowerShell action host.");
                DateTime deadline = DateTime.UtcNow.AddMilliseconds(120000);
                DateTime nextControlCheck = DateTime.MinValue;
                DateTime resultFirstObserved = DateTime.MinValue;
                int nextProgressIndex = 1;
                Dictionary<string, object> completedResult = null;
                while (!process.WaitForExit(250))
                {
                    ForwardProgressEvents(progressDirectory, requestId, capability, ref nextProgressIndex);
                    if (action != "detect-pc")
                    {
                        Dictionary<string, object> candidate;
                        if (TryReadCompletedLauncherResult(resultPath, out candidate))
                        {
                            if (resultFirstObserved == DateTime.MinValue)
                            {
                                resultFirstObserved = DateTime.UtcNow;
                                WriteRunnerLog("A valid final result file appeared; checking that it remains stable.");
                            }
                            else if (TryStopLauncherAfterCompletedResult(process, resultPath, resultFirstObserved, DateTime.UtcNow, out candidate))
                            {
                                completedResult = candidate;
                                WriteRunnerLog("Stopped the lingering PowerShell host after validating its stable result.");
                                break;
                            }
                        }
                        else resultFirstObserved = DateTime.MinValue;
                    }
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
                        string diagnostic = BuildLocalActionTimeoutDiagnostic(resultPath, progressDirectory);
                        WriteRunnerLog(diagnostic);
                        throw new TimeoutException(diagnostic);
                    }
                }
                ForwardProgressEvents(progressDirectory, requestId, capability, ref nextProgressIndex);
                if (completedResult == null && action != "detect-pc")
                    TryReadCompletedLauncherResult(resultPath, out completedResult);
                if ((process.ExitCode != 0 && completedResult == null) || !File.Exists(resultPath) || new FileInfo(resultPath).Length > 64 * 1024)
                    throw new InvalidOperationException("The verified launcher could not return a valid action result.");
                if (completedResult != null)
                {
                    WriteRunnerLog("Returned the validated local action result.");
                    return completedResult;
                }
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

    internal static bool TryReadCompletedLauncherResult(string resultPath, out Dictionary<string, object> result)
    {
        result = null;
        try
        {
            if (!File.Exists(resultPath)) return false;
            FileInfo info = new FileInfo(resultPath);
            if (info.Length <= 0 || info.Length > 64 * 1024) return false;
            Dictionary<string, object> candidate = Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(resultPath, Encoding.UTF8));
            object schema;
            object rawResult;
            if (candidate == null || !candidate.TryGetValue("schemaVersion", out schema) || Convert.ToInt32(schema, CultureInfo.InvariantCulture) != 1 ||
                !candidate.ContainsKey("state") || !candidate.TryGetValue("result", out rawResult)) return false;
            string state = candidate["state"] as string;
            Dictionary<string, object> payload = rawResult as Dictionary<string, object>;
            if (state != "COMPLETED" && state != "PARTIAL" && state != "SKIPPED" && state != "FAILED" && state != "INTERRUPTED") return false;
            if (payload == null || !payload.ContainsKey("summary") || !(payload["summary"] is string) ||
                !payload.ContainsKey("steps") || !payload.ContainsKey("data")) return false;
            result = candidate;
            return true;
        }
        catch { return false; }
    }

    internal static string BuildLocalActionTimeoutDiagnostic(string resultPath, string progressDirectory)
    {
        string resultStatus = "not present";
        try
        {
            if (File.Exists(resultPath))
            {
                FileInfo info = new FileInfo(resultPath);
                Dictionary<string, object> result;
                resultStatus = TryReadCompletedLauncherResult(resultPath, out result)
                    ? "valid final result present"
                    : "present but incomplete or invalid (" + info.Length.ToString(CultureInfo.InvariantCulture) + " bytes)";
            }
        }
        catch { resultStatus = "could not be read"; }

        string lastProgress = "none";
        try
        {
            string[] files = Directory.GetFiles(progressDirectory, "progress-*.json");
            Array.Sort(files, StringComparer.OrdinalIgnoreCase);
            for (int index = files.Length - 1; index >= 0; index--)
            {
                try
                {
                    Dictionary<string, object> progress = Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(files[index], Encoding.UTF8));
                    string name = RequiredString(progress, "name");
                    string status = RequiredString(progress, "status");
                    if (name.Length > 100) name = name.Substring(0, 100);
                    if (status.Length > 20) status = status.Substring(0, 20);
                    lastProgress = name + " (" + status + ")";
                    break;
                }
                catch { }
            }
        }
        catch { }

        return "The local CafeLauncher action exceeded 120 seconds and was stopped. Final result file: " + resultStatus + "; last local progress stage: " + lastProgress + ".";
    }

    internal static bool TryStopLauncherAfterCompletedResult(Process process, string resultPath, DateTime firstObservedUtc, DateTime nowUtc, out Dictionary<string, object> result)
    {
        result = null;
        if (nowUtc - firstObservedUtc < TimeSpan.FromSeconds(2) || !TryReadCompletedLauncherResult(resultPath, out result)) return false;
        if (process == null) { result = null; return false; }
        try
        {
            if (!process.HasExited) process.Kill();
            if (!process.WaitForExit(5000))
                throw new TimeoutException("CafeLauncher returned its result, but Windows PowerShell could not be stopped cleanly.");
            return true;
        }
        catch
        {
            result = null;
            throw;
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
                if (state != "RUNNING") WriteRunnerLog("Backend accepted final action state " + state + ".");
                return;
            }
            catch (Exception error)
            {
                lastError = error;
                System.Threading.Thread.Sleep(500 * (attempt + 1));
            }
        }
        WriteRunnerLog("Backend did not confirm an action event after retries (" + (lastError == null ? "unknown error" : lastError.GetType().Name) + ").");
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

    private static HttpWebRequest CreateGithubRequest(Uri uri, string method, int timeoutMilliseconds = 15000)
    {
        if (uri.Scheme != Uri.UriSchemeHttps || !String.Equals(uri.GetLeftPart(UriPartial.Authority), "https://api.github.com", StringComparison.OrdinalIgnoreCase) ||
            uri.AbsolutePath != "/repos/fabjoncela/Cs-script/contents/cafe.bat" || uri.Query != "?ref=main" || uri.Fragment.Length != 0 || uri.UserInfo.Length != 0)
            throw new InvalidOperationException("CafeLauncher refused a request outside the trusted GitHub source endpoint.");
        HttpWebRequest request = (HttpWebRequest)WebRequest.Create(uri);
        request.Method = method;
        request.UserAgent = "CafeLauncher-WebRunner/" + RunnerVersion;
        request.Accept = "application/vnd.github+json";
        request.Timeout = timeoutMilliseconds;
        request.ReadWriteTimeout = timeoutMilliseconds;
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

    private static void WriteRunnerLog(string message)
    {
        try
        {
            string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CafeLauncher", "Runner", "logs");
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, "runner.log");
            lock (RunnerLogLock)
            {
                FileInfo info = new FileInfo(path);
                if (info.Exists && info.Length > 512 * 1024)
                {
                    string previous = Path.Combine(directory, "runner.previous.log");
                    if (File.Exists(previous)) File.Delete(previous);
                    File.Move(path, previous);
                }
                string safeMessage = String.IsNullOrWhiteSpace(message) ? "Runner event." : message.Replace("\r", " ").Replace("\n", " ");
                if (safeMessage.Length > 600) safeMessage = safeMessage.Substring(0, 600);
                File.AppendAllText(path, DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture) + " [" + RunnerVersion + "] " + safeMessage + Environment.NewLine, new UTF8Encoding(false));
            }
        }
        catch { }
    }
}
