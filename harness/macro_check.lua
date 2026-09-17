-- Runs the generated simulator macros, UNMODIFIED, against the real widget
-- core. The `simulator` namespace is mocked so that the macro's own calls
-- drive the model the way the radio would: switch SG = Launch mode, release
-- = Zoom until the elevator moves, throttle pulled = Landing mode, the
-- launch button zeroes the altitude (SF11), sleep() advances the clock.
CATEGORY_TELEMETRY_SENSOR, CATEGORY_LOGIC_SWITCH, CATEGORY_FLIGHT = 1, 2, 3
CATEGORY_FUNCTION_SWITCH = 12
local M = { raw = 0, offset = 0, lastFrame = -100, sg = false, zoom = false, brake = true }   -- at rest the sim model sits in Landing mode
local clock = 2000000.0
os.time = function() return math.floor(clock) end
local function mkSrc(get, age, unit, name)
  return { value = function() return get() end, age = function() return age and age() or 0 end,
           stringUnit = function() return unit or "" end, name = function() return name or "mock" end }
end
system = {
  getSource = function(spec)
    if spec.category == CATEGORY_TELEMETRY_SENSOR and spec.name == "Altitude" then
      return mkSrc(function() return M.raw - M.offset end,
                   function() return math.floor((clock - M.lastFrame) * 1000) end, "ft")
    elseif spec.category == CATEGORY_TELEMETRY_SENSOR and spec.name == "RxBatt" then
      return mkSrc(function() return 3.8 end, function() return 100 end, "V", "RxBatt")
    elseif spec.category == CATEGORY_FLIGHT then
      return mkSrc(function() return M.brake and 4 or (M.sg and 2 or (M.zoom and 3 or 0)) end)
    elseif spec.category == 12 then return mkSrc(function() return -100 end) end
    return nil
  end,
  getVersion = function() return { board = "X14", simulation = true } end,
  playHaptic = function() end, playTone = function() end,
}
model = { name = function() return "Bull Nose" end }
lcd = { RGB = function(r, g, b) return { r, g, b } end }

local core = assert(loadfile("core.lua"))()
core.init()
core.S.cfg.timeScale = TIMESCALE or 1

simulator = {
  sleep = function(dt) clock = clock + dt; core.wakeup() end,
  injectSPortFrame = function(f)
    if f.appId == 0x0100 then M.raw = f.value / 30.48; M.lastFrame = clock end
  end,
  resetSwitches = function() end,
  pressKey = function() end,
  screenshot = function() end,
  setSwitch = function(idx, v)
    assert(idx == 7, "launch is simulator switch index 7 (measured)")
    local on = v > 0
    if on and not M.sg then M.offset = M.raw end                 -- SF11: Reset Telemetry Altitude
    if M.sg and not on then M.zoom = true end                    -- release -> Zoom
    M.sg = on
  end,
  setAnalog = function(idx, v)
    if idx == 2 and v ~= 0 then M.zoom = false end               -- elevator (index 2) push leaves Zoom
    if idx == 1 then M.brake = v <= 0 end                        -- throttle (index 1): at or below rest = brake
  end,
}

local out = io.open("macro_out.txt", "w")
local seen = 0
for name in io.lines("macro_list.txt") do
  local realPrint = print
  print = function() end
  local ok, err = pcall(function() assert(loadfile(name .. ".lua"))() end)
  print = realPrint
  if not ok then out:write(name .. "\tERROR\t" .. tostring(err) .. "\n") end
  for _ = 1, 8 do clock = clock + 1; core.wakeup() end             -- a few idle seconds between macros
  local rows = core.readRows("flights")
  if #rows == seen then out:write(name .. "\tNOFLIGHT\n") end
  for i = seen + 1, #rows do
    local r = rows[i]
    local fams, order = {}, {}
    for token in (r[12] or ""):gmatch("[^;]+") do
      local fam = token:match("^(%a+)%.")
      if fam and not fams[fam] then fams[fam] = true; order[#order + 1] = fam end
    end
    out:write(string.format("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", name, r[4], r[5], r[6], r[8], r[10],
      table.concat(order, "+"), r[11], core.state()))
  end
  seen = #rows
  core.dismissRecap()
end
out:close()
