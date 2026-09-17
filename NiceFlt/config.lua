-- Nice Flight! settings, built with the native Ethos form API.

local core, draw = ...
local config = {}

local function cfg() return core.S.cfg end

local function num(line, min, max, key, suffix, step)
  local f = form.addNumberField(line, nil, min, max,
    function() return cfg()[key] end,
    function(v) cfg()[key] = v core.saveConfig() end)
  if suffix then f:suffix(suffix) end
  if step then f:step(step) end
  return f
end

function config.build(onErase)
  local u = core.unit()
  local isM = u == "m"

  local panel = form.addExpansionPanel("What counts as a nice flight")
  local line = panel:addLine("Height")
  num(line, isM and 30 or 100, isM and 1000 or 3000, "niceHeight", u, isM and 10 or 50)
  line = panel:addLine("Time")
  num(line, 1, 60, "niceTimeMin", "min")
  line = panel:addLine("A flight is nice when it beats EITHER value")
  form.addStaticText(line, nil, "")

  panel = form.addExpansionPanel("Flight")
  line = panel:addLine("Climb size (count + graph)")
  num(line, isM and 10 or 25, isM and 300 or 1000, "climb", u, isM and 5 or 25)
  line = panel:addLine("Landing needs altitude under")
  num(line, isM and 5 or 10, isM and 100 or 300, "landAlt", u, isM and 5 or 10)
  -- Seconds since the last Altitude update before the feed counts as lost.
  -- 0 switches the check off -- for the simulator only.
  line = panel:addLine("Stale telemetry limit (0=off)")
  num(line, 0, 30, "stale", "s")

  panel = form.addExpansionPanel("Alerts and display")
  line = panel:addLine("Alerts (sound + vibration)")
  form.addChoiceField(line, nil, { { "On", 1 }, { "Off", 0 } },
    function() return cfg().alerts end,
    function(v) cfg().alerts = v core.saveConfig() end)
  line = panel:addLine("Units")
  form.addChoiceField(line, nil, { { "ft", 1 }, { "m", 2 } },
    function() return (cfg().units == "m") and 2 or 1 end,
    function(v) core.setUnits((v == 2) and "m" or "ft") end)
  line = panel:addLine("Theme")
  form.addChoiceField(line, nil, { { "Night", 1 }, { "Day", 2 } },
    function() return cfg().theme end,
    function(v) cfg().theme = v core.saveConfig() lcd.invalidate() end)
  -- Persisted BY NAME, per plane: a source object does not survive a reboot
  -- through config.csv (Throw Trainer's hard-won lesson).
  line = panel:addLine("RX voltage source")
  form.addSourceField(line, nil,
    function() return core.S.rxBattSrc end,
    function(v)
      if v == nil then core.setRxSensor(nil) return end
      local ok, n = pcall(function() return v:name() end)
      if ok and type(n) == "string" and n ~= "" then core.setRxSensor(n)
      else core.setStatus("could not read that source's name") end
    end)

  panel = form.addExpansionPanel("Data")
  panel:open(false)
  local nF, nB = core.counts()
  line = panel:addLine("Recorded")
  form.addStaticText(line, nil, string.format("%d flights, %d badge rows", nF, nB))
  line = panel:addLine("Sample data")
  form.addButton(line, nil, { text = "Add samples", press = function() core.seedDemo() end })
  -- SIMULATOR ONLY, and only shown there: speeds up the flight clock to match
  -- a NiceSim macro's SPEED so a replayed flight is still measured at full
  -- length. A real radio never sees this row and never honours the value.
  if core.isSimulator() then
    line = panel:addLine("Simulator time scale")
    form.addChoiceField(line, nil, { { "1x (normal)", 1 }, { "4x", 4 }, { "8x", 8 }, { "16x", 16 } },
      function() return cfg().timeScale or 1 end,
      function(v) cfg().timeScale = v core.saveConfig() end)
  end
  line = panel:addLine("Erase all flights and badges")
  form.addButton(line, nil, { text = "Erase...", press = function() if onErase then onErase() end end })

  panel = form.addExpansionPanel("About")
  panel:open(false)
  line = panel:addLine("Version")
  form.addStaticText(line, nil, "Nice Flight! " .. core.VERSION)
  line = panel:addLine("Model")
  form.addStaticText(line, nil, core.S.model)
  line = panel:addLine("Altitude sensor unit")
  form.addStaticText(line, nil, core.S.sensorUnit)
  line = panel:addLine("Storage")
  form.addStaticText(line, nil, core.S.dir or "unavailable")
end

return config
