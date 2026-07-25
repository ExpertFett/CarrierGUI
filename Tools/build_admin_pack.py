#!/usr/bin/env python3
r"""
Build the SERVER ADMIN PACK (.zip) — one download a squad admin extracts to set
up the relay + dedicated server.  Laid out so Server\Install-Server.ps1 resolves
its siblings (Patcher\, agent\, Server\) straight out of the extracted folder.

  CarrierGUI-Admin_v<ver>/
    README.txt
    relay/      (deploy to Railway)
    Server/     Install-Server.ps1 + injector
    Patcher/    Patch Mission.bat + patch_miz.py + bridge + bundled python
    agent/      server agent + launcher

Usage:  python Tools/build_admin_pack.py 1.3-beta47
"""
import sys
import zipfile
from pathlib import Path

ROOT = Path(r"C:\Users\Fett\Saved Games\Claude Dump\CarrierGUI")


def build(ver: str) -> Path:
    name = f"CarrierGUI-Admin_v{ver}"
    out = ROOT / "dist" / f"{name}.zip"
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()

    files = {
        ROOT / "Server/ADMIN-README.txt":          "README.txt",
        ROOT / "Server/Install-Server.ps1":        "Server/Install-Server.ps1",
        ROOT / "Server/carrier-gui-server.lua":    "Server/carrier-gui-server.lua",
        ROOT / "Patcher/carrier-gui-bridge.lua":   "Patcher/carrier-gui-bridge.lua",
        ROOT / "Patcher/patch_miz.py":             "Patcher/patch_miz.py",
        ROOT / "Patcher/Patch Mission.bat":        "Patcher/Patch Mission.bat",
        ROOT / "Patcher/Revert Mission.bat":       "Patcher/Revert Mission.bat",
        ROOT / "agent/carriergui_serveragent.py":  "agent/carriergui_serveragent.py",
        ROOT / "agent/Start-ServerAgent.vbs":      "agent/Start-ServerAgent.vbs",
        ROOT / "relay/server.js":                  "relay/server.js",
        ROOT / "relay/package.json":               "relay/package.json",
        ROOT / "relay/README.md":                  "relay/README.md",
    }
    py = ROOT / "Patcher" / "python"
    pyn = 0
    for p in py.rglob("*"):
        if p.is_file():
            files[p] = f"Patcher/python/{p.relative_to(py).as_posix()}"
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
        print(__doc__)
        sys.exit(1)
    p, npy = build(sys.argv[1])
    print(f"built {p.name}  ({p.stat().st_size/1024/1024:.1f} MB, incl. {npy} bundled-python files)")
    with zipfile.ZipFile(p) as zf:
        for i in zf.infolist():
            if not i.is_dir() and "/python/" not in i.filename:
                print("    " + i.filename)
