-- Renders the widget's REAL paint output to SVG: the lcd mock records every
-- primitive with its colour, then each screen is written to out/<name>.svg.
-- Font metrics are approximations, so this checks composition, not pixels.

CATEGORY_TELEMETRY_SENSOR, CATEGORY_LOGIC_SWITCH, CATEGORY_FLIGHT = 1, 2, 3
CATEGORY_FUNCTION_SWITCH = 12
FONT_XS, FONT_S, FONT_STD, FONT_L, FONT_XL, FONT_XXL = 0, 1, 2, 3, 4, 5
KEY_ROTARY_RIGHT, KEY_ROTARY_LEFT, KEY_ENTER_BREAK, KEY_RTN_FIRST, KEY_EXIT_FIRST = 11, 12, 13, 14, 15
EVT_KEY, EVT_TOUCH = 0, 1
TOUCH_START, TOUCH_END = 16640, 16641

SIM = { alt = 0, altAge = 100, fm = 0 }
local function mkSrc(get, age, unit, name)
  return { value = function() return get() end, age = function() return age and age() or 0 end,
           stringUnit = function() return unit or "" end, name = function() return name or "mock" end }
end
system = {
  getSource = function(spec)
    if spec.category == CATEGORY_TELEMETRY_SENSOR and spec.name == "Altitude" then
      return mkSrc(function() return SIM.alt end, function() return SIM.altAge end, "ft")
    elseif spec.category == CATEGORY_TELEMETRY_SENSOR and spec.name == "RxBatt" then
      return mkSrc(function() return 3.74 end, function() return 100 end, "V", "RxBatt")
    elseif spec.category == CATEGORY_FLIGHT then return mkSrc(function() return SIM.fm end)
    elseif spec.category == 12 then return mkSrc(function() return -100 end) end
    return nil
  end,
  getVersion = function() return { board = "X14", simulation = true } end,
  playHaptic = function() end, playTone = function() end,
}
model = { name = function() return "Bull Nose" end }

local FONT_H = { [0] = 17, [1] = 20, [2] = 25, [3] = 28, [4] = 37, [5] = 47 }      -- measured on the X14 sim, 26.1.2
local FONT_W = { [0] = 0.50, [1] = 0.52, [2] = 0.50, [3] = 0.52, [4] = 0.53, [5] = 0.55 }
local curFont, curCol, ops, CW, CH = 1, "#000", {}, 640, 360
local function hex(c) return string.format("#%02x%02x%02x", c[1], c[2], c[3]) end
lcd = {
  color = function(c) curCol = hex(c) end, pen = function() end,
  font = function(f) assert(FONT_H[f], "font") curFont = f end,
  invalidate = function() end, resetFocusTimeout = function() end,
  hasFocus = function() return true end, isSwiping = function() return false end,
  RGB = function(r, g, b) return { r, g, b } end, GREY = function(v) return { v, v, v } end,
  getWindowSize = function() return CW, CH end,
  getTextSize = function(t) return math.floor(#tostring(t) * FONT_H[curFont] * FONT_W[curFont]), FONT_H[curFont] end,
  drawText = function(x, y, t)
    t = t:gsub("&", "&amp;"):gsub("<", "&lt;")
    ops[#ops + 1] = string.format('<text x="%d" y="%d" font-size="%d" fill="%s" font-weight="%s">%s</text>',
      x, y + math.floor(FONT_H[curFont] * 0.8), math.floor(FONT_H[curFont] * 0.86), curCol, curFont >= 3 and "800" or "600", t)
  end,
  drawFilledRectangle = function(x, y, w, h)
    ops[#ops + 1] = string.format('<rect x="%d" y="%d" width="%d" height="%d" fill="%s"/>', x, y, math.min(w, 4000), math.min(h, 4000), curCol)
  end,
  drawRectangle = function(x, y, w, h, t)
    ops[#ops + 1] = string.format('<rect x="%d" y="%d" width="%d" height="%d" fill="none" stroke="%s" stroke-width="%d"/>', x, y, w, h, curCol, t or 1)
  end,
  drawLine = function(a, b, c, d)
    ops[#ops + 1] = string.format('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="%s"/>', a, b, c, d, curCol)
  end,
  loadBitmap = function(path) return { path = path } end,
  drawBitmap = function(x, y, bmp, w, h)
    ops[#ops + 1] = string.format('<image x="%d" y="%d" width="%d" height="%d" href="../../NiceFlt/%s"/>', x, y, w, h, bmp.path)
  end,
}
form = { openDialog = function() end, clear = function() end }

local core   = assert(loadfile("core.lua"))()
local draw   = assert(loadfile("draw.lua"))(core)
local config = assert(loadfile("config.lua"))(core, draw)
local screen = assert(loadfile("screen.lua"))(core, draw, config)
local app = screen.new({ needsFocus = true })

local realTime, tOff = os.time, 0
os.time = function() return realTime() + tOff end
local function sec(n) for _ = 1, (n or 1) do tOff = tOff + 1; core.wakeup() end end

local function shot(name)
  ops = {}
  app.paint(CW, CH)
  local f = io.open("out_" .. name .. ".svg", "w")
  f:write(string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" font-family="Helvetica,Arial,sans-serif">\n', CW, CH, CW, CH))
  f:write(table.concat(ops, "\n")); f:write("\n</svg>\n"); f:close()
end

core.init(); core.wakeup()
shot("1_idle_empty")

local function fly(way, stopAt)
  SIM.fm = 2; SIM.alt = 0; sec(1); SIM.fm = 3; core.wakeup()
  local t = 0
  for i = 2, #way do
    local t0, a0, t1, a1 = way[i - 1][1], way[i - 1][2], way[i][1], way[i][2]
    while t < t1 do
      t = t + 1
      SIM.alt = a0 + (a1 - a0) * (t - t0) / (t1 - t0)
      if t == 2 then SIM.fm = 0 end
      sec(1)
      if stopAt and stopAt[t] then shot(stopAt[t]) end
    end
  end
  SIM.fm = 4; sec(4); SIM.fm = 0; core.wakeup()
end

fly({ { 0, 0 }, { 4, 171 }, { 115, 55 }, { 268, 402 }, { 380, 200 }, { 500, 588 }, { 590, 350 }, { 660, 560 }, { 700, 40 }, { 704, 5 } },
    { [100] = "2_live_plain", [520] = "3_live_badge" })
shot("4_recap")
core.dismissRecap()
fly({ { 0, 0 }, { 4, 168 }, { 40, 30 }, { 46, 3 } })
shot("5_idle")
core.seedDemo()
app.pressKey(2); shot("6_history")
app.event(KEY_RTN_FIRST, nil, nil, EVT_KEY)
app.pressKey(3); shot("7_badges_peak")
for i = 2, 8 do app.pressKey(4); if i == 3 or i == 5 or i == 6 or i == 7 then shot("8_badges_" .. core.FAMILIES[i]) end end
print("rendered")
