local spacesOK, spaces = pcall(require, "hs._asm.undocumented.spaces")
if not spacesOK then
  spacesOK, spaces = pcall(require, "hs.spaces")
end
if not spacesOK then
  error("No usable Hammerspoon Spaces module: " .. tostring(spaces))
end
if not spaces.count or not spaces.currentSpace then
  -- Hammerspoon 0.9.52's built-in hs.spaces only has a watcher. Keep the
  -- window-layout shortcuts working, but leave the obsolete space cycler off.
  spaces = {
    count = function() return 0 end,
    currentSpace = function() return 1 end
  }
end

-- Config
local mash = {
  split   = {"ctrl", "cmd"},
  corner  = {"ctrl", "shift"},
  utils   = {"ctrl", "cmd"}
}

local spacesModifier = "ctrl"

local animationDuration = 0

local centeredWindowRatios = {
  small = { w = 0.8, h = 0.8 }, -- screen width < 2560
  large = { w = 0.66, h = 0.66 } -- screen width >= 2560
}

local defaultBrightness = 60
local nightModeBrightness = 6

-- Setup
local logger = hs.logger.new("config", "verbose")

hs.alert.defaultStyle.strokeColor = { white = 0, alpha = 0.75 }
hs.alert.defaultStyle.textSize = 25

hs.window.animationDuration = animationDuration

hs.grid.setGrid("10x2")
hs.grid.setMargins("0x0")

-- Reload config
hs.hotkey.bind(mash.utils, "-", function()
  hs.reload()
end)

-- Resize windows
local gridPositions = {
  -- splits
  top              = { ["50-50"] = "0,0 10x1", ["60-40"] = "0,0 10x1" },
  right            = { ["50-50"] = "5,0 5x2",  ["60-40"] = "6,0 4x2" },
  bottom           = { ["50-50"] = "0,1 10x1", ["60-40"] = "0,1 10x1" },
  left             = { ["50-50"] = "0,0 5x2",  ["60-40"] = "0,0 6x2" },
  -- corners
  ["top-left"]     = { ["50-50"] = "0,0 5x1", ["60-40"] = "0,0 6x1" },
  ["top-right"]    = { ["50-50"] = "5,0 5x1", ["60-40"] = "6,0 4x1" },
  ["bottom-right"] = { ["50-50"] = "5,1 5x1", ["60-40"] = "6,1 4x1" },
  ["bottom-left"]  = { ["50-50"] = "0,1 5x1", ["60-40"] = "0,1 6x1" }
}

local function adjustWindow(position)
  local gridPosition = gridPositions[position]

  return function()
    local win = hs.window.focusedWindow()
    if not win then return end

    local grid = spaces.currentSpace() == 3 and "60-40" or "50-50"

    hs.grid.set(win, gridPosition[grid])
  end
end

-- top half
hs.hotkey.bind(mash.split, "up", adjustWindow("top"))

-- right half
hs.hotkey.bind(mash.split, "right", adjustWindow("right"))

-- bottom half
hs.hotkey.bind(mash.split, "down", adjustWindow("bottom"))

-- left half
hs.hotkey.bind(mash.split, "left", adjustWindow("left"))

-- top left
hs.hotkey.bind(mash.corner, "up", adjustWindow("top-left"))

-- top right
hs.hotkey.bind(mash.corner, "right", adjustWindow("top-right"))

-- bottom right
hs.hotkey.bind(mash.corner, "down", adjustWindow("bottom-right"))

-- bottom left
hs.hotkey.bind(mash.corner, "left", adjustWindow("bottom-left"))

-- fullscreen
hs.hotkey.bind(mash.split, ",", hs.grid.maximizeWindow)

-- center small
hs.hotkey.bind(mash.split, ".", function()
  local win = hs.window.focusedWindow()
  if not win then return end

  local f = win:frame()
  local screen = win:screen():frame()
  local size = screen.w >= 2560 and "large" or "small"

  f.w = math.floor(screen.w * centeredWindowRatios[size].w)
  f.h = math.floor(screen.h * centeredWindowRatios[size].h)
  f.x = math.floor((screen.w / 2) - (f.w / 2))
  f.y = math.floor((screen.h / 2) - (f.h / 2))
  win:setFrame(f)
end)


-- Spaces
local spacesCount = spaces.count()
local spacesModifiers = {"alt", spacesModifier}

-- infinitely cycle through spaces using ctrl+left/right to trigger ctrl+[1..n]
local spacesEventtap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(o)
  local keyCode = o:getKeyCode()
  local modifiers = o:getFlags()

  --logger.i(keyCode, hs.inspect(modifiers))

  -- check if correct key code
  if keyCode ~= 123 and keyCode ~= 124 then return end
  if not modifiers[spacesModifier] then return end

  -- check if no other modifiers where pressed
  local passed = hs.fnutils.every(modifiers, function(_, modifier)
    return hs.fnutils.contains(spacesModifiers, modifier)
  end)

  if not passed then return end

  -- switch spaces
  local currentSpace = spaces.currentSpace()
  local nextSpace

  -- left arrow
  if keyCode == 123 then
    nextSpace = currentSpace ~= 1 and currentSpace - 1 or spacesCount
   -- right arrow
  elseif keyCode == 124 then
    nextSpace = currentSpace ~= spacesCount and currentSpace + 1 or 1
  end

  local event = require("hs.eventtap").event
  --event.newKeyEvent({spacesModifier}, string.format("%d", nextSpace), true):post()
  --event.newKeyEvent({spacesModifier}, string.format("%d", nextSpace), false):post()
  -- TODO: replace with this once > 0.9.50 has been released
  hs.eventtap.keyStroke(spacesModifier, string.format("%d", nextSpace), 0)

  -- stop propagation
  return true
end)

if spacesCount > 1 then spacesEventtap:start() end

hs.hotkey.bind(mash.utils, "e", function()
  -- this is to bind the spacesEventtap variable to a long-lived function in
  -- order to prevent GC from doing their evil business
  hs.alert.show("Fast space switching enabled: " .. tostring(spacesEventtap:isEnabled()))
end)


-- Wacom CTL-470: hold the upper pen button (middle mouse from OpenTabletDriver)
-- and move the pen to scroll. The cursor stays put during the gesture.
local wacomScrollActive = false
local wacomScrollLastPosition = nil
local wacomScrollStartPosition = nil
local wacomScrollMoved = false
local wacomScrollSpeed = 1.0
local wacomScrollActivationDistance = 20
local wacomScrollButtonNumber = 2
local wacomScrollSourcePID = nil
local wacomLastTapTime = 0
local wacomDoubleTapInterval = 0.65
local wacomDoubleTapInProgress = false
wacomDisplay = require("wacom-display")

local function openTabletDriverPID()
  local output, ok = hs.execute(
    "/usr/bin/pgrep -f '^/Applications/OpenTabletDriver[.]app/Contents/MacOS/OpenTabletDriver[.]Daemon$'"
  )
  if not ok then return nil end
  return tonumber(output:match("%d+"))
end

local function isOpenTabletDriverEvent(event, properties)
  local eventPID = event:getProperty(properties.eventSourceUnixProcessID)
  if not wacomScrollSourcePID or eventPID ~= wacomScrollSourcePID then
    wacomScrollSourcePID = openTabletDriverPID()
  end
  return wacomScrollSourcePID ~= nil and eventPID == wacomScrollSourcePID
end

local function rounded(value)
  if value >= 0 then
    return math.floor(value + 0.5)
  end
  return math.ceil(value - 0.5)
end

local function toggleWacomDisplay()
  wacomDisplay.toggle()
end

wacomScrollTap = hs.eventtap.new({
  hs.eventtap.event.types.otherMouseDown,
  hs.eventtap.event.types.otherMouseUp,
  hs.eventtap.event.types.mouseMoved,
  hs.eventtap.event.types.leftMouseDragged,
  hs.eventtap.event.types.rightMouseDragged,
  hs.eventtap.event.types.otherMouseDragged
}, function(event)
  local eventType = event:getType()
  local properties = hs.eventtap.event.properties

  if eventType == hs.eventtap.event.types.otherMouseDown
      and event:getProperty(properties.mouseEventButtonNumber) == wacomScrollButtonNumber then
    if not isOpenTabletDriverEvent(event, properties) then return false end

    local now = hs.timer.secondsSinceEpoch()
    if now - wacomLastTapTime <= wacomDoubleTapInterval then
      wacomLastTapTime = 0
      wacomDoubleTapInProgress = true
      wacomScrollActive = false
      wacomScrollLastPosition = nil
      wacomScrollStartPosition = nil
      toggleWacomDisplay()
      return true
    end

    wacomDoubleTapInProgress = false
    wacomScrollActive = true
    wacomScrollLastPosition = event:location()
    wacomScrollStartPosition = wacomScrollLastPosition
    wacomScrollMoved = false
    return true
  end

  if eventType == hs.eventtap.event.types.otherMouseUp
      and event:getProperty(properties.mouseEventButtonNumber) == wacomScrollButtonNumber then
    if event:getProperty(properties.eventSourceUnixProcessID) ~= wacomScrollSourcePID then
      return false
    end

    if wacomDoubleTapInProgress then
      wacomDoubleTapInProgress = false
      return true
    end

    if not wacomScrollActive then return false end
    local wasTap = not wacomScrollMoved
    wacomScrollActive = false
    wacomScrollLastPosition = nil
    wacomScrollStartPosition = nil

    if wasTap then
      wacomLastTapTime = hs.timer.secondsSinceEpoch()
    else
      wacomLastTapTime = 0
    end
    return true
  end

  if not wacomScrollActive then return false end
  if event:getProperty(properties.eventSourceUnixProcessID) ~= wacomScrollSourcePID then return false end

  local position = event:location()
  if wacomScrollLastPosition then
    local horizontal = rounded((wacomScrollLastPosition.x - position.x) * wacomScrollSpeed)
    local vertical = rounded((position.y - wacomScrollLastPosition.y) * wacomScrollSpeed)

    if not wacomScrollMoved and wacomScrollStartPosition then
      local fromStartX = position.x - wacomScrollStartPosition.x
      local fromStartY = position.y - wacomScrollStartPosition.y
      wacomScrollMoved = math.sqrt(fromStartX * fromStartX + fromStartY * fromStartY)
        >= wacomScrollActivationDistance
    end

    if wacomScrollMoved and (horizontal ~= 0 or vertical ~= 0) then
      hs.eventtap.event.newScrollEvent({horizontal, vertical}, {}, "pixel"):post()
    end
  end
  wacomScrollLastPosition = position

  -- Suppress pointer movement while scrolling, like grabbing the page by hand.
  return true
end):start()

slimbladeHandedness = require("slimblade")
hs.shutdownCallback = function() wacomDisplay.stop() end

-- All set
hs.alert.show("Hammerspoon — input-device shortcuts enabled")
