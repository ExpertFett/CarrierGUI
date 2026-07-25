#!/usr/bin/env python3
r"""
Build the OLYMPUS controller .ozp — "connect like OPT Live" (host + password).

CoreMod (target = Saved Games\DCS):
  Scripts/Hooks/        the panel (hook + dlg + TGAs)
  CarrierGUI-Olympus/   the Olympus agent + setup wizard + windowless launcher
                        + bundled Python (decodes Olympus's binary unit feed)

Full picture (no MP culling) on any Olympus server.  No mission patch / hooks /
relay / desanitize.

Usage:  python Tools/build_olympus_ozp.py 1.3-beta48
"""
import sys
import zipfile
from pathlib import Path

ROOT = Path(r"C:\Users\Fett\Saved Games\Claude Dump\CarrierGUI")
HOOKS = ROOT / "Hooks"
AGENT = ROOT / "agent"
PY = ROOT / "Patcher" / "python"
C = "CarrierGUI-Olympus"


def build(ver: str):
    name = f"CarrierGUI-Olympus_v{ver}"
    out = ROOT / "dist" / f"{name}.ozp"
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()
    files = {
        HOOKS / "carrier-gui-hook.lua":     "Scripts/Hooks/carrier-gui-hook.lua",
        HOOKS / "carrier-gui.dlg":          "Scripts/Hooks/carrier-gui.dlg",
        HOOKS / "carrier-gui-olympus-client.lua": "Scripts/Hooks/carrier-gui-olympus-client.lua",
        HOOKS / "radar_scope.tga":          "Scripts/Hooks/radar_scope.tga",
        HOOKS / "deck_overhead.tga":        "Scripts/Hooks/deck_overhead.tga",
        AGENT / "carriergui_olympus.py":    f"{C}/carriergui_olympus.py",
        AGENT / "olympus_setup.py":         f"{C}/olympus_setup.py",
        AGENT / "Setup-Olympus.bat":        f"{C}/Setup-Olympus.bat",
        AGENT / "Start-Olympus-Agent.vbs":  f"{C}/Start-Olympus-Agent.vbs",
        AGENT / "OLYMPUS-README.txt":       f"{C}/README.txt",
    }
    pyn = 0
    for p in PY.rglob("*"):
        if p.is_file():
            files[p] = f"{C}/python/{p.relative_to(PY).as_posix()}"
            pyn += 1
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
    return out, pyn


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    p, npy = build(sys.argv[1])
    print(f"built {p.name}  ({p.stat().st_size/1024/1024:.1f} MB, incl. {npy} bundled-python files)")
    with zipfile.ZipFile(p) as zf:
        for i in zf.infolist():
            if not i.is_dir() and "/python/" not in i.filename:
                print("    " + i.filename)
