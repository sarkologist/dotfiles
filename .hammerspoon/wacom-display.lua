-- Keep the OpenTabletDriver CLI warm; each switch uses only live RPC calls.
local M = {}
local cli = "/Applications/OpenTabletDriver.app/Contents/MacOS/OpenTabletDriver.Console"
local tablet = '"Wacom CTL-470"'
local task, listingTask, request, timeout, screenWatcher
local displays, buffer, ready, busy, pending = nil, "", false, false, false
local completion, started
local maybeRun, perform, refreshDisplays

local function finish(ok, message)
  busy, pending = false, false
  M.lastDurationMs = (hs.timer.secondsSinceEpoch() - started) * 1000
  local callback = completion
  completion = nil
  if callback then callback(ok, message, M.lastDurationMs)
  else hs.alert.show(message, ok and 0.8 or 2) end
end

local function disconnect(message)
  ready, request, buffer = false, nil, ""
  if timeout then timeout:stop(); timeout = nil end
  local old = task
  task = nil
  if old and old:isRunning() then old:terminate() end
  if busy then finish(false, message)
  else print("Wacom display: " .. message) end
end

local function area(lines, kind)
  for _, line in ipairs(lines) do
    if line:find("^" .. kind .. " area:") then
      local w, h, x, y, rotation = line:match("%[([%d.]+)x([%d.]+)@<%s*([%d.%-]+),%s*([%d.%-]+)>:([%d.%-]+)°%]")
      if w then return {w=tonumber(w), h=tonumber(h), x=tonumber(x), y=tonumber(y), rotation=tonumber(rotation)} end
    end
  end
end

local function same(a, b)
  return a and b and math.abs(a.w-b.w)<0.01 and math.abs(a.h-b.h)<0.01
    and math.abs(a.x-b.x)<0.01 and math.abs(a.y-b.y)<0.01
end

local function query(commands, callback)
  if not task or not task:isRunning() or request then
    disconnect("OpenTabletDriver connection is unavailable")
    return
  end
  request = {lines={}, callback=callback}
  timeout = hs.timer.doAfter(3, function()
    disconnect("OpenTabletDriver did not respond; try again")
  end)
  task:setInput(table.concat(commands, "\n") .. "\n")
end

local function receive(stdout, stderr)
  if stderr and stderr ~= "" then
    disconnect("OpenTabletDriver reported an error; try again")
    return
  end
  buffer = buffer .. (stdout or "")
  while buffer:find("\n", 1, true) do
    local ending = buffer:find("\n", 1, true)
    local line = buffer:sub(1, ending-1):gsub("\r$", "")
    buffer = buffer:sub(ending+1)
    if line:find("Daemon not running", 1, true) or line:find("Unhandled exception", 1, true) then
      disconnect("Cannot connect to OpenTabletDriver; restart the app")
      return
    end
    if request then
      table.insert(request.lines, line)
      if line:find("^Tablet area:") then
        local completed = request
        request = nil
        if timeout then timeout:stop(); timeout = nil end
        completed.callback(completed.lines)
      end
    end
  end
end

function M.start()
  if task and task:isRunning() then return end
  ready, buffer = false, ""
  local launched
  launched = hs.task.new(cli, function()
    if task == launched then disconnect("OpenTabletDriver connection closed; try again") end
  end, function(_, stdout, stderr)
    if task == launched then receive(stdout, stderr) end
    return true
  end, {"stdio"})
  task = launched
  if not task or not task:start() then
    disconnect("Could not start the OpenTabletDriver connection")
    return
  end
  query({'getareas ' .. tablet}, function(lines)
    if not area(lines, "Tablet") then
      disconnect("Could not read the tablet settings")
      return
    end
    ready = true
    maybeRun()
  end)
end

refreshDisplays = function()
  displays = nil
  if listingTask and listingTask:isRunning() then return end
  listingTask = hs.task.new(cli, function(code, stdout, stderr)
    listingTask = nil
    local found = {}
    for line in (stdout or ""):gmatch("[^\r\n]+") do
      local index, w, h, x, y = line:match("^(%d+): Display .- %(([%d.]+)x([%d.]+)@<%s*([%d.%-]+),%s*([%d.%-]+)>%)")
      if index then
        w, h, x, y = tonumber(w), tonumber(h), tonumber(x), tonumber(y)
        found[tonumber(index)] = {w=w, h=h, x=x+w/2, y=y+h/2}
      end
    end
    if code ~= 0 or not found[0] or not found[1] then
      if pending then finish(false, "Could not find two connected displays") end
      return
    end
    displays = found
    maybeRun()
  end, {"listdisplays"})
  if not listingTask or not listingTask:start() then
    listingTask = nil
    if pending then finish(false, "Could not read connected displays") end
  end
end

perform = function()
  pending = false
  local cached = displays
  query({'getareas ' .. tablet}, function(lines)
    local current, pen = area(lines, "Display"), area(lines, "Tablet")
    if not current or not pen then disconnect("Could not read the current tablet mapping"); return end
    local index = same(current, cached[0]) and 1 or 0
    local target = cached[index]
    local ratio = target.w / target.h
    local w, h = 147.2, 92
    if ratio > w/h then h = w/ratio else w = h*ratio end
    query({
      string.format("setdisplayarea %s %.3f %.3f %.3f %.3f", tablet, target.w, target.h, target.x, target.y),
      string.format("settabletarea %s %.3f %.3f 73.6 46 %.6f", tablet, w, h, pen.rotation),
      "savedefaultsettings",
      "getareas " .. tablet,
    }, function(verified)
      local mapped, rotated = area(verified, "Display"), area(verified, "Tablet")
      if not same(mapped, target) or not rotated or math.abs(rotated.rotation-pen.rotation)>0.001 then
        disconnect("Tablet mapping did not match the requested display")
        return
      end
      M.currentDisplay = index
      finish(true, "Wacom: display " .. (index+1))
    end)
  end)
end

maybeRun = function()
  if pending and ready and displays and not request then perform() end
end

function M.toggle(callback)
  if busy then return false end
  busy, pending, completion = true, true, callback
  started = hs.timer.secondsSinceEpoch()
  if not displays then refreshDisplays() end
  M.start()
  maybeRun()
  return true
end

function M.stop()
  if screenWatcher then screenWatcher:stop() end
  if timeout then timeout:stop(); timeout = nil end
  request, ready, busy, pending = nil, false, false, false
  local old = task
  task = nil
  if old and old:isRunning() then old:closeInput(); old:terminate() end
  if listingTask and listingTask:isRunning() then listingTask:terminate() end
  listingTask = nil
end

screenWatcher = hs.screen.watcher.new(refreshDisplays):start()
refreshDisplays()
M.start()
return M
