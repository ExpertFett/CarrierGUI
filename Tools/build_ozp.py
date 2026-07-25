#!/usr/bin/env python3
r"""
Build Open Mod Manager packages (.ozp) for CarrierGUI.

OMM / OvGME packages are ZIP archives whose single root folder is
"<Name>_v<Version>/", with the deployment tree inside it RELATIVE to the mod
channel's target path.  No embedded metadata / archive comment (verified
against the user's CSG-3 / vSFG-7 library; the modpack.xml/readme.md some of
those carry at the zip root is CSG-3 tooling, NOT required by OMM).

Two channels:
  CoreMod  -> target  Saved Games\DCS                (the panel: hook + dlg + TGAs)
  RootMod  -> target  <DCS install root>             (the radar/deck images)

The PLAT NVG gain is NOT packaged here — it surgically edits a core shader
(gui.fx) that DCS overwrites each update, so it stays the Enable-LsoTools
script.

Usage:  python Tools/build_ozp.py 1.3-beta36
"""
import sys
import zipfile
from pathlib import Path

ROOT = Path(r"C:\Users\Fett\Saved Games\Claude Dump\CarrierGUI")
HOOKS = ROOT / "Hooks"

# CoreMod (Saved Games\DCS): the panel itself.
CORE = {
    HOOKS / "carrier-gui-hook.lua": "Scripts/Hooks/carrier-gui-hook.lua",
    HOOKS / "carrier-gui.dlg":      "Scripts/Hooks/carrier-gui.dlg",
        HOOKS / "carrier-gui-olympus-client.lua": "Scripts/Hooks/carrier-gui-olympus-client.lua",
    HOOKS / "radar_scope.tga":      "Scripts/Hooks/radar_scope.tga",
    HOOKS / "deck_overhead.tga":    "Scripts/Hooks/deck_overhead.tga",
}
# RootMod (DCS install root): the MARSHALL radar + DECKBOSS deck background
# images, dropped where the .dlg bkg.file references them.
ROOT_IMG = {
    HOOKS / "radar_scope.tga":   "Mods/tech/Supercarrier/PLATCameraUI/carriergui_radar.tga",
    HOOKS / "deck_overhead.tga": "Mods/tech/Supercarrier/PLATCameraUI/carriergui_deck.tga",
}


def build(name: str, payload: dict) -> Path:
    out = ROOT / "dist" / f"{name}.ozp"
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()
    dirs = set()
    for dest in payload.values():
        parts = (f"{name}/" + dest).split("/")[:-1]
        for i in range(1, len(parts) + 1):
            dirs.add("/".join(parts[:i]) + "/")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for d in sorted(dirs):
            zf.writestr(d, "")
        for src, dest in payload.items():
            if not src.exists():
                raise FileNotFoundError(src)
            zf.write(src, f"{name}/{dest}")
    return out


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    ver = sys.argv[1]
    for name, payload in [
        (f"CarrierGUI_v{ver}", CORE),
        (f"(ROOT)_CarrierGUI_Images_v{ver}", ROOT_IMG),
    ]:
        p = build(name, payload)
        print(f"built {p.name}  ({p.stat().st_size/1024:.0f} KB)")
        with zipfile.ZipFile(p) as zf:
            for i in zf.infolist():
                if not i.is_dir():
                    print(f"    {i.filename}")
