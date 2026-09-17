# Nice Flight! — DLG flight celebration widget for FrSky Ethos

Sister project to Throw Trainer (`~/Developer/ThrowTrainer`) and DLG Poker
(`~/Developer/DLGPoker`). **Read Throw Trainer's CLAUDE.md "Hard-won Ethos-Lua
facts" before touching file I/O, sources or events** — every rule there
applies here and the code was lifted from it (numeric `f:read(N)` only, logic
switches read +-100, `age()` is -1 when nothing was received, touch acts on
TOUCH_END only, FS1-4 are category 12, pcall every entry point).

The spec is the two approved mockups in `mockup/`. Do not redesign screens
without the pilot; change the mockup first.

## Layout

```
NiceFlt/            -> scripts/NiceFlt/ on the radio (widget key "niceflt")
  main.lua          glue, pcall-wrapped entry points, 1 Hz repaint gate
  core.lua          storage, sources, flight state machine, climbs, badges
  draw.lua          every lcd.* call: key row, values, pills, chips, graph, icons
  screen.lua        Live / Idle / Recap / History / Badges + keys and events
  config.lua        native settings form
  icons/*.png       24 px badge icons (tools/make_icons.py, original art)
  Files/            flights.csv badges.csv config.csv diag.csv (never ship data)
harness/            python3 harness/run.py  -- run before every deploy
                    python3 harness/render.py -- the widget's REAL paint calls as SVG
                    (harness/out/index.html); look at it after any layout change,
                    it caught the graph losing its launch peak on day one
tools/              make_icons.py, deploy_sim.sh
mockup/             the approved spec
```

## Decisions that are easy to get wrong

- **Internal altitude is always feet.** The sensor's unit is detected once
  (`S.sensorUnit`) and converted. Display and every ladder use `cfg.units`.
  Metric ladders are separate round ladders (`LADDERS.m`), never converted
  feet, and badge rows carry their unit system so the two never mix.
- **Flight start** = flight mode leaves Launch (2) after having entered it.
  **Launch height** = running max until 3 s after leaving Launch/Zoom (10 s
  cap). **Flight end** = Landing mode (4) held 2 whole seconds AND altitude
  under `cfg.landAlt` (or telemetry lost); OR the next launch (ends at the
  last sample above 20 ft); OR 20 s on the ground.
- A "flight" that never reached 25 ft is a fumble: not logged, not a throw.
- **Nice** = beat `niceHeight` OR `niceTimeMin` OR earned any badge.
- `os.time()` is whole seconds. Anything timed is in whole seconds on purpose.
- **Climbs**: one online reversal detector at min(climb size, yo-yo floor);
  coarser views re-run `zigzag()` over the pivots. Yo-yo/Rebound/Save use the
  fixed ladder floors, the climb COUNT and graph use `cfg.climb` (default 50 ft /
  15 m since 2026-09-17; the graph still keeps at most six reversals, smallest
  dropped first, the count is uncapped).
- **badges.csv is append-only** (`sys,fam,kind,val,exact,ts,model,extra,seed`).
  Tallies are row counts; records and bests are derived at load. Only
  purgeSeed/erase rewrite it.
- The recap and the live pill show ONE pill per family (`core.displayBadges`);
  all rungs are still recorded.
- Mid-flight alert: one vibration per second at most, no sound (the vario owns
  audio). `cfg.alerts = 0` silences the landing alert, the vibration AND the
  pill.
- Records start at a floor (400 ft / 10 min), so the first flight over the
  floor is a record.
- Sample data (`seed = 1`) is purged the moment a flight passes 25 ft.
- Paint is gated to 1 Hz + input (`screen.needsPaint`): the recap graph is a
  few hundred `drawLine` calls.

## Simulator time scale

`cfg.timeScale` (CFG > Data, 1/4/8/16) multiplies the FLIGHT clock only
(`clock()` in core.lua); timestamps, the day boundary and the landing alert
delay stay on real time. Ignored when `system.getVersion().simulation ==
false`. Because os.time() is whole seconds the flight clock then moves N
seconds per step, so anything timed must tolerate a step > 1 (`sampleFlight`
gets `dt`). The macros keep launch hold, Zoom exit, brake and landing tail
in REAL seconds, since the model's own logic runs in real time.

There is deliberately no `configure` callback in main.lua: Ethos opens it
the moment the widget is added, which looked like the app launching on CFG
(FEEDBACK.md #1).

## Real-flight tooling

- `harness/replay.py <logs>` replays Ethos log CSVs through the real core
  (flight mode derived from the logged MOM_LAUNCH / ZOOM_MODE / LANDING_MODE
  switches). 60 real flights from 2026-09-13..16 segment correctly, including
  hand catches with no brake.
- `tools/make_macros.py <logdir>` builds `sim/NiceSim*/flight.lua`;
  `harness/macro_check.py` runs those files UNMODIFIED against the core with a
  mocked `simulator` namespace and asserts each flight's outcome in sequence.
- Facts read off the pilot's logs: launch button = switch SG (index 6),
  brake = throttle stick (about +1015 off, pulled negative = Landing mode),
  Zoom ends ~1 s after release on an elevator push, Altitude is BLANK while
  the launch button is held (SF11 reset), log rate ~4 Hz, the pilot's launches
  are 85-110 ft. Raw logs stay out of git (`sim/logs/` is ignored).
- UNVERIFIED in the simulator: `simulator.setSwitch(6, +-100)` and
  `simulator.setAnalog(1|2, -100..100)` argument scales. The macros pcall
  them and print a prompt to work the control by hand if one fails.

## Not yet verified on hardware

`lcd.loadBitmap` / `lcd.drawBitmap` with PNG alpha (falls back to a lettered
square), `FONT_XXL` / `FONT_STD` availability (falls back down the list),
`system.playTone` from a widget, and the whole thing on a real X14.
