-- NiceSimDiag v3 -- (1) which macro call makes the radio jump to its first
-- screen page, (2) how densely telemetry frames must be sent to keep the
-- Altitude sensor alive, and whether RSSI/VFR frames matter.
-- BEFORE RUNNING: have the Nice Flight! page showing. About 40 seconds.
local DIR = "SCRIPTS:/NiceSimDiag/"
local lines = {}
local function flush() local ok, f = pcall(io.open, DIR .. "log.txt", "w"); if ok and f then f:write(table.concat(lines, "\n") .. "\n"); f:close() end end
local function log(s) lines[#lines + 1] = tostring(s); print("NiceSimDiag: " .. tostring(s)); flush() end
local function nap(s) pcall(simulator.sleep, s) end
local function shot(n) pcall(simulator.screenshot, DIR .. n .. ".bmp") end
local function frame(appId, value) simulator.injectSPortFrame({ module = 0, band = 0, rx = 0, physId = 0x1A, primId = 0x10, appId = appId, value = value }) end
local function age()
  local ok, src = pcall(system.getSource, { category = CATEGORY_TELEMETRY_SENSOR, name = "Altitude" })
  if not (ok and src) then return -2 end
  local _, a = pcall(function() return src:age() end)
  return tonumber(a) or -2
end

log("v3 start")
shot("0_start");                                                  nap(0.3)
pcall(simulator.resetSwitches);            nap(0.6); shot("1_resetSwitches")
pcall(simulator.setAnalog, 1, 100);        nap(0.6); shot("2_throttle_up")
pcall(simulator.setSwitch, 7, 100);        nap(0.8); shot("3_launch_down")
pcall(simulator.setSwitch, 7, -100);       nap(0.8); shot("4_launch_release")
pcall(simulator.setAnalog, 2, 40); nap(0.4); pcall(simulator.setAnalog, 2, 0); nap(0.5); shot("5_elevator")
for _ = 1, 30 do frame(0x0100, 3048); nap(0.03) end;              shot("6_alt_frames")
for _ = 1, 30 do frame(0xF101, 90); frame(0x0100, 3048); nap(0.03) end; shot("7_rssi_frames")
log("steps done")

-- density: fraction of reads that find the sensor alive (age 0..1000 ms)
local function density(gap, withLink)
  local alive, n = 0, 0
  local stop = os.clock and nil
  for _ = 1, math.floor(3 / gap) do
    if withLink then frame(0xF101, 90); frame(0xF010, 100) end
    frame(0x0100, 3048)
    nap(gap)
    local a = age()
    n = n + 1
    if a >= 0 and a < 1000 then alive = alive + 1 end
  end
  log(string.format("gap %.2f s %s: alive %d of %d reads", gap, withLink and "ALT+RSSI+VFR" or "ALT only", alive, n))
end
for _, gap in ipairs({ 0.10, 0.05, 0.03, 0.02 }) do density(gap, true) end
for _, gap in ipairs({ 0.05, 0.02 }) do density(gap, false) end
pcall(simulator.resetAnalogs); pcall(simulator.resetSwitches)
log("done")
