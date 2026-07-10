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
  local message
  if statusIsActive() then
    message = statusMessage
  else
    message = data.health .. "  |  " .. data.healthDetail
  end
  writeAt(2, 2, message, colors.black, stripColor, w - 2)
end

local function drawNav(screen, page, h)
  local w = mon.getSize()
  local labels = w >= 58
    and {"OVERVIEW", "CRAFTING", "STOCK", "STORAGE", "SYSTEM"}
    or {"HOME", "CRAFT", "STOCK", "STORE", "SYS"}
  local x = 1
  for i, pageName in ipairs(PAGE_ORDER) do
    local remaining = w - x + 1
    local remainingTabs = #PAGE_ORDER - i + 1
    local tabW = math.floor(remaining / remainingTabs)
    local x2 = i == #PAGE_ORDER and w or x + tabW - 1
    local active = pageName == page
    local bg = active and colors.cyan or colors.gray
    local fg = active and colors.black or colors.white
    fillRect(x, h, x2 - x + 1, 1, bg)
    local label = labels[i]
    local labelX = x + math.max(0, math.floor(((x2 - x + 1) - #label) / 2))
    writeAt(labelX, h, label, fg, bg, x2 - labelX + 1)
    registerButton(screen, {x = x, x2 = x2, y = h, action = "nav", page = pageName})
    x = x2 + 1
  end
end

local function pageControls(screen, page, y, pageNumber, pageCount)
  local w = mon.getSize()
  pageNumber = math.max(1, math.min(pageNumber, pageCount))
  local text = "PAGE " .. pageNumber .. "/" .. pageCount
  writeAt(math.max(1, w - #text - 12), y, text, colors.lightGray, colors.black, #text)
  local prevX = math.max(1, w - 10)
  local nextX = math.max(1, w - 4)
  writeAt(prevX, y, "<", pageNumber > 1 and colors.white or colors.gray, colors.blue, 3)
  writeAt(nextX, y, ">", pageNumber < pageCount and colors.white or colors.gray, colors.blue, 3)
  if pageNumber > 1 then registerButton(screen, {x = prevX, x2 = prevX + 2, y = y, action = "page", page = page, delta = -1}) end
  if pageNumber < pageCount then registerButton(screen, {x = nextX, x2 = nextX + 2, y = y, action = "page", page = page, delta = 1}) end
end

local function renderOverview(screen, data, h)
  local w = mon.getSize()
  local bottom = h - 1
  local y = 3

  if bottom - y >= 8 and w >= 42 then
    local gap = 1
    local tileW = math.floor((w - (gap * 2)) / 3)
    tile(1, y, tileW, "ITEM STORAGE", math.floor(data.itemPct + 0.5) .. "%", fmt(data.itemUsed) .. " / " .. (data.itemTotal > 0 and fmt(data.itemTotal) or "?"), colors.green)
    tile(tileW + gap + 1, y, tileW, "TYPE SLOTS", math.floor(data.typePct + 0.5) .. "%", data.itemTypes .. " / " .. (data.itemTypeTotal > 0 and data.itemTypeTotal or "?"), colors.yellow)
    tile((tileW * 2) + (gap * 2) + 1, y, w - ((tileW * 2) + (gap * 2)), "POWER", math.floor(data.powerPct + 0.5) .. "%", fmt(data.usage) .. "/t use", colors.orange)
    y = y + 4
  end

  capacityRow(y, "Items", data.itemUsed, data.itemTotal, colors.lime); y = y + 1
  capacityRow(y, "Types", data.itemTypes, data.itemTypeTotal, colors.yellow); y = y + 1
  capacityRow(y, "Fluids", data.fluidUsed, data.fluidTotal, colors.blue); y = y + 1
  capacityRow(y, "Power", data.energy, data.energyCap, colors.orange); y = y + 2

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
        local pctText = string.format("%3d%%", math.floor(task.completion * 100 + 0.5))
        local detail = task.quantity > 0 and (fmt(task.crafted) .. "/" .. fmt(task.quantity)) or "running"
        writeAt(2, y, task.name, colors.cyan, colors.black, math.max(8, w - #pctText - #detail - 6))
        writeAt(math.max(1, w - #detail - #pctText - 2), y, detail .. " " .. pctText, colors.white, colors.black)
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
  local bottom = h - 1
  clearLine(3, colors.black)
  writeAt(2, 3, tostring(#data.tasks) .. " active job(s)  |  " .. data.busyCpuCount .. "/" .. #data.cpus .. " CPUs busy", colors.lightGray, colors.black, math.max(8, w - 25))

  if #data.tasks == 0 then
    if data.busyCpuCount > 0 then
      centerText(math.min(bottom, 7), "CRAFTING DETECTED", colors.cyan, colors.black, w)
      if math.min(bottom, 9) <= bottom then centerText(math.min(bottom, 9), "CPU busy; this AP build did not expose job details.", colors.lightGray, colors.black, w) end
    else
      centerText(math.min(bottom, 7), "NO ACTIVE CRAFTING JOBS", colors.cyan, colors.black, w)
      if math.min(bottom, 9) <= bottom then centerText(math.min(bottom, 9), "Start a craft from an AE2 terminal to see it here.", colors.lightGray, colors.black, w) end
    end
    local y = 12
    if y <= bottom then
      clearLine(y, colors.lightGray)
      writeAt(2, y, "CRAFTING CPUs", colors.black, colors.lightGray, w - 2)
      y = y + 1
      for _, cpu in ipairs(data.cpus) do
        if y > bottom then break end
        local name = cleanLabel(firstField(cpu, {"name", "displayName"}, "Unnamed CPU"))
        local storage = n(firstField(cpu, {"storage", "bytes"}, 0))
        local co = n(firstField(cpu, {"coProcessors", "coprocessors"}, 0))
        local busy = cpuBusy(cpu)
        writeAt(2, y, name, busy and colors.cyan or colors.white, colors.black, math.max(8, w - 26))
        writeAt(math.max(1, w - 24), y, (busy and "BUSY" or "IDLE") .. "  " .. fmt(storage) .. "B  " .. co .. " co", busy and colors.cyan or colors.lightGray, colors.black, 24)
        y = y + 1
