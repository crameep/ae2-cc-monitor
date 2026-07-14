local function runUpdater()
  if not http or not http.get then
    setStatus("HTTP disabled; use wget")
    return true
  end

  local function readUrl(url)
    local headers = {["User-Agent"] = "ae2-cc-monitor"}
    local res = http.get(url, headers)
    if not res then res = http.get(url) end
    if not res then return nil end
    local body = res.readAll()
    res.close()
    return body
  end

  local function latestCommitSha()
    local body = readUrl(GITHUB_COMMIT_API .. "?v=" .. tostring(os.epoch and os.epoch("utc") or os.time()))
    if not body then return nil end
    return string.match(body, '"sha"%s*:%s*"([0-9a-f]+)"')
  end

  local function manifestFor(ref)
    local url = RAW_BASE_URL .. "/" .. ref .. "/" .. MANIFEST_FILE .. "?v=" .. tostring(os.epoch and os.epoch("utc") or os.time())
    local body = readUrl(url)
    if not body then return nil end
    local startupPath = string.match(body, '"startup"%s*:%s*"([^"]+)"') or "startup.lua"
    local version = string.match(body, '"version"%s*:%s*"([^"]+)"') or ref
    return {version = version, startupPath = startupPath}
  end

  setStatus("Resolving latest version...")
  local ref = latestCommitSha()
  local manifest = ref and manifestFor(ref) or nil
  local url
  if ref and manifest then
    url = RAW_BASE_URL .. "/" .. ref .. "/" .. manifest.startupPath
    setStatus("Updating to " .. manifest.version .. "...")
  else
    url = UPDATE_URL .. "?v=" .. tostring(os.epoch and os.epoch("utc") or os.time())
    setStatus("Manifest failed; using raw main...")
  end

  local body = readUrl(url)
  if not body then
    setStatus("Update failed")
    return true
  end
  if not body or #body < 1000 or not string.find(body, "AE2 Visual Monitor", 1, true) then
    setStatus("Bad update file")
    return true
  end

  local h = fs.open("startup.lua", "w")
  if not h then
    setStatus("Cannot write startup.lua")
    return true
  end
  h.write(body)
  h.close()
  os.reboot()
  return true
end

local function downloadDumpScript()
  if not http or not http.get then return false, "HTTP is disabled" end
  local url = DUMP_URL .. "?v=" .. tostring(os.epoch and os.epoch("utc") or os.time())
  local res, err = http.get(url)
  if not res then return false, err or "Download failed" end
  local body = res.readAll()
  res.close()
  if not body or #body < 3000 or not string.find(body, "AE2 / Advanced Peripherals", 1, true) then
    return false, "Downloaded diagnostic was invalid"
  end
  if fs.exists(DUMP_SCRIPT) then fs.delete(DUMP_SCRIPT) end
  local h = fs.open(DUMP_SCRIPT, "w")
  if not h then return false, "Cannot write " .. DUMP_SCRIPT end
  h.write(body)
  h.close()
  return true
end

local function readDumpPreview()
  if not fs.exists(DUMP_FILE) or fs.isDir(DUMP_FILE) then return nil end
  local h = fs.open(DUMP_FILE, "r")
  if not h then return nil end
  local body = h.readAll() or ""
  h.close()
  body = string.gsub(body, "\n", " ")
  body = string.gsub(body, "%s+", " ")
  if body == "" then return nil end
  return string.sub(body, 1, 160)
end

local function loadPastebinKey()
  if not fs.exists(PASTEBIN_KEY_FILE) then return nil end
  local h = fs.open(PASTEBIN_KEY_FILE, "r")
  if not h then return nil end
  local key = h.readAll() or ""
  h.close()
  key = string.gsub(key, "%s+", "")
  if key == "" then return nil end
  return key
end

local function pastebinUrlFromOutput(output)
  output = tostring(output or "")
  local url = string.match(output, "https?://pastebin%.com/raw/[%w]+")
    or string.match(output, "https?://pastebin%.com/[%w]+")
  if url then return string.gsub(url, "/raw/", "/") end
  local code = string.match(output, "pastebin%.com/([%w]+)")
    or string.match(output, "Uploaded as%s+([%w]+)")
    or string.match(output, "uploaded as%s+([%w]+)")
  if code then return "https://pastebin.com/" .. code end
  return nil
end

local function uploadDumpWithPastebinProgram()
  if not shell or not shell.run then return nil, "shell.run unavailable" end
  if not term or not term.redirect or not term.current then return nil, "term redirect unavailable" end

  local oldTerm = term.current()
  local output = {}
  local capture = {}
  function capture.write(text) output[#output + 1] = tostring(text or "") end
  function capture.blit(text) output[#output + 1] = tostring(text or "") end
  function capture.clear() end
  function capture.clearLine() end
  function capture.scroll() end
  function capture.setCursorPos() end
  function capture.setCursorBlink() end
  function capture.setTextColor() end
  function capture.setBackgroundColor() end
  function capture.getCursorPos() return 1, 1 end
  function capture.getSize() return 80, 24 end
  function capture.isColor() return false end
  function capture.isColour() return false end
  function capture.getTextColor() return colors.white end
  function capture.getTextColour() return colors.white end
  function capture.getBackgroundColor() return colors.black end
  function capture.getBackgroundColour() return colors.black end

  local redirected = pcall(term.redirect, capture)
  local ran, result = pcall(shell.run, "pastebin", "put", DUMP_FILE)
  if redirected then pcall(term.redirect, oldTerm) end

  local text = table.concat(output)
  local url = pastebinUrlFromOutput(text)
  if ran and result ~= false and url then return url end
  if url then return url end
  if text ~= "" then return nil, text end
  return nil, ran and "pastebin put failed" or tostring(result)
end

local function uploadDumpToPastebin()
  local pastebinKey = loadPastebinKey()
  if not fs.exists(DUMP_FILE) or fs.isDir(DUMP_FILE) then return nil, "Diagnostic file was not created" end
  local h = fs.open(DUMP_FILE, "r")
  if not h then return nil, "Cannot read " .. DUMP_FILE end
  local body = h.readAll()
  h.close()
  lastDumpSize = #body
  if #body < 100 then return nil, "Diagnostic file is empty" end

  local apiError = nil
  if pastebinKey and http and http.post then
    local response, err = http.post(
      "https://pastebin.com/api/api_post.php",
      "api_option=paste&" ..
      "api_dev_key=" .. textutils.urlEncode(pastebinKey) .. "&" ..
      "api_paste_format=javascript&" ..
      "api_paste_name=" .. textutils.urlEncode("AE2 diagnostic " .. tostring(os.getComputerID())) .. "&" ..
      "api_paste_code=" .. textutils.urlEncode(body)
    )
    if response then
      local result = response.readAll()
      response.close()
      if result and string.match(result, "^https?://pastebin%.com/[%a%d]+$") then
        return result
      end
      apiError = result or "Pastebin returned no link"
    else
      apiError = err or "Pastebin API upload failed"
    end
  elseif pastebinKey then
    apiError = "HTTP POST is disabled"
  end

  local url, fallbackError = uploadDumpWithPastebinProgram()
  if url then return url end
  if apiError then return nil, apiError .. " | pastebin program: " .. tostring(fallbackError) end
  return nil, tostring(fallbackError or ("Missing " .. PASTEBIN_KEY_FILE))
end

local function runDiagnosticUpload()
  if toolBusy then
    setStatus("Diagnostic already running")
    return true
  end
  toolBusy = true
  lastPasteError = nil
  lastDumpPreview = nil
  setStatus("Downloading diagnostic tool...")

  local ok, err = downloadDumpScript()
  if not ok then
    toolBusy = false
    lastPasteError = tostring(err)
    setStatus("Dump failed: " .. lastPasteError)
    return true
  end

  if fs.exists(DUMP_FILE) then fs.delete(DUMP_FILE) end
  setStatus("Collecting AE2 diagnostic...")
  local ran, runResult = pcall(shell.run, DUMP_SCRIPT, DUMP_FILE)
  if not ran or runResult == false or not fs.exists(DUMP_FILE) then
    toolBusy = false
    lastPasteError = ran and "Diagnostic script failed" or tostring(runResult)
    setStatus("Dump failed: " .. lastPasteError, 30)
    return true
  end
  lastDumpSize = fs.getSize(DUMP_FILE) or 0
  lastDumpPreview = readDumpPreview()

  setStatus("Uploading diagnostic to Pastebin...")
  local url, uploadError = uploadDumpToPastebin()
  toolBusy = false
  if not url then
    lastPasteError = tostring(uploadError)
    setStatus("Saved " .. DUMP_FILE .. "; upload failed", 30)
    return true
  end

  lastPasteUrl = url
  lastPasteError = nil
  local h = fs.open(LAST_PASTE_FILE, "w")
  if h then h.write(url); h.close() end
  setStatus("Paste ready: " .. url, 30)
  return true
end

local function ignoreWarning(button)
  usageState.ignored[button.key] = button.name or true
  usageState.tracked[button.key] = nil
  usageState.warnings = filteredWarnings(usageState.warnings)
  saveState(usageState)
  setStatus("Ignored: " .. tostring(button.name or button.key))
end

local function toggleBulk(button)
  local state = cycleBulkHint(button.key, button.name, button.cellState)
  if state == nil then
    setStatus("Could not save bulk marker")
  elseif state == "bulk" then
    setStatus("Bulk marker added: " .. button.name)
  elseif state == "inf" then
    setStatus("Infinity marker added: " .. button.name)
  else
    setStatus("Cell marker cleared: " .. button.name)
  end
end

local function handleTouch(screen, x, y)
  for _, button in ipairs(uiButtons[screen] or {}) do
    if y >= button.y and y <= (button.y2 or button.y) and x >= button.x and x <= button.x2 then
      if button.action == "nav" then
        currentPages[screen] = button.page
      elseif button.action == "page" then
        setListPage(screen, button.page, button.delta)
      elseif button.action == "subtab" then
        setSectionTab(screen, button.page, button.tab)
      elseif button.action == "ignore" then
        ignoreWarning(button)
      elseif button.action == "bulk" then
        toggleBulk(button)
      elseif button.action == "update" then
        return runUpdater()
      elseif button.action == "diagnostic" then
        if toolBusy or diagnosticRequested then
          setStatus("Diagnostic already running", 30)
        else
          diagnosticRequested = true
          setStatus("Diagnostic queued...", 30)
        end
      end
      return true
    end
  end
  return false
end

local function updateUsage(items)
  local now = nowSeconds()
  if usageState.lastSample and now - usageState.lastSample < SAMPLE_SECONDS then
    usageState.warnings = filteredWarnings(usageState.warnings)
    return usageState.warnings or {}, usageState.recent or {}, usageState.movers or {}
  end

  local current = {}
  local warnings = {}
  local recent = {}
  local movers = {}
  local elapsed = math.max(1, now - n(usageState.lastSample))
  usageState.recentCandidates = usageState.recentCandidates or {}
  for _, item in pairs(items or {}) do
    local key = itemKey(item)
    local amount = amountOf(item)
    if amount > 0 then
      current[key] = amount
      local prior = usageState.last[key]
      local label = itemLabel(item)
      local watchable = shouldWatchItem(key, label)
      if prior and amount ~= prior then
        local delta = amount - prior
        movers[#movers + 1] = {
          key = key,
          name = label,
          delta = delta,
          amount = amount,
          perMinute = delta / elapsed * 60,
          perHour = delta / elapsed * 3600,
          score = math.abs(delta / elapsed)
        }
      end
      if prior and not usageState.ignored[key] and watchable then
        local tracked = usageState.tracked[key] or {name = label, consumed = 0, lastDrop = 0, left = amount, samples = 0, dropEvents = 0}
        tracked.name = label
        tracked.samples = n(tracked.samples) + 1
        tracked.left = amount
        tracked.lastSeen = now

        if amount < prior then
          local drop = prior - amount
          if drop >= RECENT_DROP then
            local candidate = usageState.recentCandidates[key] or {name = label, firstSeen = now, totalDrop = 0, dropEvents = 0}
            if now - n(candidate.firstSeen) > RECENT_CONFIRM_SECONDS then
              candidate = {name = label, firstSeen = now, totalDrop = 0, dropEvents = 0}
            end
            candidate.name = label
            candidate.totalDrop = n(candidate.totalDrop) + drop
            candidate.dropEvents = n(candidate.dropEvents) + 1
            candidate.lastDrop = drop
            candidate.left = amount
            candidate.lastSeen = now
            usageState.recentCandidates[key] = candidate
            if n(candidate.dropEvents) >= RECENT_EVENTS_REQUIRED then
              recent[#recent + 1] = {
                key = key,
                name = label,
                drop = candidate.totalDrop,
                left = amount,
                score = candidate.totalDrop
              }
            end
          end
          if drop >= MIN_REAL_DROP then
            tracked.consumed = n(tracked.consumed) + drop
            tracked.dropEvents = n(tracked.dropEvents) + 1
            tracked.lastDrop = drop
          else
            tracked.lastDrop = 0
          end
        elseif amount > prior then
          usageState.recentCandidates[key] = nil
          tracked.lastDrop = 0
          tracked.dropEvents = math.max(0, n(tracked.dropEvents) - 1)
          tracked.consumed = math.floor(n(tracked.consumed) * 0.5)
        else
          tracked.lastDrop = 0
        end

        usageState.tracked[key] = tracked

        local bigDrop = n(tracked.lastDrop) >= math.max(FAST_DROP, amount * 0.10)
        local learned = n(tracked.samples) >= WARMUP_SAMPLES
        local repeatedDrops = n(tracked.dropEvents) >= DROP_EVENTS_REQUIRED
        local heavyUse = n(tracked.consumed) >= CONSUMED_WATCH
        local lowStock = amount <= LOW_STOCK
        if learned and repeatedDrops and heavyUse and (lowStock or bigDrop) then
          warnings[#warnings + 1] = {
            key = key,
            name = label,
            drop = n(tracked.lastDrop),
            left = amount,
            consumed = tracked.consumed,
            score = (lowStock and 100000000 or 0) + n(tracked.lastDrop) + tracked.consumed
          }
        end
      end
    end
  end

  for key, tracked in pairs(usageState.tracked or {}) do
    if tracked.lastSeen and now - tracked.lastSeen > 86400 then
      usageState.tracked[key] = nil
    end
  end
  for key, candidate in pairs(usageState.recentCandidates or {}) do
    if candidate.lastSeen and now - candidate.lastSeen > RECENT_CONFIRM_SECONDS then
      usageState.recentCandidates[key] = nil
    end
  end

  table.sort(warnings, function(a, b) return a.score > b.score end)
  table.sort(recent, function(a, b) return a.score > b.score end)
  table.sort(movers, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.name < b.name
  end)
  usageState.stateVersion = STATE_VERSION
  usageState.last = current
  usageState.lastSample = now
  usageState.warnings = warnings
  usageState.recent = recent
  usageState.movers = movers
  saveState(usageState)
  return warnings, recent, movers
end

local function updateFluidMovers(fluids)
  local now = nowSeconds()
  usageState.lastFluids = usageState.lastFluids or {}
  if usageState.lastFluidSample and now - usageState.lastFluidSample < SAMPLE_SECONDS then
    return usageState.fluidMovers or {}
  end

  local current = {}
  local movers = {}
  local elapsed = math.max(1, now - n(usageState.lastFluidSample))
  for _, fluid in pairs(fluids or {}) do
    local key = "fluid:" .. itemKey(fluid)
    local amount = amountOf(fluid)
    if amount > 0 then
      current[key] = amount
      local prior = usageState.lastFluids[key]
      if prior and amount ~= prior then
        local delta = amount - prior
        movers[#movers + 1] = {
          key = key,
          name = itemLabel(fluid),
          delta = delta,
          amount = amount,
          perMinute = delta / elapsed * 60,
          perHour = delta / elapsed * 3600,
          score = math.abs(delta / elapsed)
        }
      end
    end
  end
  table.sort(movers, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.name < b.name
  end)
  usageState.lastFluids = current
  usageState.lastFluidSample = now
  usageState.fluidMovers = movers
  saveState(usageState)
  return movers
end

local function duration(seconds)
  seconds = math.max(0, math.floor(n(seconds) + 0.5))
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
  local resourceName = type(resource) == "table" and tostring(resource.name or resource.id or "") or tostring(resource or "")
  local resourceFingerprint = type(resource) == "table" and tostring(resource.fingerprint or "") or ""

  local quantity = n(firstField(task, {"quantity", "total", "totalItems", "count", "amount"}, 0))
  if quantity <= 0 then quantity = n(methodValue(task, {"getTotalItems"}, 0)) end
  if quantity <= 0 and type(resource) == "table" then quantity = amountOf(resource) end

  local rawCrafted = firstField(task, {"crafted", "itemProgress", "completed", "done"}, nil)
  if rawCrafted == nil and type(task.getItemProgress) == "function" then rawCrafted = methodValue(task, {"getItemProgress"}, nil) end
  local rawCompletion = firstField(task, {"completion", "percent", "percentage", "progress"}, nil)
  local progressKnown = rawCrafted ~= nil or rawCompletion ~= nil
  local crafted = n(rawCrafted)
  local completion = n(rawCompletion)
  if completion > 1 then completion = completion / 100 end
  if progressKnown and completion <= 0 and quantity > 0 then completion = crafted / quantity end
  completion = math.max(0, math.min(1, completion))
  if progressKnown and crafted <= 0 and quantity > 0 and completion > 0 then crafted = quantity * completion end

  local cpu = firstField(task, {"cpu", "craftingCpu", "craftingCPU"}, nil)
  local cpuName = firstField(task, {"cpuName"}, nil)
  local cpuStorage, cpuCoProcessors = 0, 0
  if type(cpu) == "table" then
    cpuName = firstField(cpu, {"_monitorName", "name", "displayName"}, cpuName)
    cpuStorage = n(firstField(cpu, {"storage", "bytes"}, 0))
    cpuCoProcessors = n(firstField(cpu, {"coProcessors", "coprocessors"}, 0))
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
  local key = tostring(identity or (resourceName .. ":" .. tostring(quantity) .. ":" .. tostring(cpuName)))
  local now = nowSeconds()
  local rate = 0
  if progressKnown then
    local previous = craftHistory[key]
    rate = previous and n(previous.rate) or 0
    if previous and crafted >= n(previous.crafted) and now > n(previous.time) then
      local instant = (crafted - n(previous.crafted)) / (now - n(previous.time))
      if instant > 0 then rate = rate > 0 and ((rate * 0.65) + (instant * 0.35)) or instant end
    elseif not previous and elapsed > 0 and crafted > 0 then
      rate = crafted / elapsed
    end
    craftHistory[key] = {crafted = crafted, time = now, rate = rate, seen = now}
  end

  local remaining = math.max(0, quantity - crafted)
  local eta = rate > 0 and remaining / rate or 0

  return {
    key = key,
    id = id,
    bridgeId = bridgeId,
    name = label,
    resourceName = resourceName,
    resourceFingerprint = resourceFingerprint,
    quantity = quantity,
    crafted = crafted,
    completion = completion,
    progressKnown = progressKnown,
    cpu = cpuName,
    cpuStorage = cpuStorage,
    cpuCoProcessors = cpuCoProcessors,
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
    local an = cleanLabel(firstField(a, {"name", "displayName"}, "Unnamed"))
    local bn = cleanLabel(firstField(b, {"name", "displayName"}, "Unnamed"))
    if an ~= bn then return an < bn end
    return n(firstField(a, {"storage", "bytes"}, 0)) < n(firstField(b, {"storage", "bytes"}, 0))
  end)
  for index, cpu in ipairs(normalized) do
    local rawName = cleanLabel(firstField(cpu, {"name", "displayName"}, "Unnamed"))
    if string.lower(rawName) == "unnamed" or string.lower(rawName) == "unknown" then rawName = "CPU " .. index end
    cpu._monitorIndex = index
    cpu._monitorName = rawName
  end
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
    local row = normalizeTask(task, #normalized + 1)
    if not seen[row.key] then
      seen[row.key] = true
      normalized[#normalized + 1] = row
    end
  end
  table.sort(normalized, function(a, b)
    if a.completion ~= b.completion then return a.completion > b.completion end
    return a.name < b.name
  end)

  local now = nowSeconds()
  for key, history in pairs(craftHistory) do
    if now - n(history.seen) > 180 then craftHistory[key] = nil end
  end
  return normalized
end

local function getPatternCache()
  local now = nowSeconds()
  if now - patternCacheTime >= PATTERN_REFRESH_SECONDS or next(patternCache) == nil then
    local fresh = call("getPatterns", nil)
    if type(fresh) == "table" then
      patternCache = fresh
      patternCacheTime = now
    end
  end
  return patternCache
end

local function patternIndex(patterns)
  local index = {}
  for _, pattern in pairs(patterns or {}) do
    local output = type(pattern) == "table" and pattern.primaryOutput or nil
    if type(output) == "table" then
      local name = tostring(output.name or output.id or "")
      local fingerprint = tostring(output.fingerprint or "")
      if name ~= "" then index["name:" .. name] = pattern end
      if fingerprint ~= "" then index["fp:" .. fingerprint] = pattern end
    end
  end
  return index
end

local function recipeSummary(task, patternsByOutput)
  local pattern = nil
  if task.resourceFingerprint ~= "" then pattern = patternsByOutput["fp:" .. task.resourceFingerprint] end
  if not pattern and task.resourceName ~= "" then pattern = patternsByOutput["name:" .. task.resourceName] end
  if type(pattern) ~= "table" then return nil end
  local output = pattern.primaryOutput or {}
  local outputCount = math.max(1, amountOf(output))
  local batches = task.quantity > 0 and math.max(1, math.ceil(task.quantity / outputCount)) or 1
  local parts = {}
  for _, input in ipairs(pattern.inputs or {}) do
    local primary = type(input) == "table" and input.primaryInput or nil
    if type(primary) == "table" then
      local amount = math.max(1, n(input.multiplier or 1)) * batches
      parts[#parts + 1] = fmt(amount) .. "x " .. itemLabel(primary)
    end
  end
  if #parts == 0 then return nil end
  return "Recipe: " .. table.concat(parts, ", ", 1, math.min(3, #parts))
end

local function enrichTasks(tasks, items, patterns)
  local amountsByName, amountsByFingerprint = {}, {}
  for _, item in pairs(items or {}) do
    local amount = amountOf(item)
    local name = tostring(item.name or item.id or "")
    local fingerprint = tostring(item.fingerprint or "")
    if name ~= "" then amountsByName[name] = n(amountsByName[name]) + amount end
    if fingerprint ~= "" then amountsByFingerprint[fingerprint] = n(amountsByFingerprint[fingerprint]) + amount end
  end

  local byOutput = patternIndex(patterns)
  local now = nowSeconds()
  for _, task in ipairs(tasks or {}) do
    task.recipe = recipeSummary(task, byOutput)
    if not task.progressKnown then
      local current = task.resourceFingerprint ~= "" and amountsByFingerprint[task.resourceFingerprint] or nil
      if current == nil then current = amountsByName[task.resourceName] or 0 end
      local history = stockCraftHistory[task.key]
      if not history then
        history = {lastAmount = current, estimated = 0, rate = 0, time = now, seen = now}
      elseif now > n(history.time) then
        local delta = current - n(history.lastAmount)
        if delta > 0 then
          history.estimated = n(history.estimated) + delta
          local instant = delta / (now - n(history.time))
          history.rate = n(history.rate) > 0 and (n(history.rate) * 0.65 + instant * 0.35) or instant
        end
        history.lastAmount = current
        history.time = now
        history.seen = now
      end
      stockCraftHistory[task.key] = history
      task.estimatedCrafted = n(history.estimated)
      task.estimatedRate = n(history.rate)
      task.estimatedEta = task.estimatedRate > 0 and math.max(0, task.quantity - task.estimatedCrafted) / task.estimatedRate or 0
    end
  end

  for key, history in pairs(stockCraftHistory) do
    if now - n(history.seen) > 180 then stockCraftHistory[key] = nil end
  end
end

local function centerText(y, text, fg, bg, maxWidth)
  local w = mon.getSize()
  text = tostring(text or "")
  if maxWidth then text = string.sub(text, 1, maxWidth) end
  local x = math.max(1, math.floor((w - #text) / 2) + 1)
  writeAt(x, y, text, fg, bg)
end

local function meter(x, y, width, ratio, color, emptyColor)
  width = math.max(1, width)
  ratio = math.max(0, math.min(1, n(ratio)))
  local filled = math.floor((width * ratio) + 0.5)
  fillRect(x, y, width, 1, emptyColor or colors.gray)
  if filled > 0 then fillRect(x, y, filled, 1, color or colors.green) end
end

local function capacityRow(y, label, used, total, color)
  local w = mon.getSize()
  local labelW = math.min(12, math.max(8, math.floor(w * 0.18)))
  local value = fmt(used) .. "/" .. (n(total) > 0 and fmt(total) or "?")
  local pctText = string.format("%3d%%", math.floor(pct(used, total) + 0.5))
  local rightW = #value + #pctText + 2
  local barX = labelW + 2
  local barW = math.max(4, w - barX - rightW)
  writeAt(2, y, label, colors.white, colors.black, labelW - 1)
  meter(barX, y, barW, pct(used, total) / 100, color, colors.gray)
  writeAt(w - rightW + 1, y, value .. " " .. pctText, colors.white, colors.black, rightW)
end

local function signedFmt(value)
  value = n(value)
  local sign = value >= 0 and "+" or "-"
  return sign .. fmt(math.abs(value))
end

local function rateFmt(value, suffix)
  value = n(value)
  if value == 0 then return "--" .. suffix end
  local mag = math.abs(value)
  local text
  if mag < 1 then
    text = string.format("%.2f", mag)
  elseif mag < 10 then
    text = string.format("%.1f", mag)
  else
    text = fmt(mag)
  end
  return (value >= 0 and "+" or "-") .. text .. suffix
end

local function powerTrendText(stats)
  if stats and not stats.known then return "stored AE hidden" end
  if not stats or not stats.trendReady then return "trend learning" end
  return rateFmt(stats.netPerTick, " AE/t") .. "  " .. rateFmt(stats.netPerMinute, " AE/m")
end

local function powerEtaText(stats)
  if not stats or not stats.trendReady or n(stats.eta) <= 0 then return nil end
  if stats.etaMode == "full" then return "Full in " .. duration(stats.eta) end
  if stats.etaMode == "empty" then return "Empty in " .. duration(stats.eta) end
  return nil
end

local function statusIsActive()
  return statusMessage and nowSeconds() < statusUntil
end

local function drawHeader(screen, page, data)
  local w = mon.getSize()
  clearLine(1, colors.blue)
  writeAt(2, 1, "AE2 // " .. PAGE_TITLES[page], colors.white, colors.blue, math.max(8, w - 18))
  local timeText = textutils.formatTime(os.time(), true)
  writeAt(math.max(1, w - #timeText + 1), 1, timeText, colors.white, colors.blue, #timeText)

  local stripColor = data.healthColor
  clearLine(2, stripColor)
  if statusIsActive() then
    writeAt(2, 2, statusMessage, colors.black, stripColor, w - 2)
  else
    local labelW = math.min(18, math.max(10, math.floor(w * 0.30)))
    writeAt(2, 2, data.health, colors.black, stripColor, labelW)
    writeAt(labelW + 3, 2, data.healthDetail, colors.black, stripColor, math.max(1, w - labelW - 3))
  end
end

local function drawNav(screen, page, h)
  local w = mon.getSize()
  local labels = w >= 68
    and {"OVERVIEW", "CRAFT", "STOCK", "STORAGE", "MOVERS", "SYSTEM", "TOOLS"}
    or {"HOME", "CRAFT", "STOCK", "STORE", "MOVE", "SYS", "MORE"}
  local tabCount = #PAGE_ORDER
  local baseW = math.max(1, math.floor(w / tabCount))
  local extra = w - (baseW * tabCount)
  local x = 1
  for i, pageName in ipairs(PAGE_ORDER) do
    local tabW = baseW
    if i <= extra then tabW = tabW + 1 end
    local x2 = i == tabCount and w or math.min(w, x + tabW - 1)
    local active = pageName == page
    local bg = active and colors.cyan or colors.gray
    local fg = active and colors.black or colors.white
    local width = math.max(1, x2 - x + 1)
    fillRect(x, h, width, 1, bg)
    local label = labels[i]
    if #label > width then label = string.sub(label, 1, width) end
    local labelX = x + math.max(0, math.floor((width - #label) / 2))
    writeAt(labelX, h, label, fg, bg, x2 - labelX + 1)
    registerButton(screen, {x = x, x2 = x2, y = h, action = "nav", page = pageName})
    x = x2 + 1
  end
end

local function bottomPageControls(screen, page, y, pageNumber, pageCount)
  local w = mon.getSize()
  pageNumber = math.max(1, math.min(pageNumber, pageCount))
  local navHeight = 2
  local buttonW = math.max(10, math.floor((w - 6) / 2))
  local prevX = 2
  local nextX = math.max(2, w - buttonW + 1)
  local pageText = tostring(pageNumber) .. "/" .. tostring(pageCount)

  fillRect(1, y, w, navHeight, colors.blue)
  writeAt(prevX + math.max(0, math.floor((buttonW - 6) / 2)), y, "< PREV", pageNumber > 1 and colors.white or colors.lightGray, colors.blue, 6)
  writeAt(nextX + math.max(0, math.floor((buttonW - 6) / 2)), y, "NEXT >", pageNumber < pageCount and colors.white or colors.lightGray, colors.blue, 6)
  writeAt(math.max(1, math.floor((w - #pageText) / 2) + 1), y + 1, pageText, colors.black, colors.yellow, #pageText)

  if pageNumber > 1 then registerButton(screen, {x = prevX, x2 = prevX + buttonW - 1, y = y, y2 = y + navHeight - 1, action = "page", page = page, delta = -1}) end
  if pageNumber < pageCount then registerButton(screen, {x = nextX, x2 = nextX + buttonW - 1, y = y, y2 = y + navHeight - 1, action = "page", page = page, delta = 1}) end
end

