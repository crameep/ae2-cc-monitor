  if seconds >= 3600 then
    return string.format("%dh %02dm", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
  elseif seconds >= 60 then
    return string.format("%dm %02ds", math.floor(seconds / 60), seconds % 60)
  end
  return tostring(seconds) .. "s"
end

local function fmtRate(rate)
  rate = n(rate)
  if rate <= 0 then return "--/s" end
  if rate < 0.1 then return string.format("%.2f/s", rate) end
  if rate < 10 then return string.format("%.1f/s", rate) end
  return fmt(rate) .. "/s"
end

local function collectResources(value, out, depth)
  out = out or {}
  depth = depth or 0
  if depth > 3 or type(value) ~= "table" then return out end

  local name = firstField(value, {"displayName", "name", "id", "resource"}, nil)
  local amount = firstField(value, {"amount", "count", "quantity", "qty", "crafted"}, nil)
  if name ~= nil and (amount ~= nil or depth > 0) then
    out[#out + 1] = {name = cleanLabel(name), amount = n(amount)}
    return out
  end

  for _, child in pairs(value) do
    if type(child) == "table" then collectResources(child, out, depth + 1) end
  end
  return out
end

local function resourceSummary(prefix, value, maxItems)
  local rows = collectResources(value, {}, 0)
  table.sort(rows, function(a, b) return a.amount > b.amount end)
  if #rows == 0 then return nil end
  local parts = {}
  for i = 1, math.min(#rows, maxItems or 2) do
    local amount = rows[i].amount > 0 and (" " .. fmt(rows[i].amount)) or ""
    parts[#parts + 1] = rows[i].name .. amount
  end
  return prefix .. table.concat(parts, ", ")
end

local function taskDetailObject(task, bridgeId, id)
  if type(task) == "table" and (
    type(task.getUsedItems) == "function" or
    type(task.getEmittedItems) == "function" or
    type(task.getMissingItems) == "function") then
    return task
  end

  local lookupId = nil
  local numericBridgeId = tonumber(bridgeId)
  if numericBridgeId and numericBridgeId >= 0 then
    lookupId = numericBridgeId
  elseif tonumber(id) then
    lookupId = tonumber(id)
  end
  if lookupId ~= nil then
    local detail = callAnyArg({"getCraftingTask", "getCraftingJob"}, lookupId, nil)
    if type(detail) == "table" then return detail end
  end
  return task
end

local function normalizeTask(task, index)
  task = type(task) == "table" and task or {}
  local bridgeId = firstField(task, {"bridge_id", "bridgeId"}, -1)
  local id = firstField(task, {"id", "jobId", "taskId"}, nil)
  if id == nil then id = methodValue(task, {"getId"}, nil) end

  local resource = firstField(task, {"resource", "requested", "requestedItem", "output", "finalOutput"}, nil)
  if resource == nil then resource = methodValue(task, {"getRequestedItem", "getFinalOutput"}, nil) end
  local label = type(resource) == "table" and itemLabel(resource) or cleanLabel(resource or ("Crafting Job " .. index))

  local quantity = n(firstField(task, {"quantity", "total", "totalItems", "count", "amount"}, 0))
  if quantity <= 0 then quantity = n(methodValue(task, {"getTotalItems"}, 0)) end
  if quantity <= 0 and type(resource) == "table" then quantity = amountOf(resource) end

  local crafted = n(firstField(task, {"crafted", "itemProgress", "completed", "done"}, 0))
  if crafted <= 0 then crafted = n(methodValue(task, {"getItemProgress"}, 0)) end

  local completion = n(firstField(task, {"completion", "percent", "percentage", "progress"}, 0))
  if completion > 1 then completion = completion / 100 end
  if completion <= 0 and quantity > 0 then completion = crafted / quantity end
  completion = math.max(0, math.min(1, completion))
  if crafted <= 0 and quantity > 0 and completion > 0 then
    crafted = quantity * completion
  end

  local cpu = firstField(task, {"cpu", "craftingCpu", "craftingCPU"}, nil)
  local cpuName = firstField(task, {"cpuName"}, nil)
  if type(cpu) == "table" then
    cpuName = firstField(cpu, {"name", "displayName"}, cpuName)
  elseif type(cpu) == "string" then
    cpuName = cpu
  end
  cpuName = cleanLabel(cpuName or "Automatic CPU")

  local elapsed = n(firstField(task, {"elapsed", "elapsedTime", "time"}, 0))
  if elapsed <= 0 then elapsed = n(methodValue(task, {"getElapsedTime"}, 0)) end
  if elapsed > 100000 then elapsed = elapsed / 1000 end

  local usedBytes = n(firstField(task, {"usedBytes", "bytes"}, 0))
  if usedBytes <= 0 then usedBytes = n(methodValue(task, {"getUsedBytes"}, 0)) end

  local debug = firstField(task, {"debugMessage", "message", "state", "status"}, nil)
  if debug == nil then debug = methodValue(task, {"getDebugMessage"}, nil) end

  local detail = taskDetailObject(task, bridgeId, id)
  local missing = methodValue(detail, {"getMissingItems"}, nil)
  local emitted = methodValue(detail, {"getEmittedItems"}, nil)
  local used = methodValue(detail, {"getUsedItems"}, nil)
  local subparts = resourceSummary("Missing: ", missing, 2)
    or resourceSummary("Produced: ", emitted, 2)
    or resourceSummary("Using: ", used, 2)

  local identity = id
  local numericBridgeId = tonumber(bridgeId)
  if identity == nil and numericBridgeId and numericBridgeId >= 0 then identity = numericBridgeId end
  local key = tostring(identity or (label .. ":" .. tostring(quantity) .. ":" .. tostring(cpuName)))
  local now = nowSeconds()
  local previous = craftHistory[key]
  local rate = previous and n(previous.rate) or 0
  if previous and crafted >= n(previous.crafted) and now > n(previous.time) then
    local instant = (crafted - n(previous.crafted)) / (now - n(previous.time))
    if instant > 0 then
      rate = rate > 0 and ((rate * 0.65) + (instant * 0.35)) or instant
    end
  elseif not previous and elapsed > 0 and crafted > 0 then
    rate = crafted / elapsed
  end
  craftHistory[key] = {crafted = crafted, time = now, rate = rate, seen = now}

  local remaining = math.max(0, quantity - crafted)
  local eta = rate > 0 and remaining / rate or 0

  return {
    key = key,
    id = id,
    bridgeId = bridgeId,
    name = label,
    quantity = quantity,
    crafted = crafted,
    completion = completion,
    cpu = cpuName,
    usedBytes = usedBytes,
    elapsed = elapsed,
    rate = rate,
    eta = eta,
    subparts = subparts,
    debug = debug
  }
end

local function cpuBusy(cpu)
  local value = firstField(cpu, {"isBusy", "busy"}, nil)
  if value ~= nil then return value == true end
  return methodValue(cpu, {"isBusy"}, false) == true
end

local function normalizeCpus(cpus)
  local normalized = {}
  for _, cpu in pairs(cpus or {}) do
    if type(cpu) == "table" then normalized[#normalized + 1] = cpu end
  end
  table.sort(normalized, function(a, b)
    local an = cleanLabel(firstField(a, {"name", "displayName"}, "Unnamed CPU"))
    local bn = cleanLabel(firstField(b, {"name", "displayName"}, "Unnamed CPU"))
    return an < bn
  end)
  return normalized
end

local function normalizeTasks(tasks, cpus)
  local sources = {}
  for _, task in pairs(tasks or {}) do
    if type(task) == "table" then sources[#sources + 1] = task end
  end

  -- Some Advanced Peripherals/AE2 combinations report terminal-started jobs
  -- on the crafting CPU object even when getCraftingTasks() is empty.
  for _, cpu in pairs(cpus or {}) do
    local job = firstField(cpu, {"craftingJob", "job", "task"}, nil)
    if job == nil then job = methodValue(cpu, {"getCraftingJob", "getJob"}, nil) end
    if type(job) == "table" then
      local copy = {}
      for key, value in pairs(job) do copy[key] = value end
      if copy.cpu == nil and copy.craftingCpu == nil and copy.craftingCPU == nil then copy.cpu = cpu end
      sources[#sources + 1] = copy
    end
  end

  local normalized = {}
  local seen = {}
  for _, task in ipairs(sources) do
