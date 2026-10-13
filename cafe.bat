@echo off
set "CAFE_SCRIPT=%~f0"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command "try { $l=[IO.File]::ReadAllLines($env:CAFE_SCRIPT); $i=[Array]::IndexOf($l,'# POWERSHELL_GUI'); if($i -lt 0){throw 'PowerShell script marker not found'}; $code=($l[($i+1)..($l.Length-1)] -join [Environment]::NewLine); $t=$null; $er=$null; [void][System.Management.Automation.Language.Parser]::ParseInput($code,[ref]$t,[ref]$er); if($er.Count -gt 0){throw ('PowerShell syntax: '+$er[0].ToString())}; Invoke-Expression $code } catch { $msg=$_.ToString()+' '+$_.ScriptStackTrace; try { [IO.File]::WriteAllText((Join-Path $env:TEMP 'CafeLauncher-startup-error.log'),$msg) } catch {}; try { Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show($msg,'CafeLauncher Startup Error') } catch {} }"
exit /b

# POWERSHELL_GUI
# CAFE_RELEASE=2026.10.13.19

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
    if($script:StepScope){
        if($Level -eq "ERROR"){$script:StepScopeError=$true}
        elseif($Level -eq "WARN"){$script:StepScopeWarning=$true}
    }
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

# Result records are separate from diagnostic INFO/WARN/ERROR logs.
$script:StepResults=New-Object 'System.Collections.Generic.List[object]'
$script:StepScope=$null
$script:StepScopeError=$false
$script:StepScopeWarning=$false
$script:ActiveRunName=''
function Set-StepResult {
    param([string]$Run,[string]$Step,[ValidateSet('SUCCESS','PARTIAL','SKIPPED','FAILED','PENDING')][string]$Status,[string]$Detail='')
    foreach($old in @($script:StepResults | Where-Object {$_.Run -eq $Run -and $_.Step -eq $Step})){
        [void]$script:StepResults.Remove($old)
    }
    $script:StepResults.Add([pscustomobject]@{Run=$Run;Step=$Step;Status=$Status;Detail=$Detail})
    Write-Log ($Run+' | '+$Step+' | '+$Status+$(if($Detail){' | '+$Detail}else{''})) 'RESULT'
}
function Start-StepScope {
    param([string]$Run,[string]$Step)
    $script:StepScope=[pscustomobject]@{Run=$Run;Step=$Step}
    $script:StepScopeError=$false
    $script:StepScopeWarning=$false
}
function Complete-StepScope {
    param([string]$Detail='Step finished; consult detailed logs for verification.')
    if(-not $script:StepScope){return}
    $scope=$script:StepScope
    $errorSeen=$script:StepScopeError
    $warnSeen=$script:StepScopeWarning
    $script:StepScope=$null
    $state=if($errorSeen){'FAILED'}elseif($warnSeen){'PARTIAL'}else{'SUCCESS'}
    if($errorSeen){$Detail='One or more errors reported. '+$Detail}
    elseif($warnSeen){$Detail='One or more warnings were reported; step may be partially applied. '+$Detail}
    Set-StepResult -Run $scope.Run -Step $scope.Step -Status $state -Detail $Detail
}
function Write-RunSummary {
    param([string]$Run)
    $items=@($script:StepResults | Where-Object {$_.Run -eq $Run})
    $counts=@{}
    foreach($state in @('SUCCESS','PARTIAL','SKIPPED','FAILED','PENDING')){$counts[$state]=@($items | Where-Object {$_.Status -eq $state}).Count}
    Write-Log ($Run+': '+$counts.SUCCESS+' SUCCESS, '+$counts.PARTIAL+' PARTIAL, '+$counts.SKIPPED+' SKIPPED, '+$counts.FAILED+' FAILED, '+$counts.PENDING+' PENDING') 'SUMMARY'
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

function Apply-ProfileMouse {
    param(
        [string]$ProfileName = 'FabMode',
        [ValidateRange(1,20)][int]$PointerSpeed = 10,
        [bool]$DisableAcceleration = $true,
        [switch]$SkipPointerOptions
    )
    $mousePath = "HKCU:\Control Panel\Mouse"
    if ($DisableAcceleration) {
        $accelSetting = '0'; $threshold1 = 0; $threshold2 = 0; $acceleration = 0
    } else {
        $accelSetting = '1'; $threshold1 = 6; $threshold2 = 10; $acceleration = 1
    }
    $accelDescription = if ($DisableAcceleration) { 'disabled' } else { 'enabled' }
    Write-Log "$ProfileName mouse settings started."

    try {
        # Write Windows mouse settings directly.
        Set-ItemProperty -Path $mousePath -Name MouseSensitivity -Value ([string]$PointerSpeed) -ErrorAction Stop
        Set-ItemProperty -Path $mousePath -Name MouseSpeed -Value $accelSetting -ErrorAction Stop
        Set-ItemProperty -Path $mousePath -Name MouseThreshold1 -Value ([string]$threshold1) -ErrorAction Stop
        Set-ItemProperty -Path $mousePath -Name MouseThreshold2 -Value ([string]$threshold2) -ErrorAction Stop
        Write-Log "Mouse registry values written (speed $PointerSpeed; acceleration $accelDescription)."

        # Apply the requested acceleration to the active Windows session.
        # SPI_SETMOUSE expects a pointer to three integers: threshold1, threshold2, acceleration.
        $mouseData = [Runtime.InteropServices.Marshal]::AllocHGlobal(12)
        try {
            [Runtime.InteropServices.Marshal]::WriteInt32($mouseData, 0, $threshold1)
            [Runtime.InteropServices.Marshal]::WriteInt32($mouseData, 4, $threshold2)
            [Runtime.InteropServices.Marshal]::WriteInt32($mouseData, 8, $acceleration)
            $accelOk = [FabMouseNative]::SystemParametersInfo(
                0x0004, 0, $mouseData, 0x03
            )
            if ($accelOk) {
                Write-Log "Windows accepted SPI_SETMOUSE: acceleration $accelDescription."
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
            0x0071, 0, [IntPtr]$PointerSpeed, 0x03
        )
        if ($apiOk) {
            Write-Log "Windows accepted SPI_SETMOUSESPEED speed $PointerSpeed."
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
                Write-Log "Windows live pointer-speed read-back: $actualSpeed (requested $PointerSpeed)."
            } else {
                $readError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                Write-Log "SPI_GETMOUSESPEED read-back failed; Win32 error=$readError." "WARN"
            }
        } finally {
            [Runtime.InteropServices.Marshal]::FreeHGlobal($readSpeedPtr)
        }

        $apiVerified = $apiOk -and $speedReadOk -and ($actualSpeed -eq $PointerSpeed)
        if ($apiOk -and $speedReadOk -and ($actualSpeed -ne $PointerSpeed)) {
            Write-Log "Windows accepted the set call but reports live speed $actualSpeed instead of $PointerSpeed." "ERROR"
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
        if ($current.MouseSensitivity -ne [string]$PointerSpeed -or
            $current.MouseSpeed -ne $accelSetting -or
            $current.MouseThreshold1 -ne [string]$threshold1 -or
            $current.MouseThreshold2 -ne [string]$threshold2) {
            throw "Registry verification failed. Current values: sensitivity=$($current.MouseSensitivity), speed=$($current.MouseSpeed), threshold1=$($current.MouseThreshold1), threshold2=$($current.MouseThreshold2)."
        }

        Write-Log "$ProfileName registry verification passed." "INFO"
        if ($apiVerified) {
            Write-Log "$ProfileName applied and verified live pointer speed $PointerSpeed." "INFO"
            if (-not $SkipPointerOptions) { Open-MousePointerOptions }
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "$ProfileName saved the registry values, but live pointer speed $PointerSpeed could not be confirmed. Check LIVE LOGS for SPI_SETMOUSESPEED and SPI_GETMOUSESPEED results.",
                "$ProfileName - Apply Warning",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
    } catch {
        Write-Log "$ProfileName mouse settings failed: $($_.Exception.Message)" "ERROR"
        [System.Windows.Forms.MessageBox]::Show(
            "$ProfileName mouse settings error:`n$($_.Exception.Message)`n`nSee LIVE LOGS for details.",
            "$ProfileName",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

function Apply-FabMode {
    param([switch]$SkipPointerOptions)
    Apply-ProfileMouse -ProfileName 'FabMode' -PointerSpeed 10 -DisableAcceleration $true -SkipPointerOptions:$SkipPointerOptions
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
# Automatically chooses highest driver-advertised refresh at preferred resolution
# if the requested Hz is unavailable; falls back to the CURRENT resolution only.
# The display mode helper uses a byte-array placeholder for DEVMODE's 16-byte union,
# avoiding compiler/layout problems from the prior explicit union implementation.
try {
    if (-not ("FabDisplayNative" -as [type])) {
        Add-Type -ErrorAction Stop @"
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

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

    // Read-only validation; does not change Windows display settings.
    public static bool IsAdvertisedMode(int w, int h, int hz) {
        const string device = @"\\.\DISPLAY1";
        if(w < 640 || h < 480 || hz < 0) return false;
        for(int i=0;i<4096;i++){
            DEVMODE dm=NewMode();
            if(!EnumDisplaySettings(device,i,ref dm)) break;
            if(dm.dmBitsPerPel < 24 || (dm.dmDisplayFlags & 2) != 0) continue;
            if(dm.dmPelsWidth == w && dm.dmPelsHeight == h &&
               (hz == 0 || dm.dmDisplayFrequency == hz)) return true;
        }
        return false;
    }

    // List of driver-advertised modes for the main Windows display (DISPLAY1).
    public static string GetDisplayModesReport() {
        const string device = @"\\.\DISPLAY1";
        DEVMODE current = NewMode();
        string active = EnumDisplaySettings(device, -1, ref current)
            ? current.dmPelsWidth + "x" + current.dmPelsHeight + " @" + current.dmDisplayFrequency + "Hz"
            : "unknown";
        SortedSet<int> requested1080 = new SortedSet<int>();
        SortedSet<int> atCurrent = new SortedSet<int>();
        int count = 0;
        for (int i=0; i<4096; i++) {
            DEVMODE dm = NewMode();
            if (!EnumDisplaySettings(device, i, ref dm)) break;
            if (dm.dmBitsPerPel < 24 || dm.dmDisplayFrequency < 24 ||
                (dm.dmDisplayFlags & 2) != 0) continue;
            count++;
            if (dm.dmPelsWidth == 1920 && dm.dmPelsHeight == 1080)
                requested1080.Add(dm.dmDisplayFrequency);
            if (dm.dmPelsWidth == current.dmPelsWidth && dm.dmPelsHeight == current.dmPelsHeight)
                atCurrent.Add(dm.dmDisplayFrequency);
        }
        return device + ": active " + active + "; 1080p Hz: " +
            (requested1080.Count > 0 ? String.Join(", ", requested1080) : "not advertised") +
            "; current-resolution Hz: " +
            (atCurrent.Count > 0 ? String.Join(", ", atCurrent) : "not advertised") +
            "; modes checked=" + count + ".";
    }

    public static bool TrySetDisplayMode(int desiredWidth, int desiredHeight, int desiredHz, out string report) {
        const string device = @"\\.\DISPLAY1";
        DEVMODE current = NewMode();
        if (!EnumDisplaySettings(device, -1, ref current)) {
            report = "Cannot read current DISPLAY1 mode; no changes made.";
            return false;
        }
        DEVMODE candidate = NewMode();
        int tier = -1;  // 2 = preferred resolution/Hz; 1 = preferred resolution; 0 = current resolution
        int count = 0;
        for (int i=0; i<4096; i++) {
            DEVMODE dm = NewMode();
            if (!EnumDisplaySettings(device, i, ref dm)) break;
            count++;
            if (dm.dmBitsPerPel < 24 || dm.dmDisplayFrequency < 24 ||
                (dm.dmDisplayFlags & 2) != 0) continue;
            int thisTier = -1;
            if (dm.dmPelsWidth == desiredWidth && dm.dmPelsHeight == desiredHeight)
                thisTier = dm.dmDisplayFrequency == desiredHz ? 2 : 1;
            else if (dm.dmPelsWidth == current.dmPelsWidth && dm.dmPelsHeight == current.dmPelsHeight)
                thisTier = 0;
            if (thisTier < 0) continue;
            bool preferable = thisTier > tier ||
                (thisTier == tier && dm.dmDisplayFrequency > candidate.dmDisplayFrequency) ||
                (thisTier == tier && dm.dmDisplayFrequency == candidate.dmDisplayFrequency &&
                    dm.dmBitsPerPel > candidate.dmBitsPerPel);
            if (preferable) { candidate = dm; tier = thisTier; }
        }
        if (tier < 0) {
            report = device + " no suitable display mode advertised after checking " + count +
                " modes. Keeping " + current.dmPelsWidth + "x" + current.dmPelsHeight +
                " @" + current.dmDisplayFrequency + "Hz.";
            return false;
        }
        string choice = candidate.dmPelsWidth + "x" + candidate.dmPelsHeight +
            " @" + candidate.dmDisplayFrequency + "Hz";
        string requested = desiredWidth + "x" + desiredHeight + " @" + desiredHz + "Hz";
        string reason = tier == 2 ? "exact mode available" :
            tier == 1 ? "requested Hz unavailable; highest advertised Hz at preferred resolution" :
            "preferred resolution unavailable; using highest advertised Hz at current resolution";

        // Avoid screen flicker and unnecessary registry writes if mode is already correct.
        if (current.dmPelsWidth == candidate.dmPelsWidth &&
            current.dmPelsHeight == candidate.dmPelsHeight &&
            current.dmDisplayFrequency == candidate.dmDisplayFrequency) {
            report = device + " already uses " + choice + " (requested " + requested +
                "; " + reason + "). No change needed.";
            return true;
        }
        candidate.dmFields |= 0x00040000 | 0x00080000 | 0x00100000 | 0x00400000;
        int test = ChangeDisplaySettingsEx(device, ref candidate, IntPtr.Zero, 0x00000002, IntPtr.Zero);
        if (test != 0) {
            report = "Windows rejected candidate " + choice + " during test: " + ResultName(test) + ". Original mode kept.";
            return false;
        }
        int apply = ChangeDisplaySettingsEx(device, ref candidate, IntPtr.Zero, 0x00000001, IntPtr.Zero);
        if (apply != 0) {
            report = "Windows rejected candidate " + choice + " during apply: " + ResultName(apply) + ".";
            return false;
        }
        DEVMODE after = NewMode();
        if (EnumDisplaySettings(device, -1, ref after)) {
            bool verified = after.dmPelsWidth == candidate.dmPelsWidth &&
                after.dmPelsHeight == candidate.dmPelsHeight &&
                after.dmDisplayFrequency == candidate.dmDisplayFrequency;
            report = device + " " + (verified ? "set and verified " : "read-back mismatch after requesting ") +
                choice + "; requested " + requested + "; " + reason + ".";
            return verified;
        }
        report = "Windows accepted " + choice + " but current mode could not be verified.";
        return false;
    }

    public static bool TrySetDisplay1To1080p360(out string report) {
        return TrySetDisplayMode(1920, 1080, 360, out report);
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

    public static bool TrySetDigitalVibrance(int percentage, out string report) {
        if (percentage < 0 || percentage > 100) { report = "Invalid vibrance percentage"; return false; }
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
            int requested = info.minLevel + (int)Math.Round((info.maxLevel - info.minLevel) * (percentage / 100.0));
            int setStatus = setLevel(handle, 0, requested);
            if (setStatus != 0) throw new Exception("NvAPI_SetDVCLevel failed with status " + setStatus + ".");

            DvcInfo verify = new DvcInfo();
            verify.version = (uint)(Marshal.SizeOf(typeof(DvcInfo)) | 0x10000);
            int verifyStatus = getInfo(handle, 0, ref verify);
            if (verifyStatus != 0) throw new Exception("Digital Vibrance was set, but read-back failed with status " + verifyStatus + ".");
            if (verify.currentLevel != requested)
                throw new Exception("NVIDIA accepted the Digital Vibrance request but reports " + verify.currentLevel + " (requested " + requested + ").");

            report = "Digital Vibrance set and verified at " + percentage + "%: driver level " + verify.currentLevel +
                " (range " + verify.minLevel + "-" + verify.maxLevel + ") for the NVIDIA display associated with DISPLAY1.";
            return true;
        } catch (Exception ex) {
            report = "Digital Vibrance failed: " + ex.Message;
            return false;
        } finally {
            if (initialized && unload != null) { try { unload(); } catch {} }
        }
    }

    public static bool TrySetDigitalVibrance75(out string report) {
        return TrySetDigitalVibrance(75, out report);
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


# Read-only NVIDIA compatibility inventory; no automatic driver installation.
function Get-NvidiaCompatibilityScan {
    param([int]$Width=1920,[int]$Height=1080,[int]$RefreshHz=360)
    $report=New-Object 'System.Collections.Generic.List[string]'
    $result=[ordered]@{NVAPI=$false;DisplayHelper=$false;ExactMode=$false;Report=$report}
    try {
        $adapters=@(Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object {$_.Name -match 'NVIDIA'})
        if($adapters.Count -eq 0){$report.Add('No NVIDIA GPU reported by Windows.')}
        foreach($gpu in $adapters){$report.Add(('GPU: '+$gpu.Name+' | NVIDIA driver: '+$gpu.DriverVersion))}
    }catch{$report.Add('GPU / driver version inventory unavailable: '+$_.Exception.Message)}
    $result.DisplayHelper=[bool]('FabDisplayNative' -as [type])
    if($result.DisplayHelper){
        try {
            $result.ExactMode=[FabDisplayNative]::IsAdvertisedMode($Width,$Height,$RefreshHz)
            $report.Add(('Requested '+$Width+'x'+$Height+' @'+$RefreshHz+'Hz: '+
                $(if($result.ExactMode){'advertised'}else{'not advertised; existing safest available mode fallback will be used'})))
            $report.Add([FabDisplayNative]::GetDisplayModesReport())
        }catch{
            $report.Add('Monitor mode enumeration unavailable: '+$_.Exception.Message)
            $result.DisplayHelper=$false
        }
    }else{$report.Add('Windows display helper unavailable; resolution change skipped.')}
    $apiDll=Join-Path $env:windir 'System32\nvapi64.dll'
    $apiFile=Test-Path -LiteralPath $apiDll -PathType Leaf
    $result.NVAPI=([bool]('FabNvApi' -as [type])) -and $apiFile
    $report.Add(('NVAPI availability: '+$(if($result.NVAPI){'driver DLL and wrapper detected'}else{'not detected; NVIDIA-only operations skipped'})))
    if($apiFile){
        try{$report.Add('NVAPI DLL version: '+[Diagnostics.FileVersionInfo]::GetVersionInfo($apiDll).FileVersion)}
        catch{$report.Add('NVAPI DLL version unavailable')}
    }
    try {
        $paths=@(
            (Join-Path $env:ProgramFiles 'NVIDIA Corporation\Control Panel Client\nvcplui.exe'),
            (Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'NVIDIA Corporation\Control Panel Client\nvcplui.exe')
        )
        if(@($paths | Where-Object {Test-Path -LiteralPath $_ -PathType Leaf}).Count -gt 0){
            $report.Add('NVIDIA Control Panel: classic desktop')
        }elseif(@(Get-StartApps -ErrorAction Stop | Where-Object {$_.Name -match '^NVIDIA Control Panel$'}).Count -gt 0){
            $report.Add('NVIDIA Control Panel: Microsoft Store / DCH')
        }else{$report.Add('NVIDIA Control Panel not detected (NVAPI is independent)')}
    }catch{$report.Add('NVIDIA Control Panel inventory unavailable')}
    return [pscustomobject]$result
}
function Write-NvidiaCompatibilityScan {
    param([int]$Width=1920,[int]$Height=1080,[int]$RefreshHz=360)
    $scan=Get-NvidiaCompatibilityScan -Width $Width -Height $Height -RefreshHz $RefreshHz
    foreach($line in $scan.Report){Write-Log ('NVIDIA compatibility: '+$line)}
    return $scan
}

function Apply-NvidiaGamingSettings {
    param(
        [ValidateRange(640,7680)][int]$Width = 1920,
        [ValidateRange(480,4320)][int]$Height = 1080,
        [ValidateRange(30,600)][int]$RefreshHz = 360,
        [ValidateRange(0,100)][int]$Vibrance = 75
    )
    Write-Log "NVIDIA gaming-settings apply started (requested: ${Width}x${Height} @${RefreshHz}Hz, vibrance ${Vibrance}%)."
    $compat=$null
    try{$compat=Write-NvidiaCompatibilityScan -Width $Width -Height $Height -RefreshHz $RefreshHz}
    catch{Write-Log ("NVIDIA preflight unavailable: "+$_.Exception.Message) "WARN"}

    Write-Log "Attempting Windows display 1: ${Width}x${Height} at $RefreshHz Hz."
    if (("FabDisplayNative" -as [type]) -and ($null -eq $compat -or $compat.DisplayHelper)) {
        try {
            $displayReport = ""
            $displayOk = [FabDisplayNative]::TrySetDisplayMode($Width, $Height, $RefreshHz, [ref]$displayReport)
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

    if (("FabNvApi" -as [type]) -and ($null -eq $compat -or $compat.NVAPI)) {
        try {
            $vibranceReport = ""
            $vibranceOk = [FabNvApi]::TrySetDigitalVibrance($Vibrance, [ref]$vibranceReport)
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
        Write-Log 'CS2 was not found in any discovered Steam library. Skipping config install (no popup).' 'WARN'
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

function Assert-ConfigUrl {
    param([string]$Url)
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $Url.Length -gt 2048 -or
        $uri.Host -ne 'raw.githubusercontent.com' -or
        $uri.AbsolutePath -notmatch '^/[^/]+/[^/]+/[^/]+/(?:[^/]+/)*[A-Za-z0-9_-]+\.cfg$') {
        throw 'Config URL must be a direct HTTPS raw.githubusercontent.com link ending in .cfg.'
    }
}

function Get-AtCfgSource {
    param([string]$CfgName = 'at.cfg', [string]$DownloadUrl = '', [switch]$CloudPreferred)
    $launcherDir = Split-Path -Parent $env:CAFE_SCRIPT
    $localCfg = Join-Path $launcherDir $CfgName

    # Friend profiles: always attempt their GitHub config first, even if a local copy exists.
    if ($CloudPreferred -and -not [string]::IsNullOrWhiteSpace($DownloadUrl)) {
        Assert-ConfigUrl $DownloadUrl
        return [pscustomobject]@{ Type='Url'; Value=$DownloadUrl; RememberUrl=$false }
    }
    if (Test-Path -LiteralPath $localCfg -PathType Leaf) {
        Write-Log "Found $CfgName next to launcher: $localCfg"
        return [pscustomobject]@{ Type='File'; Value=$localCfg; RememberUrl=$false }
    }
    if ($CfgName -ne 'at.cfg') {
        # Never silently install FabMode's at.cfg into a friend's profile.
        $cached = Join-Path $env:LOCALAPPDATA ("CafeLauncher\cfg-cache\$CfgName")
        if (Test-Path -LiteralPath $cached -PathType Leaf) {
            Write-Log "Using previously cached $CfgName (cloud source not configured)." 'WARN'
            return [pscustomobject]@{ Type='File'; Value=$cached; RememberUrl=$false }
        }
        if (-not [string]::IsNullOrWhiteSpace($DownloadUrl)) {
            Assert-ConfigUrl $DownloadUrl
            return [pscustomobject]@{ Type='Url'; Value=$DownloadUrl; RememberUrl=$false }
        }
        Write-Log "No source available for $CfgName. Upload its GitHub CFG or put $CfgName beside the launcher." 'WARN'
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($DownloadUrl) -and
        -not [string]::IsNullOrWhiteSpace($script:EmbeddedAtCfgBase64)) {
        Write-Log 'Using bundled at.cfg (FabMode offline default).'
        return [pscustomobject]@{ Type='Embedded'; Value='bundled at.cfg'; RememberUrl=$false }
    }

    $url = $DownloadUrl
    $remember = $false
    if ([string]::IsNullOrWhiteSpace($url)) {
        $storedUrlFile = Join-Path $env:LOCALAPPDATA 'CafeLauncher\at_cfg_url.txt'
        if (Test-Path -LiteralPath $storedUrlFile -PathType Leaf) {
            try { $url = (Get-Content -LiteralPath $storedUrlFile -Raw -ErrorAction Stop).Trim() } catch {}
        }
    }
    if ([string]::IsNullOrWhiteSpace($url)) {
        Add-Type -AssemblyName Microsoft.VisualBasic
        $url = [Microsoft.VisualBasic.Interaction]::InputBox(
            "Paste a DIRECT raw.githubusercontent.com HTTPS link for at.cfg.`nLeave blank to browse for a local file.",
            'Install CS2 at.cfg', ''
        ).Trim()
        if ([string]::IsNullOrWhiteSpace($url)) {
            $picker = New-Object System.Windows.Forms.OpenFileDialog
            $picker.Title = 'Select at.cfg to install'
            $picker.Filter = 'CS2 CFG files (*.cfg)|*.cfg'
            if ($picker.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
            return [pscustomobject]@{ Type='File'; Value=$picker.FileName; RememberUrl=$false }
        }
        $remember = $true
    }
    Assert-ConfigUrl $url
    return [pscustomobject]@{ Type='Url'; Value=$url; RememberUrl=$remember }
}

function Get-FriendConfigFallback {
    param([string]$CfgName, [string]$CfgDirectory)
    $launcherDir = Split-Path -Parent $env:CAFE_SCRIPT
    $cache = Join-Path $env:LOCALAPPDATA ("CafeLauncher\cfg-cache\$CfgName")
    foreach ($candidate in @($cache, (Join-Path $launcherDir $CfgName), (Join-Path $CfgDirectory $CfgName))) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Install-AtCfg {
    param(
        [switch]$Silent,
        [string]$CfgName = 'at.cfg',
        [string]$DownloadUrl = '',
        [switch]$CloudPreferred,
        [string]$CS2Sensitivity = ''
    )
    if ($CfgName -notmatch '^[A-Za-z0-9_-]+\.cfg$') {
        Write-Log "Unsafe config filename rejected: $CfgName" 'ERROR'
        return
    }
    $downloaded = $null
    $staged = $null
    $configured = $null
    $cloudDownloaded = $false
    try {
        Write-Log "CS2 config installation started: $CfgName."
        $source = Get-AtCfgSource -CfgName $CfgName -DownloadUrl $DownloadUrl -CloudPreferred:$CloudPreferred
        if (-not $source) {
            Write-Log "CS2 $CfgName installation cancelled; no file or URL selected." 'WARN'
            return $false
        }

        $cfgDirectory = Find-CS2ConfigFolder -NoPrompt:$Silent
        if (-not $cfgDirectory) {
            Write-Log "CS2 $CfgName installation cancelled; no CS2 config folder selected." 'WARN'
            return $false
        }

        if ($source.Type -eq 'Embedded') {
            $downloaded = Join-Path $env:TEMP ("CafeLauncher-{0}-{1}.cfg" -f [IO.Path]::GetFileNameWithoutExtension($CfgName), [Guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllBytes($downloaded, [Convert]::FromBase64String($script:EmbeddedAtCfgBase64))
            $sourcePath = $downloaded
            Write-Log "Extracted bundled starter config for $CfgName to a temporary file."
        } elseif ($source.Type -eq 'Url') {
            $downloaded = Join-Path $env:TEMP ("CafeLauncher-{0}-{1}.cfg" -f [IO.Path]::GetFileNameWithoutExtension($CfgName), [Guid]::NewGuid().ToString('N'))
            Write-Log "Downloading $CfgName from $($source.Value)"
            # Windows PowerShell 5.1 uses TLS 1.2 when supported by the system.
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            try {
                Invoke-WebRequest -Uri $source.Value -OutFile $downloaded -UseBasicParsing -TimeoutSec 15 -MaximumRedirection 5 -ErrorAction Stop
                $sourcePath = $downloaded
                $cloudDownloaded = [bool]$CloudPreferred
            } catch {
                if (-not $CloudPreferred) { throw }
                Write-Log "Could not download latest ${CfgName}: $($_.Exception.Message)" 'WARN'
                $sourcePath = Get-FriendConfigFallback -CfgName $CfgName -CfgDirectory $cfgDirectory
                if (-not $sourcePath -and $CfgName -eq 'fab.cfg') {
                    # FabMode has the original at.cfg embedded for first-run offline use.
                    # The installed filename is still fab.cfg, not at.cfg.
                    [IO.File]::WriteAllBytes($downloaded, [Convert]::FromBase64String($script:EmbeddedAtCfgBase64))
                    $sourcePath = $downloaded
                    Write-Log 'GitHub unavailable; using embedded at.cfg content as offline fab.cfg fallback.' 'WARN'
                }
                if (-not $sourcePath) {
                    throw "GitHub download unavailable and no cached/local $CfgName exists. Skipping this config; other profile steps can continue."
                }
                Write-Log "Using offline fallback for ${CfgName}: $sourcePath" 'WARN'
                $source = [pscustomobject]@{ Type='File'; Value=$sourcePath; RememberUrl=$false }
            }
        } else {
            $sourcePath = $source.Value
        }

        $fileInfo = Get-Item -LiteralPath $sourcePath -ErrorAction Stop
        if ($fileInfo.Length -lt 1 -or $fileInfo.Length -gt 2097152) {
            throw "$CfgName is empty or larger than 2 MB. Installation stopped."
        }
        $buffer = [IO.File]::ReadAllBytes($sourcePath)
        $firstBytes = [Text.Encoding]::UTF8.GetString($buffer, 0, [Math]::Min($buffer.Length, 300)).TrimStart([char[]]@([char]0xFEFF, [char]32, [char]13, [char]10, [char]9))
        if ($firstBytes -match '(?i)^(<!doctype\s+html|<html\b|\{\s*"(?:message|error)"\s*:)') {
            throw 'The download appears to be a webpage/API error rather than a .cfg file. Use a direct raw-file download URL.'
        }
        if ([Array]::IndexOf($buffer, [byte]0) -ge 0) {
            throw 'The source contains NUL bytes and does not appear to be a plain-text CFG.'
        }

        # Apply optional per-profile sensitivity to a TEMP copy, never overwrite the GitHub source.
        # Blank = use sensitivity already defined by the friend CFG.
        if (-not [string]::IsNullOrWhiteSpace($CS2Sensitivity)) {
            $parsedSens = 0.0
            if (-not [double]::TryParse($CS2Sensitivity, [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$parsedSens) -or
                [double]::IsNaN($parsedSens) -or $parsedSens -le 0 -or $parsedSens -gt 20) {
                throw 'CS2 sensitivity must be blank or a number greater than 0 and at most 20.'
            }
            $sensText = $parsedSens.ToString('0.####', [Globalization.CultureInfo]::InvariantCulture)
            $cfgText = [IO.File]::ReadAllText($sourcePath)
            $cfgText = [Regex]::Replace($cfgText,
                '(?m)^[ \t]*// CafeLauncher sensitivity override[ \t]*\r?\n[ \t]*sensitivity\s+"[0-9.]+"[ \t]*\r?\n?', '')
            $configured = Join-Path $env:TEMP ("CafeLauncher-configured-{0}.cfg" -f [Guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText($configured, ($cfgText.TrimEnd() + "`r`n// CafeLauncher sensitivity override`r`nsensitivity `"$sensText`"`r`n"),
                (New-Object System.Text.UTF8Encoding($false)))
            $sourcePath = $configured
            Write-Log "$CfgName sensitivity override prepared: $sensText."
        }

        $dest = Join-Path $cfgDirectory $CfgName
        $expected = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256 -ErrorAction Stop).Hash
        $previousHash = if (Test-Path -LiteralPath $dest -PathType Leaf) {
            (Get-FileHash -LiteralPath $dest -Algorithm SHA256 -ErrorAction Stop).Hash
        } else { $null }
        if ($previousHash -eq $expected) {
            Write-Log "$CfgName already matches the latest source (no replacement/backup needed)."
        } else {
            $staged = Join-Path $cfgDirectory ("{0}.cafe-{1}.tmp" -f $CfgName, [Guid]::NewGuid().ToString('N'))
            Copy-Item -LiteralPath $sourcePath -Destination $staged -ErrorAction Stop
            if ($previousHash) {
                $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
                $backup = Join-Path $cfgDirectory ("{0}.backup-{1}" -f $CfgName, $stamp)
                Copy-Item -LiteralPath $dest -Destination $backup -ErrorAction Stop
                Write-Log "Backed up previous $CfgName to $backup"
            }
            Copy-Item -LiteralPath $staged -Destination $dest -Force -ErrorAction Stop
        }
        $actual = (Get-FileHash -LiteralPath $dest -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($expected -ne $actual) { throw 'SHA-256 verification failed: installed file does not match the source.' }

        if ($cloudDownloaded -and $downloaded -and (Test-Path -LiteralPath $downloaded -PathType Leaf)) {
            try {
                $cacheDir = Join-Path $env:LOCALAPPDATA 'CafeLauncher\cfg-cache'
                if (-not (Test-Path -LiteralPath $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force -ErrorAction Stop | Out-Null }
                Copy-Item -LiteralPath $downloaded -Destination (Join-Path $cacheDir $CfgName) -Force -ErrorAction Stop
                Write-Log "Latest GitHub $CfgName cached for offline use."
            } catch {
                Write-Log "Could not update offline CFG cache: $($_.Exception.Message)" 'WARN'
            }
        }

        if ($source.Type -eq 'Url' -and $source.RememberUrl) {
            try {
                $savedFile = Join-Path $env:LOCALAPPDATA ('CafeLauncher\{0}_cfg_url.txt' -f [IO.Path]::GetFileNameWithoutExtension($CfgName))
                $savedDir = Split-Path -Parent $savedFile
                if (-not (Test-Path -LiteralPath $savedDir)) { New-Item -ItemType Directory -Path $savedDir -Force -ErrorAction Stop | Out-Null }
                Set-Content -LiteralPath $savedFile -Value $source.Value -Encoding UTF8 -ErrorAction Stop
                Write-Log "Saved config download URL for later use on this PC: $savedFile"
            } catch {
                Write-Log "Installed $CfgName, but could not save the download URL: $($_.Exception.Message)" 'WARN'
            }
        }

        Write-Log "CS2 $CfgName installed and SHA-256 verified: $dest"
        if (-not $Silent) {
            [System.Windows.Forms.MessageBox]::Show(
                "$CfgName installed successfully!`n`n$dest`n`nTo load it in CS2: exec $([IO.Path]::GetFileNameWithoutExtension($CfgName))",
                'Cafe Launcher',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
        return $true
    } catch {
        Write-Log "CS2 $CfgName installation failed: $($_.Exception.Message)" 'ERROR'
        if (-not $Silent) {
            [System.Windows.Forms.MessageBox]::Show(
                "Could not install ${CfgName}:`n$($_.Exception.Message)",
                'Cafe Launcher',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
        return $false
    } finally {
        foreach ($temporary in @($downloaded, $staged, $configured)) {
            if ($temporary -and (Test-Path -LiteralPath $temporary -PathType Leaf)) {
                try { Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop } catch {}
            }
        }
    }
}

# ============================================================== 
# Automatic PC inventory; safe to run without administrator rights.
# ============================================================== 
function Get-SteamExecutable {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Steam\steam.exe",
        "$env:ProgramFiles\Steam\steam.exe",
        "$env:LOCALAPPDATA\Steam\steam.exe"
    )
    foreach ($root in @(Get-SteamLibraryRoots)) { $candidates += (Join-Path $root 'steam.exe') }
    return Find-App -Paths $candidates
}

function Start-DetectedSteam {
    $steamExe = Get-SteamExecutable
    if ($steamExe) {
        try { Start-Process -FilePath $steamExe -ErrorAction Stop; Write-Log "Steam launched from $steamExe" }
        catch { Write-Log "Steam failed to launch: $($_.Exception.Message)" 'ERROR' }
    } else { Write-Log 'Steam executable not found.' 'WARN' }
}

function Get-PCDiagnostics {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    try{$scan=Get-NvidiaCompatibilityScan;foreach($line in $scan.Report){$lines.Add('NVIDIA: '+$line)}}
    catch{$lines.Add('NVIDIA compatibility scan unavailable: '+$_.Exception.Message)}
    $lines.Add("Machine: $env:COMPUTERNAME")
    try {
        $gpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
            Where-Object { $_.Name } | Select-Object -ExpandProperty Name)
        $lines.Add('Graphics: ' + ($(if ($gpus.Count) { $gpus -join '; ' } else { 'Unavailable' })))
    } catch { $lines.Add('Graphics: Could not query GPU details') }
    try {
        if ('FabDisplayNative' -as [type]) {
            $lines.Add([FabDisplayNative]::GetDisplayModesReport())
        } else { $lines.Add('Display modes: driver helper unavailable') }
        foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
            $lines.Add("Monitor $($screen.DeviceName): $($screen.Bounds.Width)x$($screen.Bounds.Height), primary=$($screen.Primary)")
        }
    } catch { $lines.Add('Display inventory could not be read') }
    try {
        $ptr = [Runtime.InteropServices.Marshal]::AllocHGlobal(4)
        try {
            $ok = [FabMouseNative]::SystemParametersInfo(0x0070,0,$ptr,0)
            if ($ok) { $lines.Add('Active Windows pointer speed: ' + [Runtime.InteropServices.Marshal]::ReadInt32($ptr)) }
            else { $lines.Add('Pointer speed API read failed') }
        } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($ptr) }
        $m = Get-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -ErrorAction Stop
        $lines.Add("Mouse registry: speed=$($m.MouseSensitivity), acceleration=$($m.MouseSpeed), thresholds=$($m.MouseThreshold1)/$($m.MouseThreshold2)")
    } catch { $lines.Add('Mouse settings could not be read') }
    $steam = Get-SteamExecutable
    $lines.Add('Steam: ' + $(if ($steam) { $steam } else { 'not detected' }))
    $roots = @(Get-SteamLibraryRoots)
    $lines.Add('Steam libraries: ' + $(if ($roots.Count) { $roots -join '; ' } else { 'not detected' }))
    $cs2 = Find-CS2ConfigFolder -NoPrompt
    $lines.Add('CS2 config: ' + $(if ($cs2) { $cs2 } else { 'not detected' }))
    $faceit = Find-App -Paths @("$env:ProgramFiles\FACEIT AC\faceitclient.exe", "${env:ProgramFiles(x86)}\FACEIT AC\faceitclient.exe")
    $lines.Add('FACEIT AC: ' + $(if ($faceit) { $faceit } else { 'not detected' }))
    $ghub = Find-App -Paths @("$env:ProgramFiles\LGHUB\lghub.exe", "$env:ProgramFiles\LGHUB\lghub_system_tray.exe")
    $lines.Add('Logitech G HUB: ' + $(if ($ghub) { $ghub } else { 'not detected' }))
    $chrome = Get-ChromePath
    $lines.Add('Chrome: ' + $(if ($chrome) { $chrome } else { 'not detected' }))
    try {
        $nvPanel = Find-App -Paths @("$env:ProgramFiles\NVIDIA Corporation\Control Panel Client\nvcplui.exe", "${env:ProgramFiles(x86)}\NVIDIA Corporation\Control Panel Client\nvcplui.exe")
        if (-not $nvPanel) {
            $storeApp = Get-StartApps -ErrorAction Stop | Where-Object { $_.Name -match '^NVIDIA Control Panel$' } | Select-Object -First 1
            if ($storeApp) { $nvPanel='Installed Store app' }
        }
        $lines.Add('NVIDIA Control Panel: ' + $(if ($nvPanel) { $nvPanel } else { 'not detected' }))
    } catch { $lines.Add('NVIDIA Control Panel: not detected') }
    return ($lines -join [Environment]::NewLine)
}

function Show-PCDiagnostics {
    Write-Log 'PC detection started.'
    try {
        $summary = Get-PCDiagnostics
        foreach ($line in ($summary -split '\r?\n')) { if ($line) { Write-Log ('PC: ' + $line) } }
        $formDialog = New-Object System.Windows.Forms.Form
        $formDialog.Text='PC Detection - CafeLauncher'
        $formDialog.ClientSize=[System.Drawing.Size]::new(755,445)
        $formDialog.StartPosition='CenterParent'
        $formDialog.BackColor=$BG
        $formDialog.ForeColor=$WHITE
        $formDialog.Font=New-Object System.Drawing.Font('Consolas',10)
        $reportBox = New-Object System.Windows.Forms.TextBox
        $reportBox.Location=[System.Drawing.Point]::new(12,12)
        $reportBox.Size=[System.Drawing.Size]::new(731,385)
        $reportBox.Multiline=$true
        $reportBox.ReadOnly=$true
        $reportBox.ScrollBars='Both'
        $reportBox.WordWrap=$false
        $reportBox.BackColor=$PANEL
        $reportBox.ForeColor=$WHITE
        $reportBox.Text=$summary
        $formDialog.Controls.Add($reportBox)
        $close = New-Object System.Windows.Forms.Button
        $close.Text='Close'
        $close.Location=[System.Drawing.Point]::new(633,404)
        $close.Size=[System.Drawing.Size]::new(110,30)
        $close.Add_Click({ $formDialog.Close() })
        $formDialog.Controls.Add($close)
        [void]$formDialog.ShowDialog($form)
        $formDialog.Dispose()
    } catch { Write-Log "PC detection failed: $($_.Exception.Message)" 'ERROR' }
}

# ============================================================== 
# Public GitHub updater: no token needed, never auto-runs new code.
# Compares local content to the main-branch Git blob SHA, verifies download.
# ============================================================== 
function Get-GitBlobSha {
    param([byte[]]$Bytes)
    $head=[Text.Encoding]::ASCII.GetBytes('blob ' + $Bytes.Length + [char]0)
    $blob=New-Object byte[] ($head.Length + $Bytes.Length)
    [Array]::Copy($head,0,$blob,0,$head.Length)
    [Array]::Copy($Bytes,0,$blob,$head.Length,$Bytes.Length)
    $sha=[Security.Cryptography.SHA1]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($blob))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Test-LauncherIsCurrent {
    param([string]$CurrentPath,[string]$RemoteBlobSha)
    if (-not (Test-Path -LiteralPath $CurrentPath -PathType Leaf)) { return $false }
    $bytes=[IO.File]::ReadAllBytes($CurrentPath)
    if ((Get-GitBlobSha -Bytes $bytes) -eq $RemoteBlobSha) { return $true }
    # Chrome/Drive may preserve CRLF even when GitHub stores LF. Ignore just
    # line-ending differences and an optional final newline for comparison.
    $normalized=[Text.Encoding]::UTF8.GetString($bytes).Replace("`r`n","`n")
    if ((Get-GitBlobSha -Bytes ([Text.Encoding]::UTF8.GetBytes($normalized))) -eq $RemoteBlobSha) { return $true }
    $oneNewline=$normalized.TrimEnd("`n")
    return (Get-GitBlobSha -Bytes ([Text.Encoding]::UTF8.GetBytes($oneNewline))) -eq $RemoteBlobSha
}

function Check-CafeLauncherUpdates {
    param([switch]$Manual)
    $source=$env:CAFE_SCRIPT
    if ([string]::IsNullOrWhiteSpace($source)) {
        if ($Manual) { Write-Log 'Current BAT path not available for updater.' 'WARN' }
        return
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $uri="https://api.github.com/repos/fabjoncela/Cs-script/contents/cafe.bat?ref=main"
        $remote=Invoke-RestMethod -Uri $uri -Headers @{'User-Agent'='CafeLauncher-Updater'; 'Accept'='application/vnd.github+json'} -TimeoutSec 8 -ErrorAction Stop
        if ($remote.path -ne 'cafe.bat' -or $remote.sha -notmatch '^[a-fA-F0-9]{40}$' -or
            [int64]$remote.size -lt 10000 -or [int64]$remote.size -gt 1000000) { throw 'Unexpected update metadata from GitHub.' }
        # Ignore older/unversioned GitHub builds. A new release must increment
        # its CAFE_RELEASE marker, rather than merely have different line endings.
        if ($remote.encoding -ne 'base64' -or [string]::IsNullOrWhiteSpace($remote.content)) {
            throw 'GitHub did not include update version metadata.'
        }
        $remoteText=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($remote.content -replace '\s','')))
        $pattern='(?m)^# CAFE_RELEASE=(\d{4}\.\d{1,2}\.\d{1,2}\.\d+)\s*$'
        $remoteMatch=[regex]::Match($remoteText,$pattern)
        $localMatch=[regex]::Match([IO.File]::ReadAllText($source),$pattern)
        if (-not $remoteMatch.Success) {
            Write-Log 'GitHub main has no release marker (older launcher); skipping downgrade. Upload this new cafe.bat to main first.' 'WARN'
            if ($Manual) { [System.Windows.Forms.MessageBox]::Show('Your current local build is newer than the unversioned GitHub launcher. Upload this BAT to GitHub main to activate self-updates.', 'Update Check', 'OK', 'Information') | Out-Null }
            return
        }
        $remoteRelease=[version]::Parse($remoteMatch.Groups[1].Value)
        $localRelease=if ($localMatch.Success) { [version]::Parse($localMatch.Groups[1].Value) } else { [version]'0.0.0.0' }
        if ($remoteRelease -le $localRelease) {
            Write-Log "CafeLauncher local release $localRelease is current; GitHub main release is $remoteRelease."
            if ($Manual) { [System.Windows.Forms.MessageBox]::Show("CafeLauncher is current (local $localRelease; GitHub $remoteRelease).", 'Update Check', 'OK', 'Information') | Out-Null }
            return
        }
        if (Test-LauncherIsCurrent -CurrentPath $source -RemoteBlobSha $remote.sha) {
            Write-Log 'CafeLauncher is up to date with GitHub main.'
            if ($Manual) { [System.Windows.Forms.MessageBox]::Show('CafeLauncher is already up to date.', 'Update Check', 'OK', 'Information') | Out-Null }
            return
        }
        Write-Log 'A newer/different cafe.bat is available on GitHub main.' 'INFO'
        $reply=[System.Windows.Forms.MessageBox]::Show(
            "GitHub has a different CafeLauncher build.`n`nDownload and replace your local BAT?`n`nYour currently open launcher will keep running. Reopen it to use the update.`n`nNo GitHub login required.",
            'CafeLauncher Update Available',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($reply -ne [System.Windows.Forms.DialogResult]::Yes) { Write-Log 'User skipped CafeLauncher update.'; return }
        $temp=Join-Path $env:TEMP ("CafeLauncher-update-{0}.bat" -f [Guid]::NewGuid().ToString('N'))
        try {
            Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/fabjoncela/Cs-script/main/cafe.bat' -OutFile $temp -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop | Out-Null
            $bytes=[IO.File]::ReadAllBytes($temp)
            if ($bytes.Length -ne [int64]$remote.size -or
                (Get-GitBlobSha -Bytes $bytes) -ne $remote.sha) { throw 'Downloaded BAT failed GitHub blob hash and size verification.' }
            $text=[Text.Encoding]::UTF8.GetString($bytes)
            if (-not $text.StartsWith('@echo off') -or -not $text.Contains('# POWERSHELL_GUI')) { throw 'Downloaded launcher structure check failed.' }
            # Verify that the embedded PowerShell can be PARSED before installing it.
            # In earlier releases, a correct GitHub hash was incorrectly treated as proof
            # that the replacement could launch. A hash does not verify syntax.
            $downloadLines=[IO.File]::ReadAllLines($temp)
            $marker=[Array]::IndexOf($downloadLines,'# POWERSHELL_GUI')
            if ($marker -lt 0 -or $marker -ge ($downloadLines.Length - 1)) { throw 'Update has no valid PowerShell section.' }
            $downloadScript=($downloadLines[($marker+1)..($downloadLines.Length-1)] -join [Environment]::NewLine)
            $parseTokens=$null
            $parseErrors=$null
            [void][System.Management.Automation.Language.Parser]::ParseInput($downloadScript,[ref]$parseTokens,[ref]$parseErrors)
            if ($parseErrors.Count -gt 0) {
                throw ('Refusing update with PowerShell syntax errors: ' + $parseErrors[0].ToString())
            }
            # Raw GitHub .bat content can use LF-only line endings. cmd.exe on Windows
            # expects CRLF for reliable BAT interpretation. Verify original bytes above,
            # then normalize the verified payload BEFORE placing it on disk.
            $windowsText=$text.Replace("`r`n","`n").Replace("`r","`n").Replace("`n","`r`n")
            [IO.File]::WriteAllText($temp,$windowsText,(New-Object System.Text.UTF8Encoding($false)))
            $backupDir=Join-Path $env:LOCALAPPDATA 'CafeLauncher\backups'
            if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force -ErrorAction Stop | Out-Null }
            $backup=Join-Path $backupDir ("cafe-before-update-{0}.bat" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            try {
                # Stage beside the original and replace atomically when supported;
                # this avoids leaving a partially overwritten BAT after a crash.
                $staged=Join-Path (Split-Path -Parent $source) ('.CafeLauncher-update-' + [Guid]::NewGuid().ToString('N') + '.bat')
                try {
                    Copy-Item -LiteralPath $temp -Destination $staged -ErrorAction Stop
                    try {
                        [IO.File]::Replace($staged,$source,$backup)
                    } catch {
                        # File.Replace can be unavailable on network/FAT volumes.
                        Copy-Item -LiteralPath $source -Destination $backup -ErrorAction Stop
                        Copy-Item -LiteralPath $staged -Destination $source -Force -ErrorAction Stop
                    }
                } finally {
                    Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
                }
                Write-Log "Update downloaded, syntax-checked, CRLF-normalized and installed at $source; backup: $backup"
                [System.Windows.Forms.MessageBox]::Show("CafeLauncher updated successfully at:`n$source`n`nClose and reopen the BAT to use the latest version.", 'Update Installed', 'OK', 'Information') | Out-Null
            } catch {
                $dest=Join-Path $env:USERPROFILE 'Downloads\CafeLauncher_latest.bat'
                Copy-Item -LiteralPath $temp -Destination $dest -Force -ErrorAction Stop
                Write-Log "Current BAT could not be overwritten; saved verified update to $dest" 'WARN'
                [System.Windows.Forms.MessageBox]::Show("Your original BAT could not be replaced (read-only/protected folder).`n`nA verified new copy was saved to:`n$dest`n`nOpen that copy next time.", 'Update Downloaded', 'OK', 'Warning') | Out-Null
            }
        } finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    } catch {
        Write-Log "Update check/download failed; the existing launcher is unchanged where possible: $($_.Exception.Message)" 'WARN'
        if ($Manual) { [System.Windows.Forms.MessageBox]::Show("Update check failed: $($_.Exception.Message)", 'Update Check', 'OK', 'Warning') | Out-Null }
    }
}

function Launch-All {
    Start-DetectedSteam

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

# ==============================================================
# PROFILE DEFAULTS - Edit in GUI, save locally or sync via GitHub
# Cloud profile settings: profiles/<ProfileName>.json (public read).
# CS2 .cfg files remain separately managed on GitHub.
# Local unsynced edits ALWAYS win over downloaded cloud settings.
# ==============================================================
$script:GithubRepo = 'fabjoncela/Cs-script'
$script:GithubBranch = 'main'
$script:FabCfgCloudUrl = 'https://raw.githubusercontent.com/fabjoncela/Cs-script/main/fab.cfg'
$script:GamingProfiles = [ordered]@{
    FabMode = @{
        PointerSpeed=10; LogitechDPI=800; DisableAcceleration=$true; ApplyNvidia=$true
        Width=1920; Height=1080; RefreshHz=360; Vibrance=75
        CS2Sensitivity=''; ConfigFile='fab.cfg'; CfgDownloadUrl=$script:FabCfgCloudUrl; LaunchApps=$true
    }
    ArliMode = @{
        PointerSpeed=10; LogitechDPI=800; DisableAcceleration=$true; ApplyNvidia=$true
        Width=1920; Height=1080; RefreshHz=360; Vibrance=75
        CS2Sensitivity=''; ConfigFile='arli.cfg'; CfgDownloadUrl='https://raw.githubusercontent.com/fabjoncela/Cs-script/main/arli.cfg'; LaunchApps=$true
    }
    BrileMode = @{
        PointerSpeed=10; LogitechDPI=800; DisableAcceleration=$true; ApplyNvidia=$true
        Width=1920; Height=1080; RefreshHz=360; Vibrance=75
        CS2Sensitivity=''; ConfigFile='brile.cfg'; CfgDownloadUrl='https://raw.githubusercontent.com/fabjoncela/Cs-script/main/brile.cfg'; LaunchApps=$true
    }
    ArmlMode = @{
        PointerSpeed=10; LogitechDPI=800; DisableAcceleration=$true; ApplyNvidia=$true
        Width=1920; Height=1080; RefreshHz=360; Vibrance=75
        CS2Sensitivity=''; ConfigFile='arml.cfg'; CfgDownloadUrl='https://raw.githubusercontent.com/fabjoncela/Cs-script/main/arml.cfg'; LaunchApps=$true
    }
    OliMode = @{
        PointerSpeed=10; LogitechDPI=800; DisableAcceleration=$true; ApplyNvidia=$true
        Width=1920; Height=1080; RefreshHz=360; Vibrance=75
        CS2Sensitivity=''; ConfigFile='oli.cfg'; CfgDownloadUrl='https://raw.githubusercontent.com/fabjoncela/Cs-script/main/oli.cfg'; LaunchApps=$true
    }
}
$script:ProfileSettingsPath = Join-Path $env:LOCALAPPDATA 'CafeLauncher\profiles.json'
$script:PendingSync = @{}
foreach ($name in @($script:GamingProfiles.Keys)) { $script:PendingSync[$name] = $false }

function Import-ProfileValues {
    param([string]$ProfileName, $SavedProfile, [string]$SourceLabel = 'local')
    if (-not $script:GamingProfiles.Contains($ProfileName) -or -not $SavedProfile) { return }
    foreach ($setting in @('PointerSpeed','LogitechDPI','DisableAcceleration','ApplyNvidia','Width','Height','RefreshHz','Vibrance','CS2Sensitivity','CfgDownloadUrl','LaunchApps')) {
        $saved = $SavedProfile.PSObject.Properties[$setting]
        if (-not $saved) { continue }
        $value = $saved.Value
        try {
            switch ($setting) {
                'PointerSpeed' { $value=[int]$value; if ($value -lt 1 -or $value -gt 20) { throw 'range' } }
                'LogitechDPI' { $value=[int]$value; if ($value -lt 100 -or $value -gt 25600) { throw 'range' } }
                'Width'        { $value=[int]$value; if ($value -lt 640 -or $value -gt 7680) { throw 'range' } }
                'Height'       { $value=[int]$value; if ($value -lt 480 -or $value -gt 4320) { throw 'range' } }
                'RefreshHz'    { $value=[int]$value; if ($value -lt 30 -or $value -gt 600) { throw 'range' } }
                'Vibrance'     { $value=[int]$value; if ($value -lt 0 -or $value -gt 100) { throw 'range' } }
                'CS2Sensitivity' {
                    $value=[string]$value
                    if ($value -and $value -notmatch '^(?:[0-9]+(?:\.[0-9]+)?)$') { throw 'invalid sensitivity' }
                    if ($value -and ([double]::Parse($value,[Globalization.CultureInfo]::InvariantCulture) -le 0 -or [double]::Parse($value,[Globalization.CultureInfo]::InvariantCulture) -gt 20)) { throw 'range' }
                }
                'CfgDownloadUrl' {
                    $value = [string]$value
                    if ($ProfileName -eq 'FabMode' -and [string]::IsNullOrWhiteSpace($value)) {
                        $value = $script:FabCfgCloudUrl
                        Write-Log 'Migrated old FabMode empty CFG URL to GitHub fab.cfg.'
                    }
                    if ($value) { Assert-ConfigUrl $value }
                }
                default {
                    if ($setting -in @('DisableAcceleration','ApplyNvidia','LaunchApps')) {
                        if ($value -isnot [bool]) { throw 'boolean expected' }
                    }
                }
            }
            $script:GamingProfiles[$ProfileName][$setting] = $value
        } catch { Write-Log "Ignored invalid $SourceLabel $ProfileName/$setting value." 'WARN' }
    }
}

function Load-ProfileSettings {
    if (-not (Test-Path -LiteralPath $script:ProfileSettingsPath -PathType Leaf)) { return }
    try {
        $settings = Get-Content -LiteralPath $script:ProfileSettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($name in @($script:GamingProfiles.Keys)) {
            $savedProfile = $settings.PSObject.Properties[$name]
            if (-not $savedProfile -or -not $savedProfile.Value) { continue }
            Import-ProfileValues -ProfileName $name -SavedProfile $savedProfile.Value -SourceLabel 'local'
            $dirty = $savedProfile.Value.PSObject.Properties['SyncPending']
            # Old versions saved ONLY locally: protect edits from being replaced by cloud defaults.
            if ($dirty -and $dirty.Value -is [bool]) {
                $script:PendingSync[$name] = [bool]$dirty.Value
            } else {
                $script:PendingSync[$name] = $true
            }
        }
        Write-Log "Loaded local profile settings from $script:ProfileSettingsPath."
    } catch {
        Write-Log "Profile settings JSON could not be read; using defaults: $($_.Exception.Message)" 'WARN'
    }
}

function Export-ProfileValues {
    param([string]$ProfileName)
    $p = $script:GamingProfiles[$ProfileName]
    if (-not $p) { throw "Unknown profile: $ProfileName" }
    $profileValues = [ordered]@{
        PointerSpeed=[int]$p.PointerSpeed; LogitechDPI=[int]$p.LogitechDPI; DisableAcceleration=[bool]$p.DisableAcceleration
        ApplyNvidia=[bool]$p.ApplyNvidia; Width=[int]$p.Width; Height=[int]$p.Height
        RefreshHz=[int]$p.RefreshHz; Vibrance=[int]$p.Vibrance
        CS2Sensitivity=[string]$p.CS2Sensitivity; CfgDownloadUrl=[string]$p.CfgDownloadUrl
        LaunchApps=[bool]$p.LaunchApps
    }
    # Preserve the dictionary as ONE pipeline object on Windows PowerShell 5.1.
    Write-Output -NoEnumerate $profileValues
}

function Save-ProfileSettings {
    # Build a full independent snapshot before writing to disk. Do NOT index
    # $settings[$name] immediately after assignment: in some Windows PowerShell
    # hosts a missing/empty pipeline output caused a null-array exception here.
    $settings = [ordered]@{}
    foreach ($name in @($script:GamingProfiles.Keys)) {
        $values = Export-ProfileValues -ProfileName $name
        if ($null -eq $values -or $values -isnot [System.Collections.IDictionary]) {
            throw "Cannot save ${name}: the profile exporter did not return a settings dictionary."
        }
        $snapshot = [ordered]@{}
        foreach ($key in @($values.Keys)) { $snapshot[$key] = $values[$key] }
        $snapshot['SyncPending'] = [bool]$script:PendingSync[$name]
        $settings[$name] = $snapshot
    }
    $dir = Split-Path -Parent $script:ProfileSettingsPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
    $tmp = Join-Path $dir ("profiles-{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($tmp, ($settings | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $script:ProfileSettingsPath -Force -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    Write-Log "Profile settings saved locally: $script:ProfileSettingsPath"
}

Load-ProfileSettings

function Refresh-ProfileFromGitHub {
    param([Parameter(Mandatory=$true)][string]$ProfileName)
    if (-not $script:GamingProfiles.Contains($ProfileName)) { throw "Unknown profile: $ProfileName" }
    if ($script:PendingSync[$ProfileName]) {
        Write-Log "$ProfileName has local edits not synced to GitHub; keeping local settings." 'INFO'
        return
    }
    $url = "https://raw.githubusercontent.com/$($script:GithubRepo)/$($script:GithubBranch)/profiles/$ProfileName.json"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        # GitHub content is JSON data only; no code is executed from remote profiles.
        $remote = Invoke-RestMethod -Uri $url -Method Get -Headers @{'Cache-Control'='no-cache'} -TimeoutSec 8 -ErrorAction Stop
        if ($remote.ProfileName -ne $ProfileName -or [int]$remote.SchemaVersion -ne 1) {
            throw "Unexpected profile JSON schema for $ProfileName."
        }
        Import-ProfileValues -ProfileName $ProfileName -SavedProfile $remote -SourceLabel 'GitHub'
        try { Save-ProfileSettings } catch { Write-Log "Unable to cache cloud settings: $($_.Exception.Message)" 'WARN' }
        Write-Log "$ProfileName settings downloaded from GitHub (no login needed)."
    } catch {
        Write-Log "Could not refresh $ProfileName settings from GitHub; using cached/local values. $($_.Exception.Message)" 'WARN'
    }
}

function Get-GitHubSyncToken {
    param($OwnerWindow)
    $authForm = New-Object System.Windows.Forms.Form
    $authForm.Text = 'Authorize GitHub Sync'
    $authForm.ClientSize = New-Object System.Drawing.Size(590,286)
    $authForm.StartPosition='CenterParent'
    $authForm.FormBorderStyle='FixedDialog'
    $authForm.MaximizeBox=$false
    $authForm.MinimizeBox=$false
    $authForm.BackColor=$PANEL
    $authForm.ForeColor=$WHITE
    $authForm.Font=New-Object System.Drawing.Font('Segoe UI',10)

    $instructions = New-Object System.Windows.Forms.Label
    $instructions.Text = "Paste a fine-grained GitHub access token for $($script:GithubRepo).`r`nPermissions: Contents = Read and write (only this repo).`r`nCreate a short-lived token and revoke it when finished."
    $instructions.Location=New-Object System.Drawing.Point(20,18)
    $instructions.Size=New-Object System.Drawing.Size(550,75)
    $authForm.Controls.Add($instructions)

    $secretBox = New-Object System.Windows.Forms.TextBox
    $secretBox.Location=New-Object System.Drawing.Point(20,106)
    $secretBox.Size=New-Object System.Drawing.Size(545,30)
    $secretBox.UseSystemPasswordChar=$true
    $authForm.Controls.Add($secretBox)

    $warning = New-Object System.Windows.Forms.Label
    $warning.Text='Never paste a GitHub token on an untrusted/shared cafe PC. Tokens are not saved by CafeLauncher.'
    $warning.ForeColor=[System.Drawing.Color]::FromArgb(255,190,105)
    $warning.Location=New-Object System.Drawing.Point(20,147)
    $warning.Size=New-Object System.Drawing.Size(550,46)
    $authForm.Controls.Add($warning)

    $create = New-Object System.Windows.Forms.Button
    $create.Text='Create a GitHub token...'
    $create.Location=New-Object System.Drawing.Point(20,213)
    $create.Size=New-Object System.Drawing.Size(200,36)
    $create.Add_Click({ Start-Process 'https://github.com/settings/personal-access-tokens/new' })
    $authForm.Controls.Add($create)

    $ok=New-Object System.Windows.Forms.Button
    $ok.Text='Authorize & Upload'
    $ok.Location=New-Object System.Drawing.Point(267,213)
    $ok.Size=New-Object System.Drawing.Size(162,36)
    $ok.BackColor=$BLUE
    $ok.ForeColor=$WHITE
    $authForm.Controls.Add($ok)
    $cancel=New-Object System.Windows.Forms.Button
    $cancel.Text='Cancel'
    $cancel.Location=New-Object System.Drawing.Point(439,213)
    $cancel.Size=New-Object System.Drawing.Size(125,36)
    $cancel.DialogResult=[System.Windows.Forms.DialogResult]::Cancel
    $authForm.Controls.Add($cancel)
    $authForm.CancelButton=$cancel

    $ok.Add_Click({
        if ($secretBox.Text.Trim().Length -lt 20) {
            [System.Windows.Forms.MessageBox]::Show('Paste a valid GitHub token before uploading.', 'GitHub authorization', 'OK', 'Warning') | Out-Null
            return
        }
        $authForm.DialogResult=[System.Windows.Forms.DialogResult]::OK
        $authForm.Close()
    }.GetNewClosure())
    try {
        $result=$authForm.ShowDialog($OwnerWindow)
        if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        return $secretBox.Text.Trim()
    } finally {
        $secretBox.Clear()
        $authForm.Dispose()
    }
}

function Sync-ProfileToGitHub {
    param([Parameter(Mandatory=$true)][string]$ProfileName, [Parameter(Mandatory=$true)][string]$Token)
    if (-not $script:GamingProfiles.Contains($ProfileName)) { throw "Unknown profile: $ProfileName" }
    $path = "profiles/$ProfileName.json"
    $uri = "https://api.github.com/repos/$($script:GithubRepo)/contents/$path"
    $headers = @{
        'Authorization'="Bearer $Token"
        'Accept'='application/vnd.github+json'
        'User-Agent'='CafeLauncher-ProfileSync'
        'X-GitHub-Api-Version'='2022-11-28'
    }
    $existingSha = $null
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try {
        $current = Invoke-RestMethod -Uri ($uri + '?ref=' + $script:GithubBranch) -Method Get -Headers $headers -TimeoutSec 20 -MaximumRedirection 0 -ErrorAction Stop
        $existingSha = [string]$current.sha
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -ne 404) { throw "GitHub authorization or file read failed (HTTP $status)." }
    }

    $payload = [ordered]@{ SchemaVersion=1; ProfileName=$ProfileName }
    $values = Export-ProfileValues -ProfileName $ProfileName
    if ($null -eq $values -or $values -isnot [System.Collections.IDictionary]) {
        throw "Cannot sync ${ProfileName}: the profile exporter returned no valid settings."
    }
    foreach ($key in @($values.Keys)) { $payload[$key] = $values[$key] }
    $json = $payload | ConvertTo-Json -Depth 5
    $body = @{
        message="Update $ProfileName settings from CafeLauncher"
        content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json + "`n"))
        branch=$script:GithubBranch
    }
    if ($existingSha) { $body.sha = $existingSha }
    try {
        $result = Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 5 -Compress) -TimeoutSec 25 -MaximumRedirection 0 -ErrorAction Stop
        if (-not $result.commit.sha) { throw 'GitHub did not return a successful commit.' }
        Write-Log "$ProfileName settings synced to GitHub. Commit: $($result.commit.sha)"
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -eq 401 -or $status -eq 403) { throw 'GitHub refused the token. Check repository access and Contents: Read and write permission.' }
        if ($status -eq 409 -or $status -eq 422) { throw 'GitHub rejected the update due to a changed version or validation error. Retry syncing.' }
        throw "GitHub upload failed (HTTP $status). Your settings remain saved locally."
    } finally {
        $headers.Authorization = $null
        $body.content = $null
    }
}

function New-EditorLabel {
    param($Window, [string]$Caption, [int]$X, [int]$Y, [int]$Width=200)
    $label = New-Object System.Windows.Forms.Label
    $label.Text=$Caption
    $label.ForeColor=$script:EditorTextColor
    $label.Location=New-Object System.Drawing.Point($X,$Y)
    $label.Size=New-Object System.Drawing.Size($Width,23)
    $Window.Controls.Add($label)
    return $label
}

function New-EditorNumber {
    param($Window, [int]$X, [int]$Y, [int]$Min, [int]$Max, [int]$Value, [int]$Width=180)
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Location=New-Object System.Drawing.Point($X,$Y)
    $n.Size=New-Object System.Drawing.Size($Width,28)
    $n.Minimum=[decimal]$Min
    $n.Maximum=[decimal]$Max
    $n.Value=[decimal]$Value
    $Window.Controls.Add($n)
    return $n
}

function Show-ProfileEditor {
    param([Parameter(Mandatory=$true)][string]$ProfileName)
    Refresh-ProfileFromGitHub -ProfileName $ProfileName
    $p = $script:GamingProfiles[$ProfileName]
    if (-not $p) { throw "Unknown profile: $ProfileName" }
    # GetNewClosure() creates a new dynamic module scope. The script: scope
    # inside a captured click handler is NOT the original launcher's script:
    # scope. Capture a reference to the real pending-sync dictionary here.
    $pendingSyncState = $script:PendingSync
    if ($null -eq $pendingSyncState -or $pendingSyncState -isnot [System.Collections.IDictionary]) {
        throw 'Profile sync state is missing; cannot safely edit this profile.'
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Edit $ProfileName"
    $dialog.ClientSize = New-Object System.Drawing.Size(590,645)
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.BackColor = $PANEL
    $dialog.ForeColor = $WHITE
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI',10)
    $script:EditorTextColor = $WHITE

    New-EditorLabel $dialog 'Windows pointer speed (1-20)' 20 18 260 | Out-Null
    $pointer = New-EditorNumber $dialog 20 42 1 20 ([int]$p.PointerSpeed) 245
    New-EditorLabel $dialog 'NVIDIA Digital Vibrance (%)' 305 18 260 | Out-Null
    $vibrance = New-EditorNumber $dialog 305 42 0 100 ([int]$p.Vibrance) 245

    $accel = New-Object System.Windows.Forms.CheckBox
    $accel.Text='Enable Windows mouse acceleration (EPP)'
    $accel.Checked = -not [bool]$p.DisableAcceleration
    $accel.Location=New-Object System.Drawing.Point(20,83)
    $accel.Size=New-Object System.Drawing.Size(500,27)
    $dialog.Controls.Add($accel)

    New-EditorLabel $dialog 'Resolution width' 20 122 210 | Out-Null
    New-EditorLabel $dialog 'Resolution height' 205 122 210 | Out-Null
    New-EditorLabel $dialog 'Refresh rate (Hz)' 390 122 190 | Out-Null
    $width = New-EditorNumber $dialog 20 147 640 7680 ([int]$p.Width) 165
    $height = New-EditorNumber $dialog 205 147 480 4320 ([int]$p.Height) 165
    $hz = New-EditorNumber $dialog 390 147 30 600 ([int]$p.RefreshHz) 160

    New-EditorLabel $dialog 'CS2 sensitivity (blank = value from .cfg)' 20 196 530 | Out-Null
    $sens = New-Object System.Windows.Forms.TextBox
    $sens.Text=[string]$p.CS2Sensitivity
    $sens.Location=New-Object System.Drawing.Point(20,222)
    $sens.Size=New-Object System.Drawing.Size(530,29)
    $dialog.Controls.Add($sens)

    New-EditorLabel $dialog 'CS2 config filename (fixed for each profile)' 20 276 530 | Out-Null
    $cfgFile = New-Object System.Windows.Forms.TextBox
    $cfgFile.Text=[string]$p.ConfigFile
    $cfgFile.ReadOnly=$true
    $cfgFile.Location=New-Object System.Drawing.Point(20,300)
    $cfgFile.Size=New-Object System.Drawing.Size(530,29)
    $dialog.Controls.Add($cfgFile)

    New-EditorLabel $dialog 'GitHub .cfg URL (FabMode default: fab.cfg)' 20 355 540 | Out-Null
    $url = New-Object System.Windows.Forms.TextBox
    $url.Text=[string]$p.CfgDownloadUrl
    $url.Location=New-Object System.Drawing.Point(20,380)
    $url.Size=New-Object System.Drawing.Size(530,28)
    $dialog.Controls.Add($url)

    $nv = New-Object System.Windows.Forms.CheckBox
    $nv.Text='Apply NVIDIA settings (including resolution + vibrance)'
    $nv.Checked=[bool]$p.ApplyNvidia
    $nv.Location=New-Object System.Drawing.Point(20,430)
    $nv.Size=New-Object System.Drawing.Size(550,26)
    $dialog.Controls.Add($nv)

    $apps = New-Object System.Windows.Forms.CheckBox
    $apps.Text='Launch Steam, FACEIT, Spotify, G HUB, Mouse Options'
    $apps.Checked=[bool]$p.LaunchApps
    $apps.Location=New-Object System.Drawing.Point(20,461)
    $apps.Size=New-Object System.Drawing.Size(550,26)
    $dialog.Controls.Add($apps)

    $dialog.ClientSize = New-Object System.Drawing.Size(590,725)
    New-EditorLabel $dialog 'Logitech DPI (live, per profile)' 20 495 400 | Out-Null
    $logitechDpi = New-EditorNumber $dialog 405 493 100 25600 ([int]$p.LogitechDPI) 145
    $logitechDpi.Increment = 50
    $tip = New-EditorLabel $dialog 'Local edits stay on this PC. GitHub sync shares ALL profile settings; CFG binds remain separate.' 20 538 550
    $tip.ForeColor=$MUTED
    $tip.Font=New-Object System.Drawing.Font('Segoe UI',8)
    $tip.Size=New-Object System.Drawing.Size(550,37)

    $status = New-EditorLabel $dialog '' 20 582 550
    $status.Font=New-Object System.Drawing.Font('Segoe UI',8,[System.Drawing.FontStyle]::Bold)
    $status.Size=New-Object System.Drawing.Size(550,23)
    if ($script:PendingSync[$ProfileName]) {
        $status.Text='Unsynced local edits - cloud download will not overwrite them.'
        $status.ForeColor=[System.Drawing.Color]::FromArgb(255,190,105)
    } else {
        $status.Text='GitHub settings enabled - saved locally and cached for offline use.'
        $status.ForeColor=$MUTED
    }

    $saveLocal = New-Object System.Windows.Forms.Button
    $saveLocal.Text='Save Locally'
    $saveLocal.Location=New-Object System.Drawing.Point(20,635)
    $saveLocal.Size=New-Object System.Drawing.Size(155,40)
    $saveLocal.BackColor=$BLUE
    $saveLocal.ForeColor=$WHITE
    $saveLocal.FlatStyle='Flat'
    $dialog.Controls.Add($saveLocal)

    $saveSync = New-Object System.Windows.Forms.Button
    $saveSync.Text='Save & Sync to GitHub'
    $saveSync.Location=New-Object System.Drawing.Point(184,635)
    $saveSync.Size=New-Object System.Drawing.Size(219,40)
    $saveSync.BackColor=[System.Drawing.Color]::FromArgb(38,132,102)
    $saveSync.ForeColor=$WHITE
    $saveSync.FlatStyle='Flat'
    $dialog.Controls.Add($saveSync)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text='Cancel'
    $cancel.Location=New-Object System.Drawing.Point(413,635)
    $cancel.Size=New-Object System.Drawing.Size(137,40)
    $cancel.DialogResult=[System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancel)
    $dialog.CancelButton=$cancel

    $saveEditorValues = {
        $sensValue=$sens.Text.Trim()
        if ($sensValue) {
            $number=0.0
            if (-not [double]::TryParse($sensValue,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number) -or
                [double]::IsNaN($number) -or $number -le 0 -or $number -gt 20) {
                throw 'Sensitivity must be blank or between 0 and 20, using a decimal point (e.g. 1.2).'
            }
            $sensValue=$number.ToString('0.####',[Globalization.CultureInfo]::InvariantCulture)
        }
        $cfgUrl=$url.Text.Trim()
        if ($cfgUrl) { Assert-ConfigUrl $cfgUrl }
        $p.PointerSpeed=[int]$pointer.Value
        $p.LogitechDPI=[int]$logitechDpi.Value
        Assert-LogitechDPI $p.LogitechDPI
        $p.DisableAcceleration= -not $accel.Checked
        $p.Width=[int]$width.Value
        $p.Height=[int]$height.Value
        $p.RefreshHz=[int]$hz.Value
        $p.Vibrance=[int]$vibrance.Value
        $p.ApplyNvidia=[bool]$nv.Checked
        $p.LaunchApps=[bool]$apps.Checked
        $p.CS2Sensitivity=$sensValue
        $p.CfgDownloadUrl=$cfgUrl
        # Use the captured shared dictionary, not script: scope in this closure.
        $pendingSyncState[$ProfileName] = $true
        Save-ProfileSettings
        Write-Log "$ProfileName edited locally: pointer=$($p.PointerSpeed), acceleration enabled=$(-not $p.DisableAcceleration), display=$($p.Width)x$($p.Height)@$($p.RefreshHz), vibrance=$($p.Vibrance)%, LogitechDPI=$($p.LogitechDPI), sensitivity=$sensValue."
    }.GetNewClosure()

    $saveLocal.Add_Click({
        try {
            & $saveEditorValues
            [System.Windows.Forms.MessageBox]::Show("$ProfileName saved locally. No GitHub login required.`nChanges on a Deep Freeze PC may disappear after restart.", 'Saved locally', 'OK', 'Information') | Out-Null
            $dialog.DialogResult=[System.Windows.Forms.DialogResult]::OK
            $dialog.Close()
        } catch {
            Write-Log "Save Locally failed for ${ProfileName}: $($_.Exception.Message); $($_.ScriptStackTrace)" 'ERROR'
            [System.Windows.Forms.MessageBox]::Show("Could not save ${ProfileName}:`n$($_.Exception.Message)`n`nSee LIVE LOGS for the failing line.", 'Profile Editor', 'OK', 'Error') | Out-Null
        }
    }.GetNewClosure())

    $saveSync.Add_Click({
        try {
            & $saveEditorValues
            $token = Get-GitHubSyncToken -OwnerWindow $dialog
            if ([string]::IsNullOrWhiteSpace($token)) {
                $status.Text='Saved locally. GitHub sync canceled; local edits preserved.'
                $status.ForeColor=[System.Drawing.Color]::FromArgb(255,190,105)
                Write-Log "$ProfileName GitHub sync canceled; local changes preserved."
                return
            }
            try {
                $saveSync.Enabled=$false
                $dialog.Cursor=[System.Windows.Forms.Cursors]::WaitCursor
                Sync-ProfileToGitHub -ProfileName $ProfileName -Token $token
                $pendingSyncState[$ProfileName] = $false
                Save-ProfileSettings
                [System.Windows.Forms.MessageBox]::Show("$ProfileName settings committed to GitHub and saved locally.`nOther PCs can now download the new settings without signing in.`nThe .cfg bindings are still maintained separately on GitHub.", 'GitHub sync complete', 'OK', 'Information') | Out-Null
                $dialog.DialogResult=[System.Windows.Forms.DialogResult]::OK
                $dialog.Close()
            } finally {
                $token = $null
                if (-not $dialog.IsDisposed) {
                    $saveSync.Enabled=$true
                    $dialog.Cursor=[System.Windows.Forms.Cursors]::Default
                }
            }
        } catch {
            Write-Log "$ProfileName GitHub sync failed; local settings kept. $($_.Exception.Message); $($_.ScriptStackTrace)" 'WARN'
            $status.Text='Cloud sync failed; settings are saved locally. Retry Save & Sync.'
            $status.ForeColor=[System.Drawing.Color]::FromArgb(255,190,105)
            [System.Windows.Forms.MessageBox]::Show("$ProfileName saved locally, but GitHub sync failed:`n$($_.Exception.Message)", 'GitHub sync', 'OK', 'Warning') | Out-Null
        }
    }.GetNewClosure())

    [void]$dialog.ShowDialog($form)
    $dialog.Dispose()
}


# Portable Logitech HID++ CLI, downloaded from our tested SHA-256 pinned release.
function Assert-LogitechDPI {
    param([int]$DPI)
    if($DPI -lt 100 -or $DPI -gt 25600){throw 'Logitech DPI must be 100 to 25600.'}
}
# One asynchronous download at a time. WinForms timer handles completion on UI thread.
$script:LogihubDownloadProcess=$null
$script:LogihubDownloadTimer=$null
$script:LogihubRequestedDPI=$null
$script:LogihubDownloadStatus=$null
$script:LogihubExpectedSHA='dc30e45d4ba1df7d043c7c9a0aacda4257e09f5f23bb980466b985b77aa7dda4'
$script:LogihubDirectory=Join-Path $env:LOCALAPPDATA 'CafeLauncher\logihub'
$script:LogihubExe=Join-Path $script:LogihubDirectory 'logihub.exe'
function Get-LogihubExecutable {
    if(-not (Test-Path -LiteralPath $script:LogihubExe -PathType Leaf)){throw 'logihub.exe not downloaded yet.'}
    if((Get-FileHash -LiteralPath $script:LogihubExe -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() -ne $script:LogihubExpectedSHA){
        throw 'Cached logihub.exe checksum mismatch; refusing to execute.'
    }
    return $script:LogihubExe
}
function Start-LogihubAsyncDownload {
    if($script:LogihubDownloadProcess -and -not $script:LogihubDownloadProcess.HasExited){return}
    [void](New-Item -ItemType Directory -Path $script:LogihubDirectory -Force -ErrorAction Stop)
    $id=[guid]::NewGuid().ToString('N')
    $script:LogihubDownloadStatus=Join-Path $script:LogihubDirectory ('download-'+$id+'.status')
    $temp=Join-Path $script:LogihubDirectory ('logihub-'+$id+'.tmp')
    $status=$script:LogihubDownloadStatus
    $exe=$script:LogihubExe
    $expected=$script:LogihubExpectedSHA
    # Separate PowerShell process: no GUI-thread network I/O. Only this
    # known embedded script runs, and only the SHA-verified binary is cached.
    $worker=@'
param([string]$Temp,[string]$Destination,[string]$Status,[string]$Expected)
try {
    $ErrorActionPreference='Stop'
    [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri 'https://github.com/fabjoncela/better-logihub/releases/download/v0.1.0-c54d.1/logihub.exe' -OutFile $Temp -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    if((Get-FileHash -LiteralPath $Temp -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Expected){throw 'Downloaded Logitech helper SHA-256 verification failed.'}
    Move-Item -LiteralPath $Temp -Destination $Destination -Force -ErrorAction Stop
    [IO.File]::WriteAllText($Status,'OK')
} catch {
    [IO.File]::WriteAllText($Status,('ERROR: '+$_.Exception.Message))
} finally {
    Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
}
'@

    # EncodedCommand with positional parameters does not reliably bind flags after
    # the encoded script; instead pass required data as environment-safe literals
    # embedded before encoding (validated, generated local paths).
    $worker=$worker.Replace('param([string]$Temp,[string]$Destination,[string]$Status,[string]$Expected)',(
        '$Temp='+("'"+$temp.Replace("'","''")+"'")+'; '+
        '$Destination='+("'"+$exe.Replace("'","''")+"'")+'; '+
        '$Status='+("'"+$status.Replace("'","''")+"'")+'; '+
        '$Expected='+("'"+$expected+"'")))
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($worker))
    $script:LogihubDownloadProcess=Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand '+$encoded) -WindowStyle Hidden -PassThru -ErrorAction Stop
    Write-Log 'Logitech helper download started in background (pinned C54D release). Other profile actions continue.'
    if(-not $script:LogihubDownloadTimer){
        $script:LogihubDownloadTimer=New-Object System.Windows.Forms.Timer
        $script:LogihubDownloadTimer.Interval=400
        $script:LogihubDownloadTimer.Add_Tick({
            if(-not $script:LogihubDownloadProcess){return}
            if(-not $script:LogihubDownloadProcess.HasExited){return}
            $script:LogihubDownloadTimer.Stop()
            $statusPath=$script:LogihubDownloadStatus
            $statusText=''
            try {
                if(Test-Path -LiteralPath $statusPath -PathType Leaf){$statusText=[IO.File]::ReadAllText($statusPath)}
                if($statusText -ne 'OK'){throw ('Logitech download failed: '+$(if($statusText){$statusText}else{'worker exited without completion status'}))}
                [void](Get-LogihubExecutable)
                Write-Log 'Verified Logitech helper downloaded successfully.'
                if($null -ne $script:LogihubRequestedDPI){
                    $dpi=[int]$script:LogihubRequestedDPI
                    $script:LogihubRequestedDPI=$null
                    $run=$script:LogihubRequestedRun
                    if(-not $run){$run='Manual DPI'}
                    Start-StepScope -Run $run -Step 'Logitech live DPI'
                    try{Set-LogitechLiveDPI -DPI $dpi}catch{Write-Log ('Delayed Logitech DPI failed: '+$_.Exception.Message) 'ERROR'}
                    finally{Complete-StepScope -Detail 'Async DPI command finished; review read-back verification.';Write-RunSummary -Run $run}
                }
            } catch {
                Write-Log $_.Exception.Message 'ERROR'
                if($null -ne $script:LogihubRequestedDPI){
                    $run=$script:LogihubRequestedRun
                    if(-not $run){$run='Manual DPI'}
                    Set-StepResult -Run $run -Step 'Logitech live DPI' -Status FAILED -Detail $_.Exception.Message
                    Write-RunSummary -Run $run
                }
                $script:LogihubRequestedDPI=$null
            } finally {
                Remove-Item -LiteralPath $statusPath -Force -ErrorAction SilentlyContinue
                $script:LogihubDownloadProcess.Dispose()
                $script:LogihubDownloadProcess=$null
            }
        })
    }
    $script:LogihubDownloadTimer.Start()
}
function Request-LogitechLiveDPI {
    param([int]$DPI=800)
    Assert-LogitechDPI $DPI
    # Latest-click-wins: a later profile changes the target DPI, not the download.
    $script:LogihubRequestedDPI=$DPI
    $script:LogihubRequestedRun=if($script:StepScope){$script:StepScope.Run}else{'Manual DPI'}
    # A cached upstream/older executable must never run; download the pinned fork
    # automatically, keeping the last requested DPI until the download is verified.
    $cacheReady=$false
    if(Test-Path -LiteralPath $script:LogihubExe -PathType Leaf){
        try {
            [void](Get-LogihubExecutable)
            $cacheReady=$true
        } catch {
            if($_.Exception.Message -notlike 'Cached logihub.exe checksum mismatch*'){
                $script:LogihubRequestedDPI=$null
                throw ('Logitech helper cache verification failed: '+$_.Exception.Message)
            }
            Write-Log 'Cached Logitech helper is outdated or fails SHA-256; downloading the pinned C54D release. Old helper will not be executed.' 'WARN'
        }
    }
    if($cacheReady){
        $dpi=[int]$script:LogihubRequestedDPI
        $script:LogihubRequestedDPI=$null
        Write-Log 'Logitech helper cache verified successfully.'
        # Device discovery and DPI errors must propagate separately to the step result.
        Set-LogitechLiveDPI -DPI $dpi
        return
    }
    if($script:LogihubDownloadProcess){
        Write-Log ('Logitech download pending; latest requested live DPI = '+$DPI)
        return
    }
    Start-LogihubAsyncDownload
}

function Invoke-Logihub {
    param([string[]]$Arguments)
    $exe=Get-LogihubExecutable
    $output=(& $exe @Arguments 2>&1 | Out-String).Trim()
    $code=$LASTEXITCODE
    if($output){Write-Log ('logihub '+($Arguments -join ' ')+': '+$output)}
    if($code -ne 0){throw ('logihub exited '+$code+': '+$output)}
    return $output
}

# Better-logihub exposes machine-readable device records with explicit indexes.
# Only the original PRO X SUPERLIGHT and PRO X SUPERLIGHT 2 are supported here.
function Select-SuperlightDevice {
    param([Parameter(Mandatory=$true)][string]$Json)
    try {$rows=@(ConvertFrom-Json -InputObject $Json -ErrorAction Stop | ForEach-Object {$_})}
    catch{throw ('Could not parse Logitech device list as JSON: '+$_.Exception.Message)}
    $matches=New-Object 'System.Collections.Generic.List[object]'
    foreach($row in $rows){
        if($null -eq $row){continue}
        $model=[string]$row.model_id
        $name=[string]$row.display_name
        # Trust the CLI model_id, not a receiver name containing 'Superlight'.
        if($model -notin @('pro_x_wireless_mouse','pro_x_2_wireless_mouse')){continue}
        if(([string]$row.type) -match '^(receiver)$'){continue}
        if(([string]$row.status) -ne 'connected'){continue} # paired but powered-off mice report 'unreachable: ...'
        $idx=0
        if(-not [int]::TryParse(([string]$row.index),[ref]$idx) -or $idx -lt 0){continue}
        $matches.Add([pscustomobject]@{Index=$idx;Model=$model;Name=$name})
    }
    if($matches.Count -eq 0){throw 'No supported PRO X SUPERLIGHT 1 or 2 detected. Check mouse/receiver and connection.'}
    if($matches.Count -gt 1){
        $names=($matches | ForEach-Object { $_.Name+' (device '+$_.Index+')' }) -join ', '
        throw ('Multiple Superlight mice detected: '+$names+'. DPI was NOT changed; disconnect other mouse before retrying.')
    }
    return $matches[0]
}
function Get-SelectedSuperlight {
    $json=Invoke-Logihub -Arguments @('--json','list')
    $selected=Select-SuperlightDevice -Json $json
    Write-Log ('Logitech target: '+$selected.Name+' (device '+$selected.Index+')')
    return $selected
}

function Set-LogitechLiveDPI {
    param([int]$DPI=800)
    Assert-LogitechDPI $DPI
    if(@(Get-Process -Name lghub,lghub_agent -ErrorAction SilentlyContinue).Count -gt 0){
        Write-Log 'G HUB detected; leaving it running. It may override the DPI later.' 'WARN'
    }
    $target=Get-SelectedSuperlight
    [void](Invoke-Logihub -Arguments @('dpi','set',([string]$DPI),'--device',([string]$target.Index)))
    $read=Invoke-Logihub -Arguments @('dpi','get','--device',([string]$target.Index))
    $deviceIndex=[int]$target.Index
    $readValue=$null
    foreach($line in @($read -split '\r?\n' | Where-Object {$_ -match '\S'})){
        if($line -match ('^\s*'+$deviceIndex+'\s+.+?\s+(\d+)\s*$')){
            $readValue=[int]$Matches[1]
            break
        }
    }
    if($null -eq $readValue){throw ('Logitech DPI read-back cannot be parsed for device '+$deviceIndex+': '+$read)}
    if($readValue -ne $DPI){throw ('Logitech DPI verification failed: requested '+$DPI+' but mouse reports '+$readValue)}
    Write-Log ('Logitech live DPI verified: requested '+$DPI+'; read-back '+$readValue+' (device '+$deviceIndex+').')
}
function Set-LogitechOnboardDPI {
    param([int]$DPI=800)
    Assert-LogitechDPI $DPI
    $answer=[System.Windows.Forms.MessageBox]::Show(
        ('This WRITES mouse onboard memory (survives Deep Freeze/reboot).'+[Environment]::NewLine+
        'Back up existing memory, set DPI '+$DPI+' and enable onboard mode?'),
        'Confirm Onboard DPI Write','YesNo','Warning')
    if($answer -ne [System.Windows.Forms.DialogResult]::Yes){Write-Log 'Onboard DPI cancelled.';return}
    $target=Get-SelectedSuperlight
    $folder=Join-Path $env:LOCALAPPDATA 'CafeLauncher\logihub\onboard-backups'
    [void](New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop)
    $backup=Join-Path $folder ('onboard-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.bin')
    [void](Invoke-Logihub -Arguments @('onboard','dump','--out',$backup,'--device',([string]$target.Index)))
    if(-not (Test-Path -LiteralPath $backup -PathType Leaf) -or (Get-Item -LiteralPath $backup).Length -le 0){
        throw 'Onboard backup is missing/empty; no memory changes attempted.'
    }
    Write-Log ('Onboard backup: '+$backup)
    [void](Invoke-Logihub -Arguments @('onboard','set-dpi',([string]$DPI),'--default','1','--shift',([string]$DPI),'--device',([string]$target.Index)))
    [void](Invoke-Logihub -Arguments @('onboard','mode','set','on','--device',([string]$target.Index)))
    Write-Log ('Onboard DPI '+$DPI+' command completed. Backup: '+$backup)
}
# Parse custom DPI text; reject empty, decimal, negative and out-of-range values.
function ConvertTo-ManualLogitechDPI {
    param([AllowEmptyString()][string]$Text)
    $raw=$Text.Trim()
    if($raw -notmatch '^[0-9]{1,5}$'){
        throw 'Type a whole-number DPI between 100 and 25600.'
    }
    $dpi=[int]::Parse($raw,[Globalization.CultureInfo]::InvariantCulture)
    Assert-LogitechDPI -DPI $dpi
    return $dpi
}
function Invoke-LogitechDpiButton {
    param([int]$DPI=800,[switch]$Onboard)
    try {
        Assert-LogitechDPI -DPI $DPI
        if($Onboard){Set-LogitechOnboardDPI -DPI $DPI}
        else{Request-LogitechLiveDPI -DPI $DPI}
    } catch {
        Write-Log ('Logitech DPI failed: '+$_.Exception.Message) 'ERROR'
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Logitech DPI','OK','Warning')
    }
}

function Invoke-GamingProfile {
    param([Parameter(Mandatory=$true)][string]$ProfileName)
    if (-not $script:GamingProfiles.Contains($ProfileName)) {
        Write-Log "Unknown gaming profile: $ProfileName" 'ERROR'
        return
    }
    $script:ActiveRunName=$ProfileName
    $script:StepResults.Clear()
    Refresh-ProfileFromGitHub -ProfileName $ProfileName
    $profile = $script:GamingProfiles[$ProfileName]
    Write-Log "$ProfileName full routine started: mouse, NVIDIA, CS2 config, applications."

    $steps = @(
        @{ Name = 'Windows mouse speed/acceleration'; Action = {
            Apply-ProfileMouse -ProfileName $ProfileName -PointerSpeed ([int]$profile.PointerSpeed) -DisableAcceleration ([bool]$profile.DisableAcceleration) -SkipPointerOptions
        } }
    )
    if ($profile.ApplyNvidia) {
        $steps += @{ Name = 'NVIDIA settings'; Action = { Apply-NvidiaGamingSettings -Width ([int]$profile.Width) -Height ([int]$profile.Height) -RefreshHz ([int]$profile.RefreshHz) -Vibrance ([int]$profile.Vibrance) } }
    }
    $profileCfgName = [string]$profile.ConfigFile
    if (-not [string]::IsNullOrWhiteSpace($profileCfgName)) {
        $profileCfgUrl = [string]$profile.CfgDownloadUrl
        if ($ProfileName -eq 'FabMode' -and [string]::IsNullOrWhiteSpace($profileCfgUrl)) {
            $profileCfgUrl = $script:FabCfgCloudUrl
        }
        # Profile Apply installs its CFG without editing any Steam launch options.
        $steps += @{ Name = "Install CS2 $profileCfgName"; Action = {
            [void](Install-AtCfg -Silent -CfgName $profileCfgName -DownloadUrl $profileCfgUrl -CloudPreferred:([bool]$profileCfgUrl) -CS2Sensitivity ([string]$profile.CS2Sensitivity))
        } }
    }
    if ($profile.LaunchApps) {
        $steps += @{ Name = 'Launch All (including Mouse Pointer Options)'; Action = { Launch-All } }
    }
    # Live DPI LAST: Launch All may start Logitech G HUB, which can otherwise
    # overwrite a DPI set early in the profile routine. Never write onboard here.
    $steps += @{ Name = 'Logitech live DPI'; Action = { Request-LogitechLiveDPI -DPI ([int]$profile.LogitechDPI) } }
    foreach ($step in $steps) {
        Write-Log ("$ProfileName step started: " + $step.Name)
        Start-StepScope -Run $ProfileName -Step $step.Name
        try {
            & ($step.Action)
            Write-Log ("$ProfileName step returned: " + $step.Name + ". Check logs for individual success or errors.")
        } catch {
            Write-Log ("$ProfileName step failed: " + $step.Name + ": " + $_.Exception.Message) 'ERROR'
        } finally {
            if($step.Name -eq 'Logitech live DPI' -and $script:LogihubDownloadProcess){
                $script:StepScope=$null
                Set-StepResult -Run $ProfileName -Step $step.Name -Status PENDING -Detail 'Helper downloading; live DPI not yet applied.'
            }else{Complete-StepScope}
        }
    }
    Write-RunSummary -Run $ProfileName
    Write-Log "$ProfileName full routine finished. Review logs for individual results."
}

# The separate Play + Exec action launches CS2 with a one-time +exec argument.
# No writes to Steam userdata/config/localconfig.vdf and no Steam restart.
function Get-CS2SteamLaunchArguments {
    param([Parameter(Mandatory=$true)][string]$CfgName)
    if ($CfgName -notmatch '^[A-Za-z0-9_-]+\.cfg$') { throw 'Invalid CFG filename for CS2.' }
    return @('-applaunch', '730', '+exec', $CfgName)
}

function Start-CS2WithProfileCfg {
    param([Parameter(Mandatory=$true)][string]$ProfileName)
    if (-not $script:GamingProfiles.Contains($ProfileName)) { throw "Unknown CS2 profile: $ProfileName" }
    if (Get-Process -Name 'cs2' -ErrorAction SilentlyContinue) {
        $runningCfg = [string]$script:GamingProfiles[$ProfileName].ConfigFile
        Write-Log "$ProfileName Play + Exec skipped; CS2 is already running. Use developer console: exec $runningCfg" 'WARN'
        [System.Windows.Forms.MessageBox]::Show(
            "CS2 is already running. Steam launch arguments work only when starting the game." +
            [Environment]::NewLine + [Environment]::NewLine +
            "In CS2, open the developer console and type: exec $runningCfg" +
            [Environment]::NewLine + "Or close CS2 and click Play + Exec again.",
            'CS2 Already Running', 'OK', 'Information'
        ) | Out-Null
        return
    }
    Refresh-ProfileFromGitHub -ProfileName $ProfileName
    $profile = $script:GamingProfiles[$ProfileName]
    $cfgName = [string]$profile.ConfigFile
    if ($cfgName -notmatch '^[A-Za-z0-9_-]+\.cfg$') { throw "Invalid CFG filename for $ProfileName." }
    $url = [string]$profile.CfgDownloadUrl
    if ($ProfileName -eq 'FabMode' -and [string]::IsNullOrWhiteSpace($url)) {
        $url = $script:FabCfgCloudUrl
    }
    Write-Log "$ProfileName Play + Exec: installing $cfgName before starting CS2."
    $installed = Install-AtCfg -Silent -CfgName $cfgName -DownloadUrl $url -CloudPreferred:([bool]$url) -CS2Sensitivity ([string]$profile.CS2Sensitivity)
    if ($installed -ne $true) {
        Write-Log "$ProfileName Play + Exec cancelled: $cfgName installation did not succeed." 'ERROR'
        [System.Windows.Forms.MessageBox]::Show(
            "Unable to install $cfgName. CS2 was not started. Check LIVE LOGS.",
            'CS2 CFG Installation Failed', 'OK', 'Warning'
        ) | Out-Null
        return
    }
    $steamExe = Get-SteamExecutable
    if (-not $steamExe) {
        Write-Log 'Steam was not detected. CFG installed, but CS2 not launched.' 'ERROR'
        [System.Windows.Forms.MessageBox]::Show('Steam not found. CFG installed but CS2 was not launched.', 'Steam Not Found', 'OK', 'Warning') | Out-Null
        return
    }
    $args = @(Get-CS2SteamLaunchArguments -CfgName $cfgName)
    Start-Process -FilePath $steamExe -ArgumentList $args -ErrorAction Stop
    Write-Log "$ProfileName requested CS2 launch via Steam: -applaunch 730 +exec $cfgName. Persistent Steam launch options unchanged."
}

# Independent CS2 graphics module; loaded ONLY when Apply Graphics is clicked.
# Strict hash pin prevents executing unreviewed modified remote module code.
function Invoke-GraphicsOnly {
    param([Parameter(Mandatory=$true)][string]$ModeName)
    Start-StepScope -Run ('Graphics '+$ModeName) -Step 'Apply Graphics'
    try {
    $expected='f6dbb6d21ceeecc32166c73a14e0d8d2e9066971'
    $source='https://raw.githubusercontent.com/fabjoncela/Cs-script/main/graphics/ApplyGraphics.ps1'
    $cache=Join-Path $env:LOCALAPPDATA 'CafeLauncher\graphics-module.ps1'
    $parent=Split-Path -Parent $cache
    if(-not (Test-Path -LiteralPath $parent)){[void](New-Item -Path $parent -ItemType Directory -Force)}
    $temp=Join-Path $env:TEMP ('CafeLauncher-graphics-module-'+[guid]::NewGuid().ToString('N')+'.ps1')
    try{
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $source -OutFile $temp -UseBasicParsing -TimeoutSec 12 -ErrorAction Stop
        $bytes=[IO.File]::ReadAllBytes($temp)
        if((Get-GitBlobSha -Bytes $bytes) -ne $expected){throw 'Cloud graphics module SHA does not match the reviewed launcher version.'}
        $lines=[IO.File]::ReadAllLines($temp)
        $tokens=$null;$errors=$null
        [void][System.Management.Automation.Language.Parser]::ParseFile($temp,[ref]$tokens,[ref]$errors)
        if(@($errors).Count){throw 'Downloaded graphics module has invalid PowerShell syntax.'}
        Copy-Item -LiteralPath $temp -Destination $cache -Force -ErrorAction Stop
    }catch{
        Write-Log ('Could not download graphics module: '+$_.Exception.Message) 'WARN'
    }finally{Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
    if(-not (Test-Path -LiteralPath $cache -PathType Leaf)){throw 'Graphics module unavailable. Connect to GitHub and retry.'}
    if((Get-GitBlobSha -Bytes ([IO.File]::ReadAllBytes($cache))) -ne $expected){
        throw 'Cached graphics module failed signature/hash validation. Graphics not applied.'
    }
    . $cache
    Apply-CS2ModeGraphics -ModeName $ModeName
    } catch {
        Write-Log ('Graphics module could not complete: '+$_.Exception.Message) 'ERROR'
    } finally {
        Complete-StepScope -Detail 'Graphics action finished; inspect applied/skipped video keys and backup logs.'
        Write-RunSummary -Run ('Graphics '+$ModeName)
    }
}

# Backward-compatible entry point.
function Invoke-FabModeFull { Invoke-GamingProfile -ProfileName 'FabMode' }

# Main window
$form = New-Object System.Windows.Forms.Form
$form.Text = "Cafe Launcher"
$form.Size = New-Object System.Drawing.Size(800,1050)
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
        [switch]$Primary,
        [string]$EditProfile = ''
    )

    $col = $Index % 3
    $row = [Math]::Floor($Index / 3)
    $x = 25 + ($col * 250)
    $y = 125 + ($row * 88)

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($x,$y)
    if ($EditProfile) {
        # Split the profile tile into Apply and Play + Exec buttons.
        $button.Size = New-Object System.Drawing.Size(88,46)
    } else {
        $button.Size = New-Object System.Drawing.Size(235,70)
    }
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 0
    if ($Primary) {
        $button.BackColor = $BLUE
    } else {
        $button.BackColor = $PANEL
    }
    $button.ForeColor = $WHITE
    $button.Font = New-Object System.Drawing.Font("Segoe UI",$(if($EditProfile){9}else{10}),[System.Drawing.FontStyle]::Bold)
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
    if ($EditProfile) {
        $selectedProfile = $EditProfile
        $play = New-Object System.Windows.Forms.Button
        $play.Text = 'Play + Exec'
        $play.Location = New-Object System.Drawing.Point(($x + 92), $y)
        $play.Size = New-Object System.Drawing.Size(70,46)
        $play.FlatStyle = 'Flat'
        $play.FlatAppearance.BorderSize = 0
        $play.BackColor = [System.Drawing.Color]::FromArgb(38,132,102)
        $play.ForeColor = $WHITE
        $play.Font = New-Object System.Drawing.Font('Segoe UI',8,[System.Drawing.FontStyle]::Bold)
        $play.Cursor = [System.Windows.Forms.Cursors]::Hand
        $play.Add_Click({
            Write-Log "Clicked: Play + Exec $selectedProfile"
            try { Start-CS2WithProfileCfg -ProfileName $selectedProfile }
            catch {
                Write-Log ("Play + Exec failed for " + $selectedProfile + ": " + $_.Exception.Message + "; " + $_.ScriptStackTrace) 'ERROR'
                [System.Windows.Forms.MessageBox]::Show(
                    ("Unable to launch CS2 for " + $selectedProfile + ": " + $_.Exception.Message),
                    'CS2 Launch Failed', 'OK', 'Error'
                ) | Out-Null
            }
        }.GetNewClosure())
        $form.Controls.Add($play)

        # Independent third button: no graphics writes from the main mode,
        # Play + Exec, Launch All, or background startup routines.
        $graphics = New-Object System.Windows.Forms.Button
        $graphics.Text = 'Apply Graphics'
        $graphics.Location = New-Object System.Drawing.Point(($x + 166), $y)
        $graphics.Size = New-Object System.Drawing.Size(69,46)
        $graphics.FlatStyle = 'Flat'
        $graphics.FlatAppearance.BorderSize = 0
        $graphics.BackColor = [System.Drawing.Color]::FromArgb(77,72,125)
        $graphics.ForeColor = $WHITE
        $graphics.Font = New-Object System.Drawing.Font('Segoe UI',7,[System.Drawing.FontStyle]::Bold)
        $graphics.Cursor = [System.Windows.Forms.Cursors]::Hand
        $graphics.Add_Click({
            try { Invoke-GraphicsOnly -ModeName $selectedProfile }
            catch {
                Write-Log ('Graphics button failed for '+$selectedProfile+': '+$_.Exception.Message) 'ERROR'
                [void][System.Windows.Forms.MessageBox]::Show(
                    ('Unable to apply '+$selectedProfile+' graphics: '+$_.Exception.Message),
                    'CS2 Graphics','OK','Warning')
            }
        }.GetNewClosure())
        $form.Controls.Add($graphics)

        $edit = New-Object System.Windows.Forms.Button
        $edit.Text = "Edit $EditProfile settings"
        $edit.Location = [System.Drawing.Point]::new($x, ($y + 48))
        $edit.Size = New-Object System.Drawing.Size(235,22)
        $edit.Font = New-Object System.Drawing.Font('Segoe UI',8)
        $edit.FlatStyle = 'Flat'
        $edit.FlatAppearance.BorderSize = 0
        $edit.BackColor = [System.Drawing.Color]::FromArgb(58,67,83)
        $edit.ForeColor = $WHITE
        $edit.Cursor = [System.Windows.Forms.Cursors]::Hand
        $selectedProfile = $EditProfile
        $edit.Add_Click({
            Write-Log "Clicked: Edit $selectedProfile settings"
            try { Show-ProfileEditor -ProfileName $selectedProfile }
            catch { Write-Log "Profile editor failed: $($_.Exception.Message)" 'ERROR' }
        }.GetNewClosure())
        $form.Controls.Add($edit)
    }
}

New-Tile "LAUNCH ALL" 0 { Launch-All } -Primary
New-Tile "Steam" 1 { Start-DetectedSteam }
New-Tile "FACEIT Anti-Cheat" 2 {
    Launch-App -Name "FACEIT Anti-Cheat" -Paths @(
        "$env:ProgramFiles\FACEIT AC\faceitclient.exe",
        "${env:ProgramFiles(x86)}\FACEIT AC\faceitclient.exe"
    )
}
New-Tile "FACEIT Matchmaking" 3 { Open-FaceitMatchmaking }
New-Tile "Spotify" 4 { Open-Spotify }
New-Tile "Logitech G HUB" 5 { Open-GHub }

# Five editable gaming profiles, all using the same shared routine.
New-Tile "FabMode" 6 { Invoke-GamingProfile -ProfileName 'FabMode' } -Primary -EditProfile 'FabMode'
New-Tile "ArliMode" 7 { Invoke-GamingProfile -ProfileName 'ArliMode' } -Primary -EditProfile 'ArliMode'
New-Tile "BrileMode" 8 { Invoke-GamingProfile -ProfileName 'BrileMode' } -Primary -EditProfile 'BrileMode'
New-Tile "ArmlMode" 9 { Invoke-GamingProfile -ProfileName 'ArmlMode' } -Primary -EditProfile 'ArmlMode'
New-Tile "OliMode" 10 { Invoke-GamingProfile -ProfileName 'OliMode' } -Primary -EditProfile 'OliMode'

New-Tile "Mouse Pointer Options" 11 { Open-MousePointerOptions }
New-Tile "NVIDIA Control Panel" 12 { Open-NvidiaControlPanel }
New-Tile "Apply NVIDIA Settings" 13 { Apply-NvidiaGamingSettings } -Primary
New-Tile "Install CS2 fab.cfg" 14 {
    [void](Install-AtCfg -CfgName 'fab.cfg' -DownloadUrl $script:FabCfgCloudUrl -CloudPreferred)
} -Primary
New-Tile "Detect PC" 15 { Show-PCDiagnostics }
New-Tile "Check for Updates" 16 { Check-CafeLauncherUpdates -Manual }
New-Tile "Exit" 17 { $form.Close() }
# Editable DPI input replaces the fixed-800 live button in tile 18.
$manualDpiPanel=New-Object System.Windows.Forms.Panel
$manualDpiPanel.Location=New-Object System.Drawing.Point(25,653)
$manualDpiPanel.Size=New-Object System.Drawing.Size(235,70)
$manualDpiPanel.BackColor=$PANEL
$form.Controls.Add($manualDpiPanel)

$manualDpiLabel=New-Object System.Windows.Forms.Label
$manualDpiLabel.Text='DPI (100 - 25600)'
$manualDpiLabel.Location=New-Object System.Drawing.Point(10,7)
$manualDpiLabel.Size=New-Object System.Drawing.Size(108,20)
$manualDpiLabel.Font=New-Object System.Drawing.Font('Segoe UI',8)
$manualDpiLabel.ForeColor=$WHITE
$manualDpiPanel.Controls.Add($manualDpiLabel)

$script:ManualDpiInput=New-Object System.Windows.Forms.TextBox
$script:ManualDpiInput.Text='800'
$script:ManualDpiInput.Location=New-Object System.Drawing.Point(10,32)
$script:ManualDpiInput.Size=New-Object System.Drawing.Size(105,26)
$script:ManualDpiInput.MaxLength=5
$script:ManualDpiInput.Font=New-Object System.Drawing.Font('Segoe UI',11)
$script:ManualDpiInput.ForeColor=$WHITE
$script:ManualDpiInput.BackColor=$BG
$manualDpiPanel.Controls.Add($script:ManualDpiInput)

$script:ManualDpiChangeButton=New-Object System.Windows.Forms.Button
$script:ManualDpiChangeButton.Text='Change DPI'
$script:ManualDpiChangeButton.Location=New-Object System.Drawing.Point(121,10)
$script:ManualDpiChangeButton.Size=New-Object System.Drawing.Size(105,50)
$script:ManualDpiChangeButton.Font=New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
$script:ManualDpiChangeButton.FlatStyle='Flat'
$script:ManualDpiChangeButton.FlatAppearance.BorderSize=0
$script:ManualDpiChangeButton.BackColor=$BLUE
$script:ManualDpiChangeButton.ForeColor=$WHITE
$script:ManualDpiChangeButton.Cursor=[System.Windows.Forms.Cursors]::Hand
$script:ManualDpiChangeButton.Add_Click({
    try {
        $dpi=ConvertTo-ManualLogitechDPI -Text $script:ManualDpiInput.Text
        Write-Log ('Clicked: Change DPI ('+$dpi+')')
        Invoke-LogitechDpiButton -DPI $dpi
    } catch {
        Write-Log ('Invalid custom Logitech DPI: '+$_.Exception.Message) 'ERROR'
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Change DPI','OK','Warning')
        $script:ManualDpiInput.Focus()
        $script:ManualDpiInput.SelectAll()
    }
})
$manualDpiPanel.Controls.Add($script:ManualDpiChangeButton)
$script:ManualDpiInput.Add_KeyDown({
    param($sender,$eventArgs)
    if($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Enter){
        $eventArgs.SuppressKeyPress=$true
        $script:ManualDpiChangeButton.PerformClick()
    }
})
# New-Tile "Set DPI 800 (Onboard)" 19 { Invoke-LogitechDpiButton -Onboard } # disabled until hardware tested

# Live diagnostic log panel (visible only while the launcher is open)
$logTitle = New-Object System.Windows.Forms.Label
$logTitle.Text = "LIVE LOGS  |  Errors and button activity"
$logTitle.Location = New-Object System.Drawing.Point(28,755)
$logTitle.Size = New-Object System.Drawing.Size(500,22)
$logTitle.Font = New-Object System.Drawing.Font("Segoe UI",9,[System.Drawing.FontStyle]::Bold)
$logTitle.ForeColor = $WHITE
$form.Controls.Add($logTitle)

$clearLogs = New-Object System.Windows.Forms.Button
$clearLogs.Text = "Clear Logs"
$clearLogs.Location = New-Object System.Drawing.Point(670,751)
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
$script:LogBox.Location = New-Object System.Drawing.Point(28,782)
$script:LogBox.Size = New-Object System.Drawing.Size(742,168)
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
$footer.Location = New-Object System.Drawing.Point(28,970)
$footer.Size = New-Object System.Drawing.Size(740,22)
$footer.Font = New-Object System.Drawing.Font("Segoe UI",8)
$footer.ForeColor = $MUTED
$form.Controls.Add($footer)

$form.Add_FormClosed({
    if($script:LogihubDownloadTimer){$script:LogihubDownloadTimer.Stop();$script:LogihubDownloadTimer.Dispose();$script:LogihubDownloadTimer=$null}
    $script:LogihubRequestedDPI=$null
    if ($script:ColorWatchTimer) {
        try { $script:ColorWatchTimer.Stop(); $script:ColorWatchTimer.Dispose() } catch {}
        Write-Log "Color Watch stopped because the launcher closed."
    }
})
# On first display, automatically inventory the machine and check GitHub for
# an update. One-shot timer lets Windows render the UI before network access.
$startupTimer = New-Object System.Windows.Forms.Timer
$startupTimer.Interval=350
$startupTimer.Add_Tick({
    $startupTimer.Stop()
    $startupTimer.Dispose()
    try {
        Write-Log 'Automatic startup inventory:'
        $summary = Get-PCDiagnostics
        foreach ($line in ($summary -split '\r?\n')) { if ($line) { Write-Log ('PC: ' + $line) } }
    } catch { Write-Log "Startup inventory failed: $($_.Exception.Message)" 'WARN' }
    Check-CafeLauncherUpdates
})
$form.Add_Shown({ $startupTimer.Start() })
[void]$form.ShowDialog()
