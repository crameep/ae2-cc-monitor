      end
    end
    return
  end

  local taskHeight = 4
  local rowsAvailable = math.max(taskHeight, bottom - 3)
  local perPage = math.max(1, math.floor(rowsAvailable / taskHeight))
  local pageCount = math.max(1, math.ceil(#data.tasks / perPage))
  listPages[screen] = listPages[screen] or {}
  local pageNumber = math.min(pageCount, math.max(1, n(listPages[screen].crafting or 1)))
  listPages[screen].crafting = pageNumber
  pageControls(screen, "crafting", 3, pageNumber, pageCount)

  local startIndex = ((pageNumber - 1) * perPage) + 1
  local y = 4
  for i = startIndex, math.min(#data.tasks, startIndex + perPage - 1) do
    local task = data.tasks[i]
    if y + taskHeight - 1 > bottom then break end
    clearLine(y, colors.gray)
    local pctText = string.format("%3d%%", math.floor(task.completion * 100 + 0.5))
    writeAt(2, y, task.name, colors.white, colors.gray, math.max(8, w - #pctText - 4))
    writeAt(math.max(1, w - #pctText), y, pctText, colors.white, colors.gray, #pctText)
    meter(2, y + 1, math.max(4, w - 2), task.completion, colors.cyan, colors.gray)

    local progress = task.quantity > 0 and (fmt(task.crafted) .. " / " .. fmt(task.quantity)) or "Progress data unavailable"
    local rateEta = task.rate > 0 and (fmtRate(task.rate) .. "  ETA " .. duration(task.eta)) or "rate learning"
    writeAt(2, y + 2, progress, colors.white, colors.black, math.max(8, w - #rateEta - 4))
    writeAt(math.max(1, w - #rateEta), y + 2, rateEta, colors.lightGray, colors.black, #rateEta)

    local detail = task.subparts or ("CPU " .. task.cpu .. (task.usedBytes > 0 and ("  |  " .. fmt(task.usedBytes) .. " bytes") or ""))
    if task.debug and not task.subparts then detail = detail .. "  |  " .. cleanLabel(task.debug) end
    writeAt(2, y + 3, detail, task.subparts and colors.yellow or colors.lightGray, colors.black, w - 2)
    y = y + taskHeight
  end
end

local function renderStock(screen, data, h)
  local w = mon.getSize()
  local bottom = h - 1
  local y = 3
  clearLine(y, colors.black)
  writeAt(2, y, #data.warnings .. " warnings  |  " .. #data.recent .. " recent movers  |  " .. #data.lowStock .. " low watched items", colors.lightGray, colors.black, w - 2)
  y = y + 2

  clearLine(y, #data.warnings > 0 and colors.red or colors.gray)
  writeAt(2, y, "CONFIRMED DROPS", colors.black, #data.warnings > 0 and colors.red or colors.gray, w - 2)
  y = y + 1
  if #data.warnings == 0 then
    writeAt(2, y, "None", colors.lightGray, colors.black, w - 2)
    y = y + 1
  else
    for i = 1, math.min(#data.warnings, 4) do
      if y > bottom then break end
      local row = data.warnings[i]
      local buttonX = math.max(1, w - 5)
      writeAt(2, y, row.name, colors.red, colors.black, math.max(8, w - 30))
      writeAt(math.max(1, w - 24), y, "-" .. fmt(row.drop) .. " left " .. fmt(row.left), colors.yellow, colors.black, 17)
      writeAt(buttonX, y, "IGN", colors.white, colors.gray, 3)
      registerButton(screen, {x = buttonX, x2 = w, y = y, action = "ignore", key = row.key, name = row.name})
      y = y + 1
    end
  end

  if y <= bottom then y = y + 1 end
  if y <= bottom then
    clearLine(y, #data.recent > 0 and colors.orange or colors.gray)
    writeAt(2, y, "RECENT USE", colors.black, #data.recent > 0 and colors.orange or colors.gray, w - 2)
    y = y + 1
    if #data.recent == 0 then
      writeAt(2, y, "No repeated movement detected", colors.lightGray, colors.black, w - 2)
      y = y + 1
    else
      for i = 1, math.min(#data.recent, 3) do
        if y > bottom then break end
        local row = data.recent[i]
        writeAt(2, y, row.name, colors.orange, colors.black, math.max(8, w - 25))
        writeAt(math.max(1, w - 22), y, "-" .. fmt(row.drop) .. " left " .. fmt(row.left), colors.yellow, colors.black, 22)
        y = y + 1
      end
    end
  end

  if y <= bottom then y = y + 1 end
  if y <= bottom then
    clearLine(y, colors.yellow)
    writeAt(2, y, "ATM10 LOW STOCK", colors.black, colors.yellow, math.max(8, w - 24))
    y = y + 1
    local rowsAvailable = math.max(1, bottom - y + 1)
    local pageCount = math.max(1, math.ceil(#data.lowStock / rowsAvailable))
    listPages[screen] = listPages[screen] or {}
    local pageNumber = math.min(pageCount, math.max(1, n(listPages[screen].stock or 1)))
    listPages[screen].stock = pageNumber
    if pageCount > 1 then pageControls(screen, "stock", y - 1, pageNumber, pageCount) end
    if #data.lowStock == 0 then
      writeAt(2, y, "No watched ATM10 bottlenecks are low", colors.lightGray, colors.black, w - 2)
    else
      local startIndex = ((pageNumber - 1) * rowsAvailable) + 1
      for i = startIndex, math.min(#data.lowStock, startIndex + rowsAvailable - 1) do
        local row = data.lowStock[i]
        local amountText = fmt(row.amount)
        writeAt(2, y, row.name, colors.yellow, colors.black, math.max(8, w - #amountText - 18))
        writeAt(math.max(1, w - #amountText - 14), y, row.group, colors.lightGray, colors.black, 12)
        writeAt(math.max(1, w - #amountText), y, amountText, colors.white, colors.black, #amountText)
        y = y + 1
      end
    end
  end
end

local function renderStorage(screen, data, h)
  local w = mon.getSize()
  local bottom = h - 1
  local y = 3
  local rowsAvailable = math.max(1, bottom - y)
  local pageCount = math.max(1, math.ceil(#data.top / rowsAvailable))
  listPages[screen] = listPages[screen] or {}
  local pageNumber = math.min(pageCount, math.max(1, n(listPages[screen].storage or 1)))
  listPages[screen].storage = pageNumber

  clearLine(y, colors.black)
  writeAt(2, y, #data.top .. " stored item types  |  " .. data.bulkItemMatches .. " bulk-marked  |  " .. data.bulkCellCount .. " bulk cells", colors.lightGray, colors.black, math.max(8, w - 24))
  pageControls(screen, "storage", y, pageNumber, pageCount)
  y = y + 1

  clearLine(y, colors.lightGray)
  writeAt(2, y, "ITEM", colors.black, colors.lightGray, math.max(8, w - 22))
  writeAt(math.max(1, w - 19), y, "CELL", colors.black, colors.lightGray, 5)
  writeAt(math.max(1, w - 11), y, "AMOUNT", colors.black, colors.lightGray, 10)
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
    local marker = row.bulk and "BULK" or "B+"
    local rowBg = row.bulk and colors.purple or ((i % 2 == 0) and colors.gray or colors.black)
    clearLine(y, rowBg)
    writeAt(2, y, row.name, colors.white, rowBg, math.max(8, w - #amountText - 10))
    local markerX = math.max(1, w - #amountText - 7)
    writeAt(markerX, y, marker, row.bulk and colors.white or colors.lightGray, rowBg, 5)
    registerButton(screen, {x = markerX, x2 = markerX + 4, y = y, action = "bulk", key = row.key, name = row.name})
    writeAt(math.max(1, w - #amountText), y, amountText, colors.white, rowBg, #amountText)
    y = y + 1
  end
end

local function renderSystem(screen, data, h)
  local w = mon.getSize()
  local bottom = h - 1
  local y = 3

  clearLine(y, colors.black)
  local onlineText = data.online and "GRID ONLINE" or "GRID STATUS UNKNOWN"
  writeAt(2, y, onlineText, data.online and colors.green or colors.orange, colors.black, math.max(8, w - 14))
  local updateX = math.max(1, w - 10)
  writeAt(updateX, y, " UPDATE ", colors.white, colors.blue, 8)
  registerButton(screen, {x = updateX, x2 = w, y = y, action = "update"})
  y = y + 2

  if w >= 42 and y + 2 <= bottom then
    local gap = 1
    local tileW = math.floor((w - (gap * 2)) / 3)
    tile(1, y, tileW, "CELLS", tostring(data.cellCount), data.itemCellCount .. " item / " .. data.fluidCellCount .. " fluid", colors.green)
    tile(tileW + gap + 1, y, tileW, "DRIVES", tostring(data.driveCount), data.itemTypes .. " item types", colors.yellow)
    tile((tileW * 2) + (gap * 2) + 1, y, w - ((tileW * 2) + (gap * 2)), "CPUs", tostring(#data.cpus), data.busyCpuCount .. " busy", colors.cyan)
    y = y + 4
  end

  if y <= bottom then
    clearLine(y, colors.lightGray)
    writeAt(2, y, "POWER", colors.black, colors.lightGray, w - 2)
    y = y + 1
    writeAt(2, y, "Stored", colors.lightGray, colors.black, 12)
    writeAt(15, y, fmt(data.energy) .. " / " .. (data.energyCap > 0 and fmt(data.energyCap) or "?"), colors.white, colors.black, w - 15)
    y = y + 1
    writeAt(2, y, "Flow", colors.lightGray, colors.black, 12)
    writeAt(15, y, fmt(data.input) .. "/t in   " .. fmt(data.usage) .. "/t used", colors.white, colors.black, w - 15)
    y = y + 2
  end

  if y <= bottom then
    clearLine(y, colors.lightGray)
    writeAt(2, y, "CRAFTING CPUs", colors.black, colors.lightGray, w - 2)
    y = y + 1
    if #data.cpus == 0 then
      writeAt(2, y, "No crafting CPU data exposed", colors.lightGray, colors.black, w - 2)
      y = y + 1
    else
      for _, cpu in ipairs(data.cpus) do
        if y > bottom - 2 then break end
        local name = cleanLabel(firstField(cpu, {"name", "displayName"}, "Unnamed CPU"))
        local storage = n(firstField(cpu, {"storage", "bytes"}, 0))
