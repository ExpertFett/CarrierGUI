# CarrierGUI server-side installer (run on the DCS dedicated-server box).
# Idempotent + makes backups. ASCII-only (PS 5.1 safe).
#
#   1. Desanitizes io/lfs in the dedicated server's MissionScripting.lua so the
#      bridge can write the recovery snapshot + read the command file.
#   2. Copies the bridge + injector hook into the server profile's Scripts\Hooks.
#   3. Sets up the server agent folder (agent + bundled Python + launcher) and
#      writes its carriergui_agent.json from the relay details you enter.
#
# Re-patch your mission(s) with Patcher\Patch Mission.bat as usual.

param(
  [string]$ServerInstall = "D:\DCS World Server",
  [string]$ServerProfile = "$env:USERPROFILE\Saved Games\DCS.dcs_serverrelease"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot   # ...\CarrierGUI

function Info($m){ Write-Host "[CarrierGUI] $m" }

# --- 1. desanitize MissionScripting.lua --------------------------------------
$ms = Join-Path $ServerInstall "Scripts\MissionScripting.lua"
if (-not (Test-Path $ms)) { throw "MissionScripting.lua not found at $ms (set -ServerInstall)" }
if (-not (Test-Path "$ms.cgbak")) { Copy-Item $ms "$ms.cgbak" }
$lines = Get-Content $ms
$changed = $false
for ($i=0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -match "^\s*sanitizeModule\('(io|lfs)'\)") {
    $lines[$i] = "--" + $lines[$i].TrimStart()
    $changed = $true
  }
}
if ($changed) {
  [System.IO.File]::WriteAllLines($ms, $lines, (New-Object System.Text.ASCIIEncoding))
  Info "desanitized io/lfs in MissionScripting.lua (backup: $ms.cgbak)"
} else {
  Info "MissionScripting.lua already desanitized (or lines not found) - check manually if needed"
}

# --- 2. bridge + injector into the server profile ----------------------------
$hooks = Join-Path $ServerProfile "Scripts\Hooks"
New-Item -ItemType Directory -Force -Path $hooks | Out-Null
Copy-Item (Join-Path $repo "Patcher\carrier-gui-bridge.lua") $hooks -Force
Copy-Item (Join-Path $repo "Server\carrier-gui-server.lua")  $hooks -Force
Info "copied bridge + injector to $hooks"

# --- 3. server agent folder (agent + python + launcher + config) -------------
$agentDir = Join-Path $ServerProfile "CarrierGUI-Server"
New-Item -ItemType Directory -Force -Path $agentDir | Out-Null
Copy-Item (Join-Path $repo "agent\carriergui_serveragent.py") $agentDir -Force
Copy-Item (Join-Path $repo "agent\Start-ServerAgent.vbs")     $agentDir -Force
$pyDst = Join-Path $agentDir "python"
if (-not (Test-Path (Join-Path $pyDst "pythonw.exe"))) {
  Copy-Item (Join-Path $repo "Patcher\python") $pyDst -Recurse -Force
}
Info "server agent staged in $agentDir"

$url = Read-Host "Relay URL (e.g. https://yourrelay.up.railway.app)"
$tok = Read-Host "Relay token"
$sid = Read-Host "Server ID (controllers must use the same)"
$wd  = ($ServerProfile.TrimEnd('\') + '\').Replace('\','\\')
$cfg = "{`n  ""relay_url"": ""$($url.TrimEnd('/'))"",`n  ""relay_token"": ""$tok"",`n  ""server_id"": ""$sid"",`n  ""dcs_writedir"": ""$wd"",`n  ""poll_secs"": 1.0`n}"
[System.IO.File]::WriteAllText((Join-Path $agentDir "carriergui_agent.json"), $cfg, (New-Object System.Text.ASCIIEncoding))
Info "wrote carriergui_agent.json"

Write-Host ""
Info "DONE. Next:"
Info "  - Re-patch your mission(s): drag the .miz onto Patcher\Patch Mission.bat"
Info "  - Start the server agent: double-click $agentDir\Start-ServerAgent.vbs (or auto-start it)"
Info "  - Deploy the relay (relay\) to Railway with RELAY_TOKEN=$tok"
