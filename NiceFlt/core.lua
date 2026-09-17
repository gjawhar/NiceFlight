-- Nice Flight! core: storage, telemetry sources, the flight state machine,
-- altitude sampling, climbs, and the badge engine. The only module that
-- touches files or decides what a flight, a climb or a badge is. Spec:
-- mockup/nice_flight_mockup.html + mockup/badges_screen.html.
--
-- Ethos-Lua rules inherited from Throw Trainer (see its CLAUDE.md): read
-- files with f:read(N) only; logic switches read +-100; source:age() is -1
-- when nothing was ever received; os.time() is whole seconds and os.clock()
-- is CPU time (useless); pcall every Ethos call that can be missing.

local core = {}
core.VERSION = "0.1.8"

local FT_PER_M = 3.28084

-- DLG template flight modes (CATEGORY_FLIGHT member 0).
local FM_LAUNCH, FM_ZOOM, FM_LANDING = 2, 3, 4

local LAUNCH_FREEZE_SEC   = 3     -- launch height frozen this long after leaving Launch/Zoom
local LAUNCH_FREEZE_MAX   = 10    -- ...or this long after release, whichever first
local RESET_GRACE_SEC     = 10    -- SF11 sensor reset: age() reads -1 for a few s after launch
local BRAKE_HOLD_SEC      = 2     -- os.time() is whole seconds: 2 guarantees >= 1 s real
local GROUND_FT           = 20    -- "on the ground" for unbraked / idle flight ends
local GROUND_HOLD_SEC     = 20
local LOST_LOW_SEC        = 30    -- link gone this long with the plane last seen low: it landed
local LOST_ANY_SEC        = 180   -- link gone this long at any height: stop the clock where it was last seen
local MIN_THROW_FT        = 25    -- a "flight" that never got this high is a fumble, not a throw
local MAX_SAMPLES         = 3600
local FLIGHT_CAP          = 5000
local HISTORY_CAP         = 200
local DIAG_CAP            = 300
local STATUS_SEC          = 4
local ALERT_DELAY_SEC     = 2

-- Ladders per unit system, in DISPLAY units. Separate round ladders, not
-- converted feet (pilot's decision). k = feet per display unit.
local LADDERS = {
  ft = { k = 1, unit = "ft",
    peakFirsts = { 400, 600, 800, 1000, 1250, 1500, 2000 }, peakRepeat = 1000, peakBand = 100,
    durFirsts  = { 5, 10, 15, 20, 30, 45, 60 }, durRepeat = 15,
    yoyoFloor = 100, yoyoBand = 100, yoyoRepeat = 300,
    rebMin = 300, rebBand = 100, rebRepeat = 500,
    saveFloor = 60, saveTarget = 300, saveStep = 10, saveLowest = 20,
    recHFloor = 400, recTFloor = 600,
    niceHeight = 300, climb = 50, landAlt = 50 },
  m = { k = FT_PER_M, unit = "m",
    peakFirsts = { 120, 180, 250, 300, 400, 450, 600 }, peakRepeat = 300, peakBand = 50,
    durFirsts  = { 5, 10, 15, 20, 30, 45, 60 }, durRepeat = 15,
    yoyoFloor = 30, yoyoBand = 25, yoyoRepeat = 100,
    rebMin = 100, rebBand = 25, rebRepeat = 150,
    saveFloor = 20, saveTarget = 100, saveStep = 5, saveLowest = 5,
    recHFloor = 120, recTFloor = 600,
    niceHeight = 100, climb = 15, landAlt = 15 },
}

local S = {
  ready = false, dir = nil, ioError = nil,
  status = nil, statusAt = 0,
  cfg = nil, model = "model",
  altSrc = nil, fmSrc = nil, rxBattSrc = nil, rxLowSrc = nil,
  fs = {}, prevFS = {},
  sensorUnit = "ft",
  prevFM = nil, armed = false, bootAt = 0,
  F = nil,            -- flight in progress
  last = nil,         -- last completed throw (nice or not)
  recap = nil,        -- nice flight waiting on the recap screen
  alertAt = nil,
  today = nil,
  history = {},       -- nice flights, newest first
  B = nil,            -- badge state for the active unit system
  diagCount = nil, diagLost = 0,
  sourcesAt = 0,
}
core.S = S

-- ---------------------------------------------------------------- small helpers

local function L() return LADDERS[(S.cfg and S.cfg.units) or "ft"] or LADDERS.ft end
core.ladders = L

function core.unit() return L().unit end
-- feet -> display units (number, not rounded)
function core.disp(ft) if ft == nil then return nil end return ft / L().k end
function core.round(v) if v == nil then return nil end return math.floor(v + 0.5) end
function core.fmtAlt(ft)
  if ft == nil then return "--" end
  return tostring(core.round(core.disp(ft)))
end
function core.fmtTime(sec)
  if sec == nil then return "--:--" end
  if sec < 0 then sec = 0 end
  return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end
function core.fmtDate(ts)
  local ok, d = pcall(os.date, "*t", ts)
  if ok and type(d) == "table" then
    return string.format("%d/%d/%02d", d.month, d.day, d.year % 100)
  end
  return "?"
end
local function dayKey(ts)
  local ok, d = pcall(os.date, "%Y%m%d", ts)
  if ok and type(d) == "string" then return d end
  return tostring(math.floor((ts or 0) / 86400))
end

-- Flight clock. On a radio it is os.time(). In the SIMULATOR a test time
-- scale (CFG > Data) multiplies it so a macro can replay a 16 minute flight
-- in two and still be measured as 16 minutes. os.time() is whole seconds,
-- so at x8 the flight clock moves 8 s at a time; everything timed below is
-- written to cope with a step bigger than one. Never honoured on hardware.
-- True only when the firmware itself reports a simulator (getVersion()
-- .simulation == true, as measured in FrSky Suite 26.1.2). Anything else,
-- including a firmware with no such field, is treated as a real radio.
function core.isSimulator()
  local ok, v = pcall(system.getVersion)
  return ok and type(v) == "table" and v.simulation == true
end

local function timeScale()
  local n = S.cfg and S.cfg.timeScale or 1
  if n <= 1 then return 1 end
  if not core.isSimulator() then return 1 end
  return n
end
core.timeScale = timeScale
local function clock() return os.time() * timeScale() end

function core.setStatus(text) S.status = text; S.statusAt = os.time() end
function core.status()
  if S.ioError then return "storage: " .. S.ioError end
  if S.status and os.time() - S.statusAt <= STATUS_SEC then return S.status end
  return nil
end

-- ---------------------------------------------------------------- files

local function tryDir(dir)
  local p = dir .. "probe.tmp"
  local f = io.open(p, "w")
  if not f then return false end
  f:write("x"); f:close()
  if os.remove then pcall(os.remove, p) end
  return true
end

local function resolveDir()
  local candidates = { "Files/", "/scripts/NiceFlt/Files/", "SCRIPTS:/NiceFlt/Files/" }
  for i = 1, #candidates do
    local ok, works = pcall(tryDir, candidates[i])
    if ok and works then return candidates[i] end
  end
  return nil
end

local function path(base) if not S.dir then return nil end return S.dir .. base .. ".csv" end

local function splitLine(line)
  local out = {}
  for field in string.gmatch(line .. ",", "([^,]*),") do out[#out + 1] = field end
  return out
end

local function readAll(f)
  local chunks = {}
  while true do
    local chunk = f:read(2048)
    if not chunk or chunk == "" then break end
    chunks[#chunks + 1] = chunk
    if #chunk < 2048 then break end
  end
  return table.concat(chunks)
end

local function readRows(base)
  local p = path(base)
  if not p then return {} end
  local f = io.open(p, "r")
  if not f then return {} end
  local ok, content = pcall(readAll, f)
  pcall(function() f:close() end)
  if not ok then core.setStatus("read error (" .. base .. ")") return {} end
  local rows = {}
  for line in (content or ""):gmatch("[^\r\n]+") do
    if line ~= "" and string.sub(line, 1, 1) ~= "#" then rows[#rows + 1] = splitLine(line) end
  end
  return rows
end
core.readRows = readRows

local NO_DIR_ERROR = "no writable Files/ folder"
local function clearWriteError()
  if S.ioError and S.ioError ~= NO_DIR_ERROR then S.ioError = nil end
end

local function appendRow(base, fields)
  local p = path(base)
  if not p then return false end
  local f = io.open(p, "a")
  if not f then S.ioError = "append " .. base return false end
  f:write(table.concat(fields, ",") .. "\n")
  f:close()
  clearWriteError()
  return true
end

local function rewrite(base, rows)
  local p = path(base)
  if not p then return false end
  local f = io.open(p, "w")
  if not f then S.ioError = "rewrite " .. base return false end
  for i = 1, #rows do f:write(table.concat(rows[i], ",") .. "\n") end
  f:close()
  clearWriteError()
  return true
end

-- Files/diag.csv: ts,model,code,detail. Event-driven only, never per wakeup.
-- Detail must not contain commas.
local function diag(code, detail)
  if not S.dir then return false end
  detail = tostring(detail or ""):gsub(",", ";")
  if S.diagLost > 0 then detail = detail .. " lost=" .. S.diagLost end
  local ok = appendRow("diag", { tostring(os.time()), S.model or "?", code, detail })
  if ok then
    S.diagLost = 0
    S.diagCount = (S.diagCount or 0) + 1
    if S.diagCount > DIAG_CAP + 50 then
      local rows = readRows("diag")
      local kept = {}
      for i = math.max(1, #rows - DIAG_CAP + 1), #rows do kept[#kept + 1] = rows[i] end
      if rewrite("diag", kept) then S.diagCount = #kept end
    end
  else
    S.diagLost = S.diagLost + 1
  end
  return ok
end
core.diag = diag

-- ---------------------------------------------------------------- config

-- config.csv rows: scope,key,value. scope "*" = the pilot (badges and
-- thresholds are the pilot's, not the plane's); a model name scopes the one
-- per-plane setting, the RX voltage sensor (persisted BY NAME).
local function defaults(units)
  local l = LADDERS[units] or LADDERS.ft
  return { units = units or "ft", niceHeight = l.niceHeight, niceTimeMin = 5,
           climb = l.climb, landAlt = l.landAlt, alerts = 1, stale = 3, theme = 2, timeScale = 1 }
end

local NUMERIC = { niceHeight = true, niceTimeMin = true, climb = true, landAlt = true,
                  alerts = true, stale = true, theme = true, timeScale = true }

local function loadConfig()
  local rows = readRows("config")
  local units = "ft"
  for _, r in ipairs(rows) do if r[1] == "*" and r[2] == "units" and r[3] == "m" then units = "m" end end
  local cfg = defaults(units)
  cfg.rxSensor = nil
  for _, r in ipairs(rows) do
    local scope, key, val = r[1], r[2], r[3]
    if scope == "*" and NUMERIC[key] then
      local n = tonumber(val)
      if n then cfg[key] = n end
    elseif scope == S.model and key == "rxSensor" and val and val ~= "" then
      cfg.rxSensor = val
    end
  end
  S.cfg = cfg
end

function core.saveConfig()
  local rows = readRows("config")
  local kept = {}
  for _, r in ipairs(rows) do
    local mine = (r[1] == "*") or (r[1] == S.model and r[2] == "rxSensor")
    if not mine then kept[#kept + 1] = r end
  end
  local c = S.cfg
  kept[#kept + 1] = { "*", "units", c.units }
  for key in pairs(NUMERIC) do kept[#kept + 1] = { "*", key, tostring(c[key]) } end
  if c.rxSensor then kept[#kept + 1] = { S.model, "rxSensor", c.rxSensor } end
  rewrite("config", kept)
end

-- ---------------------------------------------------------------- sources

local function srcValue(src, opts)
  if not src then return nil end
  local ok, v
  if opts then ok, v = pcall(function() return src:value(opts) end)
  else ok, v = pcall(function() return src:value() end) end
  if ok then return v end
  return nil
end

local function srcAge(src)
  if not src then return -1 end
  local ok, v = pcall(function() return src:age() end)
  if ok and type(v) == "number" then return v end
  return -1
end

local function getSensor(name)
  local ok, src = pcall(system.getSource, { category = CATEGORY_TELEMETRY_SENSOR, name = name })
  if ok then return src end
  return nil
end
local function getLogic(name)
  local ok, src = pcall(system.getSource, { category = CATEGORY_LOGIC_SWITCH, name = name })
  if ok then return src end
  return nil
end
local function getByName(name)
  local src = getSensor(name)
  if src then return src end
  local ok, s2 = pcall(system.getSource, { name = name })
  if ok then return s2 end
  return nil
end

local FS_CATEGORY = rawget(_G, "CATEGORY_FUNCTION_SWITCH") or 12

function core.rxSensorName() return (S.cfg and S.cfg.rxSensor) or "RxBatt" end
function core.resolveRxSource() S.rxBattSrc = getByName(core.rxSensorName()) end
function core.setRxSensor(name)
  if name == "" then name = nil end
  S.cfg.rxSensor = name
  core.saveConfig()
  core.resolveRxSource()
end

local function resolveSources()
  if not S.altSrc then
    S.altSrc = getSensor("Altitude")
    if S.altSrc then
      local ok, u = pcall(function() return S.altSrc:stringUnit() end)
      if ok and type(u) == "string" and u:find("m", 1, true) and not u:find("ft", 1, true) then
        S.sensorUnit = "m"
      else
        S.sensorUnit = "ft"
      end
    end
  end
  if not S.fmSrc then
    local ok, src = pcall(system.getSource, { category = CATEGORY_FLIGHT, member = 0 })
    if ok then S.fmSrc = src end
  end
  if not S.rxBattSrc then core.resolveRxSource() end
  if not S.rxLowSrc then S.rxLowSrc = getLogic("RXBAT_LOW") end
  for i = 1, 4 do
    if not S.fs[i] then
      local ok, src = pcall(system.getSource, { category = FS_CATEGORY, member = i - 1 })
      if ok then S.fs[i] = src end
    end
  end
end

local function sourcesSummary()
  local function ok(s) return s and "ok" or "MISSING" end
  return string.format("alt=%s fm=%s rx=%s:%s unit=%s", ok(S.altSrc), ok(S.fmSrc),
    core.rxSensorName(), ok(S.rxBattSrc), S.sensorUnit)
end

function core.currentFlightMode()
  local v = srcValue(S.fmSrc)
  if type(v) == "number" then return math.floor(v + 0.5) end
  return nil
end

local function staleLimitMs()
  local s = S.cfg and S.cfg.stale or 3
  return s * 1000
end

-- Altitude in FEET, or nil when the feed is not trustworthy. Inside the
-- post-launch reset grace the sensor's age() reads -1 although packets
-- arrive (Throw Trainer field logs), so the value is accepted there.
local function altFt()
  local v = srcValue(S.altSrc)
  if type(v) ~= "number" then return nil end
  local age = srcAge(S.altSrc)
  local limit = staleLimitMs()
  local fresh = (limit <= 0) or (age >= 0 and age < limit)
  if not fresh then
    local F = S.F
    if not (F and age < 0 and clock() - F.t0 <= RESET_GRACE_SEC) then return nil end
  end
  if S.sensorUnit == "m" then v = v * FT_PER_M end
  return v
end

function core.telemetryState()
  if not S.altSrc then return "none" end
  local age = srcAge(S.altSrc)
  if age < 0 then return "none" end
  local limit = staleLimitMs()
  if limit > 0 and age >= limit then return "stale" end
  return "ok"
end

function core.rxBatt()
  local out = { value = nil, unit = "V", low = false }
  if not S.rxBattSrc then return out end
  local age = srcAge(S.rxBattSrc)
  local limit = staleLimitMs()
  local fresh = (limit <= 0) or (age >= 0 and age < limit)
  local v = srcValue(S.rxBattSrc)
  if fresh and type(v) == "number" then out.value = v end
  if S.rxLowSrc then
    local l = srcValue(S.rxLowSrc)
    out.low = type(l) == "number" and l > 0
  end
  return out
end

function core.pollFS()
  for i = 1, 4 do
    local v = srcValue(S.fs[i])
    if type(v) == "number" then
      local prev = S.prevFS[i]
      S.prevFS[i] = v
      if prev ~= nil and prev <= 0 and v > 0 then return i end
    end
  end
  return nil
end

-- ---------------------------------------------------------------- climbs (zigzag)

-- Reversal detector. seq = list of {t=, a=} in time order whose FIRST entry
-- is a high (the launch peak); returns the pivots (first entry included)
-- with the still-unconfirmed last extreme appended and flagged open=true.
local function zigzag(seq, thr)
  local piv = {}
  if #seq == 0 then return piv end
  piv[1] = { t = seq[1].t, a = seq[1].a, kind = "H" }
  local dir, extT, extA = -1, seq[1].t, seq[1].a
  for i = 2, #seq do
    local t, a = seq[i].t, seq[i].a
    if dir == -1 then
      if a < extA then extT, extA = t, a
      elseif a - extA >= thr then
        piv[#piv + 1] = { t = extT, a = extA, kind = "L" }
        dir, extT, extA = 1, t, a
      end
    else
      if a > extA then extT, extA = t, a
      elseif extA - a >= thr then
        piv[#piv + 1] = { t = extT, a = extA, kind = "H" }
        dir, extT, extA = -1, t, a
      end
    end
  end
  local last = piv[#piv]
  if extT ~= last.t or extA ~= last.a then
    piv[#piv + 1] = { t = extT, a = extA, kind = (dir == 1) and "H" or "L", open = true }
  end
  return piv
end
core.zigzag = zigzag

-- Up-legs of at least thr: every L -> H pair (an open H counts once its gain
-- has reached thr, which the detector already guarantees).
local function climbsOf(piv)
  local gains = {}
  for i = 2, #piv do
    if piv[i].kind == "H" and piv[i - 1].kind == "L" then
      gains[#gains + 1] = piv[i].a - piv[i - 1].a
    end
  end
  return gains
end

-- ---------------------------------------------------------------- badge state

-- badges.csv is append-only: sys,fam,kind,val,exact,ts,model,extra,seed.
-- kind: first | rep | rec. Tallies are row counts, so nothing is ever
-- rewritten except by purgeSeed.
local function newBadgeState()
  return { first = {}, tally = {}, best = {}, rec = { rech = {}, rect = {} }, hatDays = {} }
end

local function betterThan(fam, a, b)      -- is exact a better than exact b?
  if b == nil then return true end
  if fam == "save" then return a < b end
  return a > b
end

local function applyBadgeRow(B, r)
  local fam, kind = r[2], r[3]
  local val, exact, ts = tonumber(r[4]) or 0, tonumber(r[5]) or 0, tonumber(r[6]) or 0
  local model, extra = r[7] or "", r[8] or ""
  if kind == "first" then
    B.first[fam] = B.first[fam] or {}
    B.first[fam][val] = true
  elseif kind == "rep" then
    B.tally[fam] = (B.tally[fam] or 0) + 1
    if fam == "hat" then B.hatDays[#B.hatDays + 1] = { ts = ts, n = val } end
  elseif kind == "rec" then
    local list = B.rec[fam]
    if list then list[#list + 1] = { val = exact, ts = ts, model = model } end
  end
  if fam ~= "hat" and kind ~= "rec" then
    local b = B.best[fam]
    if betterThan(fam, exact, b and b.exact) then
      B.best[fam] = { exact = exact, ts = ts, model = model, extra = extra }
    end
  end
end

local function loadBadges()
  local B = newBadgeState()
  local sys = S.cfg.units
  for _, r in ipairs(readRows("badges")) do
    if r[1] == sys then applyBadgeRow(B, r) end
  end
  S.B = B
end

function core.recordHeight()          -- display units
  local list, best = S.B.rec.rech, L().recHFloor
  for i = 1, #list do if list[i].val > best then best = list[i].val end end
  return best
end
function core.recordTime()            -- seconds
  local list, best = S.B.rec.rect, L().recTFloor
  for i = 1, #list do if list[i].val > best then best = list[i].val end end
  return best
end

-- ---------------------------------------------------------------- badge evaluation

-- Everything a flight has achieved SO FAR, in display units. Works mid-flight
-- (open last pivot, elapsed so far) and at landing alike, so the mid-flight
-- alert and the recap can never disagree.
local function achievements(F, elapsed)
  local l = L()
  local k = l.k
  local a = { peak = F.maxAlt / k, durMin = math.floor(elapsed / 60), elapsed = elapsed }
  if not F.launchFrozen then return a end

  local seq = {}
  for i = 1, #F.piv do seq[i] = F.piv[i] end
  if F.ext then seq[#seq + 1] = F.ext end
  local piv = zigzag(seq, l.yoyoFloor * k)

  -- Yo-yo: three climbs ALL of at least N.
  local gains = climbsOf(piv)
  table.sort(gains, function(x, y) return x > y end)
  if #gains >= 3 then
    local third = gains[3] / k
    a.yoyo = math.floor(third / l.yoyoBand) * l.yoyoBand
    a.yoyoExact = core.round(third)
    a.yoyoExtra = string.format("%d/%d/%d", core.round(gains[1] / k), core.round(gains[2] / k), core.round(third))
  end

  -- Rebound: sank 75% below a high, then climbed back OVER it.
  for i = 1, #piv do
    if piv[i].kind == "H" and piv[i].a / k >= l.rebMin then
      local H, low = piv[i].a, piv[i].a
      for j = i + 1, #piv do
        if piv[j].a < low then low = piv[j].a end
        if piv[j].a > H and low <= 0.25 * H then
          local hv = H / k
          if not a.rebExact or hv > a.rebExact then
            a.rebExact = core.round(hv)
            a.reb = math.floor(hv / l.rebBand) * l.rebBand
            a.rebExtra = string.format("%d/%d/%d", core.round(hv), core.round(low / k), core.round(piv[j].a / k))
          end
          break
        end
      end
    end
  end

  -- Save: got under the floor after the launch, then back up to the target.
  for i = 2, #piv do
    if piv[i].kind == "L" and piv[i].a / k < l.saveFloor then
      for j = i + 1, #piv do
        if piv[j].a / k >= l.saveTarget then
          local lv = piv[i].a / k
          if lv < 0 then lv = 0 end
          if not a.saveExact or lv < a.saveExact then
            a.saveExact = core.round(lv)
            a.saveTop = core.round(piv[j].a / k)
          end
          break
        end
      end
    end
  end
  if a.saveExact then
    local rung = (math.floor(a.saveExact / l.saveStep) + 1) * l.saveStep
    if rung < l.saveLowest then rung = l.saveLowest end
    if rung > l.saveFloor then rung = l.saveFloor end
    a.saveRung = rung
  end
  return a
end

-- Badge items for the achievements, against the persistent state B. Each
-- item: { key, fam, kind, val, exact, extra }. key is stable for a first
-- ("peak.first.400") and per family for a repeatable/record ("peak.rep"),
-- whose val simply grows as the flight goes on.
local function badgeItems(a)
  local l, B, out = L(), S.B, {}
  local function add(fam, kind, val, exact, extra, key)
    out[#out + 1] = { key = key or (fam .. "." .. kind), fam = fam, kind = kind,
                      val = val, exact = exact or val, extra = extra or "" }
  end
  local function firsts(fam, rungs, value, exact, extra, descending)
    local have = B.first[fam] or {}
    for _, r in ipairs(rungs) do
      local hit
      if descending then hit = value <= r else hit = value >= r end
      if hit and not have[r] then add(fam, "first", r, exact, extra, fam .. ".first." .. r) end
    end
  end

  local peakExact = core.round(a.peak)
  firsts("peak", l.peakFirsts, a.peak, peakExact)
  if a.peak >= l.peakRepeat then
    add("peak", "rep", math.floor(a.peak / l.peakBand) * l.peakBand, peakExact)
  end

  firsts("dur", l.durFirsts, a.durMin, a.elapsed)
  if a.durMin >= l.durRepeat then add("dur", "rep", a.durMin, a.elapsed) end

  if a.yoyo and a.yoyo >= l.yoyoFloor then
    local rungs = {}
    for r = l.yoyoFloor, a.yoyo, l.yoyoBand do rungs[#rungs + 1] = r end
    firsts("yoyo", rungs, a.yoyo, a.yoyoExact, a.yoyoExtra)
    if a.yoyo >= l.yoyoRepeat then add("yoyo", "rep", a.yoyo, a.yoyoExact, a.yoyoExtra) end
  end

  if a.reb and a.reb >= l.rebMin then
    local rungs = {}
    for r = l.rebMin, a.reb, l.rebBand do rungs[#rungs + 1] = r end
    firsts("reb", rungs, a.reb, a.rebExact, a.rebExtra)
    if a.reb >= l.rebRepeat then add("reb", "rep", a.reb, a.rebExact, a.rebExtra) end
  end

  if a.saveRung then
    local rungs = {}
    for r = l.saveFloor, a.saveRung, -l.saveStep do rungs[#rungs + 1] = r end
    local extra = string.format("%d/%d", a.saveExact, a.saveTop or 0)
    firsts("save", rungs, a.saveRung, a.saveExact, extra, true)
    add("save", "rep", a.saveRung, a.saveExact, extra)
  end

  if a.peak > core.recordHeight() then add("rech", "rec", peakExact, peakExact) end
  if a.elapsed > core.recordTime() then add("rect", "rec", a.elapsed, a.elapsed) end
  return out
end

-- Text for a badge pill and for the caption line under the recap.
function core.badgeLabel(it, unit)
  unit = unit or core.unit()
  local f = it.fam
  if f == "peak" then return string.format("Peak %d %s", it.val, unit) end
  if f == "dur"  then return string.format("%d min", it.val) end
  if f == "yoyo" then return string.format("3x %d %s", it.val, unit) end
  if f == "reb"  then return string.format("Rebound %d %s", it.val, unit) end
  if f == "save" then return string.format("Save from %d %s", it.exact, unit) end
  if f == "hat"  then return it.val > 1 and ("Hat trick x" .. it.val) or "Hat trick" end
  if f == "rech" then return string.format("New record %d %s", it.exact, unit) end
  if f == "rect" then return "New record " .. core.fmtTime(it.exact) end
  return f
end

local function captionFor(it, unit)
  local f, first = it.fam, it.kind == "first"
  local function parts(s) local o = {} for p in tostring(s):gmatch("[^/]+") do o[#o + 1] = p end return o end
  if f == "peak" then
    if first then return string.format("Peak %d %s: first flight over %d %s", it.val, unit, it.val, unit) end
    return string.format("Peak %d %s: a flight over %d %s", it.val, unit, L().peakRepeat, unit)
  elseif f == "dur" then
    if first then return string.format("%d min: first flight of %d minutes or more", it.val, it.val) end
    return string.format("%d min: a flight over %d minutes", it.val, L().durRepeat)
  elseif f == "yoyo" then
    return string.format("Yo-yo: three climbs of %d %s or more", it.val, unit)
  elseif f == "reb" then
    local p = parts(it.extra)
    if #p == 3 then return string.format("Rebound: %s %s down to %s and back up to %s", p[1], unit, p[2], p[3]) end
    return string.format("Rebound: lost 75%% of %d %s and climbed back over it", it.val, unit)
  elseif f == "save" then
    local p = parts(it.extra)
    if #p == 2 then return string.format("Save: down to %s %s and back up to %s", p[1], unit, p[2]) end
    return "Save: got low and climbed back up"
  elseif f == "hat" then
    return string.format("Hat trick%s: %d nice flights today", it.val > 1 and (" x" .. it.val) or "", it.val * 5)
  elseif f == "rech" then return string.format("New record: %d %s, your highest flight", it.exact, unit)
  elseif f == "rect" then return "New record: " .. core.fmtTime(it.exact) .. ", your longest flight" end
  return ""
end

function core.badgeCaption(it, unit)
  unit = unit or core.unit()
  local text = captionFor(it, unit)
  if it.also and #it.also > 0 and it.fam ~= "save" then
    table.sort(it.also)
    local list = {}
    for i = 1, #it.also do list[i] = tostring(it.also[i]) end
    text = text .. " (also " .. table.concat(list, " ") .. ")"
  end
  return text
end

-- A first flight of 800 earns the 400, 600 and 800 firsts together, and a
-- save from 55 earns five rungs. They are all recorded, but the recap and
-- the live pill show ONE pill per family: the best first, with the others
-- named in its caption, plus the per-flight / record badge when its label
-- differs.
function core.displayBadges(items, unit)
  local out, firstOf = {}, {}
  for _, it in ipairs(items) do
    if it.kind == "first" then
      local cur = firstOf[it.fam]
      if not cur then
        cur = { fam = it.fam, kind = "first", val = it.val, exact = it.exact, extra = it.extra, also = {} }
        firstOf[it.fam] = cur
        out[#out + 1] = cur
      else
        local better
        if it.fam == "save" then better = it.val < cur.val else better = it.val > cur.val end
        if better then cur.also[#cur.also + 1] = cur.val; cur.val = it.val
        else cur.also[#cur.also + 1] = it.val end
      end
    end
  end
  for _, it in ipairs(items) do
    if it.kind ~= "first" then
      local f = firstOf[it.fam]
      if not (f and core.badgeLabel(f, unit) == core.badgeLabel(it, unit)) then out[#out + 1] = it end
    end
  end
  return out
end

-- ---------------------------------------------------------------- alerts

-- Both return ok, err so the caller can record what the firmware did: the
-- pilot reported the landing tone "might have been silent" in the simulator.
local function haptic(ms)
  if not system.playHaptic then return false, "no playHaptic" end
  return pcall(system.playHaptic, ms)
end
local function tone(freq, ms, pause)
  if not system.playTone then return false, "no playTone" end
  if pause and pause > 0 then return pcall(system.playTone, freq, ms, pause) end
  return pcall(system.playTone, freq, ms)
end
local function verdict(ok, err) return ok and "ok" or ("FAILED " .. tostring(err)) end
local function alertsOn() return S.cfg and S.cfg.alerts == 1 end

-- ---------------------------------------------------------------- today / history

local function today()
  local key = dayKey(os.time())
  if not S.today or S.today.key ~= key then
    S.today = { key = key, throws = 0, nice = 0, bestAlt = nil, bestDur = nil }
  end
  return S.today
end
core.today = today

local function parseBadges(str)
  local out = {}
  for token in tostring(str or ""):gmatch("[^;]+") do
    local p = {}
    for x in token:gmatch("[^%.]+") do p[#p + 1] = x end
    if #p >= 3 then
      out[#out + 1] = { fam = p[1], kind = p[2], val = tonumber(p[3]) or 0,
                        exact = tonumber(p[4]) or tonumber(p[3]) or 0, extra = p[5] or "" }
    end
  end
  return out
end
core.parseBadges = parseBadges

local function encodeBadges(items)
  local out = {}
  for _, it in ipairs(items) do
    out[#out + 1] = string.format("%s.%s.%d.%d.%s", it.fam, it.kind, it.val, it.exact, it.extra or "")
  end
  return table.concat(out, ";")
end

function core.parsePoints(str)
  local out = {}
  for token in tostring(str or ""):gmatch("[^|]+") do
    local t, a = token:match("^(%-?%d+):(%-?%d+)$")
    if t then out[#out + 1] = { t = tonumber(t), a = tonumber(a) } end
  end
  return out
end

-- flights.csv: ts,model,sys,launch_ft,max_ft,dur_s,above_s,climbs,best_ft,
--              nice,points,badges,seed
local function flightFromRow(r)
  return { ts = tonumber(r[1]) or 0, model = r[2] or "", sys = r[3] or "ft",
           launch = tonumber(r[4]) or 0, max = tonumber(r[5]) or 0, dur = tonumber(r[6]) or 0,
           above = tonumber(r[7]) or 0, climbs = tonumber(r[8]) or 0, best = tonumber(r[9]) or 0,
           nice = r[10] == "1", points = r[11] or "", badges = r[12] or "", seed = r[13] == "1" }
end

local function loadFlights()
  local rows = readRows("flights")
  if #rows > FLIGHT_CAP + 500 then
    local kept = {}
    for i = #rows - FLIGHT_CAP + 1, #rows do kept[#kept + 1] = rows[i] end
    if rewrite("flights", kept) then rows = kept end
  end
  S.history, S.today, S.last = {}, nil, nil
  local t = today()
  for i = 1, #rows do
    local f = flightFromRow(rows[i])
    if dayKey(f.ts) == t.key and not f.seed then
      t.throws = t.throws + 1
      if f.nice then
        t.nice = t.nice + 1
        if not t.bestAlt or f.max > t.bestAlt then t.bestAlt = f.max end
        if not t.bestDur or f.dur > t.bestDur then t.bestDur = f.dur end
      end
    end
  end
  -- newest first by TIME, not file order (sample rows are appended after
  -- real ones but dated earlier)
  local nice, latest = {}, nil
  for i = 1, #rows do
    local f = flightFromRow(rows[i])
    if f.nice then nice[#nice + 1] = f end
    if not f.seed and (not latest or f.ts >= latest.ts) then latest = f end
  end
  table.sort(nice, function(a, b) return a.ts > b.ts end)
  for i = 1, math.min(#nice, HISTORY_CAP) do S.history[i] = nice[i] end
  S.last = latest
end

function core.history() return S.history end

-- Sample data is flagged seed=1 and disappears the moment a real flight lands.
local function purgeSeed()
  local any = false
  for _, base in ipairs({ "flights", "badges" }) do
    local rows, kept, col = readRows(base), {}, (base == "flights") and 13 or 9
    for _, r in ipairs(rows) do
      if r[col] == "1" then any = true else kept[#kept + 1] = r end
    end
    if #kept ~= #rows then rewrite(base, kept) end
  end
  if any then loadBadges(); loadFlights() end
  return any
end

-- ---------------------------------------------------------------- flight lifecycle

local function startFlight(now)
  S.recap, S.alertAt = nil, nil
  S.F = { t0 = now, lastSec = now, n = 0, samples = {},
          maxAlt = 0, launchPeak = 0, launchPeakT = 0, launchFrozen = false, lzExitAt = nil,
          piv = {}, ext = nil, above = 0, lastHighT = now, lowSince = nil, brakeSince = nil,
          earned = {}, pill = nil, alt = nil }
  diag("launch", "release")
end

-- The graph: start, the launch peak, landing, and up to six reversals of at
-- least the climb size. The smallest reversals go first, and the launch
-- peak (piv[1]) is never one of them.
local function graphPoints(piv, dur, maxAlt)
  local mid = {}
  for i = 1, #piv do mid[#mid + 1] = { t = piv[i].t, a = piv[i].a } end
  -- Pivots come from once-a-second samples, the max from every wakeup: make
  -- the graph's top agree with the MAX field (seen in the sim: 373 vs 379).
  if maxAlt then
    local hi = 1
    for i = 2, #mid do if mid[i].a > mid[hi].a then hi = i end end
    if mid[hi] and maxAlt > mid[hi].a then mid[hi].a = maxAlt end
  end
  while #mid > 7 do
    -- a reversal is a high/low PAIR; dropping the pair with the smallest
    -- swing keeps the alternation intact. Pairs start at index 2.
    local worst, wi = nil, nil
    for i = 3, #mid do
      local swing = math.abs(mid[i].a - mid[i - 1].a)
      if not worst or swing < worst then worst, wi = swing, i end
    end
    if not wi then break end
    table.remove(mid, wi); table.remove(mid, wi - 1)
  end
  local out = { "0:0" }
  for i = 1, #mid do
    local token = string.format("%d:%d", math.max(0, mid[i].t), core.round(mid[i].a))
    if out[#out] ~= token then out[#out + 1] = token end
  end
  out[#out + 1] = string.format("%d:0", dur)
  return table.concat(out, "|")
end

local function closeFlight(reason, endT)
  local F = S.F
  S.F = nil
  if not F then return end
  local dur = (endT or clock()) - F.t0
  if dur < 0 then dur = 0 end
  if F.maxAlt < MIN_THROW_FT then
    diag("fumble", string.format("max=%d dur=%d via=%s", core.round(F.maxAlt), dur, reason))
    return
  end
  if not F.launchFrozen then F.launchFrozen = true; F.piv = { { t = F.launchPeakT, a = F.launchPeak } } end

  local l = L()
  local seq = {}
  for i = 1, #F.piv do seq[i] = F.piv[i] end
  if F.ext then seq[#seq + 1] = F.ext end
  local piv = zigzag(seq, (S.cfg.climb or l.climb) * l.k)
  -- a flight always ends going down: an open trailing LOW is the landing
  -- itself, not a reversal worth plotting
  if #piv > 1 and piv[#piv].open and piv[#piv].kind == "L" then table.remove(piv) end
  local gains = climbsOf(piv)
  local best = 0
  for _, g in ipairs(gains) do if g > best then best = g end end

  local a = achievements(F, dur)
  local items = badgeItems(a)

  local t = today()
  t.throws = t.throws + 1
  local nice = (F.maxAlt / l.k >= S.cfg.niceHeight) or (dur >= S.cfg.niceTimeMin * 60) or (#items > 0)
  if nice then
    t.nice = t.nice + 1
    if not t.bestAlt or F.maxAlt > t.bestAlt then t.bestAlt = F.maxAlt end
    if not t.bestDur or dur > t.bestDur then t.bestDur = dur end
    if t.nice % 5 == 0 then
      items[#items + 1] = { key = "hat.rep", fam = "hat", kind = "rep", val = t.nice / 5,
                            exact = t.nice / 5, extra = "" }
    end
  end

  local now = os.time()
  local flight = { ts = now, model = S.model, sys = S.cfg.units, launch = F.launchPeak, max = F.maxAlt,
                   dur = dur, above = F.above, climbs = #gains, best = best, nice = nice,
                   points = graphPoints(piv, dur, F.maxAlt), badges = encodeBadges(items), seed = false }
  appendRow("flights", { tostring(now), S.model, flight.sys, tostring(core.round(flight.launch)),
    tostring(core.round(flight.max)), tostring(dur), tostring(flight.above), tostring(flight.climbs),
    tostring(core.round(best)), nice and "1" or "0", flight.points, flight.badges, "" })
  for _, it in ipairs(items) do
    local row = { S.cfg.units, it.fam, it.kind, tostring(it.val), tostring(it.exact), tostring(now),
                  S.model, it.extra or "", "" }
    appendRow("badges", row)
    applyBadgeRow(S.B, row)
  end
  diag("flight", string.format("max=%d launch=%d dur=%d climbs=%d nice=%s badges=%d via=%s",
    core.round(F.maxAlt), core.round(F.launchPeak), dur, #gains, tostring(nice), #items, reason))

  S.last = flight
  if nice then
    table.insert(S.history, 1, flight)
    if #S.history > HISTORY_CAP then table.remove(S.history) end
    S.recap = flight
    S.alertAt = os.time() + ALERT_DELAY_SEC        -- the alert waits in REAL seconds
  end
end

function core.dismissRecap() S.recap = nil; S.alertAt = nil end

-- zigzag() assumes its first entry is a HIGH. When the online tracker
-- restarts from the last confirmed pivot that may be a LOW; mirror the
-- altitudes so one detector serves both directions.
local function trackReversals(F, t, alt)
  local l = L()
  local thr = math.min(S.cfg.climb or l.climb, l.yoyoFloor) * l.k
  local lastP = F.piv[#F.piv]
  local sign = (lastP.kind == "L") and -1 or 1
  local seq = { { t = lastP.t, a = lastP.a * sign } }
  if F.ext then seq[2] = { t = F.ext.t, a = F.ext.a * sign } end
  seq[#seq + 1] = { t = t, a = alt * sign }
  local z = zigzag(seq, thr)
  local last = z[#z]
  local confirmed = last.open and (#z - 1) or #z
  for i = 2, confirmed do
    local kind = z[i].kind
    if sign == -1 then kind = (kind == "H") and "L" or "H" end
    F.piv[#F.piv + 1] = { t = z[i].t, a = z[i].a * sign, kind = kind }
  end
  if last.open then F.ext = { t = last.t, a = last.a * sign } else F.ext = nil end
end

-- Once a second while airborne: store the sample, track reversals, count
-- time above launch height, and raise any badge earned in the air.
local function sampleFlight(F, now, alt, fm, dt)
  local t = now - F.t0
  if alt then
    if F.n < MAX_SAMPLES then F.n = F.n + 1; F.samples[F.n] = core.round(alt) end
    if F.launchFrozen then
      trackReversals(F, t, alt)
      if alt > F.launchPeak then F.above = F.above + dt end
    end
    if alt > GROUND_FT then F.lastHighT = now; F.lowSince = nil
    elseif F.launchFrozen then F.lowSince = F.lowSince or now end
  end
  local items = badgeItems(achievements(F, t))
  local RANK = { first = 1, rep = 2, rec = 3 }
  local newest
  for _, it in ipairs(items) do
    local had = F.earned[it.key]
    F.earned[it.key] = it
    if not had then
      diag("badge", it.key .. " " .. tostring(it.val))
      if not newest or RANK[it.kind] >= RANK[newest.kind] then newest = it end
    elseif F.pill and F.pill.key == it.key then
      F.pill = it                                -- silent value update (Peak 1000 -> 1100)
    end
  end
  if newest and alertsOn() then
    -- one buzz and one SHORT beep however many rungs fell this second (the
    -- pilot asked for the beep, 2026-09-17; short so it cannot mask the vario)
    local hOk, hErr = haptic(250)
    local tOk, tErr = tone(1500, 90)
    F.pill = newest
    if not F.alertLogged then
      F.alertLogged = true
      diag("alert", "badge tone=" .. verdict(tOk, tErr) .. " haptic=" .. verdict(hOk, hErr))
    end
  end
end

local function pollFlight(now)
  local fm = core.currentFlightMode()
  local prev = S.prevFM
  if fm ~= nil then S.prevFM = fm end

  if fm ~= nil and prev ~= nil then
    if fm == FM_LAUNCH and prev ~= FM_LAUNCH then
      -- launch button pressed: an unbraked flight still open ends where it
      -- last was above the ground
      if S.F then closeFlight("relaunch", S.F.lastHighT) end
      S.armed = true
    elseif S.armed and prev == FM_LAUNCH and fm ~= FM_LAUNCH then
      S.armed = false
      startFlight(now)
    end
  end

  local F = S.F
  if not F then return end
  local alt = altFt()
  F.alt = alt
  if alt and alt > F.maxAlt then F.maxAlt = alt end
  -- sample data goes the moment a flight is genuinely a throw, so the
  -- mid-flight alerts and the recap judge it against real badges only
  if not F.genuine and F.maxAlt >= MIN_THROW_FT then F.genuine = true; purgeSeed() end

  if not F.launchFrozen then
    if alt and alt > F.launchPeak then F.launchPeak, F.launchPeakT = alt, now - F.t0 end
    local inLZ = (fm == FM_LAUNCH or fm == FM_ZOOM)
    if not inLZ and not F.lzExitAt then F.lzExitAt = now end
    if inLZ then F.lzExitAt = nil end
    if (F.lzExitAt and now - F.lzExitAt >= LAUNCH_FREEZE_SEC) or (now - F.t0 >= LAUNCH_FREEZE_MAX) then
      F.launchFrozen = true
      F.piv = { { t = F.launchPeakT, a = F.launchPeak, kind = "H" } }
      F.ext = nil
    end
  end

  if now ~= F.lastSec then
    local dt = now - F.lastSec
    F.lastSec = now
    sampleFlight(F, now, alt, fm, dt)
  end

  -- landing: brakes held, and low (or blind). A brake in the air is ignored.
  if fm == FM_LANDING then
    F.brakeSince = F.brakeSince or now
    local low = (alt == nil) or (alt / L().k < (S.cfg.landAlt or L().landAlt))
    if low and now - F.brakeSince >= BRAKE_HOLD_SEC and now - F.t0 >= 3 then
      closeFlight("brake", now)
      return
    end
  else
    F.brakeSince = nil
  end

  -- never braked and never relaunched: sitting on the ground ends it
  if F.lowSince and now - F.lowSince >= GROUND_HOLD_SEC then
    closeFlight("ground", F.lastHighT)
    return
  end

  -- Hand catch, then the plane is unplugged: no brake, no ground samples, and
  -- no more telemetry ever. Without this the flight ran until the radio was
  -- switched off, and was then dropped -- a nice flight lost. Seen for real
  -- in the simulator on 2026-09-17 (a flight collecting Duration badges with
  -- a dead link). Last seen low = it landed then; last seen high = give the
  -- link three minutes to come back, then stop the clock where it was seen.
  if alt then
    F.lostSince, F.lastAlt, F.lastAltT = nil, alt, now
  elseif F.launchFrozen then
    F.lostSince = F.lostSince or now
    local lost = now - F.lostSince
    local lastLow = (F.lastAlt or 0) / L().k < (S.cfg.landAlt or L().landAlt)
    if lastLow and lost >= LOST_LOW_SEC then
      closeFlight("lost-low", F.lastHighT)
    elseif lost >= LOST_ANY_SEC then
      closeFlight("lost", F.lastAltT or F.lastHighT)
    end
  end
end

-- ---------------------------------------------------------------- views

function core.state()
  if S.F then return "live" end
  if S.recap then return "recap" end
  return "idle"
end

function core.live()
  local F = S.F
  if not F then return nil end
  local l = L()
  local climbs = 0
  if F.launchFrozen then
    local seq = {}
    for i = 1, #F.piv do seq[i] = F.piv[i] end
    if F.ext then seq[#seq + 1] = F.ext end
    climbs = #climbsOf(zigzag(seq, (S.cfg.climb or l.climb) * l.k))
  end
  return { elapsed = clock() - F.t0, max = F.maxAlt, now = F.alt,
           launch = F.launchFrozen and F.launchPeak or nil, above = F.above,
           climbs = climbs, pill = F.pill, telem = core.telemetryState() }
end

-- One entry per badge family for the Badges screen.
local FAMILIES = { "peak", "dur", "yoyo", "reb", "save", "hat", "rech", "rect" }
core.FAMILIES = FAMILIES

function core.familyView(fam)
  local l, B, u = L(), S.B, core.unit()
  local v = { fam = fam, chips = {}, earned = false }
  local function highestFirst(rungs, descending)
    local have, best = B.first[fam] or {}, nil
    for _, r in ipairs(rungs) do
      if have[r] and (best == nil or (descending and r < best) or (not descending and r > best)) then best = r end
    end
    return best
  end
  -- fixed ladder: every rung; rolling ladder: earned rungs + the next three
  local function chipsFixed(rungs, fmt)
    local have = B.first[fam] or {}
    for _, r in ipairs(rungs) do v.chips[#v.chips + 1] = { text = string.format(fmt, r), earned = have[r] == true } end
  end
  local function chipsRolling(from, step, fmt, descending, stop)
    local have, shown, pending, r = B.first[fam] or {}, 0, 0, from
    local all = {}
    while pending < 3 and shown < 40 do
      if descending and r < stop then break end
      local e = have[r] == true
      all[#all + 1] = { text = string.format(fmt, r), earned = e }
      if not e then pending = pending + 1 end
      shown = shown + 1
      r = r + (descending and -step or step)
    end
    local start = math.max(1, #all - 7)
    for i = start, #all do v.chips[#v.chips + 1] = all[i] end
  end
  local best = B.best[fam]
  local function bestLine(text)
    if best then v.status = string.format("Best %s - %s - %s", text, core.fmtDate(best.ts), best.model) end
  end

  if fam == "peak" then
    v.title = "Peak"
    local h = highestFirst(l.peakFirsts)
    v.big = h and string.format("%d %s", h, u) or "--"
    v.small = string.format("%d%s+ peaks x%d", l.peakRepeat, u, B.tally.peak or 0)
    v.def = string.format("Peak: the highest altitude in a flight. Every flight over %d %s earns one, numbered to the %d below its max.", l.peakRepeat, u, l.peakBand)
    chipsFixed(l.peakFirsts, "%d " .. u)
    v.tally = string.format("%d %s+ x%d", l.peakRepeat, u, B.tally.peak or 0)
    if best then bestLine(string.format("%d %s", best.exact, u)) end
    v.earned = h ~= nil
  elseif fam == "dur" then
    v.title = "Duration"
    local h = highestFirst(l.durFirsts)
    v.big = h and string.format("%d min", h) or "--"
    v.small = string.format("%dmin+ flights x%d", l.durRepeat, B.tally.dur or 0)
    v.def = string.format("Duration: minutes airborne. Every flight of %d min or more earns one, numbered in whole minutes.", l.durRepeat)
    chipsFixed(l.durFirsts, "%d min")
    v.tally = string.format("%d min+ x%d", l.durRepeat, B.tally.dur or 0)
    if best then bestLine(core.fmtTime(best.exact)) end
    v.earned = h ~= nil
  elseif fam == "yoyo" then
    v.title = "Yo-yo"
    local have, h = B.first.yoyo or {}, nil
    for r in pairs(have) do if not h or r > h then h = r end end
    v.big = h and string.format("3x %d %s", h, u) or "--"
    v.bigSuffix = h and "climbs" or nil
    v.small = string.format("%d%s+ yo-yos x%d", l.yoyoRepeat, u, B.tally.yoyo or 0)
    v.def = string.format("Yo-yo: three separate climbs of N %s or more in one flight. Sinking to %d then climbing to %d is one %d climb. Every flight with a %d %s yo-yo or better earns one.", u, l.yoyoRepeat / 2, l.yoyoRepeat / 2 + l.yoyoRepeat, l.yoyoRepeat, l.yoyoRepeat, u)
    chipsRolling(l.yoyoFloor, l.yoyoBand, "%d " .. u)
    v.tally = string.format("%d %s+ x%d", l.yoyoRepeat, u, B.tally.yoyo or 0)
    if best then bestLine(string.format("%d %s (climbs %s)", best.exact, u, (best.extra or ""):gsub("/", " - "))) end
    v.earned = h ~= nil
  elseif fam == "reb" then
    v.title = "Rebound"
    local have, h = B.first.reb or {}, nil
    for r in pairs(have) do if not h or r > h then h = r end end
    v.big = h and string.format("%d %s", h, u) or "--"
    v.bigSuffix = h and string.format("from %d", core.round(h / 4)) or nil
    v.small = string.format("%d%s+ rebounds x%d", l.rebRepeat, u, B.tally.reb or 0)
    v.def = string.format("Rebound: lose three quarters of your height, then climb back over where you were. %d %s and up. Every rebound of %d %s or more earns one.", l.rebMin, u, l.rebRepeat, u)
    chipsRolling(l.rebMin, l.rebBand, "%d " .. u)
    v.tally = string.format("%d %s+ x%d", l.rebRepeat, u, B.tally.reb or 0)
    if best then bestLine((best.extra or ""):gsub("/", " > ") .. " " .. u) end
    v.earned = h ~= nil
  elseif fam == "save" then
    v.title = string.format("Save from <%d %s", l.saveFloor, u)
    local have, h = B.first.save or {}, nil
    for r in pairs(have) do if not h or r < h then h = r end end
    v.big = h and string.format("%d %s", h, u) or "--"
    v.bigSuffix = h and string.format("to %d", l.saveTarget) or nil
    v.small = string.format("saves x%d", B.tally.save or 0)
    v.def = string.format("Save: get under %d %s, then climb back to %d. Badges count in %d %s steps, lower is better. Every save earns one.", l.saveFloor, u, l.saveTarget, l.saveStep, u)
    chipsRolling(l.saveFloor, l.saveStep, "<%d " .. u, true, l.saveLowest)
    v.tally = string.format("saves x%d", B.tally.save or 0)
    if best then bestLine((best.extra or ""):gsub("/", " > ") .. " " .. u) end
    v.earned = h ~= nil
  elseif fam == "hat" then
    v.title = "Hat trick"
    local n = B.tally.hat or 0
    v.big = n > 0 and string.format("%d hat trick%s", n, n == 1 and "" or "s") or "--"
    v.small = "5 nice flights/day"
    v.def = string.format("Hat trick: five nice flights in one day. A flight is nice when it beats %d %s or %d:00 (CFG). Ten in a day is two hat tricks.", S.cfg.niceHeight, u, S.cfg.niceTimeMin)
    v.chipLabel = "EARNED"
    local days, order = {}, {}
    for i = #B.hatDays, 1, -1 do
      local d = core.fmtDate(B.hatDays[i].ts)
      if not days[d] then days[d] = 0; order[#order + 1] = d end
      days[d] = days[d] + 1
    end
    for i = 1, math.min(#order, 5) do
      local d = order[i]
      v.chips[#v.chips + 1] = { text = days[d] > 1 and (d .. " x" .. days[d]) or d, earned = true }
    end
    v.tally = "hat tricks x" .. n
    v.earned = n > 0
  else
    local isH = fam == "rech"
    v.title = isH and "Record height" or "Record time"
    local list = B.rec[fam]
    local cur = isH and core.recordHeight() or core.recordTime()
    local function show(x) if isH then return string.format("%d %s", x, u) end return core.fmtTime(x) end
    v.big = #list > 0 and show(cur) or "--"
    v.small = "beaten x" .. #list
    v.def = isH and string.format("Record height: the highest you have ever flown, starting from a %d %s floor. Every flight that beats the record earns one.", l.recHFloor, u)
                 or string.format("Record time: your longest flight ever, starting from a %d minute floor. Every flight that beats the record earns one.", l.recTFloor / 60)
    v.chipLabel = "HISTORY"
    local sorted = {}
    for i = 1, #list do sorted[i] = list[i] end
    table.sort(sorted, function(x, y) return x.val > y.val end)
    for i = 1, math.min(#sorted, 4) do
      v.chips[#v.chips + 1] = { text = show(sorted[i].val), sub = core.fmtDate(sorted[i].ts),
                                earned = true, beaten = i > 1 }
    end
    v.chips[#v.chips + 1] = { text = show(isH and l.recHFloor or l.recTFloor), sub = "floor",
                              earned = true, beaten = #list > 0 }
    v.tally = "records x" .. #list
    if #sorted > 0 then
      v.status = string.format("Set %s - %s - %s", show(sorted[1].val), core.fmtDate(sorted[1].ts), sorted[1].model)
    end
    v.earned = #list > 0
  end
  v.chipLabel = v.chipLabel or "FIRSTS"
  return v
end

-- ---------------------------------------------------------------- sample data

function core.seedDemo()
  local now, day = os.time(), 86400
  local u = S.cfg.units
  local function flight(ago, model, launch, max, dur, above, climbs, best, points, badges)
    appendRow("flights", { tostring(now - ago), model, u, tostring(launch), tostring(max), tostring(dur),
      tostring(above), tostring(climbs), tostring(best), "1", points, badges, "1" })
  end
  local function badge(ago, fam, kind, val, exact, model, extra)
    appendRow("badges", { u, fam, kind, tostring(val), tostring(exact), tostring(now - ago), model, extra or "", "1" })
  end
  flight(7 * day, "Bull Nose", 170, 506, 764, 640, 2, 330, "0:0|11:170|140:120|420:506|764:0", "peak.first.400.506.;dur.first.5.764.;dur.first.10.764.;rech.rec.506.506.;rect.rec.764.764.")
  flight(3 * day, "Whip Tail", 172, 1340, 965, 900, 3, 610, "0:0|12:172|110:52|330:730|450:380|700:1340|965:0", "peak.first.600.1340.;peak.first.800.1340.;peak.first.1000.1340.;peak.first.1250.1340.;peak.rep.1300.1340.;dur.first.15.965.;dur.rep.16.965.;yoyo.first.100.347.412/388/347;yoyo.first.200.347.412/388/347;yoyo.first.300.347.412/388/347;yoyo.rep.300.347.412/388/347;save.first.60.52.52/730;save.rep.60.52.52/730;rech.rec.1340.1340.;rect.rec.965.965.")
  flight(1 * day, "Bull Nose", 165, 341, 320, 250, 1, 190, "0:0|11:165|120:150|250:341|320:0", "")
  for _, r in ipairs({ { 7, "peak", "first", 400, 506, "Bull Nose" }, { 7, "dur", "first", 5, 764, "Bull Nose" },
      { 7, "dur", "first", 10, 764, "Bull Nose" }, { 7, "rech", "rec", 506, 506, "Bull Nose" },
      { 7, "rect", "rec", 764, 764, "Bull Nose" },
      { 3, "peak", "first", 600, 1340, "Whip Tail" }, { 3, "peak", "first", 800, 1340, "Whip Tail" },
      { 3, "peak", "first", 1000, 1340, "Whip Tail" }, { 3, "peak", "first", 1250, 1340, "Whip Tail" },
      { 3, "peak", "rep", 1300, 1340, "Whip Tail" }, { 3, "dur", "first", 15, 965, "Whip Tail" },
      { 3, "dur", "rep", 16, 965, "Whip Tail" },
      { 3, "yoyo", "first", 100, 347, "Whip Tail", "412/388/347" }, { 3, "yoyo", "first", 200, 347, "Whip Tail", "412/388/347" },
      { 3, "yoyo", "first", 300, 347, "Whip Tail", "412/388/347" }, { 3, "yoyo", "rep", 300, 347, "Whip Tail", "412/388/347" },
      { 3, "save", "first", 60, 52, "Whip Tail", "52/730" }, { 3, "save", "rep", 60, 52, "Whip Tail", "52/730" },
      { 3, "rech", "rec", 1340, 1340, "Whip Tail" }, { 3, "rect", "rec", 965, 965, "Whip Tail" } }) do
    badge(r[1] * day, r[2], r[3], r[4], r[5], r[6], r[7])
  end
  loadBadges(); loadFlights()
  core.setStatus("sample data added")
end

function core.erase()
  rewrite("flights", {}); rewrite("badges", {})
  loadBadges(); loadFlights()
  S.recap = nil
  core.setStatus("all flights and badges erased")
end

function core.counts() return #readRows("flights"), #readRows("badges") end

function core.setUnits(units)
  if units ~= "ft" and units ~= "m" then return end
  if S.cfg.units == units then return end
  local keep = S.cfg
  local d = defaults(units)
  d.niceTimeMin, d.alerts, d.stale, d.theme, d.rxSensor = keep.niceTimeMin, keep.alerts, keep.stale, keep.theme, keep.rxSensor
  d.timeScale = keep.timeScale
  S.cfg = d
  core.saveConfig()
  loadBadges()
end

-- ---------------------------------------------------------------- lifecycle

local function modelName()
  local ok, n = pcall(model.name)
  if ok and type(n) == "string" and n ~= "" then return (n:gsub(",", " ")) end
  return "model"
end

function core.init()
  if S.ready then return end
  S.bootAt = os.time()
  S.dir = resolveDir()
  if not S.dir then S.ioError = NO_DIR_ERROR end
  S.model = modelName()
  if S.dir and S.diagCount == nil then S.diagCount = #readRows("diag") end
  loadConfig()
  resolveSources()
  loadBadges()
  loadFlights()
  S.ready = true
  S.bootRowAt = os.time() + 1
  S.bootRowTries = 0
end

function core.wakeup()
  if not S.ready then
    local ok, err = pcall(core.init)
    if not ok then core.setStatus("init error: " .. tostring(err)) end
    return
  end
  local now = os.time()

  -- model switched in place: the flight in progress belongs to another plane
  local name = modelName()
  if name ~= S.model then
    S.model = name
    S.F, S.recap, S.alertAt, S.prevFM, S.armed = nil, nil, nil, nil, false
    S.rxBattSrc = nil
    loadConfig(); loadBadges()
    core.resolveRxSource()
    diag("model", name .. " " .. sourcesSummary())
  end

  if now - S.sourcesAt >= 1 and not (S.altSrc and S.fmSrc and S.rxBattSrc) then
    S.sourcesAt = now
    resolveSources()
  end

  if S.bootRowAt and now >= S.bootRowAt then
    local ok = diag("boot", "v" .. core.VERSION .. " " .. sourcesSummary())
    S.bootRowTries = S.bootRowTries + 1
    if ok or S.bootRowTries >= 30 then S.bootRowAt = nil else S.bootRowAt = now + 1 end
  end

  pollFlight(clock())

  if S.alertAt and now >= S.alertAt then
    S.alertAt = nil
    if alertsOn() then
      local aOk, aErr = tone(880, 180, 80)
      local bOk, bErr = tone(1320, 260)
      local hOk, hErr = haptic(400)
      diag("alert", "landing tone1=" .. verdict(aOk, aErr) .. " tone2=" .. verdict(bOk, bErr) .. " haptic=" .. verdict(hOk, hErr))
    end
  end
end

return core
