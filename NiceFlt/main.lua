-- Nice Flight! -- celebrates and records good DLG flights. Widget-only, the
-- same shape as Throw Trainer: thin glue, every entry point pcall-wrapped so
-- a failure surfaces as text instead of silently stopping flight detection.

local core   = assert(loadfile("core.lua"))()
local draw   = assert(loadfile("draw.lua"))(core)
local config = assert(loadfile("config.lua"))(core, draw)
local screen = assert(loadfile("screen.lua"))(core, draw, config)

local function widgetCreate()
  local ok, err = pcall(core.init)
  if not ok then core.setStatus("init error: " .. tostring(err)) end
  return { app = screen.new({ needsFocus = true }) }
end

local function widgetPaint(widget)
  local w, h = lcd.getWindowSize()
  local ok, err = pcall(function()
    if widget and widget.app then widget.app.paint(w, h) else draw.tooSmall(w, h) end
  end)
  if not ok then
    lcd.color(lcd.RGB(30, 10, 10))
    lcd.drawFilledRectangle(0, 0, w, h)
    lcd.color(lcd.RGB(240, 90, 70))
    lcd.drawText(4, 4, "Nice Flight! error (paint):")
    lcd.drawText(4, 22, tostring(err))
  end
end

-- wakeup runs on every screen page of this model, which is what lets flights
-- be detected and logged while another page is showing.
local function widgetWakeup(widget)
  local ok, err = pcall(core.wakeup)
  if not ok then core.setStatus("wakeup error: " .. tostring(err)) end

  -- Hardware FS1-FS4 mirror the on-screen key row and act whenever this
  -- widget's page is the one on screen (screen.visible), NOT only while it
  -- holds focus: Ethos takes focus away on every RTN and after ten idle
  -- seconds, which left the keys dead. A hidden page still ignores them.
  local ok2, fs = pcall(core.pollFS)
  if ok2 and fs and widget and widget.app and widget.app.visible() then
    local ok3, err3 = pcall(widget.app.pressKey, fs)
    if not ok3 then core.setStatus("FS error: " .. tostring(err3)) end
  end

  if widget and widget.app then
    local ok4, need = pcall(widget.app.needsPaint)
    if not ok4 or need then lcd.invalidate() end
  else
    lcd.invalidate()
  end
end

local function widgetEvent(widget, category, value, x, y)
  if not widget or not widget.app then return false end
  if not widget.app.fits(lcd.getWindowSize()) then return false end
  if lcd.isSwiping and lcd.isSwiping() then return false end
  if lcd.hasFocus and not lcd.hasFocus() then return false end
  local ok, handled = pcall(widget.app.event, value, x, y, category)
  if not ok then
    core.setStatus("event error: " .. tostring(handled))
    return true
  end
  if handled and lcd.resetFocusTimeout then pcall(lcd.resetFocusTimeout) end
  return handled
end

local function widgetConfigure(widget)
  local ok, err = pcall(function()
    core.init()
    config.build(screen.confirmErase)
  end)
  if not ok then
    core.setStatus("config error: " .. tostring(err))
    lcd.invalidate()
  end
end

local function widgetMenu(widget)
  return { { "Nice Flight! settings", function() widgetConfigure(widget) end } }
end

-- No `configure` entry on purpose (pilot feedback #1): Ethos opens a widget's
-- configure page the moment the widget is added to a screen, so the app
-- appeared to "launch on the CFG screen". Settings are one press away on the
-- CFG key and in the long-press menu below.
local function init()
  system.registerWidget({
    key       = "niceflt",
    name      = "Nice Flight!",
    create    = widgetCreate,
    paint     = widgetPaint,
    wakeup    = widgetWakeup,
    event     = widgetEvent,
    menu      = widgetMenu,
    title     = false,
  })
end

return { init = init }
