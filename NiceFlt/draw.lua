-- Nice Flight! rendering. Every lcd.* drawing call lives here. Dimensions
-- derive from measured text height, never raw pixels (an X14 and an X20
-- render the same font constant at different sizes).

local core = ...
local draw = {}

local C = lcd.RGB

local function lightPalette()
  return { bg = C(246, 246, 248), text = C(20, 20, 22), dim = C(110, 110, 116), line = C(195, 195, 200),
           good = C(35, 140, 75), goodBg = C(215, 240, 222), bad = C(190, 55, 45), badBg = C(250, 222, 218),
           amber = C(195, 135, 15), amberBg = C(251, 236, 203), fill = C(219, 232, 248),
           grey = C(165, 165, 171), greyBg = C(232, 232, 236) }
end

local function darkPalette()
  return { bg = C(14, 14, 16), text = C(235, 235, 235), dim = C(150, 150, 156), line = C(90, 90, 96),
           good = C(90, 200, 120), goodBg = C(20, 46, 30), bad = C(220, 90, 70), badBg = C(50, 24, 22),
           amber = C(240, 190, 60), amberBg = C(60, 46, 14), fill = C(30, 44, 61),
           grey = C(110, 110, 116), greyBg = C(36, 36, 40) }
end

function draw.palette()
  local theme = (core.S.cfg and core.S.cfg.theme) or 2
  if theme == 1 then return darkPalette() end
  return lightPalette()
end

-- ---------------------------------------------------------------- fonts

-- Font constants that may not exist on every firmware are looked up by name
-- and tried largest-first; the first one lcd.font accepts wins.
local function fontByName(name) return rawget(_G, name) end
local SIZES = {
  hero  = { "FONT_XXL", "FONT_XL", "FONT_L" },
  big   = { "FONT_XL", "FONT_L", "FONT_STD" },
  mid   = { "FONT_L", "FONT_STD", "FONT_M", "FONT_S" },
  std   = { "FONT_STD", "FONT_M", "FONT_S" },
  small = { "FONT_S" },
  tiny  = { "FONT_XS", "FONT_S" },
}
function draw.font(size)
  local list = SIZES[size] or SIZES.small
  for i = 1, #list do
    local f = fontByName(list[i])
    if f ~= nil and pcall(lcd.font, f) then return end
  end
  pcall(lcd.font, FONT_S)
end

function draw.metrics(w, h)
  draw.font("small")
  local _, th = lcd.getTextSize("8")
  if not th or th < 8 then th = 18 end
  return { w = w, h = h, th = th, pad = math.floor(th * 0.3) }
end

-- ---------------------------------------------------------------- basics

function draw.clear(w, h, p)
  lcd.color(p.bg)
  lcd.drawFilledRectangle(0, 0, w, h)
end

function draw.clearAll(p)
  lcd.color(p.bg)
  lcd.drawFilledRectangle(0, 0, 4000, 4000)
end

function draw.fitText(text, maxW)
  local tw = lcd.getTextSize(text)
  if tw <= maxW then return text end
  for i = #text - 1, 1, -1 do
    local cut = string.sub(text, 1, i)
    if lcd.getTextSize(cut) <= maxW then return cut end
  end
  return ""
end

function draw.textAt(x, y, text, maxW)
  text = tostring(text)
  if maxW then text = draw.fitText(text, maxW) end
  lcd.drawText(math.floor(x), math.floor(y), text)
end

function draw.textRight(xRight, y, text)
  text = tostring(text)
  local tw = lcd.getTextSize(text)
  lcd.drawText(math.floor(xRight - tw), math.floor(y), text)
end

-- Small caps-style field label ("FLIGHT", "MAX").
function draw.label(x, y, text, p)
  draw.font("small")
  lcd.color(p.dim)
  draw.textAt(x, y, string.upper(text))
  local _, th = lcd.getTextSize("8")
  return th
end

-- Big value with a smaller trailing unit. Returns width, height.
function draw.value(x, y, text, unit, size, unitSize, p)
  draw.font(size)
  text = tostring(text)
  local bw, bh = lcd.getTextSize(text)
  lcd.color(p.text)
  draw.textAt(x, y, text)
  local uw = 0
  if unit and unit ~= "" then
    draw.font(unitSize or "std")
    local w2, sh = lcd.getTextSize(unit)
    lcd.color(p.dim)
    draw.textAt(x + bw + 4, y + (bh - sh) - math.floor(bh * 0.08), unit)
    uw = w2 + 4
  end
  return bw + uw, bh
end

-- ---------------------------------------------------------------- large digits

-- The biggest Ethos font on an X14 is 47 px tall (FONT_XXL, measured), about
-- half of what a number read at arm's length while flying needs. These are
-- seven-segment digits built from filled rectangles, so they scale to any
-- height and cost at most seven rectangles each. Supports 0-9 : - and space.
--      aaa
--     f   b
--      ggg
--     e   c
--      ddd
local SEGS = { ["0"] = "abcdef", ["1"] = "bc", ["2"] = "abged", ["3"] = "abgcd", ["4"] = "fgbc",
               ["5"] = "afgcd", ["6"] = "afgedc", ["7"] = "abc", ["8"] = "abcdefg", ["9"] = "abfgcd",
               ["-"] = "g" }

function draw.segMetrics(h)
  local t = math.max(4, math.floor(h * 0.13))          -- stroke
  local dw = math.floor(h * 0.54)                      -- digit width
  return t, dw, math.max(4, math.floor(t * 1.1))       -- stroke, width, gap between characters
end

function draw.segWidth(text, h)
  local t, dw, gap = draw.segMetrics(h)
  local w = 0
  for i = 1, #text do
    local ch = text:sub(i, i)
    w = w + ((ch == ":") and t or ((ch == " ") and math.floor(dw / 2) or dw)) + gap
  end
  return math.max(0, w - gap)
end

-- Segments have pointed (mitred) ends like a real LCD, built from 2 px
-- slices, so the digits read as shaped strokes rather than stacked blocks.
local STEP = 2
local function hseg(x0, x1, yc, k)
  for r = -k, k, STEP do
    local inset = math.abs(r)
    local len = (x1 - x0) - 2 * inset
    if len > 0 then lcd.drawFilledRectangle(x0 + inset, yc + r, len, STEP) end
  end
end
local function vseg(xc, y0, y1, k)
  for r = -k, k, STEP do
    local inset = math.abs(r)
    local len = (y1 - y0) - 2 * inset
    if len > 0 then lcd.drawFilledRectangle(xc + r, y0 + inset, STEP, len) end
  end
end

function draw.segText(x, y, text, h, color)
  local t, dw, gap = draw.segMetrics(h)
  local k = math.floor(t / 2)
  lcd.color(color)
  x = math.floor(x); y = math.floor(y)
  local yT, yM, yB = y + k, y + math.floor(h / 2), y + h - k - 1
  for i = 1, #text do
    local ch = text:sub(i, i)
    if ch == ":" then
      local cx = x + k
      vseg(cx, y + math.floor(h * 0.30) - k, y + math.floor(h * 0.30) + k, k)
      vseg(cx, y + math.floor(h * 0.70) - k, y + math.floor(h * 0.70) + k, k)
      x = x + t + gap
    elseif ch == " " then
      x = x + math.floor(dw / 2) + gap
    else
      local segs = SEGS[ch] or ""
      local xL, xR = x + k, x + dw - k - 1
      for j = 1, #segs do
        local sg = segs:sub(j, j)
        if sg == "a" then hseg(xL + 1, xR - 1, yT, k)
        elseif sg == "g" then hseg(xL + 1, xR - 1, yM, k)
        elseif sg == "d" then hseg(xL + 1, xR - 1, yB, k)
        elseif sg == "f" then vseg(xL, yT + 1, yM - 1, k)
        elseif sg == "b" then vseg(xR, yT + 1, yM - 1, k)
        elseif sg == "e" then vseg(xL, yM + 1, yB - 1, k)
        elseif sg == "c" then vseg(xR, yM + 1, yB - 1, k) end
      end
      x = x + dw + gap
    end
  end
end

-- ---------------------------------------------------------------- key row

-- FS1-FS4 aligned key row pinned to the top of the canvas (the physical
-- buttons sit above the screen on the X14). items[i] = { label=, focused= }
-- or nil for an empty slot. Returns tap rects (when live) and the row height.
function draw.keyRow(w, m, p, live, items, touch)
  local keyRowH = m.th + 4 + m.pad * 2
  local kw = math.floor(w / 4)
  local rects = {}
  for i = 1, 4 do
    local kx = (i - 1) * kw
    local it = items[i]
    draw.font("small")
    if not it then
      lcd.color(p.line)
      local tw = lcd.getTextSize("--")
      draw.textAt(kx + math.floor((kw - tw) / 2), m.pad, "--")
    else
      local bx, bw2, bh2 = kx + 2, kw - 4, keyRowH - m.pad
      local focused = live and it.focused
      local labelColor
      if not live then
        lcd.color(p.line); lcd.drawRectangle(bx, 0, bw2, bh2, 1); labelColor = p.line
      elseif focused then
        lcd.color(p.text); lcd.drawFilledRectangle(bx, 0, bw2, bh2); labelColor = p.bg
      else
        lcd.color(p.line); lcd.drawRectangle(bx, 0, bw2, bh2, 1); labelColor = p.dim
      end
      draw.font("tiny")
      lcd.color(focused and p.bg or p.line)
      draw.textAt(bx + 4, 2, "FS" .. i)
      draw.font("small")
      lcd.color(labelColor)
      local tw = lcd.getTextSize(it.label)
      draw.textAt(kx + math.floor((kw - tw) / 2), m.pad, it.label, kw - 6)
      if live and touch then rects[i] = { x = kx, y = 0, w = kw, h = keyRowH } end
    end
  end
  return rects, keyRowH
end

-- ---------------------------------------------------------------- icons

-- Badge icons are PNGs shipped in icons/. Loaded once, pcall-guarded: a
-- radio that cannot load them gets a lettered square instead, never an error.
local ICON_FILE = { peak = "peak", dur = "dur", yoyo = "yoyo", reb = "reb", save = "save",
                    hat = "hat", rech = "rec", rect = "rec" }
local ICON_LETTER = { peak = "P", dur = "D", yoyo = "Y", reb = "R", save = "S", hat = "H", rech = "*", rect = "*" }
local icons = {}

local function icon(fam)
  local v = icons[fam]
  if v ~= nil then return v or nil end
  local ok, bmp = false, nil
  if lcd.loadBitmap then ok, bmp = pcall(lcd.loadBitmap, "icons/" .. (ICON_FILE[fam] or fam) .. ".png") end
  icons[fam] = (ok and bmp) or false
  return icons[fam] or nil
end

function draw.icon(fam, x, y, size, p, inverted)
  local bmp = icon(fam)
  if bmp and lcd.drawBitmap and pcall(lcd.drawBitmap, x, y, bmp, size, size) then return end
  lcd.color(inverted and p.bg or p.text)
  lcd.drawRectangle(x, y, size, size, 1)
  draw.font("tiny")
  local s = ICON_LETTER[fam] or "?"
  local tw, th = lcd.getTextSize(s)
  draw.textAt(x + math.floor((size - tw) / 2), y + math.floor((size - th) / 2), s)
end

-- ---------------------------------------------------------------- pills

-- style: "normal" outline, "sel" solid ink, "rec" gold, "grey" unearned.
-- size: font size name. Returns width, height. With dry=true only measures.
function draw.pill(x, y, fam, text, style, size, p, dry)
  draw.font(size)
  local tw, th = lcd.getTextSize(text)
  local padX, padY = math.floor(th * 0.35), math.floor(th * 0.18)
  local isz = fam and th or 0
  local w = padX * 2 + tw + (fam and (isz + math.floor(th * 0.3)) or 0)
  local h = th + padY * 2
  if dry then return w, h end
  local fg, bg, border = p.text, p.bg, p.text
  if style == "sel" then fg, bg, border = p.bg, p.text, p.text
  elseif style == "rec" then fg, bg, border = p.text, p.amberBg, p.amber
  elseif style == "grey" then fg, bg, border = p.grey, p.greyBg, p.grey end
  lcd.color(bg); lcd.drawFilledRectangle(x, y, w, h)
  lcd.color(border); lcd.drawRectangle(x, y, w, h, 2)
  local tx = x + padX
  if fam then
    draw.icon(fam, tx, y + padY, isz, p, style == "sel")
    tx = tx + isz + math.floor(th * 0.3)
  end
  draw.font(size)
  lcd.color(fg)
  draw.textAt(tx, y + padY, text)
  return w, h
end

-- Ladder chip: text, optional small second line, optional diagonal slash
-- for a beaten record. Returns width, height.
function draw.chip(x, y, chip, p, dry)
  local size = chip.size or "small"
  draw.font(size)
  local tw, th = lcd.getTextSize(chip.text)
  local sw, sh = 0, 0
  if chip.sub then draw.font("tiny"); sw, sh = lcd.getTextSize(chip.sub) end
  local padX, padY = math.floor(th * 0.3), 2
  local w = math.max(tw, sw) + padX * 2
  local h = th + sh + padY * 2
  if dry then return w, h end
  local fg, bg, border = p.text, p.bg, p.text
  if chip.tally then fg, bg, border = p.bg, p.text, p.text
  elseif not chip.earned then fg, bg, border = p.grey, p.greyBg, p.grey end
  lcd.color(bg); lcd.drawFilledRectangle(x, y, w, h)
  lcd.color(border); lcd.drawRectangle(x, y, w, h, 2)
  draw.font(size); lcd.color(fg)
  draw.textAt(x + math.floor((w - tw) / 2), y + padY, chip.text)
  if chip.sub then
    draw.font("tiny"); lcd.color(p.dim)
    draw.textAt(x + math.floor((w - sw) / 2), y + padY + th, chip.sub)
  end
  if chip.beaten then
    lcd.color(p.dim)
    lcd.drawLine(x - 1, y + h + 1, x + w + 1, y - 1)
  end
  return w, h
end

-- ---------------------------------------------------------------- recap graph

-- points: { {t=, a=} ... } in feet, first = start, last = landing. Smooth
-- (Catmull-Rom) trace with a light fill; highs get a green value pill, lows
-- a red one. Costs a few hundred short lines, so the caller only repaints
-- when something changed.
function draw.graph(x, y, w, h, points, p)
  if #points < 2 then return end
  draw.font("tiny")
  local _, th = lcd.getTextSize("8")
  local maxA, dur = 1, points[#points].t
  for i = 1, #points do if points[i].a > maxA then maxA = points[i].a end end
  if dur <= 0 then dur = 1 end
  local axisW = lcd.getTextSize(core.fmtAlt(maxA)) + 6
  local gx, gy, gw, gh = x + axisW, y + th, w - axisW - 4, h - th * 2 - 4
  if gw < 20 or gh < 20 then return end
  local function X(t) return gx + t / dur * gw end
  local function Y(a) return gy + gh - (a / maxA) * gh end

  lcd.color(p.line)
  lcd.drawLine(gx, gy, gx, gy + gh)
  lcd.drawLine(gx, gy + gh, gx + gw, gy + gh)
  lcd.color(p.dim)
  draw.textRight(gx - 4, gy - math.floor(th / 2), core.fmtAlt(maxA))
  draw.textRight(gx - 4, gy + gh - math.floor(th / 2), "0")
  draw.textAt(gx, gy + gh + 3, "0:00")
  draw.textRight(gx + gw, gy + gh + 3, core.fmtTime(points[#points].t))

  -- sample the curve
  local px = {}
  for i = 1, #points do px[i] = { X(points[i].t), Y(points[i].a) } end
  local curve = {}
  local STEPS = 10
  for i = 1, #px - 1 do
    local p0, p1, p2, p3 = px[i - 1] or px[i], px[i], px[i + 1], px[i + 2] or px[i + 1]
    for s = 0, STEPS - 1 do
      local t = s / STEPS
      local t2, t3 = t * t, t * t * t
      local cx = 0.5 * ((2 * p1[1]) + (-p0[1] + p2[1]) * t + (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2 + (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3)
      local cy = 0.5 * ((2 * p1[2]) + (-p0[2] + p2[2]) * t + (2 * p0[2] - 5 * p1[2] + 4 * p2[2] - p3[2]) * t2 + (-p0[2] + 3 * p1[2] - 3 * p2[2] + p3[2]) * t3)
      if cy > gy + gh then cy = gy + gh end
      if cy < gy then cy = gy end
      curve[#curve + 1] = { cx, cy }
    end
  end
  curve[#curve + 1] = { px[#px][1], px[#px][2] }

  -- fill: one vertical line every other column is enough at this size
  lcd.color(p.fill)
  local ci = 1
  for col = math.floor(gx) + 1, math.floor(gx + gw) - 1, 2 do
    while ci < #curve - 1 and curve[ci + 1][1] < col do ci = ci + 1 end
    local a, b = curve[ci], curve[ci + 1]
    local yy = a[2]
    if b[1] > a[1] then yy = a[2] + (b[2] - a[2]) * (col - a[1]) / (b[1] - a[1]) end
    if yy < gy + gh - 1 then
      lcd.drawLine(col, math.floor(yy), col, gy + gh - 1)
      lcd.drawLine(col + 1, math.floor(yy), col + 1, gy + gh - 1)
    end
  end

  -- trace, drawn twice for weight
  lcd.color(p.text)
  for i = 1, #curve - 1 do
    local a, b = curve[i], curve[i + 1]
    lcd.drawLine(math.floor(a[1]), math.floor(a[2]), math.floor(b[1]), math.floor(b[2]))
    lcd.drawLine(math.floor(a[1]), math.floor(a[2]) + 1, math.floor(b[1]), math.floor(b[2]) + 1)
  end

  -- value pills on the interior points: highs above in green, lows below in red
  -- A pill that would sit on top of one already drawn is skipped (its dot
  -- stays): seen in the sim, a 7 ft dip right after launch put "94" on "101".
  draw.font("tiny")
  local placed = {}
  for i = 2, #points - 1 do
    local prev, cur, nxt = points[i - 1].a, points[i].a, points[i + 1].a
    local high = cur >= prev and cur >= nxt
    local txt = core.fmtAlt(cur)
    local tw = lcd.getTextSize(txt)
    local bw, bh = tw + 8, th + 2
    local bx = math.floor(px[i][1] - bw / 2)
    if bx < gx + 1 then bx = gx + 1 end
    if bx + bw > gx + gw then bx = gx + gw - bw end
    local by = high and (px[i][2] - bh - 5) or (px[i][2] + 5)
    if by < y then by = y end
    if by + bh > gy + gh - 1 then by = gy + gh - 1 - bh end
    local clash = false
    for _, r in ipairs(placed) do
      if bx < r.x + r.w + 2 and r.x < bx + bw + 2 and by < r.y + r.h + 2 and r.y < by + bh + 2 then clash = true end
    end
    if not clash then
      placed[#placed + 1] = { x = bx, y = by, w = bw, h = bh }
      lcd.color(high and p.goodBg or p.badBg)
      lcd.drawFilledRectangle(bx, math.floor(by), bw, bh)
      lcd.color(high and p.good or p.bad)
      draw.textAt(bx + 4, math.floor(by) + 1, txt)
    end
    lcd.color(p.text)
    lcd.drawFilledRectangle(math.floor(px[i][1]) - 2, math.floor(px[i][2]) - 2, 5, 5)
  end
end

-- Shown when the cell is too small for the app.
function draw.tooSmall(w, h)
  local p = draw.palette()
  draw.clear(w, h, p)
  draw.font("small")
  lcd.color(p.dim)
  draw.textAt(4, 4, "Nice Flight! needs a full screen", w - 8)
end

return draw
