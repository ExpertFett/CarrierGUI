<#
    Enables the CarrierGUI LSO-tab NVG toggle by patching DCS's Supercarrier
    PLATCameraUI.lua. The patch reads a small flag file written by the
    CarrierGUI hook and sets the PLAT widget's color accordingly:

        carriergui_nvg.txt = "1" -> sentinel 0x00ffc0ff -> gui.fx amplifies (NVG ON)
        carriergui_nvg.txt = "0" -> 0xffffffff           -> normal feed (NVG OFF)

    Prerequisites:
      1. PlatCam-NVG installer must already be run (gui.fx must be patched).
      2. CarrierGUI must be installed (Install.bat in the v0.5+ release).

    What it does:
      * Backs up PLATCameraUI.lua -> PLATCameraUI.lua.platcamnvg.bak (once).
      * Restores from backup first if patched before, then re-injects.
      * Hooks setShipYawPitchRoll (runs per-frame while PLAT is visible).

    Safe to re-run. Undo with Disable-NvgToggle.ps1.
    Self-elevates (UAC). Patches a Program Files file -> needs admin.
#>

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath))
    exit
}

$ErrorActionPreference = 'Stop'

# Detect DCS install (try stable first, then openbeta)
$candidates = @(
    'C:\Program Files\Eagle Dynamics\DCS World',
    'C:\Program Files\Eagle Dynamics\DCS World OpenBeta'
)
$dcs = $candidates | Where-Object { Test-Path (Join-Path $_ 'Mods\tech\Supercarrier\PLATCameraUI\PLATCameraUI.lua') } | Select-Object -First 1
if (-not $dcs) {
    Write-Host 'ERROR: Could not find DCS World or DCS World OpenBeta with Supercarrier installed.' -ForegroundColor Red
    pause; exit 1
}
$lua    = Join-Path $dcs 'Mods\tech\Supercarrier\PLATCameraUI\PLATCameraUI.lua'
$luaBak = "$lua.platcamnvg.bak"
$fx     = Join-Path $dcs 'Bazar\shaders\MissionEditor\gui.fx'

Write-Host "=== CarrierGUI LSO NVG toggle installer ===" -ForegroundColor Cyan
Write-Host "DCS: $dcs"

# Sanity: gui.fx should be patched (NVG amplification active). If not, warn.
if (Test-Path $fx) {
    $fxText = [IO.File]::ReadAllText($fx)
    if (-not ($fxText -match 'float3\s*\(\s*0\.23')) {
        Write-Host 'WARNING: gui.fx does not look patched (no NVG branch found).' -ForegroundColor Yellow
        Write-Host '         The toggle will fire but you will not see green NVG.' -ForegroundColor Yellow
        Write-Host '         Run the PlatCam-NVG installer first for full effect.' -ForegroundColor Yellow
    }
}

# Backup or restore from backup
if (-not (Test-Path $luaBak)) {
    Copy-Item $lua $luaBak -Force
    Write-Host 'Backed up PLATCameraUI.lua'
} else {
    Copy-Item $luaBak $lua -Force
    Write-Host 'Restored from existing .bak before re-patching'
}

$text = [IO.File]::ReadAllText($lua)
$anchor = 'function setShipYawPitchRoll(heading,pitch,roll)'

if (-not $text.Contains($anchor)) {
    Write-Host 'ERROR: anchor "setShipYawPitchRoll" not found in PLATCameraUI.lua.' -ForegroundColor Red
    Write-Host '       DCS may have changed; nothing was modified.' -ForegroundColor Red
    pause; exit 1
}

# The injected Lua. Reads carriergui_nvg.txt every ~30 frames (cheap, OS-cached
# read), then applies the resulting color each frame. Setting the color every
# frame defeats any engine re-application of the .dlg color. We only call
# setSkin when the color actually changes (avoids per-frame skin churn).
$inj = @'
  -- BEGIN CARRIERGUI_NVG_TOGGLE_v1
  _G.__cgNvgF = (_G.__cgNvgF or 0) + 1
  if _G.__cgNvgF % 30 == 1 then
    pcall(function()
      local f = io.open(lfs.writedir() .. 'carriergui_nvg.txt', 'r')
      if f then
        local s = f:read('*a') or ''
        f:close()
        _G.__cgNvgOn = (s:sub(1,1) == '1')
        _G.__cgNvgFileSeen = true
      end
    end)
  end
  if _G.__cgNvgFileSeen then
    pcall(function()
      local w = LSOStation_ and LSOStation_.PLATCamera
      if not w then return end
      local target = _G.__cgNvgOn and '0x00ffc0ff' or '0xffffffff'
      local sk = w:getSkin()
      local st = sk and sk.skinData and sk.skinData.states and sk.skinData.states.released
      local p = st and st[1] and st[1].picture
      if p and p.color ~= target then
        p.color = target
        w:setSkin(sk)
      end
    end)
  end
  -- END CARRIERGUI_NVG_TOGGLE_v1
'@

$replacement = $anchor + "`n" + $inj
$text = $text.Replace($anchor, $replacement)
[IO.File]::WriteAllText($lua, $text)

Write-Host 'Patch installed.' -ForegroundColor Green
Write-Host ''
Write-Host 'How to use:' -ForegroundColor Cyan
Write-Host '  1. Launch DCS, start a Supercarrier mission, press LAlt+F9 (LSO).'
Write-Host '  2. Press Ctrl+Shift+c to open CarrierGUI.'
Write-Host '  3. Click the LSO tab, then "Toggle NVG".'
Write-Host '     ON  = green NVG amplification'
Write-Host '     OFF = normal PLAT feed'
Write-Host ''
Write-Host 'Default state is OFF on each DCS launch. Undo with Disable-NvgToggle.ps1.'
pause
