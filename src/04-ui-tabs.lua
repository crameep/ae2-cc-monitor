local function drawSubtabs(screen, page, active, tabs, y)
  local w = mon.getSize()
  local tabCount = #tabs
  local tabW = math.max(1, math.floor(w / tabCount))
  local x = 1
  for i, tab in ipairs(tabs) do
    local x2 = i == tabCount and w or math.min(w, x + tabW - 1)
    local width = math.max(1, x2 - x + 1)
    local selected = tab.key == active
    local bg = selected and colors.lime or colors.gray
    local fg = selected and colors.black or colors.white
    fillRect(x, y, width, 1, bg)
    local label = tab.label
    if #label > width then label = string.sub(label, 1, width) end
    writeAt(x + math.max(0, math.floor((width - #label) / 2)), y, label, fg, bg, width)
    registerButton(screen, {x = x, x2 = x2, y = y, action = "subtab", page = page, tab = tab.key})
    x = x2 + 1
  end
  return y + 1
end

local function renderFluidRows(screen, pageKey, rows, y, bottom, navY, emptyText)
  local w = mon.getSize()
  local rowsAvailable = math.max(1, bottom - y + 1)
  local pageCount = math.max(1, math.ceil(#rows / rowsAvailable))
  listPages[screen] = listPages[screen] or {}
  local pageNumber = math.min(pageCount, math.max(1, n(listPages[screen][pageKey] or 1)))
  listPages[screen][pageKey] = pageNumber
  bottomPageControls(screen, pageKey, navY, pageNumber, pageCount)

  if #rows == 0 then
    writeAt(2, y, emptyText or "No fluids reported", colors.lightGray, colors.black, w - 2)
    return
  end

  local startIndex = ((pageNumber - 1) * rowsAvailable) + 1
  for i = startIndex, math.min(#rows, startIndex + rowsAvailable - 1) do
    if y > bottom then break end
    local fluid = rows[i]
    local amountText = fmt(fluid.amount)
    local amountW = math.min(14, math.max(10, #amountText))
    local bg = (i % 2 == 0) and colors.gray or colors.black
    clearLine(y, bg)
    writeAt(2, y, fluid.name, colors.cyan, bg, math.max(8, w - amountW - 3))
    writeAt(math.max(1, w - amountW + 1), y, amountText, colors.white, bg, amountW)
    y = y + 1
  end
end

