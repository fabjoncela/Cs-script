
@echo off
set "CAFE_SCRIPT=%~f0"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command "$l=Get-Content -LiteralPath $env:CAFE_SCRIPT; $i=[Array]::IndexOf($l,'# POWERSHELL_GUI'); if($i -ge 0){Invoke-Expression ($l[($i+1)..($l.Length-1)] -join [Environment]::NewLine)}"
exit /b

# POWERSHELL_GUI

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:BG = [System.Drawing.Color]::FromArgb(20, 23, 30)
$script:PANEL = [System.Drawing.Color]::FromArgb(31, 36, 46)
$script:BLUE = [System.Drawing.Color]::FromArgb(35, 125, 245)
$script:WHITE = [System.Drawing.Color]::FromArgb(240, 243, 248)
$script:MUTED = [System.Drawing.Color]::FromArgb(160, 170, 185)

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
    param(
        [string[]]$Paths,
        [string]$Name
    )

    $appPath = Find-App -Paths $Paths

    if ($appPath) {
        try {
            Start-Process -FilePath $appPath
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Could not launch $Name.`n$($_.Exception.Message)",
                "Cafe Launcher"
            )
        }
    } else {
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
    Start-Process -FilePath "$env:windir\System32\control.exe" `
        -ArgumentList "main.cpl,,2"
}

function Apply-FabMode {
    $mousePath = "HKCU:\Control Panel\Mouse"

    try {
        # Windows mouse speed: 6/11
        Set-ItemProperty -Path $mousePath -Name MouseSensitivity -Value "10"

        # Disable Enhance Pointer Precision
        Set-ItemProperty -Path $mousePath -Name MouseSpeed -Value "0"
        Set-ItemProperty -Path $mousePath -Name MouseThreshold1 -Value "0"
        Set-ItemProperty -Path $mousePath -Name MouseThreshold2 -Value "0"

        # Apply settings immediately through Windows
        if (-not ("FabMouseNative" -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class FabMouseNative {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool SystemParametersInfo(
        uint action, uint uiParam, IntPtr pvParam, uint flags);
}
"@
        }

        # SPI_SETMOUSE: thresholds 0, 0 and acceleration 0
        $ptr = [Runtime.InteropServices.Marshal]::AllocHGlobal(12)

        try {
            [Runtime.InteropServices.Marshal]::WriteInt32($ptr, 0, 0)
            [Runtime.InteropServices.Marshal]::WriteInt32($ptr, 4, 0)
            [Runtime.InteropServices.Marshal]::WriteInt32($ptr, 8, 0)

            [FabMouseNative]::SystemParametersInfo(
                0x0004, 0, $ptr, 0x03
            ) | Out-Null
        } finally {
            [Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)
        }

        # SPI_SETMOUSESPEED: value 10 corresponds to 6/11
        [FabMouseNative]::SystemParametersInfo(
            0x0071, 10, [IntPtr]::Zero, 0x03
        ) | Out-Null

        # Open Pointer Options
        Open-MousePointerOptions

    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "FabMode could not apply all mouse settings.`n$($_.Exception.Message)",
            "FabMode"
        )
    }
}

function Open-NvidiaControlPanel {
    # Check traditional desktop installations
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

    # Check the installed Microsoft Store app in Start
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

    # Last fallback: open the Store listing
    Start-Process "ms-windows-store://pdp/?ProductId=9NF8H0H7WMLT"
}

function Open-GHub {
    Launch-App -Name "Logitech G HUB" -Paths @(
        "$env:ProgramFiles\LGHUB\lghub.exe",
        "$env:ProgramFiles\LGHUB\lghub_system_tray.exe"
    )
}

function Launch-All {
    Launch-App -Name "Steam" -Paths @(
        "$env:ProgramFiles(x86)\Steam\steam.exe",
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
$form.Size = New-Object System.Drawing.Size(800, 620)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.BackColor = $script:BG
$form.ForeColor = $script:WHITE
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)

# Header
$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point(0, 0)
$header.Size = New-Object System.Drawing.Size(800, 105)
$header.BackColor = $script:PANEL
$form.Controls.Add($header)

$title = New-Object System.Windows.Forms.Label
$title.Text = "GAMING CAFE"
$title.Location = New-Object System.Drawing.Point(28, 18)
$title.Size = New-Object System.Drawing.Size(500, 38)
$title.Font = New-Object System.Drawing.Font("Segoe UI", 21, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = $script:WHITE
$header.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = "APP LAUNCHER  |  PC SETTINGS"
$subtitle.Location = New-Object System.Drawing.Point(31, 62)
$subtitle.Size = New-Object System.Drawing.Size(500, 23)
$subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$subtitle.ForeColor = $script:MUTED
$header.Controls.Add($subtitle)

# Reusable tile creator
function New-Tile {
    param(
        [string]$Text,
        [int]$Index,
        [scriptblock]$Action,
        [switch]$Primary
    )

    $columns = 3
    $col = $Index % $columns
    $row = [Math]::Floor($Index / $columns)

    $x = 25 + ($col * 250)
    $y = 125 + ($row * 88)

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($x, $y)
    $button.Size = New-Object System.Drawing.Size(235, 70)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 0
    $button.BackColor = if ($Primary) { $script:BLUE } else { $script:PANEL }
    $button.ForeColor = $script:WHITE
    $button.Font = New-Object System.Drawing.Font(
        "Segoe UI", 10, [System.Drawing.FontStyle]::Bold
    )
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.Add_Click($Action)

    $form.Controls.Add($button)
}

# Application buttons
New-Tile "LAUNCH ALL" 0 {
    Launch-All
} -Primary

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

New-Tile "FACEIT Matchmaking" 3 {
    Open-FaceitMatchmaking
}

New-Tile "Spotify" 4 {
    Open-Spotify
}

New-Tile "FabMode" 5 {
    Apply-FabMode
} -Primary

New-Tile "Mouse Pointer Options" 6 {
    Open-MousePointerOptions
}

New-Tile "NVIDIA Control Panel" 7 {
    Open-NvidiaControlPanel
}

New-Tile "Logitech G HUB" 8 {
    Open-GHub
}

New-Tile "Sound Settings" 9 {
    Start-Process "mmsys.cpl"
}

New-Tile "Display Settings" 10 {
    Start-Process "ms-settings:display"
}

New-Tile "Network Connections" 11 {
    Start-Process "ncpa.cpl"
}

New-Tile "Task Manager" 12 {
    Start-Process "taskmgr.exe"
}

New-Tile "Exit" 13 {
    $form.Close()
}

# Footer
$footer = New-Object System.Windows.Forms.Label
$footer.Text = "GAMING CAFE  |  WINDOWS TOOLKIT"
$footer.Location = New-Object System.Drawing.Point(28, 545)
$footer.Size = New-Object System.Drawing.Size(700, 22)
$footer.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$footer.ForeColor = $script:MUTED
$form.Controls.Add($footer)

[void]$form.ShowDialog()
