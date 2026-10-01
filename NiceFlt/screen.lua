-- Nice Flight! screens: Live, Idle, Recap, History, Badges, plus keys, focus,
-- rotary and touch. What shows by default follows core.state() (live /
-- recap / idle); History and Badges are visited from the key row and a
-- launch always snaps back to Live.

local core, draw, config = ...
local screen = {}

local AUTO, HISTORY, HISTRECAP, BADGES = "auto", "history", "histrecap", "badges"
local HISTORY_ROWS = 8

-- Touch: same rules as Throw Trainer / DLGPoker. A tap arrives as
-- TOUCH_START then TOUCH_END; only the release acts.
local touchCapable = nil
local function isTouchCapable()
  if touchCapable ~= nil then return touchCapable end
  local ok, v = pcall(system.getVersion)
  local board = (ok and v and v.board) or ""
  touchCapable = not string.find(tostring(board), "X14")
  return touchCapable
end
local EVT_TOUCH_CAT = rawget(_G, "EVT_TOUCH") or 1
local TOUCH_END_VAL = rawget(_G, "TOUCH_END") or 16641
local function isTouchEvent(category, x, y)
  if category ~= nil then return category == EVT_TOUCH_CAT end
  return isTouchCapable() and x ~= nil and y ~= nil and x > 0 and y > 0
end

local function confirmErase()
  local nF = core.counts()
  form.openDialog({
    title = "Erase all data",
    message = string.format("Delete %d flights and every badge? This cannot be undone.", nF),
    width = 500,
    buttons = {
      { label = "Keep data", action = function() return true end },
      { label = "Erase", action = function() core.erase() lcd.invalidate() return true end },
    },
  })
end
screen.confirmErase = confirmErase

function screen.new(opts)
  opts = opts or {}
  local V = { screen = AUTO, focus = 2, badgeSel = 1, histSel = 1, histTop = 1, famSel = 1,
              histFlight = nil, inForm = false, keyRects = {}, dirty = true, lastState = nil }
  local self = { V = V }

  function self.fits(w, h) return (w or 0) >= 300 and (h or 0) >= 200 end

  -- "On screen right now": paint only runs for the page being displayed, so a
  -- recent paint means the pilot can see the widget. FS1-FS4 are gated on
  -- THIS, not on focus. Measured in the simulator (2026-09-17): Ethos drops a
  -- widget's focus on every RTN press, even one the widget handled, and after
  -- ten idle seconds, which left the keys dead after backing out of a recap.
  -- Visibility still means a bumped FS switch can never act on a hidden page.
  function self.visible() return V.lastPaint ~= nil and os.time() - V.lastPaint <= 2 end

  -- ------------------------------------------------------------ keys

  local function keysFor()
    local st = core.state()
    if V.screen == HISTORY then return { "BACK", "OPEN", "UP", "DOWN" } end
    if V.screen == HISTRECAP then return { "BACK", nil, nil, nil } end
    if V.screen == BADGES then return { "BACK", nil, "PREV", "NEXT" } end
    if st == "live" then return { nil, nil, nil, nil } end
    if st == "recap" then return { "DISMISS", "HISTORY", "BADGES", "CFG" } end
    return { nil, "HISTORY", "BADGES", "CFG" }
  end

  local function openConfig()
    draw.clearAll(draw.palette())
    form.clear()
    V.inForm = true
    config.build(confirmErase)
  end

  local function moveHist(d)
    local n = #core.history()
    if n == 0 then return end
    V.histSel = math.max(1, math.min(n, V.histSel + d))
    if V.histSel < V.histTop then V.histTop = V.histSel end
    if V.histSel > V.histTop + HISTORY_ROWS - 1 then V.histTop = V.histSel - HISTORY_ROWS + 1 end
  end

  local function moveFam(d)
    local n = #core.FAMILIES
    V.famSel = ((V.famSel - 1 + d) % n) + 1
  end

  local function activate(i)
    local key = keysFor()[i]
    if not key then return end
    if key == "DISMISS" then core.dismissRecap()
    elseif key == "HISTORY" then V.screen = HISTORY; V.histSel, V.histTop = 1, 1
    elseif key == "BADGES" then V.screen = BADGES
    elseif key == "CFG" then openConfig()
    elseif key == "BACK" then
      if V.screen == HISTRECAP then V.screen = HISTORY else V.screen = AUTO end
    elseif key == "OPEN" then
      local f = core.history()[V.histSel]
      if f then V.histFlight = f; V.badgeSel = 1; V.screen = HISTRECAP end
    elseif key == "UP" then moveHist(-1)
    elseif key == "DOWN" then moveHist(1)
    elseif key == "PREV" then moveFam(-1)
    elseif key == "NEXT" then moveFam(1)
    end
    V.dirty = true
    lcd.invalidate()
  end

  function self.pressKey(i)
    if V.inForm then return end
    activate(i)
  end

  -- ------------------------------------------------------------ shared bits

  local function rxText()
    local rx = core.rxBatt()
    if rx.value then return string.format("RX %.2fV", rx.value), rx.low end
    return "RX --", false
  end

  local function drawRx(w, y, m, p)
    local txt, low = rxText()
    draw.font("std")
    lcd.color(low and p.bad or p.text)
    draw.textRight(w - m.pad * 3, y, txt)
  end

  local function fontH(size) draw.font(size); local _, h = lcd.getTextSize("8"); return h end

  -- The two-row big-number layout shared by Live and Idle. cells = four
  -- { label, text, unit } in reading order. Row one (timer and max) is drawn
  -- in draw.segText digits sized to whatever height is left over, because no
  -- Ethos font is big enough to read while flying; row two uses the largest
  -- real font. Returns the y below row two and the left margin.
  local function bigLayout(w, h, m, p, top, cells, reserve)
    local bigH = fontH("hero")                                -- largest real font, row two
    local x1, x2 = m.pad * 3, math.floor(w * 0.515)
    local minGap = 4
    local heroH = h - top - (m.th * 2 + bigH + reserve + minGap * 4)
    local cap = math.floor(h * 0.30)
    if heroH > cap then heroH = cap end
    -- never wider than its column: "16:04" on the left, "1340 ft" on the right
    draw.font("mid")
    local unitW = lcd.getTextSize(cells[2][3] or "") + 8
    while heroH > bigH and (draw.segWidth("88:88", heroH) > x2 - x1 - 10
          or draw.segWidth("8888", heroH) + unitW > w - x2 - m.pad * 2) do
      heroH = heroH - 2
    end
    if heroH < bigH then heroH = bigH end
    local gap = math.floor((h - top - (m.th * 2 + heroH + bigH + reserve)) / 4)
    if gap < 2 then gap = 2 end

    local y = top + gap
    draw.label(x1, y, cells[1][1], p, cells[1].color); draw.label(x2, y, cells[2][1], p)
    drawRx(w, y, m, p)
    y = y + m.th + 2
    local function hero(x, cell)
      local text = tostring(cell[2])
      if text:find("^[%d:%- ]+$") then
        draw.segText(x, y, text, heroH, p.text)
        if cell[3] and cell[3] ~= "" then
          draw.font("mid"); lcd.color(p.dim)
          local _, uh = lcd.getTextSize(cell[3])
          draw.textAt(x + draw.segWidth(text, heroH) + 8, y + heroH - uh, cell[3])
        end
      else
        draw.value(x, y, text, cell[3], "hero", "mid", p)
      end
    end
    hero(x1, cells[1]); hero(x2, cells[2])
    y = y + heroH + gap
    draw.label(x1, y, cells[3][1], p); draw.label(x2, y, cells[4][1], p)
    y = y + m.th
    draw.value(x1, y, cells[3][2], cells[3][3], "hero", "mid", p)
    draw.value(x2, y, cells[4][2], cells[4][3], "hero", "mid", p)
    return y + bigH + gap, x1
  end

  -- ------------------------------------------------------------ live

  local function paintLive(w, h, m, p, top)
    local lv = core.live()
    if not lv then return end
    local u = core.unit()
    local cells = {
      -- once the flight qualifies, the timer's label says so in green
      { lv.nice and "Nice flight!" or "Flight", core.fmtTime(lv.elapsed), color = lv.nice and p.good or nil },
      { "Max", core.fmtAlt(lv.max), u },
      { "Now", lv.now and core.fmtAlt(lv.now) or "--", u },
      { "Launch", lv.launch and core.fmtAlt(lv.launch) or "--", u },
    }
    local y, x1 = bigLayout(w, h, m, p, top, cells, m.th * 2 + 6)

    -- bottom left: two stacked lines, values bold by colour
    draw.font("std")
    local lineH = fontH("std")
    if y + lineH * 2 > h - 2 then y = h - 2 - lineH * 2 end
    local l1, l2 = "Time above launch", string.format("Climbs over %d %s:", core.S.cfg.climb, u)
    draw.font("std")
    local valX = x1 + math.max(lcd.getTextSize(l1), lcd.getTextSize(l2)) + 10
    local function line(yy, text, val)
      draw.font("std"); lcd.color(p.dim)
      draw.textAt(x1, yy, text)
      lcd.color(p.text)
      draw.textAt(valX, yy, val)
    end
    line(y, l1, core.fmtTime(lv.above))
    line(y + lineH, l2, tostring(lv.climbs))

    -- bottom right: the latest badge earned this flight, for the rest of it
    if lv.pill then
      local it = lv.pill
      local txt = core.badgeLabel(it)
      local style = (it.kind == "rec") and "rec" or "sel"
      local pw, ph = draw.pill(0, 0, it.fam, txt, style, "mid", p, true)
      local px, py = w - m.pad * 3 - pw, h - m.pad - ph
      draw.font("tiny")
      local _, lh = lcd.getTextSize("8")
      lcd.color(p.dim)
      draw.textRight(w - m.pad * 3, py - lh - 1, "BADGE EARNED")
      draw.pill(px, py, it.fam, txt, style, "mid", p)
    end
  end

  -- ------------------------------------------------------------ idle

  local function paintIdle(w, h, m, p, top)
    local last, t, u = core.S.last, core.today(), core.unit()
    local cells = {
      { "Last flight", last and core.fmtTime(last.dur) or "--:--" },
      { "Max", last and core.fmtAlt(last.max) or "--", u },
      { "Launch", last and core.fmtAlt(last.launch) or "--", u },
      { "Nice flights today", tostring(t.nice), string.format("of %d throw%s", t.throws, t.throws == 1 and "" or "s") },
    }
    local y, x1 = bigLayout(w, h, m, p, top, cells, m.th * 2 + 6)
    local lineH = fontH("std")
    if y + lineH * 2 > h - 2 then y = h - 2 - lineH * 2 end
    draw.font("std")
    if t.bestAlt then
      lcd.color(p.dim); draw.textAt(x1, y, "Best today")
      local tw = lcd.getTextSize("Best today")
      lcd.color(p.text)
      draw.textAt(x1 + tw + 6, y, string.format("%s %s  -  %s", core.fmtAlt(t.bestAlt), u, core.fmtTime(t.bestDur)))
    end
    -- status text lives on this screen only
    local status = core.status()
    if not status then
      local ts = core.telemetryState()
      local tail = (ts == "ok") and "ready" or ((ts == "none") and "no telemetry link" or "stale telemetry")
      status = core.S.model .. " - " .. tail
    end
    if core.timeScale() > 1 then status = string.format("TEST CLOCK x%d (simulator) - %s", core.timeScale(), status) end
    draw.font("small"); lcd.color(p.dim)
    draw.textAt(x1, h - m.th - 2, status, w - x1 * 2)
  end

  -- ------------------------------------------------------------ recap

  -- Badge pills, wrapped to at most two rows; drops to the small font when
  -- the standard one would not fit. Returns the y below them.
  local function badgeRows(x, y, maxW, items, sel, p, unit)
    local function rowsNeeded(size)
      local cx, rows = x, 1
      for _, it in ipairs(items) do
        local pw = draw.pill(0, 0, it.fam, core.badgeLabel(it, unit), "normal", size, p, true)
        if cx + pw > x + maxW and cx > x then rows = rows + 1; cx = x end
        cx = cx + pw + 6
      end
      return rows
    end
    local size = (rowsNeeded("std") <= 2) and "std" or "small"
    local cx, cy, rowH, rows = x, y, 0, 1
    for i, it in ipairs(items) do
      local style = (i == sel) and "sel" or ((it.kind == "rec") and "rec" or "normal")
      local txt = core.badgeLabel(it, unit)
      local pw, ph = draw.pill(0, 0, it.fam, txt, style, size, p, true)
      if cx + pw > x + maxW and cx > x then
        rows = rows + 1
        if rows > 2 then break end               -- the rest are still in History's caption walk
        cx, cy = x, cy + rowH + 4
      end
      draw.pill(cx, cy, it.fam, txt, style, size, p)
      cx, rowH = cx + pw + 6, ph
    end
    return cy + rowH
  end

  local function paintRecap(w, h, m, p, top, f)
    local u = (f.sys == "m") and "m" or "ft"
    local k = (f.sys == "m") and 3.28084 or 1
    local function alt(ft) return tostring(core.round(ft / k)) .. " " .. u end
    local x1 = m.pad * 3
    local y = top + 2
    draw.font("mid"); lcd.color(p.text)
    draw.textAt(x1, y, "Nice Flight!")
    local _, titleH = lcd.getTextSize("N")
    draw.font("small"); lcd.color(p.dim)
    draw.textRight(w - x1, y + titleH - m.th, f.model .. " - " .. core.fmtDate(f.ts))
    y = y + titleH + 2

    local items = core.displayBadges(core.parseBadges(f.badges), u)
    local valH = fontH("std")
    local rowH = m.th + valH
    local fieldsH = rowH * 3
    local colW = math.floor(w * 0.19)
    local fields = { { "Launch", alt(f.launch) }, { "Max", alt(f.max) },
                     { "Time", core.fmtTime(f.dur) }, { "Above launch", core.fmtTime(f.above) },
                     { "Climbs", tostring(f.climbs) }, { "Best climb", alt(f.best) } }
    for i, fd in ipairs(fields) do
      local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
      local fx, fy = x1 + col * colW, y + row * rowH
      draw.label(fx, fy, fd[1], p)
      draw.font("std"); lcd.color(p.text)
      draw.textAt(fx, fy + m.th - 2, fd[2])
    end
    local gx = x1 + colW * 2 + m.pad
    draw.graph(gx, y, w - gx - m.pad, fieldsH, core.parsePoints(f.points), p)
    y = y + fieldsH + 2

    if #items > 0 then
      draw.label(x1, y, "Badges earned on this flight", p)
      y = y + m.th
      if V.badgeSel > #items then V.badgeSel = #items end
      -- The caption sits directly under the pills it explains (pilot,
      -- 2026-09-17: at the bottom of the screen it did not look like it
      -- belonged to the badge).
      local yEnd = badgeRows(x1, y, w - x1 * 2, items, V.badgeSel, p, u)
      local cy = math.min(yEnd + 4, h - m.th - 2)
      draw.font("small"); lcd.color(p.dim)
      draw.textAt(x1, cy, core.badgeCaption(items[V.badgeSel], u), w - x1 * 2)
    end
  end

  -- ------------------------------------------------------------ history

  local function paintHistory(w, h, m, p, top)
    local list = core.history()
    local x1 = m.pad * 3
    local cols = { 0, 0.16, 0.30, 0.44, 0.57, 0.76 }
    local heads = { "Date", "Launch", "Max", "Flight", "Badges", "Model" }
    local function cx(i) return x1 + math.floor((w - x1 * 2) * cols[i]) end
    local y = top + 2
    draw.font("tiny"); lcd.color(p.dim)
    for i = 1, #heads do draw.textAt(cx(i), y, string.upper(heads[i])) end
    local _, hh = lcd.getTextSize("8")
    y = y + hh + 2
    lcd.color(p.line); lcd.drawLine(x1, y, w - x1, y)
    local rowH = m.th + 6
    if #list == 0 then
      draw.font("small"); lcd.color(p.dim)
      draw.textAt(x1, y + 8, "No nice flights yet.")
      return
    end
    for r = 0, HISTORY_ROWS - 1 do
      local f = list[V.histTop + r]
      if not f then break end
      local ry = y + 1 + r * rowH
      if ry + rowH > h - m.th - 4 then break end
      local sel = (V.histTop + r) == V.histSel
      if sel then lcd.color(p.text); lcd.drawFilledRectangle(x1 - 4, ry, w - x1 * 2 + 8, rowH) end
      local u = (f.sys == "m") and "m" or "ft"
      local k = (f.sys == "m") and 3.28084 or 1
      draw.font("small"); lcd.color(sel and p.bg or p.text)
      draw.textAt(cx(1), ry + 3, core.fmtDate(f.ts))
      draw.textAt(cx(2), ry + 3, core.round(f.launch / k) .. " " .. u)
      draw.textAt(cx(3), ry + 3, core.round(f.max / k) .. " " .. u)
      draw.textAt(cx(4), ry + 3, core.fmtTime(f.dur))
      draw.textAt(cx(6), ry + 3, f.model, w - x1 - cx(6))
      -- one icon per family earned
      local seen, ix = {}, cx(5)
      for _, it in ipairs(core.parseBadges(f.badges)) do
        local famKey = (it.fam == "rect") and "rech" or it.fam
        if not seen[famKey] and ix + m.th < cx(6) - 4 then
          seen[famKey] = true
          draw.icon(it.fam, ix, ry + 3, m.th, p, sel)
          ix = ix + m.th + 2
        end
      end
    end
    draw.font("small"); lcd.color(p.dim)
    local last = math.min(#list, V.histTop + HISTORY_ROWS - 1)
    draw.textAt(x1, h - m.th - 2, string.format("%d-%d of %d", V.histTop, last, #list))
  end

  -- ------------------------------------------------------------ badges

  local function wrap(text, maxW, maxLines)
    local lines, cur = {}, ""
    for word in tostring(text):gmatch("%S+") do
      local try = (cur == "") and word or (cur .. " " .. word)
      if lcd.getTextSize(try) <= maxW then cur = try
      else
        if cur ~= "" then lines[#lines + 1] = cur end
        cur = word
        if #lines >= maxLines then break end
      end
    end
    if cur ~= "" and #lines < maxLines then lines[#lines + 1] = cur end
    return lines
  end

  local function paintBadges(w, h, m, p, top)
    local x1 = m.pad + 2
    local gapX, gapY = 4, 5        -- measured on the X14: every pixel of tile width matters for the tiny font
    local cw = math.floor((w - x1 * 2 - gapX * 3) / 4)
    local stdH, tinyH = fontH("small"), fontH("tiny")
    local ch = tinyH + stdH + tinyH + 10
    local selView
    for i, fam in ipairs(core.FAMILIES) do
      local v = core.familyView(fam)
      local col, row = (i - 1) % 4, math.floor((i - 1) / 4)
      local cx, cy = x1 + col * (cw + gapX), top + 2 + row * (ch + gapY)
      local sel = i == V.famSel
      if sel then selView = v end
      local fg, sub, border, bg = p.text, p.dim, p.text, p.bg
      if sel then fg, sub, border, bg = p.bg, p.line, p.text, p.text
      elseif not v.earned then fg, sub, border, bg = p.grey, p.grey, p.grey, p.greyBg end
      lcd.color(bg); lcd.drawFilledRectangle(cx, cy, cw, ch)
      lcd.color(border); lcd.drawRectangle(cx, cy, cw, ch, 2)
      draw.icon(fam, cx + 4, cy + 3, tinyH, p, sel)
      draw.font("tiny"); lcd.color(fg)
      draw.textAt(cx + 4 + tinyH + 2, cy + 3, v.title, cw - tinyH - 8)
      local by = cy + tinyH + 5
      draw.font("small"); lcd.color(fg)
      local big = draw.fitText(v.big, cw - 10)
      draw.textAt(cx + 6, by, big)
      if v.bigSuffix then
        local bw = lcd.getTextSize(big)
        draw.font("tiny"); lcd.color(sub)
        draw.textAt(cx + 6 + bw + 4, by + (stdH - tinyH) - 1, v.bigSuffix, cw - bw - 16)
      end
      draw.font("tiny"); lcd.color(sub)
      draw.textAt(cx + 5, by + stdH, v.small, cw - 7)
    end
    if not selView then return end

    local y = top + 2 + 2 * (ch + gapY) + 2
    draw.font("small"); lcd.color(p.text)
    for _, ln in ipairs(wrap(selView.def, w - x1 * 2, 3)) do
      draw.textAt(x1, y, ln)
      y = y + m.th
    end
    y = y + 4

    -- the family's row: label, chips, and the tally chip at the right. If
    -- the whole ladder does not fit in the small font it is drawn tiny, so
    -- the unearned rungs at the end are never the ones that get dropped.
    draw.font("tiny")
    local lw = lcd.getTextSize(selView.chipLabel)
    local function rowWidth(size)
      local total = 0
      for _, chip in ipairs(selView.chips) do
        chip.size = size
        total = total + draw.chip(0, 0, chip, p, true) + 4
      end
      return total
    end
    local tally = { text = selView.tally, tally = true }
    local tallyW = draw.chip(0, 0, tally, p, true)
    local room = w - x1 * 2 - lw - 6 - tallyW - 6
    if rowWidth("small") > room then
      tally.size = "tiny"
      tallyW = draw.chip(0, 0, tally, p, true)
      room = w - x1 * 2 - lw - 6 - tallyW - 6
      rowWidth("tiny")
    end
    local _, chipH = draw.chip(0, 0, selView.chips[1] or tally, p, true)
    local _, tallyH = draw.chip(0, 0, tally, p, true)
    draw.font("tiny"); lcd.color(p.dim)
    draw.textAt(x1, y + math.floor((chipH - tinyH) / 2), selView.chipLabel)
    local cx, limit = x1 + lw + 6, w - x1 - tallyW - 6
    for _, chip in ipairs(selView.chips) do
      local cwid = draw.chip(0, 0, chip, p, true)
      if cx + cwid > limit then break end
      draw.chip(cx, y, chip, p)
      cx = cx + cwid + 4
    end
    draw.chip(w - x1 - tallyW, y + math.floor((chipH - tallyH) / 2), tally, p)

    if selView.status then
      draw.font("small"); lcd.color(p.dim)
      draw.textAt(x1, h - m.th - 2, selView.status, w - x1 * 2)
    end
  end

  -- ------------------------------------------------------------ paint

  function self.paint(w, h)
    if V.inForm then return end
    if not self.fits(w, h) then draw.tooSmall(w, h) return end
    local st = core.state()
    if st == "live" and V.screen ~= AUTO then V.screen = AUTO end      -- a launch always wins
    if st ~= V.lastState then V.lastState = st; V.badgeSel = 1; V.focus = (st == "recap") and 1 or 2 end

    V.lastPaint = os.time()
    local p, m = draw.palette(), draw.metrics(w, h)
    -- once per boot: which font constants this firmware has and how tall they
    -- really are, so layout questions can be answered from diag.csv
    if not V.fontsLogged then
      V.fontsLogged = true
      -- pcall'd as a whole, and every number goes through tostring: Ethos
      -- returns FLOAT text sizes and "%d" of a non-integer float throws.
      pcall(function()
        local parts = { "canvas=" .. tostring(w) .. "x" .. tostring(h) }
        for _, name in ipairs({ "FONT_XS", "FONT_S", "FONT_STD", "FONT_M", "FONT_L", "FONT_XL", "FONT_XXL", "FONT_XXXL" }) do
          local f = rawget(_G, name)
          if f ~= nil and pcall(lcd.font, f) then
            local tw, th = lcd.getTextSize("8")
            parts[#parts + 1] = name:sub(6) .. "=" .. tostring(tw) .. "x" .. tostring(th)
          else
            parts[#parts + 1] = name:sub(6) .. "=none"
          end
        end
        core.diag("fonts", table.concat(parts, " "))
      end)
    end
    draw.clear(w, h, p)
    local live = true        -- the FS keys work whenever this page is showing (see self.visible)
    local keys, items = keysFor(), {}
    local LABEL = { UP = "UP", DOWN = "DOWN", PREV = "PREV", NEXT = "NEXT" }
    for i = 1, 4 do
      if keys[i] then items[i] = { label = LABEL[keys[i]] or keys[i], focused = (V.focus == i) and V.screen == AUTO and st == "idle" } end
    end
    local keyH
    V.keyRects, keyH = draw.keyRow(w, m, p, live, items, isTouchCapable())
    V.dirty = false

    if V.screen == HISTORY then paintHistory(w, h, m, p, keyH)
    elseif V.screen == HISTRECAP and V.histFlight then paintRecap(w, h, m, p, keyH, V.histFlight)
    elseif V.screen == BADGES then paintBadges(w, h, m, p, keyH)
    elseif st == "live" then paintLive(w, h, m, p, keyH)
    elseif st == "recap" then paintRecap(w, h, m, p, keyH, core.S.recap)
    else paintIdle(w, h, m, p, keyH) end
  end

  -- True when the next frame would differ: once a second while anything
  -- ticks, immediately after input, never otherwise. The recap graph is a
  -- few hundred lines; repainting it every wakeup is pointless.
  local lastPaintSec, lastSig = nil, nil
  function self.needsPaint()
    local now = os.time()
    local lv = core.live()
    local sig = core.state() .. (lv and lv.pill and lv.pill.key or "")
    if V.dirty or sig ~= lastSig or now ~= lastPaintSec then
      lastSig, lastPaintSec = sig, now
      return true
    end
    return false
  end

  -- ------------------------------------------------------------ events

  local function step(value, x)
    local n = math.abs(tonumber(x) or 1)
    if n < 1 then n = 1 end
    if value == KEY_ROTARY_RIGHT then return n end
    if value == KEY_ROTARY_LEFT then return -n end
    return 0
  end

  function self.event(value, x, y, category)
    if isTouchEvent(category, x, y) and value ~= TOUCH_END_VAL then return true end

    if V.inForm then
      if value == KEY_RTN_FIRST or value == 99 then
        form.clear()
        V.inForm = false
        V.screen = AUTO
        draw.clearAll(draw.palette())
        V.dirty = true
        lcd.invalidate()
        return true
      end
      return false
    end

    if isTouchEvent(category, x, y) then
      for i, r in pairs(V.keyRects) do
        if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
          activate(i)
          return true
        end
      end
      return false
    end

    local st = core.state()
    if value == KEY_ROTARY_RIGHT or value == KEY_ROTARY_LEFT then
      local d = step(value, x)
      if V.screen == HISTORY then moveHist(d)
      elseif V.screen == BADGES then moveFam(d)
      elseif V.screen == HISTRECAP or (V.screen == AUTO and st == "recap") then
        local f = (V.screen == HISTRECAP) and V.histFlight or core.S.recap
        local n = f and #core.displayBadges(core.parseBadges(f.badges)) or 0
        if n > 0 then V.badgeSel = ((V.badgeSel - 1 + d) % n) + 1 end
      elseif st == "idle" then
        V.focus = ((V.focus - 2 + d) % 3) + 2          -- keys 2..4
      end
      V.dirty = true
      lcd.invalidate()
      return true
    end

    if value == KEY_ENTER_BREAK then
      if V.screen == HISTORY then activate(2)
      elseif V.screen == AUTO and st == "idle" then activate(V.focus) end
      return true
    end

    if value == KEY_RTN_FIRST or value == KEY_EXIT_FIRST or value == 99 then
      if V.screen ~= AUTO then
        activate(1)                                      -- BACK
        return true
      end
      return false
    end
    return false
  end

  function self.leaveForm()
    if V.inForm then
      form.clear()
      V.inForm = false
      draw.clearAll(draw.palette())
    end
  end

  return self
end

return screen
