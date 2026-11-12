-- InstrProbe: finds Ethos's per-callback Lua instruction budget ("Max
-- instructions count reached"). Each paint runs ONE pcall'd busy loop of N
-- instructions-ish (N grows 2000 per paint), logs "N ok" or "N FAIL" to
-- Files/probe.csv, and draws the running result. Leave it on screen for a
-- minute; then read the file. Also tries the same in wakeup, separately.
local N_STEP, N_MAX = 2000, 400000
local S = { paintN = 0, wakeN = 0, paintMax = 0, paintFail = nil, wakeMax = 0, wakeFail = nil, wakeups = 0, sec = nil, rate = 0, rateMax = 0 }

local function log(line)
  local f = io.open("probe.csv", "a")
  if f then f:write(tostring(os.time()) .. "," .. line .. "\n"); f:close() end
end

local function burn(n)       -- ~4 VM instructions per iteration
  local x = 0
  for i = 1, n do x = x + i end
  return x
end

local function tryN(kind, n)
  local ok, err = pcall(burn, n)
  if ok then
    if kind == "paint" then S.paintMax = n else S.wakeMax = n end
    log(kind .. "," .. n .. ",ok")
  else
    if kind == "paint" then S.paintFail = S.paintFail or n else S.wakeFail = S.wakeFail or n end
    log(kind .. "," .. n .. ",FAIL," .. tostring(err))
  end
  return ok
end

local function create() log("boot,,,") return {} end

local function wakeup(widget)
  -- wakeup rate, per whole second
  local now = os.time()
  if S.sec ~= now then
    if S.sec then S.rate = S.wakeups; if S.rate > S.rateMax then S.rateMax = S.rate end; log("rate," .. S.rate) end
    S.sec, S.wakeups = now, 0
  end
  S.wakeups = S.wakeups + 1
  if not S.wakeFail and S.wakeN < N_MAX then
    S.wakeN = S.wakeN + N_STEP
    tryN("wakeup", S.wakeN)
  end
  lcd.invalidate()
end

local function paint(widget)
  if not S.paintFail and S.paintN < N_MAX then
    S.paintN = S.paintN + N_STEP
    tryN("paint", S.paintN)
  end
  lcd.font(FONT_STD)
  lcd.color(lcd.RGB(255, 255, 255))
  lcd.drawText(8, 8, "InstrProbe (loop iterations, ~4 instr each)")
  lcd.drawText(8, 40, string.format("paint: ok up to %d%s", S.paintMax, S.paintFail and ("  FAIL at " .. S.paintFail) or "  (still probing)"))
  lcd.drawText(8, 72, string.format("wakeup: ok up to %d%s", S.wakeMax, S.wakeFail and ("  FAIL at " .. S.wakeFail) or "  (still probing)"))
  lcd.drawText(8, 104, string.format("wakeups per second: %d (max %d)", S.rate, S.rateMax))
  lcd.drawText(8, 150, "Files/probe.csv has the full record")
end

local function init()
  system.registerWidget({ key = "inprobe", name = "Instr Probe", create = create, wakeup = wakeup, paint = paint })
end
return { init = init }
