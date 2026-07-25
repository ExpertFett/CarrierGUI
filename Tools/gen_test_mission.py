#!/usr/bin/env python3
"""
gen_test_mission.py - build the CarrierGUI systems-test mission.

One mission that exercises every carrier feature we need to verify after a
DCS update / patch re-run:

  1. LSO + PLAT NVG      - night, player Hornet on deck, recovery traffic
  2. MARSHALL / TOWER    - AI stacked in the CCZ at spread range/altitude
  3. DECKBOSS            - AI parked on deck + a recovery tanker
  4. ELEVATORS           - late-activated deck spawns (elevator 4 = SPAWN) and
                           recovering AI that taxi + despawn (elevators 1/2/3)
  5. Ops Bot bomb grade  - a TGT-marked ground target, scored by dcsopt_mission

Usage:  python Tools/gen_test_mission.py [outfile.miz]
"""
import sys
from dcs.mission import Mission, StartType
from dcs.terrain import Caucasus
from dcs.mapping import Point
from dcs.country import Country
import dcs.ships as ships
import dcs.planes as planes
import dcs.vehicles as vehicles
import dcs.task as task
from dcs.triggers import TriggerOnce, Event
from dcs.point import PointAction
from dcs.condition import TimeAfter
from dcs.action import DoScript, ActivateGroup
from dcs.translation import String

OUT = sys.argv[1] if len(sys.argv) > 1 else "CarrierGUI-SystemsTest-v1.0.miz"

m = Mission(terrain=Caucasus())
T = m.terrain

# Night so the PLAT NVG gain is actually testable; the UI overlays (radar /
# deck images) render regardless of time of day.
m.start_time = m.start_time.replace(hour=21, minute=0, second=0)

# Wind so "TURN INTO WIND" does something visible, and the LSO crosswind
# readout has a non-zero value to show.
m.weather.wind_at_ground.speed = 6      # m/s  (~12 kt)
m.weather.wind_at_ground.direction = 225
m.weather.wind_at_8000.speed = 10
m.weather.wind_at_8000.direction = 240
m.weather.clouds_base = 2000

usa: Country = m.country("USA")

# ---------------------------------------------------------------- carrier ---
# Open water south-west of Batumi: plenty of sea room on a westerly BRC.
CV_X, CV_Y = -280000.0, 480000.0
cv_pos = Point(CV_X, CV_Y, T)

cv = m.ship_group(usa, "CVN-71 Roosevelt", ships.CVN_71, cv_pos, heading=270)
# Steam WEST at ~20 kt so recoveries have wind over deck for the whole test.
# NOTE pydcs Point(x, y): x = NORTH, y = EAST -> west means y DEcreasing.
cv.add_waypoint(Point(CV_X, CV_Y - 120000.0, T), speed=10)   # ~20 kt
cv.units[0].name = "Mother"

# Escort - gives DECKBOSS / MARSHALL a second surface contact.
esc = m.ship_group(usa, "Escort", ships.USS_Arleigh_Burke_IIa,
                   Point(CV_X + 6000.0, CV_Y + 4000.0, T), heading=270)
esc.add_waypoint(Point(CV_X + 6000.0, CV_Y - 116000.0, T), speed=10)


def deck_flight(name, n, start=StartType.Cold, late=False, callsign=None):
    """A flight parked on the carrier deck."""
    fg = m.flight_group_from_unit(
        usa, name, planes.FA_18C_hornet, cv,
        maintask=task.CAP, start_type=start, group_size=n)
    if late:
        fg.late_activation = True
    return fg


# ------------------------------------------------- 1. PLAYER (LSO / NVG) ---
# Hot on deck so you can jump straight to LAlt+F9 (LSO) or fly.
player = deck_flight("Player Hornet", 1, start=StartType.Warm)
player.units[0].set_player()
player.units[0].name = "Player"

# ------------------------------------- 2. DECKBOSS: jets parked on deck ---
# CROWD THE DECK ON PURPOSE. Per ED's own FAQ the elevators run "automatically
# for the AI to move aircraft off the deck to prevent over-crowding" -- so deck
# pressure is the actual trigger we are trying to provoke, not just traffic.
for tag in ("Alpha", "Bravo", "Charlie", "Delta", "Echo"):
    deck_flight("Deck " + tag, 2)

# ---------------------- 3. ELEVATOR "SPAWN" test (elevator 4 = SPAWN) -----
# Late-activated deck groups. Each activation is a fresh deck spawn, which is
# what drives the SPAWN elevator in USS_Nimitz_RunwaysAndRoutes.lua. Fire them
# early (T+1 / +2.5 / +4) so a short test still exercises them.
elev_spawns = [deck_flight("Elevator Spawn %d" % i, 2, late=True)
               for i in (1, 2, 3)]

# ---------- 4. ELEVATOR "DESPAWN" test + MARSHALL/TOWER stack picture -----
# Airborne AI inbound to recover. After they trap and taxi to a lift parking
# spot they despawn -> that is what cycles DESPAWN elevators 1/2/3.
# Spread in range + altitude so the marshal stack / CCZ tables have content.
STACK = [
    ("Recovery 1", 10000.0, 900),
    ("Recovery 2", 15000.0, 1200),
    ("Recovery 3", 21000.0, 1500),
    ("Recovery 4", 28000.0, 1800),
]


def land_on_carrier(fg, ship_group):
    """Landing waypoint bound to a ship (pydcs land_at() only takes Airports)."""
    wp = fg.add_waypoint(ship_group.position, altitude=0, speed=0)
    wp.type = "Land"
    wp.action = PointAction.Landing
    wp.helipad_id = ship_group.units[0].id
    wp.link_unit = ship_group.units[0].id
    return wp


for nm, dist, alt in STACK:
    # Astern of the boat (east) and offset north, all over open water.
    fg = m.flight_group(
        usa, nm, planes.FA_18C_hornet, None,
        Point(CV_X + dist * 0.2, CV_Y + dist, T),
        altitude=alt, speed=180, maintask=task.CAP, group_size=2)
    fg.add_waypoint(cv_pos, altitude=alt, speed=180)
    land_on_carrier(fg, cv)

# Recovery tanker - exercises the tanker/AWACS filter on MARSHALL + DECKBOSS.
tkr = m.flight_group(
    usa, "Texaco", planes.S_3B_Tanker, None,
    Point(CV_X + 20000.0, CV_Y - 16000.0, T),
    altitude=2000, speed=150, maintask=task.Refueling, group_size=1)
tkr.add_waypoint(Point(CV_X + 30000.0, CV_Y - 26000.0, T), altitude=2000, speed=150)

# -------------------------------- 5. Ops Bot bomb-grade target (TGT mark) ---
# Small ground group ashore + an F10 mark whose text starts with "TGT", which
# is what dcsopt_mission.lua scores bomb impacts against.
TGT_X, TGT_Y = -210000.0, 560000.0
m.vehicle_group(usa, "TGT Convoy", vehicles.Armor.T_55,
                Point(TGT_X, TGT_Y, T), heading=90, group_size=3)

mark_script = (
    "-- CarrierGUI systems test: F10 mark for Ops Bot bomb scoring\n"
    "trigger.action.markToAll(1701, 'TGT Convoy', "
    "{{x = {x}, y = 0, z = {z}}}, false)\n"
).format(x=TGT_X, z=TGT_Y)

trig = TriggerOnce(Event.NoEvent, "TGT mark")
trig.add_condition(TimeAfter(5))
trig.add_action(DoScript(String(mark_script)))
m.triggerrules.triggers.append(trig)

# Stagger the elevator spawn activations: T+3, T+6, T+9 minutes.
for i, fg in enumerate(elev_spawns):
    t = TriggerOnce(Event.NoEvent, "Elevator spawn %d" % (i + 1))
    t.add_condition(TimeAfter(60 + i * 90))
    t.add_action(ActivateGroup(fg.id))
    m.triggerrules.triggers.append(t)

m.save(OUT)
print("wrote", OUT)
print("  carrier   : CVN-71 @ (%.0f, %.0f) heading 270, 20 kt" % (CV_X, CV_Y))
print("  player    : 1x F/A-18C hot on deck")
print("  deck AI   : 10x parked (deck crowding) | elevator spawns @ T+1/2.5/4 min")
print("  recovery  : 8x inbound 5-15nm (trap -> taxi -> despawn) + S-3B tanker")
print("  target    : TGT Convoy + F10 'TGT' mark at T+5s")
print("  time      : 21:00 night, wind 225/12kt")
