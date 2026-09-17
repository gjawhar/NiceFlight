-- Replays real Ethos telemetry logs through the REAL widget core. Input is
-- replay_in.txt: lines "LOG name", then "t alt fm rxv" (alt "-" = no data).
-- Every flight starts from a clean slate (no badges) unless KEEP is set, so
-- each one is judged the way a fresh install would judge it.
CATEGORY_TELEMETRY_SENSOR, CATEGORY_LOGIC_SWITCH, CATEGORY_FLIGHT = 1, 2, 3
CATEGORY_FUNCTION_SWITCH = 12
SIM = { alt = 0, altAge = 100, fm = 0, rxv = 3.8 }
local function mkSrc(get, age, unit, name)
  return { value = function() return get() end, age = function() return age and age() or 0 end,
           stringUnit = function() return unit or "" end, name = function() return name or "mock" end }
end
system = {
  getSource = function(spec)
    if spec.category == CATEGORY_TELEMETRY_SENSOR and spec.name == "Altitude" then
      return mkSrc(function() return SIM.alt end, function() return SIM.altAge end, "ft")
    elseif spec.category == CATEGORY_TELEMETRY_SENSOR and spec.name == "RxBatt" then
      return mkSrc(function() return SIM.rxv end, function() return 100 end, "V", "RxBatt")
    elseif spec.category == CATEGORY_FLIGHT then return mkSrc(function() return SIM.fm end)
    elseif spec.category == 12 then return mkSrc(function() return -100 end) end
    return nil
  end,
  getVersion = function() return { board = "X14", simulation = true } end,
  playHaptic = function() end, playTone = function() end,
}
model = { name = function() return "Bull Nose" end }
lcd = { RGB = function(r, g, b) return { r, g, b } end }

local core = assert(loadfile("core.lua"))()
local now = 1000000
os.time = function() return now end
core.init()

local out = io.open("replay_out.txt", "w")
local logName, seen, startT = "?", 0, nil
local function report()
  local rows = core.readRows("flights")
  for i = seen + 1, #rows do
    local r = rows[i]
    local fams, order = {}, {}
    for token in (r[12] or ""):gmatch("[^;]+") do
      local fam, kind = token:match("^(%a+)%.(%a+)")
      if fam and not fams[fam] then fams[fam] = true; order[#order + 1] = fam end
    end
    out:write(string.format("%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", logName, (startT or 0),
      r[4], r[5], r[6], r[7], r[8], r[9], r[10], table.concat(order, "+")))
  end
  seen = #rows
  if not KEEP then core.erase(); seen = 0 end
end

for line in io.lines("replay_in.txt") do
  local name = line:match("^LOG (.+)$")
  if name then
    report(); logName = name
    core.S.F, core.S.recap, core.S.prevFM, core.S.armed = nil, nil, nil, false
  else
    local t, alt, fm, rxv = line:match("^(%S+) (%S+) (%S+) (%S+)$")
    if t then
      now = 1000000 + math.floor(tonumber(t))
      if alt == "-" then SIM.altAge = 9000 else SIM.alt = tonumber(alt); SIM.altAge = 100 end
      SIM.fm = tonumber(fm)
      local wasF = core.S.F
      core.wakeup()
      if core.S.F and not wasF then startT = math.floor(tonumber(t)) end
      if wasF and not core.S.F then report() end
    end
  end
end
report()
out:close()
