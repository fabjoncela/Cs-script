
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
    param([switch]$SkipPointerOptions)
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
            if (-not $SkipPointerOptions) { Open-MousePointerOptions }
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
using System.Collections.Generic;
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

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiDispGetDisplayConfig(ref uint pathCount, IntPtr pathInfo);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiDispSetDisplayConfig(uint pathCount, IntPtr pathInfo, uint flags);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiDispGetDisplayIdByDisplayName(
        [MarshalAs(UnmanagedType.LPStr)] string displayName, out uint displayId);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiDrsCreateSession(out IntPtr session);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiDrsDestroySession(IntPtr session);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiDrsLoadSettings(IntPtr session);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiDrsSaveSettings(IntPtr session);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiDrsGetCurrentGlobalProfile(IntPtr session, out IntPtr profile);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiDrsGetSetting(IntPtr session, IntPtr profile, uint settingId, IntPtr setting);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiDrsSetSetting(IntPtr session, IntPtr profile, IntPtr setting);

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct NvDisplayConfigPathInfoV2 {
        public uint version;
        public uint sourceId;
        public uint targetInfoCount;
        public IntPtr targetInfo;
        public IntPtr sourceModeInfo;
        public uint adapterFlags;
        public IntPtr osAdapterId;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct NvDisplayConfigTargetInfoV2 {
        public uint displayId;
        public IntPtr details;
        public uint targetId;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct NvDisplayConfigSourceModeInfoV1 {
        public uint width;
        public uint height;
        public uint colorDepth;
        public int colorFormat;
        public int positionX;
        public int positionY;
        public int spanningOrientation;
        public uint flags;
    }

    // NV_DISPLAYCONFIG_PATH_ADVANCED_TARGET_INFO_V1 is 128 bytes:
    // its 32-byte header is followed by the 96-byte NV_TIMING structure.
    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct NvDisplayConfigAdvancedTargetInfoV1 {
        public uint version;
        public int rotation;
        public int scaling;
        public uint refreshRate1K;
        public uint flags;
        public int connector;
        public int tvFormat;
        public int timingOverride;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 96)]
        public byte[] timing;
    }

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

    public static bool TryReadDigitalVibrance(out int currentLevel, out int minLevel, out int maxLevel, out string report) {
        NvApiUnload unload = null;
        bool initialized = false;
        currentLevel = -1;
        minLevel = -1;
        maxLevel = -1;
        try {
            Initialize(out unload);
            initialized = true;

            IntPtr handle = GetDisplayHandle();
            NvApiGetDvcInfo getInfo = Resolve<NvApiGetDvcInfo>(0x4085DE45);
            DvcInfo info = new DvcInfo();
            info.version = (uint)(Marshal.SizeOf(typeof(DvcInfo)) | 0x10000);
            int status = getInfo(handle, 0, ref info);
            if (status != 0)
                throw new Exception("NvAPI_GetDVCInfo failed with status " + status + ".");

            currentLevel = info.currentLevel;
            minLevel = info.minLevel;
            maxLevel = info.maxLevel;
            report = "NVIDIA reports Digital Vibrance driver level " + currentLevel +
                " (range " + minLevel + "-" + maxLevel + ").";
            return true;
        } catch (Exception ex) {
            report = ex.Message;
            return false;
        } finally {
            if (initialized && unload != null) { try { unload(); } catch {} }
        }
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

    private static IntPtr AllocZeroed(List<IntPtr> allocations, int bytes) {
        IntPtr p = Marshal.AllocHGlobal(bytes);
        byte[] zero = new byte[bytes];
        Marshal.Copy(zero, 0, p, bytes);
        allocations.Add(p);
        return p;
    }

    private static string ScalingStatus(int status) {
        if (status == -159) return "NVAPI_ADVANCED_DISPLAY_TOPOLOGY_REQUIRED";
        if (status == -158) return "NVAPI_SET_NOT_ALLOWED";
        if (status == -9) return "NVAPI_INCOMPATIBLE_STRUCT_VERSION";
        if (status == -5) return "NVAPI_INVALID_ARGUMENT";
        if (status == -104) return "NVAPI_NOT_SUPPORTED";
        if (status == -175) return "NVAPI_ACCESS_DENIED";
        return "NVAPI status " + status;
    }

    // NVDRS_SETTING_V1 from nvapi.h:
    // header(4) + Unicode name(2048 UTF-16 = 4096) + five DWORD fields(20)
    // + two NVDRS_BINARY_SETTING unions(4+4096 bytes each).
    // The original draft used the wrong size and current-value offset.
    private const int DrsSettingSize = 12320;
    private const int DrsSettingIdOffset = 4100;
    private const int DrsSettingTypeOffset = 4104;
    private const int DrsSettingCurrentValueOffset = 8220;

    private static IntPtr NewDrsSetting(uint id, uint? value) {
        IntPtr p = Marshal.AllocHGlobal(DrsSettingSize);
        Marshal.Copy(new byte[DrsSettingSize], 0, p, DrsSettingSize);
        Marshal.WriteInt32(p, 0, DrsSettingSize | (1 << 16));
        Marshal.WriteInt32(p, DrsSettingIdOffset, unchecked((int)id));
        Marshal.WriteInt32(p, DrsSettingTypeOffset, 0); // NVDRS_DWORD_TYPE
        if (value.HasValue) {
            Marshal.WriteInt32(p, DrsSettingCurrentValueOffset, unchecked((int)value.Value));
        }
        return p;
    }

    public static bool TryApplyPerformanceProfile(out string report) {
        NvApiUnload unload = null;
        NvApiDrsDestroySession destroySession = null;
        IntPtr session = IntPtr.Zero;
        IntPtr profile = IntPtr.Zero;
        bool initialized = false;
        List<string> messages = new List<string>();

        // Performance slider equivalent: NVIDIA's official slider table lists
        // Texture filtering = Quality, AA/AF = application-controlled, VSync =
        // force off, Trilinear + Anisotropic optimizations = On.
        // G-SYNC request: disable globally through driver profile. This does
        // NOT guarantee that the Set up G-SYNC checkbox is visually unchecked.
        uint[] ids = new uint[] {
            0x00CE2691, // QUALITY_ENHANCEMENTS_ID
            0x107EFC5B, // AA_MODE_SELECTOR_ID
            0x10D2BB16, // ANISO_MODE_SELECTOR_ID
            0x00A879CF, // VSYNCMODE_ID
            0x00E73211, // PS_TEXFILTER_ANISO_OPTS2_ID
            0x0084CD70, // PS_TEXFILTER_BILINEAR_IN_ANISO_ID
            0x002ECAF2, // PS_TEXFILTER_DISABLE_TRILIN_SLOPE_ID
            0x1194F158, // VRR_MODE_ID: disabled
            0x1094F1F7, // VRRREQUESTSTATE_ID: disabled
            0x10A879CF, // VRR_APP_OVERRIDE_ID: force off
            0x10A879AC  // VRR_APP_OVERRIDE_REQUEST_STATE_ID: force off
        };
        uint[] values = new uint[] {
            0x00000000, // QUALITY_ENHANCEMENTS_QUALITY - NVIDIA slider table
            0x00000000, // AA_MODE_SELECTOR_APP_CONTROL
            0x00000000, // ANISO_MODE_SELECTOR_APP
            0x08416747, // VSYNCMODE_FORCEOFF
            0x00000001, // PS_TEXFILTER_ANISO_OPTS2_ON
            0x00000001, // PS_TEXFILTER_BILINEAR_IN_ANISO_ON
            0x00000000, // leave disable-trilinear-slope OFF
            0x00000000, // VRR_MODE_DISABLED
            0x00000000, // VRRREQUESTSTATE_DISABLED
            0x00000001, // VRR_APP_OVERRIDE_FORCE_OFF
            0x00000001  // VRR_APP_OVERRIDE_REQUEST_STATE_FORCE_OFF
        };
        string[] names = new string[] {
            "Texture filtering quality = Quality (NVIDIA Performance slider table)",
            "Antialiasing = application controlled",
            "Anisotropic filtering = application controlled",
            "Vertical sync = force off",
            "Anisotropic sample optimization = on",
            "Anisotropic filter optimization = on",
            "Trilinear optimization related driver flag = off",
            "G-SYNC global mode = off",
            "G-SYNC global requested state = disabled",
            "G-SYNC application override = force off",
            "G-SYNC application requested state = force off"
        };

        try {
            Initialize(out unload);
            initialized = true;
            NvApiDrsCreateSession create = Resolve<NvApiDrsCreateSession>(0x0694D52E);
            destroySession = Resolve<NvApiDrsDestroySession>(0xDAD9CFF8);
            NvApiDrsLoadSettings load = Resolve<NvApiDrsLoadSettings>(0x375DBD6B);
            NvApiDrsSaveSettings save = Resolve<NvApiDrsSaveSettings>(0xFCBC7E14);
            NvApiDrsGetCurrentGlobalProfile global = Resolve<NvApiDrsGetCurrentGlobalProfile>(0x617BFF9F);
            NvApiDrsGetSetting get = Resolve<NvApiDrsGetSetting>(0x73BF8338);
            NvApiDrsSetSetting set = Resolve<NvApiDrsSetSetting>(0x577DD202);

            int result = create(out session);
            if (result != 0 || session == IntPtr.Zero) throw new Exception("DRS_CreateSession status=" + result);
            result = load(session);
            if (result != 0) throw new Exception("DRS_LoadSettings status=" + result);
            result = global(session, out profile);
            if (result != 0 || profile == IntPtr.Zero) throw new Exception("DRS_GetCurrentGlobalProfile status=" + result);

            bool[] accepted = new bool[ids.Length];
            for (int i = 0; i < ids.Length; i++) {
                IntPtr p = IntPtr.Zero;
                try {
                    p = NewDrsSetting(ids[i], null);
                    int getResult = get(session, profile, ids[i], p);
                    string previous = getResult == 0
                        ? "0x" + unchecked((uint)Marshal.ReadInt32(p, DrsSettingCurrentValueOffset)).ToString("X8")
                        : "not found (status " + getResult + ")";
                    Marshal.FreeHGlobal(p);
                    p = NewDrsSetting(ids[i], values[i]);
                    int setResult = set(session, profile, p);
                    if (setResult == 0) {
                        accepted[i] = true;
                        messages.Add("INFO: Submitted " + names[i] + "; previous=" + previous + ".");
                    } else {
                        messages.Add("WARN: Driver rejected " + names[i] + "; status=" + setResult + ".");
                    }
                } catch (Exception e) {
                    messages.Add("ERROR: " + names[i] + ": " + e.Message);
                } finally {
                    if (p != IntPtr.Zero) Marshal.FreeHGlobal(p);
                }
            }

            bool any = false;
            for (int i=0; i<accepted.Length; i++) if (accepted[i]) any = true;
            if (!any) throw new Exception("NVIDIA driver accepted none of the performance/G-SYNC settings.");

            result = save(session);
            if (result != 0) throw new Exception("DRS_SaveSettings failed with status=" + result);
            messages.Add("INFO: NVIDIA global profile saved. Re-loading to verify persisted values.");

            result = load(session);
            if (result != 0) throw new Exception("DRS_LoadSettings read-back status=" + result);
            result = global(session, out profile);
            if (result != 0 || profile == IntPtr.Zero) throw new Exception("DRS_GetCurrentGlobalProfile read-back status=" + result);

            int verifiedCount = 0;
            for (int i=0; i<ids.Length; i++) {
                if (!accepted[i]) continue;
                IntPtr p = IntPtr.Zero;
                try {
                    p = NewDrsSetting(ids[i], null);
                    int rc = get(session, profile, ids[i], p);
                    if (rc != 0) {
                        messages.Add("WARN: Read-back unavailable for " + names[i] + "; status=" + rc);
                    } else {
                        uint actual = unchecked((uint)Marshal.ReadInt32(p, DrsSettingCurrentValueOffset));
                        if (actual == values[i]) {
                            verifiedCount++;
                            messages.Add("INFO: Verified " + names[i] + ".");
                        } else {
                            messages.Add("ERROR: " + names[i] + " read-back mismatch (0x" + actual.ToString("X8") + ").");
                        }
                    }
                } catch (Exception e) {
                    messages.Add("ERROR: Read-back " + names[i] + ": " + e.Message);
                } finally {
                    if (p != IntPtr.Zero) Marshal.FreeHGlobal(p);
                }
            }

            bool allOk = verifiedCount == ids.Length;
            messages.Insert(0, "INFO: DRS global 3D + G-SYNC-off settings verified " +
                verifiedCount + "/" + ids.Length + ".");
            if (!allOk) messages.Add("WARN: Not every global driver setting was verified; inspect NVIDIA Control Panel.");
            report = String.Join("\n", messages.ToArray());
            return allOk;
        } catch (Exception e) {
            messages.Add("ERROR: DRS apply failed: " + e.Message);
            report = String.Join("\n", messages.ToArray());
            return false;
        } finally {
            if (session != IntPtr.Zero && destroySession != null) {
                try { destroySession(session); } catch {}
            }
            if (initialized && unload != null) {
                try { unload(); } catch {}
            }
        }
    }

    public static bool TrySetGpuFullscreenScaling(out string report) {
        NvApiUnload unload = null;
        bool initialized = false;
        IntPtr pathArray = IntPtr.Zero;
        List<IntPtr> allocations = new List<IntPtr>();

        try {
            Initialize(out unload);
            initialized = true;

            NvApiDispGetDisplayConfig getConfig =
                Resolve<NvApiDispGetDisplayConfig>(0x11ABCCF8);
            NvApiDispSetDisplayConfig setConfig =
                Resolve<NvApiDispSetDisplayConfig>(0x5D8CF8DE);
            NvApiDispGetDisplayIdByDisplayName getDisplayId =
                Resolve<NvApiDispGetDisplayIdByDisplayName>(0xAE457190);

            uint pathCount = 0;
            int status = getConfig(ref pathCount, IntPtr.Zero);
            if (status != 0)
                throw new Exception("NvAPI_DISP_GetDisplayConfig count query failed: " + ScalingStatus(status) + ".");
            if (pathCount < 1 || pathCount > 64)
                throw new Exception("Unexpected display configuration path count: " + pathCount + ".");

            int pathSize = Marshal.SizeOf(typeof(NvDisplayConfigPathInfoV2));
            int targetSize = Marshal.SizeOf(typeof(NvDisplayConfigTargetInfoV2));
            int sourceModeSize = Marshal.SizeOf(typeof(NvDisplayConfigSourceModeInfoV1));
            int advancedSize = Marshal.SizeOf(typeof(NvDisplayConfigAdvancedTargetInfoV1));
            if (advancedSize != 128)
                throw new Exception("Internal NVAPI advanced-target structure size mismatch (" + advancedSize + " bytes; expected 128).");

            pathArray = AllocZeroed(allocations, checked((int)pathCount * pathSize));
            uint pathVersion = (uint)(pathSize | (2 << 16));
            for (int i = 0; i < pathCount; i++) {
                NvDisplayConfigPathInfoV2 entry = new NvDisplayConfigPathInfoV2();
                entry.version = pathVersion;
                Marshal.StructureToPtr(entry, IntPtr.Add(pathArray, i * pathSize), false);
            }

            uint fetchedCount = pathCount;
            status = getConfig(ref fetchedCount, pathArray);
            if (status != 0)
                throw new Exception("NvAPI_DISP_GetDisplayConfig path query failed: " + ScalingStatus(status) + ".");
            if (fetchedCount != pathCount)
                throw new Exception("Display topology changed during query. Please click Apply NVIDIA Settings again.");

            // Allocate target arrays, source mode records, and advanced target details,
            // following NVIDIA's documented three-pass GetDisplayConfig pattern.
            for (int i = 0; i < pathCount; i++) {
                IntPtr pPath = IntPtr.Add(pathArray, i * pathSize);
                NvDisplayConfigPathInfoV2 entry =
                    (NvDisplayConfigPathInfoV2)Marshal.PtrToStructure(pPath, typeof(NvDisplayConfigPathInfoV2));

                if (entry.targetInfoCount < 1 || entry.targetInfoCount > 32)
                    throw new Exception("Unexpected target count for display path " + i + ": " + entry.targetInfoCount + ".");

                entry.sourceModeInfo = AllocZeroed(allocations, sourceModeSize);
                entry.targetInfo = AllocZeroed(allocations, checked((int)entry.targetInfoCount * targetSize));

                for (int j = 0; j < entry.targetInfoCount; j++) {
                    IntPtr pTarget = IntPtr.Add(entry.targetInfo, j * targetSize);
                    IntPtr details = AllocZeroed(allocations, advancedSize);
                    Marshal.WriteInt32(details, 0, (int)(advancedSize | (1 << 16)));

                    NvDisplayConfigTargetInfoV2 target = new NvDisplayConfigTargetInfoV2();
                    target.details = details;
                    Marshal.StructureToPtr(target, pTarget, false);
                }

                Marshal.StructureToPtr(entry, pPath, false);
            }

            fetchedCount = pathCount;
            status = getConfig(ref fetchedCount, pathArray);
            if (status != 0)
                throw new Exception("NvAPI_DISP_GetDisplayConfig full query failed: " + ScalingStatus(status) + ".");
            if (fetchedCount != pathCount)
                throw new Exception("Display topology changed while reading settings.");

            // Resolve Windows DISPLAY1 to NVIDIA's display ID where possible.
            uint desiredDisplayId = 0;
            int displayNameStatus = getDisplayId(@"\\.\DISPLAY1", out desiredDisplayId);
            bool exactNameResolved = displayNameStatus == 0 && desiredDisplayId != 0;
            int targetPath = -1;
            int targetIndex = -1;

            if (exactNameResolved) {
                for (int i = 0; i < pathCount && targetPath < 0; i++) {
                    NvDisplayConfigPathInfoV2 entry =
                        (NvDisplayConfigPathInfoV2)Marshal.PtrToStructure(
                            IntPtr.Add(pathArray, i * pathSize), typeof(NvDisplayConfigPathInfoV2));
                    for (int j = 0; j < entry.targetInfoCount; j++) {
                        NvDisplayConfigTargetInfoV2 target =
                            (NvDisplayConfigTargetInfoV2)Marshal.PtrToStructure(
                                IntPtr.Add(entry.targetInfo, j * targetSize), typeof(NvDisplayConfigTargetInfoV2));
                        if (target.displayId == desiredDisplayId) {
                            targetPath = i;
                            targetIndex = j;
                            break;
                        }
                    }
                }
            }

            // If driver naming could not be mapped, select the NVIDIA target on
            // the Windows GDI-primary path rather than blindly changing every monitor.
            if (targetPath < 0) {
                for (int i = 0; i < pathCount && targetPath < 0; i++) {
                    NvDisplayConfigPathInfoV2 entry =
                        (NvDisplayConfigPathInfoV2)Marshal.PtrToStructure(
                            IntPtr.Add(pathArray, i * pathSize), typeof(NvDisplayConfigPathInfoV2));
                    if (entry.sourceModeInfo != IntPtr.Zero) {
                        NvDisplayConfigSourceModeInfoV1 source =
                            (NvDisplayConfigSourceModeInfoV1)Marshal.PtrToStructure(
                                entry.sourceModeInfo, typeof(NvDisplayConfigSourceModeInfoV1));
                        if ((source.flags & 1u) != 0 && entry.targetInfoCount > 0) {
                            targetPath = i;
                            targetIndex = 0;
                        }
                    }
                }
            }
            if (targetPath < 0)
                throw new Exception("Could not identify DISPLAY1 or the Windows primary display in NVIDIA's display configuration; no scaling change was made.");

            IntPtr selectedPathPtr = IntPtr.Add(pathArray, targetPath * pathSize);
            NvDisplayConfigPathInfoV2 selectedPath =
                (NvDisplayConfigPathInfoV2)Marshal.PtrToStructure(selectedPathPtr, typeof(NvDisplayConfigPathInfoV2));
            IntPtr selectedTargetPtr = IntPtr.Add(selectedPath.targetInfo, targetIndex * targetSize);
            NvDisplayConfigTargetInfoV2 selectedTarget =
                (NvDisplayConfigTargetInfoV2)Marshal.PtrToStructure(selectedTargetPtr, typeof(NvDisplayConfigTargetInfoV2));

            if (selectedTarget.details == IntPtr.Zero)
                throw new Exception("NVIDIA did not return advanced settings for the selected display.");

            int oldScaling = Marshal.ReadInt32(selectedTarget.details, 8);
            Marshal.WriteInt32(selectedTarget.details, 8, 2); // NV_SCALING_GPU_SCALING_TO_NATIVE = Force GPU - Full Screen

            // Validate the updated current topology first. This is a dry run and
            // should not change display settings if NVIDIA rejects the configuration.
            status = setConfig(pathCount, pathArray, 0x00000001); // NV_DISPLAYCONFIG_VALIDATE_ONLY
            if (status != 0)
                throw new Exception("NVIDIA rejected the scaling configuration during validation: " + ScalingStatus(status) + ".");

            // Apply the unchanged current topology with only this target's scaling
            // changed; request persistence so the setting can survive sign-in/reboot.
            status = setConfig(pathCount, pathArray, 0x00000002); // NV_DISPLAYCONFIG_SAVE_TO_PERSISTENCE
            if (status != 0)
                throw new Exception("NvAPI_DISP_SetDisplayConfig apply failed: " + ScalingStatus(status) + ".");

            // Query into the same allocated path structures to verify what driver reports.
            fetchedCount = pathCount;
            status = getConfig(ref fetchedCount, pathArray);
            if (status != 0)
                throw new Exception("Scaling was submitted, but verification read failed: " + ScalingStatus(status) + ".");

            selectedPath =
                (NvDisplayConfigPathInfoV2)Marshal.PtrToStructure(selectedPathPtr, typeof(NvDisplayConfigPathInfoV2));
            selectedTargetPtr = IntPtr.Add(selectedPath.targetInfo, targetIndex * targetSize);
            selectedTarget =
                (NvDisplayConfigTargetInfoV2)Marshal.PtrToStructure(selectedTargetPtr, typeof(NvDisplayConfigTargetInfoV2));
            int actualScaling = Marshal.ReadInt32(selectedTarget.details, 8);

            if (actualScaling != 2)
                throw new Exception("NVIDIA did not retain Force GPU - Full Screen. Driver reports scaling mode " + actualScaling + " (previous " + oldScaling + ").");

            report = "GPU scaling set and verified using NvAPI_DISP_SetDisplayConfig: Force GPU - Full Screen (mode 2). Previous mode " +
                oldScaling + "; selected path " + targetPath + ", target " + targetIndex +
                (exactNameResolved ? ", matched DISPLAY1 by display ID." : ", matched Windows GDI-primary display because DISPLAY1 name could not be mapped.");
            return true;
        } catch (Exception ex) {
            report = "GPU full-screen scaling failed: " + ex.Message;
            return false;
        } finally {
            // Release all nested arrays/details before the top-level array.
            for (int i = allocations.Count - 1; i >= 0; i--) {
                try { Marshal.FreeHGlobal(allocations[i]); } catch {}
            }
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

$script:ColorWatchTimer = $null
$script:ColorWatchLastLevel = $null
$script:ColorWatchLastStatusLog = Get-Date

function Start-ColorWatch {
    if (-not ("FabNvApi" -as [type])) {
        Write-Log "Color Watch could not start because NVAPI helper is unavailable." "ERROR"
        return
    }
    if ($script:ColorWatchTimer) {
        if (-not $script:ColorWatchTimer.Enabled) {
            $script:ColorWatchTimer.Start()
            Write-Log "Color Watch resumed."
        } else {
            Write-Log "Color Watch is already running."
        }
        return
    }

    $script:ColorWatchTimer = New-Object System.Windows.Forms.Timer
    $script:ColorWatchTimer.Interval = 10000
    $script:ColorWatchTimer.Add_Tick({
        try {
            $level = -1
            $minLevel = -1
            $maxLevel = -1
            $readReport = ""
            $readOk = [FabNvApi]::TryReadDigitalVibrance(
                [ref]$level, [ref]$minLevel, [ref]$maxLevel, [ref]$readReport
            )
            if (-not $readOk) {
                Write-Log "Color Watch read failed: $readReport" "WARN"
                return
            }

            $target = $minLevel + [int][Math]::Round(($maxLevel - $minLevel) * 0.75)
            if ($null -eq $script:ColorWatchLastLevel) {
                Write-Log "Color Watch started: current Digital Vibrance=$level; target for 75%=$target (range $minLevel-$maxLevel)."
            } elseif ($level -ne $script:ColorWatchLastLevel) {
                Write-Log "Color Watch detected Digital Vibrance changed from $($script:ColorWatchLastLevel) to $level." "WARN"
            }
            $script:ColorWatchLastLevel = $level

            if ($level -ne $target) {
                Write-Log "Color Watch detected Digital Vibrance is no longer 75%; attempting to restore it." "WARN"
                $setReport = ""
                $setOk = [FabNvApi]::TrySetDigitalVibrance75([ref]$setReport)
                if ($setOk) {
                    Write-Log "Color Watch restored Digital Vibrance: $setReport" "WARN"
                    $script:ColorWatchLastLevel = $target
                } else {
                    Write-Log "Color Watch could not restore Digital Vibrance: $setReport" "ERROR"
                }
            } else {
                $now = Get-Date
                if (($now - $script:ColorWatchLastStatusLog).TotalSeconds -ge 60) {
                    Write-Log "Color Watch: Digital Vibrance remains at driver level $level (75%). If the screen still looks washed out, another color pipeline/display setting is responsible."
                    $script:ColorWatchLastStatusLog = $now
                }
            }
        } catch {
            Write-Log "Color Watch error: $($_.Exception.Message)" "ERROR"
        }
    })
    $script:ColorWatchTimer.Start()
    Write-Log "Color Watch enabled: checks NVIDIA Digital Vibrance every 10 seconds and restores 75% only if the driver reports a different level. Active while this launcher is open."
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

        # Start-ColorWatch  # Temporarily disabled: no 10-second Digital Vibrance polling or automatic restore.

        try {
            $performanceReport = ""
            $performanceOk = [FabNvApi]::TryApplyPerformanceProfile([ref]$performanceReport)
            foreach ($performanceLine in ($performanceReport -split "\r?\n")) {
                if (-not [string]::IsNullOrWhiteSpace($performanceLine)) {
                    if ($performanceLine.StartsWith("ERROR:")) {
                        Write-Log $performanceLine.Substring(6).Trim() "ERROR"
                    } elseif ($performanceLine.StartsWith("WARN:")) {
                        Write-Log $performanceLine.Substring(5).Trim() "WARN"
                    } else {
                        Write-Log $performanceLine.Substring(5).Trim()
                    }
                }
            }
            if (-not $performanceOk) {
                Write-Log "Some NVIDIA Performance/G-SYNC-off driver profile settings were not verified. See DRS lines." "WARN"
            }
        } catch {
            Write-Log "NVIDIA 3D Performance DRS call failed unexpectedly: $($_.Exception.Message)" "ERROR"
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
        Write-Log "NVIDIA NVAPI helper is unavailable; Digital Vibrance, driver profile, G-SYNC profile and scaling were not changed." "ERROR"
    }

    Write-Log "NVIDIA Performance-equivalent values were requested through the global driver profile; select the actual preview slider manually if the radio control must also show Performance."
    Write-Log "Still manual: Configure Surround, PhysX -> select the NVIDIA GPU."
    Write-Log "Still manual: Adjust desktop size and position -> enable override scaling mode set by games and programs."
    Write-Log "G-SYNC-off driver profile values were requested globally; confirm Set up G-SYNC checkbox is OFF on display 1 (this GUI checkbox itself was not toggled)."
    Write-Log "Opening NVIDIA Control Panel. Check the scaling override checkbox and PhysX GPU choice manually." "INFO"
    Open-NvidiaControlPanel
}

function Open-GHub {
    Launch-App -Name "Logitech G HUB" -Paths @(
        "$env:ProgramFiles\LGHUB\lghub.exe",
        "$env:ProgramFiles\LGHUB\lghub_system_tray.exe"
    )
}

# Optional: place a direct HTTPS URL here to make the at.cfg button fully
# one-click on every PC. Alternatively, keep at.cfg next to this BAT, or let
# the button request a URL the first time on each PC.
$script:AtCfgDownloadUrl = ""

# Built-in at.cfg from the uploaded file. Makes this BAT portable and usable
# offline without needing a second file or a configuration download URL.
# An at.cfg beside this BAT can override the bundled copy.
$script:EmbeddedAtCfgBase64 = @"
Ly8gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQ0KLy8gQ1MyIEFVVE9FWEVDDQovLyA9PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09DQplY2hvICJGYWIgTW9kZSINCg0KLy8gLS0tLS0tLS0tLSBDT05TT0xFIC0t
LS0tLS0tLS0NCmJpbmQgImAiICJ0b2dnbGVjb25zb2xlIg0KDQoNCi8vIC0tLS0tLS0tLS0gTU9VU0UgLyBNT1ZFTUVOVCAtLS0t
LS0tLS0tDQpiaW5kICJNV0hFRUxVUCIgIitqdW1wIg0KYmluZCAiTVdIRUVMRE9XTiIgIitqdW1wIg0KYmluZCAiU1BBQ0UiICIr
anVtcCINCg0Kc2Vuc2l0aXZpdHkgIjEuMiINCnpvb21fc2Vuc2l0aXZpdHlfcmF0aW8gIjEuMCINCg0KDQovLyAtLS0tLS0tLS0t
IFJBREFSIC8gSFVEIC0tLS0tLS0tLS0NCmJpbmQgIkFMVCIgInRvZ2dsZSBjbF9yYWRhcl9zY2FsZSAwLjI1IDAuOCINCmNsX2h1
ZF9yYWRhcl9zY2FsZSAiMS4zMCINCg0KDQovLyAtLS0tLS0tLS0tIFdFQVBPTlMgLS0tLS0tLS0tLQ0KYmluZCAiUiIgIityZWxv
YWQiDQpiaW5kICJYIiAiK2xvb2thdHdlYXBvbiINCg0KYmluZCAiVCIgInNsb3Q2IiAgICAgICAgLy8gSEUgZ3JlbmFkZQ0KYmlu
ZCAiRiIgInNsb3Q3IiAgICAgICAgLy8gRmxhc2hiYW5nDQpiaW5kICJDIiAic2xvdDgiICAgICAgICAvLyBTbW9rZQ0KYmluZCAi
TiIgInNsb3QxMCIgICAgICAgLy8gTW9sb3RvdiAvIEluY2VuZGlhcnkNCg0KDQovLyAtLS0tLS0tLS0tIFZPSUNFIC0tLS0tLS0t
LS0NCmJpbmQgIlYiICIrdm9pY2VyZWNvcmQiDQoNCg0KLy8gLS0tLS0tLS0tLSBJTkNPTUlORyBDSEFUIC0tLS0tLS0tLS0NCmJp
bmQgIk1PVVNFNSIgInRvZ2dsZSBjbF9tdXRlX2VuZW15X3RlYW0gMSAwIg0KDQoNCi8vIC0tLS0tLS0tLS0gQ1JPU1NIQUlSIC0t
LS0tLS0tLS0NCmNsX2Nyb3NzaGFpcl9kcmF3b3V0bGluZSB0cnVlDQpjbF9jcm9zc2hhaXJfb3V0bGluZXRoaWNrbmVzcyAwDQpj
bF9jcm9zc2hhaXJfcmVjb2lsIGZhbHNlDQpjbF9jcm9zc2hhaXJfc25pcGVyX3dpZHRoIDANCmNsX2Nyb3NzaGFpcl90IGZhbHNl
DQoNCmNsX2Nyb3NzaGFpcmFscGhhIDIwMA0KY2xfY3Jvc3NoYWlyY29sb3IgNQ0KY2xfY3Jvc3NoYWlyY29sb3JfYiAwDQpjbF9j
cm9zc2hhaXJjb2xvcl9nIDI1NQ0KY2xfY3Jvc3NoYWlyY29sb3JfciAwDQoNCmNsX2Nyb3NzaGFpcmRvdCBmYWxzZQ0KY2xfY3Jv
c3NoYWlyZ2FwIC0zLjcNCmNsX2Nyb3NzaGFpcmdhcF91c2V3ZWFwb252YWx1ZSBmYWxzZQ0KY2xfY3Jvc3NoYWlyc2l6ZSAyDQpj
bF9jcm9zc2hhaXJzdHlsZSA0DQpjbF9jcm9zc2hhaXJ0aGlja25lc3MgMQ0KY2xfY3Jvc3NoYWlydXNlYWxwaGEgdHJ1ZQ0KDQoN
Ci8vIC0tLS0tLS0tLS0gUEVSRk9STUFOQ0UgLS0tLS0tLS0tLQ0KZnBzX21heCAiNDAwIg0KDQoNCnJfbG93X2xhdGVuY3kgIjIi
DQoNCnJfcGxheWVyX3Zpc2liaWxpdHlfbW9kZSAiMSINCg0KDQovLyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09DQovLyBWSURFTyBTRVRUSU5HUw0KLy8gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQ0KLy8N
Ci8vIERpc3BsYXkgTW9kZTogRnVsbHNjcmVlbg0KLy8gQXNwZWN0IFJhdGlvOiA0OjMNCi8vIFJlc29sdXRpb246IDEyODB4OTYw
DQovLyBSZWZyZXNoIFJhdGU6IDM2MCBIeg0KLy8gQnJpZ2h0bmVzczogOTMlDQovLw0KLy8gQWR2YW5jZWQgVmlkZW86DQovLw0K
Ly8gTXVsdGlzYW1wbGluZyBBbnRpLUFsaWFzaW5nOiA4WCBNU0FBDQovLyBHbG9iYWwgU2hhZG93IFF1YWxpdHk6IExPVw0KLy8g
RHluYW1pYyBTaGFkb3dzOiBBTEwNCi8vIE1vZGVsIC8gVGV4dHVyZSBEZXRhaWw6IE1FRElVTQ0KLy8gVGV4dHVyZSBGaWx0ZXJp
bmc6IEJJTElORUFSDQovLyBTaGFkZXIgRGV0YWlsOiBMT1cNCi8vIFBhcnRpY2xlIERldGFpbDogTE9XDQovLyBBbWJpZW50IE9j
Y2x1c2lvbjogRElTQUJMRUQNCi8vIEhpZ2ggRHluYW1pYyBSYW5nZTogUEVSRk9STUFOQ0UNCi8vIEZpZGVsaXR5RlggU3VwZXIg
UmVzb2x1dGlvbjogRElTQUJMRUQNCi8vDQovLyBCb29zdCBQbGF5ZXIgQ29udHJhc3Q6IEVOQUJMRUQNCi8vIFYtU3luYzogRElT
QUJMRUQNCi8vIE5WSURJQSBSZWZsZXg6IEVOQUJMRUQgKyBCT09TVA0KLy8gTWF4aW11bSBGUFM6IDQwMA==
"@

function Get-SteamLibraryRoots {
    $steamInstalls = New-Object 'System.Collections.Generic.List[string]'
    $libraryRoots = New-Object 'System.Collections.Generic.List[string]'
    $seenSteam = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $seenLibrary = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    $registryKeys = @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )
    $guessSteam = @(
        "${env:ProgramFiles(x86)}\Steam",
        "$env:ProgramFiles\Steam",
        "${env:LOCALAPPDATA}\Steam",
        "${env:SystemDrive}\Steam"
    )
    foreach ($key in $registryKeys) {
        try {
            $props = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            foreach ($name in @('SteamPath', 'InstallPath', 'SteamExe')) {
                $value = $props.$name
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    if ($name -eq 'SteamExe') { $value = Split-Path -Parent $value }
                    $guessSteam += $value
                }
            }
        } catch {}
    }

    try {
        $steamProcesses = Get-Process -Name 'steam' -ErrorAction SilentlyContinue
        foreach ($steamProcess in $steamProcesses) {
            if ($steamProcess.Path) { $guessSteam += (Split-Path -Parent $steamProcess.Path) }
        }
    } catch {}

    foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        foreach ($folderName in @('SteamLibrary', 'Steam', 'Games\SteamLibrary', 'Games\Steam')) {
            $guessSteam += (Join-Path $drive.Root $folderName)
        }
    }

    foreach ($steamRoot in $guessSteam) {
        if ([string]::IsNullOrWhiteSpace($steamRoot)) { continue }
        $steamRoot = $steamRoot.Replace('/', '\').TrimEnd('\')
        if ((Test-Path -LiteralPath $steamRoot -PathType Container) -and $seenSteam.Add($steamRoot)) {
            $steamInstalls.Add($steamRoot)
        }
    }

    foreach ($steamRoot in $steamInstalls) {
        if ($seenLibrary.Add($steamRoot)) { $libraryRoots.Add($steamRoot) }
        $vdf = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (-not (Test-Path -LiteralPath $vdf -PathType Leaf)) { continue }
        try {
            $raw = Get-Content -LiteralPath $vdf -Raw -ErrorAction Stop
            # New format: "path" "D:\\SteamLibrary". Old: "1" "D:\\SteamLibrary".
            $matches = [regex]::Matches($raw, '(?m)^\s*"(?:path|\d+)"\s+"([^"\r\n]+)"')
            foreach ($match in $matches) {
                $root = $match.Groups[1].Value.Replace('\\', '\').Replace('/', '\').TrimEnd('\')
                if ($root -match '^[A-Za-z]:\\' -and
                    (Test-Path -LiteralPath $root -PathType Container) -and
                    $seenLibrary.Add($root)) {
                    $libraryRoots.Add($root)
                }
            }
        } catch {
            Write-Log "Could not read Steam library file $vdf`: $($_.Exception.Message)" "WARN"
        }
    }

    return $libraryRoots.ToArray()
}

function Find-CS2ConfigFolder {
    param([switch]$NoPrompt)
    $roots = @(Get-SteamLibraryRoots)
    Write-Log "Searching $($roots.Count) Steam library location(s) for CS2 (app 730)."
    $fallback = $null

    foreach ($root in $roots) {
        $steamApps = Join-Path $root 'steamapps'
        $manifestPath = Join-Path $steamApps 'appmanifest_730.acf'
        $gameNames = New-Object 'System.Collections.Generic.List[string]'
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            try {
                $manifestText = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop
                $nameMatch = [regex]::Match($manifestText, '(?m)^\s*"installdir"\s+"([^"\r\n]+)"')
                if ($nameMatch.Success) { $gameNames.Add($nameMatch.Groups[1].Value) }
            } catch {
                Write-Log "Could not read CS2 manifest at $manifestPath`: $($_.Exception.Message)" "WARN"
            }
        }
        $gameNames.Add('Counter-Strike Global Offensive')
        foreach ($gameName in ($gameNames | Select-Object -Unique)) {
            $candidate = Join-Path $steamApps ("common\{0}\game\csgo\cfg" -f $gameName)
            if (Test-Path -LiteralPath $candidate -PathType Container) {
                if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
                    Write-Log "Found installed CS2 config folder: $candidate"
                    return $candidate
                }
                if (-not $fallback) { $fallback = $candidate }
            }
        }
    }

    if ($fallback) {
        Write-Log "Found CS2 config folder without appmanifest_730.acf: $fallback" "WARN"
        return $fallback
    }

    if ($NoPrompt) {
        Write-Log 'CS2 was not found in any discovered Steam library. Skipping config install in FabMode (no popup).' 'WARN'
        return $null
    }
    Write-Log 'Automatic CS2 installation detection failed; requesting the game cfg folder.' 'WARN'
    $pick = New-Object System.Windows.Forms.FolderBrowserDialog
    $pick.Description = 'Select the CS2 folder ending in game\csgo\cfg'
    $pick.ShowNewFolderButton = $false
    if ($pick.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    $selected = $pick.SelectedPath.TrimEnd('\')
    if ($selected -notmatch '(?i)\\game\\csgo\\cfg$') {
        throw "Selected path is not the CS2 game\\csgo\\cfg folder: $selected"
    }
    return $selected
}

function Get-AtCfgSource {
    $launcherDir = Split-Path -Parent $env:CAFE_SCRIPT
    $localCfg = Join-Path $launcherDir 'at.cfg'
    if (Test-Path -LiteralPath $localCfg -PathType Leaf) {
        Write-Log "Found at.cfg next to launcher: $localCfg"
        return [pscustomobject]@{ Type='File'; Value=$localCfg; RememberUrl=$false }
    }

    # Use the portable, bundled source when no explicit direct URL is configured.
    # This avoids prompting for a file during the multi-step FabMode action.
    if ([string]::IsNullOrWhiteSpace($script:AtCfgDownloadUrl) -and
        -not [string]::IsNullOrWhiteSpace($script:EmbeddedAtCfgBase64)) {
        Write-Log 'Using bundled at.cfg stored inside the launcher (offline).'
        return [pscustomobject]@{ Type='Embedded'; Value='bundled at.cfg'; RememberUrl=$false }
    }

    $storedUrlFile = Join-Path $env:LOCALAPPDATA 'CafeLauncher\at_cfg_url.txt'
    $url = $script:AtCfgDownloadUrl
    $remember = $false
    if ([string]::IsNullOrWhiteSpace($url) -and (Test-Path -LiteralPath $storedUrlFile -PathType Leaf)) {
        try { $url = (Get-Content -LiteralPath $storedUrlFile -Raw -ErrorAction Stop).Trim() } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($url)) {
        Add-Type -AssemblyName Microsoft.VisualBasic
        $url = [Microsoft.VisualBasic.Interaction]::InputBox(
            "Paste the DIRECT HTTPS download link to your at.cfg file.`n`nLeave blank to browse for a local at.cfg instead.`nThe link will be saved after a successful installation on this PC.",
            'Install CS2 at.cfg', ''
        ).Trim()
        if ([string]::IsNullOrWhiteSpace($url)) {
            $picker = New-Object System.Windows.Forms.OpenFileDialog
            $picker.Title = 'Select the at.cfg file to install'
            $picker.Filter = 'CS2 config (at.cfg)|at.cfg|CFG files (*.cfg)|*.cfg'
            $picker.CheckFileExists = $true
            if ($picker.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
            return [pscustomobject]@{ Type='File'; Value=$picker.FileName; RememberUrl=$false }
        }
        $remember = $true
    }

    $uri = $null
    if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') {
        throw 'The config download URL must be a full HTTPS link directly to at.cfg (not a GitHub webpage).'
    }
    return [pscustomobject]@{ Type='Url'; Value=$url; RememberUrl=$remember }
}

function Install-AtCfg {
    param([switch]$Silent)
    $downloaded = $null
    $staged = $null
    try {
        Write-Log 'CS2 config installation started.'
        $source = Get-AtCfgSource
        if (-not $source) {
            Write-Log 'CS2 at.cfg installation cancelled; no file or URL selected.' 'WARN'
            return
        }

        $cfgDirectory = Find-CS2ConfigFolder -NoPrompt:$Silent
        if (-not $cfgDirectory) {
            Write-Log 'CS2 at.cfg installation cancelled; no CS2 config folder selected.' 'WARN'
            return
        }

        if ($source.Type -eq 'Embedded') {
            $downloaded = Join-Path $env:TEMP ("CafeLauncher-at-{0}.cfg" -f [Guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllBytes($downloaded, [Convert]::FromBase64String($script:EmbeddedAtCfgBase64))
            $sourcePath = $downloaded
            Write-Log 'Extracted bundled at.cfg to a temporary file for installation.'
        } elseif ($source.Type -eq 'Url') {
            $downloaded = Join-Path $env:TEMP ("CafeLauncher-at-{0}.cfg" -f [Guid]::NewGuid().ToString('N'))
            Write-Log "Downloading at.cfg from $($source.Value)"
            # Windows PowerShell 5.1 uses TLS 1.2 when supported by the system.
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $source.Value -OutFile $downloaded -UseBasicParsing -TimeoutSec 30 -MaximumRedirection 5 -ErrorAction Stop
            $sourcePath = $downloaded
        } else {
            $sourcePath = $source.Value
        }

        $fileInfo = Get-Item -LiteralPath $sourcePath -ErrorAction Stop
        if ($fileInfo.Length -lt 1 -or $fileInfo.Length -gt 2097152) {
            throw 'at.cfg is empty or larger than 2 MB. Installation stopped.'
        }
        $buffer = [IO.File]::ReadAllBytes($sourcePath)
        $firstBytes = [Text.Encoding]::UTF8.GetString($buffer, 0, [Math]::Min($buffer.Length, 300)).TrimStart([char[]]@([char]0xFEFF, [char]32, [char]13, [char]10, [char]9))
        if ($firstBytes -match '(?i)^(<!doctype\s+html|<html\b|\{\s*"(?:message|error)"\s*:)') {
            throw 'The download appears to be a webpage/API error rather than at.cfg. Use a direct raw-file download URL.'
        }
        if ([Array]::IndexOf($buffer, [byte]0) -ge 0) {
            throw 'The source contains NUL bytes and does not appear to be a plain-text CFG.'
        }

        $dest = Join-Path $cfgDirectory 'at.cfg'
        if ([string]::Equals([IO.Path]::GetFullPath($sourcePath), [IO.Path]::GetFullPath($dest), [StringComparison]::OrdinalIgnoreCase)) {
            Write-Log "at.cfg is already in the correct location: $dest"
        } else {
            $staged = Join-Path $cfgDirectory ("at.cfg.cafe-{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
            Copy-Item -LiteralPath $sourcePath -Destination $staged -ErrorAction Stop
            if (Test-Path -LiteralPath $dest -PathType Leaf) {
                $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
                $backup = Join-Path $cfgDirectory "at.cfg.backup-$stamp"
                Copy-Item -LiteralPath $dest -Destination $backup -ErrorAction Stop
                Write-Log "Backed up previous at.cfg to $backup"
            }
            Copy-Item -LiteralPath $staged -Destination $dest -Force -ErrorAction Stop
        }

        $expected = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256 -ErrorAction Stop).Hash
        $actual = (Get-FileHash -LiteralPath $dest -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($expected -ne $actual) { throw 'SHA-256 verification failed: installed file does not match the source.' }

        if ($source.Type -eq 'Url' -and $source.RememberUrl) {
            try {
                $savedFile = Join-Path $env:LOCALAPPDATA 'CafeLauncher\at_cfg_url.txt'
                $savedDir = Split-Path -Parent $savedFile
                if (-not (Test-Path -LiteralPath $savedDir)) { New-Item -ItemType Directory -Path $savedDir -Force -ErrorAction Stop | Out-Null }
                Set-Content -LiteralPath $savedFile -Value $source.Value -Encoding UTF8 -ErrorAction Stop
                Write-Log "Saved config download URL for later use on this PC: $savedFile"
            } catch {
                Write-Log "Installed at.cfg, but could not save the download URL: $($_.Exception.Message)" 'WARN'
            }
        }

        Write-Log "CS2 at.cfg installed and SHA-256 verified: $dest"
        if (-not $Silent) {
            [System.Windows.Forms.MessageBox]::Show(
                "at.cfg installed successfully!`n`n$dest`n`nTo load it in CS2: exec at",
                'Cafe Launcher',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
    } catch {
        Write-Log "CS2 at.cfg installation failed: $($_.Exception.Message)" 'ERROR'
        if (-not $Silent) {
            [System.Windows.Forms.MessageBox]::Show(
                "Could not install at.cfg:`n$($_.Exception.Message)",
                'Cafe Launcher',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    } finally {
        foreach ($temporary in @($downloaded, $staged)) {
            if ($temporary -and (Test-Path -LiteralPath $temporary -PathType Leaf)) {
                try { Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop } catch {}
            }
        }
    }
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
    Write-Log "Launch All: opening Mouse Pointer Options."
    Open-MousePointerOptions
}

function Invoke-FabModeFull {
    Write-Log 'FabMode full routine started: mouse settings, NVIDIA settings, CS2 config, Launch All.'

    $steps = @(
        @{ Name = 'Windows mouse speed/acceleration'; Action = { Apply-FabMode -SkipPointerOptions } },
        @{ Name = 'NVIDIA settings'; Action = { Apply-NvidiaGamingSettings } },
        @{ Name = 'Install CS2 at.cfg'; Action = { Install-AtCfg -Silent } },
        @{ Name = 'Launch All (including Mouse Pointer Options)'; Action = { Launch-All } }
    )
    foreach ($step in $steps) {
        Write-Log ("FabMode step started: " + $step.Name)
        try {
            & ($step.Action)
            Write-Log ("FabMode step returned: " + $step.Name + ". Check logs for individual success or errors.")
        } catch {
            Write-Log ("FabMode step failed: " + $step.Name + ": " + $_.Exception.Message) 'ERROR'
        }
    }
    Write-Log 'FabMode full routine finished. Review logs for individual results.'
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
New-Tile "FabMode" 5 { Invoke-FabModeFull } -Primary
New-Tile "Mouse Pointer Options" 6 { Open-MousePointerOptions }
New-Tile "NVIDIA Control Panel" 7 { Open-NvidiaControlPanel }
New-Tile "Apply NVIDIA Settings" 8 { Apply-NvidiaGamingSettings } -Primary
New-Tile "Logitech G HUB" 9 { Open-GHub }
New-Tile "Install CS2 at.cfg" 10 { Install-AtCfg } -Primary
New-Tile "Exit" 11 { $form.Close() }

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

$form.Add_FormClosed({
    if ($script:ColorWatchTimer) {
        try { $script:ColorWatchTimer.Stop(); $script:ColorWatchTimer.Dispose() } catch {}
        Write-Log "Color Watch stopped because the launcher closed."
    }
})
[void]$form.ShowDialog()
