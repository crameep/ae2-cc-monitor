local function renderOverview(screen, data, h)
  local w = mon.getSize()
  local bottom = h - 1
  local y = 3

  if bottom - y >= 8 and w >= 42 then
    local gap = 1
    local tileW = math.floor((w - (gap * 2)) / 3)
    local energyValue = data.energyCap > 0 and (math.floor(data.aeEnergyPct + 0.5) .. "%") or fmt(data.energy)
    tile(1, y, tileW, "ITEM STORAGE", math.floor(data.itemPct + 0.5) .. "%", fmt(data.itemUsed) .. " / " .. (data.itemTotal > 0 and fmt(data.itemTotal) or "?"), colors.green)
    tile(tileW + gap + 1, y, tileW, "TYPE SLOTS", math.floor(data.typePct + 0.5) .. "%", data.itemTypes .. " / " .. (data.itemTypeTotal > 0 and data.itemTypeTotal or "?"), colors.yellow)
    tile((tileW * 2) + (gap * 2) + 1, y, w - ((tileW * 2) + (gap * 2)), "AE ENERGY", energyValue, powerTrendText(data.powerStats), colors.orange)
    y = y + 4
  end

  capacityRow(y, "Items", data.itemUsed, data.itemTotal, colors.lime); y = y + 1
  capacityRow(y, "Types", data.itemTypes, data.itemTypeTotal, colors.yellow); y = y + 1
  capacityRow(y, "Fluids", data.fluidUsed, data.fluidTotal, colors.blue); y = y + 1
  if data.energyCap > 0 then
    capacityRow(y, "AE Energy", data.energy, data.energyCap, colors.orange)
  else
    writeAt(2, y, "AE Energy", colors.lightGray, colors.black, 12)
    writeAt(15, y, fmt(data.energy) .. " AE stored  |  capacity hidden", colors.orange, colors.black, w - 15)
  end
  y = y + 1
  if y <= bottom then
    local etaText = powerEtaText(data.powerStats)
    local rightText = etaText or (fmt(data.usage) .. "/t bridge use")
    local trendColor = (data.powerStats and not data.powerStats.known) and colors.orange or (data.powerStats and data.powerStats.netPerSecond < 0 and colors.orange or colors.lime)
    writeAt(2, y, "AE Trend", colors.lightGray, colors.black, 12)
    writeAt(15, y, powerTrendText(data.powerStats), trendColor, colors.black, math.max(8, w - #rightText - 18))
    writeAt(math.max(1, w - #rightText + 1), y, rightText, etaText and colors.yellow or colors.lightGray, colors.black, #rightText)
    y = y + 2
  else
    y = y + 1
  end

  if y <= bottom then
    clearLine(y, colors.lightGray)
    writeAt(2, y, "ACTIVE CRAFTING", colors.black, colors.lightGray, w - 2)
    writeAt(math.max(1, w - 11), y, tostring(#data.tasks) .. " JOB(S)", colors.black, colors.lightGray, 10)
    y = y + 1
    if #data.tasks == 0 then
      local summary = data.busyCpuCount > 0 and (data.busyCpuCount .. " CPU(s) busy; job details unavailable") or "No active crafting jobs"
      writeAt(2, y, summary, data.busyCpuCount > 0 and colors.cyan or colors.lightGray, colors.black, w - 2)
      y = y + 1
    else
      for i = 1, math.min(#data.tasks, 2) do
        local task = data.tasks[i]
        local statusText, detail
        if task.progressKnown then
          statusText = string.format("%3d%%", math.floor(task.completion * 100 + 0.5))
          detail = task.quantity > 0 and (fmt(task.crafted) .. "/" .. fmt(task.quantity)) or "running"
        else
          statusText = "RUNNING"
          detail = n(task.estimatedCrafted) > 0 and ("EST +" .. fmt(task.estimatedCrafted)) or (task.quantity > 0 and ("TARGET " .. fmt(task.quantity)) or "ACTIVE")
        end
        writeAt(2, y, task.name, colors.cyan, colors.black, math.max(8, w - #statusText - #detail - 6))
        writeAt(math.max(1, w - #detail - #statusText - 2), y, detail .. " " .. statusText, colors.white, colors.black)
        y = y + 1
      end
    end
  end

  if y <= bottom then
    y = y + 1
    if y <= bottom then
      local alertColor = #data.warnings > 0 and colors.red or (#data.recent > 0 and colors.orange or colors.green)
      clearLine(y, alertColor)
      local alertTitle = #data.warnings > 0 and "CONFIRMED MATERIAL DROP" or (#data.recent > 0 and "RECENT MATERIAL USE" or "NO ACTIVE MATERIAL ALERTS")
      writeAt(2, y, alertTitle, colors.black, alertColor, w - 2)
      y = y + 1
    end
    if y <= bottom then
      if #data.warnings > 0 then
        local row = data.warnings[1]
        writeAt(2, y, row.name .. "  -" .. fmt(row.drop) .. "  left " .. fmt(row.left), colors.red, colors.black, w - 2)
      elseif #data.recent > 0 then
        local row = data.recent[1]
        writeAt(2, y, row.name .. "  -" .. fmt(row.drop) .. "  left " .. fmt(row.left), colors.orange, colors.black, w - 2)
      elseif #data.lowStock > 0 then
        local row = data.lowStock[1]
        writeAt(2, y, "Low: " .. row.name .. "  " .. fmt(row.amount), colors.yellow, colors.black, w - 2)
      else
        writeAt(2, y, "Storage, power, and watched stock are stable", colors.lightGray, colors.black, w - 2)
      end
    end
  end
end

local function renderCrafting(screen, data, h)
  local w = mon.getSize()
  local navY = h - 2
  local bottom = h - 3
  clearLine(3, colors.black)
  writeAt(2, 3, tostring(#data.tasks) .. " active job(s)  |  " .. data.busyCpuCount .. "/" .. #data.cpus .. " CPUs busy", colors.lightGray, colors.black, math.max(8, w - 25))

  if #data.tasks == 0 then
    if data.busyCpuCount > 0 then
      centerText(math.min(bottom, 7), "CRAFTING DETECTED", colors.cyan, colors.black, w)
      centerText(math.min(bottom, 9), "CPU busy; this bridge did not expose the job object.", colors.lightGray, colors.black, w)
    else
      centerText(math.min(bottom, 7), "NO ACTIVE CRAFTING JOBS", colors.cyan, colors.black, w)
      centerText(math.min(bottom, 9), "Start a craft from an AE2 terminal to see it here.", colors.lightGray, colors.black, w)
    end
    local y = 12
    if y <= bottom then
      clearLine(y, colors.lightGray)
      writeAt(2, y, "CRAFTING CPUs", colors.black, colors.lightGray, w - 2)
      y = y + 1
      for _, cpu in ipairs(data.cpus) do
        if y > bottom then break end
        local name = firstField(cpu, {"_monitorName", "name", "displayName"}, "CPU")
        local storage = n(firstField(cpu, {"storage", "bytes"}, 0))
        local co = n(firstField(cpu, {"coProcessors", "coprocessors"}, 0))
        local busy = cpuBusy(cpu)
        writeAt(2, y, name, busy and colors.cyan or colors.white, colors.black, math.max(8, w - 26))
        writeAt(math.max(1, w - 24), y, (busy and "BUSY" or "IDLE") .. "  " .. fmt(storage) .. "B  " .. fmt(co) .. " co", busy and colors.cyan or colors.lightGray, colors.black, 24)
        y = y + 1
      end
    end
    return
  end

  local taskHeight = 5
  local rowsAvailable = math.max(taskHeight, bottom - 3)
  local perPage = math.max(1, math.floor(rowsAvailable / taskHeight))
  local pageCount = math.max(1, math.ceil(#data.tasks / perPage))
  listPages[screen] = listPages[screen] or {}
  local pageNumber = math.min(pageCount, math.max(1, n(listPages[screen].crafting or 1)))
  listPages[screen].crafting = pageNumber
  bottomPageControls(screen, "crafting", navY, pageNumber, pageCount)

  local startIndex = ((pageNumber - 1) * perPage) + 1
  local y = 4
  for i = startIndex, math.min(#data.tasks, startIndex + perPage - 1) do
    local task = data.tasks[i]
    if y + taskHeight - 1 > bottom then break end
    clearLine(y, colors.gray)
    local statusText = task.progressKnown and string.format("%3d%%", math.floor(task.completion * 100 + 0.5)) or "RUNNING"
    writeAt(2, y, task.name, colors.white, colors.gray, math.max(8, w - #statusText - 4))
    writeAt(math.max(1, w - #statusText), y, statusText, colors.white, colors.gray, #statusText)

    if task.progressKnown then
      meter(2, y + 1, math.max(4, w - 2), task.completion, colors.cyan, colors.gray)
    else
      clearLine(y + 1, colors.black)
      writeAt(2, y + 1, "DIRECT PROGRESS NOT EXPOSED - STOCK DELTA ESTIMATE", colors.yellow, colors.black, w - 2)
    end

    local progress, rateEta
    if task.progressKnown then
      progress = task.quantity > 0 and (fmt(task.crafted) .. " / " .. fmt(task.quantity)) or "running"
      rateEta = task.rate > 0 and (fmtRate(task.rate) .. "  ETA " .. duration(task.eta)) or "rate learning"
    else
      progress = task.quantity > 0 and ("Target " .. fmt(task.quantity) .. "  |  EST stock +" .. fmt(task.estimatedCrafted)) or "Running"
      rateEta = task.estimatedRate > 0 and ("~" .. fmtRate(task.estimatedRate) .. "  ETA~ " .. duration(task.estimatedEta)) or "estimate learning"
    end
    writeAt(2, y + 2, progress, colors.white, colors.black, math.max(8, w - #rateEta - 4))
    writeAt(math.max(1, w - #rateEta), y + 2, rateEta, colors.lightGray, colors.black, #rateEta)

    local cpuDetail = task.cpu
    if task.cpuStorage > 0 then cpuDetail = cpuDetail .. "  |  " .. fmt(task.cpuStorage) .. " bytes" end
    if task.cpuCoProcessors > 0 then cpuDetail = cpuDetail .. "  |  " .. fmt(task.cpuCoProcessors) .. " co" end
    writeAt(2, y + 3, cpuDetail, colors.lightGray, colors.black, w - 2)

    local detail = task.subparts or task.recipe or (task.debug and cleanLabel(task.debug)) or "Recipe inputs unavailable"
    writeAt(2, y + 4, detail, (task.subparts or task.recipe) and colors.yellow or colors.lightGray, colors.black, w - 2)
    y = y + taskHeight
  end
end

local function renderStock(screen, data, h)
  local w = mon.getSize()
  local navY = h - 2
  local bottom = h - 3
  local y = 3

  clearLine(y, colors.black)
  local summary = #data.warnings .. " warning" .. (#data.warnings == 1 and "" or "s")
    .. "  |  " .. #data.recent .. " moving"
    .. "  |  " .. #data.lowStock .. " low"
  writeAt(2, y, summary, colors.lightGray, colors.black, w - 2)
  y = y + 1

  local activeTab = getSectionTab(screen, "stock", "items")
  y = drawSubtabs(screen, "stock", activeTab, {
    {key = "items", label = "ITEM STOCK"},
    {key = "fluids", label = "FLUID STOCK"}
  }, y)
  y = y + 1

  if activeTab == "fluids" then
    renderFluidRows(screen, "stockFluids", data.topFluids, y, bottom, navY, "No stored fluids reported")
    return
  end

  local alerts = {}
  for i = 1, math.min(2, #data.warnings) do
    local row = data.warnings[i]
    alerts[#alerts + 1] = {kind = "DROP", row = row, color = colors.red, ignore = true}
  end
  if #alerts < 2 and #data.recent > 0 then
    alerts[#alerts + 1] = {kind = "MOVE", row = data.recent[1], color = colors.orange}
  end

  if #alerts == 0 then
    writeAt(2, y, "No confirmed drops or repeated movement", colors.lightGray, colors.black, w - 2)
    y = y + 1
  else
    for _, alert in ipairs(alerts) do
      if y > bottom then break end
      local row = alert.row
      local prefix = alert.kind .. "  "
      local rightText = "-" .. fmt(row.drop) .. "  left " .. fmt(row.left)
      local rightReserve = #rightText + (alert.ignore and 6 or 1)
      writeAt(2, y, prefix .. row.name, alert.color, colors.black, math.max(8, w - rightReserve - 2))
      writeAt(math.max(1, w - rightReserve + 1), y, rightText, colors.yellow, colors.black, #rightText)
      if alert.ignore then
        local buttonX = math.max(1, w - 4)
        writeAt(buttonX, y, "IGN", colors.white, colors.gray, 3)
        registerButton(screen, {x = buttonX, x2 = w, y = y, action = "ignore", key = row.key, name = row.name})
      end
      y = y + 1
    end
  end

  if y <= bottom then y = y + 1 end
  if y > bottom then return end

  local headerY = y
  local columnY = y + 1
  local firstRowY = y + 2
  local rowsAvailable = math.max(1, bottom - firstRowY + 1)
  local pageCount = math.max(1, math.ceil(#data.lowStock / rowsAvailable))
  listPages[screen] = listPages[screen] or {}
  local pageNumber = math.min(pageCount, math.max(1, n(listPages[screen].stock or 1)))
  listPages[screen].stock = pageNumber

  clearLine(headerY, colors.yellow)
  writeAt(2, headerY, "ATM10 LOW STOCK", colors.black, colors.yellow, w - 2)
  bottomPageControls(screen, "stock", navY, pageNumber, pageCount)

  local ignoreW = 4
  local amountW = w >= 70 and 13 or 10
  local groupW = w >= 70 and 12 or 8
  local ignoreX = math.max(1, w - ignoreW + 1)
  local amountX = math.max(1, ignoreX - amountW - 1)
  local groupX = amountX - groupW - 1
  local itemW = math.max(8, groupX - 3)

  clearLine(columnY, colors.lightGray)
  writeAt(2, columnY, "ITEM", colors.black, colors.lightGray, itemW)
  writeAt(groupX, columnY, "GROUP", colors.black, colors.lightGray, groupW)
  writeAt(amountX, columnY, "COUNT/TARGET", colors.black, colors.lightGray, amountW)
  writeAt(ignoreX, columnY, "IGN", colors.black, colors.lightGray, ignoreW)

  if #data.lowStock == 0 then
    writeAt(2, firstRowY, "No watched ATM10 bottlenecks are low", colors.lightGray, colors.black, w - 2)
  end

  local startIndex = ((pageNumber - 1) * rowsAvailable) + 1
  local rowY = firstRowY
  for i = startIndex, math.min(#data.lowStock, startIndex + rowsAvailable - 1) do
    if rowY > bottom then break end
    local row = data.lowStock[i]
    local bg = (i % 2 == 0) and colors.gray or colors.black
    local ratio = n(row.ratio)
    local amountColor = ratio <= 0.10 and colors.red or (ratio <= 0.25 and colors.orange or colors.yellow)
    local amountText = fmt(row.amount) .. "/" .. fmt(row.target)
    clearLine(rowY, bg)
    writeAt(2, rowY, row.name, colors.white, bg, itemW)
    writeAt(groupX, rowY, row.group, colors.lightGray, bg, groupW)
    writeAt(math.max(amountX, w - #amountText + 1), rowY, amountText, amountColor, bg, amountW)
    writeAt(ignoreX, rowY, "IGN", colors.white, colors.gray, ignoreW)
    registerButton(screen, {x = ignoreX, x2 = w, y = rowY, action = "ignore", key = row.key, name = row.name})
    rowY = rowY + 1
  end

end

local function renderStorage(screen, data, h)
  local w = mon.getSize()
  local navY = h - 2
  local bottom = h - 3
  local y = 3
  local activeTab = getSectionTab(screen, "storage", "items")
  y = drawSubtabs(screen, "storage", activeTab, {
    {key = "items", label = "ITEM STORAGE"},
    {key = "fluids", label = "FLUID STORAGE"}
  }, y)
  y = y + 1

  if activeTab == "fluids" then
    clearLine(y, colors.black)
    writeAt(2, y, data.fluidTypes .. " fluid types  |  " .. fmt(data.fluidUsed) .. "/" .. (data.fluidTotal > 0 and fmt(data.fluidTotal) or "?") .. " bytes", colors.lightGray, colors.black, w - 2)
    y = y + 2
    renderFluidRows(screen, "storageFluids", data.topFluids, y, bottom, navY, "No stored fluids reported")
    return
  end

  local headerRows = 2
  local rowsAvailable = math.max(1, bottom - (y + headerRows) + 1)
  local pageCount = math.max(1, math.ceil(#data.top / rowsAvailable))
  listPages[screen] = listPages[screen] or {}
  local pageNumber = math.min(pageCount, math.max(1, n(listPages[screen].storage or 1)))
  listPages[screen].storage = pageNumber
  local amountW = w >= 64 and 12 or 10
  local markerW = 6
  local amountX = math.max(1, w - amountW + 1)
  local markerX = math.max(1, amountX - markerW - 1)
  local itemW = math.max(8, markerX - 3)

  clearLine(y, colors.black)
  local bulkText = data.bulkAutoAvailable and (data.bulkItemMatches .. " cell-marked") or (data.manualBulkCount .. " bulk | " .. data.manualInfCount .. " inf | auto unavailable")
  writeAt(2, y, #data.top .. " item types  |  " .. bulkText .. "  |  " .. data.hugeCount .. " huge hints", colors.lightGray, colors.black, w - 2)
  bottomPageControls(screen, "storage", navY, pageNumber, pageCount)
  y = y + 1

  clearLine(y, colors.lightGray)
  writeAt(2, y, "ITEM", colors.black, colors.lightGray, itemW)
  writeAt(markerX, y, "CELL", colors.black, colors.lightGray, markerW)
  writeAt(amountX, y, "AMOUNT", colors.black, colors.lightGray, amountW)
  y = y + 1

  if #data.top == 0 then
    centerText(math.min(bottom, y + 3), "No stored items reported", colors.lightGray, colors.black, w)
    return
  end

  local startIndex = ((pageNumber - 1) * rowsAvailable) + 1
  for i = startIndex, math.min(#data.top, startIndex + rowsAvailable - 1) do
    if y > bottom then break end
    local row = data.top[i]
    local amountText = fmt(row.amount)
    local cellState = row.cellState
    local marker = cellState == "inf" and "INF" or (cellState == "bulk" and "BULK" or (row.huge and "HUGE" or "BULK+"))
    local rowBg = cellState == "inf" and colors.green or (cellState == "bulk" and colors.purple or ((i % 2 == 0) and colors.gray or colors.black))
    local markerColor = cellState and colors.white or (row.huge and colors.orange or colors.lightGray)
    clearLine(y, rowBg)
    local amountCell = string.rep(" ", math.max(0, amountW - #amountText)) .. amountText
    writeAt(2, y, row.name, colors.white, rowBg, itemW)
    writeAt(markerX, y, marker, markerColor, rowBg, markerW)
    registerButton(screen, {x = markerX, x2 = markerX + markerW - 1, y = y, action = "bulk", key = row.key, name = row.name, cellState = cellState})
    writeAt(amountX, y, amountCell, colors.white, rowBg, amountW)
    y = y + 1
  end

end

local function renderMovers(screen, data, h)
  local w = mon.getSize()
  local navY = h - 2
  local bottom = h - 3
  local y = 3

  clearLine(y, colors.black)
  local summary = #data.movers .. " changing item type" .. (#data.movers == 1 and "" or "s")
    .. "  |  " .. #data.fluidMovers .. " changing fluid" .. (#data.fluidMovers == 1 and "" or "s")
  writeAt(2, y, summary .. "  |  sampled every " .. SAMPLE_SECONDS .. "s", colors.lightGray, colors.black, w - 2)
  y = y + 1

  local activeTab = getSectionTab(screen, "movers", "items")
  y = drawSubtabs(screen, "movers", activeTab, {
    {key = "items", label = "ITEM MOVEMENT"},
    {key = "fluids", label = "FLUID MOVEMENT"}
  }, y)
  y = y + 1

  local rows = activeTab == "fluids" and data.fluidMovers or data.movers
  local pageKey = activeTab == "fluids" and "fluidMovers" or "movers"
  local rowsAvailable = math.max(1, bottom - (y + 1) + 1)
  local pageCount = math.max(1, math.ceil(#rows / rowsAvailable))
  listPages[screen] = listPages[screen] or {}
  local pageNumber = math.min(pageCount, math.max(1, n(listPages[screen][pageKey] or 1)))
  listPages[screen][pageKey] = pageNumber
  bottomPageControls(screen, pageKey, navY, pageNumber, pageCount)

  local nowW = w >= 72 and 10 or 0
  local hourW = w >= 58 and 10 or 8
  local minW = w >= 58 and 10 or 8
  local deltaW = w >= 58 and 9 or 8
  local nowX = nowW > 0 and (w - nowW + 1) or nil
  local hourX = nowW > 0 and (nowX - hourW - 1) or (w - hourW + 1)
  local minX = hourX - minW - 1
  local deltaX = minX - deltaW - 1
  local itemW = math.max(8, deltaX - 3)

  clearLine(y, colors.lightGray)
  writeAt(2, y, activeTab == "fluids" and "FLUID" or "ITEM", colors.black, colors.lightGray, itemW)
  writeAt(deltaX, y, "DELTA", colors.black, colors.lightGray, deltaW)
  writeAt(minX, y, "/MIN", colors.black, colors.lightGray, minW)
  writeAt(hourX, y, "/HR", colors.black, colors.lightGray, hourW)
  if nowX then writeAt(nowX, y, "NOW", colors.black, colors.lightGray, nowW) end
  y = y + 1

  if #rows == 0 then
    local emptyText = activeTab == "fluids" and "No fluid movement in the current sample window" or "No item movement in the current sample window"
    writeAt(2, y, emptyText, colors.lightGray, colors.black, w - 2)
    return
  end

  local startIndex = ((pageNumber - 1) * rowsAvailable) + 1
  for i = startIndex, math.min(#rows, startIndex + rowsAvailable - 1) do
    if y > bottom then break end
    local row = rows[i]
    local bg = (i % 2 == 0) and colors.gray or colors.black
    local movementColor = n(row.delta) < 0 and colors.orange or colors.lime
    local deltaText = signedFmt(row.delta)
    local minText = rateFmt(row.perMinute, "/m")
    local hourText = rateFmt(row.perHour, "/h")
    local nowText = fmt(row.amount)
    clearLine(y, bg)
    writeAt(2, y, row.name, colors.white, bg, itemW)
    writeAt(math.max(deltaX, deltaX + deltaW - #deltaText), y, deltaText, movementColor, bg, deltaW)
    writeAt(math.max(minX, minX + minW - #minText), y, minText, movementColor, bg, minW)
    writeAt(math.max(hourX, hourX + hourW - #hourText), y, hourText, movementColor, bg, hourW)
    if nowX then writeAt(math.max(nowX, nowX + nowW - #nowText), y, nowText, colors.lightGray, bg, nowW) end
    y = y + 1
  end
end

local function renderSystem(screen, data, h)
  local w = mon.getSize()
  local footerY = h - 1
  local bottom = h - 2
  local y = 3

  clearLine(y, colors.black)
  local onlineText = data.online and "GRID ONLINE" or "GRID STATUS UNKNOWN"
  writeAt(2, y, onlineText, data.online and colors.green or colors.orange, colors.black, math.max(8, w - 14))
  local updateX = math.max(1, w - 10)
  writeAt(updateX, y, " UPDATE ", colors.white, colors.blue, 8)
  registerButton(screen, {x = updateX, x2 = w, y = y, action = "update"})
  y = y + 2

  local activeTab = getSectionTab(screen, "system", "summary")
  y = drawSubtabs(screen, "system", activeTab, {
    {key = "summary", label = "SUMMARY"},
    {key = "cells", label = "CELLS"}
  }, y)
  y = y + 1

  if activeTab == "cells" then
    local rowsAvailable = math.max(1, bottom - (y + 1) + 1)
    local pageCount = math.max(1, math.ceil(#data.cellRows / rowsAvailable))
    listPages[screen] = listPages[screen] or {}
    local pageNumber = math.min(pageCount, math.max(1, n(listPages[screen].systemCells or 1)))
    listPages[screen].systemCells = pageNumber
    bottomPageControls(screen, "systemCells", footerY - 2, pageNumber, pageCount)
    clearLine(y, colors.lightGray)
    writeAt(2, y, "CELL", colors.black, colors.lightGray, math.max(8, w - 18))
    writeAt(math.max(1, w - 16), y, "USED", colors.black, colors.lightGray, 16)
    y = y + 1
    if #data.cellRows == 0 then
      writeAt(2, y, "No storage cell data exposed", colors.lightGray, colors.black, w - 2)
    else
      local startIndex = ((pageNumber - 1) * rowsAvailable) + 1
      for i = startIndex, math.min(#data.cellRows, startIndex + rowsAvailable - 1) do
        if y > bottom then break end
        local row = data.cellRows[i]
        local bg = (i % 2 == 0) and colors.gray or colors.black
        local usedText = fmt(row.used) .. "/" .. fmt(row.total) .. " " .. math.floor(row.pct + 0.5) .. "%"
        clearLine(y, bg)
        writeAt(2, y, row.name, row.type == "ae2:f" and colors.cyan or colors.white, bg, math.max(8, w - #usedText - 3))
        writeAt(math.max(1, w - #usedText + 1), y, usedText, colors.lightGray, bg, #usedText)
        y = y + 1
      end
    end
    clearLine(footerY, colors.black)
    writeAt(2, footerY, "v" .. VERSION .. "  |  refresh 3s  |  usage sample " .. SAMPLE_SECONDS .. "s", colors.lightGray, colors.black, w - 2)
    return
  end

  if w >= 42 and y + 2 <= bottom then
    local gap = 1
    local tileW = math.floor((w - (gap * 2)) / 3)
    tile(1, y, tileW, "CELLS", tostring(data.cellCount), data.nearFullCellCount .. " near full / " .. data.emptyCellCount .. " empty", colors.green)
    tile(tileW + gap + 1, y, tileW, "PATTERNS", tostring(data.patternCount), data.driveDataAvailable and (data.driveCount .. " drives") or "drive data N/A", colors.yellow)
    tile((tileW * 2) + (gap * 2) + 1, y, w - ((tileW * 2) + (gap * 2)), "CPUs", tostring(#data.cpus), data.busyCpuCount .. " busy", colors.cyan)
    y = y + 4
  end

  if y <= bottom then
    clearLine(y, colors.lightGray)
    writeAt(2, y, "AE ENERGY", colors.black, colors.lightGray, w - 2)
    y = y + 1
    writeAt(2, y, "Stored", colors.lightGray, colors.black, 12)
    if data.energyCap > 0 then
      writeAt(15, y, fmt(data.energy) .. " / " .. fmt(data.energyCap) .. " AE  (" .. math.floor(data.aeEnergyPct + 0.5) .. "%)", colors.white, colors.black, w - 15)
    else
      writeAt(15, y, fmt(data.energy) .. " AE stored  |  capacity hidden", colors.orange, colors.black, w - 15)
    end
    y = y + 1
    writeAt(2, y, "Trend", colors.lightGray, colors.black, 12)
    local trendColor = (data.powerStats and not data.powerStats.known) and colors.orange or (data.powerStats and data.powerStats.netPerSecond < 0 and colors.orange or colors.lime)
    writeAt(15, y, powerTrendText(data.powerStats), trendColor, colors.black, w - 15)
    y = y + 1
    if y <= bottom then
      writeAt(2, y, "Bridge", colors.lightGray, colors.black, 12)
      local netText = (data.powerNet >= 0 and "+" or "") .. fmt(data.powerNet) .. "/t net"
      writeAt(15, y, fmt(data.input) .. "/t in  " .. fmt(data.usage) .. "/t used  " .. netText, colors.white, colors.black, w - 15)
      y = y + 1
    end
    local etaText = powerEtaText(data.powerStats)
    if etaText and y <= bottom then
      writeAt(2, y, "Estimate", colors.lightGray, colors.black, 12)
      writeAt(15, y, etaText, colors.yellow, colors.black, w - 15)
      y = y + 1
    end
    y = y + 1
  end

  if y <= bottom then
    clearLine(y, colors.lightGray)
    writeAt(2, y, "CELL HARDWARE", colors.black, colors.lightGray, w - 2)
    y = y + 1
    if #data.cellGroups == 0 then
      writeAt(2, y, "No storage cell data exposed", colors.lightGray, colors.black, w - 2)
      y = y + 1
    else
      for _, group in ipairs(data.cellGroups) do
        if y > bottom then break end
        local pctText = group.total > 0 and (" " .. math.floor(pct(group.used, group.total) + 0.5) .. "%") or ""
        local line = group.count .. "x " .. group.name .. "  " .. group.nonempty .. " used  " .. fmt(group.used) .. "/" .. fmt(group.total) .. pctText
        local color = group.type == "ae2:f" and colors.cyan or colors.white
        writeAt(2, y, line, color, colors.black, w - 2)
        y = y + 1
      end
    end
    y = y + 1
  end

  if y <= bottom then
    if y <= bottom then
      clearLine(y, colors.lightGray)
      writeAt(2, y, "CRAFTING CPUs", colors.black, colors.lightGray, w - 2)
      y = y + 1
    end
    if #data.cpus == 0 then
      writeAt(2, y, "No crafting CPU data exposed", colors.lightGray, colors.black, w - 2)
      y = y + 1
    else
      for _, cpu in ipairs(data.cpus) do
        if y > bottom - 2 then break end
        local name = firstField(cpu, {"_monitorName", "name", "displayName"}, "CPU")
        local storage = n(firstField(cpu, {"storage", "bytes"}, 0))
        local co = n(firstField(cpu, {"coProcessors", "coprocessors"}, 0))
        local busy = cpuBusy(cpu)
        writeAt(2, y, name, busy and colors.cyan or colors.white, colors.black, math.max(8, w - 28))
        writeAt(math.max(1, w - 26), y, (busy and "BUSY" or "IDLE") .. "  " .. fmt(storage) .. "B  " .. co .. " co", busy and colors.cyan or colors.lightGray, colors.black, 26)
        y = y + 1
      end
    end
  end

  clearLine(footerY, colors.black)
  writeAt(2, footerY, "v" .. VERSION .. "  |  refresh 3s  |  usage sample " .. SAMPLE_SECONDS .. "s", colors.lightGray, colors.black, w - 2)
end

local function renderTools(screen, data, h)
  local w = mon.getSize()
  local bottom = h - 1
  local y = 3

  clearLine(y, colors.lightGray)
  writeAt(2, y, "AE2 DIAGNOSTIC", colors.black, colors.lightGray, w - 2)
  y = y + 2

  local busy = toolBusy or diagnosticRequested
  local buttonText = busy and " DIAGNOSTIC RUNNING... " or " CREATE + UPLOAD AE2 DUMP "
  local buttonWidth = math.min(w - 4, #buttonText + 4)
  local buttonX = math.max(2, math.floor((w - buttonWidth) / 2) + 1)
  fillRect(buttonX, y, buttonWidth, 3, busy and colors.gray or colors.blue)
  centerText(y + 1, buttonText, colors.white, busy and colors.gray or colors.blue, buttonWidth)
  if not busy then
    registerButton(screen, {x = buttonX, x2 = buttonX + buttonWidth - 1, y = y, y2 = y + 2, action = "diagnostic"})
  end
  y = y + 5

  if y <= bottom then
    writeAt(2, y, "Scans peripherals and safe ME Bridge getters, then uploads", colors.lightGray, colors.black, w - 2)
    y = y + 1
  end
  if y <= bottom then
    writeAt(2, y, "ae2-dump.json and uploads if " .. PASTEBIN_KEY_FILE .. " exists.", colors.lightGray, colors.black, w - 2)
    y = y + 2
  end

  if lastPasteUrl and y <= bottom then
    clearLine(y, colors.green)
    writeAt(2, y, "LAST PASTEBIN LINK", colors.black, colors.green, w - 2)
    y = y + 1
    if y <= bottom then
      writeAt(2, y, lastPasteUrl, colors.cyan, colors.black, w - 2)
      y = y + 1
    end
    if y <= bottom then
      local code = string.match(lastPasteUrl, "([^/]+)$") or lastPasteUrl
      writeAt(2, y, "Paste code: " .. code, colors.white, colors.black, w - 2)
      y = y + 1
    end
    if y <= bottom and lastDumpSize > 0 then
      writeAt(2, y, "Dump size: " .. fmt(lastDumpSize) .. " bytes", colors.lightGray, colors.black, w - 2)
    end
  elseif lastPasteError and y <= bottom then
    clearLine(y, colors.red)
    writeAt(2, y, "LAST ERROR", colors.black, colors.red, w - 2)
    y = y + 1
    if y <= bottom then writeAt(2, y, lastPasteError, colors.red, colors.black, w - 2) end
    y = y + 1
    if y <= bottom and lastDumpSize > 0 then
      writeAt(2, y, "Saved " .. DUMP_FILE .. " (" .. fmt(lastDumpSize) .. " bytes)", colors.lightGray, colors.black, w - 2)
      y = y + 1
    end
    if y <= bottom and lastDumpPreview then
      writeAt(2, y, "Dump preview: " .. lastDumpPreview, colors.orange, colors.black, w - 2)
      y = y + 1
    end
    if y <= bottom then
      writeAt(2, y, "Terminal fallback: pastebin put " .. DUMP_FILE, colors.yellow, colors.black, w - 2)
    end
  elseif y <= bottom then
    writeAt(2, y, "No diagnostic has been uploaded yet.", colors.lightGray, colors.black, w - 2)
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
  elseif page == "movers" then
    renderMovers(screen, data, h)
  elseif page == "system" then
    renderSystem(screen, data, h)
  elseif page == "tools" then
    renderTools(screen, data, h)
  else
    renderOverview(screen, data, h)
  end

  drawNav(screen, page, h)
end

local function updatePowerStats(fluxInfo)
  local now = nowSeconds()
  local stored = fluxInfo and fluxInfo.stored or nil
  local cap = fluxInfo and n(fluxInfo.capacity) or 0
  powerStats.known = fluxInfo and fluxInfo.known == true
  powerStats.source = fluxInfo and fluxInfo.source or "unknown"

  if not powerStats.known or stored == nil then
    powerStats.trendReady = false
    powerStats.netPerSecond = 0
    powerStats.netPerTick = 0
    powerStats.netPerMinute = 0
    powerStats.eta = 0
    powerStats.etaMode = nil
    powerStats.lastEnergy = nil
    powerStats.lastTime = now
    return powerStats
  end

  if powerStats.lastEnergy ~= nil and powerStats.lastTime ~= nil and now > powerStats.lastTime then
    local elapsed = now - powerStats.lastTime
    local instantPerSecond = (n(stored) - n(powerStats.lastEnergy)) / elapsed
    if powerStats.trendReady then
      powerStats.netPerSecond = (n(powerStats.netPerSecond) * 0.70) + (instantPerSecond * 0.30)
    else
      powerStats.netPerSecond = instantPerSecond
      powerStats.trendReady = true
    end
    powerStats.netPerTick = powerStats.netPerSecond / 20
    powerStats.netPerMinute = powerStats.netPerSecond * 60

    if powerStats.netPerSecond > 0 and cap > n(stored) then
      powerStats.eta = (cap - n(stored)) / powerStats.netPerSecond
      powerStats.etaMode = "full"
    elseif powerStats.netPerSecond < 0 and n(stored) > 0 then
      powerStats.eta = n(stored) / math.abs(powerStats.netPerSecond)
      powerStats.etaMode = "empty"
    else
      powerStats.eta = 0
      powerStats.etaMode = nil
    end
  end

  powerStats.lastEnergy = n(stored)
  powerStats.lastTime = now
  return powerStats
end

