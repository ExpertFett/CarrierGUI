#!/usr/bin/env python3
r"""
Build the CONTROLLER Open Mod Manager package (.ozp) — EXPORT mode (the easy,
"turn on and work" path).  One OMM download:

  Scripts/Hooks/   panel (hook + dlg + TGAs) + carriergui-export.lua
                   (client-side data source, reads the object export like Tacview)
  CarrierGUI-Controller/   Setup-Export.bat (wires it into Export.lua) + README

No relay, no agent, no Python.  Relay mode (for locked servers) ships in the
Admin pack instead.

Usage:  python Tools/build_controller_ozp.py 1.3-beta48
"""
import sys
import zipfile
from pathlib import Path

ROOT = Path(r"C:\Users\Fett\Saved Games\Claude Dump\CarrierGUI")
HOOKS = ROOT / "Hooks"
EXPORT = ROOT / "Export"
C = "CarrierGUI-Controller"


def build(ver: str) -> Path:
    name = f"CarrierGUI-Controller_v{ver}"
    out = ROOT / "dist" / f"{name}.ozp"
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()

    files = {
        HOOKS / "carrier-gui-hook.lua":   "Scripts/Hooks/carrier-gui-hook.lua",
        HOOKS / "carrier-gui.dlg":        "Scripts/Hooks/carrier-gui.dlg",
        HOOKS / "carrier-gui-olympus-client.lua": "Scripts/Hooks/carrier-gui-olympus-client.lua",
        HOOKS / "radar_scope.tga":        "Scripts/Hooks/radar_scope.tga",
        HOOKS / "deck_overhead.tga":      "Scripts/Hooks/deck_overhead.tga",
        EXPORT / "carriergui-export.lua": "Scripts/Hooks/carriergui-export.lua",
        EXPORT / "Setup-Export.bat":      f"{C}/Setup-Export.bat",
        EXPORT / "CONTROLLER-README.txt": f"{C}/README.txt",
    }
    dirs = set()
    for dest in files.values():
        parts = (f"{name}/" + dest).split("/")[:-1]
        for i in range(1, len(parts) + 1):
            dirs.add("/".join(parts[:i]) + "/")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for d in sorted(dirs):
            zf.writestr(d, "")
        for src, dest in files.items():
            if not src.exists():
                raise FileNotFoundError(src)
            zf.write(src, f"{name}/{dest}")
    return out


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    p = build(sys.argv[1])
    print(f"built {p.name}  ({p.stat().st_size/1024:.0f} KB)")
    with zipfile.ZipFile(p) as zf:
        for i in zf.infolist():
            if not i.is_dir():
                print("    " + i.filename)
