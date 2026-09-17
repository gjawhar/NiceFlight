-- NiceSimTour -- walks the Nice Flight! screens behind the key row and
-- photographs each one into this folder, so they can be checked without
-- anyone pressing buttons. Have the Nice Flight! page showing (Idle or a
-- recap). About 30 seconds. Writes log.txt + t*.bmp here.
local DIR = "SCRIPTS:/NiceSimTour/"
local lines = {}
local function flush() local ok, f = pcall(io.open, DIR .. "log.txt", "w"); if ok and f then f:write(table.concat(lines, "\n") .. "\n"); f:close() end end
local function log(s) lines[#lines + 1] = tostring(s); print("NiceSimTour: " .. tostring(s)); flush() end
local function nap(s) pcall(simulator.sleep, s) end
local n = 0
local function shot(name) n = n + 1; pcall(simulator.screenshot, string.format("%st%02d_%s.bmp", DIR, n, name)); nap(0.2) end
-- raw key indices (measured earlier): PAGE=0 ENTER=1 RTN=3
local function key(idx, what) local ok, e = pcall(simulator.pressKey, idx, 0.1); log("key " .. what .. ": " .. tostring(ok) .. " " .. tostring(e or "")); nap(0.7) end
local function fs(i, what)
  local ok, e = pcall(simulator.pressFunctionSwitch, i, 0.2)
  log(string.format("FS index %d (%s): %s %s", i, what, tostring(ok), tostring(e or "")))
  nap(0.9)
end
local function rotary(steps) local ok, e = pcall(simulator.turnRotaryEncoder, steps); log("rotary " .. steps .. ": " .. tostring(ok) .. " " .. tostring(e or "")); nap(0.6) end

pcall(simulator.setAnalog, 1, 100)       -- brake off, so the model is not sitting in Landing mode
nap(0.5)
shot("start")
-- No ENTER needed for the FS keys any more (they follow page visibility).
-- Focus is only taken later, where the rotary and ENTER are used.
shot("unfocused")

-- Function switches: try the 0-based index first (FS2 = 1); the screenshots
-- show whether HISTORY opened, and the 1-based guess follows if it did not.
fs(1, "FS2 = HISTORY, pressed WITHOUT focus")
shot("history_no_focus")
key(1, "ENTER (focus, for the rotary)")
rotary(1);  shot("history_row2")
key(1, "ENTER (open the selected flight)")
shot("history_recap")
rotary(1);  shot("history_recap_next_badge")
key(3, "RTN");  shot("back_to_history")        -- Ethos drops the widget's focus here; FS keys must still work
fs(0, "FS1 = BACK (no focus)");  shot("back_to_main")

fs(2, "FS3 = BADGES if 0-based")
shot("badges_1")
for i = 2, 8 do
  fs(3, "FS4 = NEXT if 0-based")
  shot("badges_" .. i)
end
key(3, "RTN")
shot("end")
pcall(simulator.resetAnalogs)
log("done")
