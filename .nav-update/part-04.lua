  return default
end

local function registerButton(screen, button)
  uiButtons[screen] = uiButtons[screen] or {}
  uiButtons[screen][#uiButtons[screen] + 1] = button
end

local function setListPage(screen, page, delta)
  listPages[screen] = listPages[screen] or {}
  listPages[screen][page] = math.max(1, n(listPages[screen][page] or 1) + delta)
end

function setStatus(message)
  statusMessage = message
  statusUntil = nowSeconds() + 8
end

local function runUpdater()
  if not http or not http.get then
    setStatus("HTTP disabled; use wget")
    return true
  end

  setStatus("Updating from GitHub...")
  local url = UPDATE_URL .. "?v=" .. tostring(os.epoch and os.epoch("utc") or os.time())
  local res = http.get(url)
  if not res then
    setStatus("Update failed")
    return true
  end
  local body = res.readAll()
  res.close()
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

local function ignoreWarning(button)
  usageState.ignored[button.key] = button.name or true
  usageState.tracked[button.key] = nil
  usageState.warnings = filteredWarnings(usageState.warnings)
  saveState(usageState)
  setStatus("Ignored: " .. tostring(button.name or button.key))
end

local function toggleBulk(button)
  local marked = toggleBulkHint(button.key, button.name)
  if marked == nil then
    setStatus("Could not save bulk marker")
  elseif marked then
    setStatus("Bulk marker added: " .. button.name)
  else
    setStatus("Bulk marker removed: " .. button.name)
  end
end

local function handleTouch(screen, x, y)
  for _, button in ipairs(uiButtons[screen] or {}) do
    if y >= button.y and y <= (button.y2 or button.y) and x >= button.x and x <= button.x2 then
      if button.action == "nav" then
        currentPages[screen] = button.page
      elseif button.action == "page" then
        setListPage(screen, button.page, button.delta)
      elseif button.action == "ignore" then
        ignoreWarning(button)
      elseif button.action == "bulk" then
        toggleBulk(button)
      elseif button.action == "update" then
        return runUpdater()
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
    return usageState.warnings or {}, usageState.recent or {}
  end

  local current = {}
  local warnings = {}
  local recent = {}
  usageState.recentCandidates = usageState.recentCandidates or {}
  for _, item in pairs(items or {}) do
    local key = itemKey(item)
    local amount = amountOf(item)
    if amount > 0 then
      current[key] = amount
      local prior = usageState.last[key]
      local label = itemLabel(item)
      local watchable = shouldWatchItem(key, label)
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
  usageState.stateVersion = STATE_VERSION
  usageState.last = current
  usageState.lastSample = now
  usageState.warnings = warnings
  usageState.recent = recent
  saveState(usageState)
  return warnings, recent
end

local function duration(seconds)
  seconds = math.max(0, math.floor(n(seconds) + 0.5))
