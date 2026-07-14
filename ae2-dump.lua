-- AE2 / Advanced Peripherals one-shot exploratory JSON dumper
-- Produces a bounded, paste-ready snapshot without filling the computer disk.

local args = {...}
local OUTPUT_FILE = args[1] and args[1] ~= "upload" and args[1] or "ae2-dump.json"
local SHOULD_UPLOAD = args[1] == "upload" or args[2] == "upload"

local MAX_DEPTH = 8
local MAX_FULL_TABLE_ENTRIES = 180
local SAMPLE_ENTRIES = 24
local TOP_AMOUNT_ENTRIES = 30
local MAX_STRING_LENGTH = 4000
local MAX_OUTPUT_BYTES = 900000
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

local function jsonEscape(text)
  text = tostring(text or "")
  text = string.gsub(text, "\\", "\\\\")
  text = string.gsub(text, "\"", "\\\"")
  text = string.gsub(text, "\b", "\\b")
  text = string.gsub(text, "\f", "\\f")
  text = string.gsub(text, "\n", "\\n")
  text = string.gsub(text, "\r", "\\r")
  text = string.gsub(text, "\t", "\\t")
  text = string.gsub(text, "[%z\1-\31]", function(c)
    return string.format("\\u%04x", string.byte(c))
  end)
  return text
end

local function isArray(value)
  if type(value) ~= "table" then return false, 0 end
  local count, maxIndex = 0, 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false, 0 end
    count = count + 1
    if key > maxIndex then maxIndex = key end
  end
  return count == maxIndex, maxIndex
end

local jsonEncode

jsonEncode = function(value, indent)
  indent = indent or 0
  local valueType = type(value)
  if valueType == "nil" then return "null" end
  if valueType == "boolean" then return value and "true" or "false" end
  if valueType == "number" then
    if value ~= value or value == math.huge or value == -math.huge then return "null" end
    return tostring(value)
  end
  if valueType == "string" then return "\"" .. jsonEscape(value) .. "\"" end
  if valueType ~= "table" then return "\"" .. jsonEscape("<" .. valueType .. ": " .. safeToString(value) .. ">") .. "\"" end

  local pad = string.rep("  ", indent)
  local childPad = string.rep("  ", indent + 1)
  local array, maxIndex = isArray(value)
  local parts = {}

  if array then
    for i = 1, maxIndex do
      parts[#parts + 1] = childPad .. jsonEncode(value[i], indent + 1)
    end
    if #parts == 0 then return "[]" end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
  end

  for _, key in ipairs(sortedKeys(value)) do
    parts[#parts + 1] = childPad .. "\"" .. jsonEscape(safeToString(key)) .. "\": " .. jsonEncode(value[key], indent + 1)
  end
  if #parts == 0 then return "{}" end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
end

local function serializeJson(value)
  local fn = textutils and (textutils.serializeJSON or textutils.serialiseJSON)
  if type(fn) == "function" then
    local ok, result = pcall(fn, value)
    if ok and type(result) == "string" then return result end
  end
  return jsonEncode(value, 0)
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

local function returnedValues(returned)
  local values = {count = returned.n, values = {}}
  for i = 1, returned.n do values.values[i] = sanitize(returned[i]) end
  return values
end

local function collectReturnedTaskIds(returned, taskIds)
  for i = 1, returned.n do collectTaskIds(returned[i], taskIds) end
end

local function callAndCapture(name, method, args)
  args = args or {}
  local unpackArgs = table.unpack or unpack
  local result = pack(pcall(peripheral.call, name, method, unpackArgs(args)))
  if not result[1] then
    return {ok = false, error = safeToString(result[2])}
  end
  local returned = {n = result.n - 1}
  for i = 2, result.n do returned[i - 1] = result[i] end
  return {ok = true, returned = returnedValues(returned), rawReturned = returned}
end

local function captureProbe(name, method, args)
  local captured = callAndCapture(name, method, args)
  local rawReturned = captured.rawReturned
  captured.rawReturned = nil
  return captured, rawReturned
end

local function methodExists(methods, wanted)
  for _, method in ipairs(methods or {}) do
    if method == wanted then return true end
  end
  return false
end

local function addTargetedProbe(probes, bridgeName, methods, method, args, note)
  if not methodExists(methods, method) then return end
  local captured = captureProbe(bridgeName, method, args)
  probes[#probes + 1] = {
    method = method,
    args = sanitize(args or {}),
    note = note,
    result = captured
  }
  checkpoint(true)
end

local function runDump()
  local startClock = os.clock()
  local dump = {
    schema = "ae2-cc-monitor.exploratory-dump.v1",
    meta = {
      generatedBy = "ae2-dump.lua",
      purpose = "Explore Advanced Peripherals ME Bridge accessible data for items, fluids, chemicals, FE, cells, CPUs, and method shapes.",
      readOnlyMethodsOnly = true,
      outputFile = OUTPUT_FILE,
      outputBudgetBytes = outputBudget,
      maxDepth = MAX_DEPTH,
      maxFullTableEntries = MAX_FULL_TABLE_ENTRIES,
      sampleEntries = SAMPLE_ENTRIES,
      topAmountEntries = TOP_AMOUNT_ENTRIES,
      computerId = os.getComputerID and os.getComputerID() or nil,
      computerLabel = os.getComputerLabel and os.getComputerLabel() or nil,
      craftOs = os.version and os.version() or nil,
      epochUtc = os.epoch and os.epoch("utc") or nil
    },
    peripherals = {},
    bridges = {},
    summary = {}
  }

  local names = peripheral.getNames()
  table.sort(names)

  local bridgeRefs = {}
  for _, name in ipairs(names) do
    local types = peripheralTypes(name)
    local methods = peripheral.getMethods(name) or {}
    table.sort(methods)
    dump.peripherals[#dump.peripherals + 1] = {
      name = name,
      types = types,
      methods = methods,
      methodCount = #methods
    }
    if contains(types, "me_bridge") then
      bridgeRefs[#bridgeRefs + 1] = {name = name, methods = methods, types = types}
    end
    checkpoint()
  end

  for _, bridge in ipairs(bridgeRefs) do
    local bridgeDump = {
      name = bridge.name,
      types = bridge.types,
      methods = bridge.methods,
      readOnlyResults = {},
      targetedProbes = {},
      deepCraftingTaskLookups = {}
    }
    local taskIds = {}

    for _, method in ipairs(bridge.methods) do
      if isReadOnlyMethod(method) then
        local captured, rawReturned = captureProbe(bridge.name, method)
        bridgeDump.readOnlyResults[method] = captured
        if rawReturned then collectReturnedTaskIds(rawReturned, taskIds) end
        checkpoint(true)
      end
    end

    local noArgTargets = {
      "listItems", "getItems", "listFluids", "getFluids", "listChemicals", "getChemicals",
      "listCells", "getCells", "listCraftingCPUs", "getCraftingCPUs", "getEnergyStorage",
      "getMaxEnergyStorage", "getEnergyUsage", "getAvgPowerInjection", "getAvgPowerUsage"
    }
    for _, method in ipairs(noArgTargets) do
      addTargetedProbe(bridgeDump.targetedProbes, bridge.name, bridge.methods, method, {}, "targeted no-arg AE2/FE/fluid inventory probe")
    end

    local filters = {
      {name = "appflux:fe"},
      {id = "appflux:fe"},
      {fingerprint = "appflux:fe"},
      {resource = "appflux:fe"},
      {type = "appflux:fe"},
      {name = "appflux:fe", displayName = "FE"},
      "appflux:fe",
      {name = "ae2:charged_certus_quartz_crystal"},
      {name = "minecraft:water"},
      {name = "minecraft:lava"}
    }
    local filteredMethods = {
      "getItem", "getFluid", "getChemical", "getAmount", "getItemDetail",
      "getFluidDetail", "getChemicalDetail"
    }
    for _, method in ipairs(filteredMethods) do
      if methodExists(bridge.methods, method) then
        for _, filter in ipairs(filters) do
          addTargetedProbe(bridgeDump.targetedProbes, bridge.name, bridge.methods, method, {filter}, "known-value filter shape probe")
        end
      end
    end

    local orderedIds = {}
    for id in pairs(taskIds) do orderedIds[#orderedIds + 1] = id end
    table.sort(orderedIds)
    local taskMethods = {}
    for _, method in ipairs({"getCraftingTask", "getCraftingJob"}) do
      if methodExists(bridge.methods, method) then taskMethods[#taskMethods + 1] = method end
    end
    for _, id in ipairs(orderedIds) do
      for _, method in ipairs(taskMethods) do
        local captured = captureProbe(bridge.name, method, {id})
        bridgeDump.deepCraftingTaskLookups[#bridgeDump.deepCraftingTaskLookups + 1] = {
          method = method,
          args = {id},
          result = captured
        }
        checkpoint(true)
      end
    end

    dump.bridges[#dump.bridges + 1] = bridgeDump
  end

  dump.summary = {
    peripheralCount = #names,
    meBridgeCount = #bridgeRefs,
    elapsedSeconds = tonumber(string.format("%.3f", os.clock() - startClock)),
    bytesWrittenBeforeJson = bytesWritten
  }

  local encoded = serializeJson(dump)
  if #encoded > outputBudget then
    dump.meta.truncated = true
    dump.meta.truncatedReason = "Encoded JSON exceeded output budget; readOnlyResults were removed but targetedProbes were kept."
    for _, bridgeDump in ipairs(dump.bridges) do
      bridgeDump.readOnlyResults = {
        __removed = "Removed to fit output budget",
        methodCount = #(bridgeDump.methods or {})
      }
    end
    encoded = serializeJson(dump)
  end
  writeRaw(encoded)
  writeRaw("\n")
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
