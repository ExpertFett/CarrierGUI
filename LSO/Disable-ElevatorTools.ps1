<#
    Disable-ElevatorTools.ps1   (CarrierGUI v1.4)

    Reverts Enable-ElevatorTools.ps1: restores the stock Supercarrier
    AirBoss.lua from the clean .cgelev.bak backup, or (if no backup is found)
    strips the injected CARRIERGUI_ELEVATOR_TOOLS block in place.

    Usage:
      Disable-ElevatorTools.ps1                  (auto-find DCS, self-elevate)
      Disable-ElevatorTools.ps1 -DcsRoot <path>  (explicit root, no elevation)
#>
param([string]$DcsRoot)

$ErrorActionPreference = 'Stop'

if (-not $DcsRoot) {
    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath))
        exit
    }
}

$logPath = Join-Path $PSScriptRoot 'ElevatorTools-uninstall-log.txt'
try { Start-Transcript -Path $logPath -Force | Out-Null } catch {}

Write-Host '=== CarrierGUI ELEVATOR tools UNINSTALL ===' -ForegroundColor Cyan

$running = @(Get-Process -Name 'DCS','DCS_server' -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    Write-Host 'ERROR: DCS is running. Close DCS first, then re-run.' -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch {}
    pause; exit 1
}

function Find-Dcs {
    $drives   = 'C','D','E','F','G','H'
    $suffixes = @(
        'Program Files\Eagle Dynamics\DCS World',
        'Program Files\Eagle Dynamics\DCS World OpenBeta',
        'Program Files (x86)\Eagle Dynamics\DCS World',
        'Program Files (x86)\Eagle Dynamics\DCS World OpenBeta',
        'SteamLibrary\steamapps\common\DCSWorld',
        'Games\DCS World','DCS World','Eagle Dynamics\DCS World')
    foreach ($d in $drives) {
        if (-not (Test-Path "${d}:\" -ErrorAction SilentlyContinue)) { continue }
        foreach ($s in $suffixes) {
            $p = "${d}:\$s"
            try {
                if (Test-Path "$p\Mods\tech\Supercarrier\AirBossScreensUI\AirBoss.lua" -ErrorAction SilentlyContinue) {
                    return $p
                }
            } catch {}
        }
    }
    return $null
}

if ($DcsRoot) { $dcs = $DcsRoot } else { $dcs = Find-Dcs }
if (-not $dcs) {
    Write-Host 'ERROR: No DCS install with the Supercarrier module found.' -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch {}
    pause; exit 1
}

$lua    = Join-Path $dcs 'Mods\tech\Supercarrier\AirBossScreensUI\AirBoss.lua'
$luaBak = "$lua.cgelev.bak"

if (Test-Path $luaBak) {
    Copy-Item $luaBak $lua -Force
    Remove-Item $luaBak -Force
    Write-Host 'Restored stock AirBoss.lua from backup (and removed the .bak).' -ForegroundColor Green
} elseif (Test-Path $lua) {
    $t = [IO.File]::ReadAllText($lua)
    if ($t.Contains('CARRIERGUI_ELEVATOR_TOOLS')) {
        $t = [regex]::Replace($t, '(?s)\r?\n\s*-- BEGIN CARRIERGUI_ELEVATOR_TOOLS.*?-- END CARRIERGUI_ELEVATOR_TOOLS', '')
        [IO.File]::WriteAllText($lua, $t)
        Write-Host 'No backup found - stripped the ELEVATOR tools block in place.' -ForegroundColor Yellow
    } else {
        Write-Host 'AirBoss.lua already clean (no ELEVATOR tools block).' -ForegroundColor Green
    }
} else {
    Write-Host "ERROR: AirBoss.lua not found at $lua" -ForegroundColor Red
}

try { Stop-Transcript | Out-Null } catch {}
if (-not $DcsRoot) { pause }
