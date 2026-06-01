<#
    Reverts Enable-LsoTools.ps1 (or the v1.0 Enable-NvgDial.ps1, same .bak
    files). Restores both gui.fx and PLATCameraUI.lua from their pristine
    .platcamnvg.bak siblings. Clears shader cache so DCS picks up the
    restored shader on next launch.

    Leaves the .bak files in place so re-enabling is one click.

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

$restored = 0
foreach ($dcs in $candidates) {
    foreach ($pair in @(
        @{ live = (Join-Path $dcs 'Bazar\shaders\MissionEditor\gui.fx');
           name = 'gui.fx' },
        @{ live = (Join-Path $dcs 'Mods\tech\Supercarrier\PLATCameraUI\PLATCameraUI.lua');
           name = 'PLATCameraUI.lua' }
    )) {
        $bak = "$($pair.live).platcamnvg.bak"
        if (Test-Path $bak) {
            Copy-Item $bak $pair.live -Force
            Write-Host "Restored $($pair.name) ($dcs)" -ForegroundColor Green
            $restored++
        }
    }
}

if ($restored -eq 0) {
    Write-Host 'No .platcamnvg.bak files found — nothing to revert.'
} else {
    foreach ($c in @('metashaders2','fxo','fxo2')) {
        foreach ($sg in @('Saved Games\DCS','Saved Games\DCS.openbeta')) {
            $p = Join-Path $env:USERPROFILE (Join-Path $sg $c)
            if (Test-Path $p) {
                Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Write-Host ''
    Write-Host 'Done. CarrierGUI LSO tools fully disabled.' -ForegroundColor Cyan
    Write-Host 'NOTE: first DCS launch after this will be slow (shader cache rebuild).'
}
pause
