@echo off
REM CarrierGUI - wire the client-side data source into your DCS Export.lua.
REM Idempotent + safe alongside Tacview/SRS. No BOM (Add-Content default).
powershell -NoProfile -ExecutionPolicy Bypass -Command "$e = Join-Path $env:USERPROFILE 'Saved Games\DCS\Scripts\Export.lua'; New-Item -ItemType Directory -Force -Path (Split-Path $e) | Out-Null; if ((-not (Test-Path $e)) -or (-not (Select-String -Path $e -SimpleMatch 'carriergui-export.lua' -Quiet))) { Add-Content -Path $e -Value ''; Add-Content -Path $e -Value 'local cg = lfs.writedir()..[[Scripts\Hooks\carriergui-export.lua]]'; Add-Content -Path $e -Value 'if lfs.attributes(cg) then dofile(cg) end'; Write-Host 'Wired CarrierGUI into Export.lua.' } else { Write-Host 'Already wired - nothing to do.' }"
echo.
echo Done. Launch DCS, join the server, slot in near the carrier, press Ctrl+Shift+c.
pause
