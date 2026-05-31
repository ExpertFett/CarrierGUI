<#
    Enables the CarrierGUI LSO-tab NVG GAIN DIAL by patching two DCS files:

      1) Bazar\shaders\MissionEditor\gui.fx
         - Adds a color-gated NVG branch that uses the PLAT widget's ALPHA
           channel as a continuous gain mixer. Alpha 0 = normal feed, alpha
           255 = full amplification, anything between = lerp blend.
         - Backward-compatible: a widget left at the .dlg's default sentinel
           (0x00ffc0ff = alpha 255) gives the same full-NVG output as the
           original PlatCam-NVG always-on patch.

      2) Mods\tech\Supercarrier\PLATCameraUI\PLATCameraUI.lua
         - Reads gain (0..100, written by the CarrierGUI hook) from
           Saved Games\DCS\carriergui_nvg.txt every ~30 frames.
         - Sets the PLAT widget color's alpha byte each frame so the new
           shader can mix the NVG amount continuously.

    Prerequisites:
      * DCS World (stable or OpenBeta) with the Supercarrier module.
      * CarrierGUI installed (Install.bat). Without the hook there is no UI
        to drive the dial.
      * PlatCam-NVG-style .bak files are reused if present; otherwise this
        script creates its own (.platcamnvg.bak siblings).

    Safe to re-run. Undo with Disable-NvgDial.ps1.
    Self-elevates (UAC) because it writes inside Program Files.

    NOTE: Modifying gui.fx makes DCS rebuild the shader cache on the next
    launch. First launch after running this WILL be slow. That is normal.
    Modifies a core shader -> FAILS multiplayer integrity check.
    Single-player / IC-free servers only. Fully reversible.
#>

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath))
    exit
}

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- locate DCS --
$candidates = @(
    'C:\Program Files\Eagle Dynamics\DCS World',
    'C:\Program Files\Eagle Dynamics\DCS World OpenBeta'
)
$dcs = $candidates | Where-Object {
    Test-Path (Join-Path $_ 'Bazar\shaders\MissionEditor\gui.fx')
} | Select-Object -First 1
if (-not $dcs) {
    Write-Host 'ERROR: DCS World install not found.' -ForegroundColor Red
    pause; exit 1
}

$fx     = Join-Path $dcs 'Bazar\shaders\MissionEditor\gui.fx'
$fxBak  = "$fx.platcamnvg.bak"
$lua    = Join-Path $dcs 'Mods\tech\Supercarrier\PLATCameraUI\PLATCameraUI.lua'
$luaBak = "$lua.platcamnvg.bak"

Write-Host '=== CarrierGUI LSO NVG dial installer ===' -ForegroundColor Cyan
Write-Host "DCS: $dcs"

# ---------------------------------------------------------- patch gui.fx ------
# Create or reuse the .bak. Always re-patch from the pristine .bak so we don't
# stack patches on top of a prior NVG version.
if (-not (Test-Path $fxBak)) {
    Copy-Item $fx $fxBak -Force
    Write-Host 'Backed up gui.fx'
}
$g = [IO.File]::ReadAllText($fxBak)

$fxTarget = 'return correctGammaAndBrightness(diffuse * IN.Color);'
# Alpha-as-gain mixer. Gate matches the stock sentinel hue (R~0, G~1, B~0.75).
# When gated, lerp between the raw texture (no NVG) and the green-phosphor
# amplified output, mixed by IN.Color.a. Output alpha is kept at diffuse.a
# (NOT multiplied by IN.Color.a) so the widget stays visible at gain 0.
$fxReplace = '{ float3 _amp = diffuse.rgb * IN.Color.rgb; float _outA = diffuse.a * IN.Color.a; if (IN.Color.r < 0.05 && IN.Color.g > 0.95 && IN.Color.b > 0.70 && IN.Color.b < 0.80) { float _l = dot(diffuse.rgb, float3(0.2126, 0.7152, 0.0722)); _l = pow(saturate(_l * 12.0), 1.0 / 2.6); float3 _green = float3(0.23, 0.78, 0.26) * _l * 1.8; _amp = lerp(diffuse.rgb, _green, IN.Color.a); _outA = diffuse.a; } return correctGammaAndBrightness(float4(_amp, _outA)); }'

if (-not $g.Contains($fxTarget)) {
    Write-Host 'ERROR: gui.fx anchor line not found.' -ForegroundColor Red
    Write-Host '       Stock shader may have changed; nothing was modified.' -ForegroundColor Red
    pause; exit 1
}
$g = $g.Replace($fxTarget, $fxReplace)
[IO.File]::WriteAllText($fx, $g)
Write-Host 'Patched gui.fx (alpha-as-gain mixer)' -ForegroundColor Green

# -------------------------------------------------------- patch PLATCameraUI --
if (-not (Test-Path $luaBak)) {
    Copy-Item $lua $luaBak -Force
    Write-Host 'Backed up PLATCameraUI.lua'
} else {
    # restore from pristine .bak before re-injecting
    Copy-Item $luaBak $lua -Force
}
$t = [IO.File]::ReadAllText($lua)
$luaAnchor = 'function setShipYawPitchRoll(heading,pitch,roll)'

if (-not $t.Contains($luaAnchor)) {
    Write-Host 'ERROR: PLATCameraUI.lua anchor "setShipYawPitchRoll" not found.' -ForegroundColor Red
    pause; exit 1
}

# Reads percent (0..100) from Saved Games\DCS\carriergui_nvg.txt every ~30
# frames, computes the alpha byte, and sets the widget color each frame to
# defeat any engine re-application of the .dlg color.
$luaInject = @'
  -- BEGIN CARRIERGUI_NVG_DIAL_v1
  _G.__cgNvgF = (_G.__cgNvgF or 0) + 1
  if _G.__cgNvgF % 30 == 1 then
    pcall(function()
      local f = io.open(lfs.writedir() .. 'carriergui_nvg.txt', 'r')
      if f then
        local s = f:read('*a') or ''
        f:close()
        local n = tonumber(s) or 0
        if n < 0   then n = 0 end
        if n > 100 then n = 100 end
        _G.__cgNvgPct = n
        _G.__cgNvgFileSeen = true
      end
    end)
  end
  if _G.__cgNvgFileSeen then
    pcall(function()
      local w = LSOStation_ and LSOStation_.PLATCamera
      if not w then return end
      local pct = _G.__cgNvgPct or 0
      local alpha = math.floor(pct * 2.55 + 0.5)
      local target = string.format('0x00ffc0%02x', alpha)
      local sk = w:getSkin()
      local st = sk and sk.skinData and sk.skinData.states and sk.skinData.states.released
      local p = st and st[1] and st[1].picture
      if p and p.color ~= target then
        p.color = target
        w:setSkin(sk)
      end
    end)
  end
  -- END CARRIERGUI_NVG_DIAL_v1
'@

$t = $t.Replace($luaAnchor, $luaAnchor + "`n" + $luaInject)
[IO.File]::WriteAllText($lua, $t)
Write-Host 'Patched PLATCameraUI.lua (gain reader)' -ForegroundColor Green

# --------------------------------------------------- clear shader cache -------
foreach ($c in @('metashaders2','fxo','fxo2')) {
    foreach ($sg in @('Saved Games\DCS','Saved Games\DCS.openbeta')) {
        $p = Join-Path $env:USERPROFILE (Join-Path $sg $c)
        if (Test-Path $p) {
            Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "Cleared shader cache: $p"
        }
    }
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host ''
Write-Host 'NEXT:' -ForegroundColor Cyan
Write-Host '  1. Launch DCS. The FIRST launch after this will be slow (rebuilding shaders) — that is normal.'
Write-Host '  2. Start any Supercarrier mission, press LAlt+F9 (LSO station).'
Write-Host '  3. Open CarrierGUI (Ctrl+Shift+c), click LSO tab.'
Write-Host '  4. Use the Gain - / + buttons to dial in 0% .. 100% in 10% steps.'
Write-Host ''
Write-Host 'Default gain is 0% (normal feed) on each DCS launch.'
Write-Host 'Undo with Disable-NvgDial.ps1.'
pause
