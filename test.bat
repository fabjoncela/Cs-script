
@echo off
setlocal
title Gaming Setup

echo =====================================
echo       STARTING GAMING SETUP
echo =====================================
echo.

:: =====================================
:: FACEIT ANTI-CHEAT
:: =====================================
set "FACEIT="

if exist "C:\Program Files\FACEIT AC\faceitclient.exe" set "FACEIT=C:\Program Files\FACEIT AC\faceitclient.exe"
if not defined FACEIT if exist "C:\Program Files (x86)\FACEIT AC\faceitclient.exe" set "FACEIT=C:\Program Files (x86)\FACEIT AC\faceitclient.exe"

if defined FACEIT (
    start "" "%FACEIT%"
) else (
    echo FACEIT AC not found - skipping.
)

:: =====================================
:: STEAM
:: =====================================
set "STEAM="

if exist "%ProgramFiles(x86)%\Steam\steam.exe" set "STEAM=%ProgramFiles(x86)%\Steam\steam.exe"
if not defined STEAM if exist "%ProgramFiles%\Steam\steam.exe" set "STEAM=%ProgramFiles%\Steam\steam.exe"

if defined STEAM (
    start "" "%STEAM%"
) else (
    start "" "steam://open/main"
)

:: =====================================
:: GOOGLE CHROME
:: =====================================
set "CHROME="

if exist "%ProgramFiles%\Google\Chrome\Application\chrome.exe" set "CHROME=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
if not defined CHROME if exist "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe" set "CHROME=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
if not defined CHROME if exist "%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe" set "CHROME=%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"

if defined CHROME (
    start "" "%CHROME%" "https://www.faceit.com/en/matchmaking"
    start "" "%CHROME%" "https://open.spotify.com/"
) else (
    start "" "https://www.faceit.com/en/matchmaking"
    start "" "https://open.spotify.com/"
)

:: =====================================
:: MOUSE - POINTER OPTIONS
:: =====================================
start "" rundll32.exe shell32.dll,Control_RunDLL main.cpl,,2

:: =====================================
:: NVIDIA CONTROL PANEL - DYNAMIC
:: =====================================
echo.
echo Launching NVIDIA Control Panel...

set "NVIDIA_CP="

if exist "%ProgramFiles%\NVIDIA Corporation\Control Panel Client\nvcplui.exe" set "NVIDIA_CP=%ProgramFiles%\NVIDIA Corporation\Control Panel Client\nvcplui.exe"
if not defined NVIDIA_CP if exist "%ProgramFiles(x86)%\NVIDIA Corporation\Control Panel Client\nvcplui.exe" set "NVIDIA_CP=%ProgramFiles(x86)%\NVIDIA Corporation\Control Panel Client\nvcplui.exe"

if not defined NVIDIA_CP (
    for /d %%D in ("%ProgramFiles%\NVIDIA Corporation\*") do (
        if not defined NVIDIA_CP if exist "%%D\nvcplui.exe" set "NVIDIA_CP=%%D\nvcplui.exe"
        if not defined NVIDIA_CP if exist "%%D\Control Panel Client\nvcplui.exe" set "NVIDIA_CP=%%D\Control Panel Client\nvcplui.exe"
    )
)

if defined NVIDIA_CP (
    start "" "%NVIDIA_CP%"
) else (
    start "" "shell:AppsFolder\NVIDIACorp.NVIDIAControlPanel_56jybvy8sckqj!NVIDIAControlPanel"
)

:: =====================================
:: LOGITECH G HUB - LAST
:: =====================================
echo.
echo Launching Logitech G HUB...

set "GHUB="

if exist "%ProgramFiles%\LGHUB\lghub.exe" set "GHUB=%ProgramFiles%\LGHUB\lghub.exe"
if not defined GHUB if exist "%ProgramFiles%\LGHUB\lghub_system_tray.exe" set "GHUB=%ProgramFiles%\LGHUB\lghub_system_tray.exe"

if defined GHUB (
    start "" "%GHUB%"
) else (
    echo Logitech G HUB not found - skipping.
)

echo.
echo =====================================
echo        GAMING SETUP LAUNCHED
echo =====================================

endlocal
exit
