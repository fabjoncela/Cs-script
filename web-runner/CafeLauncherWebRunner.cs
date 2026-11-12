// Minimal .NET Framework runner for the CafeLauncher web-action protocol.
// State-changing actions are bound to short-lived backend tickets and the
// verified CafeLauncher release.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
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
    private const string RunnerVersion = "0.1.0";
    private const int MaxLauncherBytes = 1000000;
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 2 * 1024 * 1024 };

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 1 && args[0] == "--register") return RegisterProtocol();
            if (args.Length == 1 && args[0] == "--unregister") return UnregisterProtocol();
            if (args.Length != 1) throw new InvalidOperationException("Open CafeLauncher from the CafeLauncher website on this PC.");

            string requestId = ParseRequestUri(args[0]);
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            ServicePointManager.Expect100Continue = false;

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
            if (action != "detect-pc" && action != "play-exec")
                throw new InvalidOperationException("This CafeLauncher action is not supported by the installed runner.");
            if (action == "detect-pc" && profile != null)
                throw new InvalidOperationException("Detect PC must not include a profile.");
            if (action == "play-exec") ProfileCfg(profile);
            return ExecuteClaimedAction(requestId, action, profile, claimCapability);
        }
        catch (Exception error)
        {
            MessageBox.Show(SafeMessage(error), "CafeLauncher", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 1;
        }
    }

    private static int RegisterProtocol()
    {
        string executable = Process.GetCurrentProcess().MainModule.FileName;
        string expectedCommand = "\"" + executable + "\" \"%1\"";
        using (RegistryKey existing = Registry.CurrentUser.OpenSubKey(@"Software\Classes\cafelauncher\shell\open\command", false))
        {
            string registeredCommand = existing == null ? null : existing.GetValue(null) as string;
            if (registeredCommand != null && !String.Equals(registeredCommand, expectedCommand, StringComparison.OrdinalIgnoreCase))
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
        MessageBox.Show("CafeLauncher web links are registered for this Windows user.", "CafeLauncher", MessageBoxButtons.OK, MessageBoxIcon.Information);
        return 0;
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

    private static int ExecuteClaimedAction(string requestId, string action, string profile, string capability)
    {
        SendEvent(requestId, capability, "RUNNING", "Runner claimed request", "SUCCESS", "CafeLauncher runner is ready on this Windows session.", null);
        if (action != "detect-pc" && action != "play-exec")
        {
            SendEvent(requestId, capability, "FAILED", null, null, null, FailureResult(action, profile, "This action is not supported by the installed runner."));
            return 1;
        }
        if (action == "play-exec") ProfileCfg(profile);

        bool actionMayHaveRun = false;
        bool localPlayOutcomeKnown = false;
        try
        {
            Dictionary<string, object> release = GetLatestVerifiedLauncher();
            string launcherPath = (string)release["path"];
            SendEvent(requestId, capability, "RUNNING", "Launcher verification", "SUCCESS", "Downloaded launcher size and SHA-256 match the immutable release manifest.", null);
            actionMayHaveRun = action == "play-exec";
            Dictionary<string, object> detection = RunLauncherAction(launcherPath, requestId, action, profile);
            if (action == "play-exec")
            {
                if (Convert.ToInt32(detection["schemaVersion"]) != 1)
                    throw new InvalidOperationException("The launcher action result used an unsupported schema.");
                string terminalState = RequiredString(detection, "state");
                if (terminalState != "COMPLETED" && terminalState != "PARTIAL" && terminalState != "SKIPPED" && terminalState != "FAILED" && terminalState != "INTERRUPTED")
                    throw new InvalidOperationException("The launcher returned an unsupported Play + Exec result state.");
                Dictionary<string, object> playResult = GetDictionary(detection, "result");
                ValidatePlayResult(playResult, profile, terminalState);
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

    private static Dictionary<string, object> RunLauncherAction(string launcherPath, string requestId, string action, string profile)
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
            if (profile != null) start.EnvironmentVariables["CAFE_WEB_PROFILE"] = profile;
            using (Process process = Process.Start(start))
            {
                if (process == null) throw new InvalidOperationException("Windows PowerShell could not be started.");
                if (!process.WaitForExit(120000))
                {
                    try { process.Kill(); } catch { }
                    throw new TimeoutException("The CafeLauncher action took too long and was stopped.");
                }
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
        HttpWebRequest request = CreateRequest(uri, "GET");
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
