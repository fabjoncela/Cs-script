@echo off
set "CAFE_SCRIPT=%~f0"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command "try { $l=[IO.File]::ReadAllLines($env:CAFE_SCRIPT); $i=[Array]::IndexOf($l,'# POWERSHELL_GUI'); if($i -lt 0){throw 'PowerShell script marker not found'}; $code=($l[($i+1)..($l.Length-1)] -join [Environment]::NewLine); $t=$null; $er=$null; [void][System.Management.Automation.Language.Parser]::ParseInput($code,[ref]$t,[ref]$er); if($er.Count -gt 0){throw ('PowerShell syntax: '+$er[0].ToString())}; Invoke-Expression $code } catch { $msg=$_.ToString()+' '+$_.ScriptStackTrace; try { [IO.File]::WriteAllText((Join-Path $env:TEMP 'CafeLauncher-startup-error.log'),$msg) } catch {}; try { Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show($msg,'CafeLauncher Startup Error') } catch {} }"
exit /b

# POWERSHELL_GUI
# CAFE_RELEASE=2026.10.14.34

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Capture the version represented by this process at startup. The BAT on disk
# can be replaced while its already-open PowerShell UI is still running.
$script:LauncherRunningRelease='unknown'
try{
    $startupSource=[string]$env:CAFE_SCRIPT
    if(-not [string]::IsNullOrWhiteSpace($startupSource) -and (Test-Path -LiteralPath $startupSource -PathType Leaf)){
        $startupVersionMatch=[regex]::Match([IO.File]::ReadAllText($startupSource),'(?m)^# CAFE_RELEASE=(\d{4}\.\d{1,2}\.\d{1,2}\.\d+)\s*$')
        if($startupVersionMatch.Success){$script:LauncherRunningRelease=$startupVersionMatch.Groups[1].Value}
    }
}catch{}

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
    if($script:StatusLine -and -not $script:StatusLine.IsDisposed -and
        $Level -in @('ERROR','WARN','RESULT','SUMMARY')){
        try {
            $messageForStatus=$Message
            if($script:StatusLine.InvokeRequired){
                [void]$script:StatusLine.BeginInvoke([Action]{
                    $script:StatusLine.Text=$messageForStatus
                })
            }else{
                $script:StatusLine.Text=$messageForStatus
                $script:StatusLine.ForeColor=if($Level -eq 'ERROR'){
                    [System.Drawing.Color]::FromArgb(255,128,128)
                }elseif($Level -eq 'WARN'){
                    [System.Drawing.Color]::FromArgb(255,190,105)
                }else{$MUTED}
            }
        }catch{}
    }
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

# Track the primary REST quota from responses the launcher already receives.
# This deliberately makes no additional request to GitHub.
$script:GitHubRateLimitSnapshot=$null
$script:GitHubRateLimitLabel=$null
function Set-CafeGitHubRateLimitDisplay {
    param([string]$Remaining,[string]$Limit)
    $remainingValue=0;$limitValue=0
    if(-not [int]::TryParse($Remaining,[ref]$remainingValue) -or
       -not [int]::TryParse($Limit,[ref]$limitValue) -or $limitValue -le 0 -or
       $remainingValue -lt 0 -or $remainingValue -gt $limitValue){return}
    $snapshot=[pscustomobject]@{Remaining=$remainingValue;Limit=$limitValue;CheckedAt=[DateTime]::Now}
    $script:GitHubRateLimitSnapshot=$snapshot
    if(-not $script:GitHubRateLimitLabel -or $script:GitHubRateLimitLabel.IsDisposed){return}
    $labelText=("GitHub API: {0}/{1} left`nLast checked {2}" -f $remainingValue,$limitValue,$snapshot.CheckedAt.ToString('HH:mm:ss'))
    try{
        $script:GitHubRateLimitLabel.Text=$labelText
        $script:GitHubRateLimitLabel.ForeColor=if($remainingValue -le 5){[System.Drawing.Color]::FromArgb(255,150,120)}else{$MUTED}
    }catch{}
}
function Update-CafeGitHubRateLimitFromHeaders {
    param($Headers)
    if(-not $Headers){return}
    try{
        Set-CafeGitHubRateLimitDisplay -Remaining ([string]$Headers['X-RateLimit-Remaining']) `
            -Limit ([string]$Headers['X-RateLimit-Limit'])
    }catch{}
}
function Invoke-CafeGitHubRestMethod {
    param([Parameter(Mandatory=$true)][string]$Uri,[string]$Method='Get',
          [hashtable]$Headers=@{},[int]$TimeoutSec=30,[int]$MaximumRedirection=5,
          [string]$ContentType,[object]$Body)
    $request=@{
        Uri=$Uri;Method=$Method;Headers=$Headers;TimeoutSec=$TimeoutSec
        MaximumRedirection=$MaximumRedirection;UseBasicParsing=$true;ErrorAction='Stop'
    }
    if($ContentType){$request.ContentType=$ContentType}
    if($PSBoundParameters.ContainsKey('Body')){$request.Body=$Body}
    try{$response=Invoke-WebRequest @request}
    catch{
        if($_.Exception.Response){Update-CafeGitHubRateLimitFromHeaders -Headers $_.Exception.Response.Headers}
        throw
    }
    Update-CafeGitHubRateLimitFromHeaders -Headers $response.Headers
    if([string]::IsNullOrWhiteSpace([string]$response.Content)){return $null}
    try{return ($response.Content | ConvertFrom-Json -ErrorAction Stop)}catch{return [string]$response.Content}
}

# Result records are separate from diagnostic INFO/WARN/ERROR logs.
$script:StepResults=New-Object 'System.Collections.Generic.List[object]'
$script:RunOutcomes=New-Object 'System.Collections.Generic.List[object]'
$script:StepScope=$null
$script:StepScopeError=$false
$script:StepScopeWarning=$false
$script:ActiveRunName=''
function Set-RunOutcome {
    param([string]$Run,[string]$Setting,[string]$Requested,[string]$Target,
          [ValidateSet('APPLIED','FALLBACK','SKIPPED','FAILED','PENDING')][string]$Status,
          [string]$Actual='',[string]$Detail='')
    if([string]::IsNullOrWhiteSpace($Run)){ $Run='Manual action' }
    foreach($old in @($script:RunOutcomes | Where-Object {$_.Run -eq $Run -and $_.Setting -eq $Setting})){
        [void]$script:RunOutcomes.Remove($old)
    }
    $script:RunOutcomes.Add([pscustomobject]@{
        Run=$Run;Setting=$Setting;Requested=$Requested;Target=$Target;Status=$Status;Actual=$Actual;Detail=$Detail
    })
}
function Clear-RunOutcomes {
    param([string]$Run)
    foreach($old in @($script:RunOutcomes | Where-Object {$_.Run -eq $Run})){
        [void]$script:RunOutcomes.Remove($old)
    }
}
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
function Get-StepRecoveryAdvice {
    param([string]$Step,[string]$Status)
    if($Status -eq 'PENDING'){
        return 'This action is still running. Keep the launcher open, allow the helper download if prompted, and check LIVE LOGS for completion.'
    }
    if($Status -eq 'PARTIAL'){
        return 'Open LIVE LOGS and review the warnings for this step; verify the affected setting before retrying the profile.'
    }
    switch -Wildcard ($Step) {
        'Windows mouse speed/acceleration' { return 'Check LIVE LOGS for Windows read-back or permission errors, then verify pointer speed and acceleration in Windows Mouse settings.' }
        'NVIDIA settings' { return 'Check LIVE LOGS for the failed display, vibrance, or scaling operation; confirm the NVIDIA driver and requested display mode, then retry.' }
        'Install CS2 *' { return 'Check internet access and the CS2 cfg folder under the active Steam account; confirm the profile CFG URL or local file, then retry.' }
        'Launch apps*' { return 'Check the configured application paths and whether each app is installed; fix the missing path and retry Launch Apps.' }
        'Logitech live DPI' { return 'Check LIVE LOGS for the selected mouse/dongle and DPI read-back; keep the intended mouse connected and retry after helper download finishes.' }
        'Delayed Logitech DPI verification' { return 'Keep the target mouse connected, then retry the profile and confirm the requested DPI in LIVE LOGS.' }
        default { return 'Open LIVE LOGS for the error details for this step, resolve the reported device, permission, file, or network issue, then retry the profile.' }
    }
}
function Write-RunSummary {
    param([string]$Run)
    $items=@($script:StepResults | Where-Object {$_.Run -eq $Run})
    $counts=@{}
    foreach($state in @('SUCCESS','PARTIAL','SKIPPED','FAILED','PENDING')){$counts[$state]=@($items | Where-Object {$_.Status -eq $state}).Count}
    Write-Log ($Run+': '+$counts.SUCCESS+' SUCCESS, '+$counts.PARTIAL+' PARTIAL, '+$counts.SKIPPED+' SKIPPED, '+$counts.FAILED+' FAILED, '+$counts.PENDING+' PENDING') 'SUMMARY'
    foreach($item in @($items | Where-Object {$_.Status -in @('PARTIAL','FAILED','PENDING')})){
        $level=if($item.Status -eq 'FAILED'){'ERROR'}else{'WARN'}
        $detail=if([string]::IsNullOrWhiteSpace([string]$item.Detail)){'No additional error detail was recorded.'}else{[string]$item.Detail}
        $advice=Get-StepRecoveryAdvice -Step ([string]$item.Step) -Status ([string]$item.Status)
        Write-Log ($Run+' | '+$item.Step+' | '+$item.Status+': '+$detail+' Next: '+$advice) $level
    }
    $outcomes=@($script:RunOutcomes | Where-Object {$_.Run -eq $Run})
    foreach($outcome in $outcomes){
        $parts=@($Run+' | '+$outcome.Setting+' | '+$outcome.Status)
        if($outcome.Requested){$parts+=('requested: '+$outcome.Requested)}
        if($outcome.Target){$parts+=('target: '+$outcome.Target)}
        if($outcome.Actual){$parts+=('actual: '+$outcome.Actual)}
        if($outcome.Detail){$parts+=('detail: '+$outcome.Detail)}
        Write-Log ($parts -join ' | ') 'INFO'
    }
    $outcomeCounts=@{}
    foreach($state in @('APPLIED','FALLBACK','SKIPPED','FAILED','PENDING')){
        $outcomeCounts[$state]=@($outcomes | Where-Object {$_.Status -eq $state}).Count
    }
    Write-Log ($Run+' settings: '+$outcomeCounts.APPLIED+' APPLIED, '+$outcomeCounts.FALLBACK+' FALLBACK, '+$outcomeCounts.SKIPPED+' SKIPPED, '+$outcomeCounts.FAILED+' FAILED, '+$outcomeCounts.PENDING+' PENDING') 'SUMMARY'
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
        $runName=if($script:ActiveRunName){$script:ActiveRunName}else{$ProfileName}
        Set-RunOutcome -Run $runName -Setting 'Windows pointer speed' -Requested ([string]$PointerSpeed) `
            -Target 'Current Windows user/session' -Status $(if($apiVerified){'APPLIED'}else{'FALLBACK'}) `
            -Actual $(if($speedReadOk){[string]$actualSpeed}else{'unknown'}) `
            -Detail $(if($apiVerified){'Live API read-back matched.'}else{'Registry values were verified; live pointer speed was not confirmed.'})
        Set-RunOutcome -Run $runName -Setting 'Windows mouse acceleration' -Requested $accelDescription `
            -Target 'Current Windows user/session' -Status $(if($accelOk){'APPLIED'}else{'FALLBACK'}) `
            -Actual $(if($accelOk){$accelDescription}else{'registry values saved; active value unconfirmed'}) `
            -Detail $(if($accelOk){'Windows accepted the active-session setting.'}else{'Registry values were verified, but the active-session API failed.'})

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
# Profile applies select the highest advertised refresh at the profile resolution;
# if that resolution is unavailable they keep the current resolution and maximize it.
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
        DEVMODE current=NewMode();
        if(EnumDisplaySettings(device,-1,ref current) &&
           current.dmBitsPerPel >= 24 && (current.dmDisplayFlags & 2) == 0 &&
           current.dmPelsWidth == w && current.dmPelsHeight == h &&
           (hz == 0 || current.dmDisplayFrequency == hz)) return true;
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
        bool hasCurrent = EnumDisplaySettings(device, -1, ref current);
        string active = hasCurrent
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
        if (hasCurrent && current.dmDisplayFrequency >= 24 && current.dmBitsPerPel >= 24 &&
            (current.dmDisplayFlags & 2) == 0) {
            if (current.dmPelsWidth == 1920 && current.dmPelsHeight == 1080)
                requested1080.Add(current.dmDisplayFrequency);
            atCurrent.Add(current.dmDisplayFrequency);
        }
        return device + ": active " + active + "; 1080p Hz (available modes + active): " +
            (requested1080.Count > 0 ? String.Join(", ", requested1080) : "not advertised") +
            "; current-resolution Hz (available modes + active): " +
            (atCurrent.Count > 0 ? String.Join(", ", atCurrent) : "not advertised") +
            "; modes checked=" + count + ".";
    }

    // Selects the maximum rate for one resolution from parallel mode arrays.
    public static int GetHighestRefreshAtResolution(int width, int height, int[] widths, int[] heights, int[] rates) {
        if (widths == null || heights == null || rates == null) return 0;
        int count = Math.Min(widths.Length, Math.Min(heights.Length, rates.Length));
        int highest = 0;
        for (int i=0; i<count; i++)
            if (widths[i] == width && heights[i] == height && rates[i] >= 24 && rates[i] > highest)
                highest = rates[i];
        return highest;
    }

    // Read-only: choose the highest progressive rate the active display advertises at a game resolution.
    public static int GetHighestRefreshForResolution(int width, int height) {
        const string device = @"\\.\DISPLAY1";
        if (width < 640 || height < 480) return 0;
        List<int> widths = new List<int>();
        List<int> heights = new List<int>();
        List<int> rates = new List<int>();
        DEVMODE current = NewMode();
        if (EnumDisplaySettings(device, -1, ref current) && current.dmBitsPerPel >= 24 &&
            current.dmDisplayFrequency >= 24 && current.dmDisplayFrequency <= 600 &&
            (current.dmDisplayFlags & 2) == 0) {
            widths.Add(current.dmPelsWidth); heights.Add(current.dmPelsHeight); rates.Add(current.dmDisplayFrequency);
        }
        for (int i=0; i<4096; i++) {
            DEVMODE dm = NewMode();
            if (!EnumDisplaySettings(device, i, ref dm)) break;
            if (dm.dmBitsPerPel < 24 || dm.dmDisplayFrequency < 24 || dm.dmDisplayFrequency > 600 ||
                (dm.dmDisplayFlags & 2) != 0) continue;
            widths.Add(dm.dmPelsWidth); heights.Add(dm.dmPelsHeight); rates.Add(dm.dmDisplayFrequency);
        }
        return GetHighestRefreshAtResolution(width, height, widths.ToArray(), heights.ToArray(), rates.ToArray());
    }

    public static bool TrySetDisplayMode(int desiredWidth, int desiredHeight, int desiredHz, out string report) {
        const string device = @"\\.\DISPLAY1";
        DEVMODE current = NewMode();
        if (!EnumDisplaySettings(device, -1, ref current)) {
            report = "Cannot read current DISPLAY1 mode; no changes made.";
            return false;
        }
        List<DEVMODE> modes = new List<DEVMODE>();
        List<int> widths = new List<int>();
        List<int> heights = new List<int>();
        List<int> rates = new List<int>();
        if (current.dmBitsPerPel >= 24 && current.dmDisplayFrequency >= 24 &&
            (current.dmDisplayFlags & 2) == 0) {
            modes.Add(current); widths.Add(current.dmPelsWidth); heights.Add(current.dmPelsHeight); rates.Add(current.dmDisplayFrequency);
        }
        int count = 0;
        for (int i=0; i<4096; i++) {
            DEVMODE dm = NewMode();
            if (!EnumDisplaySettings(device, i, ref dm)) break;
            count++;
            if (dm.dmBitsPerPel < 24 || dm.dmDisplayFrequency < 24 ||
                (dm.dmDisplayFlags & 2) != 0) continue;
            modes.Add(dm); widths.Add(dm.dmPelsWidth); heights.Add(dm.dmPelsHeight); rates.Add(dm.dmDisplayFrequency);
        }
        int highest = GetHighestRefreshAtResolution(desiredWidth, desiredHeight, widths.ToArray(), heights.ToArray(), rates.ToArray());
        int selectedWidth = desiredWidth, selectedHeight = desiredHeight;
        bool preferredResolution = highest >= 24;
        if (!preferredResolution) {
            selectedWidth = current.dmPelsWidth; selectedHeight = current.dmPelsHeight;
            highest = GetHighestRefreshAtResolution(selectedWidth, selectedHeight, widths.ToArray(), heights.ToArray(), rates.ToArray());
        }
        if (highest < 24) {
            report = device + " no suitable display mode advertised after checking " + count +
                " modes. Keeping " + current.dmPelsWidth + "x" + current.dmPelsHeight +
                " @" + current.dmDisplayFrequency + "Hz.";
            return false;
        }
        DEVMODE candidate = NewMode();
        bool candidateFound = false;
        foreach (DEVMODE dm in modes) {
            if (dm.dmPelsWidth != selectedWidth || dm.dmPelsHeight != selectedHeight || dm.dmDisplayFrequency != highest) continue;
            if (!candidateFound || dm.dmBitsPerPel > candidate.dmBitsPerPel) { candidate = dm; candidateFound = true; }
        }
        if (!candidateFound) {
            report = device + " could not resolve the selected " + selectedWidth + "x" + selectedHeight + " @" + highest + "Hz mode.";
            return false;
        }
        string choice = candidate.dmPelsWidth + "x" + candidate.dmPelsHeight +
            " @" + candidate.dmDisplayFrequency + "Hz";
        string requested = desiredWidth + "x" + desiredHeight + " (profile refresh " + desiredHz + "Hz)";
        string reason = preferredResolution
            ? "highest advertised refresh at preferred resolution"
            : "preferred resolution unavailable; highest advertised refresh at current resolution";

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
    private delegate int NvApiGetDvcInfoEx(IntPtr handle, uint outputId, ref DvcInfoEx info);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiSetDvcLevelEx(IntPtr handle, uint outputId, ref DvcInfoEx info);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiGetDvcInfo(IntPtr handle, uint outputId, ref DvcInfoLegacy info);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiSetDvcLevel(IntPtr handle, uint outputId, uint level);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiGetHueInfo(IntPtr handle, uint outputId, ref HueInfo info);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int NvApiSetHueAngle(IntPtr handle, uint outputId, uint hueAngle);
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

    // The extended DVC interface uses the percentage scale shown by NVIDIA
    // Control Panel. Legacy DVC levels are quantized; query their range per driver.
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct DvcInfoEx {
        public uint version;
        public int currentLevel;
        public int minLevel;
        public int maxLevel;
        public int defaultLevel;
    }

    // The legacy DVC structure reports an integer driver range (commonly 0-63).
    // Always query the range; do not assume that every driver uses the same bounds.
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct DvcInfoLegacy {
        public uint version;
        public uint currentLevel;
        public uint minLevel;
        public uint maxLevel;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct HueInfo {
        public uint version;
        public uint currentAngle;
        public uint defaultAngle;
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

    public static bool TryCheckNvApiSupport(out string report) {
        NvApiUnload unload = null;
        bool initialized = false;
        string failure = null;
        int unloadStatus = 0;
        try {
            Initialize(out unload);
            initialized = true;
        } catch (Exception ex) {
            failure = ex.Message;
        } finally {
            if (initialized && unload != null) {
                try { unloadStatus = unload(); }
                catch (Exception ex) { failure = "NvAPI_Unload failed: " + ex.Message; }
            }
        }
        if (!initialized) {
            report = "NVAPI initialization failed: " + failure;
            return false;
        }
        if (failure != null || unloadStatus != 0) {
            report = "NVAPI initialized, but cleanup failed" + (failure != null ? ": " + failure : " with status " + unloadStatus) + ".";
            return false;
        }
        report = "NvAPI_Initialize and NvAPI_Unload succeeded.";
        return true;
    }

    public static bool TryCheckDigitalVibranceSupport(out string report) {
        NvApiUnload unload = null;
        bool initialized = false;
        string extendedFailure = "not available";
        try {
            Initialize(out unload);
            initialized = true;
            IntPtr handle = GetDisplayHandle();
            try {
                NvApiGetDvcInfoEx getExtended = Resolve<NvApiGetDvcInfoEx>(0x0E45002D);
                DvcInfoEx extended = new DvcInfoEx();
                extended.version = (uint)(Marshal.SizeOf(typeof(DvcInfoEx)) | 0x10000);
                int rc = getExtended(handle, 0, ref extended);
                if (rc != 0) throw new Exception("extended DVC query status " + rc);
                if (extended.maxLevel <= extended.minLevel) throw new Exception("extended DVC returned an invalid range");
                report = "Extended Digital Vibrance query available (range " + extended.minLevel + "-" + extended.maxLevel + ").";
                return true;
            } catch (Exception ex) {
                extendedFailure = ex.Message;
            }

            NvApiGetDvcInfo getLegacy = Resolve<NvApiGetDvcInfo>(0x4085DE45);
            DvcInfoLegacy legacy = new DvcInfoLegacy();
            legacy.version = (uint)(Marshal.SizeOf(typeof(DvcInfoLegacy)) | 0x10000);
            int legacyStatus = getLegacy(handle, 0, ref legacy);
            if (legacyStatus != 0) throw new Exception("legacy DVC query status " + legacyStatus);
            if (legacy.maxLevel <= legacy.minLevel) throw new Exception("legacy DVC returned an invalid range");
            report = "Extended DVC unavailable (" + extendedFailure + "); legacy Digital Vibrance query available (range " +
                legacy.minLevel + "-" + legacy.maxLevel + ").";
            return true;
        } catch (Exception ex) {
            report = "Digital Vibrance unavailable: extended interface " + extendedFailure + "; legacy interface " + ex.Message + ".";
            return false;
        } finally {
            if (initialized && unload != null) { try { unload(); } catch {} }
        }
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
            NvApiGetDvcInfoEx getInfo = Resolve<NvApiGetDvcInfoEx>(0x0E45002D);
            DvcInfoEx info = new DvcInfoEx();
            info.version = (uint)(Marshal.SizeOf(typeof(DvcInfoEx)) | 0x10000);
            int status = getInfo(handle, 0, ref info);
            if (status != 0)
                throw new Exception("NvAPI_GetDVCInfoEx failed with status " + status + ".");

            currentLevel = info.currentLevel;
            minLevel = info.minLevel;
            maxLevel = info.maxLevel;
            report = "NVIDIA Control Panel Digital Vibrance is " + currentLevel +
                "% (driver range " + minLevel + "-" + maxLevel + "%).";
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
            NvApiGetDvcInfoEx getInfo = Resolve<NvApiGetDvcInfoEx>(0x0E45002D);
            NvApiSetDvcLevelEx setLevel = Resolve<NvApiSetDvcLevelEx>(0x4A82C2B1);

            DvcInfoEx info = new DvcInfoEx();
            info.version = (uint)(Marshal.SizeOf(typeof(DvcInfoEx)) | 0x10000);
            int status = getInfo(handle, 0, ref info);
            if (status != 0) throw new Exception("NvAPI_GetDVCInfoEx failed with status " + status + ".");
            if (info.maxLevel <= info.minLevel) throw new Exception("NVIDIA returned an invalid Digital Vibrance range.");

            // Map the requested Control Panel percentage onto the driver's
            // extended scale (normally 0-100), not the legacy 0-63 scale.
            int requested = info.minLevel + (int)Math.Round((info.maxLevel - info.minLevel) * (percentage / 100.0));
            DvcInfoEx request = info;
            request.currentLevel = requested;
            int setStatus = setLevel(handle, 0, ref request);
            if (setStatus != 0) throw new Exception("NvAPI_SetDVCLevelEx failed with status " + setStatus + ".");

            DvcInfoEx verify = new DvcInfoEx();
            verify.version = (uint)(Marshal.SizeOf(typeof(DvcInfoEx)) | 0x10000);
            int verifyStatus = getInfo(handle, 0, ref verify);
            if (verifyStatus != 0) throw new Exception("Digital Vibrance was set, but extended read-back failed with status " + verifyStatus + ".");
            if (verify.currentLevel != requested)
                throw new Exception("NVIDIA accepted the Digital Vibrance request but reports " + verify.currentLevel + " (requested " + requested + ").");

            report = "Digital Vibrance set and verified at " + verify.currentLevel +
                "% (requested " + percentage + "%; driver range " + verify.minLevel + "-" + verify.maxLevel +
                "%) for the NVIDIA display associated with DISPLAY1.";
            return true;
        } catch (Exception ex) {
            // Older drivers may expose the legacy DVC interface but not the
            // extended percentage-scale interface. Use it only after querying
            // its range and verify the actual value with a second query.
            if (initialized) {
                try {
                    string legacyReport;
                    if (TrySetDigitalVibranceLegacy(GetDisplayHandle(), percentage, out legacyReport)) {
                        report = "Extended Digital Vibrance interface failed (" + ex.Message + "). " + legacyReport;
                        return true;
                    }
                    report = "Digital Vibrance failed: extended interface: " + ex.Message + "; legacy interface: " + legacyReport;
                    return false;
                } catch (Exception legacyEx) {
                    report = "Digital Vibrance failed: extended interface: " + ex.Message + "; legacy interface: " + legacyEx.Message;
                    return false;
                }
            }
            report = "Digital Vibrance failed: " + ex.Message;
            return false;
        } finally {
            if (initialized && unload != null) { try { unload(); } catch {} }
        }
    }

    public static uint MapLegacyDvcPercentage(int percentage, uint minLevel, uint maxLevel) {
        if (percentage < 0 || percentage > 100) throw new ArgumentOutOfRangeException("percentage");
        if (maxLevel <= minLevel) throw new ArgumentException("Legacy Digital Vibrance range must have max greater than min.");
        return minLevel + (uint)Math.Round(
            (maxLevel - minLevel) * (percentage / 100.0), MidpointRounding.AwayFromZero);
    }

    private static bool TrySetDigitalVibranceLegacy(IntPtr handle, int percentage, out string report) {
        try {
            NvApiGetDvcInfo getInfo = Resolve<NvApiGetDvcInfo>(0x4085DE45);
            NvApiSetDvcLevel setLevel = Resolve<NvApiSetDvcLevel>(0x172409B4);
            DvcInfoLegacy info = new DvcInfoLegacy();
            info.version = (uint)(Marshal.SizeOf(typeof(DvcInfoLegacy)) | 0x10000);
            int status = getInfo(handle, 0, ref info);
            if (status != 0) throw new Exception("NvAPI_GetDVCInfo failed with status " + status + ".");
            if (info.maxLevel <= info.minLevel) throw new Exception("NVIDIA returned an invalid legacy Digital Vibrance range.");

            uint requested = MapLegacyDvcPercentage(percentage, info.minLevel, info.maxLevel);
            int setStatus = setLevel(handle, 0, requested);
            if (setStatus != 0) throw new Exception("NvAPI_SetDVCLevel failed with status " + setStatus + ".");

            DvcInfoLegacy verify = new DvcInfoLegacy();
            verify.version = (uint)(Marshal.SizeOf(typeof(DvcInfoLegacy)) | 0x10000);
            int verifyStatus = getInfo(handle, 0, ref verify);
            if (verifyStatus != 0) throw new Exception("Legacy Digital Vibrance read-back failed with status " + verifyStatus + ".");
            if (verify.currentLevel != requested)
                throw new Exception("NVIDIA reports legacy level " + verify.currentLevel + " (requested " + requested + ").");

            double effectivePercent = ((verify.currentLevel - verify.minLevel) * 100.0) /
                (verify.maxLevel - verify.minLevel);
            report = "Legacy Digital Vibrance set and verified: requested " + percentage +
                "%, driver level " + verify.currentLevel + " (range " + verify.minLevel + "-" +
                verify.maxLevel + "; effective " + effectivePercent.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) + "%).";
            return true;
        } catch (Exception ex) {
            report = ex.Message;
            return false;
        }
    }

    public static bool TrySetDigitalVibrance75(out string report) {
        return TrySetDigitalVibrance(75, out report);
    }

    // NVIDIA's Hue calls are private NVAPI interfaces; guard them and verify
    // read-back because support can vary across driver versions.
    public static bool TryCheckHueSupport(out uint currentAngle, out uint defaultAngle, out string report) {
        NvApiUnload unload = null;
        bool initialized = false;
        currentAngle = 0;
        defaultAngle = 0;
        try {
            Initialize(out unload);
            initialized = true;
            IntPtr handle = GetDisplayHandle();
            NvApiGetHueInfo getInfo = Resolve<NvApiGetHueInfo>(0x95B64341);
            // Resolve the setter during preflight without changing the display.
            NvApiSetHueAngle setAngle = Resolve<NvApiSetHueAngle>(0xF5A0F22C);
            HueInfo info = new HueInfo();
            info.version = (uint)(Marshal.SizeOf(typeof(HueInfo)) | 0x10000);
            int status = getInfo(handle, 0, ref info);
            if (status != 0) throw new Exception("NvAPI_GetHUEInfo failed with status " + status + ".");
            if (info.currentAngle > 359 || info.defaultAngle > 359)
                throw new Exception("NVIDIA returned a Hue value outside the documented 0-359 degree range.");
            currentAngle = info.currentAngle;
            defaultAngle = info.defaultAngle;
            report = "Hue query/set interfaces detected for the NVIDIA display associated with DISPLAY1 (current " +
                currentAngle + " degrees; driver default " + defaultAngle + " degrees).";
            return true;
        } catch (Exception ex) {
            report = "Hue unavailable: " + ex.Message;
            return false;
        } finally {
            if (initialized && unload != null) { try { unload(); } catch {} }
        }
    }

    public static bool TrySetHueAngle(int hueAngle, out string report) {
        if (hueAngle < -1 || hueAngle > 359) { report = "Invalid hue angle"; return false; }
        NvApiUnload unload = null;
        bool initialized = false;
        try {
            Initialize(out unload);
            initialized = true;
            IntPtr handle = GetDisplayHandle();
            NvApiGetHueInfo getInfo = Resolve<NvApiGetHueInfo>(0x95B64341);
            NvApiSetHueAngle setAngle = Resolve<NvApiSetHueAngle>(0xF5A0F22C);
            HueInfo info = new HueInfo();
            info.version = (uint)(Marshal.SizeOf(typeof(HueInfo)) | 0x10000);
            int status = getInfo(handle, 0, ref info);
            if (status != 0) throw new Exception("NvAPI_GetHUEInfo failed with status " + status + ".");
            uint requestedAngle = hueAngle < 0 ? info.defaultAngle : (uint)hueAngle;
            int setStatus = setAngle(handle, 0, requestedAngle);
            if (setStatus != 0) throw new Exception("NvAPI_SetHUEAngle failed with status " + setStatus + ".");
            HueInfo verify = new HueInfo();
            verify.version = (uint)(Marshal.SizeOf(typeof(HueInfo)) | 0x10000);
            int verifyStatus = getInfo(handle, 0, ref verify);
            if (verifyStatus != 0) throw new Exception("Hue was set, but read-back failed with status " + verifyStatus + ".");
            if (verify.currentAngle != requestedAngle)
                throw new Exception("NVIDIA reports hue " + verify.currentAngle + " degrees (requested " + requestedAngle + ").");
            report = hueAngle < 0
                ? "Hue reset to and verified at the NVIDIA driver default: " + verify.currentAngle + " degrees."
                : "Hue set and verified at " + verify.currentAngle + " degrees (driver default " + verify.defaultAngle + ").";
            return true;
        } catch (Exception ex) {
            report = "Hue failed: " + ex.Message;
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

    public static bool TryCheckDriverProfileSupport(out string report) {
        NvApiUnload unload = null;
        NvApiDrsDestroySession destroy = null;
        IntPtr session = IntPtr.Zero;
        bool initialized = false;
        try {
            Initialize(out unload);
            initialized = true;
            NvApiDrsCreateSession create = Resolve<NvApiDrsCreateSession>(0x0694D52E);
            destroy = Resolve<NvApiDrsDestroySession>(0xDAD9CFF8);
            NvApiDrsLoadSettings load = Resolve<NvApiDrsLoadSettings>(0x375DBD6B);
            Resolve<NvApiDrsSaveSettings>(0xFCBC7E14);
            NvApiDrsGetCurrentGlobalProfile getGlobal = Resolve<NvApiDrsGetCurrentGlobalProfile>(0x617BFF9F);
            Resolve<NvApiDrsGetSetting>(0x73BF8338);
            Resolve<NvApiDrsSetSetting>(0x577DD202);
            int status = create(out session);
            if (status != 0 || session == IntPtr.Zero) throw new Exception("DRS_CreateSession status " + status);
            status = load(session);
            if (status != 0) throw new Exception("DRS_LoadSettings status " + status);
            IntPtr profile;
            status = getGlobal(session, out profile);
            if (status != 0 || profile == IntPtr.Zero) throw new Exception("DRS_GetCurrentGlobalProfile status " + status);
            report = "NVIDIA DRS profile query, save, and setting interfaces are available; global profile opened read-only.";
            return true;
        } catch (Exception ex) {
            report = "NVIDIA driver-profile settings unavailable: " + ex.Message + ".";
            return false;
        } finally {
            if (session != IntPtr.Zero && destroy != null) { try { destroy(session); } catch {} }
            if (initialized && unload != null) { try { unload(); } catch {} }
        }
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
        return TrySetGpuScalingMode(2, out report);
    }

    public static bool TryCheckGpuScalingSupport(out string report) {
        NvApiUnload unload = null;
        bool initialized = false;
        try {
            Initialize(out unload);
            initialized = true;
            NvApiDispGetDisplayConfig getConfig = Resolve<NvApiDispGetDisplayConfig>(0x11ABCCF8);
            Resolve<NvApiDispSetDisplayConfig>(0x5D8CF8DE);
            uint pathCount = 0;
            int status = getConfig(ref pathCount, IntPtr.Zero);
            if (status != 0) throw new Exception("display configuration query status " + ScalingStatus(status));
            if (pathCount < 1 || pathCount > 64) throw new Exception("unexpected display path count " + pathCount);
            report = "NVAPI display-scaling read/apply interfaces available; " + pathCount + " active display path(s) detected. Apply will validate and verify the requested mode.";
            return true;
        } catch (Exception ex) {
            report = "GPU scaling unavailable: " + ex.Message + ".";
            return false;
        } finally {
            if (initialized && unload != null) { try { unload(); } catch {} }
        }
    }

    public static bool TrySetGpuScalingMode(int requestedScaling, out string report) {
        if (requestedScaling != 2 && requestedScaling != 3 && requestedScaling != 5) {
            report = "Unsupported NVIDIA scaling mode " + requestedScaling + ".";
            return false;
        }
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
            Marshal.WriteInt32(selectedTarget.details, 8, requestedScaling);

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

            if (actualScaling != requestedScaling)
                throw new Exception("NVIDIA did not retain scaling mode " + requestedScaling + ". Driver reports mode " + actualScaling + " (previous " + oldScaling + ").");

            string scalingName = requestedScaling == 2 ? "GPU full-screen stretch" :
                requestedScaling == 3 ? "centered, no scaling" : "preserve aspect ratio";
            report = "GPU scaling set and verified using NvAPI_DISP_SetDisplayConfig: " + scalingName + " (mode " + requestedScaling + "). Previous mode " +
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
    $result=[ordered]@{NVAPI=$false;DisplayHelper=$false;ExactMode=$false;Vibrance=$false;Hue=$false;DriverProfile=$false;GpuScaling=$false;Report=$report}
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
                $(if($result.ExactMode){'available or already active'}else{'not available; trying the highest advertised Hz at the requested resolution, then the current resolution'})))
            $report.Add([FabDisplayNative]::GetDisplayModesReport())
        }catch{
            $report.Add('Monitor mode enumeration unavailable: '+$_.Exception.Message)
            $result.DisplayHelper=$false
        }
    }else{$report.Add('Windows display helper unavailable; resolution change skipped.')}
    $apiDll=Join-Path $env:windir 'System32\nvapi64.dll'
    $apiFile=Test-Path -LiteralPath $apiDll -PathType Leaf
    $nvapiType=[bool]('FabNvApi' -as [type])
    if($nvapiType){
        try{
            $nvapiInitializationReport=''
            $result.NVAPI=[FabNvApi]::TryCheckNvApiSupport([ref]$nvapiInitializationReport)
            if($result.NVAPI){$report.Add('NVAPI availability: initialization succeeded. '+$nvapiInitializationReport)}
            else{$report.Add('NVAPI availability: initialization failed; NVIDIA-only operations will be skipped. '+$nvapiInitializationReport)}
        }catch{$result.NVAPI=$false;$report.Add('NVAPI availability: initialization probe failed; NVIDIA-only operations will be skipped. '+$_.Exception.Message)}
    }else{
        $report.Add('NVAPI availability: embedded NVAPI wrapper unavailable; NVIDIA-only operations will be skipped.')
    }
    if($apiFile){
        try{$report.Add('NVAPI DLL version: '+[Diagnostics.FileVersionInfo]::GetVersionInfo($apiDll).FileVersion)}
        catch{$report.Add('NVAPI DLL version unavailable')}
    }
    if($result.NVAPI){
        try{
            $vibranceCapabilityReport=''
            $result.Vibrance=[FabNvApi]::TryCheckDigitalVibranceSupport([ref]$vibranceCapabilityReport)
            if($result.Vibrance){$report.Add('NVIDIA Digital Vibrance capability: available. '+$vibranceCapabilityReport)}
            else{$report.Add('NVIDIA Digital Vibrance capability: unavailable; profile value will be skipped. '+$vibranceCapabilityReport)}
        }catch{$result.Vibrance=$false;$report.Add('NVIDIA Digital Vibrance capability check failed; profile value will be skipped: '+$_.Exception.Message)}
        try{
            [uint32]$hueCurrent=0;[uint32]$hueDefault=0;$hueCapabilityReport=''
            $result.Hue=[FabNvApi]::TryCheckHueSupport([ref]$hueCurrent,[ref]$hueDefault,[ref]$hueCapabilityReport)
            if($result.Hue){$report.Add('NVIDIA Hue capability: available. '+$hueCapabilityReport)}
            else{$report.Add('NVIDIA Hue capability: unavailable; profile Hue settings will be skipped. '+$hueCapabilityReport)}
        }catch{$result.Hue=$false;$report.Add('NVIDIA Hue capability check failed; profile Hue settings will be skipped: '+$_.Exception.Message)}
        try{
            $driverProfileReport=''
            $result.DriverProfile=[FabNvApi]::TryCheckDriverProfileSupport([ref]$driverProfileReport)
            if($result.DriverProfile){$report.Add('NVIDIA driver-profile capability: available. '+$driverProfileReport)}
            else{$report.Add('NVIDIA driver-profile capability: unavailable; performance and G-SYNC profile values will be skipped. '+$driverProfileReport)}
        }catch{$result.DriverProfile=$false;$report.Add('NVIDIA driver-profile capability check failed; settings will be skipped: '+$_.Exception.Message)}
        try{
            $scalingCapabilityReport=''
            $result.GpuScaling=[FabNvApi]::TryCheckGpuScalingSupport([ref]$scalingCapabilityReport)
            if($result.GpuScaling){$report.Add('NVIDIA GPU-scaling capability: available. '+$scalingCapabilityReport)}
            else{$report.Add('NVIDIA GPU-scaling capability: unavailable; profile scaling value will be skipped. '+$scalingCapabilityReport)}
        }catch{$result.GpuScaling=$false;$report.Add('NVIDIA GPU-scaling capability check failed; profile scaling value will be skipped: '+$_.Exception.Message)}
    }else{
        $report.Add('NVIDIA Digital Vibrance capability: not checked because NVAPI is unavailable; profile value will be skipped.')
        $report.Add('NVIDIA Hue capability: not checked because NVAPI is unavailable; profile value will be skipped.')
        $report.Add('NVIDIA driver-profile capability: not checked because NVAPI is unavailable; settings will be skipped.')
        $report.Add('NVIDIA GPU-scaling capability: not checked because NVAPI is unavailable; profile scaling value will be skipped.')
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
        [ValidateRange(0,100)][int]$Vibrance = 75,
        [ValidateRange(-1,359)][int]$Hue = -1,
        [ValidateSet(2,3,5)][int]$ScalingMode = 2
    )
    $runName=if($script:StepScope){$script:StepScope.Run}elseif($script:ActiveRunName){$script:ActiveRunName}else{'Manual NVIDIA'}
    $hueDescription=if($Hue -lt 0){'driver default'}else{"${Hue} degrees"}
    Write-Log "NVIDIA gaming-settings apply started (profile resolution: ${Width}x${Height}; highest advertised refresh; configured refresh ${RefreshHz}Hz; vibrance ${Vibrance}%; hue $hueDescription; brightness unchanged, default is 50%)."
    $compat=$null
    try{$compat=Write-NvidiaCompatibilityScan -Width $Width -Height $Height -RefreshHz $RefreshHz}
    catch{Write-Log ("NVIDIA preflight unavailable: "+$_.Exception.Message) "WARN"}

    Write-Log "Profile display apply: selecting the highest advertised refresh at ${Width}x${Height}; if unavailable, keep current resolution and select its highest refresh."
    if($null -eq $compat){
        Write-Log "Display resolution/refresh skipped because the compatibility preflight did not complete." "WARN"
        Set-RunOutcome -Run $runName -Setting 'Windows display mode' -Requested "${Width}x${Height} @ highest advertised Hz" -Target 'DISPLAY1' -Status SKIPPED -Detail 'Display capability preflight did not complete.'
    }elseif(-not $compat.DisplayHelper){
        Write-Log "Display resolution/refresh skipped because Windows mode enumeration is unavailable." "WARN"
        Set-RunOutcome -Run $runName -Setting 'Windows display mode' -Requested "${Width}x${Height} @ highest advertised Hz" -Target 'DISPLAY1' -Status SKIPPED -Detail 'Windows display-mode enumeration is unavailable.'
    }elseif ("FabDisplayNative" -as [type]) {
        try {
            $displayReport = ""
            $displayOk = [FabDisplayNative]::TrySetDisplayMode($Width, $Height, $RefreshHz, [ref]$displayReport)
            if ($displayOk) {
                $displayStatus=if($displayReport -match 'preferred resolution unavailable'){'FALLBACK'}else{'APPLIED'}
                $displayActual=if($displayReport -match '(\d+x\d+ @\d+Hz)'){$Matches[1]}else{$displayReport}
                Set-RunOutcome -Run $runName -Setting 'Windows display mode' -Requested "${Width}x${Height} @ highest advertised Hz (profile hint ${RefreshHz} Hz)" -Target 'DISPLAY1' -Status $displayStatus -Actual $displayActual -Detail $displayReport
                if($displayReport -match 'preferred resolution unavailable'){
                    Write-Log $displayReport "WARN"
                }else{
                    Write-Log $displayReport
                }
            } else {
                Set-RunOutcome -Run $runName -Setting 'Windows display mode' -Requested "${Width}x${Height} @ highest advertised Hz" -Target 'DISPLAY1' -Status FAILED -Actual $displayReport -Detail 'Display mode change was not verified.'
                Write-Log $displayReport "WARN"
            }
        } catch {
            Set-RunOutcome -Run $runName -Setting 'Windows display mode' -Requested "${Width}x${Height} @ highest advertised Hz" -Target 'DISPLAY1' -Status FAILED -Detail $_.Exception.Message
            Write-Log "Display resolution/refresh was not applied: $($_.Exception.Message)" "WARN"
        }
    }else{
        Set-RunOutcome -Run $runName -Setting 'Windows display mode' -Requested "${Width}x${Height} @ highest advertised Hz" -Target 'DISPLAY1' -Status SKIPPED -Detail 'Display-mode helper is unavailable.'
    }

    if($null -eq $compat -or -not $compat.NVAPI -or -not ("FabNvApi" -as [type])){
        Write-Log "NVIDIA settings skipped because the NVAPI capability preflight did not succeed." "WARN"
        foreach($setting in @('Digital Vibrance','Hue','NVIDIA performance/G-SYNC driver profile','GPU scaling mode')){
            Set-RunOutcome -Run $runName -Setting $setting -Requested 'Profile value' -Target 'NVIDIA display/driver' -Status SKIPPED -Detail 'NVAPI capability preflight did not succeed.'
        }
    }else{
        if(-not $compat.Vibrance){
            Write-Log "Digital Vibrance skipped: neither the extended nor legacy driver interface passed its read-only capability check." "WARN"
            Set-RunOutcome -Run $runName -Setting 'Digital Vibrance' -Requested ("${Vibrance}%") -Target 'NVIDIA display associated with DISPLAY1' -Status SKIPPED -Detail 'No supported DVC query interface.'
        }else{
            try {
                $vibranceReport = ""
                $vibranceOk = [FabNvApi]::TrySetDigitalVibrance($Vibrance, [ref]$vibranceReport)
                $vibranceState=if(-not $vibranceOk){'FAILED'}elseif($vibranceReport -match '^Extended Digital Vibrance interface failed'){'FALLBACK'}else{'APPLIED'}
                $vibranceActual=if($vibranceReport -match '(?:at |level )(\d+)(?:%| \()'){$Matches[1]+'%'}else{$vibranceReport}
                Set-RunOutcome -Run $runName -Setting 'Digital Vibrance' -Requested ("${Vibrance}%") -Target 'NVIDIA display associated with DISPLAY1' -Status $vibranceState -Actual $vibranceActual -Detail $vibranceReport
                if ($vibranceOk) {
                    Write-Log $vibranceReport
                } else {
                    Write-Log ("Digital Vibrance was detected, but apply was not verified: "+$vibranceReport) "WARN"
                }
            } catch {
                Set-RunOutcome -Run $runName -Setting 'Digital Vibrance' -Requested ("${Vibrance}%") -Target 'NVIDIA display associated with DISPLAY1' -Status FAILED -Detail $_.Exception.Message
                Write-Log "Digital Vibrance apply was not verified: $($_.Exception.Message)" "WARN"
            }
        }

        if(-not $compat.Hue){
            Write-Log "Hue skipped: the current driver/display did not pass its read-only Hue capability check." "WARN"
            Set-RunOutcome -Run $runName -Setting 'Hue' -Requested $(if($Hue -lt 0){'driver default'}else{"${Hue} degrees"}) -Target 'NVIDIA display associated with DISPLAY1' -Status SKIPPED -Detail 'Hue query/set capability is unavailable.'
        }else{
            try {
                $hueReport = ""
                $hueOk = [FabNvApi]::TrySetHueAngle($Hue, [ref]$hueReport)
                Set-RunOutcome -Run $runName -Setting 'Hue' -Requested $(if($Hue -lt 0){'driver default'}else{"${Hue} degrees"}) -Target 'NVIDIA display associated with DISPLAY1' -Status $(if($hueOk){'APPLIED'}else{'FAILED'}) -Actual $hueReport -Detail $hueReport
                if ($hueOk) { Write-Log $hueReport }
                else { Write-Log ("Hue was detected, but apply was not verified: "+$hueReport) "WARN" }
            } catch {
                Set-RunOutcome -Run $runName -Setting 'Hue' -Requested $(if($Hue -lt 0){'driver default'}else{"${Hue} degrees"}) -Target 'NVIDIA display associated with DISPLAY1' -Status FAILED -Detail $_.Exception.Message
                Write-Log "Hue apply was not verified: $($_.Exception.Message)" "WARN"
            }
        }

        if(-not $compat.DriverProfile){
            Write-Log "Performance and G-SYNC driver-profile settings skipped: DRS profile read/save capability is unavailable." "WARN"
            Set-RunOutcome -Run $runName -Setting 'NVIDIA performance/G-SYNC driver profile' -Requested 'Performance values; G-SYNC driver flags off' -Target 'Global NVIDIA driver profile' -Status SKIPPED -Detail 'DRS read/save capability is unavailable.'
        }else{
            try {
                $performanceReport = ""
                $performanceOk = [FabNvApi]::TryApplyPerformanceProfile([ref]$performanceReport)
                Set-RunOutcome -Run $runName -Setting 'NVIDIA performance/G-SYNC driver profile' -Requested 'Performance values; G-SYNC driver flags off' -Target 'Global NVIDIA driver profile' -Status $(if($performanceOk){'APPLIED'}else{'FALLBACK'}) -Actual $performanceReport -Detail 'Individual verified and skipped driver flags are included in the detailed result.'
                foreach ($performanceLine in ($performanceReport -split "\r?\n")) {
                    if (-not [string]::IsNullOrWhiteSpace($performanceLine)) {
                        if ($performanceLine.StartsWith("ERROR:")) {
                            Write-Log $performanceLine.Substring(6).Trim() "WARN"
                        } elseif ($performanceLine.StartsWith("WARN:")) {
                            Write-Log $performanceLine.Substring(5).Trim() "WARN"
                        } else {
                            Write-Log $performanceLine.Substring(5).Trim()
                        }
                    }
                }
                if (-not $performanceOk) {
                    Write-Log "Some NVIDIA Performance/G-SYNC-off driver profile settings were unavailable or not verified. See DRS lines." "WARN"
                }
            } catch {
                Set-RunOutcome -Run $runName -Setting 'NVIDIA performance/G-SYNC driver profile' -Requested 'Performance values; G-SYNC driver flags off' -Target 'Global NVIDIA driver profile' -Status FAILED -Detail $_.Exception.Message
                Write-Log "Performance/G-SYNC driver-profile settings were not applied: $($_.Exception.Message)" "WARN"
            }
        }

        $scalingName=switch($ScalingMode){2{'Stretch to fill'}3{'Center without scaling'}5{'Keep aspect ratio'}}
        $scalingTarget='NVIDIA display associated with Windows DISPLAY1'
        $scalingRequest="$scalingName (NVAPI mode $ScalingMode)"
        if(-not $compat.GpuScaling){
            $scalingDetail='Read-only GPU scaling capability check failed; no mode change was attempted.'
            Write-Log ("NVIDIA scaling | profile=$runName | requested=$scalingRequest | target=$scalingTarget | status=SKIPPED | detail=$scalingDetail") 'WARN'
            Set-RunOutcome -Run $runName -Setting 'GPU scaling mode' -Requested $scalingRequest -Target $scalingTarget -Status SKIPPED -Detail $scalingDetail
        }else{
            try {
                $scalingReport = ""
                $scalingOk = [FabNvApi]::TrySetGpuScalingMode($ScalingMode, [ref]$scalingReport)
                $scalingStatus=if($scalingOk){'APPLIED'}else{'FAILED'}
                if($scalingOk -and $scalingReport -match 'matched Windows GDI-primary display because DISPLAY1 name could not be mapped'){$scalingStatus='FALLBACK'}
                Write-Log ("NVIDIA scaling | profile=$runName | requested=$scalingRequest | target=$scalingTarget | status=$scalingStatus | result=$scalingReport") $(if($scalingOk){'INFO'}else{'WARN'})
                Set-RunOutcome -Run $runName -Setting 'GPU scaling mode' -Requested $scalingRequest -Target $scalingTarget -Status $scalingStatus -Actual $scalingReport -Detail $scalingReport
            } catch {
                $scalingDetail=$_.Exception.Message
                Write-Log ("NVIDIA scaling | profile=$runName | requested=$scalingRequest | target=$scalingTarget | status=FAILED | detail=$scalingDetail") 'WARN'
                Set-RunOutcome -Run $runName -Setting 'GPU scaling mode' -Requested $scalingRequest -Target $scalingTarget -Status FAILED -Detail $scalingDetail
            }
        }
    }

    Write-Log "NVIDIA Performance-equivalent values were requested through the global driver profile; select the actual preview slider manually if the radio control must also show Performance."
    Write-Log "Still manual: Configure Surround, PhysX -> select the NVIDIA GPU."
    Set-RunOutcome -Run $runName -Setting 'PhysX processor' -Requested 'NVIDIA GPU or Auto-select' -Target 'NVIDIA Control Panel > Configure Surround, PhysX' -Status SKIPPED -Detail 'No supported launcher setter; manual selection remains required.'
    Write-Log "Still manual: Adjust desktop size and position -> enable override scaling mode set by games and programs."
    Set-RunOutcome -Run $runName -Setting 'Scaling override checkbox' -Requested 'Enabled' -Target 'NVIDIA Control Panel > Adjust desktop size and position' -Status SKIPPED -Detail 'No reliable supported launcher setter; manual change remains required.'
    Write-Log "G-SYNC-off driver profile values were requested globally; confirm Set up G-SYNC checkbox is OFF on display 1 (this GUI checkbox itself was not toggled)."
    Set-RunOutcome -Run $runName -Setting 'G-SYNC Control Panel checkbox' -Requested 'Off' -Target 'NVIDIA Control Panel > Set up G-SYNC' -Status SKIPPED -Detail 'Driver profile flags were requested, but the GUI checkbox was not changed.'
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

function Get-SteamLibraryCachePath {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return $null }
    return (Join-Path $env:LOCALAPPDATA 'CafeLauncher\steam-library-cache.json')
}

function Read-SteamLibraryCache {
    $cachePath=Get-SteamLibraryCachePath
    if(-not $cachePath -or -not (Test-Path -LiteralPath $cachePath -PathType Leaf)){return @()}
    try{
        $item=Get-Item -LiteralPath $cachePath -ErrorAction Stop
        if($item.Length -gt 65536){throw 'cache is too large'}
        $cache=Get-Content -LiteralPath $cachePath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
        if([int]$cache.SchemaVersion -ne 1 -or @($cache.Libraries).Count -gt 64){throw 'cache schema or entry count is invalid'}
        $valid=New-Object 'System.Collections.Generic.List[string]'
        foreach($entry in @($cache.Libraries)){
            $path=[string]$entry
            if([string]::IsNullOrWhiteSpace($path) -or $path -notmatch '^[A-Za-z]:\\'){continue}
            $apps=Join-Path $path 'steamapps'
            if((Test-Path -LiteralPath $path -PathType Container) -and
               (Test-Path -LiteralPath $apps -PathType Container) -and
               -not $valid.Contains($path)){$valid.Add($path)}
        }
        return $valid.ToArray()
    }catch{
        Write-Log ("Ignoring invalid Steam library cache: "+$_.Exception.Message) 'WARN'
        return @()
    }
}

function Write-SteamLibraryCache {
    param([string[]]$Libraries)
    $cachePath=Get-SteamLibraryCachePath
    if(-not $cachePath){return}
    $temporary=$null
    try{
        $directory=Split-Path -Parent $cachePath
        if(-not (Test-Path -LiteralPath $directory -PathType Container)){
            [void](New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop)
        }
        $unique=@($Libraries|Where-Object{$_}|Select-Object -Unique|Select-Object -First 64)
        $json=@{SchemaVersion=1;UpdatedUtc=[DateTime]::UtcNow.ToString('o');Libraries=$unique}|ConvertTo-Json -Depth 3
        $temporary=$cachePath+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
        [IO.File]::WriteAllText($temporary,$json,(New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $cachePath -Force -ErrorAction Stop
    }catch{
        Write-Log ("Could not refresh Steam library cache: "+$_.Exception.Message) 'WARN'
    }finally{
        if($temporary -and (Test-Path -LiteralPath $temporary -PathType Leaf)){
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-SteamLibraryRoots {
    $steamInstalls = New-Object 'System.Collections.Generic.List[string]'
    $libraryRoots = New-Object 'System.Collections.Generic.List[string]'
    $seenSteam = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $seenLibrary = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    # Cached roots are only hints: each is checked again and fresh registry/VDF
    # data is still scanned so moved or newly added libraries are discovered.
    $cachedRoots=@(Read-SteamLibraryCache)
    foreach($cachedRoot in $cachedRoots){
        if($seenLibrary.Add($cachedRoot)){$libraryRoots.Add($cachedRoot)}
    }
    if($cachedRoots.Count){Write-Log ("Revalidated "+$cachedRoots.Count+' Steam library path(s) from the local cache.')}

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
        # Do not probe disconnected mapped/network drives during startup.
        if(($drive.DisplayRoot -and [string]$drive.DisplayRoot -match '^\\\\') -or
           ([string]$drive.Root -match '^\\\\')){continue}
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

    Write-SteamLibraryCache -Libraries $libraryRoots.ToArray()
    return $libraryRoots.ToArray()
}

function Find-CS2ConfigInsideInstall {
    param([Parameter(Mandatory=$true)][string]$InstallRoot)
    $root=[IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $queue=New-Object 'System.Collections.Generic.Queue[object]'
    $queue.Enqueue([pscustomobject]@{Path=$root;Depth=0})
    $visited=0
    $maxDirectories=1200
    $maxDepth=8
    while($queue.Count -gt 0 -and $visited -lt $maxDirectories){
        $current=$queue.Dequeue();$visited++
        if($current.Depth -ge $maxDepth){continue}
        try{$children=@(Get-ChildItem -LiteralPath $current.Path -Directory -Force -ErrorAction Stop)}catch{continue}
        foreach($child in $children){
            if(($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){continue}
            if($child.Name -ieq 'cfg' -and $child.Parent.Name -ieq 'csgo' -and $child.Parent.Parent.Name -ieq 'game'){
                $candidate=[IO.Path]::GetFullPath($child.FullName)
                if($candidate.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){
                    Write-Log ("Found CS2 cfg folder by bounded search inside confirmed install: "+$candidate) 'WARN'
                    return $candidate
                }
            }
            if($visited+$queue.Count -lt $maxDirectories){$queue.Enqueue([pscustomobject]@{Path=$child.FullName;Depth=($current.Depth+1)})}
        }
    }
    if($visited -ge $maxDirectories){Write-Log ("Bounded CS2 folder search stopped after "+$maxDirectories+' directories.') 'WARN'}
    return $null
}

function Get-CS2InstallFromManifest {
    param([Parameter(Mandatory=$true)][string]$LibraryRoot)
    $manifestPath=Join-Path $LibraryRoot 'steamapps\appmanifest_730.acf'
    if(-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)){return $null}
    try{
        $manifest=Get-Item -LiteralPath $manifestPath -ErrorAction Stop
        if($manifest.Length -lt 1 -or $manifest.Length -gt 262144){throw 'manifest size is unexpected'}
        $text=[IO.File]::ReadAllText($manifestPath)
        $appIdMatch=[regex]::Match($text,'(?im)^\s*"appid"\s+"(\d+)"\s*$')
        $installMatch=[regex]::Match($text,'(?im)^\s*"installdir"\s+"([^"\r\n]+)"\s*$')
        if(-not $appIdMatch.Success -or $appIdMatch.Groups[1].Value -cne '730'){
            throw 'manifest appid is missing or is not 730'
        }
        if(-not $installMatch.Success){throw 'manifest installdir is missing'}
        $installDir=$installMatch.Groups[1].Value
        if($installDir -notmatch '^[A-Za-z0-9 _.-]{1,120}$' -or $installDir -in @('.','..')){
            throw 'manifest installdir is not a safe folder name'
        }
        $common=Join-Path (Join-Path $LibraryRoot 'steamapps') 'common'
        $installRoot=[IO.Path]::GetFullPath((Join-Path $common $installDir)).TrimEnd('\')
        $commonPrefix=[IO.Path]::GetFullPath($common).TrimEnd('\')+[IO.Path]::DirectorySeparatorChar
        if(-not $installRoot.StartsWith($commonPrefix,[StringComparison]::OrdinalIgnoreCase)){
            throw 'manifest install path is outside this Steam library'
        }
        $gameRoot=Join-Path $installRoot 'game'
        $csgoRoot=Join-Path $gameRoot 'csgo'
        $binRoot=Join-Path $gameRoot 'bin'
        if(-not (Test-Path -LiteralPath $gameRoot -PathType Container) -or
           -not (Test-Path -LiteralPath $csgoRoot -PathType Container) -or
           -not (Test-Path -LiteralPath $binRoot -PathType Container)){
            throw 'expected CS2 game, game\csgo, or game\bin folder is missing'
        }
        $cfg=Join-Path $csgoRoot 'cfg'
        if(-not (Test-Path -LiteralPath $cfg -PathType Container)){
            $cfg=Find-CS2ConfigInsideInstall -InstallRoot $installRoot
        }
        if(-not $cfg){throw 'CS2 config folder was not found inside the confirmed install'}
        Write-Log ("Validated CS2 app 730 manifest "+$manifestPath+"; install="+$installRoot+"; cfg="+$cfg)
        return [pscustomobject]@{LibraryRoot=$LibraryRoot;InstallRoot=$installRoot;ManifestPath=$manifestPath;ConfigPath=$cfg}
    }catch{
        Write-Log ("Rejected CS2 install metadata in "+$manifestPath+": "+$_.Exception.Message) 'WARN'
        return $null
    }
}

function Find-CS2ConfigFolder {
    param([switch]$NoPrompt)
    $roots = @(Get-SteamLibraryRoots)
    Write-Log "Searching $($roots.Count) Steam library location(s) for a validated CS2 app 730 install."
    $installs=New-Object 'System.Collections.Generic.List[object]'
    foreach ($root in $roots) {
        $install=Get-CS2InstallFromManifest -LibraryRoot $root
        if($install){$installs.Add($install)}
    }
    if($installs.Count -eq 1){return $installs[0].ConfigPath}
    if($installs.Count -gt 1){
        $paths=@($installs|ForEach-Object{$_.ConfigPath})
        Write-Log ("Multiple validated CS2 installations found; refusing to choose automatically: "+($paths -join '; ')) 'WARN'
    }

    if ($NoPrompt) {
        if($installs.Count -gt 1){Write-Log 'CFG install skipped because the CS2 target is ambiguous. Select the intended cfg folder during an interactive install.' 'WARN'}
        else{Write-Log 'No validated CS2 app 730 installation was found; CFG install skipped. Launch CS2 once or select its cfg folder from the interactive installer.' 'WARN'}
        return $null
    }
    Write-Log 'No unique validated CS2 install was found; asking the user to select the CS2 cfg folder.' 'WARN'
    $pick = New-Object System.Windows.Forms.FolderBrowserDialog
    $pick.Description = 'Select the existing CS2 folder ending in game\csgo\cfg'
    $pick.ShowNewFolderButton = $false
    if ($pick.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    $selected = $pick.SelectedPath.TrimEnd('\')
    if (-not (Test-Path -LiteralPath $selected -PathType Container) -or
        $selected -notmatch '(?i)\\game\\csgo\\cfg$') {
        throw "Selected path is not an existing CS2 game\csgo\cfg folder: $selected"
    }
    $parent=Split-Path -Parent $selected
    if((Split-Path -Leaf $parent) -ine 'csgo' -or
       (Split-Path -Leaf (Split-Path -Parent $parent)) -ine 'game'){
        throw "Selected path does not have the expected CS2 game\csgo\cfg structure: $selected"
    }
    $confirm=[System.Windows.Forms.MessageBox]::Show(
        "Automatic detection could not select a unique verified install:`n`n$selected`n`nUse this exact folder for the CFG install?",
        'Confirm CS2 config folder',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    if($confirm -ne [System.Windows.Forms.DialogResult]::Yes){return $null}
    Write-Log ("User-selected and confirmed CS2 CFG folder: "+$selected) 'WARN'
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
                $downloadUri=Add-CafeCacheBust -Uri $source.Value
                Invoke-WebRequest -Uri $downloadUri -OutFile $downloaded -Headers @{'Cache-Control'='no-cache'} -UseBasicParsing -TimeoutSec 15 -MaximumRedirection 5 -ErrorAction Stop
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
    $candidates=New-Object 'System.Collections.Generic.List[string]'
    # Prefer the client whose ActiveProcess registry value supplied the user ID.
    # This avoids pairing an active account with another stale Steam install.
    try{
        foreach($process in @(Get-Process -Name 'steam' -ErrorAction Stop)){
            if($process.Path -and (Test-Path -LiteralPath $process.Path -PathType Leaf)){$candidates.Add($process.Path)}
        }
    }catch{}
    foreach($key in @('HKCU:\Software\Valve\Steam','HKLM:\SOFTWARE\WOW6432Node\Valve\Steam','HKLM:\SOFTWARE\Valve\Steam')){
        try{
            $props=Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            foreach($name in @('SteamExe','SteamPath','InstallPath')){
                $value=[string]$props.$name
                if([string]::IsNullOrWhiteSpace($value)){continue}
                if($name -eq 'SteamExe'){$candidate=$value}else{$candidate=Join-Path $value 'steam.exe'}
                if(Test-Path -LiteralPath $candidate -PathType Leaf){$candidates.Add($candidate)}
            }
        }catch{}
    }
    foreach($candidate in @(
        "${env:ProgramFiles(x86)}\Steam\steam.exe",
        "$env:ProgramFiles\Steam\steam.exe",
        "$env:LOCALAPPDATA\Steam\steam.exe"
    )){if($candidate){$candidates.Add($candidate)}}
    foreach ($root in @(Get-SteamLibraryRoots)) { $candidates.Add((Join-Path $root 'steam.exe')) }
    return Find-App -Paths $candidates.ToArray()
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

function Get-CafeLauncherRelease {
    $runningRelease=[string]$script:LauncherRunningRelease
    if($runningRelease -match '^\d{4}\.\d{1,2}\.\d{1,2}\.\d+$'){return $runningRelease}
    $source=[string]$env:CAFE_SCRIPT
    if([string]::IsNullOrWhiteSpace($source) -or -not(Test-Path -LiteralPath $source -PathType Leaf)){return 'unknown'}
    try{
        $pattern='(?m)^# CAFE_RELEASE=(\d{4}\.\d{1,2}\.\d{1,2}\.\d+)\s*$'
        $match=[regex]::Match([IO.File]::ReadAllText($source),$pattern)
        if($match.Success){return $match.Groups[1].Value}
    }catch{}
    return 'unknown'
}

function Get-CafeUpdateRateLimitMessage {
    param([int]$StatusCode,[string]$ResponseBody,[string]$RateLimitRemaining)
    if($StatusCode -notin @(403,429)){return $null}
    if($RateLimitRemaining -eq '0' -or $ResponseBody -match '(?i)(API rate limit exceeded|rate limit exceeded)'){
        return 'GitHub API quota limit reached. Wait for the quota to reset, then check again. The launcher was not changed.'
    }
    if($ResponseBody -match '(?i)(secondary rate limit|abuse detection|temporarily rate limited)'){
        return 'GitHub is temporarily rate-limiting requests. Wait a few minutes, then check again. The launcher was not changed.'
    }
    return $null
}

function Restart-CafeLauncherAfterUpdate {
    param([Parameter(Mandatory=$true)][string]$Path)
    try{
        if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){throw 'Updated launcher file was not found.'}
        Start-Process -FilePath $Path -ErrorAction Stop | Out-Null
        Write-Log ('Relaunching updated CafeLauncher from '+$Path+'.')
        [System.Windows.Forms.Application]::Exit()
    }catch{
        Write-Log ('Could not relaunch CafeLauncher: '+$_.Exception.Message) 'WARN'
        [void][System.Windows.Forms.MessageBox]::Show(
            "The update is installed, but CafeLauncher could not restart automatically.`n`nClose and open this file manually:`n$Path",
            'Restart CafeLauncher','OK','Warning')
    }
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
        $remote=Invoke-CafeGitHubRestMethod -Uri $uri -Headers @{'User-Agent'='CafeLauncher-Updater'; 'Accept'='application/vnd.github+json'} -TimeoutSec 8
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
        $runningReleaseText=Get-CafeLauncherRelease
        $runningRelease=if($runningReleaseText -match '^\d{4}\.\d{1,2}\.\d{1,2}\.\d+$'){[version]::Parse($runningReleaseText)}else{[version]'0.0.0.0'}
        $diskRelease=if ($localMatch.Success) { [version]::Parse($localMatch.Groups[1].Value) } else { [version]'0.0.0.0' }
        if ($remoteRelease -le $runningRelease) {
            Write-Log "CafeLauncher running release $runningRelease is current; GitHub main release is $remoteRelease."
            if ($Manual) { [System.Windows.Forms.MessageBox]::Show("CafeLauncher is current (running $runningRelease; GitHub $remoteRelease).", 'Update Check', 'OK', 'Information') | Out-Null }
            return
        }
        if (Test-LauncherIsCurrent -CurrentPath $source -RemoteBlobSha $remote.sha) {
            Write-Log "A newer release $remoteRelease is already installed at $source; this open launcher is still running $runningRelease."
            [System.Windows.Forms.MessageBox]::Show(
                "CafeLauncher release $remoteRelease is already installed at:`n$source`n`nClick OK to restart into the newer build.",
                'Newer Build Already Installed','OK','Information') | Out-Null
            Restart-CafeLauncherAfterUpdate -Path $source
            return
        }
        if($diskRelease -gt $remoteRelease){
            Write-Log "A newer local file release $diskRelease is already installed than GitHub main $remoteRelease; this open launcher is still running $runningRelease."
            [System.Windows.Forms.MessageBox]::Show(
                "A newer local CafeLauncher release ($diskRelease) is already installed at:`n$source`n`nClick OK to restart into the newer build.",
                'Newer Build Already Installed','OK','Information') | Out-Null
            Restart-CafeLauncherAfterUpdate -Path $source
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
            $updateUri=Add-CafeCacheBust -Uri 'https://raw.githubusercontent.com/fabjoncela/Cs-script/main/cafe.bat'
            Invoke-WebRequest -Uri $updateUri -OutFile $temp -Headers @{'Cache-Control'='no-cache'} -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop | Out-Null
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
                [System.Windows.Forms.MessageBox]::Show("CafeLauncher updated successfully at:`n$source`n`nClick OK to restart and use the latest version.", 'Update Installed', 'OK', 'Information') | Out-Null
                Restart-CafeLauncherAfterUpdate -Path $source
            } catch {
                $dest=Join-Path $env:USERPROFILE 'Downloads\CafeLauncher_latest.bat'
                Copy-Item -LiteralPath $temp -Destination $dest -Force -ErrorAction Stop
                Write-Log "Current BAT could not be overwritten; saved verified update to $dest" 'WARN'
                [System.Windows.Forms.MessageBox]::Show("Your original BAT could not be replaced (read-only/protected folder).`n`nA verified new copy was saved to:`n$dest`n`nOpen that copy next time.", 'Update Downloaded', 'OK', 'Warning') | Out-Null
            }
        } finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    } catch {
        $failure=$_.Exception.Message
        $statusCode=0
        $responseBody=''
        $rateLimitRemaining=''
        $responseProperty=$_.Exception.PSObject.Properties['Response']
        if($responseProperty -and $responseProperty.Value){
            $httpResponse=$responseProperty.Value
            try{$statusCode=[int]$httpResponse.StatusCode}catch{}
            try{$rateLimitRemaining=[string]$httpResponse.Headers['X-RateLimit-Remaining']}catch{}
            try{
                $responseStream=$httpResponse.GetResponseStream()
                if($responseStream){
                    $responseReader=New-Object System.IO.StreamReader($responseStream)
                    try{$responseBody=$responseReader.ReadToEnd()}finally{$responseReader.Dispose()}
                }
            }catch{}
        }
        $quotaMessage=Get-CafeUpdateRateLimitMessage -StatusCode $statusCode -ResponseBody $responseBody -RateLimitRemaining $rateLimitRemaining
        if($quotaMessage){$failure=$quotaMessage;Write-Log "Update check blocked by GitHub API rate limiting (HTTP $statusCode; remaining=$rateLimitRemaining)." 'WARN'}
        else{Write-Log "Update check/download failed; the existing launcher is unchanged where possible: $failure" 'WARN'}
        if ($Manual) { [System.Windows.Forms.MessageBox]::Show("Update check failed: $failure", 'Update Check', 'OK', 'Warning') | Out-Null }
    }
}

function Launch-All {
    param([switch]$SkipGHub)
    Start-DetectedSteam

    Launch-App -Name "FACEIT Anti-Cheat" -Paths @(
        "$env:ProgramFiles\FACEIT AC\faceitclient.exe",
        "${env:ProgramFiles(x86)}\FACEIT AC\faceitclient.exe"
    )

    Open-FaceitMatchmaking
    Open-Spotify
    if(-not $SkipGHub){
        Open-GHub
    }else{
        Write-Log 'Profile app launch: skipping Logitech G HUB; mouse DPI is handled by better-logihub.'
    }
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
# Public GitHub App client ID used only by the optional device sign-in flow.
# The corresponding app must enable device flow and repo Contents read/write.
$script:GithubDeviceFlowClientId = 'Iv23libHoHzpzAPDKmNX'
$script:FabCfgCloudUrl = 'https://raw.githubusercontent.com/fabjoncela/Cs-script/main/fab.cfg'
$script:GamingProfiles = [ordered]@{
    FabMode = @{
        PointerSpeed=10; LogitechDPI=800; DisableAcceleration=$true; ApplyNvidia=$true; ScalingMode=2
        Width=1920; Height=1080; RefreshHz=360; Vibrance=75; Hue=-1
        CS2Sensitivity=''; VoicePushToTalkKey=''; ConfigFile='fab.cfg'; CfgDownloadUrl=$script:FabCfgCloudUrl; LaunchApps=$true
    }
    ArliMode = @{
        PointerSpeed=10; LogitechDPI=800; DisableAcceleration=$true; ApplyNvidia=$true; ScalingMode=2
        Width=1920; Height=1080; RefreshHz=360; Vibrance=75; Hue=-1
        CS2Sensitivity=''; VoicePushToTalkKey=''; ConfigFile='arli.cfg'; CfgDownloadUrl='https://raw.githubusercontent.com/fabjoncela/Cs-script/main/arli.cfg'; LaunchApps=$true
    }
    BrileMode = @{
        PointerSpeed=10; LogitechDPI=800; DisableAcceleration=$true; ApplyNvidia=$true; ScalingMode=2
        Width=1920; Height=1080; RefreshHz=360; Vibrance=75; Hue=-1
        CS2Sensitivity=''; VoicePushToTalkKey=''; ConfigFile='brile.cfg'; CfgDownloadUrl='https://raw.githubusercontent.com/fabjoncela/Cs-script/main/brile.cfg'; LaunchApps=$true
    }
    ArmlMode = @{
        PointerSpeed=10; LogitechDPI=800; DisableAcceleration=$true; ApplyNvidia=$true; ScalingMode=2
        Width=1920; Height=1080; RefreshHz=360; Vibrance=75; Hue=-1
        CS2Sensitivity=''; VoicePushToTalkKey=''; ConfigFile='arml.cfg'; CfgDownloadUrl='https://raw.githubusercontent.com/fabjoncela/Cs-script/main/arml.cfg'; LaunchApps=$true
    }
    OliMode = @{
        PointerSpeed=10; LogitechDPI=800; DisableAcceleration=$true; ApplyNvidia=$true; ScalingMode=2
        Width=1920; Height=1080; RefreshHz=360; Vibrance=75; Hue=-1
        CS2Sensitivity=''; VoicePushToTalkKey=''; ConfigFile='oli.cfg'; CfgDownloadUrl='https://raw.githubusercontent.com/fabjoncela/Cs-script/main/oli.cfg'; LaunchApps=$true
    }
}
$script:ProfileSettingsPath = Join-Path $env:LOCALAPPDATA 'CafeLauncher\profiles.json'
$script:PendingSync = @{}
$script:VerifiedProfileState = @{}
$script:GraphicsPresets = [ordered]@{}
foreach ($name in @($script:GamingProfiles.Keys)) { $script:PendingSync[$name] = $false }

function ConvertTo-CafeGraphicsPreset {
    param([string]$ProfileName,$Preset)
    if(-not $script:GamingProfiles.Contains($ProfileName) -or $null -eq $Preset -or $null -eq $Preset.Settings){
        throw 'Graphics preset profile/settings are missing.'
    }
    if($Preset.ProfileName -and $Preset.ProfileName -cne $ProfileName){throw 'Graphics preset profile name mismatch.'}
    $rules=[ordered]@{
        Width=@{Min=640;Max=7680};Height=@{Min=480;Max=4320};RefreshHz=@{Min=24;Max=600}
        AspectRatioMode=@{Allowed=@(0,1,2)};Fullscreen=@{Allowed=@(0,1)};MSAASamples=@{Allowed=@(0,2,4,8,16)}
        ShadowQuality=@{Allowed=@(0,1,2,3)};DynamicShadows=@{Allowed=@(0,1)};TextureDetail=@{Allowed=@(0,1,2,3)}
        ShaderQuality=@{Allowed=@(0,1,2)};ParticleDetail=@{Allowed=@(0,1,2,3)};AmbientOcclusion=@{Allowed=@(0,1,2,3)}
        HDRDetail=@{Allowed=@(-1,0,1,2,3)};NvidiaReflex=@{Allowed=@(0,1,2)};TextureFiltering=@{Allowed=@(0,1,2,3,4,5)}
        FSRDetail=@{Allowed=@(0,1,2,3,4)};VSync=@{Allowed=@(0,1)};CMAA=@{Allowed=@(0,1)}
    }
    $settings=[ordered]@{}
    $settingsSource=$Preset.Settings
    foreach($field in $rules.Keys){
        if($settingsSource -is [System.Collections.IDictionary]){
            if(-not $settingsSource.Contains($field)){continue}
            $rawValue=$settingsSource[$field]
        }else{
            $property=$settingsSource.PSObject.Properties[$field]
            if(-not $property){continue}
            $rawValue=$property.Value
        }
        if($null -eq $rawValue){continue}
        $value=0
        if(-not [int]::TryParse([string]$rawValue,[ref]$value)){throw ('Invalid graphics value: '+$field)}
        $rule=$rules[$field]
        if(($rule.ContainsKey('Allowed') -and $value -notin $rule.Allowed) -or
           ($rule.ContainsKey('Min') -and $value -lt $rule.Min) -or
           ($rule.ContainsKey('Max') -and $value -gt $rule.Max)){throw ('Out-of-range graphics value: '+$field)}
        $settings[$field]=$value
    }
    if($settings.Contains('Width') -xor $settings.Contains('Height')){
        throw 'Graphics preset must specify both Width and Height, or neither.'
    }
    if(-not $settings.Contains('Width')){
        $settings['Width']=if($ProfileName -eq 'BrileMode'){1920}else{1280}
        $settings['Height']=if($ProfileName -eq 'BrileMode'){1080}else{960}
    }
    foreach($field in @('AspectRatioMode','Fullscreen','MSAASamples','ShadowQuality','DynamicShadows','TextureDetail','ShaderQuality','ParticleDetail','AmbientOcclusion','HDRDetail','NvidiaReflex','TextureFiltering','FSRDetail','VSync','CMAA')){
        if(-not $settings.Contains($field)){throw ('Graphics preset is missing '+$field+'.')}
    }
    $refreshPolicy=if($Preset.PSObject.Properties['RefreshPolicy'] -and $Preset.RefreshPolicy){[string]$Preset.RefreshPolicy}else{'Highest'}
    if($refreshPolicy -notin @('Highest','Exact')){throw 'RefreshPolicy must be Highest or Exact.'}
    if($refreshPolicy -eq 'Exact' -and -not $settings.Contains('RefreshHz')){throw 'Exact refresh policy requires RefreshHz.'}
    $scaling=if($Preset.PSObject.Properties['ScalingMode'] -and $null -ne $Preset.ScalingMode){[int]$Preset.ScalingMode}else{[int]$script:GamingProfiles[$ProfileName].ScalingMode}
    if($scaling -notin @(2,3,5)){throw 'ScalingMode must be 2, 3, or 5.'}
    return [pscustomobject]@{SchemaVersion=1;ProfileName=$ProfileName;DisplayPolicy='ApplyPreset';RefreshPolicy=$refreshPolicy;ScalingMode=$scaling;Settings=$settings}
}

function Get-CafeActiveSteamVideoFile {
    try{$active=Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam\ActiveProcess' -ErrorAction Stop}
    catch{throw 'Could not read Steam ActiveProcess. Sign in to Steam, then retry capture.'}
    if($null -eq $active.ActiveUser){throw 'Steam has no active signed-in account. Sign in, then retry capture.'}
    $accountNumber=0L
    if(-not [long]::TryParse([string]$active.ActiveUser,[ref]$accountNumber)){throw 'Steam returned an invalid active account ID.'}
    if($accountNumber -lt 0){$accountNumber=$accountNumber -band 4294967295L}
    if($accountNumber -le 0){throw 'Steam has no active signed-in account. Sign in, then retry capture.'}

    $steamProcesses=@(Get-Process -Name 'steam' -ErrorAction SilentlyContinue | Where-Object {$_.Path -and (Test-Path -LiteralPath $_.Path -PathType Leaf)})
    if($steamProcesses.Count -ne 1){throw 'Could not identify exactly one running Steam client. Start Steam and retry capture.'}
    $steamRoot=Split-Path -Parent ([string]$steamProcesses[0].Path)
    if([string]::IsNullOrWhiteSpace($steamRoot)){throw 'Could not determine the running Steam installation path.'}
    $accountId=$accountNumber.ToString([Globalization.CultureInfo]::InvariantCulture)
    $videoPath=Join-Path $steamRoot ('userdata\'+$accountId+'\730\local\cfg\cs2_video.txt')
    return [pscustomobject]@{Path=$videoPath;AccountID=$accountId;SteamRoot=$steamRoot}
}

function ConvertFrom-CafeCS2VideoText {
    param([Parameter(Mandatory=$true)][string]$ProfileName,[Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$true)]$BasePreset,[string]$Path,[string]$AccountID)
    if($Text -notmatch '(?m)^[ \t]*"video\.cfg"[ \t]*\r?$' -or
       $Text -notmatch '(?m)^[ \t]*\{[ \t]*\r?$' -or $Text -notmatch '(?m)^[ \t]*\}[ \t]*\r?$'){
        throw 'The active account cs2_video.txt format is not recognized; nothing was imported.'
    }
    $validatedBase=ConvertTo-CafeGraphicsPreset -ProfileName $ProfileName -Preset $BasePreset
    $settings=[ordered]@{}
    foreach($field in $validatedBase.Settings.Keys){$settings[$field]=[int]$validatedBase.Settings[$field]}
    $keyMap=[ordered]@{
        Width='setting.defaultres';Height='setting.defaultresheight';AspectRatioMode='setting.aspectratiomode';Fullscreen='setting.fullscreen'
        MSAASamples='setting.msaa_samples';ShadowQuality='setting.videocfg_shadow_quality';DynamicShadows='setting.videocfg_dynamic_shadows'
        TextureDetail='setting.videocfg_texture_detail';ShaderQuality='setting.shaderquality';ParticleDetail='setting.videocfg_particle_detail'
        AmbientOcclusion='setting.videocfg_ao_detail';HDRDetail='setting.videocfg_hdr_detail';NvidiaReflex='setting.r_low_latency'
        TextureFiltering='setting.r_texturefilteringquality';FSRDetail='setting.videocfg_fsr_detail';VSync='setting.mat_vsync';CMAA='setting.r_csgo_cmaa_enable'
    }
    $captured=New-Object 'System.Collections.Generic.List[string]'
    $missing=New-Object 'System.Collections.Generic.List[string]'
    foreach($field in $keyMap.Keys){
        $pattern='(?m)^[ \t]*"'+[regex]::Escape($keyMap[$field])+'"[ \t]+"(?<value>[^"\r\n]*)"[ \t]*(?://[^\r\n]*)?\r?$'
        $matches=[regex]::Matches($Text,$pattern)
        if($matches.Count -gt 1){throw ('Duplicate CS2 video setting: '+$keyMap[$field])}
        if($matches.Count -eq 0){$missing.Add($field);continue}
        $value=0
        if(-not [int]::TryParse($matches[0].Groups['value'].Value,[Globalization.NumberStyles]::Integer,[Globalization.CultureInfo]::InvariantCulture,[ref]$value)){
            throw ('Invalid CS2 video value for '+$keyMap[$field]+'. Nothing was imported.')
        }
        $settings[$field]=$value
        $captured.Add($field)
    }
    $numerator=0.0;$denominator=0.0
    $numeratorMatches=[regex]::Matches($Text,'(?m)^[ \t]*"setting\.refreshrate_numerator"[ \t]+"(?<value>[^"\r\n]*)"[ \t]*(?://[^\r\n]*)?\r?$')
    $denominatorMatches=[regex]::Matches($Text,'(?m)^[ \t]*"setting\.refreshrate_denominator"[ \t]+"(?<value>[^"\r\n]*)"[ \t]*(?://[^\r\n]*)?\r?$')
    if($numeratorMatches.Count -gt 1 -or $denominatorMatches.Count -gt 1){throw 'Duplicate CS2 refresh-rate value; nothing was imported.'}
    if($numeratorMatches.Count -eq 1 -and $denominatorMatches.Count -eq 1){
        $numerator=0.0;$denominator=0.0
        if(-not [double]::TryParse($numeratorMatches[0].Groups['value'].Value,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$numerator) -or
           -not [double]::TryParse($denominatorMatches[0].Groups['value'].Value,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$denominator) -or
           [double]::IsNaN($numerator) -or [double]::IsInfinity($numerator) -or $numerator -le 0 -or
           [double]::IsNaN($denominator) -or [double]::IsInfinity($denominator) -or $denominator -le 0){
            throw 'CS2 refresh-rate numerator or denominator is invalid; nothing was imported.'
        }
        $exactHz=$numerator/$denominator
        if($exactHz -lt 24 -or $exactHz -gt 600){throw 'CS2 refresh rate is outside the supported 24–600 Hz range; nothing was imported.'}
        $roundedHz=[int][Math]::Round($exactHz,0,[MidpointRounding]::AwayFromZero)
        $settings['RefreshHz']=$roundedHz
        $captured.Add('RefreshHz')
        [void]$missing.Remove('RefreshHz')
    }else{$missing.Add('RefreshHz')}

    $preset=[pscustomobject]@{
        SchemaVersion=1;ProfileName=$ProfileName;DisplayPolicy='ApplyPreset'
        RefreshPolicy=$(if($captured.Contains('RefreshHz')){'Exact'}else{$validatedBase.RefreshPolicy})
        ScalingMode=[int]$validatedBase.ScalingMode;Settings=$settings
    }
    $preset=ConvertTo-CafeGraphicsPreset -ProfileName $ProfileName -Preset $preset
    return [pscustomobject]@{
        Preset=$preset;AccountID=$AccountID;Path=$Path;CapturedFields=$captured.ToArray();MissingFields=$missing.ToArray()
        RefreshWasRounded=($captured.Contains('RefreshHz') -and [Math]::Abs(($numerator/$denominator)-[int]$settings.RefreshHz) -gt 0.000001)
    }
}

function Get-CafeCS2GraphicsCapture {
    param([Parameter(Mandatory=$true)][string]$ProfileName,[Parameter(Mandatory=$true)]$BasePreset)
    if(@(Get-Process -Name 'cs2' -ErrorAction SilentlyContinue).Count){throw 'Close CS2 after saving its settings, then capture again.'}
    $source=Get-CafeActiveSteamVideoFile
    if(-not (Test-Path -LiteralPath $source.Path -PathType Leaf)){throw ('No cs2_video.txt was found for active Steam account '+$source.AccountID+'. Launch CS2 once, save video settings, and close it before capture.')}
    $file=Get-Item -LiteralPath $source.Path -ErrorAction Stop
    if($file.Length -lt 32 -or $file.Length -gt 1048576){throw 'The active account cs2_video.txt has an implausible size; nothing was imported.'}
    $reader=New-Object System.IO.StreamReader($source.Path,$true)
    try{$text=$reader.ReadToEnd()}finally{$reader.Dispose()}
    $current=Get-CafeActiveSteamVideoFile
    if($current.AccountID -cne $source.AccountID -or $current.Path -ine $source.Path){throw 'The active Steam account changed during capture. Nothing was imported; retry.'}
    return ConvertFrom-CafeCS2VideoText -ProfileName $ProfileName -Text $text -BasePreset $BasePreset -Path $source.Path -AccountID $source.AccountID
}

# CS2 user settings captured only on demand; keyed by target profile.
$script:CapturedCS2Convars=@{}
function Get-CafeCS2UserConvarsCapture {
    param($Source)
    if(@(Get-Process -Name 'cs2' -ErrorAction SilentlyContinue).Count){throw 'Close CS2 before capture.'}
    $path=Join-Path (Split-Path -Parent $Source.Path) 'cs2_user_convars_0_slot0.vcfg'
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw ('No saved CS2 user convars for Steam account '+$Source.AccountID)}
    $file=Get-Item -LiteralPath $path -ErrorAction Stop
    if($file.Length -lt 10 -or $file.Length -gt 1048576){throw 'Invalid user convars file size.'}
    $reader=New-Object IO.StreamReader($path,$true)
    try{$content=$reader.ReadToEnd()}finally{$reader.Dispose()}
    if($content -notmatch '(?m)^\s*\{\s*$' -or $content -notmatch '(?m)^\s*\}\s*$'){throw 'Unrecognized user convars KeyValues format.'}
    $allowed=@('sensitivity','cl_crosshair_drawoutline','cl_crosshair_outlinethickness','cl_crosshair_recoil',
        'cl_crosshair_sniper_width','cl_crosshair_t','cl_crosshairalpha','cl_crosshaircolor',
        'cl_crosshaircolor_b','cl_crosshaircolor_g','cl_crosshaircolor_r','cl_crosshairdot',
        'cl_crosshairgap','cl_crosshairgap_useweaponvalue','cl_crosshairsize','cl_crosshairstyle',
        'cl_crosshairthickness','cl_crosshairusealpha','cl_crosshair_friendly_warning',
        'cl_crosshair_dynamic_maxdist_splitratio','cl_crosshair_dynamic_splitalpha_innermod',
        'cl_crosshair_dynamic_splitalpha_outermod','cl_crosshair_dynamic_splitdist')
    $values=@{}
    foreach($name in $allowed){
        $rx='(?im)^\s*"'+[regex]::Escape($name)+'"\s+"(?<v>[^"\r\n]{1,40})"\s*$'
        $matches=[regex]::Matches($content,$rx)
        if($matches.Count -gt 1){throw ('Duplicate CS2 saved '+$name+' values.')}
        if($matches.Count -eq 1){
            $value=[string]$matches[0].Groups['v'].Value
            if($value -notmatch '^(true|false|-?[0-9]+(\.[0-9]+)?)$'){throw ('Unexpected '+$name+' in convars.')}
            $values[$name]=$value
        }
    }
    $active=Get-CafeActiveSteamVideoFile
    if($active.AccountID -cne $Source.AccountID -or $active.Path -ine $Source.Path){throw 'Steam account changed during capture.'}
    return [pscustomobject]@{Values=$values;Path=$path}
}
function Set-CafeCapturedConvarsInCfg {
    param([string]$Content,$Values)
    $text=$Content
    $newline=if($text.Contains(([string][char]13+[string][char]10))){[string][char]13+[string][char]10}else{[string][char]10}
    foreach($name in @($Values.Keys|Sort-Object)){
        if($name -ne 'sensitivity' -and $name -notmatch '^cl_crosshair[a-z0-9_]*$'){continue}
        $value=[string]$Values[$name]
        if($value -notmatch '^(true|false|-?[0-9]+(\.[0-9]+)?)$'){throw ('Invalid CFG value for '+$name)}
        $rx='(?im)^[ \t]*'+[regex]::Escape($name)+'[ \t]+(?:"[^"\r\n]*"|[^\s\r\n/;]+)[ \t]*(?://[^\r\n]*)?[ \t]*(?=\r?$)'
        $matches=[regex]::Matches($text,$rx)
        if($matches.Count -gt 1){throw ('Duplicate active '+$name+' in destination CFG.')}
        $line=$name+' "'+$value+'"'
        if($matches.Count){
            $m=$matches[0]
            $text=$text.Substring(0,$m.Index)+$line+$text.Substring($m.Index+$m.Length)
        }else{
            if($text.Length -and -not $text.EndsWith([string][char]10)){$text+=$newline}
            $text+=$line+$newline
        }
    }
    return $text
}
function Get-ProfileGraphicsPreset {
    param([Parameter(Mandatory=$true)][string]$ProfileName,[switch]$Canonical,[switch]$RequireGitHub)
    if(-not $script:GamingProfiles.Contains($ProfileName)){throw ('Unknown graphics profile: '+$ProfileName)}
    if($RequireGitHub -and $script:PendingSync[$ProfileName]){
        throw ('This profile has unsynced local edits. Resolve them before refreshing its GitHub graphics preset.')
    }
    if(-not $Canonical -and $script:PendingSync[$ProfileName] -and $script:GraphicsPresets.Contains($ProfileName)){
        return $script:GraphicsPresets[$ProfileName]
    }
    $cache=Join-Path $env:LOCALAPPDATA ("CafeLauncher\graphics-cache\"+$ProfileName+'.json')
    $local=Join-Path (Split-Path -Parent $env:CAFE_SCRIPT) ("graphics\"+$ProfileName+'.json')
    try{
        $remote=Get-GitHubJsonFromContentsApi -Repo $script:GithubRepo -Branch $script:GithubBranch -Path "graphics/$ProfileName.json" -MaxBytes 1048576
        $preset=ConvertTo-CafeGraphicsPreset -ProfileName $ProfileName -Preset $remote
        if(-not $Canonical){
            $script:GraphicsPresets[$ProfileName]=$preset
            $script:GamingProfiles[$ProfileName].ScalingMode=[int]$preset.ScalingMode
        }
        try{$dir=Split-Path -Parent $cache;if(-not(Test-Path -LiteralPath $dir)){[void](New-Item -ItemType Directory -Path $dir -Force)};[IO.File]::WriteAllText($cache,($preset|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))}catch{Write-Log ('Graphics preset cache warning: '+$_.Exception.Message) 'WARN'}
        return $preset
    }catch{
        Write-Log ('Graphics preset download unavailable: '+$_.Exception.Message) 'WARN'
        if($RequireGitHub){throw ('Could not verify the latest GitHub graphics preset for '+$ProfileName+': '+$_.Exception.Message)}
    }
    foreach($file in @($cache,$local)){
        if(-not(Test-Path -LiteralPath $file -PathType Leaf)){continue}
        try{
            $raw=Get-Content -LiteralPath $file -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
            $preset=ConvertTo-CafeGraphicsPreset -ProfileName $ProfileName -Preset $raw
            if(-not $Canonical){
                $script:GraphicsPresets[$ProfileName]=$preset
                $script:GamingProfiles[$ProfileName].ScalingMode=[int]$preset.ScalingMode
            }
            return $preset
        }catch{Write-Log ('Invalid graphics preset '+$file+': '+$_.Exception.Message) 'WARN'}
    }
    if(-not $Canonical -and $script:GraphicsPresets.Contains($ProfileName)){return $script:GraphicsPresets[$ProfileName]}
    throw ('No graphics preset for '+$ProfileName+'. Connect once to download it, then local editing works offline.')
}

function ConvertTo-CafeGraphicsHistoryEntry {
    param($Commit)
    if($null -eq $Commit -or [string]$Commit.sha -notmatch '^[0-9a-fA-F]{40}$'){return $null}
    $dateText=[string]$Commit.commit.author.date
    if(-not $dateText){$dateText=[string]$Commit.commit.committer.date}
    $date=[DateTimeOffset]::MinValue
    if(-not [DateTimeOffset]::TryParse($dateText,[ref]$date)){return $null}
    $message=([string]$Commit.commit.message -split "`r?`n",2)[0].Trim()
    if(-not $message){$message='GitHub graphics update'}
    if($message.Length -gt 120){$message=$message.Substring(0,117)+'...'}
    return [pscustomobject]@{Sha=([string]$Commit.sha).ToLowerInvariant();DateUtc=$date.ToUniversalTime().ToString('o');Message=$message}
}
function Clear-ProfileGraphicsHistoryCache {
    param([Parameter(Mandatory=$true)][string]$ProfileName)
    if(-not $script:GamingProfiles.Contains($ProfileName)){throw ('Unknown graphics profile: '+$ProfileName)}
    $cache=Join-Path $env:LOCALAPPDATA ('CafeLauncher\graphics-history\'+$ProfileName+'.json')
    try{
        if(Test-Path -LiteralPath $cache -PathType Leaf){Remove-Item -LiteralPath $cache -Force -ErrorAction Stop}
    }catch{Write-Log ('Could not invalidate graphics history cache for '+$ProfileName+': '+$_.Exception.Message) 'WARN'}
}
function Get-CachedProfileGraphicsHistory {
    param([Parameter(Mandatory=$true)][string]$ProfileName)
    if(-not $script:GamingProfiles.Contains($ProfileName)){throw ('Unknown graphics profile: '+$ProfileName)}
    $cache=Join-Path $env:LOCALAPPDATA ('CafeLauncher\graphics-history\'+$ProfileName+'.json')
    if(Test-Path -LiteralPath $cache -PathType Leaf){
        try{
            $cached=Get-Content -LiteralPath $cache -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
            $cachedAt=[DateTimeOffset]::MinValue
            if([int]$cached.SchemaVersion -eq 1 -and $cached.Repo -ceq $script:GithubRepo -and
               $cached.Branch -ceq $script:GithubBranch -and $cached.ProfileName -ceq $ProfileName -and
               [DateTimeOffset]::TryParse([string]$cached.CachedAtUtc,[ref]$cachedAt)){
                $age=([DateTimeOffset]::UtcNow-$cachedAt.ToUniversalTime()).TotalHours
                if($age -ge 0 -and $age -lt 24){
                    $valid=New-Object 'System.Collections.Generic.List[object]'
                    foreach($entry in @($cached.Versions|Select-Object -First 3)){
                        $clean=ConvertTo-CafeGraphicsHistoryEntry -Commit ([pscustomobject]@{
                            sha=$entry.Sha;commit=[pscustomobject]@{message=$entry.Message;author=[pscustomobject]@{date=$entry.DateUtc}}
                        })
                        if($clean){$valid.Add($clean)}
                    }
                    return [pscustomobject]@{Found=$true;Versions=[object[]]$valid.ToArray()}
                }
            }
        }catch{Write-Log ('Ignoring invalid graphics history cache for '+$ProfileName+': '+$_.Exception.Message) 'WARN'}
    }
    return [pscustomobject]@{Found=$false;Versions=[object[]]@()}
}
function Get-ProfileGraphicsHistory {
    param([Parameter(Mandatory=$true)][string]$ProfileName,[switch]$ForceRefresh,[string]$ResponseJson)
    if(-not $script:GamingProfiles.Contains($ProfileName)){throw ('Unknown graphics profile: '+$ProfileName)}
    if(-not $ForceRefresh){
        $cached=Get-CachedProfileGraphicsHistory -ProfileName $ProfileName
        if($cached.Found){return @($cached.Versions)}
    }
    if($PSBoundParameters.ContainsKey('ResponseJson')){
        if([string]::IsNullOrWhiteSpace($ResponseJson)){throw 'GitHub returned an empty graphics history response.'}
        $response=ConvertFrom-Json -InputObject $ResponseJson -ErrorAction Stop
    }else{
        $encodedPath=[Uri]::EscapeDataString('graphics/'+$ProfileName+'.json')
        $encodedBranch=[Uri]::EscapeDataString([string]$script:GithubBranch)
        $uri='https://api.github.com/repos/'+$script:GithubRepo+'/commits?path='+$encodedPath+'&per_page=4&sha='+$encodedBranch
        $headers=@{'User-Agent'='CafeLauncher-Graphics-History';'Accept'='application/vnd.github+json'}
        $response=Invoke-CafeGitHubRestMethod -Uri $uri -Method Get -Headers $headers -TimeoutSec 12
    }
    $cache=Join-Path $env:LOCALAPPDATA ('CafeLauncher\graphics-history\'+$ProfileName+'.json')
    $versions=New-Object 'System.Collections.Generic.List[object]'
    # The newest path commit is the current version. Keep the next three older versions.
    foreach($commit in @($response|Select-Object -Skip 1 -First 3)){
        $entry=ConvertTo-CafeGraphicsHistoryEntry -Commit $commit
        if($entry){$versions.Add($entry)}
    }
    $data=[pscustomobject]@{
        SchemaVersion=1;Repo=$script:GithubRepo;Branch=$script:GithubBranch;ProfileName=$ProfileName
        CachedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');Versions=@($versions.ToArray())
    }
    try{
        $directory=Split-Path -Parent $cache
        if(-not(Test-Path -LiteralPath $directory)){[void](New-Item -ItemType Directory -Path $directory -Force)}
        [IO.File]::WriteAllText($cache,($data|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
    }catch{Write-Log ('Graphics history cache warning for '+$ProfileName+': '+$_.Exception.Message) 'WARN'}
    return @($versions.ToArray())
}
function New-CafeGraphicsHistoryWorker {
    if(-not ('CafeGraphicsHistoryBackgroundWorker' -as [type])){
        Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Net;
using System.Text;

public sealed class CafeGraphicsHistoryBackgroundWorker : BackgroundWorker {
    public string WorkerName { get { return "GraphicsHistory"; } }
    public string ResultText { get; private set; }
    public string ErrorText { get; private set; }
    public string RateLimitRemaining { get; private set; }
    public string RateLimitLimit { get; private set; }
    public int WorkerThreadId { get; private set; }
    private void CaptureRateLimit(HttpWebResponse response) {
        RateLimitRemaining = response.Headers["X-RateLimit-Remaining"];
        RateLimitLimit = response.Headers["X-RateLimit-Limit"];
    }
    public CafeGraphicsHistoryBackgroundWorker() {
        DoWork += delegate(object sender, DoWorkEventArgs e) {
            WorkerThreadId = System.Threading.Thread.CurrentThread.ManagedThreadId;
            try {
                var request = (HttpWebRequest)WebRequest.Create((string)e.Argument);
                request.Method = "GET";
                request.UserAgent = "CafeLauncher-Graphics-History";
                request.Accept = "application/vnd.github+json";
                request.Timeout = 12000;
                request.ReadWriteTimeout = 12000;
                request.Headers[HttpRequestHeader.CacheControl] = "no-cache";
                using (var response = (HttpWebResponse)request.GetResponse())
                using (var reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8)) {
                    CaptureRateLimit(response);
                    ResultText = reader.ReadToEnd();
                }
            } catch (Exception error) {
                var webError = error as WebException;
                var response = webError == null ? null : webError.Response as HttpWebResponse;
                if (response != null) {
                    using (response) { CaptureRateLimit(response); }
                }
                ErrorText = error.Message;
            }
        };
    }
}
'@
    }
    return (New-Object CafeGraphicsHistoryBackgroundWorker)
}
function Get-ProfileGraphicsVersion {
    param([Parameter(Mandatory=$true)][string]$ProfileName,[Parameter(Mandatory=$true)]$Version)
    if(-not $script:GamingProfiles.Contains($ProfileName)){throw ('Unknown graphics profile: '+$ProfileName)}
    $sha=[string]$Version.Sha
    if($sha -notmatch '^[0-9a-fA-F]{40}$'){throw 'Selected graphics history entry has an invalid commit id.'}
    $path='graphics/'+$ProfileName+'.json'
    $encodedSha=[Uri]::EscapeDataString($sha)
    $uri='https://api.github.com/repos/'+$script:GithubRepo+'/contents/'+$path+'?ref='+$encodedSha
    $headers=@{'User-Agent'='CafeLauncher-Graphics-History';'Accept'='application/vnd.github+json'}
    try{
        $response=Invoke-CafeGitHubRestMethod -Uri $uri -Method Get -Headers $headers -TimeoutSec 12
    }catch{
        $status=$null
        $responseProp=$_.Exception.PSObject.Properties['Response']
        if($responseProp -and $responseProp.Value){try{$status=[int]$responseProp.Value.StatusCode}catch{}}
        $shortSha=$sha.Substring(0,7)
        if($status -eq 404){throw ('Historical version '+$shortSha+' is no longer available on GitHub. Refresh history and choose another version.')}
        throw ('Could not download historical version '+$shortSha+': '+$_.Exception.Message)
    }
    if([string]$response.path -cne ('graphics/'+$ProfileName+'.json')){throw 'GitHub returned a different graphics profile file.'}
    $encodedContent=([string]$response.content -replace '\s','')
    if(-not $encodedContent){throw 'Selected GitHub graphics version has no file content.'}
    try{$json=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedContent))|ConvertFrom-Json -ErrorAction Stop}
    catch{throw ('Could not decode selected graphics history version: '+$_.Exception.Message)}
    return (ConvertTo-CafeGraphicsPreset -ProfileName $ProfileName -Preset $json)
}
function Import-ProfileValues {
    param([string]$ProfileName, $SavedProfile, [string]$SourceLabel = 'local')
    if (-not $script:GamingProfiles.Contains($ProfileName) -or -not $SavedProfile) { return }
    foreach ($setting in @('PointerSpeed','LogitechDPI','DisableAcceleration','ApplyNvidia','Width','Height','RefreshHz','Vibrance','Hue','ScalingMode','CS2Sensitivity','VoicePushToTalkKey','CfgDownloadUrl','LaunchApps')) {
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
                'ScalingMode'  { $value=[int]$value; if ($value -notin @(2,3,5)) { throw 'unsupported NVIDIA scaling mode' } }
                'Vibrance'     { $value=[int]$value; if ($value -lt 0 -or $value -gt 100) { throw 'range' } }
                'Hue'           { $value=[int]$value; if ($value -lt -1 -or $value -gt 359) { throw 'range' } }
                'VoicePushToTalkKey' {
                    $value=[string]$value
                    if($value -and $value -notmatch '^(?:[A-Z]|[0-9]|F(?:[1-9]|1[0-2])|MOUSE[1-5]|CAPSLOCK|ALT|SHIFT|CTRL|SPACE|TAB)$'){throw 'invalid voice key'}
                }
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
    $graphicsProperty=$SavedProfile.PSObject.Properties['GraphicsSettings']
    if($graphicsProperty -and $graphicsProperty.Value){
        try{$script:GraphicsPresets[$ProfileName]=ConvertTo-CafeGraphicsPreset -ProfileName $ProfileName -Preset $graphicsProperty.Value}
        catch{Write-Log "Ignored invalid $SourceLabel $ProfileName graphics settings: $($_.Exception.Message)" 'WARN'}
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
            $verifiedBlob=$savedProfile.Value.PSObject.Properties['GitHubVerifiedProfileSha']
            $verifiedCommit=$savedProfile.Value.PSObject.Properties['GitHubVerifiedCommitSha']
            if($verifiedBlob -and [string]$verifiedBlob.Value -match '^[a-fA-F0-9]{40}$' -and
               $verifiedCommit -and [string]$verifiedCommit.Value -match '^[a-fA-F0-9]{40}$'){
                $script:VerifiedProfileState[$name]=@{BlobSha=[string]$verifiedBlob.Value;CommitSha=[string]$verifiedCommit.Value}
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
        RefreshHz=[int]$p.RefreshHz; Vibrance=[int]$p.Vibrance; Hue=[int]$p.Hue; ScalingMode=[int]$p.ScalingMode
        CS2Sensitivity=[string]$p.CS2Sensitivity; VoicePushToTalkKey=[string]$p.VoicePushToTalkKey; CfgDownloadUrl=[string]$p.CfgDownloadUrl
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
        if($script:GraphicsPresets.Contains($name)){
            $snapshot['GraphicsSettings']=$script:GraphicsPresets[$name]
        }
        $snapshot['SyncPending'] = [bool]$script:PendingSync[$name]
        if($script:VerifiedProfileState.ContainsKey($name)){
            $snapshot['GitHubVerifiedProfileSha']=[string]$script:VerifiedProfileState[$name].BlobSha
            $snapshot['GitHubVerifiedCommitSha']=[string]$script:VerifiedProfileState[$name].CommitSha
        }
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

function Add-CafeCacheBust {
    param([Parameter(Mandatory=$true)][string]$Uri)
    $separator=if($Uri.Contains('?')){'&'}else{'?'}
    return ($Uri+$separator+'fresh='+[guid]::NewGuid().ToString('N'))
}

function Get-GitHubJsonFromContentsApi {
    param(
        [Parameter(Mandatory=$true)][string]$Repo,
        [Parameter(Mandatory=$true)][string]$Branch,
        [Parameter(Mandatory=$true)][string]$Path,
        [int64]$MaxBytes=65536,
        [switch]$IncludeMetadata
    )
    if($Path -notmatch '^(profiles|graphics)/[A-Za-z0-9_-]+\.json$' -or $MaxBytes -lt 1 -or $MaxBytes -gt 1048576){
        throw 'GitHub JSON path or size limit is invalid.'
    }
    $encodedBranch=[Uri]::EscapeDataString($Branch)
    $encodedPath=(($Path -split '/')|ForEach-Object{[Uri]::EscapeDataString($_)}) -join '/'
    $url="https://api.github.com/repos/$Repo/contents/${encodedPath}?ref=$encodedBranch"
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $headers=@{
        Accept='application/vnd.github+json'
        'User-Agent'='CafeLauncher-ProfileRefresh'
        'X-GitHub-Api-Version'='2022-11-28'
        'Cache-Control'='no-cache'
        Pragma='no-cache'
    }
    # The raw-content CDN served old profile data even with a unique query.
    # Read mutable profile/graphics JSON through the API; callers keep their
    # local copy if this request fails rather than falling back to raw CDN.
    $file = Invoke-CafeGitHubRestMethod -Uri $url -Method Get -Headers $headers -TimeoutSec 12 -MaximumRedirection 0
    if($file.type -ne 'file' -or $file.path -cne $Path -or
       $file.encoding -ne 'base64' -or [string]$file.sha -notmatch '^[a-fA-F0-9]{40}$' -or
       [string]::IsNullOrWhiteSpace([string]$file.content) -or [int64]$file.size -gt $MaxBytes){
        throw "GitHub returned invalid file metadata for $Path."
    }
    $profileJson=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([string]$file.content -replace '\s','')))
    $remote=ConvertFrom-Json -InputObject $profileJson -ErrorAction Stop
    $expectedName=[IO.Path]::GetFileNameWithoutExtension($Path)
    if ($remote.ProfileName -cne $expectedName -or [int]$remote.SchemaVersion -ne 1) {
        throw "Unexpected JSON profile/schema for $Path."
    }
    if($IncludeMetadata){return [pscustomobject]@{Profile=$remote;BlobSha=[string]$file.sha}}
    return $remote
}

function Get-LatestGitHubFileCommit {
    param([Parameter(Mandatory=$true)][string]$Repo,[Parameter(Mandatory=$true)][string]$Branch,
        [Parameter(Mandatory=$true)][string]$Path)
    if($Path -notmatch '^(profiles|graphics)/[A-Za-z0-9_-]+\.json$'){throw 'GitHub commit path is invalid.'}
    $encodedBranch=[Uri]::EscapeDataString($Branch)
    $encodedPath=[Uri]::EscapeDataString($Path)
    $uri="https://api.github.com/repos/$Repo/commits?path=$encodedPath&per_page=1&sha=$encodedBranch"
    $headers=@{Accept='application/vnd.github+json';'User-Agent'='CafeLauncher-ProfileRefresh';'X-GitHub-Api-Version'='2022-11-28';'Cache-Control'='no-cache';Pragma='no-cache'}
    $commits=@(Invoke-CafeGitHubRestMethod -Uri $uri -Method Get -Headers $headers -TimeoutSec 12 -MaximumRedirection 0)
    if($commits.Count -lt 1 -or [string]$commits[0].sha -notmatch '^[a-fA-F0-9]{40}$'){
        throw "GitHub did not return a valid latest commit for $Path."
    }
    return [string]$commits[0].sha
}

function Compare-GitHubCommitOrder {
    param([Parameter(Mandatory=$true)][string]$Repo,[Parameter(Mandatory=$true)][string]$BaseSha,
        [Parameter(Mandatory=$true)][string]$HeadSha)
    if($BaseSha -notmatch '^[a-fA-F0-9]{40}$' -or $HeadSha -notmatch '^[a-fA-F0-9]{40}$'){
        throw 'GitHub commit comparison requires two full commit SHAs.'
    }
    $uri="https://api.github.com/repos/$Repo/compare/$BaseSha...$HeadSha"
    $headers=@{Accept='application/vnd.github+json';'User-Agent'='CafeLauncher-ProfileRefresh';'X-GitHub-Api-Version'='2022-11-28';'Cache-Control'='no-cache';Pragma='no-cache'}
    $comparison=Invoke-CafeGitHubRestMethod -Uri $uri -Method Get -Headers $headers -TimeoutSec 12 -MaximumRedirection 0
    $status=[string]$comparison.status
    if($status -notin @('ahead','behind','identical','diverged')){throw 'GitHub returned an invalid commit comparison status.'}
    return $status
}

function Refresh-ProfileFromGitHub {
    param([Parameter(Mandatory=$true)][string]$ProfileName,[switch]$NoSave,[switch]$ForceLoad)
    if (-not $script:GamingProfiles.Contains($ProfileName)) { throw "Unknown profile: $ProfileName" }
    if ($script:PendingSync[$ProfileName]) {
        Write-Log "$ProfileName profile refresh: decision=local-pending; remote was not checked; keeping localPointer=$($script:GamingProfiles[$ProfileName].PointerSpeed)." 'INFO'
        return 'LocalPending'
    }
    $path="profiles/$ProfileName.json"
    $latestCommit=$null
    $priorPointer=[string]$script:GamingProfiles[$ProfileName].PointerSpeed
    $verifiedState=$script:VerifiedProfileState[$ProfileName]
    try {
        # Every refresh checks the latest commit touching the profile, even on
        # a fresh install with no local verification metadata. Load by immutable
        # commit SHA so a stale mutable branch response cannot win over GitHub.
        $latestCommit=Get-LatestGitHubFileCommit -Repo $script:GithubRepo -Branch $script:GithubBranch -Path $path
        if($verifiedState -and $latestCommit -ceq $verifiedState.CommitSha -and -not $ForceLoad){
            Write-Log "$ProfileName profile refresh: decision=verified-cache; repo=$script:GithubRepo; branch=$script:GithubBranch; path=$path; latestCommit=$latestCommit; verifiedCommit=$($verifiedState.CommitSha); pointer=$priorPointer. Using values verified from this commit."
            return 'VerifiedGitHub'
        }
        if($verifiedState -and $latestCommit -cne $verifiedState.CommitSha){
            $commitOrder=Compare-GitHubCommitOrder -Repo $script:GithubRepo -BaseSha $verifiedState.CommitSha -HeadSha $latestCommit
            if($commitOrder -eq 'behind'){
                Write-Log "$ProfileName profile refresh: decision=ignore-stale-ancestor; repo=$script:GithubRepo; branch=$script:GithubBranch; path=$path; latestCommit=$latestCommit; verifiedCommit=$($verifiedState.CommitSha); comparison=$commitOrder; pointer=$priorPointer. Keeping verified settings." 'WARN'
                return 'VerifiedGitHub'
            }
            if($commitOrder -eq 'diverged'){
                Write-Log "$ProfileName profile refresh: decision=refuse-diverged-history; repo=$script:GithubRepo; branch=$script:GithubBranch; path=$path; latestCommit=$latestCommit; verifiedCommit=$($verifiedState.CommitSha); comparison=$commitOrder; pointer=$priorPointer. Keeping local settings." 'WARN'
                return 'LocalFallback'
            }
            if($commitOrder -ne 'ahead'){throw 'GitHub commit order could not be verified.'}
        }
        $remoteRead=Get-GitHubJsonFromContentsApi -Repo $script:GithubRepo -Branch $latestCommit -Path $path -IncludeMetadata
        $remote=$remoteRead.Profile
        $script:VerifiedProfileState[$ProfileName]=@{BlobSha=[string]$remoteRead.BlobSha;CommitSha=$latestCommit}
        $remotePointer=[string]$remote.PointerSpeed
        $priorCommit=if($verifiedState){[string]$verifiedState.CommitSha}else{'none'}
        Write-Log "$ProfileName profile refresh: decision=loaded-remote; repo=$script:GithubRepo; branch=$script:GithubBranch; path=$path; latestCommit=$latestCommit; priorVerifiedCommit=$priorCommit; blobSha=$($remoteRead.BlobSha); pointerBefore=$priorPointer; pointerLoaded=$remotePointer."
        Import-ProfileValues -ProfileName $ProfileName -SavedProfile $remote -SourceLabel 'GitHub'
        if(-not $NoSave){try { Save-ProfileSettings } catch { Write-Log "Unable to cache cloud settings: $($_.Exception.Message)" 'WARN' }}
        Write-Log "$ProfileName settings loaded from GitHub commit $latestCommit (no login needed)."
        return 'GitHub'
    } catch {
        $verifiedCommitForLog=if($verifiedState){[string]$verifiedState.CommitSha}else{'none'}
        $candidateForLog=if($latestCommit){[string]$latestCommit}else{'unavailable'}
        Write-Log "$ProfileName profile refresh: decision=local-fallback; repo=$script:GithubRepo; branch=$script:GithubBranch; path=$path; latestCommit=$candidateForLog; verifiedCommit=$verifiedCommitForLog; pointerKept=$priorPointer; error=$($_.Exception.Message)" 'WARN'
        return 'LocalFallback'
    }
}

function Confirm-LocalProfileApply {
    param([Parameter(Mandatory=$true)][string]$ProfileName,[Parameter(Mandatory=$true)][string]$Source,
        [ValidateSet('apply','edit')][string]$Action='apply')
    if($Source -notin @('LocalPending','LocalFallback')){return $true}
    $reason=if($Source -eq 'LocalPending'){
        'This profile has local changes that have not been synced to GitHub.'
    }else{
        'CafeLauncher could not verify the latest profile on GitHub.'
    }
    $verb=if($Action -eq 'edit'){'Opening the editor'}else{'Applying now'}
    $message="$reason`r`n`r`n$verb will use the local saved values, which may be older than GitHub. Choose Yes to continue with local values, or No to cancel and try again when GitHub is available."
    $answer=[System.Windows.Forms.MessageBox]::Show($message,'Confirm local profile settings','YesNo','Warning','Button2')
    if($answer -eq [System.Windows.Forms.DialogResult]::Yes){
        Write-Log "$ProfileName local settings apply explicitly confirmed ($Source)." 'WARN'
        return $true
    }
    Write-Log "$ProfileName apply canceled; local settings were not applied because GitHub priority could not be confirmed." 'INFO'
    return $false
}

function Resolve-PendingProfileChanges {
    param([Parameter(Mandatory=$true)][string]$ProfileName)
    if(-not $script:PendingSync[$ProfileName]){return $true}
    $message="$ProfileName has local profile and/or CS2 graphics edits that are not synced to GitHub.`r`n`r`nYes = Sync these local edits to GitHub, then continue.`r`nNo = Discard them and download the latest profile and graphics from GitHub.`r`nCancel = leave everything unchanged."
    $choice=[System.Windows.Forms.MessageBox]::Show($message,'Resolve unsynced profile edits','YesNoCancel','Warning','Button3')
    if($choice -eq [System.Windows.Forms.DialogResult]::Cancel){Write-Log "$ProfileName action canceled; unsynced local edits were kept.";return $false}
    if($choice -eq [System.Windows.Forms.DialogResult]::Yes){
        $authorization=$null;$token=$null
        try{
            $authorization=Get-GitHubSyncAuthorization -OwnerWindow $form
            if($null -eq $authorization -or [string]::IsNullOrWhiteSpace([string]$authorization.Token)){
                Write-Log "$ProfileName action canceled; GitHub authorization was not completed." 'WARN'
                return $false
            }
            if($authorization.Method -eq 'GitHub device sign-in'){
                $confirm=[System.Windows.Forms.MessageBox]::Show(
                    ('Sync these local edits using GitHub account @'+$authorization.Login+'?'),
                    'Confirm GitHub account','YesNo','Question')
                if($confirm -ne [System.Windows.Forms.DialogResult]::Yes){return $false}
            }
            $token=[string]$authorization.Token
            $authorization.Token=$null
            Sync-ProfileToGitHub -ProfileName $ProfileName -Token $token
            $script:PendingSync[$ProfileName]=$false
            Save-ProfileSettings
            Write-Log "$ProfileName pending local profile and graphics edits synced and read-back verified before continuing."
            return $true
        }catch{
            Write-Log "$ProfileName could not sync pending edits; action canceled and local edits remain pending. $($_.Exception.Message)" 'ERROR'
            [void][System.Windows.Forms.MessageBox]::Show(
                ("Could not sync $ProfileName. The local edits remain saved and pending; no action was applied.`n`n"+$_.Exception.Message),
                'Profile Sync Required','OK','Warning')
            return $false
        }finally{$token=$null;$authorization=$null}
    }

    # Discard only after both current GitHub files have been fetched and
    # validated. Restore the local state if either read fails.
    $profileBefore=@{}
    foreach($key in $script:GamingProfiles[$ProfileName].Keys){$profileBefore[$key]=$script:GamingProfiles[$ProfileName][$key]}
    $graphicsBefore=$script:GraphicsPresets[$ProfileName]
    $verifiedBefore=$script:VerifiedProfileState[$ProfileName]
    try{
        $script:PendingSync[$ProfileName]=$false
        $profileSource=Refresh-ProfileFromGitHub -ProfileName $ProfileName -NoSave -ForceLoad
        if($profileSource -notin @('GitHub','VerifiedGitHub')){throw 'The latest GitHub profile could not be verified.'}
        [void](Get-ProfileGraphicsPreset -ProfileName $ProfileName -RequireGitHub)
        Save-ProfileSettings
        Write-Log "$ProfileName unsynced edits discarded only after the latest GitHub profile and graphics files were verified."
        return $true
    }catch{
        foreach($key in @($script:GamingProfiles[$ProfileName].Keys)){[void]$script:GamingProfiles[$ProfileName].Remove($key)}
        foreach($key in $profileBefore.Keys){$script:GamingProfiles[$ProfileName][$key]=$profileBefore[$key]}
        if($graphicsBefore){$script:GraphicsPresets[$ProfileName]=$graphicsBefore}else{$script:GraphicsPresets.Remove($ProfileName)}
        if($verifiedBefore){$script:VerifiedProfileState[$ProfileName]=$verifiedBefore}else{$script:VerifiedProfileState.Remove($ProfileName)}
        $script:PendingSync[$ProfileName]=$true
        Write-Log "$ProfileName could not discard local edits because GitHub refresh failed; local values remain pending. $($_.Exception.Message)" 'ERROR'
        [void][System.Windows.Forms.MessageBox]::Show(
            ("Could not load current GitHub settings for $ProfileName. Local edits were kept and no action was applied.`n`n"+$_.Exception.Message),
            'GitHub Refresh Failed','OK','Warning')
        return $false
    }
}

function Get-GitHubSyncPersonalToken {
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

function New-CafeGitHubDeviceFlowWorker {
    param([Parameter(Mandatory=$true)][string]$ClientId,[Parameter(Mandatory=$true)][string]$Repository)
    if(-not ('CafeGitHubDeviceFlowWorker' -as [type])){
        $serializationPath=Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'System.Runtime.Serialization.dll'
        [void][Reflection.Assembly]::LoadFrom($serializationPath)
        [void](Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;

[DataContract]
public sealed class CafeGitHubRepositoryPermissions {
    [DataMember(Name="push")] public bool Push { get; set; }
}

[DataContract]
public sealed class CafeGitHubResponse {
    [DataMember(Name="device_code")] public string DeviceCode { get; set; }
    [DataMember(Name="user_code")] public string UserCode { get; set; }
    [DataMember(Name="verification_uri")] public string VerificationUri { get; set; }
    [DataMember(Name="expires_in")] public int ExpiresIn { get; set; }
    [DataMember(Name="interval")] public int Interval { get; set; }
    [DataMember(Name="error")] public string Error { get; set; }
    [DataMember(Name="access_token")] public string AccessToken { get; set; }
    [DataMember(Name="login")] public string Login { get; set; }
    [DataMember(Name="full_name")] public string FullName { get; set; }
    [DataMember(Name="permissions")] public CafeGitHubRepositoryPermissions Permissions { get; set; }
}

public sealed class CafeGitHubDeviceFlowWorker : BackgroundWorker {
    private readonly string clientId;
    private readonly string repository;
    public string UserCode { get; private set; }
    public string VerificationUri { get; private set; }
    public string AuthenticatedLogin { get; private set; }
    public string AccessToken { get; private set; }
    public string ErrorText { get; private set; }
    public string RateLimitRemaining { get; private set; }
    public string RateLimitLimit { get; private set; }

    public CafeGitHubDeviceFlowWorker(string clientId, string repository) {
        this.clientId = clientId;
        this.repository = repository;
        WorkerReportsProgress = true;
        WorkerSupportsCancellation = true;
        DoWork += RunDeviceFlow;
    }

    public string TakeAccessToken() {
        string token = AccessToken;
        AccessToken = null;
        return token;
    }

    public void ClearAccessToken() { AccessToken = null; }

    private void CaptureRateLimit(HttpWebResponse response) {
        RateLimitRemaining = response.Headers["X-RateLimit-Remaining"];
        RateLimitLimit = response.Headers["X-RateLimit-Limit"];
    }

    private static CafeGitHubResponse ReadJson(HttpWebResponse response) {
        using (var stream = response.GetResponseStream())
            return (CafeGitHubResponse)new DataContractJsonSerializer(typeof(CafeGitHubResponse)).ReadObject(stream);
    }

    private static CafeGitHubResponse Request(string url, string method, string[,] form, string token, CafeGitHubDeviceFlowWorker owner) {
        var request = (HttpWebRequest)WebRequest.Create(url);
        request.Method = method;
        request.UserAgent = "CafeLauncher-GitHub-Device-Login";
        bool isApi = url.StartsWith("https://api.github.com/", StringComparison.OrdinalIgnoreCase);
        request.Accept = isApi ? "application/vnd.github+json" : "application/json";
        if (isApi) request.Headers["X-GitHub-Api-Version"] = "2022-11-28";
        request.Timeout = 12000;
        request.ReadWriteTimeout = 12000;
        if (!String.IsNullOrEmpty(token)) request.Headers[HttpRequestHeader.Authorization] = "Bearer " + token;
        if (form != null) {
            request.ContentType = "application/x-www-form-urlencoded";
            var pairs = new string[form.GetLength(0)];
            for (int i=0;i<form.GetLength(0);i++)
                pairs[i] = Uri.EscapeDataString(form[i,0]) + "=" + Uri.EscapeDataString(form[i,1]);
            byte[] bytes = Encoding.UTF8.GetBytes(String.Join("&", pairs));
            request.ContentLength = bytes.Length;
            using (var stream = request.GetRequestStream()) stream.Write(bytes, 0, bytes.Length);
        }
        try {
            using (var response = (HttpWebResponse)request.GetResponse()) {
                if (isApi && owner != null) owner.CaptureRateLimit(response);
                return ReadJson(response);
            }
        } catch (WebException error) {
            var response = error.Response as HttpWebResponse;
            if (isApi && owner != null && response != null) {
                using (response) { owner.CaptureRateLimit(response); }
            }
            throw;
        }
    }

    private void RunDeviceFlow(object sender, DoWorkEventArgs e) {
        try {
            var form = new string[,] { { "client_id", clientId }, { "scope", "offline_access" } };
            var code = Request("https://github.com/login/device/code", "POST", form, null, this);
            string deviceCode = code.DeviceCode;
            UserCode = code.UserCode;
            VerificationUri = code.VerificationUri;
            int expires = code.ExpiresIn;
            int interval = Math.Max(1, code.Interval);
            if (String.IsNullOrEmpty(deviceCode) || String.IsNullOrEmpty(UserCode) ||
                VerificationUri != "https://github.com/login/device" || expires < 1 || expires > 1800)
                throw new InvalidOperationException("GitHub returned an invalid device-login response.");
            ReportProgress(1, new string[] { VerificationUri, UserCode });

            var deadline = DateTime.UtcNow.AddSeconds(expires);
            while (DateTime.UtcNow < deadline) {
                int waitMs = interval * 1000;
                while (waitMs > 0) {
                    if (CancellationPending) { e.Cancel = true; return; }
                    int slice = Math.Min(waitMs, 250);
                    Thread.Sleep(slice);
                    waitMs -= slice;
                }
                var tokenForm = new string[,] {
                    { "client_id", clientId },
                    { "device_code", deviceCode },
                    { "grant_type", "urn:ietf:params:oauth:grant-type:device_code" }
                };
                var result = Request("https://github.com/login/oauth/access_token", "POST", tokenForm, null, this);
                string error = result.Error;
                if (error == "authorization_pending") continue;
                if (error == "slow_down") { interval += 5; continue; }
                if (!String.IsNullOrEmpty(error)) throw new InvalidOperationException("GitHub sign-in failed: " + error.Replace('_', ' ') + ".");
                string token = result.AccessToken;
                if (String.IsNullOrEmpty(token)) throw new InvalidOperationException("GitHub did not return an access token.");
                if (result.ExpiresIn < 1)
                    throw new InvalidOperationException("GitHub did not issue an expiring token. Enable token expiration for the GitHub App and try again.");

                var user = Request("https://api.github.com/user", "GET", null, token, this);
                AuthenticatedLogin = user.Login;
                if (String.IsNullOrEmpty(AuthenticatedLogin)) throw new InvalidOperationException("Could not verify the GitHub account returned by sign-in.");
                // Confirm this account can at least access the exact repository before returning the token.
                var repo = Request("https://api.github.com/repos/" + repository, "GET", null, token, this);
                if (!String.Equals(repo.FullName, repository, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("The signed-in account cannot access the CafeLauncher repository.");
                if (repo.Permissions == null || !repo.Permissions.Push)
                    throw new InvalidOperationException("The signed-in account does not have verified write access to the CafeLauncher repository. Grant it repository write access and try again.");
                if (CancellationPending) { e.Cancel = true; return; }
                AccessToken = token;
                return;
            }
            throw new TimeoutException("The GitHub device code expired. Start sign-in again.");
        } catch (Exception error) {
            ErrorText = error.Message;
        }
    }
}
'@ -ReferencedAssemblies @('System.dll','System.Runtime.Serialization.dll','System.Xml.dll'))
    }
    return [CafeGitHubDeviceFlowWorker]::new($ClientId,$Repository)
}

function Get-GitHubDeviceAuthorization {
    param($OwnerWindow)
    if([string]::IsNullOrWhiteSpace([string]$script:GithubDeviceFlowClientId)){
        [void][System.Windows.Forms.MessageBox]::Show(
            'GitHub sign-in is not configured yet. Register a GitHub App with device flow enabled, Contents read/write permission, repository access, and expiring user tokens; then add its public Client ID to CafeLauncher.',
            'GitHub sign-in setup','OK','Information')
        return $null
    }
    $worker=New-CafeGitHubDeviceFlowWorker -ClientId $script:GithubDeviceFlowClientId -Repository $script:GithubRepo
    $authForm=New-Object System.Windows.Forms.Form
    $authForm.Text='Sign in to GitHub'
    $authForm.ClientSize=New-Object System.Drawing.Size(560,260)
    $authForm.StartPosition='CenterParent'
    $authForm.FormBorderStyle='FixedDialog'
    $authForm.MaximizeBox=$false
    $authForm.MinimizeBox=$false
    $authForm.BackColor=$PANEL
    $authForm.ForeColor=$WHITE
    $authForm.Font=New-Object System.Drawing.Font('Segoe UI',10)
    $instructions=New-Object System.Windows.Forms.Label
    $instructions.Text='On your phone or another trusted device, open github.com/login/device and enter this one-time code:'
    $instructions.Location=New-Object System.Drawing.Point(20,18)
    $instructions.Size=New-Object System.Drawing.Size(520,52)
    $authForm.Controls.Add($instructions)
    $codeBox=New-Object System.Windows.Forms.TextBox
    $codeBox.ReadOnly=$true
    $codeBox.Text='Requesting code from GitHub...'
    $codeBox.Font=New-Object System.Drawing.Font('Consolas',18,[System.Drawing.FontStyle]::Bold)
    $codeBox.TextAlign='Center'
    $codeBox.Location=New-Object System.Drawing.Point(20,76)
    $codeBox.Size=New-Object System.Drawing.Size(300,42)
    $authForm.Controls.Add($codeBox)
    $copyCode=New-Object System.Windows.Forms.Button
    $copyCode.Text='Copy code'
    $copyCode.Location=New-Object System.Drawing.Point(335,76)
    $copyCode.Size=New-Object System.Drawing.Size(100,42)
    $copyCode.Enabled=$false
    $copyCode.Add_Click({if($codeBox.Text -match '^[A-Z0-9-]{6,16}$'){[System.Windows.Forms.Clipboard]::SetText($codeBox.Text)}})
    $authForm.Controls.Add($copyCode)
    $openLink=New-Object System.Windows.Forms.Button
    $openLink.Text='Open GitHub here'
    $openLink.Location=New-Object System.Drawing.Point(20,128)
    $openLink.Size=New-Object System.Drawing.Size(160,34)
    $openLink.Enabled=$false
    $openLink.Add_Click({Start-Process 'https://github.com/login/device'})
    $authForm.Controls.Add($openLink)
    $status=New-Object System.Windows.Forms.Label
    $status.Text='Waiting for GitHub authorization...'
    $status.Location=New-Object System.Drawing.Point(195,130)
    $status.Size=New-Object System.Drawing.Size(345,35)
    $authForm.Controls.Add($status)
    $cancel=New-Object System.Windows.Forms.Button
    $cancel.Text='Cancel'
    $cancel.Location=New-Object System.Drawing.Point(420,200)
    $cancel.Size=New-Object System.Drawing.Size(120,36)
    $cancel.DialogResult=[System.Windows.Forms.DialogResult]::Cancel
    $cancel.Add_Click({if($worker.IsBusy){$worker.CancelAsync()}}.GetNewClosure())
    $authForm.Controls.Add($cancel)
    $authForm.CancelButton=$cancel
    $authorizationState=[pscustomobject]@{Result=$null}
    $worker.Add_ProgressChanged({
        if($authForm.IsDisposed){return}
        if($worker.UserCode){$codeBox.Text=$worker.UserCode;$copyCode.Enabled=$true;$openLink.Enabled=$true}
        $status.Text='Waiting for you to approve access on GitHub...'
    }.GetNewClosure())
    $worker.Add_RunWorkerCompleted({
        if($authForm.IsDisposed){$worker.ClearAccessToken();return}
        if($worker.RateLimitRemaining){
            Set-CafeGitHubRateLimitDisplay -Remaining ([string]$worker.RateLimitRemaining) `
                -Limit ([string]$worker.RateLimitLimit)
        }
        if($worker.Cancelled){$status.Text='GitHub sign-in canceled.';return}
        if($worker.ErrorText){
            Write-Log ('GitHub device sign-in failed: '+$worker.ErrorText) 'WARN'
            [void][System.Windows.Forms.MessageBox]::Show($worker.ErrorText,'GitHub sign-in','OK','Warning')
            $authForm.DialogResult=[System.Windows.Forms.DialogResult]::Cancel
            $authForm.Close();return
        }
        $token=$worker.TakeAccessToken()
        if([string]::IsNullOrWhiteSpace($token)){
            $status.Text='GitHub did not return an access token.'
            $authForm.DialogResult=[System.Windows.Forms.DialogResult]::Cancel
            $authForm.Close();return
        }
        $authorizationState.Result=[pscustomobject]@{Token=$token;Method='GitHub device sign-in';Login=[string]$worker.AuthenticatedLogin}
        $status.Text=('Signed in as '+$worker.AuthenticatedLogin+'.')
        $authForm.DialogResult=[System.Windows.Forms.DialogResult]::OK
        $authForm.Close()
    }.GetNewClosure())
    try{
        $worker.RunWorkerAsync()
        [void]$authForm.ShowDialog($OwnerWindow)
        return $authorizationState.Result
    }finally{
        if($worker.IsBusy){$worker.CancelAsync()}
        $worker.ClearAccessToken()
        $authForm.Dispose()
    }
}

function Get-GitHubSyncAuthorization {
    param($OwnerWindow)
    $chooser=New-Object System.Windows.Forms.Form
    $chooser.Text='Choose GitHub sync method'
    $chooser.ClientSize=New-Object System.Drawing.Size(500,190)
    $chooser.StartPosition='CenterParent'
    $chooser.FormBorderStyle='FixedDialog'
    $chooser.MaximizeBox=$false
    $chooser.MinimizeBox=$false
    $chooser.BackColor=$PANEL
    $chooser.ForeColor=$WHITE
    $chooser.Font=New-Object System.Drawing.Font('Segoe UI',10)
    $label=New-Object System.Windows.Forms.Label
    $label.Text='Choose how to authorize this sync. CafeLauncher will not save either credential.'
    $label.Location=New-Object System.Drawing.Point(20,18)
    $label.Size=New-Object System.Drawing.Size(460,45)
    $chooser.Controls.Add($label)
    $tokenButton=New-Object System.Windows.Forms.Button
    $tokenButton.Text='Use a token'
    $tokenButton.Location=New-Object System.Drawing.Point(20,78)
    $tokenButton.Size=New-Object System.Drawing.Size(205,42)
    $tokenButton.BackColor=$BLUE
    $tokenButton.ForeColor=$WHITE
    $chooser.Controls.Add($tokenButton)
    $deviceButton=New-Object System.Windows.Forms.Button
    $deviceButton.Text='Sign in with GitHub'
    $deviceButton.Location=New-Object System.Drawing.Point(245,78)
    $deviceButton.Size=New-Object System.Drawing.Size(235,42)
    $deviceButton.BackColor=[System.Drawing.Color]::FromArgb(38,132,102)
    $deviceButton.ForeColor=$WHITE
    $chooser.Controls.Add($deviceButton)
    $cancel=New-Object System.Windows.Forms.Button
    $cancel.Text='Cancel'
    $cancel.Location=New-Object System.Drawing.Point(360,138)
    $cancel.Size=New-Object System.Drawing.Size(120,34)
    $cancel.DialogResult=[System.Windows.Forms.DialogResult]::Cancel
    $chooser.Controls.Add($cancel)
    $chooser.CancelButton=$cancel
    $authorizationState=[pscustomobject]@{Value=$null}
    $tokenButton.Add_Click({
        $token=Get-GitHubSyncPersonalToken -OwnerWindow $chooser
        if(-not [string]::IsNullOrWhiteSpace($token)){
            $authorizationState.Value=[pscustomobject]@{Token=$token;Method='Personal access token';Login='not verified'}
            $chooser.DialogResult=[System.Windows.Forms.DialogResult]::OK
            $chooser.Close()
        }
    }.GetNewClosure())
    $deviceButton.Add_Click({
        $authorization=Get-GitHubDeviceAuthorization -OwnerWindow $chooser
        if($authorization){$authorizationState.Value=$authorization;$chooser.DialogResult=[System.Windows.Forms.DialogResult]::OK;$chooser.Close()}
    }.GetNewClosure())
    try{
        if($chooser.ShowDialog($OwnerWindow) -ne [System.Windows.Forms.DialogResult]::OK){return $null}
        return $authorizationState.Value
    }finally{$chooser.Dispose()}
}

function Get-CafeVoiceBindingFromCfg {
    param([string]$Content)
    $matches=[regex]::Matches($Content,'(?im)^[ \t]*bind[ \t]+"?(?<key>[A-Z0-9_]+)"?[ \t]+"?\+voicerecord"?[ \t]*(?://[^\r\n]*)?$')
    if($matches.Count -gt 1){throw 'Multiple voice binds in CFG. Resolve manually.'}
    if($matches.Count -eq 0){return ''}
    return [string]$matches[0].Groups['key'].Value.ToUpperInvariant()
}
function Set-CafeVoiceBindingInCfg {
    param([string]$Content,[string]$Key)
    $key=$Key.Trim().ToUpperInvariant()
    if($key -notmatch '^(?:[A-Z]|[0-9]|F(?:[1-9]|1[0-2])|MOUSE[1-5]|CAPSLOCK|ALT|SHIFT|CTRL|SPACE|TAB)$'){throw 'Unsupported voice key.'}
    $old=Get-CafeVoiceBindingFromCfg -Content $Content
    if($old -ceq $key){return $Content}
    $collision=[regex]::Matches($Content,'(?im)^[ \t]*bind[ \t]+"?'+[regex]::Escape($key)+'"?[ \t]+(?:"[^"\r\n]*"|[^\r\n]+)$')
    if($collision.Count){throw ('New voice key '+$key+' is already bound in CFG. Choose another key.')}
    $rx='(?im)^[ \t]*bind[ \t]+"?[A-Z0-9_]+"?[ \t]+"?\+voicerecord"?[ \t]*(?://[^\r\n]*)?$'
    $line='bind "'+$key+'" "+voicerecord"'
    if($old){$m=[regex]::Match($Content,$rx);return $Content.Substring(0,$m.Index)+$line+$Content.Substring($m.Index+$m.Length)}
    $nl=if($Content.Contains(([string][char]13+[string][char]10))){[string][char]13+[string][char]10}else{[string][char]10}
    return $Content+$(if($Content.EndsWith([string][char]10)){''}else{$nl})+$line+$nl
}
function Get-CafeGitHubVoiceBinding {
    param([string]$CfgName)
    $url="https://api.github.com/repos/$($script:GithubRepo)/contents/$CfgName"+'?ref='+[Uri]::EscapeDataString([string]$script:GithubBranch)
    $remote=Invoke-CafeGitHubRestMethod -Uri $url -Method Get -Headers @{'Accept'='application/vnd.github+json';'User-Agent'='CafeLauncher-VoiceBinding'} -TimeoutSec 12 -MaximumRedirection 0
    if($remote.type -ne 'file' -or $remote.path -cne $CfgName -or $remote.encoding -ne 'base64' -or [int64]$remote.size -gt 2097152){throw 'Invalid CFG metadata.'}
    $text=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([string]$remote.content -replace '\s','')))
    return Get-CafeVoiceBindingFromCfg -Content $text
}
# Replace the active CS2 sensitivity command without changing binds or comments.
function Set-CS2CfgSensitivityText {
    param([Parameter(Mandatory=$true)][string]$Content,
          [Parameter(Mandatory=$true)][string]$Sensitivity)
    $number=0.0
    if($Sensitivity -notmatch '^(?:[0-9]+(?:\.[0-9]+)?)$' -or
        -not [double]::TryParse($Sensitivity,[Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,[ref]$number) -or
        $number -le 0 -or $number -gt 20){
        throw 'CFG sensitivity must be greater than 0 and at most 20.'
    }
    $pattern='(?im)^(?<indent>[ \t]*)sensitivity[ \t]+(?:"[^"\r\n]*"|[0-9]+(?:\.[0-9]+)?)(?<tail>[ \t]*(?://[^\r\n]*)?)[ \t]*(?=\r?$)'
    $matches=[regex]::Matches($Content,$pattern)
    if($matches.Count -gt 1){throw 'Multiple active CFG sensitivity commands; please resolve them manually.'}
    if($matches.Count -eq 1){
        $m=$matches[0]
        $line=$m.Groups['indent'].Value+'sensitivity "'+$Sensitivity+'"'+$m.Groups['tail'].Value
        return $Content.Substring(0,$m.Index)+$line+$Content.Substring($m.Index+$m.Length)
    }
    $newline=if($Content.Contains(([string][char]13+[string][char]10))){
        [string][char]13+[string][char]10
    }else{[string][char]10}
    $separator=if($Content.Length -eq 0 -or $Content.EndsWith([string][char]10)){''}else{$newline}
    return $Content+$separator+'sensitivity "'+$Sensitivity+'"'+$newline
}

function Sync-ProfileToGitHub {
    param([Parameter(Mandatory=$true)][string]$ProfileName, [Parameter(Mandatory=$true)][string]$Token)
    if (-not $script:GamingProfiles.Contains($ProfileName)) { throw "Unknown profile: $ProfileName" }
    $cfgName=[string]$script:GamingProfiles[$ProfileName].ConfigFile
    $expectedCfg=(($ProfileName -replace 'Mode$','').ToLowerInvariant()+'.cfg')
    if($cfgName -ne $expectedCfg -or $cfgName -notmatch '^[a-z0-9_-]+\.cfg$'){
        throw ('Refusing to modify unexpected CFG filename: '+$cfgName)
    }
    $path = "profiles/$ProfileName.json"
    $uri = "https://api.github.com/repos/$($script:GithubRepo)/contents/$path"
    $graphicsPath="graphics/$ProfileName.json"
    $graphicsUri="https://api.github.com/repos/$($script:GithubRepo)/contents/$graphicsPath"
    $headers = @{
        'Authorization'="Bearer $Token"
        'Accept'='application/vnd.github+json'
        'User-Agent'='CafeLauncher-ProfileSync'
        'X-GitHub-Api-Version'='2022-11-28'
        'Cache-Control'='no-cache'
        Pragma='no-cache'
    }
    $existingSha = $null
    $existingGraphicsSha=$null
    $currentGraphics=$null
    $graphicsUploaded=$false
    $profileUploaded=$false
    $cfgBody=$null
    $cfgUploaded=$false
    $readbackFailed=$false
    $cfgStatus='left unchanged (no sensitivity or captured crosshair)'
    $capturedConvars=$null
    if($script:CapturedCS2Convars.ContainsKey($ProfileName)){$capturedConvars=$script:CapturedCS2Convars[$ProfileName]}
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try {
        $current = Invoke-CafeGitHubRestMethod -Uri ($uri + '?ref=' + $script:GithubBranch) -Method Get -Headers $headers -TimeoutSec 20 -MaximumRedirection 0
        $existingSha = [string]$current.sha
    } catch {
        $status = $null
        $responseProp=$_.Exception.PSObject.Properties['Response']
        if($responseProp -and $responseProp.Value){$status=[int]$responseProp.Value.StatusCode}
        if ($status -ne 404) { throw "GitHub authorization or file read failed (HTTP $status)." }
    }

    try {
        $currentGraphics=Invoke-CafeGitHubRestMethod -Uri ($graphicsUri+'?ref='+$script:GithubBranch) -Method Get -Headers $headers -TimeoutSec 20 -MaximumRedirection 0
        if($currentGraphics.type -ne 'file' -or $currentGraphics.path -ne $graphicsPath -or
           [string]$currentGraphics.sha -notmatch '^[a-fA-F0-9]{40}$' -or
           $currentGraphics.encoding -ne 'base64' -or [string]::IsNullOrWhiteSpace([string]$currentGraphics.content) -or
           [int64]$currentGraphics.size -gt 1048576){throw ('Invalid GitHub graphics metadata for '+$graphicsPath)}
        $existingGraphicsSha=[string]$currentGraphics.sha
    }catch{
        $status=$null
        $responseProp=$_.Exception.PSObject.Properties['Response']
        if($responseProp -and $responseProp.Value){$status=[int]$responseProp.Value.StatusCode}
        if($status -ne 404){throw ('GitHub graphics preset read failed (HTTP '+$status+'): '+$_.Exception.Message)}
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
    $graphicsPreset=Get-ProfileGraphicsPreset -ProfileName $ProfileName
    $graphicsPreset=ConvertTo-CafeGraphicsPreset -ProfileName $ProfileName -Preset $graphicsPreset
    $graphicsPayload=[ordered]@{
        SchemaVersion=1;ProfileName=$ProfileName;DisplayPolicy='ApplyPreset'
        RefreshPolicy=[string]$graphicsPreset.RefreshPolicy;ScalingMode=[int]$graphicsPreset.ScalingMode
        Settings=$graphicsPreset.Settings
    }
    $graphicsJson=$graphicsPayload|ConvertTo-Json -Depth 6
    $graphicsChanged=$true
    if($currentGraphics){
        try{
            $currentGraphicsJson=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([string]$currentGraphics.content -replace '\s','')))|ConvertFrom-Json -ErrorAction Stop
            $currentGraphicsPreset=ConvertTo-CafeGraphicsPreset -ProfileName $ProfileName -Preset $currentGraphicsJson
            $currentGraphicsPayload=[ordered]@{
                SchemaVersion=1;ProfileName=$ProfileName;DisplayPolicy='ApplyPreset'
                RefreshPolicy=[string]$currentGraphicsPreset.RefreshPolicy;ScalingMode=[int]$currentGraphicsPreset.ScalingMode
                Settings=$currentGraphicsPreset.Settings
            }
            $graphicsChanged=(($currentGraphicsPayload|ConvertTo-Json -Depth 6 -Compress) -cne ($graphicsPayload|ConvertTo-Json -Depth 6 -Compress))
        }catch{
            # Replace a malformed/older file with the validated editor preset.
            $graphicsChanged=$true
        }
    }
    $graphicsBody=@{
        message="Update $ProfileName CS2 graphics preset from CafeLauncher"
        content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($graphicsJson+"`n"))
        branch=$script:GithubBranch
    }
    if($existingGraphicsSha){$graphicsBody.sha=$existingGraphicsSha}
    # Stage a matching CFG update after validating its path, blob metadata, and SHA.
    # Empty sensitivity means "use the CFG's value" and does not edit the CFG.
    $sensValue=[string]$values['CS2Sensitivity']
    $voiceKey=[string]$values['VoicePushToTalkKey']
    if(-not [string]::IsNullOrWhiteSpace($sensValue) -or $voiceKey -or ($capturedConvars -and $capturedConvars.Count -gt 0)){
        $cfgUri="https://api.github.com/repos/$($script:GithubRepo)/contents/$cfgName"
        $cfgRemote=Invoke-CafeGitHubRestMethod -Uri ($cfgUri+'?ref='+$script:GithubBranch) -Method Get -Headers $headers -TimeoutSec 20 -MaximumRedirection 0
        if($cfgRemote.type -ne 'file' -or $cfgRemote.path -ne $cfgName -or
            $cfgRemote.encoding -ne 'base64' -or
            [string]$cfgRemote.sha -notmatch '^[a-fA-F0-9]{40}$' -or
            [string]::IsNullOrWhiteSpace([string]$cfgRemote.content) -or
            [int64]$cfgRemote.size -gt 2097152){
            throw ('Invalid GitHub CFG metadata, cannot safely sync '+$cfgName)
        }
        $cfgText=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([string]$cfgRemote.content -replace '\s','')))
        $newCfgText=$cfgText
        if($capturedConvars -and $capturedConvars.Count -gt 0){$newCfgText=Set-CafeCapturedConvarsInCfg -Content $newCfgText -Values $capturedConvars}
        if(-not [string]::IsNullOrWhiteSpace($sensValue)){$newCfgText=Set-CS2CfgSensitivityText -Content $newCfgText -Sensitivity $sensValue}
        if($voiceKey){$newCfgText=Set-CafeVoiceBindingInCfg -Content $newCfgText -Key $voiceKey}
        if($newCfgText -cne $cfgText){
            $cfgBody=@{
                message="Sync $cfgName CS2 sensitivity and crosshair from CafeLauncher"
                content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($newCfgText))
                branch=$script:GithubBranch
                sha=[string]$cfgRemote.sha
            }
        }else{$cfgStatus='already has the requested sensitivity'}
    }
    try {
        if($cfgBody){
            $cfgResponse=Invoke-CafeGitHubRestMethod -Uri $cfgUri -Method Put -Headers $headers -ContentType 'application/json' -Body ($cfgBody | ConvertTo-Json -Depth 5 -Compress) -TimeoutSec 25 -MaximumRedirection 0
            if(-not $cfgResponse.commit.sha){throw ('CFG write was not confirmed for '+$cfgName)}
            $cfgUploaded=$true
            if($voiceKey){
                $voiceReadUrl=$cfgUri+'?ref='+[Uri]::EscapeDataString([string]$script:GithubBranch)+'&fresh='+[guid]::NewGuid().ToString('N')
                $voiceRead=Invoke-CafeGitHubRestMethod -Uri $voiceReadUrl -Method Get -Headers $headers -TimeoutSec 20 -MaximumRedirection 0
                if($voiceRead.type -ne 'file' -or $voiceRead.path -cne $cfgName -or $voiceRead.encoding -ne 'base64' -or [int64]$voiceRead.size -gt 2097152){throw 'GitHub voice binding read-back metadata was invalid.'}
                $voiceText=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([string]$voiceRead.content -replace '\s','')))
                if((Get-CafeVoiceBindingFromCfg -Content $voiceText) -cne $voiceKey){throw 'GitHub did not confirm the requested push-to-talk binding.'}
            }
            $cfgStatus="updated CS2 sensitivity/crosshair"
            Write-Log ("GitHub CFG sensitivity saved to "+$cfgName+"; commit="+$cfgResponse.commit.sha)
        }
        $result = Invoke-CafeGitHubRestMethod -Uri $uri -Method Put -Headers $headers -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 5 -Compress) -TimeoutSec 25 -MaximumRedirection 0
        if (-not $result.commit.sha) { throw 'GitHub did not return a successful commit.' }
        $profileUploaded=$true
        if($graphicsChanged){
            $graphicsResult=Invoke-CafeGitHubRestMethod -Uri $graphicsUri -Method Put -Headers $headers -ContentType 'application/json' -Body ($graphicsBody|ConvertTo-Json -Depth 6 -Compress) -TimeoutSec 25 -MaximumRedirection 0
            if(-not $graphicsResult.commit.sha){throw ('GitHub did not confirm '+$graphicsPath+' update.')}
            $graphicsUploaded=$true
            Clear-ProfileGraphicsHistoryCache -ProfileName $ProfileName
        }

        # A successful PUT response confirms a commit, but read the committed
        # files back before declaring sync complete or allowing local edits to
        # lose their pending state. Use authenticated, no-cache Contents API reads.
        $readbackFailed=$true
        $fresh=[guid]::NewGuid().ToString('N')
        $profileReadUrl=$uri+'?ref='+[Uri]::EscapeDataString([string]$script:GithubBranch)+'&fresh='+$fresh
        $remoteProfile=Invoke-CafeGitHubRestMethod -Uri $profileReadUrl -Method Get -Headers $headers -TimeoutSec 20 -MaximumRedirection 0
        if($remoteProfile.type -ne 'file' -or $remoteProfile.path -cne $path -or
           $remoteProfile.encoding -ne 'base64' -or [string]$remoteProfile.sha -notmatch '^[a-fA-F0-9]{40}$' -or
           [string]::IsNullOrWhiteSpace([string]$remoteProfile.content) -or [int64]$remoteProfile.size -gt 65536){
            throw ('GitHub returned invalid profile read-back metadata for '+$path)
        }
        $remoteProfileJson=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([string]$remoteProfile.content -replace '\s','')))
        $verifiedProfile=ConvertFrom-Json -InputObject $remoteProfileJson -ErrorAction Stop
        if($verifiedProfile.ProfileName -cne $ProfileName -or [int]$verifiedProfile.SchemaVersion -ne 1){
            throw ('GitHub profile read-back identity/schema did not match '+$ProfileName)
        }
        foreach($key in @($values.Keys)){
            $remoteProperty=$verifiedProfile.PSObject.Properties[$key]
            if(-not $remoteProperty){throw ('GitHub profile read-back is missing '+$key)}
            $expectedValue=ConvertTo-Json -InputObject $values[$key] -Compress -Depth 5
            $actualValue=ConvertTo-Json -InputObject $remoteProperty.Value -Compress -Depth 5
            if($actualValue -cne $expectedValue){throw ('GitHub profile read-back mismatch for '+$key)}
        }

        $graphicsReadUrl=$graphicsUri+'?ref='+[Uri]::EscapeDataString([string]$script:GithubBranch)+'&fresh='+$fresh
        $remoteGraphics=Invoke-CafeGitHubRestMethod -Uri $graphicsReadUrl -Method Get -Headers $headers -TimeoutSec 20 -MaximumRedirection 0
        if($remoteGraphics.type -ne 'file' -or $remoteGraphics.path -cne $graphicsPath -or
           $remoteGraphics.encoding -ne 'base64' -or [string]$remoteGraphics.sha -notmatch '^[a-fA-F0-9]{40}$' -or
           [string]::IsNullOrWhiteSpace([string]$remoteGraphics.content) -or [int64]$remoteGraphics.size -gt 1048576){
            throw ('GitHub returned invalid graphics read-back metadata for '+$graphicsPath)
        }
        $remoteGraphicsJson=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(([string]$remoteGraphics.content -replace '\s','')))
        $verifiedGraphics=ConvertTo-CafeGraphicsPreset -ProfileName $ProfileName -Preset (ConvertFrom-Json -InputObject $remoteGraphicsJson -ErrorAction Stop)
        $verifiedGraphicsPayload=[ordered]@{
            SchemaVersion=1;ProfileName=$ProfileName;DisplayPolicy='ApplyPreset'
            RefreshPolicy=[string]$verifiedGraphics.RefreshPolicy;ScalingMode=[int]$verifiedGraphics.ScalingMode
            Settings=$verifiedGraphics.Settings
        }
        if(($verifiedGraphicsPayload|ConvertTo-Json -Depth 6 -Compress) -cne ($graphicsPayload|ConvertTo-Json -Depth 6 -Compress)){
            throw ('GitHub graphics read-back does not match the selected preset in '+$graphicsPath)
        }

        # Adopt the verified remote snapshot before the caller clears SyncPending
        # and persists the local profile file.
        foreach($key in @($values.Keys)){
            $verifiedProperty=$verifiedProfile.PSObject.Properties[$key]
            $script:GamingProfiles[$ProfileName][$key]=$verifiedProperty.Value
        }
        $script:GraphicsPresets[$ProfileName]=$verifiedGraphics
        $script:GamingProfiles[$ProfileName].ScalingMode=[int]$verifiedGraphics.ScalingMode
        if($script:CapturedCS2Convars.ContainsKey($ProfileName)){[void]$script:CapturedCS2Convars.Remove($ProfileName)}
        $script:VerifiedProfileState[$ProfileName]=@{BlobSha=[string]$remoteProfile.sha;CommitSha=[string]$result.commit.sha}
        $readbackFailed=$false
        if($graphicsChanged){
            Write-Log ("GitHub sync and read-back verified: "+$path+" and "+$graphicsPath+"; "+$cfgName+" "+$cfgStatus+"; profile commit="+$result.commit.sha+"; graphics commit="+$graphicsResult.commit.sha)
        }else{
            Write-Log ("GitHub sync and read-back verified: "+$path+" updated; "+$graphicsPath+" already matched the selected preset; no redundant graphics revision created.")
        }
    } catch {
        $status = $null
        $responseProp=$_.Exception.PSObject.Properties['Response']
        if($responseProp -and $responseProp.Value){$status=[int]$responseProp.Value.StatusCode}
        $detail=if ($status -eq 401 -or $status -eq 403) {
            'GitHub refused the token. Check Contents: Read and write permission.'
        } elseif($status -eq 409 -or $status -eq 422) {
            'GitHub file versions changed; reload and retry.'
        } else { $_.Exception.Message }
        if($readbackFailed){
            throw ("GitHub accepted the upload, but read-back verification failed. Local settings remain pending; retry Save & Sync. "+$detail)
        }
        if($cfgUploaded -or $profileUploaded){
            $savedFiles=New-Object 'System.Collections.Generic.List[string]'
            $remainingFiles=New-Object 'System.Collections.Generic.List[string]'
            if($cfgUploaded){$savedFiles.Add($cfgName)}elseif($cfgBody){$remainingFiles.Add($cfgName)}
            if($profileUploaded){$savedFiles.Add($path)}else{$remainingFiles.Add($path)}
            if($graphicsUploaded){$savedFiles.Add($graphicsPath)}elseif($graphicsChanged){$remainingFiles.Add($graphicsPath)}
            throw ("PARTIAL SYNC: saved ["+($savedFiles -join ', ')+"]. Not confirmed ["+($remainingFiles -join ', ') +"]. Retry Save & Sync. "+$detail)
        }
        throw ("GitHub sync failed; neither file was confirmed updated. "+$detail)
    } finally {
        $headers.Authorization = $null
        $body.content = $null
        if($cfgBody){$cfgBody.content=$null}
        if($graphicsBody){$graphicsBody.content=$null}
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

# A closed dropdown must never steal mouse-wheel scrolling from the editor tab.
# Implement this in WinForms rather than relying on PowerShell MouseWheel handlers:
# by the time those handlers run, ComboBox may already have changed selection.
if (-not ('CafeEditorScrollComboBox' -as [type])) {
    Add-Type -ReferencedAssemblies @('System.Windows.Forms','System.Drawing') -TypeDefinition @'
using System;
using System.Drawing;
using System.Windows.Forms;

public sealed class CafeEditorScrollComboBox : ComboBox {
    protected override void OnMouseWheel(MouseEventArgs e) {
        if (this.DroppedDown) {
            base.OnMouseWheel(e);
            return;
        }
        for (Control control = this.Parent; control != null; control = control.Parent) {
            ScrollableControl container = control as ScrollableControl;
            if (container == null || !container.AutoScroll || !container.VerticalScroll.Visible) continue;
            int lines = SystemInformation.MouseWheelScrollLines;
            int amount = lines < 0 ? container.VerticalScroll.LargeChange :
                Math.Max(1, lines) * Math.Max(16, container.VerticalScroll.SmallChange);
            int current = -container.AutoScrollPosition.Y;
            int upper = Math.Max(0, container.VerticalScroll.Maximum - container.VerticalScroll.LargeChange + 1);
            int next = Math.Max(0, Math.Min(upper, current - (e.Delta * amount / 120)));
            container.AutoScrollPosition = new Point(-container.AutoScrollPosition.X, next);
            return;
        }
        // Intentionally ignore wheel on a closed combo if no scrollable parent exists.
    }
}
'@
}

# Field controls live in isolated table cells: labels can never cover adjacent inputs.
function New-EditorTabGrid {
    param($Page,[int]$Rows)
    $grid=New-Object System.Windows.Forms.TableLayoutPanel
    $grid.Dock='Top'
    $grid.AutoSize=$true
    $grid.AutoSizeMode='GrowAndShrink'
    $grid.ColumnCount=2
    $grid.RowCount=$Rows
    $grid.Padding=New-Object System.Windows.Forms.Padding(10,12,10,10)
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent',50)))
    [void]$grid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent',50)))
    for($i=0;$i -lt $Rows;$i++){
        [void]$grid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute',75)))
    }
    $Page.Controls.Add($grid)
    return $grid
}
function Add-EditorTabField {
    param($Grid,[string]$Title,$Control,[int]$Column,[int]$Row)
    $cell=New-Object System.Windows.Forms.TableLayoutPanel
    $cell.Dock='Fill'
    $cell.ColumnCount=1
    $cell.RowCount=2
    $cell.Margin=New-Object System.Windows.Forms.Padding(7,4,7,4)
    [void]$cell.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute',28)))
    [void]$cell.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent',100)))
    $caption=New-Object System.Windows.Forms.Label
    $caption.Text=$Title
    $caption.ForeColor=$WHITE
    $caption.Dock='Fill'
    $caption.AutoEllipsis=$true
    $caption.Font=New-Object System.Drawing.Font('Segoe UI',9)
    $cell.Controls.Add($caption,0,0)
    $Control.Dock='Fill'
    $Control.Margin=New-Object System.Windows.Forms.Padding(0,0,0,3)
    $cell.Controls.Add($Control,0,1)
    $Grid.Controls.Add($cell,$Column,$Row)
    return $cell
}
function New-EditorTabNumber {
    param($Grid,[string]$Title,[int]$Column,[int]$Row,[int]$Min,[int]$Max,[int]$Value)
    $numeric=New-Object System.Windows.Forms.NumericUpDown
    $numeric.Minimum=[decimal]$Min
    $numeric.Maximum=[decimal]$Max
    $numeric.Value=[decimal]$Value
    [void](Add-EditorTabField -Grid $Grid -Title $Title -Control $numeric -Column $Column -Row $Row)
    return $numeric
}
function New-EditorTabChoice {
    param($Grid,[string]$Title,[int]$Column,[int]$Row,[string[]]$Labels,[object[]]$Values,[object]$SelectedValue)
    if($Labels.Count -ne $Values.Count -or $Labels.Count -lt 1){throw 'Choice control options are invalid.'}
    $choice=New-Object CafeEditorScrollComboBox
    $choice.DropDownStyle='DropDownList'
    [void]$choice.Items.AddRange([object[]]$Labels)
    $choice.Tag=$Values
    $choice.SelectedIndex=0
    for($i=0;$i -lt $Values.Count;$i++){
        if([string]$Values[$i] -ceq [string]$SelectedValue){$choice.SelectedIndex=$i;break}
    }
    [void](Add-EditorTabField -Grid $Grid -Title $Title -Control $choice -Column $Column -Row $Row)
    return $choice
}
function Set-EditorTabChoiceValue {
    param([System.Windows.Forms.ComboBox]$Choice,[object]$Value)
    for($i=0;$i -lt $Choice.Tag.Count;$i++){
        if([string]$Choice.Tag[$i] -ceq [string]$Value){$Choice.SelectedIndex=$i;return}
    }
    throw ('The editor does not support choice value '+$Value+'.')
}
function Add-EditorTabWide {
    param($Grid,$Control,[int]$Row)
    $Control.Dock='Fill'
    $Control.Margin=New-Object System.Windows.Forms.Padding(13,9,13,5)
    $Control.AutoSize=$false
    $Grid.Controls.Add($Control,0,$Row)
    $Grid.SetColumnSpan($Control,2)
}

function Show-ProfileEditor {
    param([Parameter(Mandatory=$true)][string]$ProfileName,[switch]$CaptureOnOpen)
    if(-not $script:GamingProfiles.Contains($ProfileName)){throw "Unknown profile: $ProfileName"}
    if(-not (Resolve-PendingProfileChanges -ProfileName $ProfileName)){return}
    $profileSource=Refresh-ProfileFromGitHub -ProfileName $ProfileName
    if(-not (Confirm-LocalProfileApply -ProfileName $ProfileName -Source $profileSource -Action edit)){return}
    try{
        $graphicsPreset=Get-ProfileGraphicsPreset -ProfileName $ProfileName -RequireGitHub
    }catch{
        try{$localGraphics=Get-ProfileGraphicsPreset -ProfileName $ProfileName}catch{
            [void][System.Windows.Forms.MessageBox]::Show(
                ("GitHub graphics could not be refreshed and no valid local preset is available:`n"+$_.Exception.Message),
                'CS2 Graphics Unavailable','OK','Warning')
            return
        }
        $message="CafeLauncher could not verify the latest GitHub CS2 graphics preset for $ProfileName.`r`n`r`nUse the available local graphics copy anyway? It may be older than GitHub.`r`n`r`nYes = open using local graphics; No = cancel."
        $answer=[System.Windows.Forms.MessageBox]::Show($message,'Confirm local CS2 graphics','YesNo','Warning','Button2')
        if($answer -ne [System.Windows.Forms.DialogResult]::Yes){return}
        $graphicsPreset=$localGraphics
        Write-Log "$ProfileName editor using explicitly confirmed local CS2 graphics after GitHub refresh failed." 'WARN'
    }
    $p = $script:GamingProfiles[$ProfileName]
    if (-not $p) { throw "Unknown profile: $ProfileName" }
    # GetNewClosure() creates a new dynamic module scope. The script: scope
    # inside a captured click handler is NOT the original launcher's script:
    # scope. Capture a reference to the real pending-sync dictionary here.
    $pendingSyncState = $script:PendingSync
    $graphicsPresetState = $script:GraphicsPresets
    if ($null -eq $pendingSyncState -or $pendingSyncState -isnot [System.Collections.IDictionary]) {
        throw 'Profile sync state is missing; cannot safely edit this profile.'
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "EDITING: $ProfileName - CafeLauncher"
    $dialog.ClientSize = New-Object System.Drawing.Size(740,600)
    $dialog.MinimumSize = New-Object System.Drawing.Size(740,620)
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'Sizable'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.BackColor = $BG
    $dialog.ForeColor = $WHITE
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI',10)
    $script:EditorTextColor = $WHITE

    # A docked layout and per-field cells prevent labels from painting over
    # neighboring numeric boxes at 100%, 125% and 150% Windows display scaling.
    $editorRoot = New-Object System.Windows.Forms.TableLayoutPanel
    $editorRoot.Dock = 'Fill'
    $editorRoot.ColumnCount = 1
    $editorRoot.RowCount = 3
    [void]$editorRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute',76)))
    [void]$editorRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent',100)))
    [void]$editorRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute',136)))
    $dialog.Controls.Add($editorRoot)

    $intro = New-Object System.Windows.Forms.Panel
    $intro.Dock='Fill'
    $intro.Padding=New-Object System.Windows.Forms.Padding(20,12,20,0)
    $editorRoot.Controls.Add($intro,0,0)
    $introTitle=New-Object System.Windows.Forms.Label
    $introTitle.Text="EDITING: $($ProfileName.ToUpperInvariant())"
    $introTitle.Dock='Top'
    $introTitle.Height=32
    $introTitle.Font=New-Object System.Drawing.Font('Segoe UI',17,[System.Drawing.FontStyle]::Bold)
    $introTitle.ForeColor=$script:ProfileAccentColors[$ProfileName]
    $intro.Controls.Add($introTitle)
    $introSubtitle=New-Object System.Windows.Forms.Label
    $introSubtitle.Text='Mouse, NVIDIA/display, CS2 and app preferences'
    $introSubtitle.Dock='Bottom'
    $introSubtitle.Height=23
    $introSubtitle.ForeColor=$MUTED
    $introSubtitle.Font=New-Object System.Drawing.Font('Segoe UI',9)
    $intro.Controls.Add($introSubtitle)

    $editorTabs=New-Object System.Windows.Forms.TabControl
    $editorTabs.Dock='Fill'
    $editorTabs.Margin=New-Object System.Windows.Forms.Padding(17,0,17,3)
    $editorRoot.Controls.Add($editorTabs,0,1)
    $mousePage=New-Object System.Windows.Forms.TabPage
    $mousePage.Text='Mouse'
    $displayPage=New-Object System.Windows.Forms.TabPage
    $displayPage.Text='NVIDIA / Display'
    $cs2Page=New-Object System.Windows.Forms.TabPage
    $cs2Page.Text='CS2 / Apps'
    foreach($page in @($mousePage,$displayPage,$cs2Page)){
        $page.BackColor=$PANEL
        $page.ForeColor=$WHITE
        $page.AutoScroll=$true
        [void]$editorTabs.TabPages.Add($page)
    }

    $mouseGrid=New-EditorTabGrid -Page $mousePage -Rows 3
    $pointerSpeedValues=@(1,2,4,6,8,10,12,14,16,18,20)
    $pointerSpeedLabels=@(
        '1/11 - Slowest (1)';'2/11 (2)';'3/11 (4)';'4/11 (6)';'5/11 (8)';
        '6/11 - Default (10)';'7/11 (12)';'8/11 (14)';'9/11 (16)';'10/11 (18)';'11/11 - Fastest (20)'
    )
    $pointerSpeedOriginalValue=[int]$p.PointerSpeed
    $pointerSpeedSelectedIndex=[Array]::IndexOf([int[]]$pointerSpeedValues,$pointerSpeedOriginalValue)
    if($pointerSpeedSelectedIndex -lt 0){
        $pointerSpeedSelectedIndex=0
        $pointerSpeedDistance=[int]::MaxValue
        for($i=0;$i -lt $pointerSpeedValues.Count;$i++){
            $distance=[Math]::Abs([int]$pointerSpeedValues[$i]-$pointerSpeedOriginalValue)
            if($distance -lt $pointerSpeedDistance){$pointerSpeedDistance=$distance;$pointerSpeedSelectedIndex=$i}
        }
    }
    $pointer=New-EditorTabChoice -Grid $mouseGrid -Title 'Windows pointer speed (11 levels)' -Column 0 -Row 0 -Labels $pointerSpeedLabels -Values $pointerSpeedValues -SelectedValue $pointerSpeedValues[$pointerSpeedSelectedIndex]
    $pointerSpeedSelectionState=@{UserChanged=$false}
    $pointer.add_SelectionChangeCommitted({$pointerSpeedSelectionState.UserChanged=$true}.GetNewClosure())
    $logitechDpi=New-EditorTabNumber -Grid $mouseGrid -Title 'Logitech DPI (live, per profile)' -Column 1 -Row 0 -Min 100 -Max 25600 -Value ([int]$p.LogitechDPI)
    $logitechDpi.Increment=50
    $accel=New-Object System.Windows.Forms.CheckBox
    $accel.Text='Enable Windows mouse acceleration (EPP)'
    $accel.Checked= -not [bool]$p.DisableAcceleration
    Add-EditorTabWide -Grid $mouseGrid -Control $accel -Row 1
    $mouseHint=New-Object System.Windows.Forms.Label
    if($pointerSpeedOriginalValue -in $pointerSpeedValues){
        $mouseHint.Text='Choices match Windows Mouse Properties (11 levels). Live DPI uses better-logihub; profiles do not launch G HUB.'
    }else{
        $mouseHint.Text="This profile's custom pointer value ($pointerSpeedOriginalValue) is preserved unless you choose a level. Live DPI uses better-logihub; profiles do not launch G HUB."
    }
    $mouseHint.ForeColor=$MUTED
    Add-EditorTabWide -Grid $mouseGrid -Control $mouseHint -Row 2

    $displayGrid=New-EditorTabGrid -Page $displayPage -Rows 5
    $width=New-EditorTabNumber -Grid $displayGrid -Title 'Resolution width' -Column 0 -Row 0 -Min 640 -Max 7680 -Value ([int]$p.Width)
    $height=New-EditorTabNumber -Grid $displayGrid -Title 'Resolution height' -Column 1 -Row 0 -Min 480 -Max 4320 -Value ([int]$p.Height)
    $hz=New-EditorTabNumber -Grid $displayGrid -Title 'Refresh rate (Hz)' -Column 0 -Row 1 -Min 30 -Max 600 -Value ([int]$p.RefreshHz)
    $vibrance=New-EditorTabNumber -Grid $displayGrid -Title 'NVIDIA Digital Vibrance (%)' -Column 1 -Row 1 -Min 0 -Max 100 -Value ([int]$p.Vibrance)
    $hue=New-EditorTabNumber -Grid $displayGrid -Title 'NVIDIA Hue (-1 = driver default)' -Column 0 -Row 2 -Min -1 -Max 359 -Value ([int]$p.Hue)
    $brightnessHint=New-Object System.Windows.Forms.Label
    $brightnessHint.Text='Brightness is not changed by the profile; NVIDIA Control Panel default is 50%.'
    $brightnessHint.ForeColor=$MUTED
    Add-EditorTabWide -Grid $displayGrid -Control $brightnessHint -Row 3
    $nv=New-Object System.Windows.Forms.CheckBox
    $nv.Text='Apply NVIDIA settings (resolution, vibrance, and hue)'
    $nv.Checked=[bool]$p.ApplyNvidia
    Add-EditorTabWide -Grid $displayGrid -Control $nv -Row 4

    $cs2Grid=New-EditorTabGrid -Page $cs2Page -Rows 20
    $cfgFile=New-Object System.Windows.Forms.TextBox
    $cfgFile.Text=[string]$p.ConfigFile
    $cfgFile.ReadOnly=$true
    Add-EditorTabField -Grid $cs2Grid -Title 'CS2 config filename (fixed)' -Control $cfgFile -Column 0 -Row 0
    $sens=New-Object System.Windows.Forms.TextBox
    $sens.Text=[string]$p.CS2Sensitivity
    Add-EditorTabField -Grid $cs2Grid -Title 'CS2 sensitivity (sync updates .cfg)' -Control $sens -Column 1 -Row 0
    # CFG remains authoritative unless this profile has unsynced local edits.
    $voiceSelected=[string]$p.VoicePushToTalkKey
    if(-not $pendingSyncState[$ProfileName]){
        try{$voiceSelected=Get-CafeGitHubVoiceBinding -CfgName ([string]$p.ConfigFile)}catch{Write-Log ('Voice key lookup unavailable: '+$_.Exception.Message) 'WARN'}
    }
    $voiceOptions=@('','V','MOUSE4','MOUSE5','CAPSLOCK','ALT','K','SPACE','SHIFT','CTRL','TAB')+
        @('A','B','C','D','E','F','G','H','I','J','L','M','N','O','P','Q','R','S','T','U','W','X','Y','Z')+
        @('0','1','2','3','4','5','6','7','8','9')+
        @('F1','F2','F3','F4','F5','F6','F7','F8','F9','F10','F11','F12')+
        @('MOUSE1','MOUSE2','MOUSE3')
    $voiceLabels=@('(Keep existing CFG binding)')+@($voiceOptions|Select-Object -Skip 1)
    $voiceBox=New-EditorTabChoice -Grid $cs2Grid -Title 'Push-to-talk key (CFG)' -Column 1 -Row 1 -Labels $voiceLabels -Values $voiceOptions -SelectedValue $voiceSelected
    $voiceCapture=New-Object System.Windows.Forms.Button
    $voiceCapture.Text='Press a key to bind voice'
    $voiceCapture.BackColor=[System.Drawing.Color]::FromArgb(58,67,83)
    $voiceCapture.ForeColor=$WHITE
    $voiceCapture.FlatStyle='Flat'
    [void](Add-EditorTabField -Grid $cs2Grid -Title 'Optional: keyboard / side mouse buttons' -Control $voiceCapture -Column 1 -Row 2)
    $voiceCapture.Add_Click({
        $voiceCapture.Text='Press a key (Esc cancels)'
        [void]$voiceCapture.Focus()
    }.GetNewClosure())
    $voiceCapture.Add_KeyDown({
        param($sender,$eventArgs)
        $raw=$eventArgs.KeyCode.ToString().ToUpperInvariant()
        if($raw -eq 'ESCAPE'){$voiceCapture.Text='Press a key to bind voice';return}
        $candidate=switch -Regex ($raw){
            '^D([0-9])$' {$Matches[1];break}
            '^NUMPAD([0-9])$' {$Matches[1];break}
            '^CAPITAL$' {'CAPSLOCK';break}
            '^CONTROLKEY$' {'CTRL';break}
            '^SHIFTKEY$' {'SHIFT';break}
            '^MENU$' {'ALT';break}
            default {$raw}
        }
        if($voiceOptions -contains $candidate){
            Set-EditorTabChoiceValue -Choice $voiceBox -Value $candidate
            $voiceCapture.Text=('Selected '+$candidate)
            $eventArgs.SuppressKeyPress=$true
        }else{
            $voiceCapture.Text='Unsupported key; choose from dropdown'
        }
    }.GetNewClosure())
    $voiceCapture.Add_MouseDown({
        param($sender,$eventArgs)
        $candidate=if($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::XButton1){'MOUSE4'}elseif($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::XButton2){'MOUSE5'}else{''}
        if($candidate){
            Set-EditorTabChoiceValue -Choice $voiceBox -Value $candidate
            $voiceCapture.Text=('Selected '+$candidate)
        }
    }.GetNewClosure())

    $url=New-Object System.Windows.Forms.TextBox
    $url.Text=[string]$p.CfgDownloadUrl
    $urlCell=Add-EditorTabField -Grid $cs2Grid -Title 'GitHub .cfg URL (FabMode default: fab.cfg)' -Control $url -Column 0 -Row 1
    # URL and voice selector share the row; no span to avoid overlapping controls.
    $apps=New-Object System.Windows.Forms.CheckBox
    $apps.Text='Launch Steam, FACEIT, Spotify, Mouse Options (no G HUB)'
    $apps.Checked=[bool]$p.LaunchApps
    Add-EditorTabWide -Grid $cs2Grid -Control $apps -Row 3
    $cs2Hint=New-Object System.Windows.Forms.Label
    $cs2Hint.Text='Apply Graphics and Play + Exec remain separate actions on the dashboard.'
    $cs2Hint.ForeColor=$MUTED
    Add-EditorTabWide -Grid $cs2Grid -Control $cs2Hint -Row 4

    $graphicsHint=New-Object System.Windows.Forms.Label
    $graphicsHint.Text='CS2 video settings: highest supported refresh is recommended; stretch mode uses NVIDIA scaling.'
    $graphicsHint.ForeColor=$MUTED
    Add-EditorTabWide -Grid $cs2Grid -Control $graphicsHint -Row 5
    $gs=$graphicsPreset.Settings
    $copyOptions=@($script:GamingProfiles.Keys|Where-Object{$_ -cne $ProfileName})
    $copyFromChoice=New-EditorTabChoice -Grid $cs2Grid -Title 'Copy CS2 graphics from profile' -Column 0 -Row 6 -Labels $copyOptions -Values $copyOptions -SelectedValue $copyOptions[0]
    $copyGraphics=New-Object System.Windows.Forms.Button
    $copyGraphics.Text='Copy graphics'
    $copyGraphics.BackColor=[System.Drawing.Color]::FromArgb(58,67,83)
    $copyGraphics.ForeColor=$WHITE
    $copyGraphics.FlatStyle='Flat'
    [void](Add-EditorTabField -Grid $cs2Grid -Title 'Copy selected profile settings' -Control $copyGraphics -Column 1 -Row 6)
    $gameWidth=New-EditorTabNumber -Grid $cs2Grid -Title 'CS2 resolution width' -Column 0 -Row 7 -Min 640 -Max 7680 -Value ([int]$gs.Width)
    $gameHeight=New-EditorTabNumber -Grid $cs2Grid -Title 'CS2 resolution height' -Column 1 -Row 7 -Min 480 -Max 4320 -Value ([int]$gs.Height)
    $aspectChoice=New-EditorTabChoice -Grid $cs2Grid -Title 'CS2 aspect ratio' -Column 0 -Row 8 -Labels @('4:3','16:9','16:10') -Values @('0','1','2') -SelectedValue ([string]$gs.AspectRatioMode)
    $fullscreenChoice=New-EditorTabChoice -Grid $cs2Grid -Title 'Display mode' -Column 1 -Row 8 -Labels @('Fullscreen','Windowed') -Values @('1','0') -SelectedValue ([string]$gs.Fullscreen)
    $refreshPolicyChoice=New-EditorTabChoice -Grid $cs2Grid -Title 'CS2 refresh selection' -Column 0 -Row 9 -Labels @('Highest supported (recommended)','Use specific Hz') -Values @('Highest','Exact') -SelectedValue ([string]$graphicsPreset.RefreshPolicy)
    $gameRefresh=New-EditorTabNumber -Grid $cs2Grid -Title 'Specific CS2 refresh (Hz)' -Column 1 -Row 9 -Min 24 -Max 600 -Value ([int]$(if($gs.RefreshHz){$gs.RefreshHz}else{360}))
    $gameRefresh.Enabled=([string]$graphicsPreset.RefreshPolicy -eq 'Exact')
    $refreshPolicyChoice.Add_SelectedIndexChanged({
        $gameRefresh.Enabled=([string]$refreshPolicyChoice.Tag[$refreshPolicyChoice.SelectedIndex] -eq 'Exact')
    }.GetNewClosure())
    $scalingChoice=New-EditorTabChoice -Grid $cs2Grid -Title 'Stretch / scaling' -Column 0 -Row 10 -Labels @('Stretch to fill','Keep aspect ratio','Center without scaling') -Values @('2','5','3') -SelectedValue ([string]$graphicsPreset.ScalingMode)
    $msaaChoice=New-EditorTabChoice -Grid $cs2Grid -Title 'Anti-aliasing (MSAA)' -Column 1 -Row 10 -Labels @('Off','2×','4×','8×','16×') -Values @('0','2','4','8','16') -SelectedValue ([string]$gs.MSAASamples)
    $shadowChoice=New-EditorTabChoice -Grid $cs2Grid -Title 'Shadow quality' -Column 0 -Row 11 -Labels @('Low','Medium','High','Very high') -Values @('0','1','2','3') -SelectedValue ([string]$gs.ShadowQuality)
    $dynamicShadowChoice=New-EditorTabChoice -Grid $cs2Grid -Title 'Dynamic shadows' -Column 1 -Row 11 -Labels @('Off','On') -Values @('0','1') -SelectedValue ([string]$gs.DynamicShadows)
    $textureChoice=New-EditorTabChoice -Grid $cs2Grid -Title 'Texture detail' -Column 0 -Row 12 -Labels @('Low','Medium','High','Very high') -Values @('0','1','2','3') -SelectedValue ([string]$gs.TextureDetail)
    $shaderChoice=New-EditorTabChoice -Grid $cs2Grid -Title 'Shader quality' -Column 1 -Row 12 -Labels @('Low','Medium','High') -Values @('0','1','2') -SelectedValue ([string]$gs.ShaderQuality)
    $particleChoice=New-EditorTabChoice -Grid $cs2Grid -Title 'Particle detail' -Column 0 -Row 13 -Labels @('Low','Medium','High','Very high') -Values @('0','1','2','3') -SelectedValue ([string]$gs.ParticleDetail)
    $aoChoice=New-EditorTabChoice -Grid $cs2Grid -Title 'Ambient occlusion' -Column 1 -Row 13 -Labels @('Off','Low','Medium','High') -Values @('0','1','2','3') -SelectedValue ([string]$gs.AmbientOcclusion)
    $hdrChoice=New-EditorTabChoice -Grid $cs2Grid -Title 'HDR detail' -Column 0 -Row 14 -Labels @('Game default','Level 0','Level 1','Level 2','Level 3') -Values @('-1','0','1','2','3') -SelectedValue ([string]$gs.HDRDetail)
    $reflexChoice=New-EditorTabChoice -Grid $cs2Grid -Title 'NVIDIA Reflex' -Column 1 -Row 14 -Labels @('Off','On','On + Boost') -Values @('0','1','2') -SelectedValue ([string]$gs.NvidiaReflex)
    $filterChoice=New-EditorTabChoice -Grid $cs2Grid -Title 'Texture filtering level' -Column 0 -Row 15 -Labels @('Level 0','Level 1','Level 2','Level 3','Level 4','Level 5') -Values @('0','1','2','3','4','5') -SelectedValue ([string]$gs.TextureFiltering)
    $fsrChoice=New-EditorTabChoice -Grid $cs2Grid -Title 'FSR level' -Column 1 -Row 15 -Labels @('Off','Level 1','Level 2','Level 3','Level 4') -Values @('0','1','2','3','4') -SelectedValue ([string]$gs.FSRDetail)
    $vsyncChoice=New-EditorTabChoice -Grid $cs2Grid -Title 'Vertical sync' -Column 0 -Row 16 -Labels @('Off','On') -Values @('0','1') -SelectedValue ([string]$gs.VSync)
    $cmaaChoice=New-EditorTabChoice -Grid $cs2Grid -Title 'CMAA' -Column 1 -Row 16 -Labels @('Off','On') -Values @('0','1') -SelectedValue ([string]$gs.CMAA)
    $historyChoice=New-Object System.Windows.Forms.ComboBox
    $historyChoice.DropDownStyle='DropDownList'
    [void]$historyChoice.Items.Add('Load history first')
    $historyChoice.SelectedIndex=0
    $historyChoice.Enabled=$false
    [void](Add-EditorTabField -Grid $cs2Grid -Title 'Earlier GitHub file revisions (commit ID shown)' -Control $historyChoice -Column 0 -Row 17)
    $loadHistory=New-Object System.Windows.Forms.Button
    $loadHistory.Text='Load history'
    $loadHistory.BackColor=[System.Drawing.Color]::FromArgb(58,67,83)
    $loadHistory.ForeColor=$WHITE
    $loadHistory.FlatStyle='Flat'
    [void](Add-EditorTabField -Grid $cs2Grid -Title 'Cached 24 hours; requires internet' -Control $loadHistory -Column 1 -Row 17)
    $resetGraphics=New-Object System.Windows.Forms.Button
    $resetGraphics.Text='Reset to defaults'
    $resetGraphics.BackColor=[System.Drawing.Color]::FromArgb(70,75,88)
    $resetGraphics.ForeColor=$WHITE
    $resetGraphics.FlatStyle='Flat'
    [void](Add-EditorTabField -Grid $cs2Grid -Title 'Load canonical profile preset' -Control $resetGraphics -Column 0 -Row 18)
    $restoreHistory=New-Object System.Windows.Forms.Button
    $restoreHistory.Text='Restore selected version'
    $restoreHistory.BackColor=[System.Drawing.Color]::FromArgb(58,67,83)
    $restoreHistory.ForeColor=$WHITE
    $restoreHistory.FlatStyle='Flat'
    $restoreHistory.Enabled=$false
    [void](Add-EditorTabField -Grid $cs2Grid -Title 'Loads into editor; save to keep' -Control $restoreHistory -Column 1 -Row 18)
    $captureGraphics=New-Object System.Windows.Forms.Button
    $captureGraphics.Text='Capture from CS2'
    $captureGraphics.BackColor=[System.Drawing.Color]::FromArgb(58,67,83)
    $captureGraphics.ForeColor=$WHITE
    $captureGraphics.FlatStyle='Flat'
    [void](Add-EditorTabField -Grid $cs2Grid -Title 'Game must be closed; review, then Save & Sync' -Control $captureGraphics -Column 0 -Row 19)

    $editorFooter=New-Object System.Windows.Forms.TableLayoutPanel
    $editorFooter.Dock='Fill'
    $editorFooter.Padding=New-Object System.Windows.Forms.Padding(20,4,20,10)
    $editorFooter.ColumnCount=3
    $editorFooter.RowCount=3
    [void]$editorFooter.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent',28)))
    [void]$editorFooter.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent',44)))
    [void]$editorFooter.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent',28)))
    [void]$editorFooter.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute',32)))
    [void]$editorFooter.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute',30)))
    [void]$editorFooter.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent',100)))
    $editorRoot.Controls.Add($editorFooter,0,2)
    $tip=New-Object System.Windows.Forms.Label
    $tip.Text='Save the profile and CS2 graphics locally, or sync both to GitHub. Click Apply Graphics to use CS2 settings.'
    $tip.ForeColor=$MUTED
    $tip.Dock='Fill'
    $tip.AutoEllipsis=$true
    $tip.Font=New-Object System.Drawing.Font('Segoe UI',9)
    $editorFooter.Controls.Add($tip,0,0)
    $editorFooter.SetColumnSpan($tip,3)

    $status=New-Object System.Windows.Forms.Label
    $status.Dock='Fill'
    $status.AutoEllipsis=$true
    $status.Font=New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
    if ($script:PendingSync[$ProfileName]) {
        $status.Text='Unsynced local edits - cloud refresh will not overwrite them.'
        $status.ForeColor=[System.Drawing.Color]::FromArgb(255,190,105)
    } else {
        $status.Text='GitHub settings enabled; cached for offline use.'
        $status.ForeColor=$MUTED
    }
    $editorFooter.Controls.Add($status,0,1)
    $editorFooter.SetColumnSpan($status,3)

    $applyGraphicsPresetToEditor={
        param($Preset)
        $validated=ConvertTo-CafeGraphicsPreset -ProfileName $ProfileName -Preset $Preset
        $values=$validated.Settings
        $gameWidth.Value=[decimal]$values.Width
        $gameHeight.Value=[decimal]$values.Height
        Set-EditorTabChoiceValue $aspectChoice ([string]$values.AspectRatioMode)
        Set-EditorTabChoiceValue $fullscreenChoice ([string]$values.Fullscreen)
        Set-EditorTabChoiceValue $refreshPolicyChoice ([string]$validated.RefreshPolicy)
        $gameRefresh.Value=[decimal]$(if($values.RefreshHz){$values.RefreshHz}else{360})
        $gameRefresh.Enabled=($validated.RefreshPolicy -eq 'Exact')
        Set-EditorTabChoiceValue $scalingChoice ([string]$validated.ScalingMode)
        Set-EditorTabChoiceValue $msaaChoice ([string]$values.MSAASamples)
        Set-EditorTabChoiceValue $shadowChoice ([string]$values.ShadowQuality)
        Set-EditorTabChoiceValue $dynamicShadowChoice ([string]$values.DynamicShadows)
        Set-EditorTabChoiceValue $textureChoice ([string]$values.TextureDetail)
        Set-EditorTabChoiceValue $shaderChoice ([string]$values.ShaderQuality)
        Set-EditorTabChoiceValue $particleChoice ([string]$values.ParticleDetail)
        Set-EditorTabChoiceValue $aoChoice ([string]$values.AmbientOcclusion)
        Set-EditorTabChoiceValue $hdrChoice ([string]$values.HDRDetail)
        Set-EditorTabChoiceValue $reflexChoice ([string]$values.NvidiaReflex)
        Set-EditorTabChoiceValue $filterChoice ([string]$values.TextureFiltering)
        Set-EditorTabChoiceValue $fsrChoice ([string]$values.FSRDetail)
        Set-EditorTabChoiceValue $vsyncChoice ([string]$values.VSync)
        Set-EditorTabChoiceValue $cmaaChoice ([string]$values.CMAA)
        return $validated
    }.GetNewClosure()

    $copyGraphics.Add_Click({
        $sourceName=[string]$copyFromChoice.Tag[$copyFromChoice.SelectedIndex]
        try{
            $dialog.Cursor=[System.Windows.Forms.Cursors]::WaitCursor
            $sourcePreset=Get-ProfileGraphicsPreset -ProfileName $sourceName
            $copyPreset=[pscustomobject]@{
                SchemaVersion=1;ProfileName=$ProfileName;DisplayPolicy='ApplyPreset'
                RefreshPolicy=[string]$sourcePreset.RefreshPolicy;ScalingMode=[int]$sourcePreset.ScalingMode
                Settings=$sourcePreset.Settings
            }
            $copyResult=& $applyGraphicsPresetToEditor $copyPreset
            $status.Text=('Copied '+$sourceName+' CS2 graphics into this editor. Save to keep the changes.')
            $status.ForeColor=[System.Drawing.Color]::FromArgb(255,190,105)
            Write-Log ("Copied CS2 graphics from "+$sourceName+" to "+$ProfileName+" in the editor; changes are not saved yet.")
        }catch{
            Write-Log ("Copy graphics to "+$ProfileName+" failed: "+$_.Exception.Message) 'WARN'
            $null=[System.Windows.Forms.MessageBox]::Show(
                ("Could not copy "+$sourceName+" graphics:`n"+$_.Exception.Message),
                'Copy CS2 Graphics','OK','Warning')
        }finally{$dialog.Cursor=[System.Windows.Forms.Cursors]::Default}
    }.GetNewClosure())

    $resetGraphics.Add_Click({
        try{
            $dialog.Cursor=[System.Windows.Forms.Cursors]::WaitCursor
            $defaults=Get-ProfileGraphicsPreset -ProfileName $ProfileName -Canonical
            $resetResult=& $applyGraphicsPresetToEditor $defaults
            $status.Text=('Reset '+$ProfileName+' CS2 graphics to its canonical profile defaults. Save to keep the changes.')
            $status.ForeColor=[System.Drawing.Color]::FromArgb(255,190,105)
            Write-Log ("Reset "+$ProfileName+" CS2 graphics in the editor to canonical profile defaults; changes are not saved yet.")
        }catch{
            Write-Log ("Reset graphics for "+$ProfileName+" failed: "+$_.Exception.Message) 'WARN'
            $null=[System.Windows.Forms.MessageBox]::Show(
                ("Could not load "+$ProfileName+" profile defaults:`n"+$_.Exception.Message),
                'Reset CS2 Graphics','OK','Warning')
        }finally{$dialog.Cursor=[System.Windows.Forms.Cursors]::Default}
    }.GetNewClosure())

    $historyState=[pscustomobject]@{Loaded=$false;Worker=$null;PollTimer=$null}
    $showGraphicsHistory={
        param($versions)
        $historyChoice.Items.Clear()
        $historyChoice.Tag=[object[]]$versions
        if($versions.Count -eq 0){
            [void]$historyChoice.Items.Add('No earlier GitHub versions found')
            $historyChoice.Enabled=$false
            $restoreHistory.Enabled=$false
            $historyChoice.SelectedIndex=0
            $status.Text='No earlier synced graphics versions were found for this profile.'
        }else{
            foreach($version in $versions){
                $dateLabel=[string]$version.DateUtc
                try{$dateLabel=([DateTimeOffset]::Parse([string]$version.DateUtc)).ToLocalTime().ToString('yyyy-MM-dd HH:mm')}catch{}
                [void]$historyChoice.Items.Add(($dateLabel+' — '+[string]$version.Message+' ['+$version.Sha.Substring(0,7)+']'))
            }
            $historyChoice.Enabled=$true
            $historyChoice.SelectedIndex=0
            $restoreHistory.Enabled=$true
            $status.Text=('Loaded '+$versions.Count+' earlier version(s). Select one and restore it into the editor.')
        }
        $historyState.Loaded=$true
        $loadHistory.Text='Refresh history'
        $status.ForeColor=[System.Drawing.Color]::FromArgb(255,190,105)
    }.GetNewClosure()
    $loadHistory.Add_Click({
        if($historyState.Worker -and $historyState.Worker.IsBusy){return}
        if(-not $historyState.Loaded){
            try{
                $cachedHistory=Get-CachedProfileGraphicsHistory -ProfileName $ProfileName
                if($cachedHistory.Found){[void](& $showGraphicsHistory @($cachedHistory.Versions));return}
            }catch{Write-Log ('Could not read cached graphics history for '+$ProfileName+': '+$_.Exception.Message) 'WARN'}
        }
        $encodedPath=[Uri]::EscapeDataString('graphics/'+$ProfileName+'.json')
        $encodedBranch=[Uri]::EscapeDataString([string]$script:GithubBranch)
        $historyUri='https://api.github.com/repos/'+$script:GithubRepo+'/commits?path='+$encodedPath+'&per_page=4&sha='+$encodedBranch
        $loadHistory.Enabled=$false
        $historyChoice.Enabled=$false
        $restoreHistory.Enabled=$false
        $status.Text='Loading GitHub graphics history in the background. You can continue using the editor.'
        $status.ForeColor=$MUTED
        try{
            $worker=New-CafeGraphicsHistoryWorker
            $historyState.Worker=$worker
            $pollTimer=New-Object System.Windows.Forms.Timer
            $pollTimer.Interval=200
            $pollTimer.Add_Tick({
                if($worker.IsBusy){return}
                $pollTimer.Stop()
                $pollTimer.Dispose()
                $historyState.PollTimer=$null
                $historyState.Worker=$null
                if($dialog.IsDisposed -or $dialog.Disposing){return}
                try{
                    if($worker.RateLimitRemaining){
                        Set-CafeGitHubRateLimitDisplay -Remaining ([string]$worker.RateLimitRemaining) `
                            -Limit ([string]$worker.RateLimitLimit)
                    }
                    if($worker.ErrorText){throw ([System.Exception]::new([string]$worker.ErrorText))}
                    $versions=@(Get-ProfileGraphicsHistory -ProfileName $ProfileName -ForceRefresh -ResponseJson ([string]$worker.ResultText))
                    [void](& $showGraphicsHistory $versions)
                }catch{
                    $message=$_.Exception.Message
                    Write-Log ('Could not load GitHub graphics history for '+$ProfileName+': '+$message) 'WARN'
                    $status.Text=('History load failed: '+$message)
                    $status.ForeColor=[System.Drawing.Color]::FromArgb(255,190,105)
                    $available=@($historyChoice.Tag)
                    $historyChoice.Enabled=($available.Count -gt 0)
                    $restoreHistory.Enabled=($available.Count -gt 0)
                }finally{
                    if(-not $dialog.IsDisposed -and -not $dialog.Disposing){
                        $loadHistory.Enabled=$true
                        $dialog.Cursor=[System.Windows.Forms.Cursors]::Default
                    }
                }
            }.GetNewClosure())
            $historyState.PollTimer=$pollTimer
            $worker.RunWorkerAsync($historyUri)
            $pollTimer.Start()
        }catch{
            if($historyState.PollTimer){$historyState.PollTimer.Stop();$historyState.PollTimer.Dispose();$historyState.PollTimer=$null}
            $historyState.Worker=$null
            $loadHistory.Enabled=$true
            $available=@($historyChoice.Tag)
            $historyChoice.Enabled=($available.Count -gt 0)
            $restoreHistory.Enabled=($available.Count -gt 0)
            $status.Text=('Could not start history load: '+$_.Exception.Message)
            $status.ForeColor=[System.Drawing.Color]::FromArgb(255,190,105)
        }
    }.GetNewClosure())
    $restoreHistory.Add_Click({
        try{
            $versions=@($historyChoice.Tag)
            $selectedIndex=[int]$historyChoice.SelectedIndex
            if($selectedIndex -lt 0 -or $selectedIndex -ge $versions.Count){throw 'Select an earlier graphics version first.'}
            $dialog.Cursor=[System.Windows.Forms.Cursors]::WaitCursor
            $version=$versions[$selectedIndex]
            $preset=Get-ProfileGraphicsVersion -ProfileName $ProfileName -Version $version
            [void](& $applyGraphicsPresetToEditor $preset)
            $status.Text=('Loaded '+$version.Message+' into the editor only. Not saved or applied. Use Save Locally or Save & Sync, then Apply Graphics to change CS2.')
            $status.ForeColor=[System.Drawing.Color]::FromArgb(255,190,105)
            Write-Log ('Loaded earlier GitHub graphics version '+$version.Sha+' for '+$ProfileName+' into the editor; no save or game settings were changed.')
        }catch{
            Write-Log ('Could not restore GitHub graphics version for '+$ProfileName+': '+$_.Exception.Message) 'WARN'
            $null=[System.Windows.Forms.MessageBox]::Show(
                ('Could not load the selected graphics version:`n'+$_.Exception.Message),
                'Restore Graphics Version','OK','Warning')
        }finally{$dialog.Cursor=[System.Windows.Forms.Cursors]::Default}
    }.GetNewClosure())
    # One shared action powers the editor button and the dashboard shortcut.
    $invokeCS2Capture={
        try{
            $captureGraphics.Enabled=$false
            $dialog.Cursor=[System.Windows.Forms.Cursors]::WaitCursor
            $capture=Get-CafeCS2GraphicsCapture -ProfileName $ProfileName -BasePreset $graphicsPreset
            $missing=@($capture.MissingFields)
            $preview='Read '+$capture.CapturedFields.Count+' CS2 graphics values from account '+$capture.AccountID+".`n"+
                'Resolution: '+$capture.Preset.Settings.Width+'x'+$capture.Preset.Settings.Height+'; aspect mode: '+$capture.Preset.Settings.AspectRatioMode+'; fullscreen: '+$capture.Preset.Settings.Fullscreen+".`n"
            if($capture.CapturedFields -contains 'RefreshHz'){
                $preview+='Refresh: '+$capture.Preset.Settings.RefreshHz+' Hz'+$(if($capture.RefreshWasRounded){' (rounded from the game value)'}else{''})+".`n"
            }else{$preview+='Refresh value was missing; current profile refresh choice will be kept.'+"`n"}
            if($missing.Count){$preview+='Missing values will keep this profile current values: '+($missing -join ', ')+".`n"}
            $preview+='NVIDIA scaling mode is not stored in cs2_video.txt and will stay as configured for this profile.'+"`n`n"+
                'Load these values into the editor? This does not change CS2 or GitHub. Review them, then click Save & Sync to publish.'
            $answer=[System.Windows.Forms.MessageBox]::Show($preview,'Capture CS2 Graphics','YesNo','Question')
            if($answer -ne [System.Windows.Forms.DialogResult]::Yes){return}
            [void](& $applyGraphicsPresetToEditor $capture.Preset)
            try{
                $source=[pscustomobject]@{Path=$capture.Path;AccountID=$capture.AccountID}
                $convars=Get-CafeCS2UserConvarsCapture -Source $source
                if($convars.Values.Count -eq 0){throw 'No relevant sensitivity or crosshair keys in saved convars.'}
                $script:CapturedCS2Convars[$ProfileName]=$convars.Values
                if($convars.Values.ContainsKey('sensitivity')){$sens.Text=[string]$convars.Values['sensitivity']}
                Write-Log ('Staged '+$convars.Values.Count+' CS2 sensitivity/crosshair values for '+$ProfileName)
            }catch{
                [void]$script:CapturedCS2Convars.Remove($ProfileName)
                Write-Log ('CS2 user convars capture skipped: '+$_.Exception.Message) 'WARN'
                [void][System.Windows.Forms.MessageBox]::Show(('Graphics captured but crosshair/sensitivity unavailable: '+$_.Exception.Message),'Partial CS2 capture','OK','Warning')
            }
            $status.Text=('Captured CS2 settings from Steam account '+$capture.AccountID+'. Review them, then Save & Sync to publish; nothing has been saved or applied yet.')
            $status.ForeColor=[System.Drawing.Color]::FromArgb(255,190,105)
            Write-Log ('Captured '+$capture.CapturedFields.Count+' CS2 graphics values from '+$capture.Path+' for '+$ProfileName+'; missing values kept the current preset. No game, local profile, or GitHub data was changed.')
        }catch{
            Write-Log ('CS2 graphics capture for '+$ProfileName+' failed: '+$_.Exception.Message) 'WARN'
            $null=[System.Windows.Forms.MessageBox]::Show(('Could not capture CS2 graphics:`n'+$_.Exception.Message),'Capture CS2 Graphics','OK','Warning')
        }finally{
            $captureGraphics.Enabled=$true
            if(-not $dialog.IsDisposed){$dialog.Cursor=[System.Windows.Forms.Cursors]::Default}
        }
    }.GetNewClosure()
    $captureGraphics.Add_Click($invokeCS2Capture)
    if($CaptureOnOpen){
        $editorTabs.SelectedTab=$cs2Page
        $dialog.Add_Shown({ & $invokeCS2Capture }.GetNewClosure())
    }
    $saveLocal=New-Object System.Windows.Forms.Button
    $saveLocal.Text='Save Locally'
    $saveLocal.BackColor=$BLUE
    $saveLocal.ForeColor=$WHITE
    $saveLocal.FlatStyle='Flat'
    $saveLocal.Dock='Fill'
    $editorFooter.Controls.Add($saveLocal,0,2)

    $saveSync=New-Object System.Windows.Forms.Button
    $saveSync.Text='Save & Sync to GitHub'
    $saveSync.BackColor=[System.Drawing.Color]::FromArgb(38,132,102)
    $saveSync.ForeColor=$WHITE
    $saveSync.FlatStyle='Flat'
    $saveSync.Dock='Fill'
    $editorFooter.Controls.Add($saveSync,1,2)
    $saveSync.Tag='Sync this profile, its CS2 graphics preset, and (if set) sensitivity in its matching CFG on GitHub.'

    $cancel=New-Object System.Windows.Forms.Button
    $cancel.Text='Cancel'
    $cancel.Dock='Fill'
    $cancel.DialogResult=[System.Windows.Forms.DialogResult]::Cancel
    $editorFooter.Controls.Add($cancel,2,2)
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
        $readChoiceValue={param($control)[string]$control.Tag[$control.SelectedIndex]}.GetNewClosure()
        $graphicsSettings=[ordered]@{
            Width=[int]$gameWidth.Value;Height=[int]$gameHeight.Value
            AspectRatioMode=[int](& $readChoiceValue $aspectChoice)
            Fullscreen=[int](& $readChoiceValue $fullscreenChoice)
            RefreshHz=[int]$gameRefresh.Value
            MSAASamples=[int](& $readChoiceValue $msaaChoice)
            ShadowQuality=[int](& $readChoiceValue $shadowChoice)
            DynamicShadows=[int](& $readChoiceValue $dynamicShadowChoice)
            TextureDetail=[int](& $readChoiceValue $textureChoice)
            ShaderQuality=[int](& $readChoiceValue $shaderChoice)
            ParticleDetail=[int](& $readChoiceValue $particleChoice)
            AmbientOcclusion=[int](& $readChoiceValue $aoChoice)
            HDRDetail=[int](& $readChoiceValue $hdrChoice)
            NvidiaReflex=[int](& $readChoiceValue $reflexChoice)
            TextureFiltering=[int](& $readChoiceValue $filterChoice)
            FSRDetail=[int](& $readChoiceValue $fsrChoice)
            VSync=[int](& $readChoiceValue $vsyncChoice)
            CMAA=[int](& $readChoiceValue $cmaaChoice)
        }
        $refreshPolicy=[string](& $readChoiceValue $refreshPolicyChoice)
        if($refreshPolicy -eq 'Highest'){$graphicsSettings.Remove('RefreshHz')}
        $scalingMode=[int](& $readChoiceValue $scalingChoice)
        $graphicsPreset=[pscustomobject]@{
            SchemaVersion=1;ProfileName=$ProfileName;DisplayPolicy='ApplyPreset'
            RefreshPolicy=$refreshPolicy;ScalingMode=$scalingMode;Settings=$graphicsSettings
        }
        $graphicsPreset=ConvertTo-CafeGraphicsPreset -ProfileName $ProfileName -Preset $graphicsPreset
        $graphicsPresetState[$ProfileName]=$graphicsPreset
        $p.ScalingMode=$scalingMode
        $selectedPointerSpeed=[int](& $readChoiceValue $pointer)
        $initialPointerChoice=[int]$pointerSpeedValues[$pointerSpeedSelectedIndex]
        if($pointerSpeedSelectionState.UserChanged -or $selectedPointerSpeed -ne $initialPointerChoice){
            $p.PointerSpeed=$selectedPointerSpeed
        }else{
            $p.PointerSpeed=$pointerSpeedOriginalValue
        }
        $p.LogitechDPI=[int]$logitechDpi.Value
        Assert-LogitechDPI $p.LogitechDPI
        $p.DisableAcceleration= -not $accel.Checked
        $p.Width=[int]$width.Value
        $p.Height=[int]$height.Value
        $p.RefreshHz=[int]$hz.Value
        $p.Vibrance=[int]$vibrance.Value
        $p.Hue=[int]$hue.Value
        $p.ApplyNvidia=[bool]$nv.Checked
        $p.LaunchApps=[bool]$apps.Checked
        $p.CS2Sensitivity=$sensValue
        $p.VoicePushToTalkKey=[string]$voiceBox.Tag[$voiceBox.SelectedIndex]
        $p.CfgDownloadUrl=$cfgUrl
        # Use the captured shared dictionary, not script: scope in this closure.
        $pendingSyncState[$ProfileName] = $true
        Save-ProfileSettings
        Write-Log "$ProfileName edited locally: pointer=$($p.PointerSpeed), acceleration enabled=$(-not $p.DisableAcceleration), display=$($p.Width)x$($p.Height)@$($p.RefreshHz), CS2=$($graphicsPreset.Settings.Width)x$($graphicsPreset.Settings.Height) refresh=$refreshPolicy scaling=$scalingMode, vibrance=$($p.Vibrance)%, hue=$($p.Hue) degrees, LogitechDPI=$($p.LogitechDPI), sensitivity=$sensValue."
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

    $syncTargetBranch=[string]$script:GithubBranch
    $saveSync.Add_Click({
        try {
            & $saveEditorValues
            $changes=if($p.VoicePushToTalkKey){
                "profiles/$ProfileName.json, graphics/$ProfileName.json AND $($p.ConfigFile) (voice key and selected settings)"
            }elseif($script:CapturedCS2Convars.ContainsKey($ProfileName)){
                "profiles/$ProfileName.json, graphics/$ProfileName.json AND $($p.ConfigFile) (captured CS2 crosshair/sensitivity)"
            }elseif($sens.Text.Trim()){
                "profiles/$ProfileName.json, graphics/$ProfileName.json AND $($p.ConfigFile) (sensitivity only)"
            }else{
                "profiles/$ProfileName.json and graphics/$ProfileName.json (CFG unchanged: sensitivity blank)"
            }
            $newline=[Environment]::NewLine
            $message="Save these files to GitHub branch $syncTargetBranch?"+$newline+
                $changes+$newline+$newline+
                'Only these profile files will be changed; other CFG binds remain untouched.'
            $confirm=[System.Windows.Forms.MessageBox]::Show(
                $message,'Confirm GitHub sync','YesNo','Question')
            if($confirm -ne [System.Windows.Forms.DialogResult]::Yes){
                $status.Text='Saved locally; GitHub sync canceled.'
                $status.ForeColor=[System.Drawing.Color]::FromArgb(255,190,105)
                Write-Log "$ProfileName GitHub sync canceled; local edits preserved."
                return
            }
            $authorization = Get-GitHubSyncAuthorization -OwnerWindow $dialog
            if ($null -eq $authorization -or [string]::IsNullOrWhiteSpace([string]$authorization.Token)) {
                $status.Text='Saved locally. GitHub sync canceled; local edits preserved.'
                $status.ForeColor=[System.Drawing.Color]::FromArgb(255,190,105)
                Write-Log "$ProfileName GitHub sync canceled; local changes preserved."
                return
            }
            if($authorization.Method -eq 'GitHub device sign-in'){
                $accountConfirm=[System.Windows.Forms.MessageBox]::Show(
                    ('Sync these settings using GitHub account @'+$authorization.Login+'?'),
                    'Confirm GitHub account','YesNo','Question')
                if($accountConfirm -ne [System.Windows.Forms.DialogResult]::Yes){
                    $authorization.Token=$null
                    $status.Text='Saved locally. GitHub sync canceled; local edits preserved.'
                    $status.ForeColor=[System.Drawing.Color]::FromArgb(255,190,105)
                    Write-Log "$ProfileName GitHub sync canceled after account verification; local changes preserved."
                    return
                }
            }
            $token = [string]$authorization.Token
            $authorization.Token=$null
            try {
                $saveSync.Enabled=$false
                $dialog.Cursor=[System.Windows.Forms.Cursors]::WaitCursor
                Sync-ProfileToGitHub -ProfileName $ProfileName -Token $token
                $pendingSyncState[$ProfileName] = $false
                Save-ProfileSettings
                [System.Windows.Forms.MessageBox]::Show("$ProfileName settings saved locally and synced to GitHub. The CS2 graphics preset was updated or already matched GitHub.`nOther PCs can now download the settings without signing in.`nIf CS2 sensitivity was set, it was also synced into the matching .cfg; binds and other commands remain unchanged.", 'GitHub sync complete', 'OK', 'Information') | Out-Null
                $dialog.DialogResult=[System.Windows.Forms.DialogResult]::OK
                $dialog.Close()
            } finally {
                $token = $null
                $authorization = $null
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
    # Editor open already refreshed this profile and its graphics preset; the
    # local snapshot is updated by Save/Sync handlers. Avoid a duplicate fetch
    # merely because the editor closed.
    Update-SelectedProfileCard -Name $ProfileName
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
$script:LogihubRequestGeneration=0
$script:LiveDpiVerificationTimer=$null
$script:LiveDpiVerificationContext=$null
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
                    try{Set-LogitechLiveDPI -DPI $dpi}catch{Write-Log ('Delayed Logitech DPI failed: '+$_.Exception.Message) 'ERROR';Set-RunOutcome -Run $run -Setting 'Logitech live DPI' -Requested ([string]$dpi) -Target 'Selected Superlight' -Status FAILED -Detail $_.Exception.Message}
                    finally{Complete-StepScope -Detail 'Async DPI command finished; review read-back verification.';Write-RunSummary -Run $run}
                }
            } catch {
                Write-Log $_.Exception.Message 'ERROR'
                if($null -ne $script:LogihubRequestedDPI){
                    $run=$script:LogihubRequestedRun
                    if(-not $run){$run='Manual DPI'}
                    Set-StepResult -Run $run -Step 'Logitech live DPI' -Status FAILED -Detail $_.Exception.Message
                    Set-RunOutcome -Run $run -Setting 'Logitech live DPI' -Requested ([string]$script:LogihubRequestedDPI) -Target 'Selected Superlight (helper download)' -Status FAILED -Detail $_.Exception.Message
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
    $script:LogihubRequestGeneration++
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
        Set-RunOutcome -Run $script:LogihubRequestedRun -Setting 'Logitech live DPI' -Requested ([string]$DPI) -Target 'Selected Superlight (pending device detection)' -Status PENDING -Detail 'Pinned helper download is still running.'
        return
    }
    Set-RunOutcome -Run $script:LogihubRequestedRun -Setting 'Logitech live DPI' -Requested ([string]$DPI) -Target 'Selected Superlight (pending device detection)' -Status PENDING -Detail 'Pinned helper download started; DPI apply waits for download verification.'
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

function Test-SameSuperlight {
    param($Expected,$Actual)
    return ($Expected -and $Actual -and [int]$Expected.Index -eq [int]$Actual.Index -and
        [string]$Expected.Model -ceq [string]$Actual.Model)
}
function Get-LogitechDPIReadback {
    param([int]$DeviceIndex)
    $read=Invoke-Logihub -Arguments @('dpi','get','--device',([string]$DeviceIndex))
    foreach($line in @($read -split '\r?\n' | Where-Object {$_ -match '\S'})){
        if($line -match ('^\s*'+$DeviceIndex+'\s+.+?\s+(\d+)\s*$')){return [int]$Matches[1]}
    }
    throw ('Logitech DPI read-back cannot be parsed for device '+$DeviceIndex+': '+$read)
}
function Get-LogitechOnboardMode {
    param($Target)
    $current=Get-SelectedSuperlight
    if(-not (Test-SameSuperlight -Expected $Target -Actual $current)){
        throw 'The connected Superlight changed before its mode was read.'
    }
    $json=Invoke-Logihub -Arguments @('onboard','mode','get','--json','--device',([string]$Target.Index))
    try{$result=ConvertFrom-Json -InputObject $json -ErrorAction Stop}
    catch{throw ('Could not parse Logitech mode response: '+$_.Exception.Message)}
    if($null -eq $result.device -or [int]$result.device -ne [int]$Target.Index){throw 'Logitech mode response was missing the expected device index.'}
    $mode=([string]$result.mode).Trim().ToLowerInvariant()
    if($mode -notin @('onboard','host')){throw ('Logitech reported an unsupported mode: '+$mode)}
    return $mode
}
function Invoke-LogitechDPISetAndReadback {
    param($Target,[int]$DPI)
    $current=Get-SelectedSuperlight
    if(-not (Test-SameSuperlight -Expected $Target -Actual $current)){
        throw 'The connected Superlight changed before DPI apply; no write was attempted.'
    }
    [void](Invoke-Logihub -Arguments @('dpi','set',([string]$DPI),'--device',([string]$current.Index)))
    $after=Get-SelectedSuperlight
    if(-not (Test-SameSuperlight -Expected $current -Actual $after)){
        throw 'The connected Superlight changed during DPI apply; read-back was not attributed to a different device.'
    }
    $actual=Get-LogitechDPIReadback -DeviceIndex ([int]$current.Index)
    if($actual -ne $DPI){throw ('DPI read-back was '+$actual+', expected '+$DPI)}
    return $actual
}
function Schedule-LogitechDpiVerification {
    param($Target,[int]$DPI,[int]$Generation,[string]$Run)
    if($script:LiveDpiVerificationTimer){$script:LiveDpiVerificationTimer.Stop();$script:LiveDpiVerificationTimer.Dispose()}
    $script:LiveDpiVerificationContext=[pscustomobject]@{Target=$Target;DPI=$DPI;Generation=$Generation;Run=$Run}
    $script:LiveDpiVerificationTimer=New-Object System.Windows.Forms.Timer
    $script:LiveDpiVerificationTimer.Interval=1500
    $script:LiveDpiVerificationTimer.Add_Tick({
        $timer=$script:LiveDpiVerificationTimer
        $timer.Stop()
        $context=$script:LiveDpiVerificationContext
        try {
            if(-not $context -or $context.Generation -ne $script:LogihubRequestGeneration){return}
            Start-StepScope -Run $context.Run -Step 'Delayed Logitech DPI verification'
            $current=Get-SelectedSuperlight
            if(-not (Test-SameSuperlight -Expected $context.Target -Actual $current)){
                Write-Log 'The connected Superlight changed after DPI apply; delayed verification did not target a different mouse.' 'WARN'
                Set-RunOutcome -Run $context.Run -Setting 'Delayed Logitech DPI verification' -Requested ([string]$context.DPI) -Target ($context.Target.Name+' device '+$context.Target.Index) -Status SKIPPED -Detail 'The connected mouse identity changed; no other device was queried for verification.'
            }else{
                $actual=Get-LogitechDPIReadback -DeviceIndex ([int]$context.Target.Index)
                if($actual -ne $context.DPI){Write-Log ('DPI changed after apply: requested '+$context.DPI+', delayed read-back '+$actual+'. G HUB or onboard profile may have restored it.') 'WARN';$verifyStatus='FALLBACK'}
                else{Write-Log ('Delayed Logitech DPI verification passed: '+$actual+' DPI.');$verifyStatus='APPLIED'}
                Set-RunOutcome -Run $context.Run -Setting 'Delayed Logitech DPI verification' -Requested ([string]$context.DPI) -Target ($context.Target.Name+' device '+$context.Target.Index) -Status $verifyStatus -Actual ([string]$actual) -Detail 'Delayed read-back checks whether another Logitech profile changed DPI.'
            }
            Complete-StepScope -Detail 'Delayed read-back checks whether another Logitech profile changed DPI after application.'
            Write-RunSummary -Run $context.Run
        }catch{
            if($script:StepScope){Write-Log ('Delayed Logitech DPI verification failed: '+$_.Exception.Message) 'WARN';Set-RunOutcome -Run $context.Run -Setting 'Delayed Logitech DPI verification' -Requested ([string]$context.DPI) -Target 'Selected Superlight' -Status FAILED -Detail $_.Exception.Message;Complete-StepScope -Detail 'Delayed DPI could not be verified.';Write-RunSummary -Run $context.Run}
            else{Write-Log ('Delayed Logitech DPI verification skipped: '+$_.Exception.Message) 'WARN'}
        }finally{$timer.Dispose();$script:LiveDpiVerificationTimer=$null;$script:LiveDpiVerificationContext=$null}
    })
    $script:LiveDpiVerificationTimer.Start()
}

function Set-LogitechLiveDPI {
    param([int]$DPI=800)
    Assert-LogitechDPI $DPI
    if(@(Get-Process -Name lghub,lghub_agent -ErrorAction SilentlyContinue).Count -gt 0){
        Write-Log 'G HUB detected; leaving it running. It may override the DPI later.' 'WARN'
    }
    $target=Get-SelectedSuperlight
    $deviceIndex=[int]$target.Index
    $usedHostFallback=$false
    $standardFailure=$null
    try{$readValue=Invoke-LogitechDPISetAndReadback -Target $target -DPI $DPI}
    catch{$standardFailure=$_.Exception.Message}
    if($standardFailure){
        if([string]$target.Model -cne 'pro_x_wireless_mouse'){
            throw ('Logitech DPI verification failed: requested '+$DPI+'; '+$standardFailure)
        }
        Write-Log ('Superlight 1 standard DPI path did not verify ('+$standardFailure+'); trying host-mode fallback.') 'WARN'
        $switchedToHost=$false
        try{
            $current=Get-SelectedSuperlight
            if(-not (Test-SameSuperlight -Expected $target -Actual $current)){
                throw 'The connected Superlight changed before host-mode fallback; no mode change was attempted.'
            }
            $mode=Get-LogitechOnboardMode -Target $current
            Write-Log ('Superlight 1 host-mode fallback: current mode is '+$mode+'.')
            if($mode -eq 'onboard'){
                $switchedToHost=$true
                Write-Log 'Switching Superlight 1 to host mode for the live DPI retry.'
                [void](Invoke-Logihub -Arguments @('onboard','mode','set','off','--device',([string]$deviceIndex)))
            }
            $verifiedMode=Get-LogitechOnboardMode -Target $current
            if($verifiedMode -ne 'host'){throw ('Host-mode switch was not verified; mode='+$verifiedMode)}
            $readValue=Invoke-LogitechDPISetAndReadback -Target $current -DPI $DPI
            $usedHostFallback=$true
            Write-Log ('Superlight 1 host-mode DPI fallback verified: requested '+$DPI+'; read-back '+$readValue+' (device '+$deviceIndex+'); mouse remains in host mode.')
        }catch{
            $fallbackFailure=$_.Exception.Message
            if($switchedToHost){
                try{
                    $now=Get-SelectedSuperlight
                    if(Test-SameSuperlight -Expected $target -Actual $now){
                        [void](Invoke-Logihub -Arguments @('onboard','mode','set','on','--device',([string]$deviceIndex)))
                        $restoredMode=Get-LogitechOnboardMode -Target $target
                        if($restoredMode -ne 'onboard'){throw ('Onboard-mode restoration was not verified; mode='+$restoredMode)}
                        Write-Log 'Superlight 1 host-mode fallback failed; onboard mode restoration verified.' 'WARN'
                    }else{$fallbackFailure+='; mouse identity changed so onboard-mode restoration was skipped'}
                }catch{$fallbackFailure+='; failed to restore onboard mode: '+$_.Exception.Message}
            }
            throw ('Standard DPI path failed ('+$standardFailure+'); Superlight 1 host-mode fallback failed ('+$fallbackFailure+').')
        }
    }else{
        Write-Log ('Logitech live DPI verified: requested '+$DPI+'; read-back '+$readValue+' (device '+$deviceIndex+').')
    }
    $run=if($script:StepScope){$script:StepScope.Run}elseif($script:LogihubRequestedRun){$script:LogihubRequestedRun}else{'Manual DPI'}
    $detail='Device identity was revalidated before applying and reading back DPI.'
    if($usedHostFallback){$detail='Standard path failed read-back; Superlight 1 host-mode fallback applied and verified DPI. Host mode remains active.'}
    Set-RunOutcome -Run $run -Setting 'Logitech live DPI' -Requested ([string]$DPI) -Target ($target.Name+' device '+$deviceIndex) -Status APPLIED -Actual ([string]$readValue) -Detail $detail
    Schedule-LogitechDpiVerification -Target $target -DPI $DPI -Generation $script:LogihubRequestGeneration -Run $run
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
    if(-not (Resolve-PendingProfileChanges -ProfileName $ProfileName)){return}
    $profileSource=Refresh-ProfileFromGitHub -ProfileName $ProfileName
    if(-not (Confirm-LocalProfileApply -ProfileName $ProfileName -Source $profileSource)){return}
    if([bool]$script:GamingProfiles[$ProfileName].ApplyNvidia){
        try{
            # ScalingMode is also stored in profiles/<Profile>.json for
            # compatibility, but graphics/<Profile>.json is authoritative.
            # Refresh and validate it before any profile action so Apply
            # Profile and Apply Graphics cannot choose different scaling.
            $graphicsPreset=Get-ProfileGraphicsPreset -ProfileName $ProfileName -RequireGitHub
            $script:GamingProfiles[$ProfileName].ScalingMode=[int]$graphicsPreset.ScalingMode
            Write-Log ("$ProfileName profile apply verified graphics/$ProfileName.json on GitHub; authoritative ScalingMode="+$graphicsPreset.ScalingMode+'.')
            try{Save-ProfileSettings}catch{Write-Log ("Unable to cache the verified $ProfileName scaling mode locally: "+$_.Exception.Message) 'WARN'}
        }catch{
            $message="Could not verify the latest GitHub CS2 graphics settings for $ProfileName. No profile actions were applied, to avoid using a different scaling mode than Apply Graphics.`r`n`r`n$($_.Exception.Message)"
            Write-Log ("$ProfileName profile apply canceled: "+$message) 'ERROR'
            [void][System.Windows.Forms.MessageBox]::Show($message,'GitHub Graphics Refresh Failed','OK','Warning')
            return
        }
    }
    $script:ActiveRunName=$ProfileName
    $script:StepResults.Clear()
    Clear-RunOutcomes -Run $ProfileName
    $profile = $script:GamingProfiles[$ProfileName]
    Write-Log "$ProfileName full routine started: mouse, NVIDIA, CS2 config, applications."

    $steps = @(
        @{ Name = 'Windows mouse speed/acceleration'; Action = {
            Apply-ProfileMouse -ProfileName $ProfileName -PointerSpeed ([int]$profile.PointerSpeed) -DisableAcceleration ([bool]$profile.DisableAcceleration) -SkipPointerOptions
        } }
    )
    if ($profile.ApplyNvidia) {
        $steps += @{ Name = 'NVIDIA settings'; Action = { Apply-NvidiaGamingSettings -Width ([int]$profile.Width) -Height ([int]$profile.Height) -RefreshHz ([int]$profile.RefreshHz) -Vibrance ([int]$profile.Vibrance) -Hue ([int]$profile.Hue) -ScalingMode ([int]$profile.ScalingMode) } }
    }
    $profileCfgName = [string]$profile.ConfigFile
    if (-not [string]::IsNullOrWhiteSpace($profileCfgName)) {
        $profileCfgUrl = [string]$profile.CfgDownloadUrl
        if ($ProfileName -eq 'FabMode' -and [string]::IsNullOrWhiteSpace($profileCfgUrl)) {
            $profileCfgUrl = $script:FabCfgCloudUrl
        }
        # Profile Apply installs its CFG without editing any Steam launch options.
        $steps += @{ Name = "Install CS2 $profileCfgName"; Action = {
            $cfgInstalled=Install-AtCfg -Silent -CfgName $profileCfgName -DownloadUrl $profileCfgUrl -CloudPreferred:([bool]$profileCfgUrl) -CS2Sensitivity ([string]$profile.CS2Sensitivity)
            Set-RunOutcome -Run $ProfileName -Setting 'CS2 profile CFG' -Requested $profileCfgName -Target 'Active Steam CS2 cfg folder' -Status $(if($cfgInstalled){'APPLIED'}else{'FAILED'}) -Actual $(if($cfgInstalled){'SHA-256 verified'}else{'not installed'}) -Detail $(if($cfgInstalled){'Selected source copied and verified.'}else{'Install-AtCfg did not confirm installation.'})
            if(-not $cfgInstalled){throw ('CS2 CFG install was not verified: '+$profileCfgName)}
        } }
    }
    if ($profile.LaunchApps) {
        $steps += @{ Name = 'Launch apps (without G HUB; including Mouse Pointer Options)'; Action = { Launch-All -SkipGHub } }
    }
    # Profile launch never starts G HUB, which can overwrite the requested mouse DPI.
    # Apply live DPI last via our better-logihub helper. Never write onboard here.
    $steps += @{ Name = 'Logitech live DPI'; Action = { Request-LogitechLiveDPI -DPI ([int]$profile.LogitechDPI) } }
    foreach ($step in $steps) {
        Write-Log ("$ProfileName step started: " + $step.Name)
        Start-StepScope -Run $ProfileName -Step $step.Name
        try {
            & ($step.Action)
            Write-Log ("$ProfileName step returned: " + $step.Name + ". Check logs for individual success or errors.")
        } catch {
            Write-Log ("$ProfileName step failed: " + $step.Name + ": " + $_.Exception.Message) 'ERROR'
            if($step.Name -eq 'Logitech live DPI'){
                Set-RunOutcome -Run $ProfileName -Setting 'Logitech live DPI' -Requested ([string]$profile.LogitechDPI) -Target 'Selected Superlight' -Status FAILED -Detail $_.Exception.Message
            }
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
    if(-not (Resolve-PendingProfileChanges -ProfileName $ProfileName)){return}
    $profileSource=Refresh-ProfileFromGitHub -ProfileName $ProfileName
    if(-not (Confirm-LocalProfileApply -ProfileName $ProfileName -Source $profileSource)){return}
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
    $graphicsRun='Graphics '+$ModeName
    Clear-RunOutcomes -Run $graphicsRun
    Start-StepScope -Run $graphicsRun -Step 'Apply Graphics'
    try {
    if(-not (Resolve-PendingProfileChanges -ProfileName $ModeName)){return}
    $expected='47d01c55176a2c2b23ac94d4a818599818761c93'
    $source=Add-CafeCacheBust -Uri 'https://raw.githubusercontent.com/fabjoncela/Cs-script/main/graphics/ApplyGraphics.ps1'
    $cache=Join-Path $env:LOCALAPPDATA 'CafeLauncher\graphics-module.ps1'
    $parent=Split-Path -Parent $cache
    if(-not (Test-Path -LiteralPath $parent)){[void](New-Item -Path $parent -ItemType Directory -Force)}
    $temp=Join-Path $env:TEMP ('CafeLauncher-graphics-module-'+[guid]::NewGuid().ToString('N')+'.ps1')
    try{
        $localModule=Join-Path (Split-Path -Parent $env:CAFE_SCRIPT) 'graphics\ApplyGraphics.ps1'
        $loadedLocal=$false
        if(Test-Path -LiteralPath $localModule -PathType Leaf){
            $localBytes=[IO.File]::ReadAllBytes($localModule)
            if((Get-GitBlobSha -Bytes $localBytes) -eq $expected){
                $localTokens=$null;$localErrors=$null
                [void][System.Management.Automation.Language.Parser]::ParseFile($localModule,[ref]$localTokens,[ref]$localErrors)
                if(@($localErrors).Count){throw 'Local graphics module has invalid PowerShell syntax.'}
                Copy-Item -LiteralPath $localModule -Destination $cache -Force -ErrorAction Stop
                $loadedLocal=$true
                Write-Log 'Loaded the hash-verified graphics module beside this testing launcher.'
            }
        }
        if(-not $loadedLocal){
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $source -OutFile $temp -UseBasicParsing -TimeoutSec 12 -ErrorAction Stop
            $bytes=[IO.File]::ReadAllBytes($temp)
            if((Get-GitBlobSha -Bytes $bytes) -ne $expected){throw 'Cloud graphics module SHA does not match the reviewed launcher version.'}
            $tokens=$null;$errors=$null
            [void][System.Management.Automation.Language.Parser]::ParseFile($temp,[ref]$tokens,[ref]$errors)
            if(@($errors).Count){throw 'Downloaded graphics module has invalid PowerShell syntax.'}
            Copy-Item -LiteralPath $temp -Destination $cache -Force -ErrorAction Stop
        }
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
        Write-RunSummary -Run $graphicsRun
    }
}

# Backward-compatible entry point.
function Invoke-FabModeFull { Invoke-GamingProfile -ProfileName 'FabMode' }

$script:ProfileAccentColors=@{
    FabMode=[System.Drawing.Color]::FromArgb(56,137,240)
    ArliMode=[System.Drawing.Color]::FromArgb(54,181,117)
    BrileMode=[System.Drawing.Color]::FromArgb(167,111,226)
    ArmlMode=[System.Drawing.Color]::FromArgb(232,151,65)
    OliMode=[System.Drawing.Color]::FromArgb(71,193,207)
}
# Modern CafeLauncher dashboard. Profile actions remain separate and independently callable.
$form=New-Object System.Windows.Forms.Form
$form.Text='CafeLauncher | CS2 Setup Center'
$form.ClientSize=New-Object System.Drawing.Size(1080,825)
$form.MinimumSize=New-Object System.Drawing.Size(960,780)
$form.StartPosition='CenterScreen'
$form.BackColor=$BG
$form.ForeColor=$WHITE
$form.Font=New-Object System.Drawing.Font('Segoe UI',10)
$form.AutoScaleMode=[System.Windows.Forms.AutoScaleMode]::Font

$script:SelectedProfile='FabMode'
$script:SelectedProfileTitle=$null
$script:SelectedProfileDetails=$null
$script:SelectedProfileHint=$null
function New-CafeLabel {
    param([string]$Text,[int]$FontSize=10,[switch]$Strong)
    $label=New-Object System.Windows.Forms.Label
    $label.Text=$Text
    $label.Dock='Fill'
    $label.ForeColor=if($Strong){$WHITE}else{$MUTED}
    $label.Font=New-Object System.Drawing.Font('Segoe UI',$FontSize,$(if($Strong){[System.Drawing.FontStyle]::Bold}else{[System.Drawing.FontStyle]::Regular}))
    $label.TextAlign='MiddleLeft'
    $label.AutoEllipsis=$true
    return $label
}
function Style-CafeButton {
    param($Button,[switch]$Primary)
    $Button.FlatStyle='Flat'
    $Button.FlatAppearance.BorderSize=0
    $Button.BackColor=if($Primary){$BLUE}else{$PANEL}
    $Button.ForeColor=$WHITE
    $Button.Font=New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
    $Button.Cursor=[System.Windows.Forms.Cursors]::Hand
    $Button.Margin=New-Object System.Windows.Forms.Padding(4)
}
function Update-SelectedProfileCard {
    param([string]$Name)
    if(-not $script:GamingProfiles.Contains($Name)){return}
    $script:SelectedProfile=$Name
    $p=$script:GamingProfiles[$Name]
    if($script:SelectedProfileTitle){$script:SelectedProfileTitle.Text=$Name}
    if($script:SelectedProfileDetails){
        $script:SelectedProfileDetails.Text=('DPI: '+[string]$p.LogitechDPI+'     Pointer: '+[string]$p.PointerSpeed+
            [Environment]::NewLine+'CFG: '+[string]$p.ConfigFile+
            [Environment]::NewLine+'Display: '+[string]$p.Width+'x'+[string]$p.Height+' @'+[string]$p.RefreshHz+' Hz')
    }
    if($script:SelectedProfileHint){
        $script:SelectedProfileHint.Text='Cloud settings refresh when you open Edit or apply this profile.'
    }
}
$root=New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock='Fill'
$root.ColumnCount=1
$root.RowCount=4
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute',82)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent',100)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute',44)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute',30)))
$form.Controls.Add($root)
$header=New-Object System.Windows.Forms.Panel
$header.Dock='Fill'
$header.BackColor=$PANEL
$root.Controls.Add($header,0,0)
$title=New-CafeLabel -Text 'CAFE  LAUNCHER' -FontSize 22 -Strong
$title.Dock='None'
$title.Location=New-Object System.Drawing.Point(24,8)
$title.Size=New-Object System.Drawing.Size(450,39)
$header.Controls.Add($title)
$subtitle=New-CafeLabel -Text 'CS2 Setup Center   |   Profiles / Graphics / DPI' -FontSize 9
$subtitle.Dock='None'
$subtitle.Location=New-Object System.Drawing.Point(28,49)
$subtitle.Size=New-Object System.Drawing.Size(600,25)
$header.Controls.Add($subtitle)
$headerStatus=New-Object System.Windows.Forms.Panel
$headerStatus.Dock='Right'
$headerStatus.Width=270
$headerStatus.Height=82
$headerStatus.BackColor=$PANEL
$header.Controls.Add($headerStatus)
$versionTag=New-CafeLabel -Text ('v'+(Get-CafeLauncherRelease)) -Strong
$versionTag.Dock='None'
$versionTag.Location=New-Object System.Drawing.Point(8,12)
$versionTag.Size=New-Object System.Drawing.Size(250,27)
$versionTag.ForeColor=[System.Drawing.Color]::FromArgb(111,177,255)
$versionTag.TextAlign='MiddleRight'
$headerStatus.Controls.Add($versionTag)
$script:GitHubRateLimitLabel=New-CafeLabel -Text 'GitHub API: waiting for request' -FontSize 8
$script:GitHubRateLimitLabel.Dock='None'
$script:GitHubRateLimitLabel.Location=New-Object System.Drawing.Point(8,43)
$script:GitHubRateLimitLabel.Size=New-Object System.Drawing.Size(250,36)
$script:GitHubRateLimitLabel.ForeColor=$MUTED
$script:GitHubRateLimitLabel.TextAlign='MiddleRight'
$headerStatus.Controls.Add($script:GitHubRateLimitLabel)
if($script:GitHubRateLimitSnapshot){
    Set-CafeGitHubRateLimitDisplay -Remaining ([string]$script:GitHubRateLimitSnapshot.Remaining) `
        -Limit ([string]$script:GitHubRateLimitSnapshot.Limit)
}

$tabs=New-Object System.Windows.Forms.TabControl
$tabs.Dock='Fill'
$tabs.Margin=New-Object System.Windows.Forms.Padding(13,8,13,8)
$root.Controls.Add($tabs,0,1)
$dashboard=New-Object System.Windows.Forms.TabPage
$dashboard.Text='Dashboard'
$dashboard.BackColor=$BG
$utilities=New-Object System.Windows.Forms.TabPage
$utilities.Text='Tools & Apps'
$utilities.BackColor=$BG
[void]$tabs.TabPages.Add($dashboard)
[void]$tabs.TabPages.Add($utilities)
$dashGrid=New-Object System.Windows.Forms.TableLayoutPanel
$dashGrid.Dock='Fill'
$dashGrid.ColumnCount=2
$dashGrid.Padding=New-Object System.Windows.Forms.Padding(8)
[void]$dashGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent',57)))
[void]$dashGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent',43)))
$dashboard.Controls.Add($dashGrid)
$profilesGrid=New-Object System.Windows.Forms.TableLayoutPanel
$profilesGrid.Dock='Fill'
$profilesGrid.RowCount=6
$profilesGrid.ColumnCount=1
[void]$profilesGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute',45)))
for($i=1;$i -le 5;$i++){[void]$profilesGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent',20)))}
$profilesGrid.Controls.Add((New-CafeLabel -Text 'NEW? Capture CS2 settings into a profile  |  Apply, Play, Graphics, Edit' -Strong),0,0)
$dashGrid.Controls.Add($profilesGrid,0,0)

$rightGrid=New-Object System.Windows.Forms.TableLayoutPanel
$rightGrid.Dock='Fill'
$rightGrid.ColumnCount=1
$rightGrid.RowCount=7
$rightGrid.Padding=New-Object System.Windows.Forms.Padding(10)
foreach($size in @(38,48,110,55,110,66)){
    [void]$rightGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute',$size)))
}
[void]$rightGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent',100)))
$dashGrid.Controls.Add($rightGrid,1,0)
$rightGrid.Controls.Add((New-CafeLabel -Text 'SELECTED PROFILE' -Strong),0,0)
$script:SelectedProfileTitle=New-CafeLabel -Text 'FabMode' -FontSize 22 -Strong
$rightGrid.Controls.Add($script:SelectedProfileTitle,0,1)
$script:SelectedProfileDetails=New-CafeLabel -Text '' -FontSize 11
$script:SelectedProfileDetails.ForeColor=$WHITE
$script:SelectedProfileDetails.BackColor=$PANEL
$script:SelectedProfileDetails.Padding=New-Object System.Windows.Forms.Padding(14)
$rightGrid.Controls.Add($script:SelectedProfileDetails,0,2)
$script:SelectedProfileHint=New-CafeLabel -Text 'Graphics is separate from profile Apply.' -FontSize 9
$rightGrid.Controls.Add($script:SelectedProfileHint,0,3)
$rightGrid.Controls.Add((New-CafeLabel -Text 'Apply changes to the mouse with the control above.' -FontSize 9),0,6)

$toolsGrid=New-Object System.Windows.Forms.TableLayoutPanel
$toolsGrid.Dock='Fill'
$toolsGrid.RowCount=2
$toolsGrid.ColumnCount=1
$toolsGrid.Padding=New-Object System.Windows.Forms.Padding(16)
[void]$toolsGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute',54)))
[void]$toolsGrid.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent',100)))
$toolsGrid.Controls.Add((New-CafeLabel -Text 'TOOLS & APPLICATIONS   |   Separate from profiles' -FontSize 13 -Strong),0,0)
$utilities.Controls.Add($toolsGrid)
$toolsFlow=New-Object System.Windows.Forms.FlowLayoutPanel
$toolsFlow.Dock='Fill'
$toolsFlow.AutoScroll=$true
$toolsFlow.WrapContents=$true
$toolsGrid.Controls.Add($toolsFlow,0,1)

function New-Tile {
    param([string]$Text,[int]$Index,[scriptblock]$Action,[switch]$Primary,[string]$EditProfile='')
    $button=New-Object System.Windows.Forms.Button
    $button.Text=if($EditProfile){"Apply $Text"}else{$Text}
    Style-CafeButton -Button $button -Primary:$Primary
    $actionToRun=$Action
    if($EditProfile){
        $selectedProfile=$EditProfile
        $card=New-Object System.Windows.Forms.TableLayoutPanel
        $card.Dock='Fill'
        $card.ColumnCount=5
        $card.RowCount=1
        $profileColor=$script:ProfileAccentColors[$selectedProfile]
        $card.BackColor=$profileColor
        $card.Padding=New-Object System.Windows.Forms.Padding(2)
        $card.Tag=$selectedProfile
        $card.Margin=New-Object System.Windows.Forms.Padding(3)
        foreach($pct in @(24,20,20,14,22)){[void]$card.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent',$pct)))}
        $button.Dock='Fill'
        $button.Add_Click({
            Update-SelectedProfileCard -Name $selectedProfile
            Write-Log ('Clicked: Apply '+$selectedProfile)
            try { & $actionToRun; Update-SelectedProfileCard -Name $selectedProfile }
            catch { Write-Log ('Profile '+$selectedProfile+' failed: '+$_.Exception.Message) 'ERROR' }
        }.GetNewClosure())
        $card.Controls.Add($button,0,0)
        $play=New-Object System.Windows.Forms.Button
        $play.Text='Play + Exec'
        Style-CafeButton -Button $play
        $play.BackColor=[System.Drawing.Color]::FromArgb(38,132,102)
        $play.Dock='Fill'
        $play.Add_Click({
            Update-SelectedProfileCard -Name $selectedProfile
            try { Start-CS2WithProfileCfg -ProfileName $selectedProfile }
            catch{Write-Log ('Play + Exec failed for '+$selectedProfile+': '+$_.Exception.Message) 'ERROR'}
        }.GetNewClosure())
        $card.Controls.Add($play,1,0)
        $graphics=New-Object System.Windows.Forms.Button
        $graphics.Text='Graphics'
        Style-CafeButton -Button $graphics
        $graphics.BackColor=[System.Drawing.Color]::FromArgb(77,72,125)
        $graphics.Dock='Fill'
        $graphics.Add_Click({
            Update-SelectedProfileCard -Name $selectedProfile
            try { Invoke-GraphicsOnly -ModeName $selectedProfile }
            catch{Write-Log ('Graphics failed for '+$selectedProfile+': '+$_.Exception.Message) 'ERROR'}
        }.GetNewClosure())
        $card.Controls.Add($graphics,2,0)
        $edit=New-Object System.Windows.Forms.Button
        $edit.Text=[string]([char]0x2699)+' Edit '+$selectedProfile
        Style-CafeButton -Button $edit
        $edit.BackColor=[System.Drawing.Color]::FromArgb(47,56,72)
        $edit.Dock='Fill'
        $edit.Add_Click({
            Update-SelectedProfileCard -Name $selectedProfile
            try{
                Show-ProfileEditor -ProfileName $selectedProfile
                Update-SelectedProfileCard -Name $selectedProfile
            }catch{Write-Log ('Editor failed: '+$_.Exception.Message) 'ERROR'}
        }.GetNewClosure())
        $card.Controls.Add($edit,3,0)
        $capture=New-Object System.Windows.Forms.Button
        $capture.Text='Capture CS2'
        Style-CafeButton -Button $capture
        $capture.BackColor=[System.Drawing.Color]::FromArgb(44,90,112)
        $capture.Dock='Fill'
        $capture.Add_Click({
            try{
                Show-ProfileEditor -ProfileName $selectedProfile -CaptureOnOpen
                Update-SelectedProfileCard -Name $selectedProfile
            }catch{Write-Log ('Capture shortcut failed for '+$selectedProfile+': '+$_.Exception.Message) 'ERROR'}
        }.GetNewClosure())
        $card.Controls.Add($capture,4,0)
        # Track pointer position over the entire row, including its child buttons.
        # Avoid a white hover border against the dark dashboard.
        $rowHover=New-Object System.Windows.Forms.Timer
        $rowHover.Interval=80
        $rowHover.Add_Tick({
            if($card.IsDisposed){$rowHover.Stop();$rowHover.Dispose();return}
            $pointer=$card.PointToClient([System.Windows.Forms.Cursor]::Position)
            $inside=$card.ClientRectangle.Contains($pointer)
            $desired=if($inside){[System.Drawing.Color]::FromArgb(238,238,245)}else{$profileColor}
            if($card.BackColor.ToArgb() -ne $desired.ToArgb()){$card.BackColor=$desired}
        }.GetNewClosure())
        $rowHover.Start()
        $profilesGrid.Controls.Add($card,0,($Index-5))
    }else{
        $button.Add_Click({
            Write-Log ('Clicked: '+$this.Text)
            try { & $actionToRun }
            catch {
                Write-Log ('Button error: '+$_.Exception.Message) 'ERROR'
                [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'CafeLauncher','OK','Warning')
            }
        }.GetNewClosure())
        if($Index -eq 0){
            $button.Dock='Fill'
            $rightGrid.Controls.Add($button,0,5)
        }else{
            $button.Size=New-Object System.Drawing.Size(198,58)
            $toolsFlow.Controls.Add($button)
        }
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
# Legacy FabMode-only shortcuts are disabled. Keep these definitions for possible
# re-enable later; regular profiles can still apply NVIDIA settings and install CFGs.
# New-Tile "Apply NVIDIA Settings" 13 { Apply-NvidiaGamingSettings } -Primary
# New-Tile "Install CS2 fab.cfg" 14 {
#     [void](Install-AtCfg -CfgName 'fab.cfg' -DownloadUrl $script:FabCfgCloudUrl -CloudPreferred)
# } -Primary
New-Tile "Detect PC" 15 { Show-PCDiagnostics }
New-Tile "Check for Updates" 16 { Check-CafeLauncherUpdates -Manual }
New-Tile "Exit" 17 { $form.Close() }
# Editable DPI input replaces the fixed-800 live button in tile 18.
$manualDpiPanel=New-Object System.Windows.Forms.Panel
$manualDpiPanel.Dock='Fill'
$manualDpiPanel.Margin=New-Object System.Windows.Forms.Padding(5,8,5,8)
$manualDpiPanel.BackColor=$PANEL
$rightGrid.Controls.Add($manualDpiPanel,0,4)

$manualDpiLabel=New-Object System.Windows.Forms.Label
$manualDpiLabel.Text='DPI (100 - 25600)'
$manualDpiLabel.Location=New-Object System.Drawing.Point(12,8)
$manualDpiLabel.Size=New-Object System.Drawing.Size(220,20)
$manualDpiLabel.Font=New-Object System.Drawing.Font('Segoe UI',8)
$manualDpiLabel.ForeColor=$WHITE
$manualDpiPanel.Controls.Add($manualDpiLabel)

$script:ManualDpiInput=New-Object System.Windows.Forms.TextBox
$script:ManualDpiInput.Text='800'
$script:ManualDpiInput.Location=New-Object System.Drawing.Point(12,38)
$script:ManualDpiInput.Size=New-Object System.Drawing.Size(110,30)
$script:ManualDpiInput.MaxLength=5
$script:ManualDpiInput.Font=New-Object System.Drawing.Font('Segoe UI',11)
$script:ManualDpiInput.ForeColor=$WHITE
$script:ManualDpiInput.BackColor=$BG
$manualDpiPanel.Controls.Add($script:ManualDpiInput)

$script:ManualDpiChangeButton=New-Object System.Windows.Forms.Button
$script:ManualDpiChangeButton.Text='Change DPI'
$script:ManualDpiChangeButton.Location=New-Object System.Drawing.Point(130,32)
$script:ManualDpiChangeButton.Size=New-Object System.Drawing.Size(142,40)
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


$logPane=New-Object System.Windows.Forms.TableLayoutPanel
$logPane.Dock='Fill'
$logPane.ColumnCount=3
$logPane.RowCount=2
$logPane.BackColor=$PANEL
$logPane.Margin=New-Object System.Windows.Forms.Padding(15,0,15,0)
[void]$logPane.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent',100)))
[void]$logPane.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute',110)))
[void]$logPane.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute',110)))
[void]$logPane.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute',42)))
[void]$logPane.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent',100)))
$root.Controls.Add($logPane,0,2)
$statusLine=New-CafeLabel -Text 'Ready - check logs for detailed operation results.' -FontSize 9
$script:StatusLine=$statusLine
$logPane.Controls.Add($statusLine,0,0)
$logToggle=New-Object System.Windows.Forms.Button
$logToggle.Text='Show Logs'
Style-CafeButton -Button $logToggle
$logToggle.Dock='Fill'
$logPane.Controls.Add($logToggle,1,0)
$clearLogs=New-Object System.Windows.Forms.Button
$clearLogs.Text='Clear Logs'
Style-CafeButton -Button $clearLogs
$clearLogs.Dock='Fill'
$logPane.Controls.Add($clearLogs,2,0)
$script:LogBox=New-Object System.Windows.Forms.TextBox
$script:LogBox.Dock='Fill'
$script:LogBox.Multiline=$true
$script:LogBox.ReadOnly=$true
$script:LogBox.ScrollBars=[System.Windows.Forms.ScrollBars]::Vertical
$script:LogBox.WordWrap=$false
$script:LogBox.BackColor=[System.Drawing.Color]::FromArgb(12,15,20)
$script:LogBox.ForeColor=[System.Drawing.Color]::FromArgb(190,220,190)
$script:LogBox.Font=New-Object System.Drawing.Font('Consolas',9)
$logPane.Controls.Add($script:LogBox,0,1)
$logPane.SetColumnSpan($script:LogBox,3)
$script:LogBox.Visible=$false
$script:LogsExpanded=$false
$logToggle.Add_Click({
    $script:LogsExpanded= -not $script:LogsExpanded
    $root.RowStyles[2].Height=if($script:LogsExpanded){185}else{44}
    $script:LogBox.Visible=$script:LogsExpanded
    $logToggle.Text=if($script:LogsExpanded){'Hide Logs'}else{'Show Logs'}
})
$clearLogs.Add_Click({
    if($script:LogBox){$script:LogBox.Clear()}
    try{Set-Content -LiteralPath $script:LogPath -Value '' -Encoding UTF8}catch{}
    Write-Log 'Logs cleared.'
})
try {$script:LogBox.Text=Get-Content -LiteralPath $script:LogPath -Raw -ErrorAction Stop}catch{}
Write-Log ('CafeLauncher dashboard ready. Log file: '+$script:LogPath)
Update-SelectedProfileCard -Name 'FabMode'
$footer=New-CafeLabel -Text '  CAFE LAUNCHER | production dashboard | %TEMP%\CafeLauncher.log' -FontSize 9
$root.Controls.Add($footer,0,3)

$form.Add_FormClosed({
    if($script:LogihubDownloadTimer){$script:LogihubDownloadTimer.Stop();$script:LogihubDownloadTimer.Dispose();$script:LogihubDownloadTimer=$null}
    if($script:LiveDpiVerificationTimer){$script:LiveDpiVerificationTimer.Stop();$script:LiveDpiVerificationTimer.Dispose();$script:LiveDpiVerificationTimer=$null}
    $script:LogihubRequestedDPI=$null
    if ($script:ColorWatchTimer) {
        try {$script:ColorWatchTimer.Stop();$script:ColorWatchTimer.Dispose()}catch{}
        Write-Log 'Color Watch stopped because the launcher closed.'
    }
})
# On first display, automatically inventory the machine and check GitHub for
# an update. One-shot timer lets Windows render the UI before network access.
$startupTimer = New-Object System.Windows.Forms.Timer
$startupTimer.Interval=350
$startupTimer.Add_Tick({
    $startupTimer.Stop()
    $startupTimer.Dispose()
    # Check for a newer build before slower hardware/game discovery so startup
    # inventory cannot delay the update prompt. The updater only prompts when
    # GitHub reports a newer release; failures remain in LIVE LOGS.
    Check-CafeLauncherUpdates
    # Profile and graphics settings refresh only when their profile is opened
    # or applied, instead of spending requests on every profile at startup.
    try {
        Write-Log 'Automatic startup inventory:'
        $summary = Get-PCDiagnostics
        foreach ($line in ($summary -split '\r?\n')) { if ($line) { Write-Log ('PC: ' + $line) } }
    } catch { Write-Log "Startup inventory failed: $($_.Exception.Message)" 'WARN' }
})
$form.Add_Shown({ $startupTimer.Start() })
[void]$form.ShowDialog()
