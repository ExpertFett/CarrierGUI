@echo off
REM Drag-drop wrapper that removes the CarrierGUI patch from .miz files.
setlocal
set SCRIPT_DIR=%~dp0
if "%~1"=="" (
    echo Usage: drag one or more .miz files onto this script.
    pause
    exit /b 1
)
python "%SCRIPT_DIR%patch_miz.py" --revert %*
echo.
pause
