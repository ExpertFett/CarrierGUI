<#
    Reverts the CarrierGUI LSO-tab NVG toggle patch on PLATCameraUI.lua.
    Restores from PLATCameraUI.lua.platcamnvg.bak and removes the backup.

    Does NOT touch gui.fx — the PlatCam-NVG amplification stays in place.
    After disabling the toggle, the PLAT cam goes back to always-on NVG
    (the original PlatCam-NVG behavior).

    Self-elevates (UAC).
#>

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath))
    exit
}

$candidates = @(
    'C:\Program Files\Eagle Dynamics\DCS World',
    'C:\Program Files\Eagle Dynamics\DCS World OpenBeta'
)
$found = 0
foreach ($dcs in $candidates) {
    $lua    = Join-Path $dcs 'Mods\tech\Supercarrier\PLATCameraUI\PLATCameraUI.lua'
    $luaBak = "$lua.platcamnvg.bak"
    if (Test-Path $luaBak) {
        Copy-Item $luaBak $lua -Force
        Remove-Item $luaBak -Force
        Write-Host "Restored: $lua" -ForegroundColor Green
        $found++
    }
}

if ($found -eq 0) {
    Write-Host 'No PLATCameraUI.lua.platcamnvg.bak found — already clean.'
} else {
    Write-Host ''
    Write-Host 'Toggle disabled. PLAT cam returns to always-on NVG (if gui.fx is still patched).' -ForegroundColor Cyan
}
pause
