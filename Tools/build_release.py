#!/usr/bin/env python3
"""
Build a CarrierGUI release zip.

    python Tools/build_release.py <version>          e.g. 0.4
    python Tools/build_release.py <version> --no-python   (skip bundling Python)

Stages the installer layout into dist/CarrierGUI-v<version>/ and writes
dist/CarrierGUI-v<version>.zip. The bundled Python embeddable is fetched once
and cached at Patcher/python/ (gitignored); pass --no-python to skip it (the
resulting zip then requires the user to have Python).

Run from the repo root.
"""
import argparse
import os
import shutil
import sys
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PYTHON_DIR = ROOT / 'Patcher' / 'python'
PY_EMBED_URL = 'https://www.python.org/ftp/python/3.12.7/python-3.12.7-embed-amd64.zip'

# Files/dirs that go into the release (relative to repo root).
INCLUDE = [
    'Hooks/carrier-gui-hook.lua',
    'Hooks/carrier-gui.dlg',
    'Hooks/radar_scope.tga',   # smooth-ring image overlay for the MARSHALL scope
    # Hooks/assets/dial-face.{png,tga} dropped in v1.0-beta4 — dxgui's
    # picture loader didn't accept any alpha-bearing format we tried, so
    # the dial is now a text-only LED bar.
    'Patcher/patch_miz.py',
    'Patcher/carrier-gui-bridge.lua',
    'Patcher/Patch Mission.bat',
    'Patcher/Revert Mission.bat',
    'LSO/Enable-LsoTools.ps1',
    'LSO/Disable-LsoTools.ps1',
    'Install.bat',
    'Uninstall.bat',
]
# INSTALL.txt is copied into the release as README.txt (end-user facing).


def ensure_python():
    if (PYTHON_DIR / 'python.exe').exists():
        print(f'  Python bundle present: {PYTHON_DIR}')
        return
    print(f'  Fetching Python embeddable -> {PYTHON_DIR}')
    PYTHON_DIR.mkdir(parents=True, exist_ok=True)
    tmp = ROOT / 'dist' / '_python_embed.zip'
    tmp.parent.mkdir(parents=True, exist_ok=True)
    urllib.request.urlretrieve(PY_EMBED_URL, tmp)
    with zipfile.ZipFile(tmp) as z:
        z.extractall(PYTHON_DIR)
    tmp.unlink()
    print('  done')


def stage(version: str, bundle_python: bool) -> Path:
    out = ROOT / 'dist' / f'CarrierGUI-v{version}'
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    for rel in INCLUDE:
        src = ROOT / rel
        dst = out / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)

    # plain-text end-user readme
    shutil.copy2(ROOT / 'INSTALL.txt', out / 'README.txt')

    if bundle_python:
        ensure_python()
        shutil.copytree(PYTHON_DIR, out / 'Patcher' / 'python')

    return out


def zip_dir(folder: Path) -> Path:
    # NB: not folder.with_suffix('.zip') — the version (e.g. "v0.4") contains a
    # dot, which with_suffix would clobber. Build the name explicitly.
    zpath = folder.parent / (folder.name + '.zip')
    if zpath.exists():
        zpath.unlink()
    with zipfile.ZipFile(zpath, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for root, _dirs, files in os.walk(folder):
            for f in files:
                full = Path(root) / f
                arc = full.relative_to(folder.parent)
                z.write(full, str(arc).replace('\\', '/'))
    return zpath


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('version', help='e.g. 0.4')
    ap.add_argument('--no-python', action='store_true',
                    help='do not bundle the Python interpreter')
    args = ap.parse_args()

    print(f'Building CarrierGUI v{args.version}')
    folder = stage(args.version, bundle_python=not args.no_python)
    zpath = zip_dir(folder)
    size_mb = zpath.stat().st_size / (1024 * 1024)
    print(f'  staged: {folder}')
    print(f'  zip:    {zpath}  ({size_mb:.1f} MB)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
