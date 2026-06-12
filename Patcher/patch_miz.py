#!/usr/bin/env python3
"""
CarrierGUI .miz patcher  (rebuild v0.1 — reconstructed from architecture)
==========================================================================

Embeds Mission/carrier-gui-bridge.lua into a .miz mission so the in-game GUI
hook can drive it. Also injects 5 inline-action triggers (one per lights mode)
because a_set_carrier_illumination_mode() is only reachable from the trigger-
action-string eval env — not from the bridge env.

Usage:
    python patch_miz.py <path/to/mission.miz>      # patch
    python patch_miz.py --revert <path/to.miz>     # remove the patch

Idempotency: the patcher embeds a marker
    -- CARRIER_GUI_BRIDGE_PATCH_v1
into the mission file. Re-running on an already-patched .miz updates the
embedded bridge contents (so you can iterate on the bridge without manually
unpatching first).

FLAG MAPPING (must match hook + bridge):
   1..8 = TACAN/ICLS/LINK4/ACLS off/on  (handled by bridge)
   10..14 = Lights Off/Auto/Nav/Launch/Recovery (handled by triggers we write)
  100..106 = Wind (handled by bridge)
"""
import argparse
import datetime
import os
import re
import shutil
import sys
import tempfile
import traceback
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
# Look for the bridge file in either layout:
#   dev:  ../Mission/carrier-gui-bridge.lua
#   dist: ./carrier-gui-bridge.lua  (same dir as this script)
_BRIDGE_CANDIDATES = [
    HERE / 'carrier-gui-bridge.lua',
    HERE.parent / 'Mission' / 'carrier-gui-bridge.lua',
]
BRIDGE_PATH = next((p for p in _BRIDGE_CANDIDATES if p.exists()), _BRIDGE_CANDIDATES[0])
MARKER           = '-- CARRIER_GUI_BRIDGE_PATCH_v1'
MARKER_BEGIN     = '-- BEGIN ' + MARKER
MARKER_END       = '-- END '   + MARKER

# DCS carrier illumination modes (these may need tuning — verify in DCS):
#   0 = Off, 1 = Auto, 2 = Nav, 3 = Launch, 4 = Recovery
LIGHTS_FLAGS = [
    (10, 0, 'Off'),
    (11, 1, 'Auto'),
    (12, 2, 'Nav'),
    (13, 3, 'Launch'),
    (14, 4, 'Recovery'),
]

CARRIER_TYPE_PATTERNS = ['CVN', 'Stennis', 'VINSON', 'Forrestal']


# ---------------------------------------------------------------------------
# Lua text helpers
# ---------------------------------------------------------------------------
def lua_quote(s: str) -> str:
    """Wrap a string for safe inclusion in Lua source as a long-bracket literal."""
    # Find an [[ ... ]] level not present in the string.
    level = 0
    while ('[' + '=' * level + '[') in s or (']' + '=' * level + ']') in s:
        level += 1
    eq = '=' * level
    return f'[{eq}[\n{s}\n]{eq}]'


def build_bridge_action_string() -> str:
    """The Lua code embedded in the bridge-load trigger."""
    bridge_src = BRIDGE_PATH.read_text(encoding='utf-8')
    quoted = lua_quote(bridge_src)
    return (
        f'{MARKER_BEGIN}\n'
        f'a_do_script({quoted})\n'
        f'{MARKER_END}'
    )


def build_lights_action_string(mode: int) -> str:
    """
    Inline trigger-action source for one lights mode.
    Runs in the only env where a_set_carrier_illumination_mode is reachable.
    Loops every coalition's groups, finds ship units whose typeName matches a
    carrier pattern, and applies the mode by unitId.
    """
    type_checks = ' or '.join(
        f'string.find(tn, "{p}")' for p in CARRIER_TYPE_PATTERNS
    )
    return (
        f'{MARKER_BEGIN}_LIGHTS_{mode}\n'
        f'do\n'
        f'  local mode = {mode}\n'
        f'  for _, side in pairs({{coalition.side.BLUE, coalition.side.RED, coalition.side.NEUTRAL}}) do\n'
        f'    local gs = coalition.getGroups(side, Group.Category.SHIP)\n'
        f'    if gs then\n'
        f'      for _, g in pairs(gs) do\n'
        f'        if g:isExist() then\n'
        f'          for _, u in pairs(g:getUnits() or {{}}) do\n'
        f'            if u:isExist() then\n'
        f'              local tn = u:getTypeName() or ""\n'
        f'              if {type_checks} then\n'
        f'                pcall(function() a_set_carrier_illumination_mode(u:getID(), mode) end)\n'
        f'              end\n'
        f'            end\n'
        f'          end\n'
        f'        end\n'
        f'      end\n'
        f'    end\n'
        f'  end\n'
        f'end\n'
        f'{MARKER_END}_LIGHTS_{mode}'
    )


# ---------------------------------------------------------------------------
# Mission file editing
# ---------------------------------------------------------------------------
# .miz mission files are Lua-data starting with `mission = { ... }`. We don't
# attempt full Lua parsing — instead we surgically insert new trigger entries
# into the existing trig.actions / conditions / func / flag arrays.
#
# Strategy:
#   * Remove any existing block bracketed by MARKER_BEGIN..MARKER_END.
#   * Find max existing trig action index N, append our entries starting at N+1.
#   * For each new trigger: action="our lua chunk", condition="return true",
#     func calls the action when its flag fires (using c_flag_is_true), flag=0.
#
# We append entries by replacing the trig table block. To stay safe across
# DCS mission file format quirks, we operate on a string of the mission file.

# ---------------------------------------------------------------------------
# Real DCS .miz trigger entry shapes (derived from inspecting actual missions)
# ---------------------------------------------------------------------------
# triggerOnce  = fires once when rules become true, never again.
# triggerFront = fires on rising edge (false->true) of rules — but the flag
#                must be cleared in the action so the NEXT press is also a
#                rising edge. Used here for button-triggered actions.
#
# Note that DCS does NOT have a "triggerStart" predicate. Earlier versions of
# this patcher used that and DCS silently never fired anything.

# Bridge loader: fires once, 1 second after mission start.
BRIDGE_ENTRY_TEMPLATE = """\
            [{idx}] =
            {{
                ["rules"] =
                {{
                    [1] =
                    {{
                        ["predicate"] = "c_time_after",
                        ["seconds"] = 1,
                    }},
                }},
                ["comment"] = "CarrierGUI: load bridge",
                ["eventlist"] = "",
                ["predicate"] = "triggerOnce",
                ["actions"] =
                {{
                    [1] = {{
                        ["text"] = {action_text},
                        ["predicate"] = "a_do_script",
                    }},
                }},
                ["colorItem"] = "0xff8800ff",
            }},
"""

# Lights / flag-driven entry: fires every time flag rises to true. After the
# script runs we MUST clear the flag so the next button press is a fresh
# rising edge.
FLAG_ACTION_ENTRY_TEMPLATE = """\
            [{idx}] =
            {{
                ["rules"] =
                {{
                    [1] = {{
                        ["flag"] = "{flag}",
                        ["value"] = 1,
                        ["predicate"] = "c_flag_is_true",
                    }},
                }},
                ["comment"] = "CarrierGUI: {comment}",
                ["eventlist"] = "",
                ["predicate"] = "triggerFront",
                ["actions"] =
                {{
                    [1] = {{
                        ["text"] = {action_text},
                        ["predicate"] = "a_do_script",
                    }},
                    [2] = {{
                        ["flag"] = "{flag}",
                        ["predicate"] = "a_clear_flag",
                    }},
                }},
                ["colorItem"] = "0xff8800ff",
            }},
"""


# All our inserted entries start with this exact prefix at column 0 of a
# line. The marker lets us find the OUTER entry (not the inner [1]=action
# wrapper that also contains the marker text).
_ENTRY_INDENT      = '            '          # 12 spaces
_ENTRY_LINE_RE     = re.compile(r'\n' + _ENTRY_INDENT + r'\[\d+\] =\n')


def strip_existing_patch(mission_src: str) -> str:
    """
    Remove every CarrierGUI-inserted "[N] = { ... }" entry.
    Brace-aware so it correctly handles the bridge entry which embeds
    hundreds of '{' / '}' inside its Lua payload.
    """
    result = mission_src
    while True:
        marker_pos = result.find(MARKER)
        if marker_pos == -1:
            break

        # Find the line that starts our outer entry: the LAST occurrence of
        # "\n<12 spaces>[<num>] =\n" before marker_pos. That's where we
        # inserted at column 12.
        head = result[:marker_pos]
        last = None
        for m in _ENTRY_LINE_RE.finditer(head):
            last = m
        if last is None:
            # Marker not preceded by our insertion shape — bail.
            break

        entry_start = last.start() + 1  # skip leading '\n'
        # The opening '{' is on the next line at the same indent. Find it.
        brace_search_from = last.end()
        brace_pos = result.find('{', brace_search_from)
        if brace_pos == -1:
            break

        # Walk forward to find matching close brace.
        k = brace_pos + 1
        depth = 1
        while k < len(result) and depth > 0:
            ch = result[k]
            if ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
            k += 1
        if depth != 0:
            break

        # Consume trailing ",\n"
        if k < len(result) and result[k] == ',':
            k += 1
        if k < len(result) and result[k] == '\n':
            k += 1

        result = result[:entry_start] + result[k:]
    return result


def patch_mission_lua(mission_src: str) -> str:
    """Insert the bridge-load trigger + 5 lights triggers into mission Lua."""
    mission_src = strip_existing_patch(mission_src)

    # Find trig = { ... actions = { [1] = {...}, [2] = {...}, ... }, ... }
    # We don't have a guaranteed start index; just append after the last entry.
    # Locate the actions array block.
    m = re.search(r'\["actions"\]\s*=\s*\{', mission_src)
    if not m:
        # No actions table at all — DCS always has trig structures, but if the
        # mission is unusual, refuse rather than corrupt.
        raise RuntimeError('Could not locate ["actions"] table in mission file')

    # Find current max index across the actions table by scanning [N] = entries
    # inside the trig.actions block. To keep regex simple we capture all
    # bracketed integer keys in the file; on a well-formed mission this
    # over-approximates safely (we just want a fresh index).
    indices = [int(x) for x in re.findall(r'\[(\d+)\]\s*=\s*\{', mission_src)]
    next_idx = (max(indices) if indices else 0) + 1

    # Build new entries.
    new_entries = []

    # 1) bridge-loader: fires once 1s after mission start (triggerOnce +
    #    c_time_after rule). Runs the embedded bridge lua via a_do_script.
    bridge_action = build_bridge_action_string()
    bridge_entry = BRIDGE_ENTRY_TEMPLATE.format(
        idx=next_idx,
        action_text=lua_quote(bridge_action),
    )
    new_entries.append(bridge_entry)
    next_idx += 1

    # 2) five lights triggers — each fires on rising edge of its flag, then
    #    clears the flag so the next button press is a fresh rising edge.
    for flag, mode, label in LIGHTS_FLAGS:
        entry = FLAG_ACTION_ENTRY_TEMPLATE.format(
            idx=next_idx,
            comment=f'Lights {label}',
            action_text=lua_quote(build_lights_action_string(mode)),
            flag=flag,
        )
        new_entries.append(entry)
        next_idx += 1

    insertion = ''.join(new_entries)

    # Insert insertion right before the closing '}' of the actions table.
    # We locate the actions block more carefully by counting braces from the
    # opening '{' captured by m.
    start = m.end()
    depth = 1
    i = start
    while i < len(mission_src) and depth > 0:
        ch = mission_src[i]
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
        i += 1
    if depth != 0:
        raise RuntimeError('Unbalanced braces in ["actions"] table')
    close_brace_idx = i - 1
    # Insert at column 0 of the close-brace's line (i.e. right after the
    # previous '\n'), NOT immediately before the close brace itself.
    # Otherwise the close brace's leading indent (tabs) ends up prefixed
    # to our 12-space-indented "[N] =" lines and downstream strip-by-indent
    # regex can't find them.
    line_start = mission_src.rfind('\n', 0, close_brace_idx) + 1
    return mission_src[:line_start] + insertion + mission_src[line_start:]


# ---------------------------------------------------------------------------
# .miz zip plumbing
# ---------------------------------------------------------------------------
def _open_patchlog(miz_path: Path):
    """
    Open a sibling text log file next to the .miz so silent failures stop
    being silent. We dump everything we know to it as we go. The .bat
    pauses on exit, but if a tester closes the window before reading,
    the log still has the info.
    """
    log_path = miz_path.with_name(miz_path.stem + '-patchlog.txt')
    try:
        f = open(log_path, 'w', encoding='utf-8')
        f.write(f'CarrierGUI patcher log\n')
        f.write(f'  when:   {datetime.datetime.now().isoformat()}\n')
        f.write(f'  miz:    {miz_path.resolve()}\n')
        try:
            f.write(f'  size:   {miz_path.stat().st_size} bytes\n')
        except OSError as e:
            f.write(f'  size:   <stat failed: {e}>\n')
        f.write(f'  bridge: {BRIDGE_PATH}\n')
        f.write(f'  bridge exists: {BRIDGE_PATH.exists()}\n')
        f.write(f'  python: {sys.version}\n')
        f.write(f'  cwd:    {os.getcwd()}\n')
        f.write('\n')
        return f, log_path
    except OSError:
        # If we can't write next to the .miz (read-only / OneDrive locked /
        # whatever), fall back to silent log so the patch can still proceed.
        return None, None


def _verify_patch(miz_path: Path) -> int:
    """Re-open the patched .miz, count markers, return count."""
    try:
        with zipfile.ZipFile(miz_path) as z:
            data = z.read('mission')
        return data.count(MARKER.encode('utf-8'))
    except Exception:
        return -1


def patch_miz(miz_path: Path) -> None:
    log, log_path = _open_patchlog(miz_path)
    def L(msg=''):
        print(msg)
        if log:
            log.write(msg + '\n')
            log.flush()

    try:
        if not miz_path.exists():
            raise FileNotFoundError(miz_path)
        if not BRIDGE_PATH.exists():
            raise FileNotFoundError(
                f'Bridge file missing: {BRIDGE_PATH}. '
                'Patcher\\carrier-gui-bridge.lua must sit next to patch_miz.py.')

        L(f'  input:  {miz_path.resolve()}')
        L(f'  size:   {miz_path.stat().st_size} bytes')

        backup = miz_path.with_suffix(miz_path.suffix + '.bak')
        if not backup.exists():
            shutil.copy2(miz_path, backup)
            L(f'  backup -> {backup.name}')
        else:
            L(f'  backup already present ({backup.name}) — not overwriting')

        tmpdir = Path(tempfile.mkdtemp(prefix='carriergui_'))
        try:
            with zipfile.ZipFile(miz_path, 'r') as zin:
                zin.extractall(tmpdir)

            mission_file = tmpdir / 'mission'
            if not mission_file.exists():
                # Some unusual .miz tools may name the mission file
                # differently or nest it; surface what's in there.
                found = [str(p.relative_to(tmpdir)) for p in tmpdir.rglob('*') if p.is_file()]
                raise RuntimeError(
                    f"No `mission` file inside this .miz. Contents were: "
                    f"{', '.join(found) if found else '(empty)'}")
            L(f'  mission size before: {mission_file.stat().st_size} bytes')

            src = mission_file.read_bytes().decode('utf-8')
            new_src = patch_mission_lua(src)
            mission_file.write_bytes(new_src.encode('utf-8'))
            L(f'  mission size after:  {mission_file.stat().st_size} bytes')

            # Stale ME-resource bridge refresh.  If a mission designer ever
            # added the bridge MANUALLY in the Mission Editor (DO SCRIPT FILE
            # trigger), the .miz carries a frozen copy of that era's bridge
            # under l10n/<lang>/carrier-gui-bridge.lua.  At mission start that
            # trigger fires BEFORE our appended ones, its old bridge sets the
            # __CARRIER_GUI_BRIDGE_LOADED guard, and our fresh embedded bridge
            # no-ops.  The old bridge silently wins on every flight.
            # Fix: overwrite any such resource with the current bridge — then
            # whichever copy runs first, it's the same current code.
            bridge_src_bytes = BRIDGE_PATH.read_bytes()
            for stale in tmpdir.rglob('carrier-gui-bridge.lua'):
                rel = stale.relative_to(tmpdir)
                stale.write_bytes(bridge_src_bytes)
                L(f'  refreshed stale ME-resource bridge: {rel}')

            tmp_out = miz_path.with_suffix('.miz.tmp')
            with zipfile.ZipFile(tmp_out, 'w', zipfile.ZIP_DEFLATED) as zout:
                for root, _dirs, files in os.walk(tmpdir):
                    for f in files:
                        full = Path(root) / f
                        rel  = full.relative_to(tmpdir)
                        zout.write(full, str(rel).replace('\\', '/'))
            os.replace(tmp_out, miz_path)
            L(f'  rewrote {miz_path.name} ({miz_path.stat().st_size} bytes)')
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

        # Self-validate: re-open the .miz and verify our markers landed.
        n = _verify_patch(miz_path)
        L(f'  verify: {n} CarrierGUI markers in patched mission (expected 12)')
        if n < 12:
            L('  !! VERIFY FAILED — patch did not take. Restoring from backup.')
            shutil.copy2(backup, miz_path)
            L(f'  restored {miz_path.name} from {backup.name}')
            raise RuntimeError(
                f'Post-patch verify expected 12 markers, found {n}. '
                'Backup restored; .miz is back to its original state.')
        print(f'  patched: {miz_path.name}  (verified OK)')
        if log:
            log.write(f'\nRESULT: SUCCESS\n')
            log.close()
            print(f'  log:    {log_path.name}')
    except Exception:
        # Make sure the exception's traceback ends up in the log file.
        if log:
            log.write('\nTRACEBACK:\n')
            log.write(traceback.format_exc())
            log.write('\nRESULT: FAILED\n')
            log.close()
            print(f'  log written to: {log_path.name}')
        raise


def revert_miz(miz_path: Path) -> None:
    if not miz_path.exists():
        raise FileNotFoundError(miz_path)
    tmpdir = Path(tempfile.mkdtemp(prefix='carriergui_revert_'))
    try:
        with zipfile.ZipFile(miz_path, 'r') as zin:
            zin.extractall(tmpdir)
        mission_file = tmpdir / 'mission'
        if not mission_file.exists():
            raise RuntimeError(f'No `mission` file inside {miz_path}')
        # Read as bytes to preserve original line endings (DCS missions
        # use LF; text-mode I/O on Windows would translate to CRLF).
        src = mission_file.read_bytes().decode('utf-8')
        new_src = strip_existing_patch(src)
        if src == new_src:
            print(f'  nothing to revert in {miz_path.name}')
            return
        mission_file.write_bytes(new_src.encode('utf-8'))

        tmp_out = miz_path.with_suffix('.miz.tmp')
        with zipfile.ZipFile(tmp_out, 'w', zipfile.ZIP_DEFLATED) as zout:
            for root, _dirs, files in os.walk(tmpdir):
                for f in files:
                    full = Path(root) / f
                    rel  = full.relative_to(tmpdir)
                    zout.write(full, str(rel).replace('\\', '/'))
        os.replace(tmp_out, miz_path)
        print(f'  reverted: {miz_path.name}')
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument('miz', help='Path to .miz mission file (or multiple)', nargs='+')
    ap.add_argument('--revert', action='store_true', help='Remove the patch')
    args = ap.parse_args()

    rc = 0
    for path in args.miz:
        p = Path(path)
        print(f'\n[{p.name}]')
        try:
            if args.revert:
                revert_miz(p)
            else:
                patch_miz(p)
        except Exception as e:
            print(f'  ERROR: {e}')
            rc = 1
    return rc


if __name__ == '__main__':
    sys.exit(main())
