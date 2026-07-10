-- AE2 / Advanced Peripherals one-shot diagnostic dumper
-- Saves a paste-ready snapshot of every attached peripheral plus all safe,
-- read-only data exposed by any connected ME Bridge.

local args = {...}
local OUTPUT_FILE = args[1] and args[1] ~= "upload" and args[1] or "ae2-dump.txt"
local SHOULD_UPLOAD = args[1] == "upload" or args[2] == "upload"
local MAX_DEPTH = 8
local MAX_TABLE_ENTRIES = 100000

local function pack(...)
  return {n = select("#", ...), ...}
end

local function safeToString(value)
  local ok, text = pcall(tostring, value)
  return ok and text or "<tostring failed>"
end

local function sortedKeys(tbl)
  local keys = {}
  for key in pairs(tbl or {}) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b)
    local ta, tb = type(a), type(b)
    if ta == tb then return safeToString(a) < safeToString(b) end
    return ta < tb
  end)
  return keys
end

local function isReadOnlyMethod(name)
  name = tostring(name or "")
  return name:match("^get")
    or name:match("^list")
    or name:match("^is")
    or name:match("^has")
    or name:match("^count")
end

local function callObjectGetter(object, method)
  local fn = object and object[method]
  if type(fn) ~= "function" then return false, "not a function" end

  local result = pack(pcall(fn))
  if not result[1] then
    result = pack(pcall(fn, object))
  end
  if not result[1] then return false, result[2] end

  local values = {n = result.n - 1}
  for i = 2, result.n do values[i - 1] = result[i] end
  return true, values
end

local function sanitize(value, depth, seen)
  depth = depth or 0
  seen = seen or {}

  local valueType = type(value)
  if valueType == "nil" or valueType == "boolean" or valueType == "number" or valueType == "string" then
    return value
  elseif valueType ~= "table" then
    return "<" .. valueType .. ": " .. safeToString(value) .. ">"
  end

  if seen[value] then return "<cycle>" end
  if depth >= MAX_DEPTH then return "<max depth reached>" end
  seen[value] = true

  local output = {}
  local methodResults = {}
  local entryCount = 0

  for _, key in ipairs(sortedKeys(value)) do
    entryCount = entryCount + 1
    if entryCount > MAX_TABLE_ENTRIES then
      output.__truncated = "table exceeded " .. MAX_TABLE_ENTRIES .. " entries"
      break
    end

    local child = value[key]
    if type(child) == "function" then
      local methodName = safeToString(key)
      output[methodName] = "<function>"
      if isReadOnlyMethod(methodName) then
        local ok, returned = callObjectGetter(value, key)
        if ok then
          local cleaned = {n = returned.n}
          for i = 1, returned.n do
            cleaned[i] = sanitize(returned[i], depth + 1, seen)
          end
          methodResults[methodName] = cleaned
        else
          methodResults[methodName] = {error = safeToString(returned)}
        end
      end
    else
      local primitiveKey = type(key) == "string" or type(key) == "number" or type(key) == "boolean"
      local cleanKey = primitiveKey and key or safeToString(key)
      output[cleanKey] = sanitize(child, depth + 1, seen)
    end
  end

  if next(methodResults) then output.__getter_results = methodResults end
  seen[value] = nil
  return output
end

local function serialize(value)
  local ok, result = pcall(textutils.serialize, value, {compact = false, allow_repetitions = true})
  if ok then return result end
  ok, result = pcall(textutils.serialize, value)
  return ok and result or ("<serialize failed: " .. safeToString(result) .. ">")
end

if fs.exists(OUTPUT_FILE) then fs.delete(OUTPUT_FILE) end
local handle = fs.open(OUTPUT_FILE, "w")
if not handle then error("Could not open " .. OUTPUT_FILE .. " for writing") end

local function line(text)
  handle.write(tostring(text or "") .. "\n")
end

local function section(title)
  line("")
  line(string.rep("=", 78))
  line(title)
  line(string.rep("=", 78))
end

local function callPeripheral(name, method, ...)
  local result = pack(pcall(peripheral.call, name, method, ...))
  if not result[1] then return false, result[2] end

  local values = {n = result.n - 1}
  for i = 2, result.n do values[i - 1] = result[i] end
  return true, values
end

local function peripheralTypes(name)
  local values = pack(peripheral.getType(name))
  local types = {}
  for i = 1, values.n do
    if values[i] ~= nil then types[#types + 1] = values[i] end
  end
  table.sort(types)
  return types
end

local function contains(list, wanted)
  for _, value in ipairs(list or {}) do
    if value == wanted then return true end
  end
  return false
end

local function collectTaskIds(value, ids, depth, seen)
  ids = ids or {}
  depth = depth or 0
  seen = seen or {}
  if depth > 6 or type(value) ~= "table" or seen[value] then return ids end
  seen[value] = true

  local candidates = {
    value.bridge_id,
    value.bridgeId,
    value.id,
    value.jobId,
    value.taskId
  }
  for _, candidate in ipairs(candidates) do
    local numeric = tonumber(candidate)
    if numeric and numeric >= 0 then ids[numeric] = true end
  end

  for _, child in pairs(value) do
    if type(child) == "table" then collectTaskIds(child, ids, depth + 1, seen) end
  end
  seen[value] = nil
  return ids
end

local startClock = os.clock()
line("AE2 / ADVANCED PERIPHERALS DIAGNOSTIC DUMP")
line("Generated once; read-only methods only")
line("Computer ID: " .. safeToString(os.getComputerID and os.getComputerID() or "unknown"))
line("Computer label: " .. safeToString(os.getComputerLabel and os.getComputerLabel() or "none"))
line("CraftOS: " .. safeToString(os.version and os.version() or "unknown"))
line("Epoch UTC: " .. safeToString(os.epoch and os.epoch("utc") or "unavailable"))

local names = peripheral.getNames()
table.sort(names)

section("ATTACHED PERIPHERALS")
line("Count: " .. #names)

local bridges = {}
for _, name in ipairs(names) do
  local types = peripheralTypes(name)
  local methods = peripheral.getMethods(name) or {}
  table.sort(methods)

  line("")
  line("Peripheral: " .. name)
  line("Types: " .. table.concat(types, ", "))
  line("Methods (" .. #methods .. "): " .. table.concat(methods, ", "))

  if contains(types, "me_bridge") then
    bridges[#bridges + 1] = {name = name, methods = methods, types = types}
  end
end

if #bridges == 0 then
  section("ME BRIDGE")
  line("No peripheral with type 'me_bridge' was found.")
else
  section("ME BRIDGE READ-ONLY PROBES")
  line("Bridge count: " .. #bridges)

  for _, bridge in ipairs(bridges) do
    line("")
    line(string.rep("-", 78))
    line("Bridge: " .. bridge.name)
    line(string.rep("-", 78))

    local taskIds = {}
    for _, method in ipairs(bridge.methods) do
      if isReadOnlyMethod(method) then
        line("")
        line("METHOD " .. method .. "()")
        local ok, returned = callPeripheral(bridge.name, method)
        if not ok then
          line("ERROR: " .. safeToString(returned))
        else
          local raw = {n = returned.n}
          for i = 1, returned.n do
            raw[i] = returned[i]
            collectTaskIds(returned[i], taskIds)
          end
          line(serialize(sanitize(raw)))
        end
      end
    end

    local taskMethods = {}
    for _, method in ipairs(bridge.methods) do
      if method == "getCraftingTask" or method == "getCraftingJob" then
        taskMethods[#taskMethods + 1] = method
      end
    end

    if next(taskIds) and #taskMethods > 0 then
      line("")
      line("DEEP CRAFTING TASK LOOKUPS")
      local orderedIds = {}
      for id in pairs(taskIds) do orderedIds[#orderedIds + 1] = id end
      table.sort(orderedIds)

      for _, id in ipairs(orderedIds) do
        for _, method in ipairs(taskMethods) do
          line("")
          line("METHOD " .. method .. "(" .. id .. ")")
          local ok, returned = callPeripheral(bridge.name, method, id)
          if not ok then
            line("ERROR: " .. safeToString(returned))
          else
            local raw = {n = returned.n}
            for i = 1, returned.n do raw[i] = returned[i] end
            line(serialize(sanitize(raw)))
          end
        end
      end
    end
  end
end

section("SUMMARY")
line("Attached peripherals: " .. #names)
line("ME bridges: " .. #bridges)
line(string.format("Elapsed: %.2f seconds", os.clock() - startClock))
line("Output: " .. OUTPUT_FILE)
handle.close()

print("AE2 dump complete: " .. OUTPUT_FILE)
print("Size: " .. fs.getSize(OUTPUT_FILE) .. " bytes")

if SHOULD_UPLOAD then
  if not shell or not shell.run then
    print("Cannot launch pastebin automatically on this computer.")
    print("Run: pastebin put " .. OUTPUT_FILE)
  else
    print("Uploading with the built-in pastebin program...")
    local ok = shell.run("pastebin", "put", OUTPUT_FILE)
    if not ok then
      print("Upload failed. Run manually: pastebin put " .. OUTPUT_FILE)
    end
  end
else
  print("To upload it, run: pastebin put " .. OUTPUT_FILE)
  print("Or rerun: ae2-dump upload")
end
