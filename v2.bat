
@echo off
if /i "%~1"=="__gui" goto gui
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command " & { $p = Get-Content -LiteralPath '%~f0'; $i = [Array]::IndexOf($p, ':__POWERSHELL__'); $s = $p[($i+1)..($p.Length-1)] -join [Environment]::NewLine; Invoke-Expression $s }"
exit /b

:__POWERSHELL__
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object Windows.Forms.Form
$form.Text = "Gaming Cafe Control Panel"
$form.Size = New-Object Drawing.Size(430,470)
$form.StartPosition = "CenterScreen"
$form.BackColor = [Drawing.Color]::FromArgb(25,27,35)
$form.ForeColor = [Drawing.Color]::White
$form.Font = New-Object Drawing.Font("Segoe UI",10)

$title = New-Object Windows.Forms.Label
$title.Text = "GAMING CAFE"
$title.Font = New-Object Drawing.Font("Segoe UI",20,[Drawing.FontStyle]::Bold)
$title.Location = New-Object Drawing.Point(20,15)
$title.Size = New-Object Drawing.Size(370,45)
$form.Controls.Add($title)

function Add-Button($text,$x,$y,$action) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object Drawing.Point($x,$y)
    $b.Size = New-Object Drawing.Size(175,48)
    $b.FlatStyle = "Flat"
    $b.BackColor = [Drawing.Color]::FromArgb(47,53,68)
    $b.ForeColor = [Drawing.Color]::White
    $b.Add_Click($action)
    $form.Controls.Add($b)
}

function Open-Url($url) {
    Start-Process $url
}

Add-Button "LAUNCH GAMING APPS" 20 80 {
    $paths = @(
        "$env:ProgramFiles(x86)\Steam\steam.exe",
        "$env:ProgramFiles\Steam\steam.exe",
        "$env:ProgramFiles\FACEIT AC\faceitclient.exe",
        "$env:ProgramFiles(x86)\FACEIT AC\faceitclient.exe",
        "$env:ProgramFiles\LGHUB\lghub.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { Start-Process $p }
    }
    Open-Url "https://www.faceit.com/en/matchmaking"
    Open-Url "https://open.spotify.com/"
} 

Add-Button "MOUSE POINTER OPTIONS" 215 80 {
    Start-Process "rundll32.exe" -ArgumentList "shell32.dll,Control_RunDLL main.cpl,,2"
}

Add-Button "NVIDIA CONTROL PANEL" 20 140 {
    $n = Get-ChildItem "$env:ProgramFiles\NVIDIA Corporation" -Filter nvcplui.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($n) { Start-Process $n.FullName }
    else { Start-Process "ms-windows-store://pdp/?ProductId=9NF8H0H7WMLT" }
}

Add-Button "LOGITECH G HUB" 215 140 {
    $p = "$env:ProgramFiles\LGHUB\lghub.exe"
    if (Test-Path $p) { Start-Process $p }
    else { [Windows.Forms.MessageBox]::Show("Logitech G HUB was not found.") }
}

Add-Button "SOUND SETTINGS" 20 200 {
    Start-Process "ms-settings:sound"
}

Add-Button "DISPLAY SETTINGS" 215 200 {
    Start-Process "ms-settings:display"
}

Add-Button "NETWORK SETTINGS" 20 260 {
    Start-Process "ms-settings:network-status"
}

Add-Button "TASK MANAGER" 215 260 {
    Start-Process "taskmgr.exe"
}

$status = New-Object Windows.Forms.Label
$status.Text = "Ready | Windows Gaming Tools"
$status.Location = New-Object Drawing.Point(20,340)
$status.Size = New-Object Drawing.Size(370,30)
$status.ForeColor = [Drawing.Color]::LightGreen
$form.Controls.Add($status)

[void]$form.ShowDialog()
exit

:__POWERSHELL__
