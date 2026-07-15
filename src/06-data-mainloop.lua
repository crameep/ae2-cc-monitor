local function collectDashboardData()
  local d = {}
  d.items = callAnyArg({"listItems", "getItems"}, {}, {}) or {}
  d.fluids = callAnyArg({"listFluid", "listFluids", "getFluids"}, {}, {}) or {}
  d.chemicals = callAnyArg({"listChemicals", "getChemicals"}, {}, {}) or {}
  d.fluxProbeRows = collectFluxProbeRows()
  d.cells = callAny({"listCells", "getCells"}, {}) or {}
  d.drives = call("getDrives", {}) or {}
  d.cpus = normalizeCpus(callAny({"getCraftingCPUs", "listCraftingCPUs"}, {}) or {})
  d.tasks = normalizeTasks(callAny({"getCraftingTasks", "listCraftingTasks"}, {}) or {}, d.cpus)
  d.patterns = getPatternCache()
  enrichTasks(d.tasks, d.items, d.patterns)

  d.itemTypes = 0
  d.itemCount = 0
  d.top = {}
  d.lowStock = {}
  d.bulkIndex, d.bulkStats = buildBulkIndex(d.cells, d.items)
  for _, item in pairs(d.items) do
    local amount = amountOf(item)
    if amount > 0 then
      d.itemTypes = d.itemTypes + 1
      d.itemCount = d.itemCount + amount
      local label = itemLabel(item)
      local key = itemKey(item)
      if shouldWatchItem(key, label) then
        local cellState = d.bulkIndex[key]
        d.top[#d.top + 1] = {key = key, name = label, amount = amount, cellState = cellState, huge = amount >= HUGE_ITEM_COUNT and cellState == nil}
      end
      local stockRule = not usageState.ignored[key] and atm10StockRule(key, label, amount)
      if stockRule then
        d.lowStock[#d.lowStock + 1] = {key = key, name = label, amount = amount, target = stockRule.max, ratio = amount / math.max(1, stockRule.max), priority = stockRule.priority, group = stockRule.short or stockRule.label}
      end
    end
  end
  table.sort(d.top, function(a, b) return a.amount > b.amount end)
  d.hugeCount = 0
  for _, row in ipairs(d.top) do
    if row.huge then d.hugeCount = d.hugeCount + 1 end
  end
  table.sort(d.lowStock, function(a, b)
    if a.priority ~= b.priority then return a.priority > b.priority end
    if a.ratio ~= b.ratio then return a.ratio < b.ratio end
    return a.name < b.name
  end)
  d.warnings, d.recent, d.movers = updateUsage(d.items)

  d.fluidTypes = 0
  d.fluidAmount = 0
  for _, fluid in pairs(d.fluids) do
    d.fluidTypes = d.fluidTypes + 1
    d.fluidAmount = d.fluidAmount + amountOf(fluid)
  end
  d.topFluids = topFluids(d.fluids, 12)
  d.fluidMovers = updateFluidMovers(d.fluids)

  d.itemUsed = call("getUsedItemStorage", d.itemCount)
  d.itemTotal = call("getTotalItemStorage", 0)
  d.fluidUsed = call("getUsedFluidStorage", d.fluidAmount)
  d.fluidTotal = call("getTotalFluidStorage", 0)
  d.energy = callAny({"getEnergyStorage", "getStoredEnergy"}, 0)
  d.energyCap = callAny({"getMaxEnergyStorage", "getEnergyCapacity"}, 0)
  d.usage = call("getEnergyUsage", 0)
  d.input = callAny({"getAverageEnergyInput", "getAvgPowerInjection"}, 0)

  d.fluxInfo = detectFluxEnergy(d.items, d.fluids, d.chemicals, d.fluxProbeRows, d.cells, d.energy, d.energyCap)
  d.aeEnergyInfo = {stored = d.energy, capacity = d.energyCap, known = d.energyCap > 0, estimated = false, source = "ME bridge AE energy (" .. BRIDGE_SOURCE_LABEL .. ")"}
  d.powerStats = updatePowerStats(d.aeEnergyInfo)
  d.itemTypeTotal, d.fluidTypeTotal, d.itemCellCount, d.fluidCellCount = typeSlots(d.cells)
  d.cellGroups = summarizeCells(d.cells)
  d.cellRows = listCells(d.cells)
  d.itemPct = pct(d.itemUsed, d.itemTotal)
  d.typePct = pct(d.itemTypes, d.itemTypeTotal)
  d.fluidPct = pct(d.fluidUsed, d.fluidTotal)
  d.fluidTypePct = pct(d.fluidTypes, d.fluidTypeTotal)
  d.powerPct = pct(d.energy, d.energyCap)
  d.fePct = d.fluxInfo.known and pct(d.fluxInfo.stored, d.fluxInfo.capacity) or 0
  d.aeEnergyPct = pct(d.energy, d.energyCap)
  d.powerNet = d.input - d.usage
  d.powerBufferSeconds = d.powerNet < 0 and d.energy / math.max(1, (-d.powerNet) * 20) or 0
  d.nearFullCellCount, d.emptyCellCount = cellHealth(d.cells)
  d.driveCount = countTable(d.drives)
  d.driveDataAvailable = d.driveCount > 0 or countTable(d.cells) == 0

  d.busyCpuCount = 0
  for _, cpu in pairs(d.cpus) do
    if cpuBusy(cpu) then d.busyCpuCount = d.busyCpuCount + 1 end
  end

  d.health = "SYSTEM OK"
  d.healthColor = colors.green
  d.healthDetail = "storage, power, and stock stable"
  if d.itemPct >= 90 then
    d.health, d.healthColor, d.healthDetail = "ITEM STORAGE FULL", colors.red, "add item storage"
  elseif d.typePct >= 85 then
    d.health, d.healthColor, d.healthDetail = "TYPE SLOTS FULL", colors.red, "add type capacity"
  elseif d.aeEnergyInfo.known and d.aeEnergyPct < 20 then
    d.health, d.healthColor, d.healthDetail = "LOW AE ENERGY", colors.red, "AE buffer " .. math.floor(d.aeEnergyPct + 0.5) .. "%"
  elseif d.powerStats.trendReady and d.powerStats.etaMode == "empty" and d.powerStats.eta > 0 and d.powerStats.eta < 1800 then
    d.health, d.healthColor, d.healthDetail = "AE ENERGY DRAIN", colors.orange, "empty in " .. duration(d.powerStats.eta)
  elseif d.fluidPct >= 90 then
    d.health, d.healthColor, d.healthDetail = "FLUID STORAGE FULL", colors.orange, "add fluid storage"
  elseif d.fluidTypePct >= 85 then
    d.health, d.healthColor, d.healthDetail = "FLUID TYPES FULL", colors.orange, "add fluid type capacity"
  elseif #d.warnings > 0 then
    d.health, d.healthColor, d.healthDetail = "MATERIAL DROP", colors.red, d.warnings[1].name
  elseif #d.recent > 0 then
    d.health, d.healthColor, d.healthDetail = "MATERIAL MOVING", colors.orange, d.recent[1].name
  elseif #d.tasks > 0 or d.busyCpuCount > 0 then
    d.health, d.healthColor, d.healthDetail = "CRAFTING", colors.cyan, #d.tasks > 0 and (tostring(#d.tasks) .. " active job(s)") or (tostring(d.busyCpuCount) .. " CPU(s) busy; details unavailable")
  end

  d.cellCount = countTable(d.cells)
  d.patternCount = countTable(d.patterns)
  d.feKnown = d.fluxInfo.known
  d.feEstimated = d.fluxInfo.estimated == true
  d.feStored = d.fluxInfo.stored or 0
  d.feCapacity = d.fluxInfo.capacity or 0
  d.feSource = d.fluxInfo.source
  d.feCellCount = d.fluxInfo.cellCount or 0
  d.feProbeCount = d.fluxInfo.probeCount or 0
  d.bulkCellCount = d.bulkStats.bulkCellCount
  d.bulkItemMatches = d.bulkStats.bulkItemMatches
  d.bulkAutoAvailable = d.bulkStats.bulkAutoAvailable
  d.manualBulkCount = d.bulkStats.manualBulkCount
  d.manualInfCount = d.bulkStats.manualInfCount
  d.online = callAny({"isOnline", "isConnected"}, true)
  return d
end

local function mainLoop()
while true do
  local data = collectDashboardData()

  for _, target in ipairs(monitorTargets) do
    renderScreen(target, data)
  end

  if diagnosticRequested then
    diagnosticRequested = false
    runDiagnosticUpload()
    if type(sleep) == "function" then sleep(0) end
  else
    local timer = os.startTimer(3)
    while true do
      local event, a, b, c = os.pullEvent()
      if event == "timer" and a == timer then
        break
      elseif event == "monitor_touch" and handleTouch(a, b, c) then
        break
      elseif event == "mouse_click" and handleTouch("terminal", b, c) then
        break
      elseif event == "monitor_resize" then
        break
      end
    end
  end
end
end

mainLoop()
