
@echo off
set "CAFE_SCRIPT=%~f0"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command "$l=Get-Content -LiteralPath $env:CAFE_SCRIPT; $i=[Array]::IndexOf($l,'# POWERSHELL_GUI'); if($i -ge 0){Invoke-Expression ($l[($i+1)..($l.Length-1)] -join [Environment]::NewLine)}"
exit /b

# POWERSHELL_GUI

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$BG = [System.Drawing.Color]::FromArgb(20,23,30)
$PANEL = [System.Drawing.Color]::FromArgb(31,36,46)
$BLUE = [System.Drawing.Color]::FromArgb(35,125,245)
$WHITE = [System.Drawing.Color]::FromArgb(240,243,248)
$MUTED = [System.Drawing.Color]::FromArgb(160,170,185)

$script:LogPath = Join-Path $env:TEMP "CafeLauncher.log"
$script:LogBox = $null
try { Set-Content -LiteralPath $script:LogPath -Value "" -Encoding UTF8 } catch {}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "HH:mm:ss"), $Level, $Message
    try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 } catch {}
    if ($script:LogBox -and -not $script:LogBox.IsDisposed) {
        try {
            if ($script:LogBox.InvokeRequired) {
                $null = $script:LogBox.BeginInvoke([Action]{
                    $script:LogBox.AppendText($line + [Environment]::NewLine)
                })
            } else {
                $script:LogBox.AppendText($line + [Environment]::NewLine)
                $script:LogBox.SelectionStart = $script:LogBox.TextLength
                $script:LogBox.ScrollToCaret()
            }
        } catch {}
    }
}
Write-Log "Launcher starting."

function Find-App {
    param([string[]]$Paths)
    foreach ($path in $Paths) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            return $path
        }
    }
    return $null
}

function Launch-App {
    param([string[]]$Paths,[string]$Name)
    $path = Find-App -Paths $Paths
    if ($path) {
        try {
            Start-Process -FilePath $path
        } catch {
            Write-Log "Could not launch $Name`: $($_.Exception.Message)" "ERROR"
            [System.Windows.Forms.MessageBox]::Show(
                "Could not launch $Name.`n$($_.Exception.Message)",
                "Cafe Launcher"
            )
        }
    } else {
        Write-Log "$Name was not found on this PC." "WARN"
        [System.Windows.Forms.MessageBox]::Show(
            "$Name was not found on this PC.",
            "Cafe Launcher"
        )
    }
}

function Get-ChromePath {
    return Find-App -Paths @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
}

function Open-FaceitMatchmaking {
    $chrome = Get-ChromePath
    if ($chrome) {
        Start-Process -FilePath $chrome -ArgumentList "https://www.faceit.com/en/matchmaking"
    } else {
        Start-Process "https://www.faceit.com/en/matchmaking"
    }
}

function Open-Spotify {
    $chrome = Get-ChromePath
    if ($chrome) {
        Start-Process -FilePath $chrome -ArgumentList "https://open.spotify.com/"
    } else {
        Start-Process "https://open.spotify.com/"
    }
}

function Open-MousePointerOptions {
    Start-Process -FilePath "$env:windir\System32\control.exe" -ArgumentList "main.cpl,,2"
}

# Windows API for mouse settings
if (-not ("FabMouseNative" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class FabMouseNative {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool SystemParametersInfo(
        uint action, uint uiParam, IntPtr pvParam, uint flags);
}
"@
}

function Apply-FabMode {
    $mousePath = "HKCU:\Control Panel\Mouse"
    Write-Log "FabMode started."

    try {
        # Write Windows mouse settings directly.
        Set-ItemProperty -Path $mousePath -Name MouseSensitivity -Value "10" -ErrorAction Stop
        Set-ItemProperty -Path $mousePath -Name MouseSpeed -Value "0" -ErrorAction Stop
        Set-ItemProperty -Path $mousePath -Name MouseThreshold1 -Value "0" -ErrorAction Stop
        Set-ItemProperty -Path $mousePath -Name MouseThreshold2 -Value "0" -ErrorAction Stop
        Write-Log "Mouse registry values written (speed 10; acceleration disabled)."

        # Apply disabled acceleration to the active Windows session.
        # SPI_SETMOUSE expects a pointer to three integers: threshold1, threshold2, acceleration.
        $mouseData = [Runtime.InteropServices.Marshal]::AllocHGlobal(12)
        try {
            [Runtime.InteropServices.Marshal]::WriteInt32($mouseData, 0, 0)
            [Runtime.InteropServices.Marshal]::WriteInt32($mouseData, 4, 0)
            [Runtime.InteropServices.Marshal]::WriteInt32($mouseData, 8, 0)
            $accelOk = [FabMouseNative]::SystemParametersInfo(
                0x0004, 0, $mouseData, 0x03
            )
            if ($accelOk) {
                Write-Log "Windows accepted SPI_SETMOUSE: acceleration disabled."
            } else {
                $accelError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                Write-Log "SPI_SETMOUSE failed; Win32 error=$accelError. Registry acceleration values remain saved." "WARN"
            }
        } finally {
            [Runtime.InteropServices.Marshal]::FreeHGlobal($mouseData)
        }

        # Apply pointer speed to the active Windows session.
        # IMPORTANT: For SPI_SETMOUSESPEED, pvParam is the numeric value itself
        # encoded as an IntPtr (1-20), NOT a pointer to a buffer.
        $apiOk = [FabMouseNative]::SystemParametersInfo(
            0x0071, 0, [IntPtr]10, 0x03
        )
        if ($apiOk) {
            Write-Log "Windows accepted SPI_SETMOUSESPEED speed 10 (6/11)."
        } else {
            $apiError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Write-Log "SPI_SETMOUSESPEED failed; Win32 error=$apiError. Registry values are saved, but active speed may not have changed." "ERROR"
        }

        # Read back the live speed using SPI_GETMOUSESPEED, which DOES require a pointer.
        $readSpeedPtr = [Runtime.InteropServices.Marshal]::AllocHGlobal(4)
        $speedReadOk = $false
        $actualSpeed = -1
        try {
            [Runtime.InteropServices.Marshal]::WriteInt32($readSpeedPtr, 0)
            $speedReadOk = [FabMouseNative]::SystemParametersInfo(
                0x0070, 0, $readSpeedPtr, 0
            )
            if ($speedReadOk) {
                $actualSpeed = [Runtime.InteropServices.Marshal]::ReadInt32($readSpeedPtr)
                Write-Log "Windows live pointer-speed read-back: $actualSpeed (requested 10)."
            } else {
                $readError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                Write-Log "SPI_GETMOUSESPEED read-back failed; Win32 error=$readError." "WARN"
            }
        } finally {
            [Runtime.InteropServices.Marshal]::FreeHGlobal($readSpeedPtr)
        }

        $apiVerified = $apiOk -and $speedReadOk -and ($actualSpeed -eq 10)
        if ($apiOk -and $speedReadOk -and ($actualSpeed -ne 10)) {
            Write-Log "Windows accepted the set call but reports live speed $actualSpeed instead of 10." "ERROR"
        }

        # Ask Windows to reload the mouse settings. This notification is best-effort:
        # failure here should not be confused with failure to write the registry.
        try {
            if (-not ("FabMouseNotify" -as [type])) {
                Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class FabMouseNotify {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam,
        uint fuFlags, uint uTimeout, out IntPtr result);
}
"@
            }
            $result = [IntPtr]::Zero
            $notify = [FabMouseNotify]::SendMessageTimeout(
                [IntPtr]0xffff, 0x001A, [IntPtr]::Zero,
                [IntPtr]::Zero, 2, 1000, [ref]$result
            )
            if ($notify -eq [IntPtr]::Zero) {
                Write-Log "Windows settings-change notification did not confirm delivery; registry values remain written." "WARN"
            } else {
                Write-Log "Windows settings-change notification sent."
            }
        } catch {
            Write-Log "Could not broadcast settings-change notification: $($_.Exception.Message)" "WARN"
        }

        # Verify that the requested values are present in the current user's profile.
        $current = Get-ItemProperty -Path $mousePath -ErrorAction Stop
        if ($current.MouseSensitivity -ne "10" -or
            $current.MouseSpeed -ne "0" -or
            $current.MouseThreshold1 -ne "0" -or
            $current.MouseThreshold2 -ne "0") {
            throw "Registry verification failed. Current values: sensitivity=$($current.MouseSensitivity), speed=$($current.MouseSpeed), threshold1=$($current.MouseThreshold1), threshold2=$($current.MouseThreshold2)."
        }

        Write-Log "FabMode registry verification passed." "INFO"
        if ($apiVerified) {
            Write-Log "FabMode applied and verified live pointer speed 10 (6/11)." "INFO"
            Open-MousePointerOptions
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "FabMode saved the registry values, but live pointer speed 10 could not be confirmed. Check LIVE LOGS for SPI_SETMOUSESPEED and SPI_GETMOUSESPEED results.",
                "FabMode - Apply Warning",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
    } catch {
        Write-Log "FabMode failed: $($_.Exception.Message)" "ERROR"
        [System.Windows.Forms.MessageBox]::Show(
            "FabMode error:`n$($_.Exception.Message)`n`nSee LIVE LOGS for details.",
            "FabMode",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

function Open-NvidiaControlPanel {
    Write-Log "Opening NVIDIA Control Panel (open-only; it does not itself apply requested options)."
    # Traditional desktop installation
    $paths = @(
        "$env:ProgramFiles\NVIDIA Corporation\Control Panel Client\nvcplui.exe",
        "${env:ProgramFiles(x86)}\NVIDIA Corporation\Control Panel Client\nvcplui.exe",
        "$env:windir\System32\nvcplui.exe"
    )

    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            try {
                Start-Process -FilePath $path -ErrorAction Stop
                return
            } catch {}
        }
    }

    # Microsoft Store / packaged app
    try {
        $app = Get-StartApps -ErrorAction Stop |
            Where-Object { $_.Name -match "NVIDIA Control Panel" } |
            Select-Object -First 1

        if ($app -and $app.AppID) {
            Start-Process -FilePath "explorer.exe" `
                -ArgumentList "shell:AppsFolder\$($app.AppID)" `
                -ErrorAction Stop
            return
        }
    } catch {}

    # Last fallback
    Write-Log "NVIDIA Control Panel executable/app not found; opening Store listing." "WARN"
    Start-Process "ms-windows-store://pdp/?ProductId=9NF8H0H7WMLT"
}


# Windows display-mode API and NVIDIA NVAPI first-stage settings helper.
# The display mode helper uses a byte-array placeholder for DEVMODE's 16-byte union,
# avoiding compiler/layout problems from the prior explicit union implementation.
try {
    if (-not ("FabDisplayNative" -as [type])) {
        Add-Type -ErrorAction Stop @"
using System;
using System.Runtime.InteropServices;

public static class FabDisplayNative {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;
        public int dmFields;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)] public byte[] dmUnion;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel;
        public int dmPelsWidth;
        public int dmPelsHeight;
        public int dmDisplayFlags;
        public int dmDisplayFrequency;
        public int dmICMMethod;
        public int dmICMIntent;
        public int dmMediaType;
        public int dmDitherType;
        public int dmReserved1;
        public int dmReserved2;
        public int dmPanningWidth;
        public int dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "EnumDisplaySettingsW")]
    public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsExW")]
    public static extern int ChangeDisplaySettingsEx(string deviceName, ref DEVMODE devMode,
        IntPtr hwnd, uint flags, IntPtr lParam);

    private static DEVMODE NewMode() {
        DEVMODE dm = new DEVMODE();
        dm.dmDeviceName = "";
        dm.dmFormName = "";
        dm.dmUnion = new byte[16];
        dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        return dm;
    }

    private static string ResultName(int code) {
        switch (code) {
            case 0: return "DISP_CHANGE_SUCCESSFUL";
            case 1: return "DISP_CHANGE_RESTART";
            case -1: return "DISP_CHANGE_FAILED";
            case -2: return "DISP_CHANGE_BADMODE";
            case -3: return "DISP_CHANGE_NOTUPDATED";
            case -4: return "DISP_CHANGE_BADFLAGS";
            case -5: return "DISP_CHANGE_BADPARAM";
            case -6: return "DISP_CHANGE_BADDUALVIEW";
            default: return "code " + code;
        }
    }

    public static bool TrySetDisplay1To1080p360(out string report) {
        const string device = @"\\.\DISPLAY1";
        DEVMODE candidate = NewMode();
        bool found = false;
        int count = 0;
        for (int i = 0; i < 4096; i++) {
            DEVMODE dm = NewMode();
            if (!EnumDisplaySettings(device, i, ref dm)) break;
            count++;
            if (dm.dmPelsWidth == 1920 && dm.dmPelsHeight == 1080 &&
                dm.dmDisplayFrequency == 360 && dm.dmBitsPerPel >= 24) {
                candidate = dm;
                found = true;
                if (dm.dmBitsPerPel >= 32) break;
            }
        }

        if (!found) {
            DEVMODE current = NewMode();
            string currentText = "current mode unavailable";
            if (EnumDisplaySettings(device, -1, ref current)) {
                currentText = current.dmPelsWidth + "x" + current.dmPelsHeight +
                    " @" + current.dmDisplayFrequency + "Hz";
            }
            report = device + " current=" + currentText +
                ". Windows did not advertise 1920x1080 @ 360Hz (modes checked: " +
                count + "). No display mode was changed.";
            return false;
        }

        candidate.dmFields |= 0x00040000 | 0x00080000 | 0x00100000 | 0x00400000;
        int test = ChangeDisplaySettingsEx(device, ref candidate, IntPtr.Zero, 0x00000002, IntPtr.Zero);
        if (test != 0) {
            report = "Windows rejected display-mode test: " + ResultName(test) + " (" + test + ").";
            return false;
        }
        int apply = ChangeDisplaySettingsEx(device, ref candidate, IntPtr.Zero, 0x00000001, IntPtr.Zero);
        if (apply != 0) {
            report = "Windows could not apply display mode: " + ResultName(apply) + " (" + apply + ").";
            return false;
        }

        DEVMODE after = NewMode();
        if (EnumDisplaySettings(device, -1, ref after)) {
            report = device + " now reports " + after.dmPelsWidth + "x" + after.dmPelsHeight +
                " @" + after.dmDisplayFrequency + "Hz, " + after.dmBitsPerPel +
                " bpp (requested 1920x1080 @ 360Hz).";
            return after.dmPelsWidth == 1920 && after.dmPelsHeight == 1080 &&
                after.dmDisplayFrequency == 360;
        }
        report = "Windows accepted display mode, but current mode could not be read back.";
        return true;
    }
}
"@
        Write-Log "Display-mode helper loaded."
    }
} catch {
    Write-Log "Display-mode helper could not compile/load: $($_.Exception.Message)" "ERROR"
}

try {
    if (-not ("FabNvApi" -as [type])) {
        Add-Type -ErrorAction Stop @"
using System;
using System.Runtime.InteropServices;

public static class FabNvApi {
    [DllImport("nvapi64.dll", EntryPoint = "nvapi_QueryInterface", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr NvApiQueryInterface(uint id);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiInitialize();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiUnload();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiEnumDisplayHandle(uint index, out IntPtr handle);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiGetAssociatedDisplayHandle([MarshalAs(UnmanagedType.LPStr)] string displayName, out IntPtr handle);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiGetDvcInfo(IntPtr handle, uint outputId, ref DvcInfo info);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiSetDvcLevel(IntPtr handle, uint outputId, int level);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiGetViewEx(IntPtr handle, ref NvDisplayPathInfo pathInfo, ref uint pathCount, ref uint viewMode);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiSetViewEx(IntPtr handle, ref NvDisplayPathInfo pathInfo, uint viewMode);

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct DvcInfo {
        public uint version;
        public int currentLevel;
        public int minLevel;
        public int maxLevel;
    }

    // NV_DISPLAY_PATH as defined by NVIDIA's NVAPI header. Bitfields are retained
    // in 32-bit containers so the rest of the path layout remains unchanged.
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct NvDisplayPath {
        public uint deviceMask;
        public uint sourceId;
        public uint primaryBits;
        public int connector;
        public uint width;
        public uint height;
        public uint depth;
        public int colorFormat;
        public int rotation;
        public int scaling;
        public uint refreshRate;
        public uint interlacedBits;
        public int tvFormat;
        public uint posx;
        public uint posy;
        public uint trailingBits;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct NvDisplayPathInfo {
        public uint version;
        public uint count;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 4, ArraySubType = UnmanagedType.Struct)]
        public NvDisplayPath[] path;
    }

    private static T Resolve<T>(uint id) where T : class {
        IntPtr p = NvApiQueryInterface(id);
        if (p == IntPtr.Zero) throw new Exception("NVAPI function 0x" + id.ToString("X8") + " is unavailable.");
        return (T)(object)Marshal.GetDelegateForFunctionPointer(p, typeof(T));
    }

    private static IntPtr GetDisplayHandle() {
        NvApiGetAssociatedDisplayHandle getAssociated = Resolve<NvApiGetAssociatedDisplayHandle>(0x35C29134);
        IntPtr handle;
        int status = getAssociated(@"\\.\DISPLAY1", out handle);
        if (status == 0 && handle != IntPtr.Zero) return handle;

        status = getAssociated(@"\\DISPLAY1", out handle);
        if (status == 0 && handle != IntPtr.Zero) return handle;

        NvApiEnumDisplayHandle enumerate = Resolve<NvApiEnumDisplayHandle>(0x9ABDD40D);
        status = enumerate(0, out handle);
        if (status != 0 || handle == IntPtr.Zero)
            throw new Exception("Could not locate an NVIDIA display handle (NVAPI status " + status + ").");
        return handle;
    }

    private static void Initialize(out NvApiUnload unload) {
        NvApiInitialize initialize = Resolve<NvApiInitialize>(0x0150E828);
        unload = Resolve<NvApiUnload>(0xD22BDD7E);
        int status = initialize();
        if (status != 0) throw new Exception("NvAPI_Initialize failed with status " + status + ".");
    }

    public static bool TrySetDigitalVibrance75(out string report) {
        NvApiUnload unload = null;
        bool initialized = false;
        try {
            Initialize(out unload);
            initialized = true;

            IntPtr handle = GetDisplayHandle();
            NvApiGetDvcInfo getInfo = Resolve<NvApiGetDvcInfo>(0x4085DE45);
            NvApiSetDvcLevel setLevel = Resolve<NvApiSetDvcLevel>(0x172409B4);

            DvcInfo info = new DvcInfo();
            info.version = (uint)(Marshal.SizeOf(typeof(DvcInfo)) | 0x10000);
            int status = getInfo(handle, 0, ref info);
            if (status != 0) throw new Exception("NvAPI_GetDVCInfo failed with status " + status + ".");
            if (info.maxLevel <= info.minLevel) throw new Exception("NVIDIA returned an invalid Digital Vibrance range.");

            // Map UI 75% onto the exact range advertised by the driver.
            int requested = info.minLevel + (int)Math.Round((info.maxLevel - info.minLevel) * 0.75);
            int setStatus = setLevel(handle, 0, requested);
            if (setStatus != 0) throw new Exception("NvAPI_SetDVCLevel failed with status " + setStatus + ".");

            DvcInfo verify = new DvcInfo();
            verify.version = (uint)(Marshal.SizeOf(typeof(DvcInfo)) | 0x10000);
            int verifyStatus = getInfo(handle, 0, ref verify);
            if (verifyStatus != 0) throw new Exception("Digital Vibrance was set, but read-back failed with status " + verifyStatus + ".");
            if (verify.currentLevel != requested)
                throw new Exception("NVIDIA accepted the Digital Vibrance request but reports " + verify.currentLevel + " (requested " + requested + ").");

            report = "Digital Vibrance set and verified at 75%: driver level " + verify.currentLevel +
                " (range " + verify.minLevel + "-" + verify.maxLevel + ") for the NVIDIA display associated with DISPLAY1.";
            return true;
        } catch (Exception ex) {
            report = "Digital Vibrance failed: " + ex.Message;
            return false;
        } finally {
            if (initialized && unload != null) { try { unload(); } catch {} }
        }
    }

    public static bool TrySetGpuFullscreenScaling(out string report) {
        NvApiUnload unload = null;
        bool initialized = false;
        try {
            Initialize(out unload);
            initialized = true;

            IntPtr handle = GetDisplayHandle();
            NvApiGetViewEx getView = Resolve<NvApiGetViewEx>(0xDBBC0AF4);
            NvApiSetViewEx setView = Resolve<NvApiSetViewEx>(0x06B89E68);

            NvDisplayPathInfo info = new NvDisplayPathInfo();
            info.path = new NvDisplayPath[4];
            info.count = 4;
            info.version = (uint)(Marshal.SizeOf(typeof(NvDisplayPathInfo)) | (4 << 16));
            uint pathCount = 4;
            uint viewMode = 0;
            int getStatus = getView(handle, ref info, ref pathCount, ref viewMode);
            if (getStatus != 0) throw new Exception("NvAPI_GetViewEx failed with status " + getStatus + ".");
            if (pathCount < 1 || pathCount > 4)
                throw new Exception("NVIDIA returned an unexpected display path count: " + pathCount + ".");
            if (info.path == null || info.path.Length < 4)
                throw new Exception("NVIDIA returned an invalid display-path array.");

            int target = -1;
            for (int i = 0; i < pathCount; i++) {
                if ((info.path[i].trailingBits & 1u) != 0) { target = i; break; } // bGDIPrimary
            }
            if (target < 0) {
                for (int i = 0; i < pathCount; i++) {
                    if ((info.path[i].primaryBits & 1u) != 0) { target = i; break; } // bPrimary
                }
            }
            if (target < 0) target = 0;

            int oldScaling = info.path[target].scaling;
            info.path[target].scaling = 2; // NV_SCALING_GPU_SCALING_TO_NATIVE = Force GPU - Full Screen
            info.count = pathCount;
            int setStatus = setView(handle, ref info, viewMode);
            if (setStatus != 0)
                throw new Exception("NvAPI_SetViewEx failed with status " + setStatus + ".");

            NvDisplayPathInfo verify = new NvDisplayPathInfo();
            verify.path = new NvDisplayPath[4];
            verify.count = 4;
            verify.version = (uint)(Marshal.SizeOf(typeof(NvDisplayPathInfo)) | (4 << 16));
            uint verifyCount = 4;
            uint verifyViewMode = 0;
            int verifyStatus = getView(handle, ref verify, ref verifyCount, ref verifyViewMode);
            if (verifyStatus != 0)
                throw new Exception("Scaling was submitted, but read-back failed with status " + verifyStatus + ".");

            int verifyTarget = target;
            if (verifyTarget >= verifyCount) verifyTarget = 0;
            int actualScaling = verify.path[verifyTarget].scaling;
            if (actualScaling != 2)
                throw new Exception("NVIDIA accepted the scaling request but read-back mode is " + actualScaling + ", not Force GPU - Full Screen (2).");

            report = "GPU scaling set and verified: Force GPU - Full Screen (mode 2). Previous mode was " +
                oldScaling + ". Target path index " + target + ".";
            return true;
        } catch (Exception ex) {
            report = "GPU full-screen scaling failed: " + ex.Message;
            return false;
        } finally {
            if (initialized && unload != null) { try { unload(); } catch {} }
        }
    }
}
"@
        Write-Log "NVIDIA NVAPI helper loaded."
    }
} catch {
    Write-Log "NVIDIA NVAPI helper could not compile/load: $($_.Exception.Message)" "ERROR"
}

function Apply-NvidiaGamingSettings {
    Write-Log "NVIDIA gaming-settings apply started."

    Write-Log "Attempting Windows display 1: 1920x1080 at 360 Hz."
    if ("FabDisplayNative" -as [type]) {
        try {
            $displayReport = ""
            $displayOk = [FabDisplayNative]::TrySetDisplay1To1080p360([ref]$displayReport)
            if ($displayOk) {
                Write-Log $displayReport
            } else {
                Write-Log $displayReport "WARN"
            }
        } catch {
            Write-Log "Display resolution/refresh attempt failed: $($_.Exception.Message)" "ERROR"
        }
    } else {
        Write-Log "Display resolution/refresh was not attempted because the Windows display helper is unavailable." "ERROR"
    }

    if ("FabNvApi" -as [type]) {
        try {
            $vibranceReport = ""
            $vibranceOk = [FabNvApi]::TrySetDigitalVibrance75([ref]$vibranceReport)
            if ($vibranceOk) {
                Write-Log $vibranceReport
            } else {
                Write-Log $vibranceReport "ERROR"
            }
        } catch {
            Write-Log "Digital Vibrance call failed unexpectedly: $($_.Exception.Message)" "ERROR"
        }

        try {
            $scalingReport = ""
            $scalingOk = [FabNvApi]::TrySetGpuFullscreenScaling([ref]$scalingReport)
            if ($scalingOk) {
                Write-Log $scalingReport
            } else {
                Write-Log $scalingReport "ERROR"
            }
        } catch {
            Write-Log "GPU full-screen scaling call failed unexpectedly: $($_.Exception.Message)" "ERROR"
        }
    } else {
        Write-Log "NVIDIA NVAPI helper is unavailable; Digital Vibrance and GPU scaling were not changed." "ERROR"
    }

    Write-Log "Still manual: Image Settings with Preview -> Use my preference emphasizing Performance."
    Write-Log "Still manual: Configure Surround, PhysX -> select the NVIDIA GPU."
    Write-Log "Still manual: Adjust desktop size and position -> enable override scaling mode set by games and programs."
    Write-Log "Still manual: Set up G-SYNC -> disable G-SYNC for display 1."
    Write-Log "Opening NVIDIA Control Panel. Stage-one settings have individual success/failure logs." "INFO"
    Open-NvidiaControlPanel
}

function Open-GHub {
    Launch-App -Name "Logitech G HUB" -Paths @(
        "$env:ProgramFiles\LGHUB\lghub.exe",
        "$env:ProgramFiles\LGHUB\lghub_system_tray.exe"
    )
}

function Launch-All {
    Launch-App -Name "Steam" -Paths @(
        "${env:ProgramFiles(x86)}\Steam\steam.exe",
        "$env:ProgramFiles\Steam\steam.exe"
    )

    Launch-App -Name "FACEIT Anti-Cheat" -Paths @(
        "$env:ProgramFiles\FACEIT AC\faceitclient.exe",
        "${env:ProgramFiles(x86)}\FACEIT AC\faceitclient.exe"
    )

    Open-FaceitMatchmaking
    Open-Spotify
    Open-GHub
}

# Main window
$form = New-Object System.Windows.Forms.Form
$form.Text = "Cafe Launcher"
$form.Size = New-Object System.Drawing.Size(800,850)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.BackColor = $BG
$form.ForeColor = $WHITE
$form.Font = New-Object System.Drawing.Font("Segoe UI",10)

# Header
$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point(0,0)
$header.Size = New-Object System.Drawing.Size(800,105)
$header.BackColor = $PANEL
$form.Controls.Add($header)

$title = New-Object System.Windows.Forms.Label
$title.Text = "GAMING CAFE"
$title.Location = New-Object System.Drawing.Point(28,18)
$title.Size = New-Object System.Drawing.Size(500,38)
$title.Font = New-Object System.Drawing.Font("Segoe UI",21,[System.Drawing.FontStyle]::Bold)
$title.ForeColor = $WHITE
$header.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = "APP LAUNCHER  |  PC SETTINGS"
$subtitle.Location = New-Object System.Drawing.Point(31,62)
$subtitle.Size = New-Object System.Drawing.Size(500,23)
$subtitle.Font = New-Object System.Drawing.Font("Segoe UI",9)
$subtitle.ForeColor = $MUTED
$header.Controls.Add($subtitle)

function New-Tile {
    param(
        [string]$Text,
        [int]$Index,
        [scriptblock]$Action,
        [switch]$Primary
    )

    $col = $Index % 3
    $row = [Math]::Floor($Index / 3)
    $x = 25 + ($col * 250)
    $y = 125 + ($row * 88)

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($x,$y)
    $button.Size = New-Object System.Drawing.Size(235,70)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 0
    if ($Primary) {
        $button.BackColor = $BLUE
    } else {
        $button.BackColor = $PANEL
    }
    $button.ForeColor = $WHITE
    $button.Font = New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold)
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $actionToRun = $Action
    $button.Add_Click({
        Write-Log "Clicked: $($this.Text)"
        try {
            & $actionToRun
        } catch {
            Write-Log "Button '$($this.Text)' failed: $($_.Exception.Message)" "ERROR"
            [System.Windows.Forms.MessageBox]::Show(
                "$($this.Text) failed:`n$($_.Exception.Message)",
                "Cafe Launcher"
            )
        }
    }.GetNewClosure())
    $form.Controls.Add($button)
}

New-Tile "LAUNCH ALL" 0 { Launch-All } -Primary

New-Tile "Steam" 1 {
    Launch-App -Name "Steam" -Paths @(
        "${env:ProgramFiles(x86)}\Steam\steam.exe",
        "$env:ProgramFiles\Steam\steam.exe"
    )
}

New-Tile "FACEIT Anti-Cheat" 2 {
    Launch-App -Name "FACEIT Anti-Cheat" -Paths @(
        "$env:ProgramFiles\FACEIT AC\faceitclient.exe",
        "${env:ProgramFiles(x86)}\FACEIT AC\faceitclient.exe"
    )
}

New-Tile "FACEIT Matchmaking" 3 { Open-FaceitMatchmaking }
New-Tile "Spotify" 4 { Open-Spotify }
New-Tile "FabMode" 5 { Apply-FabMode } -Primary
New-Tile "Mouse Pointer Options" 6 { Open-MousePointerOptions }
New-Tile "NVIDIA Control Panel" 7 { Open-NvidiaControlPanel }
New-Tile "Apply NVIDIA Settings" 8 { Apply-NvidiaGamingSettings } -Primary
New-Tile "Logitech G HUB" 9 { Open-GHub }
New-Tile "Exit" 10 { $form.Close() }

# Live diagnostic log panel (visible only while the launcher is open)
$logTitle = New-Object System.Windows.Forms.Label
$logTitle.Text = "LIVE LOGS  |  Errors and button activity"
$logTitle.Location = New-Object System.Drawing.Point(28,565)
$logTitle.Size = New-Object System.Drawing.Size(500,22)
$logTitle.Font = New-Object System.Drawing.Font("Segoe UI",9,[System.Drawing.FontStyle]::Bold)
$logTitle.ForeColor = $WHITE
$form.Controls.Add($logTitle)

$clearLogs = New-Object System.Windows.Forms.Button
$clearLogs.Text = "Clear Logs"
$clearLogs.Location = New-Object System.Drawing.Point(670,561)
$clearLogs.Size = New-Object System.Drawing.Size(100,27)
$clearLogs.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$clearLogs.FlatAppearance.BorderSize = 0
$clearLogs.BackColor = $PANEL
$clearLogs.ForeColor = $WHITE
$clearLogs.Add_Click({
    if ($script:LogBox) { $script:LogBox.Clear() }
    try { Set-Content -LiteralPath $script:LogPath -Value "" -Encoding UTF8 } catch {}
    Write-Log "Logs cleared."
})
$form.Controls.Add($clearLogs)

$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Location = New-Object System.Drawing.Point(28,592)
$script:LogBox.Size = New-Object System.Drawing.Size(742,175)
$script:LogBox.Multiline = $true
$script:LogBox.ReadOnly = $true
$script:LogBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$script:LogBox.WordWrap = $false
$script:LogBox.BackColor = [System.Drawing.Color]::FromArgb(12,15,20)
$script:LogBox.ForeColor = [System.Drawing.Color]::FromArgb(190,220,190)
$script:LogBox.Font = New-Object System.Drawing.Font("Consolas",9)
try {
    $script:LogBox.Text = Get-Content -LiteralPath $script:LogPath -Raw -ErrorAction Stop
    $script:LogBox.SelectionStart = $script:LogBox.TextLength
    $script:LogBox.ScrollToCaret()
} catch {}
$form.Controls.Add($script:LogBox)
Write-Log "Launcher ready. Log file: $script:LogPath"

# Footer
$footer = New-Object System.Windows.Forms.Label
$footer.Text = "GAMING CAFE  |  WINDOWS TOOLKIT  |  LOG: %TEMP%\CafeLauncher.log"
$footer.Location = New-Object System.Drawing.Point(28,780)
$footer.Size = New-Object System.Drawing.Size(740,22)
$footer.Font = New-Object System.Drawing.Font("Segoe UI",8)
$footer.ForeColor = $MUTED
$form.Controls.Add($footer)

[void]$form.ShowDialog()
