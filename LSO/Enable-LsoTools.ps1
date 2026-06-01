<#
    Enables the CarrierGUI v1.1 LSO tab features by patching DCS:

      gui.fx (Bazar\shaders\MissionEditor\gui.fx)
          - Alpha-as-gain NVG mixer (unchanged from v1.0)

      PLATCameraUI.lua (Mods\tech\Supercarrier\PLATCameraUI\)
          - Reads carriergui_nvg.txt     -> sets PLAT widget alpha (NVG gain)
          - Reads carriergui_foul.txt    -> setFoulDeck(true/false)
          - Reads carriergui_wire.txt    -> setDesiredRope(1..4)
          - Reads carriergui_zoom.txt    -> adjustGate(fov, ...) PLAT FOV
          File reads are throttled to ~30 frames so we're not pegging the IO.

    Same .platcamnvg.bak files as the v1.0 Enable-NvgDial script — safe to
    run if you previously ran that. Safe to re-run.

    Self-elevates (UAC). Modifies Program Files; needs admin.
    NOTE: modifies a core shader -> FAILS multiplayer integrity check.
    Single-player / IC-free servers only. Fully reversible via
    Disable-LsoTools.ps1.
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

Write-Host '=== CarrierGUI LSO tools installer ===' -ForegroundColor Cyan
Write-Host "DCS: $dcs"

# ---------------------------------------------------------- patch gui.fx ------
if (-not (Test-Path $fxBak)) {
    Copy-Item $fx $fxBak -Force
    Write-Host 'Backed up gui.fx'
}
$g = [IO.File]::ReadAllText($fxBak)

$fxTarget = 'return correctGammaAndBrightness(diffuse * IN.Color);'
$fxReplace = '{ float3 _amp = diffuse.rgb * IN.Color.rgb; float _outA = diffuse.a * IN.Color.a; if (IN.Color.r < 0.05 && IN.Color.g > 0.95 && IN.Color.b > 0.70 && IN.Color.b < 0.80) { float _l = dot(diffuse.rgb, float3(0.2126, 0.7152, 0.0722)); _l = pow(saturate(_l * 12.0), 1.0 / 2.6); float3 _green = float3(0.23, 0.78, 0.26) * _l * 1.8; _amp = lerp(diffuse.rgb, _green, IN.Color.a); _outA = diffuse.a; } return correctGammaAndBrightness(float4(_amp, _outA)); }'

if (-not $g.Contains($fxTarget)) {
    Write-Host 'ERROR: gui.fx anchor line not found.' -ForegroundColor Red
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
    Copy-Item $luaBak $lua -Force
}
$t = [IO.File]::ReadAllText($lua)
$luaAnchor = 'function setShipYawPitchRoll(heading,pitch,roll)'

if (-not $t.Contains($luaAnchor)) {
    Write-Host 'ERROR: PLATCameraUI.lua anchor "setShipYawPitchRoll" not found.' -ForegroundColor Red
    pause; exit 1
}

# Combined injection: NVG dial + foul deck + desired wire + PLAT zoom.
# Each piece file-IPC reads at ~30-frame intervals to keep IO cost negligible.
# Effects applied only when the file value actually changes (so we don't spam
# setSkin / setFoulDeck / setDesiredRope / adjustGate every frame).
$luaInject = @'
  -- BEGIN CARRIERGUI_LSO_TOOLS_v1
  _G.__cgF = (_G.__cgF or 0) + 1
  local _read = function(name)
    local f = io.open(lfs.writedir() .. name, 'r')
    if not f then return nil end
    local s = f:read('*a') or ''
    f:close()
    return s
  end
  if _G.__cgF % 30 == 1 then
    pcall(function()
      local s = _read('carriergui_nvg.txt')
      if s then
        local n = tonumber(s) or 0
        if n < 0   then n = 0 end
        if n > 100 then n = 100 end
        _G.__cgNvgPct = n
        _G.__cgNvgSeen = true
      end
      s = _read('carriergui_foul.txt')
      if s then
        local foul = (s:sub(1,1) == '1')
        if foul ~= _G.__cgFoulApplied then
          if setFoulDeck then pcall(setFoulDeck, foul) end
          _G.__cgFoulApplied = foul
        end
      end
      s = _read('carriergui_wire.txt')
      if s then
        local w = tonumber(s) or 0
        if w ~= _G.__cgWireApplied then
          if setDesiredRope then pcall(setDesiredRope, w) end
          _G.__cgWireApplied = w
        end
      end
      s = _read('carriergui_zoom.txt')
      if s then
        local fov = tonumber(s) or 0
        if fov > 0 and fov ~= _G.__cgZoomApplied then
          if adjustGate then pcall(adjustGate, fov, 50, 0) end
          _G.__cgZoomApplied = fov
        end
      end
    end)
  end
  -- NVG dial colour application: every frame to defeat .dlg re-stomp
  if _G.__cgNvgSeen then
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
  -- END CARRIERGUI_LSO_TOOLS_v1
'@

$t = $t.Replace($luaAnchor, $luaAnchor + "`n" + $luaInject)
[IO.File]::WriteAllText($lua, $t)
Write-Host 'Patched PLATCameraUI.lua (NVG dial + foul/wire/zoom readers)' -ForegroundColor Green

# Clear shader cache so DCS rebuilds for our patched gui.fx.
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
Write-Host '  1. Launch DCS. First launch will be slow (rebuilding shaders).'
Write-Host '  2. Start a Supercarrier mission, LAlt+F9 (LSO).'
Write-Host '  3. Ctrl+Shift+c, LSO tab. Try the NVG dial, Wire, Foul Deck,'
Write-Host '     and PLAT Zoom controls. See LSO calls broadcast on screen.'
Write-Host ''
Write-Host 'Undo: Disable-LsoTools.ps1'
pause
