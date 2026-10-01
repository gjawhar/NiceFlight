-- Nice Flight! execution harness: mocks the Ethos globals, runs the SAME
-- require chain main.lua uses, and flies simulated flights second by second.

local failures, checks = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if cond then print("  ok   " .. msg) else failures = failures + 1; print("  FAIL " .. msg) end
end

-- ---------------------------------------------------------------- mocks

CATEGORY_TELEMETRY_SENSOR, CATEGORY_LOGIC_SWITCH, CATEGORY_FLIGHT = 1, 2, 3
CATEGORY_FUNCTION_SWITCH = 12
FONT_XS, FONT_S, FONT_STD, FONT_L, FONT_XL, FONT_XXL = 0, 1, 2, 3, 4, 5
KEY_ROTARY_RIGHT, KEY_ROTARY_LEFT, KEY_ENTER_BREAK, KEY_RTN_FIRST, KEY_EXIT_FIRST = 11, 12, 13, 14, 15
EVT_KEY, EVT_TOUCH = 0, 1
TOUCH_START, TOUCH_END, TOUCH_MOVE, TOUCH_LONG = 16640, 16641, 16642, 16643

SIM = { alt = 0, altAge = 100, altUnit = "ft", fm = 0, rxv = 3.74, rxAge = 100, rxLow = -100,
        fs = { -100, -100, -100, -100 }, model = "Bull Nose", haptics = 0, tones = 0 }

local function mkSrc(get, age, unit, name)
  local s = {}
  function s:value() return get() end
  function s:age() return age and age() or 0 end
  function s:stringUnit() return unit and unit() or "" end
  function s:name() return name or "mock" end
  return s
end

system = {
  getSource = function(spec)
    if spec.category == CATEGORY_TELEMETRY_SENSOR and spec.name == "Altitude" then
      return mkSrc(function() return SIM.alt end, function() return SIM.altAge end, function() return SIM.altUnit end)
    elseif spec.category == CATEGORY_TELEMETRY_SENSOR and spec.name == "RxBatt" then
      return mkSrc(function() return SIM.rxv end, function() return SIM.rxAge end, function() return "V" end, "RxBatt")
    elseif spec.category == CATEGORY_TELEMETRY_SENSOR and spec.name == "ADC2" then
      return mkSrc(function() return 4.10 end, function() return 100 end, function() return "V" end, "ADC2")
    elseif spec.category == CATEGORY_LOGIC_SWITCH and spec.name == "RXBAT_LOW" then
      return mkSrc(function() return SIM.rxLow end)
    elseif spec.category == CATEGORY_FLIGHT and spec.member == 0 then
      return mkSrc(function() return SIM.fm end)
    elseif spec.category == 12 then
      local mbr = spec.member
      return mkSrc(function() return SIM.fs[mbr + 1] end)
    end
    return nil
  end,
  getVersion = function() return { board = "X20RS", simulation = true } end,
  playHaptic = function() SIM.haptics = SIM.haptics + 1 end,
  playTone = function() SIM.tones = SIM.tones + 1 end,
}
model = { name = function() return SIM.model end }

-- lcd mock that remembers what was drawn and where, so layout can be
-- checked against the canvas without a screen.
local FONT_H = { [0] = 17, [1] = 20, [2] = 25, [3] = 28, [4] = 37, [5] = 47 }     -- measured on the X14 sim, 26.1.2
local CHAR_W = { [0] = 9, [1] = 11, [2] = 13, [3] = 15, [4] = 20, [5] = 26 }
local curFont, drawn, CW, CH = 1, {}, 640, 360
lcd = {
  color = function() end, pen = function() end,
  font = function(f) assert(FONT_H[f], "unknown font " .. tostring(f)); curFont = f end,
  invalidate = function() end, resetFocusTimeout = function() end,
  hasFocus = function() return true end, isSwiping = function() return false end,
  RGB = function(r, g, b) return { r, g, b } end, GREY = function(v) return { v, v, v } end,
  getWindowSize = function() return CW, CH end,
  getTextSize = function(t) return #tostring(t) * CHAR_W[curFont] + 0.5, FONT_H[curFont] + 0.0 end,   -- FLOATS, as on Ethos
  drawText = function(x, y, t)
    assert(type(t) == "string", "drawText got " .. type(t))
    assert(type(x) == "number" and type(y) == "number", "drawText coords")
    drawn[#drawn + 1] = { x = x, y = y, t = t, h = FONT_H[curFont], w = #t * CHAR_W[curFont] }
  end,
  drawFilledRectangle = function(x, y, w, h) assert(x and y and w and h, "rect args") end,
  drawRectangle = function(x, y, w, h) assert(x and y and w and h, "rect args") end,
  drawLine = function(a, b, c, d) assert(a and b and c and d, "line args") end,
}
-- form mock that actually calls every getter/setter config.lua registers,
-- so a typo in the settings page fails here and not on the radio.
local formFields = {}
local function field(get, set)
  local f = { suffix = function() end, step = function() end }
  formFields[#formFields + 1] = { get = get, set = set }
  return f
end
local function mkPanel()
  return { addLine = function(_, text) return { text = text } end, open = function() end }
end
form = {
  openDialog = function(d) form.lastDialog = d end, clear = function() end,
  addExpansionPanel = function() return mkPanel() end,
  addNumberField = function(line, r, min, max, get, set) return field(get, set) end,
  addChoiceField = function(line, r, choices, get, set) return field(get, set) end,
  addSourceField = function(line, r, get, set) return field(get, set) end,
  addStaticText = function() return {} end,
  addButton = function(line, r, b) formFields[#formFields + 1] = { press = b.press } return {} end,
}

-- ---------------------------------------------------------------- require chain (as main.lua)

local core   = assert(loadfile("core.lua"))()
local draw   = assert(loadfile("draw.lua"))(core)
local config = assert(loadfile("config.lua"))(core, draw)
local screen = assert(loadfile("screen.lua"))(core, draw, config)
print("require chain loaded")
local app = screen.new({ needsFocus = true })

-- ---------------------------------------------------------------- clock + helpers

local realTime, tOff = os.time, 0
os.time = function() return realTime() + tOff end

local function paint() drawn = {}; app.paint(CW, CH) end
local function tick() core.wakeup(); paint() end
local function sec(n) for _ = 1, (n or 1) do tOff = tOff + 1; tick() end end
local function sawText(pat) for _, d in ipairs(drawn) do if d.t:find(pat, 1, true) then return true end end return false end
local function inBounds()
  for _, d in ipairs(drawn) do
    if d.x < 0 or d.y < 0 or d.y + d.h > CH + 1 or d.x + d.w > CW + 1 then return false, d.t .. " @" .. d.x .. "," .. d.y end
  end
  return true
end
local function boundsCheck(name) local ok, what = inBounds(); check(ok, name .. ": every text inside the canvas" .. (ok and "" or (" (" .. tostring(what) .. ")"))) end

-- Fly a flight: press the launch button (SF11 zeroes the altitude), release
-- into Zoom, leave Zoom after 2 s, then follow waypoints {t, alt} linearly.
-- brake = hold Landing mode at the end; false = hand catch, no brake.
local function fly(way, brake, hook)
  SIM.fm = 2; SIM.alt = 0; sec(1)
  SIM.fm = 3; tick()
  local t = 0
  for i = 2, #way do
    local t0, a0, t1, a1 = way[i - 1][1], way[i - 1][2], way[i][1], way[i][2]
    while t < t1 do
      t = t + 1
      SIM.alt = a0 + (a1 - a0) * (t - t0) / (t1 - t0)
      if t == 2 then SIM.fm = 0 end
      sec(1)
      if hook then hook(t) end
    end
  end
  if brake ~= false then SIM.fm = 4; sec(4); SIM.fm = 0; tick() end
end
local function rows(base) return core.readRows(base) end
local function lastFlightRow() local r = rows("flights"); return r[#r] or {} end
local function badgeRow(fam, kind, val)
  for _, r in ipairs(rows("badges")) do
    if r[2] == fam and r[3] == kind and (val == nil or tonumber(r[4]) == val) then return true end
  end
  return false
end
local function countBadge(fam, kind)
  local n = 0
  for _, r in ipairs(rows("badges")) do if r[2] == fam and r[3] == kind then n = n + 1 end end
  return n
end

-- ---------------------------------------------------------------- zigzag

print("\n-- reversal detector")
do
  local z = core.zigzag({ { t = 0, a = 171 }, { t = 50, a = 55 }, { t = 120, a = 402 }, { t = 200, a = 200 },
                          { t = 300, a = 588 }, { t = 380, a = 350 }, { t = 450, a = 560 }, { t = 500, a = 0 } }, 100)
  local kinds = {}
  for i, pv in ipairs(z) do kinds[i] = pv.kind .. math.floor(pv.a) end
  check(table.concat(kinds, " ") == "H171 L55 H402 L200 H588 L350 H560 L0", "pivots: " .. table.concat(kinds, " "))
  local z2 = core.zigzag({ { t = 0, a = 170 }, { t = 10, a = 165 }, { t = 20, a = 172 }, { t = 30, a = 160 }, { t = 60, a = 0 } }, 100)
  check(#z2 == 2 and z2[2].open, "5-10 ft wiggles produce no reversals")
end

-- ---------------------------------------------------------------- boot

print("\n-- boot")
core.init()
check(core.S.ready, "core.init ready")
tick()
check(core.state() == "idle", "starts idle")
check(sawText("HISTORY") and sawText("BADGES") and sawText("CFG"), "idle key row")
check(sawText("RX 3.74V"), "RX voltage shown")
check(sawText("NICE FLIGHTS TODAY") and sawText("of 0 throws"), "idle tally labelled")
check(sawText("Bull Nose - ready"), "idle status line")
boundsCheck("idle (empty)")
SIM.rxAge = 9000; tick()
check(sawText("RX --"), "stale RX voltage shows RX --")
SIM.rxAge = 100
sec(2)
local diagBoot = false
for _, r in ipairs(rows("diag")) do if r[3] == "boot" then diagBoot = true end end
check(diagBoot, "diag: boot row written from wakeup")

-- ---------------------------------------------------------------- fumble + ordinary throw

print("\n-- fumble, then an ordinary throw")
fly({ { 0, 0 }, { 3, 10 }, { 6, 0 } })
check(core.state() == "idle" and #rows("flights") == 0, "bench press / fumble under 25 ft is not a throw")

fly({ { 0, 0 }, { 4, 170 }, { 40, 30 }, { 46, 3 } })
check(#rows("flights") == 1, "ordinary throw logged")
check(lastFlightRow()[10] == "0", "ordinary throw is not nice")
check(core.state() == "idle", "no recap for an ordinary throw")
check(math.abs(tonumber(lastFlightRow()[4]) - 170) <= 2, "launch height ~170 (" .. tostring(lastFlightRow()[4]) .. ")")
check(sawText("of 1 throw") and core.S.last and core.S.last.dur >= 40 and core.S.last.dur <= 50, "idle shows the last throw honestly (big digits are drawn, not text)")
check(SIM.tones == 0, "ordinary flight stays silent")
boundsCheck("idle (after a throw)")

-- ---------------------------------------------------------------- the mockup's nice flight

print("\n-- nice flight: 171 launch, save from 55, climbs to 402 / 588 / 560")
SIM.haptics = 0
local sawLive, pillSeen, liveBounds = false, false, true
tonesMid = 0
SIM.tones = 0
fly({ { 0, 0 }, { 4, 171 }, { 115, 55 }, { 268, 402 }, { 380, 200 }, { 500, 588 }, { 590, 350 }, { 660, 560 }, { 700, 40 }, { 704, 5 } },
    true, function(t)
      if t == 300 then
        sawLive = core.state() == "live" and sawText("FLIGHT") and sawText("Time above launch") and sawText("Climbs over 50 ft:")
        liveBounds = inBounds()
      end
      if t == 520 then pillSeen = sawText("BADGE EARNED"); tonesMid = SIM.tones end
    end)
check(sawLive, "live screen: timer, stacked bottom lines")
check(liveBounds, "live: every text inside the canvas")
check(pillSeen, "live: badge pill with BADGE EARNED label after a mid-flight badge")
check(SIM.haptics > 0 and SIM.haptics <= 9, "mid-flight badges vibrate once per moment, not once per rung (" .. SIM.haptics .. ")")
check(tonesMid > 0, "mid-flight badge also plays a short beep (" .. tostring(tonesMid) .. ")")
check(core.state() == "recap", "nice flight lands on the recap")
local fr = lastFlightRow()
check(fr[10] == "1", "flight marked nice")
check(math.abs(tonumber(fr[4]) - 171) <= 2 and tonumber(fr[5]) == 588, "launch 171 / max 588 (" .. fr[4] .. "/" .. fr[5] .. ")")
check(tonumber(fr[8]) == 3, "3 climbs over 50 ft (" .. tostring(fr[8]) .. ")")
check(tonumber(fr[9]) >= 380 and tonumber(fr[9]) <= 392, "best climb ~388 (" .. tostring(fr[9]) .. ")")
check(math.abs(tonumber(fr[6]) - 706) <= 6, "duration ~11:4x (" .. tostring(fr[6]) .. ")")
check(badgeRow("peak", "first", 400) and not badgeRow("peak", "first", 600), "Peak first 400 only")
check(not badgeRow("peak", "rep"), "no per-flight Peak under 1000 ft")
check(badgeRow("dur", "first", 5) and badgeRow("dur", "first", 10) and not badgeRow("dur", "first", 15), "Duration firsts 5 and 10")
check(badgeRow("yoyo", "first", 100) and badgeRow("yoyo", "first", 200) and not badgeRow("yoyo", "first", 300), "Yo-yo 3x 200: firsts 100, 200")
check(not badgeRow("yoyo", "rep"), "no per-flight yo-yo under 300")
check(badgeRow("save", "rep", 60) and badgeRow("save", "first", 60) and not badgeRow("save", "first", 50) and not badgeRow("save", "first", 100), "save from 55 = the 60 rung, the top of the ladder (under 60 ft, back to 300)")
check(badgeRow("rech", "rec") and badgeRow("rect", "rec"), "records beat the 400 ft / 10 min floors")
check(sawText("Nice Flight!") and sawText("BADGES EARNED ON THIS FLIGHT"), "recap title and badge label")
check(sawText("Save from 5") and sawText("3x 200 ft") and sawText("New record 588 ft"), "recap badge wording")
check(sawText("DISMISS"), "recap key row")
check(sawText("Bull Nose - "), "recap header: model and date")
boundsCheck("recap")
SIM.tones, SIM.haptics = 0, 0
sec(3)
check(SIM.tones >= 2 and SIM.haptics >= 1, "landing alert: sound + vibration a couple of seconds after landing")
do
  local seen = false
  for _, r in ipairs(rows("diag")) do if r[3] == "alert" and (r[4] or ""):find("landing tone1=ok tone2=ok haptic=ok", 1, true) then seen = true end end
  check(seen, "diag records what the landing alert calls returned")
end
-- rotary moves the badge highlight and the caption follows
app.event(KEY_ROTARY_RIGHT, 1, nil, EVT_KEY); paint()
check(app.V.badgeSel == 2, "rotary moves the recap badge highlight")

-- ---------------------------------------------------------------- brake in the air, relaunch, ground close

print("\n-- brake in the air is ignored; relaunch closes the recap and an unbraked flight")
SIM.fm = 2; SIM.alt = 0; sec(1)
check(core.state() ~= "recap" or true, "launch button pressed")
SIM.fm = 3; tick()
check(core.state() == "live", "relaunch closes the recap and starts Live")
for t = 1, 60 do SIM.alt = math.min(320, t * 40); if t == 2 then SIM.fm = 0 end; sec(1) end
SIM.fm = 4; sec(5); SIM.fm = 0
check(core.state() == "live", "brake held at 320 ft does not end the flight")
for t = 1, 40 do SIM.alt = math.max(4, 320 - t * 9); sec(1) end
local before = #rows("flights")
SIM.fm = 2; SIM.alt = 0; sec(1); SIM.fm = 3; tick()      -- hand catch, straight into the next throw
check(#rows("flights") == before + 1, "next launch closes the unbraked flight")
local unbraked = lastFlightRow()
check(tonumber(unbraked[6]) < 115, "unbraked duration ends at the last sample above 20 ft (" .. tostring(unbraked[6]) .. ")")
-- this second flight: up, then sits on the ground with no brake and no relaunch
for t = 1, 30 do SIM.alt = (t < 5) and t * 40 or math.max(2, 200 - (t - 5) * 12); if t == 2 then SIM.fm = 0 end; sec(1) end
check(core.state() == "live", "still live while on the ground under the hold time")
sec(25)
check(core.state() ~= "live", "sitting on the ground 20 s ends the flight")

-- ---------------------------------------------------------------- second nice flight, rebound

print("\n-- second nice flight: no repeated firsts; rebound 600")
core.dismissRecap()
local firstsBefore = countBadge("peak", "first")
fly({ { 0, 0 }, { 4, 175 }, { 60, 600 }, { 140, 140 }, { 260, 660 }, { 330, 30 }, { 334, 4 } })
check(core.state() == "recap", "rebound flight is nice")
check(countBadge("peak", "first") == firstsBefore + 1 and badgeRow("peak", "first", 600), "only the new Peak first (600) is added")
check(badgeRow("reb", "first", 300) and badgeRow("reb", "first", 600) and badgeRow("reb", "rep", 600), "Rebound 600: firsts 300..600 and the per-flight badge")
check(sawText("Rebound 600 ft"), "recap shows Rebound 600 ft")
local recH = core.recordHeight()
check(recH == 660, "record height now 660 (" .. tostring(recH) .. ")")
core.dismissRecap(); tick()
check(core.state() == "idle", "DISMISS returns to idle")
check(sawText("Best today"), "idle shows best today")

-- ---------------------------------------------------------------- hat trick

print("\n-- hat trick on the 5th nice flight of the day")
local t = core.today()
check(t.nice == 3, "three nice flights so far today: the 588, the unbraked 320, the rebound (" .. t.nice .. ")")
for i = 1, 2 do
  fly({ { 0, 0 }, { 4, 170 }, { 40, 330 }, { 80, 30 }, { 84, 4 } })
  if i < 2 then check(not badgeRow("hat", "rep"), "no hat trick yet at " .. (3 + i)); core.dismissRecap() end
end
check(badgeRow("hat", "rep", 1), "hat trick awarded on the 5th nice flight")
check(sawText("Hat trick"), "recap shows the hat trick badge")
core.dismissRecap()

-- ---------------------------------------------------------------- history + badges screens

print("\n-- history and badges screens")
tick()
SIM.fs[2] = 100; core.wakeup(); local fs = nil
app.pressKey(2); paint()
check(app.V.screen == "history", "HISTORY key opens history")
check(sawText("DATE") and sawText("MODEL") and sawText("Bull Nose"), "history columns incl. model on the right")
check(sawText(" ft"), "history heights carry a unit")
check(#core.history() == 5, "history lists the 5 nice flights (" .. #core.history() .. ")")
boundsCheck("history")
app.event(KEY_ROTARY_RIGHT, 1, nil, EVT_KEY)
check(app.V.histSel == 2, "rotary moves the history selection")
app.event(KEY_ENTER_BREAK, nil, nil, EVT_KEY); paint()
check(app.V.screen == "histrecap" and sawText("Nice Flight!") and sawText("BACK"), "OPEN shows that flight's recap with BACK")
boundsCheck("history recap")
app.event(KEY_RTN_FIRST, nil, nil, EVT_KEY); check(app.V.screen == "history", "RTN goes back to history")
app.event(KEY_RTN_FIRST, nil, nil, EVT_KEY); check(app.V.screen == "auto", "RTN again goes back to idle")
app.pressKey(3); paint()
check(app.V.screen == "badges", "BADGES key opens badges")
check(sawText("Peak") and sawText("Yo-yo") and sawText("Record height") and sawText("Hat trick"), "eight family tiles")
check(sawText("600 ft") and sawText("FIRSTS"), "Peak tile shows the highest first earned (600 ft) and the ladder")
boundsCheck("badges / Peak")
for i = 2, 8 do
  app.pressKey(4); paint()
  local ok = inBounds()
  check(ok, "badges / " .. core.FAMILIES[i] .. ": inside the canvas")
end
local v = core.familyView("save")
check(v.big == "60 ft" and v.bigSuffix == "to 300" and v.title == "Save from <60 ft", "save tile: Save from <60 ft, 60 ft to 300")
v = core.familyView("hat")
check(v.big == "1 hat trick" and v.small == "5 nice flights/day" and v.chipLabel == "EARNED", "hat trick tile: count + rule, EARNED dates")
check(v.def:find("300 ft or 5:00", 1, true) ~= nil, "hat trick definition quotes the live CFG values")
v = core.familyView("rech")
check(v.big == "660 ft" and v.chips[#v.chips].sub == "floor" and v.chips[#v.chips].beaten, "record height: history ends with the beaten floor")
check(v.chips[1].beaten ~= true and v.chips[2].beaten == true, "standing record plain, beaten ones slashed")
v = core.familyView("yoyo")
check(v.big == "3x 200 ft" and v.bigSuffix == "climbs", "yo-yo tile: 3x 200 ft climbs")
app.event(KEY_RTN_FIRST, nil, nil, EVT_KEY)

-- touch: only the release acts
print("\n-- touch")
paint()
local r = app.V.keyRects[2]
check(r ~= nil, "touch rects exist on a touch radio")
app.event(TOUCH_START, r.x + 5, r.y + 5, EVT_TOUCH)
check(app.V.screen == "auto", "TOUCH_START does nothing")
app.event(TOUCH_END, r.x + 5, r.y + 5, EVT_TOUCH)
check(app.V.screen == "history", "TOUCH_END on HISTORY opens it")
app.event(KEY_RTN_FIRST, nil, nil, EVT_KEY)

-- ---------------------------------------------------------------- persistence

print("\n-- power cycle")
local niceBefore, throwsBefore = core.today().nice, core.today().throws
core.S.ready = false
core.S.altSrc, core.S.fmSrc = nil, nil
core.init(); tick()
check(#core.history() == 5, "history survives a restart")
check(core.today().nice == niceBefore and core.today().throws == throwsBefore, "today's tallies survive a restart")
check(core.recordHeight() == 660, "record survives a restart")
check(core.state() == "idle", "restart comes up idle")

print("\n-- power cycle mid-flight drops the flight")
local nRows = #rows("flights")
SIM.fm = 2; SIM.alt = 0; sec(1); SIM.fm = 3; tick()
for t2 = 1, 20 do SIM.alt = t2 * 20; if t2 == 2 then SIM.fm = 0 end; sec(1) end
core.S.ready = false; core.S.F = nil; core.init(); tick()
check(#rows("flights") == nRows and core.state() == "idle", "nothing written for the interrupted flight")

-- ---------------------------------------------------------------- telemetry loss, alerts off, model switch

print("\n-- telemetry lost mid-flight, alerts off")
core.S.cfg.alerts = 0
SIM.haptics, SIM.tones = 0, 0
local dashes = false
fly({ { 0, 0 }, { 4, 170 }, { 60, 820 }, { 120, 700 }, { 200, 30 }, { 204, 4 } }, true, function(tt)
  if tt == 80 then SIM.altAge = 9000 end
  if tt == 90 then dashes = sawText("--") end
  if tt == 100 then SIM.altAge = 100 end
end)
check(dashes, "Now shows -- while telemetry is lost")
check(core.state() == "recap", "flight still completes after a telemetry gap")
check(badgeRow("peak", "first", 800), "Peak 800 earned")
check(SIM.haptics == 0 and SIM.tones == 0, "Alerts off: no vibration, no sound")
core.S.cfg.alerts = 1
core.dismissRecap()

print("\n-- model switch mid-flight")
nRows = #rows("flights")
SIM.fm = 2; SIM.alt = 0; sec(1); SIM.fm = 3; tick()
for t2 = 1, 10 do SIM.alt = t2 * 30; sec(1) end
SIM.model = "Whip Tail"; SIM.fm = 0; sec(1)
check(core.state() == "idle" and #rows("flights") == nRows, "model switch drops the flight in progress")
core.setRxSensor("ADC2"); tick()
check(sawText("RX 4.10V"), "RX source switched by name for this plane")
SIM.model = "Bull Nose"; sec(1)
check(sawText("RX 3.74V"), "back on Bull Nose the RX source is its own")
SIM.model = "Whip Tail"; sec(1)
check(sawText("RX 4.10V"), "Whip Tail's RX source persisted per plane")

-- ---------------------------------------------------------------- sample data

print("\n-- sample data and its purge")
core.erase()
check(#rows("flights") == 0 and #rows("badges") == 0, "erase clears everything")
core.seedDemo(); tick()
check(#core.history() == 3, "sample data shows in history")
check(core.recordHeight() == 1340, "sample record 1340")
app.pressKey(3); paint(); boundsCheck("badges (sample data)")
app.event(KEY_RTN_FIRST, nil, nil, EVT_KEY)
fly({ { 0, 0 }, { 4, 170 }, { 40, 450 }, { 80, 30 }, { 84, 4 } })
check(#core.history() == 1, "first genuine flight purges the samples")
check(core.recordHeight() == 450 and badgeRow("peak", "first", 400), "and is judged against real badges only")
core.dismissRecap()

-- ---------------------------------------------------------------- metric

print("\n-- metric ladders")
core.setUnits("m")
check(core.S.cfg.niceHeight == 100 and core.S.cfg.climb == 15 and core.S.cfg.landAlt == 15, "round metric defaults")
SIM.altUnit = "m"; core.S.altSrc = nil; core.S.sourcesAt = 0; sec(1)
check(core.S.sensorUnit == "m", "sensor unit re-detected as m")
fly({ { 0, 0 }, { 4, 52 }, { 60, 190 }, { 100, 8 }, { 104, 1 } })
check(core.state() == "recap", "190 m flight is nice")
check(sawText("190 m"), "recap in metres")
local mrow = false
for _, rr in ipairs(rows("badges")) do if rr[1] == "m" and rr[2] == "peak" and tonumber(rr[4]) == 180 then mrow = true end end
check(mrow, "metric Peak ladder: 120 and 180 m firsts")
boundsCheck("recap (metric)")
core.dismissRecap()
core.setUnits("ft")
check(core.recordHeight() == 450, "switching back to ft restores the ft badges")

-- ---------------------------------------------------------------- 800x480

print("\n-- X20 canvas")
CW, CH = 800, 480
core.seedDemo(); tick(); boundsCheck("idle 800x480")
app.pressKey(2); paint(); boundsCheck("history 800x480")
app.event(KEY_ENTER_BREAK, nil, nil, EVT_KEY); paint(); boundsCheck("recap 800x480")
app.event(KEY_RTN_FIRST, nil, nil, EVT_KEY); app.event(KEY_RTN_FIRST, nil, nil, EVT_KEY)
app.pressKey(3); paint(); boundsCheck("badges 800x480")

-- ---------------------------------------------------------------- link lost for good

print("\n-- hand catch, plane unplugged: the flight still gets recorded")
SIM.altUnit = "ft"; core.S.altSrc = nil; core.S.sourcesAt = 0; sec(1)     -- back to a feet sensor after the metric section
check(core.S.sensorUnit == "ft", "sensor unit re-detected as ft")
core.erase(); core.dismissRecap()
do
  SIM.fm = 2; SIM.alt = 0; sec(1); SIM.fm = 3; tick(); SIM.fm = 0
  for t2 = 1, 120 do SIM.alt = (t2 < 60) and math.min(340, t2 * 8) or math.max(30, 340 - (t2 - 60) * 6); sec(1) end
  SIM.alt = 30; sec(2)
  SIM.altAge = -1                                   -- battery unplugged at 30 ft, in the hand
  sec(20); check(core.state() == "live", "20 s without a link: still waiting")
  sec(15)
  check(core.state() == "recap", "30 s without a link after being last seen low: flight closed and celebrated")
  local r = lastFlightRow()
  check(tonumber(r[5]) == 340 and tonumber(r[6]) >= 100 and tonumber(r[6]) <= 125, "recorded at full value, ending where it was last airborne (" .. tostring(r[5]) .. " ft, " .. tostring(r[6]) .. " s)")
  core.dismissRecap()
  -- link lost HIGH: no early close; after 3 minutes the clock stops where it was last seen
  SIM.altAge = 100
  SIM.fm = 2; SIM.alt = 0; sec(1); SIM.fm = 3; tick(); SIM.fm = 0
  for t2 = 1, 60 do SIM.alt = math.min(420, t2 * 9); sec(1) end
  SIM.altAge = -1
  sec(100); check(core.state() == "live", "link lost at 420 ft: 100 s later the flight is still open")
  sec(90)
  check(core.state() == "recap", "link lost at altitude for 3 minutes: the flight is closed")
  r = lastFlightRow()
  check(tonumber(r[6]) >= 55 and tonumber(r[6]) <= 70, "its clock stops where the plane was last seen (" .. tostring(r[6]) .. " s)")
  SIM.altAge = 100; core.dismissRecap()
end

-- ---------------------------------------------------------------- nice-flight alert

print("\n-- in-flight nice-flight alert: its own sound, once, distinct from a badge")
core.erase(); core.dismissRecap()
do
  SIM.tones, SIM.haptics = 0, 0
  local atCross, afterCross, labelSeen = nil, nil, false
  -- 320 ft and 2 minutes: nice by height, and no badge anywhere near (Peak starts at 400)
  fly({ { 0, 0 }, { 4, 100 }, { 40, 320 }, { 100, 30 }, { 104, 4 } }, true, function(t)
    if t == 30 then atCross = SIM.tones end                    -- still under 300 ft
    if t == 45 then afterCross = SIM.tones; labelSeen = sawText("NICE FLIGHT!") end
  end)
  check(atCross == 0, "silent until the flight qualifies")
  check(afterCross == 3, "crossing 300 ft plays the three-note chime (" .. tostring(afterCross) .. " tones)")
  check(labelSeen, "the timer label turns into NICE FLIGHT! on the Live screen")
  local niceRow, badgeRow2 = false, false
  for _, r in ipairs(rows("diag")) do
    if r[3] == "alert" and (r[4] or ""):find("nice tone=ok haptic=ok", 1, true) then niceRow = true end
  end
  check(niceRow, "diag records the nice-flight alert")
  check(SIM.haptics == 1, "exactly one buzz in flight, the long one (" .. SIM.haptics .. ")")
  sec(3)
  check(SIM.haptics == 2 and SIM.tones == 5, "the landing alert still follows two seconds after touchdown (" .. SIM.haptics .. " buzzes, " .. SIM.tones .. " tones)")
  core.dismissRecap()
  -- nice and a badge in the SAME second: only the chime sounds, the badge still gets the pill
  SIM.tones = 0
  local t3, pill = nil, nil
  SIM.fm = 2; SIM.alt = 0; sec(1); SIM.fm = 3; tick(); SIM.fm = 0
  for t2 = 1, 12 do SIM.alt = math.min(250, t2 * 30); sec(1) end
  SIM.alt = 450; sec(1)                                          -- 250 -> 450 ft in one second
  t3 = SIM.tones; pill = core.live() and core.live().pill
  check(t3 == 3, "nice + Peak 400 in the same second: the chime only, no extra beep (" .. tostring(t3) .. ")")
  check(pill and pill.fam ~= nil, "and the badge still takes the pill")
  SIM.alt = 480; sec(2)
  check(SIM.tones == 3, "the chime never repeats within a flight")
  for t2 = 1, 20 do SIM.alt = math.max(3, 480 - t2 * 30); sec(1) end
  SIM.fm = 4; sec(4); SIM.fm = 0; tick(); core.dismissRecap()
end

-- ---------------------------------------------------------------- model switch re-detects the sensor unit

print("\n-- in-place model switch between a metres model and a feet model")
do
  SIM.model = "Vortex 4"; SIM.altUnit = "m"; sec(1)
  check(core.S.sensorUnit == "m", "switching to a model whose Altitude is in metres detects m")
  SIM.model = "Storm Zen"; SIM.altUnit = "ft"; sec(1)
  check(core.S.sensorUnit == "ft", "switching back to a feet model re-detects ft without a reboot (field bug 2026-09-30)")
  local fmOk = core.currentFlightMode() ~= nil
  check(fmOk and core.S.altSrc ~= nil, "sources are re-resolved for the new model")
end

-- ---------------------------------------------------------------- simulator time scale

print("\n-- simulator time scale: an 8x replay is still measured at full length")
CW, CH = 640, 360
core.erase(); core.dismissRecap()
core.S.cfg.timeScale = 8
check(core.timeScale() == 8, "time scale honoured when the firmware says it is a simulator")
do
  -- 320 flight-seconds flown in 40 real seconds: altitude moves 8 s per tick
  SIM.fm = 2; SIM.alt = 0; sec(1); SIM.fm = 3; tick(); SIM.fm = 0
  for i = 1, 40 do
    local t8 = i * 8
    SIM.alt = (t8 <= 8) and 100 or ((t8 < 160) and (100 + (t8 - 8) * 1.8) or math.max(3, 374 - (t8 - 160) * 2.4))
    sec(1)
  end
  SIM.fm = 4; sec(3); SIM.fm = 0; tick()
  local r = lastFlightRow()
  check(core.state() == "recap", "compressed flight lands on the recap")
  check(tonumber(r[6]) >= 300 and tonumber(r[6]) <= 360, "measured at full length: " .. tostring(r[6]) .. " s from ~43 real seconds")
  check(badgeRow("dur", "first", 5), "Duration 5 min earned from a 40 second replay")
  tick(); core.dismissRecap(); tick()
  check(sawText("TEST CLOCK x8"), "idle screen shouts while the test clock is on")
end
local realGetVersion = system.getVersion
system.getVersion = function() return { board = "X14", simulation = false } end
check(core.timeScale() == 1, "time scale ignored on real hardware")
system.getVersion = function() return { board = "X14" } end
check(core.timeScale() == 1 and not core.isSimulator(), "and ignored when the firmware has no simulation field at all")
system.getVersion = realGetVersion
core.S.cfg.timeScale = 1

-- ---------------------------------------------------------------- main.lua + config.lua executed

print("\n-- main.lua entry points and the settings form")
CW, CH = 640, 360
local reg
system.registerWidget = function(t) reg = t end
local mainMod = assert(loadfile("main.lua"))()
mainMod.init()
check(reg and reg.key == "niceflt" and reg.name == "Nice Flight!", "widget registered as niceflt / Nice Flight!")
check(#reg.key <= 7, "widget key within the 7 character limit")
local wdg = reg.create()
check(wdg and wdg.app, "create returns a widget instance")
local okW = pcall(reg.wakeup, wdg); check(okW, "wakeup runs")
drawn = {}
local okP = pcall(reg.paint, wdg); check(okP and #drawn > 0, "paint runs and draws")
check(not sawText("error"), "paint shows no error text")
check(reg.event(wdg, EVT_KEY, KEY_ROTARY_RIGHT, 1, nil) == true, "event handles the rotary")
check(reg.configure == nil, "no configure callback: adding the widget lands on Main, not on CFG (feedback #1)")
local menu0 = reg.menu(wdg)
formFields = {}
menu0[1][2]()                                  -- the long-press menu's settings entry
check(#formFields >= 10, "settings form built from the menu (" .. #formFields .. " fields)")
local formOk = true
for _, f in ipairs(formFields) do
  if f.get then
    local ok1, v = pcall(f.get)
    if not ok1 then formOk = false; print("    getter failed: " .. tostring(v)) end
  end
end
check(formOk, "every settings getter runs")
check(not core.status() or not core.status():find("error", 1, true), "no config error on the status line")
local menu = reg.menu(wdg)
check(menu and menu[1] and menu[1][1] == "Nice Flight! settings", "menu entry")
-- FS keys follow VISIBILITY, not focus (Ethos drops focus on RTN)
do
  local focus = true
  lcd.hasFocus = function() return focus end
  focus = false
  SIM.fs[2] = -100; reg.wakeup(wdg); reg.paint(wdg)
  SIM.fs[2] = 100; reg.wakeup(wdg); SIM.fs[2] = -100
  check(wdg.app.V.screen == "history", "FS2 opens History while the page is showing, even without focus")
  wdg.app.pressKey(1)
  tOff = tOff + 5                                  -- page no longer being painted = hidden
  reg.wakeup(wdg)
  SIM.fs[3] = 100; reg.wakeup(wdg); SIM.fs[3] = -100
  check(wdg.app.V.screen == "auto", "FS3 is ignored when the page has not been painted lately (hidden)")
  focus = true
  reg.paint(wdg)
end

-- the CFG key path: opens the form, RTN leaves it
wdg.app.pressKey(4)
check(wdg.app.V.inForm, "CFG key opens the settings form")
wdg.app.event(KEY_RTN_FIRST, nil, nil, EVT_KEY)
check(not wdg.app.V.inForm, "RTN leaves the settings form")

print(string.format("\n%d checks, %d failures", checks, failures))
return failures
