local M = {}

local appBundleID = "jp.plentycom.app.SteerMouse"
local stateKey = "slimblade.handedness"
local presets = {
  left = os.getenv("HOME") .. "/.config/input-devices/steermouse/SlimBlade Left Hand.smsetting_app",
  right = os.getenv("HOME") .. "/.config/input-devices/steermouse/SlimBlade Right Hand.smsetting_app"
}

local busy = false
local usbTimer = nil

local function attribute(element, name)
  local ok, value = pcall(function() return element:attributeValue(name) end)
  if ok then return value end
end

local function descendants(root, predicate)
  if not root then return nil end
  local queue = {root}
  local index = 1
  while index <= #queue do
    local element = queue[index]
    index = index + 1
    if predicate(element) then return element end
    for _, child in ipairs(attribute(element, "AXChildren") or {}) do
      queue[#queue + 1] = child
    end
  end
end

local function matches(element, role, title, identifier, description)
  return (not role or attribute(element, "AXRole") == role)
    and (not title or attribute(element, "AXTitle") == title)
    and (not identifier or attribute(element, "AXIdentifier") == identifier)
    and (not description or attribute(element, "AXDescription") == description)
end

local function press(element)
  if not element then return false end
  local ok, result = pcall(function() return element:performAction("AXPress") end)
  return ok and result ~= false and result ~= nil
end

local function waitFor(label, finder, callback, onFailure, timeout)
  local started = hs.timer.secondsSinceEpoch()
  local timer
  timer = hs.timer.doEvery(0.1, function()
    local ok, result = pcall(finder)
    if ok and result then
      timer:stop()
      callback(result)
    elseif hs.timer.secondsSinceEpoch() - started >= (timeout or 6) then
      timer:stop()
      onFailure("Timed out waiting for " .. label)
    end
  end)
end

local function appElement()
  local app = hs.application.get(appBundleID)
  return app and hs.axuielement.applicationElement(app), app
end

local function mainWindow()
  local root = appElement()
  return descendants(root, function(element)
    return matches(element, "AXWindow", "SteerMouse")
  end)
end

local function rowAction(window, rowName)
  local row = descendants(window, function(element)
    if attribute(element, "AXRole") ~= "AXRow" then return false end
    return descendants(element, function(child)
      return attribute(child, "AXValue") == rowName
    end) ~= nil
  end)
  local button = descendants(row, function(element)
    return attribute(element, "AXRole") == "AXButton"
  end)
  return button and attribute(button, "AXTitle")
end

local function currentHandedness()
  local action = rowAction(mainWindow(), "Bottom Left")
  if action == "Primary Click" then return "right" end
  if action == "Secondary Click" then return "left" end
  return hs.settings.get(stateKey)
end

local function wacomAttached()
  for _, device in ipairs(hs.usb.attachedDevices() or {}) do
    local product = tostring(device.productName or "")
    local vendor = tostring(device.vendorName or "")
    if device.vendorID == 0x056a
        or product:lower():find("ctl%-470")
        or vendor:lower():find("wacom") then
      return true
    end
  end
  return false
end

function M.set(handedness, options)
  options = options or {}
  if handedness ~= "left" and handedness ~= "right" then
    error("handedness must be 'left' or 'right'")
  end
  if busy then return false end

  if not options.force and currentHandedness() == handedness then
    hs.settings.set(stateKey, handedness)
    return true
  end
  if not hs.fs.attributes(presets[handedness]) then
    hs.alert.show("SlimBlade " .. handedness .. "-hand preset is missing")
    return false
  end

  busy = true
  local previousApp = hs.application.frontmostApplication()
  local previousBundleID = previousApp and previousApp:bundleID()

  local function finish(message, succeeded)
    busy = false
    if succeeded then hs.settings.set(stateKey, handedness) end
    if previousBundleID and previousBundleID ~= appBundleID then
      local app = hs.application.get(previousBundleID)
      if app then app:activate(true) end
    end
    hs.alert.show(message)
  end

  local function fail(message)
    finish("SlimBlade switch failed: " .. message, false)
  end

  hs.application.launchOrFocusByBundleID(appBundleID)
  waitFor("SteerMouse", mainWindow, function(window)
    local device = descendants(window, function(element)
      return matches(element, "AXButton", "SlimBlade Pro")
    end)
    if not device or attribute(device, "AXDescription") ~= "available" then
      fail("SlimBlade Pro is not connected")
      return
    end

    local edit = descendants(window, function(element)
      return matches(element, "AXButton", "Edit")
    end)
    if not press(edit) then
      fail("could not open application settings")
      return
    end

    waitFor("application settings", function()
      local root = appElement()
      return descendants(root, function(element)
        return matches(element, "AXMenuButton", nil, nil, "action")
      end)
    end, function(actionMenu)
      local sheet = attribute(actionMenu, "AXTopLevelUIElement")
      local defaultRow = descendants(sheet, function(element)
        if attribute(element, "AXRole") ~= "AXRow" then return false end
        return descendants(element, function(child)
          return attribute(child, "AXValue") == "Default"
        end) ~= nil
      end)
      if defaultRow then defaultRow:setAttributeValue("AXSelected", true) end
      if not press(actionMenu) then
        fail("could not open the import menu")
        return
      end

      waitFor("Import menu item", function()
        local root = appElement()
        return descendants(root, function(element)
          return matches(element, "AXMenuItem", "Import...", "import:")
            and attribute(element, "AXEnabled") ~= false
        end)
      end, function(importItem)
        if not press(importItem) then
          fail("could not choose Import")
          return
        end

        waitFor("file picker", function()
          local root = appElement()
          return descendants(root, function(element)
            return matches(element, "AXSheet", nil, "open-panel")
          end)
        end, function()
          hs.eventtap.keyStroke({"cmd", "shift"}, "g", 0)
          waitFor("Go to Folder field", function()
            local root = appElement()
            return descendants(root, function(element)
              return matches(element, "AXTextField", nil, "PathTextField")
            end)
          end, function(pathField)
            pathField:setAttributeValue("AXValue", presets[handedness])
            hs.eventtap.keyStroke({}, "return", 0)

            waitFor("selected preset", function()
              local root = appElement()
              return descendants(root, function(element)
                return matches(element, "AXButton", "Open", "OKButton")
                  and attribute(element, "AXEnabled") ~= false
              end)
            end, function(openButton)
              if not press(openButton) then
                fail("could not open the preset")
                return
              end

              waitFor("replacement confirmation", function()
                local root = appElement()
                local prompt = descendants(root, function(element)
                  local value = attribute(element, "AXValue")
                  return type(value) == "string"
                    and value:find("replace.*Default") ~= nil
                end)
                if not prompt then return nil end
                local dialog = attribute(prompt, "AXTopLevelUIElement")
                return descendants(dialog, function(element)
                  return matches(element, "AXButton", "OK", "action-button--998")
                end)
              end, function(confirmButton)
                if not press(confirmButton) then
                  fail("could not confirm replacement")
                  return
                end

                waitFor("application settings confirmation", function()
                  local root = appElement()
                  local action = descendants(root, function(element)
                    return matches(element, "AXMenuButton", nil, nil, "action")
                  end)
                  local sheet = action and attribute(action, "AXTopLevelUIElement")
                  return descendants(sheet, function(element)
                    return matches(element, "AXButton", "OK")
                  end)
                end, function(okButton)
                  if not press(okButton) then
                    fail("could not save the imported preset")
                    return
                  end

                  waitFor("SteerMouse main window", mainWindow, function(windowNow)
                    local buttonsTab = descendants(windowNow, function(element)
                      return matches(element, "AXRadioButton", "Buttons")
                    end)
                    if attribute(buttonsTab, "AXValue") ~= 1 and not press(buttonsTab) then
                      fail("could not verify the imported buttons")
                      return
                    end

                    waitFor("updated buttons", function()
                      local expected = handedness == "right" and "Primary Click" or "Secondary Click"
                      return rowAction(mainWindow(), "Bottom Left") == expected and true or nil
                    end, function()
                      finish("SlimBlade: " .. handedness .. " hand", true)
                    end, fail)
                  end, fail)
                end, fail)
              end, fail)
            end, fail)
          end, fail)
        end, fail)
      end, fail)
    end, fail)
  end, fail)
  return true
end

function M.toggle()
  local current = currentHandedness() or (wacomAttached() and "left" or "right")
  return M.set(current == "left" and "right" or "left", {force = true})
end

function M.reconcile()
  return M.set(wacomAttached() and "left" or "right")
end

hs.hotkey.bind({"ctrl", "alt", "cmd"}, "h", M.toggle)

M.usbWatcher = hs.usb.watcher.new(function(event)
  local product = tostring(event.productName or ""):lower()
  local vendor = tostring(event.vendorName or ""):lower()
  if event.vendorID ~= 0x056a
      and not product:find("ctl%-470")
      and not vendor:find("wacom") then
    return
  end
  if usbTimer then usbTimer:stop() end
  usbTimer = hs.timer.doAfter(1, M.reconcile)
end):start()

hs.settings.set(stateKey, currentHandedness() or (wacomAttached() and "left" or "right"))
hs.timer.doAfter(2, M.reconcile)

return M
