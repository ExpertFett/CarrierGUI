@echo off
REM ============================================================
REM Drag any .miz file (or multiple) onto this script to embed
REM the CarrierGUI bridge + lights triggers. Idempotent — safe
REM to run on the same .miz multiple times.
REM
REM A .miz.bak backup is created next to the original on the
REM first patch. A <missionname>-patchlog.txt is written next
REM to the .miz every run with full diagnostic info, so silent
REM failures stop being silent.
REM ============================================================
setlocal
set HERE=%~dp0
set PY=%HERE%python\python.exe

if "%~1"=="" (
    echo Usage:
    echo   Drag one or more .miz files onto this script.
    echo.
    pause
    exit /b 1
)

if not exist "%PY%" (
    echo ERROR: Bundled Python not found at:
    echo   %PY%
    echo.
    echo Make sure you extracted the entire CarrierGUI zip,
    echo including the Patcher\python\ folder. Re-extract the
    echo zip and try again.
    echo.
    pause
    exit /b 1
)

REM Strip Mark-of-the-Web from anything in this folder. Windows tags every
REM file extracted from a downloaded zip; SmartScreen can silently refuse
REM to launch the bundled python.exe — which makes the patcher look like
REM it "just didn't do anything". Best-effort, no error if PowerShell is
REM unavailable.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Path '%HERE%' -Recurse -File | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1

"%PY%" "%HERE%patch_miz.py" %*
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (
    echo === Done. ===
) else (
    echo === FAILED — see messages above + the *-patchlog.txt
    echo     next to your .miz file for full diagnostics. ===
)
pause
