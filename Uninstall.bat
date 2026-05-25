@echo off
REM ============================================================
REM CarrierGUI uninstaller — removes the hook files from all
REM detected DCS Saved Games installs.
REM ============================================================
setlocal EnableDelayedExpansion

set REMOVED=0
set ROOTS=DCS DCS.openbeta DCS World DCS World OpenBeta

echo.
echo === CarrierGUI uninstaller ===
echo.

for %%R in (%ROOTS%) do (
    set "TARGET=%USERPROFILE%\Saved Games\%%R\Scripts\Hooks"
    if exist "!TARGET!\carrier-gui-hook.lua" (
        del /Q "!TARGET!\carrier-gui-hook.lua" >nul 2>&1
        echo Removed: !TARGET!\carrier-gui-hook.lua
        set /a REMOVED+=1
    )
    if exist "!TARGET!\carrier-gui.dlg" (
        del /Q "!TARGET!\carrier-gui.dlg" >nul 2>&1
        echo Removed: !TARGET!\carrier-gui.dlg
        set /a REMOVED+=1
    )
)

echo.
if "%REMOVED%"=="0" (
    echo Nothing to remove — CarrierGUI was not installed.
) else (
    echo Done. Removed %REMOVED% file(s^).
    echo Note: any .miz files you patched still contain the bridge code.
    echo If you want a clean .miz too, drag it onto "Patcher\Revert Mission.bat".
)
echo.
pause
