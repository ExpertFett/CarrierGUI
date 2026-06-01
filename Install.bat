@echo off
REM ============================================================
REM CarrierGUI installer
REM
REM Copies the hook .lua and .dlg into each DCS Saved Games
REM install on this machine. No admin rights needed.
REM ============================================================
setlocal EnableDelayedExpansion

set SCRIPT_DIR=%~dp0
set SRC=%SCRIPT_DIR%Hooks
set INSTALLED=0
set ROOTS=DCS DCS.openbeta DCS World DCS World OpenBeta

echo.
echo === CarrierGUI installer ===
echo.

if not exist "%SRC%\carrier-gui-hook.lua" (
    echo ERROR: Could not find Hooks\carrier-gui-hook.lua next to this script.
    echo Make sure you extracted the whole zip before running Install.bat.
    echo.
    pause
    exit /b 1
)

for %%R in (%ROOTS%) do (
    set "TARGET=%USERPROFILE%\Saved Games\%%R\Scripts\Hooks"
    if exist "%USERPROFILE%\Saved Games\%%R" (
        echo Found  : %USERPROFILE%\Saved Games\%%R
        if not exist "!TARGET!" mkdir "!TARGET!" >nul 2>&1
        copy /Y "%SRC%\carrier-gui-hook.lua" "!TARGET!\carrier-gui-hook.lua" >nul
        copy /Y "%SRC%\carrier-gui.dlg"      "!TARGET!\carrier-gui.dlg"      >nul
        if exist "%SRC%\assets" (
            if not exist "!TARGET!\assets" mkdir "!TARGET!\assets" >nul 2>&1
            xcopy /Y /I /Q "%SRC%\assets\*"  "!TARGET!\assets\"    >nul
        )
        if errorlevel 1 (
            echo   FAILED to copy files
        ) else (
            echo   Installed -^> !TARGET!
            set /a INSTALLED+=1
        )
    )
)

echo.
if "%INSTALLED%"=="0" (
    echo ERROR: No DCS Saved Games folder found.
    echo Expected one of:
    for %%R in (%ROOTS%) do echo   %USERPROFILE%\Saved Games\%%R
    echo.
    echo Run DCS once first to create its Saved Games folder, then re-run this.
) else (
    echo Done. Installed into %INSTALLED% DCS folder(s^).
    echo.
    echo Next steps:
    echo   1. Restart DCS if it is running.
    echo   2. Start a mission, then press Ctrl+Shift+c to open the panel.
    echo   3. To make a mission's buttons work, drag the .miz onto
    echo      "Patcher\Patch Mission.bat".
    echo.
    echo ----------------------------------------------------------------
    echo The LSO tab has a PLAT-cam NVG gain dial. It requires patching
    echo two DCS files (gui.fx + PLATCameraUI.lua). UAC will prompt.
    echo This is OPTIONAL — skip if you don't want the NVG feature.
    echo ----------------------------------------------------------------
    set /p ENABLE_NVG="Enable LSO tools (NVG dial + foul/wire/zoom) now? [y/N] "
    if /i "!ENABLE_NVG!"=="y" (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%LSO\Enable-LsoTools.ps1"
    ) else (
        echo Skipped. You can run "LSO\Enable-LsoTools.ps1" later to enable them.
    )
)
echo.
pause
