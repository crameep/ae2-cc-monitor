-- AE2 / Advanced Peripherals one-shot diagnostic dumper
-- Produces a bounded, paste-ready snapshot without filling the computer disk.

local args = {...}
local OUTPUT_FILE = args[1] and args[1] ~= "upload" and args[1] or "ae2-dump.txt"
local SHOULD_UPLOAD = args[1] == "upload" or args[2] == "upload"

local MAX_DEPTH = 7
local MAX_FULL_TABLE_ENTRIES = 120
local SAMPLE_ENTRIES = 16
local TOP_AMOUNT_ENTRIES = 20
local MAX_STRING_LENGTH = 4000
local MAX_OUTPUT_BYTES = 400000
local RESERVED_DISK_BYTES = 65536
local CHECKPOINT_EVERY = 150

local operationCount = 0
local outputStopped = false
local bytesWritten = 0
local outputBudget = MAX_OUTPUT_BYTES
local handle

local function pack(...)
  return {n = select("#", ...), ...}
end

local function safeToString(value)
  local ok, text = pcall(tostring, value)
  return ok and text or "<tostring failed>"
end

local function checkpoint(force)
  operationCount = operationCount + 1
  if force or operationCount % CHECKPOINT_EVERY == 0 then
    if type(sleep) == "function" then
      sleep(0)
    else
      local eventName = "ae2_dump_yield_" .. tostring(operationCount)
      os.queueEvent(eventName)
      os.pullEvent(eventName)
    end
  end
end

local function getOutputBudget()
  local path = fs.getDir(OUTPUT_FILE)
  if path == "" then path = "." end
  local ok, free = pcall(fs.getFreeSpace, path)
  if ok and type(free) == "number" then
    return math.max(32768, math.min(MAX_OUTPUT_BYTES, free - RESERVED_DISK_BYTES))
  end
  return MAX_OUTPUT_BYTES
end

outputBudget = getOutputBudget()

if fs.exists(OUTPUT_FILE) then fs.delete(OUTPUT_FILE) end
handle = fs.open(OUTPUT_FILE, "w")
if not handle then error("Could not open " .. OUTPUT_FILE .. " for writing") end

local function writeRaw(text)
  if outputStopped then return false end
  text = tostring(text or "")
  if bytesWritten + #text > outputBudget then
    local marker = "\n<OUTPUT TRUNCATED: reached safe " .. tostring(outputBudget) .. " byte limit>\n"
    if bytesWritten + #marker <= outputBudget then
      pcall(handle.write, marker)
      bytesWritten = bytesWritten + #marker
    end
    outputStopped = true
    return false
  end

  local ok = pcall(handle.write, text)
  if not ok then
    outputStopped = true
    return false
  end
  bytesWritten = bytesWritten + #text
  return true
end

local function line(text)
  return writeRaw(tostring(text or "") .. "\n")
end

local function section(title)
  if outputStopped then return false end
  line("")
  line(string.rep("=", 78))
  line(title)
  line(string.rep("=", 78))
  return not outputStopped
end

local function sortedKeys(tbl)
  local keys = {}
  for key in pairs(tbl or {}) do
    keys[#keys + 1] = key
    checkpoint()
  end
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
  if not result[1] then result = pack(pcall(fn, object)) end
  if not result[1] then return false, result[2] end

  local values = {n = result.n - 1}
  for i = 2, result.n do values[i - 1] = result[i] end
  return true, values
end

local sanitize

local function amountFrom(value)
  if type(value) ~= "table" then return nil end
  local fields = {"amount", "count", "quantity", "qty", "crafted", "stored"}
  for _, field in ipairs(fields) do
    local amount = tonumber(value[field])
    if amount then return amount end
  end
  return nil
end

local function addTopAmount(top, key, value, amount)
  if not amount then return end
  top[#top + 1] = {key = key, value = value, amount = amount}
  table.sort(top, function(a, b) return a.amount > b.amount end)
  while #top > TOP_AMOUNT_ENTRIES do table.remove(top) end
end

local function summarizeLargeTable(value, depth, seen, entryCount)
  local samples = {}
  local topAmounts = {}
  local fieldCounts = {}
  local keyTypes = {}
  local valueTypes = {}
  local totalAmount = 0
  local amountRows = 0
  local sampled = 0

  for key, child in pairs(value) do
    checkpoint()
    local keyType = type(key)
    local valueType = type(child)
    keyTypes[keyType] = (keyTypes[keyType] or 0) + 1
    valueTypes[valueType] = (valueTypes[valueType] or 0) + 1

    if sampled < SAMPLE_ENTRIES then
      sampled = sampled + 1
      samples[#samples + 1] = {
        key = sanitize(key, depth + 1, seen),
        value = sanitize(child, depth + 1, seen)
      }
    end

    if type(child) == "table" then
      local fieldSeen = 0
      for field in pairs(child) do
        if type(field) == "string" then
          fieldCounts[field] = (fieldCounts[field] or 0) + 1
          fieldSeen = fieldSeen + 1
          if fieldSeen >= 80 then break end
        end
      end
    end

    local amount = amountFrom(child)
    if amount then
      totalAmount = totalAmount + amount
      amountRows = amountRows + 1
      addTopAmount(topAmounts, key, child, amount)
    end
  end

  local fields = {}
  for field, count in pairs(fieldCounts) do
    fields[#fields + 1] = {name = field, seen = count}
  end
  table.sort(fields, function(a, b)
    if a.seen ~= b.seen then return a.seen > b.seen end
    return a.name < b.name
  end)
  while #fields > 60 do table.remove(fields) end

  local largest = {}
  for _, row in ipairs(topAmounts) do
    largest[#largest + 1] = {
      key = sanitize(row.key, depth + 1, seen),
      amount = row.amount,
      value = sanitize(row.value, depth + 1, seen)
    }
  end

  return {
    __summary = {
      entryCount = entryCount,
      sampledEntries = #samples,
      truncated = true,
      totalAmount = amountRows > 0 and totalAmount or nil,
      rowsWithAmount = amountRows,
      keyTypes = keyTypes,
      valueTypes = valueTypes,
      observedFields = fields
    },
    samples = samples,
    largestByAmount = #largest > 0 and largest or nil
  }
end

sanitize = function(value, depth, seen)
  depth = depth or 0
  seen = seen or {}

  local valueType = type(value)
  if valueType == "string" then
    if #value > MAX_STRING_LENGTH then
      return string.sub(value, 1, MAX_STRING_LENGTH) .. "<string truncated; original " .. #value .. " bytes>"
    end
    return value
  elseif valueType == "nil" or valueType == "boolean" or valueType == "number" then
    return value
  elseif valueType ~= "table" then
    return "<" .. valueType .. ": " .. safeToString(value) .. ">"
  end

  if seen[value] then return "<cycle>" end
  if depth >= MAX_DEPTH then return "<max depth reached>" end
  seen[value] = true

  local entryCount = 0
  for _ in pairs(value) do
    entryCount = entryCount + 1
    checkpoint()
  end

  if entryCount > MAX_FULL_TABLE_ENTRIES then
    local summarized = summarizeLargeTable(value, depth, seen, entryCount)
    seen[value] = nil
    return summarized
  end

  local output = {}
  local methodResults = {}
  for _, key in ipairs(sortedKeys(value)) do
    local child = value[key]
    if type(child) == "function" then
      local methodName = safeToString(key)
      output[methodName] = "<function>"
      if isReadOnlyMethod(methodName) then
        local ok, returned = callObjectGetter(value, key)
        if ok then
          local cleaned = {n = returned.n}
          for i = 1, returned.n do cleaned[i] = sanitize(returned[i], depth + 1, seen) end
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
    checkpoint()
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

  local candidates = {value.bridge_id, value.bridgeId, value.id, value.jobId, value.taskId}
  for _, candidate in ipairs(candidates) do
    local numeric = tonumber(candidate)
    if numeric and numeric >= 0 then ids[numeric] = true end
  end

  local visited = 0
  for _, child in pairs(value) do
    visited = visited + 1
    if type(child) == "table" then collectTaskIds(child, ids, depth + 1, seen) end
    checkpoint()
    if visited >= 1000 and depth > 1 then break end
  end
  seen[value] = nil
  return ids
end

local function runDump()
  local startClock = os.clock()
  line("AE2 / ADVANCED PERIPHERALS DIAGNOSTIC DUMP")
  line("Generated once; read-only methods only")
  line("Output mode: bounded compact dump")
  line("Safe output budget: " .. tostring(outputBudget) .. " bytes")
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
    if outputStopped then break end
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
    checkpoint()
  end

  if #bridges == 0 then
    section("ME BRIDGE")
    line("No peripheral with type 'me_bridge' was found.")
  else
    section("ME BRIDGE READ-ONLY PROBES")
    line("Bridge count: " .. #bridges)

    for _, bridge in ipairs(bridges) do
      if outputStopped then break end
      line("")
      line(string.rep("-", 78))
      line("Bridge: " .. bridge.name)
      line(string.rep("-", 78))

      local taskIds = {}
      for _, method in ipairs(bridge.methods) do
        if outputStopped then break end
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
          checkpoint(true)
        end
      end

      if not outputStopped then
        line("")
        line("APPLIED FLUX TARGETED PROBES")
        local fluxFilters = {
          {name = "appflux:fe"},
          {id = "appflux:fe"},
          {fingerprint = "appflux:fe"},
          {resource = "appflux:fe"},
          {type = "appflux:fe"},
          {name = "appflux:fe", displayName = "FE"},
          "appflux:fe"
        }
        local fluxMethods = {getItem = true, getChemical = true, getFluid = true, getAmount = true}
        for _, method in ipairs(bridge.methods) do
          if outputStopped then break end
          if fluxMethods[method] then
            for _, filter in ipairs(fluxFilters) do
              line("")
              line("METHOD " .. method .. "(" .. serialize(filter) .. ")")
              local ok, returned = callPeripheral(bridge.name, method, filter)
              if not ok then
                line("ERROR: " .. safeToString(returned))
              else
                local raw = {n = returned.n}
                for i = 1, returned.n do raw[i] = returned[i] end
                line(serialize(sanitize(raw)))
              end
              checkpoint(true)
            end
          end
        end
      end

      local taskMethods = {}
      for _, method in ipairs(bridge.methods) do
        if method == "getCraftingTask" or method == "getCraftingJob" then
          taskMethods[#taskMethods + 1] = method
        end
      end

      if not outputStopped and next(taskIds) and #taskMethods > 0 then
        line("")
        line("DEEP CRAFTING TASK LOOKUPS")
        local orderedIds = {}
        for id in pairs(taskIds) do orderedIds[#orderedIds + 1] = id end
        table.sort(orderedIds)

        for _, id in ipairs(orderedIds) do
          if outputStopped then break end
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
            checkpoint(true)
          end
        end
      end
    end
  end

  if not outputStopped then
    section("SUMMARY")
    line("Attached peripherals: " .. #names)
    line("ME bridges: " .. #bridges)
    line(string.format("Elapsed: %.2f seconds", os.clock() - startClock))
    line("Output: " .. OUTPUT_FILE)
    line("Bytes written: " .. bytesWritten)
  end
end

local ok, fatalError = xpcall(runDump, function(err)
  return safeToString(err)
end)

if not ok and not outputStopped then
  section("FATAL ERROR")
  line(fatalError)
end

if handle then handle.close() end

print("AE2 dump complete: " .. OUTPUT_FILE)
print("Size: " .. fs.getSize(OUTPUT_FILE) .. " bytes")
if outputStopped then print("Output was safely truncated before the disk filled.") end
if not ok then printError("Diagnostic encountered an error: " .. fatalError) end

if SHOULD_UPLOAD then
  if not shell or not shell.run then
    print("Cannot launch pastebin automatically on this computer.")
    print("Run: pastebin put " .. OUTPUT_FILE)
  else
    print("Uploading with the built-in pastebin program...")
    local uploaded = shell.run("pastebin", "put", OUTPUT_FILE)
    if not uploaded then print("Upload failed. Run manually: pastebin put " .. OUTPUT_FILE) end
  end
else
  print("To upload it, run: pastebin put " .. OUTPUT_FILE)
  print("Or rerun: ae2-dump upload")
end
