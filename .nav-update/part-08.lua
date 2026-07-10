        local co = n(firstField(cpu, {"coProcessors", "coprocessors"}, 0))
        local busy = cpuBusy(cpu)
        writeAt(2, y, name, busy and colors.cyan or colors.white, colors.black, math.max(8, w - 28))
        writeAt(math.max(1, w - 26), y, (busy and "BUSY" or "IDLE") .. "  " .. fmt(storage) .. "B  " .. co .. " co", busy and colors.cyan or colors.lightGray, colors.black, 26)
        y = y + 1
      end
    end
  end

  if y <= bottom then
    y = math.max(y + 1, bottom - 1)
    if y <= bottom then
      writeAt(2, y, "v" .. VERSION .. "  |  refresh 3s  |  usage sample " .. SAMPLE_SECONDS .. "s", colors.lightGray, colors.black, w - 2)
    end
  end
end

local function renderScreen(target, data)
  mon = target.device
  local screen = target.name
  local page = currentPages[screen] or "overview"
  currentPages[screen] = page
  uiButtons[screen] = {}
  warningButtons[screen] = {}
  bulkButtons[screen] = {}

  mon.setBackgroundColor(colors.black)
  mon.clear()
  local _, h = mon.getSize()
  drawHeader(screen, page, data)

  if page == "crafting" then
    renderCrafting(screen, data, h)
  elseif page == "stock" then
    renderStock(screen, data, h)
  elseif page == "storage" then
    renderStorage(screen, data, h)
  elseif page == "system" then
    renderSystem(screen, data, h)
  else
    renderOverview(screen, data, h)
  end

  drawNav(screen, page, h)
end

while true do
  local items = callAnyArg({"listItems", "getItems"}, {}, {}) or {}
  local fluids = callAnyArg({"listFluid", "listFluids", "getFluids"}, {}, {}) or {}
  local cells = callAny({"listCells", "getCells"}, {}) or {}
  local drives = call("getDrives", {}) or {}
  local rawCpus = callAny({"getCraftingCPUs", "listCraftingCPUs"}, {}) or {}
  local cpus = normalizeCpus(rawCpus)
  local rawTasks = callAny({"getCraftingTasks", "listCraftingTasks"}, {}) or {}
  local tasks = normalizeTasks(rawTasks, cpus)

  local itemTypes, itemCount = 0, 0
  local bulkIndex, bulkCellCount, bulkItemMatches = buildBulkIndex(cells, items)
  local top = {}
  local lowStock = {}
  for _, item in pairs(items) do
    local amount = amountOf(item)
    if amount > 0 then
      itemTypes = itemTypes + 1
      itemCount = itemCount + amount
      local label = itemLabel(item)
      local key = itemKey(item)
      if shouldWatchItem(key, label) then
        top[#top + 1] = {key = key, name = label, amount = amount, bulk = bulkIndex[key]}
      end
      local stockRule = atm10StockRule(key, label, amount)
      if stockRule then
        lowStock[#lowStock + 1] = {name = label, amount = amount, priority = stockRule.priority, group = stockRule.label}
      end
    end
  end
  table.sort(top, function(a, b) return a.amount > b.amount end)
  table.sort(lowStock, function(a, b)
    if a.priority ~= b.priority then return a.priority > b.priority end
    return a.amount < b.amount
  end)
  local warnings, recent = updateUsage(items)

  local fluidTypes, fluidAmount = 0, 0
  for _, fluid in pairs(fluids) do
    fluidTypes = fluidTypes + 1
    fluidAmount = fluidAmount + amountOf(fluid)
  end

  local itemUsed = call("getUsedItemStorage", itemCount)
  local itemTotal = call("getTotalItemStorage", 0)
  local fluidUsed = call("getUsedFluidStorage", fluidAmount)
  local fluidTotal = call("getTotalFluidStorage", 0)
  local energy = callAny({"getEnergyStorage", "getStoredEnergy"}, 0)
  local energyCap = callAny({"getMaxEnergyStorage", "getEnergyCapacity"}, 0)
  local usage = call("getEnergyUsage", 0)
  local input = callAny({"getAverageEnergyInput", "getAvgPowerInjection"}, 0)
  local itemTypeTotal, fluidTypeTotal, itemCellCount, fluidCellCount = typeSlots(cells)
  local itemPct = pct(itemUsed, itemTotal)
  local typePct = pct(itemTypes, itemTypeTotal)
  local fluidPct = pct(fluidUsed, fluidTotal)
  local fluidTypePct = pct(fluidTypes, fluidTypeTotal)
  local powerPct = pct(energy, energyCap)

  local busyCpuCount = 0
  for _, cpu in pairs(cpus) do
    if cpuBusy(cpu) then busyCpuCount = busyCpuCount + 1 end
  end

  local health = "SYSTEM OK"
  local healthColor = colors.green
  local healthDetail = "storage, power, and stock stable"
  if itemPct >= 90 then
    health, healthColor, healthDetail = "ITEM STORAGE FULL", colors.red, "add item storage"
  elseif typePct >= 85 then
    health, healthColor, healthDetail = "TYPE SLOTS FULL", colors.red, "add type capacity"
  elseif powerPct > 0 and powerPct < 20 then
    health, healthColor, healthDetail = "LOW POWER", colors.red, "check energy input"
  elseif input > 0 and usage > input * 1.10 then
    health, healthColor, healthDetail = "POWER DRAIN", colors.orange, fmt(usage) .. "/t used > " .. fmt(input) .. "/t input"
  elseif fluidPct >= 90 then
    health, healthColor, healthDetail = "FLUID STORAGE FULL", colors.orange, "add fluid storage"
  elseif fluidTypePct >= 85 then
    health, healthColor, healthDetail = "FLUID TYPES FULL", colors.orange, "add fluid type capacity"
  elseif #warnings > 0 then
    health, healthColor, healthDetail = "MATERIAL DROP", colors.red, warnings[1].name
  elseif #recent > 0 then
    health, healthColor, healthDetail = "MATERIAL MOVING", colors.orange, recent[1].name
  elseif #tasks > 0 or busyCpuCount > 0 then
    local detail = #tasks > 0 and (tostring(#tasks) .. " active job(s)") or (tostring(busyCpuCount) .. " CPU(s) busy; details unavailable")
    health, healthColor, healthDetail = "CRAFTING", colors.cyan, detail
  end

  local online = callAny({"isOnline", "isConnected"}, true)
  local data = {
    items = items,
    fluids = fluids,
    cells = cells,
    drives = drives,
    cellCount = countTable(cells),
    driveCount = countTable(drives),
    cpus = cpus,
    tasks = tasks,
    warnings = warnings,
    recent = recent,
    lowStock = lowStock,
    top = top,
    itemTypes = itemTypes,
    itemCount = itemCount,
    fluidTypes = fluidTypes,
    fluidAmount = fluidAmount,
    itemUsed = itemUsed,
    itemTotal = itemTotal,
    fluidUsed = fluidUsed,
    fluidTotal = fluidTotal,
    energy = energy,
    energyCap = energyCap,
    usage = usage,
    input = input,
    itemTypeTotal = itemTypeTotal,
    fluidTypeTotal = fluidTypeTotal,
    itemCellCount = itemCellCount,
    fluidCellCount = fluidCellCount,
    itemPct = itemPct,
    typePct = typePct,
    fluidPct = fluidPct,
    fluidTypePct = fluidTypePct,
    powerPct = powerPct,
    bulkCellCount = bulkCellCount,
    bulkItemMatches = bulkItemMatches,
    busyCpuCount = busyCpuCount,
    health = health,
    healthColor = healthColor,
    healthDetail = healthDetail,
    online = online
  }

  for _, target in ipairs(monitorTargets) do
    renderScreen(target, data)
  end

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
