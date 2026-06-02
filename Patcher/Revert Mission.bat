@echo off
REM Drag-drop wrapper that removes the CarrierGUI patch from .miz files.
setlocal
set HERE=%~dp0
set PY=%HERE%python\python.exe

if "%~1"=="" (
    echo Usage: drag one or more patched .miz files onto this script.
    echo.
    pause
    exit /b 1
)

if not exist "%PY%" (
    echo ERROR: Bundled Python not found at:
    echo   %PY%
    echo.
    echo Make sure you extracted the entire CarrierGUI zip
    echo including the Patcher\python\ folder.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Path '%HERE%' -Recurse -File | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1

"%PY%" "%HERE%patch_miz.py" --revert %*
echo.
pause
