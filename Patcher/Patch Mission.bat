@echo off
REM Drag-drop wrapper for patch_miz.py.
REM Drop one or more .miz files onto this .bat and they will be patched in place
REM with the CarrierGUI bridge + lights triggers. A .miz.bak backup is created.
setlocal
set SCRIPT_DIR=%~dp0
if "%~1"=="" (
    echo Usage: drag one or more .miz files onto this script.
    pause
    exit /b 1
)
python "%SCRIPT_DIR%patch_miz.py" %*
echo.
pause
