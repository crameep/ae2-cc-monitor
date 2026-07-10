      label = "Industrial",
      max = 2048,
      priority = 50,
      needles = {
        "modern industrialization", "stainless steel", "titanium", "tungsten",
        "platinum", "iridium", "kanthal", "cupronickel", "electrum",
        "invar", "constantan"
      }
    },
    {
      label = "Pack utility",
      max = 512,
      priority = 45,
      needles = {
        "eternal stella", "nether star crux", "dragon egg", "wither skeleton skull",
        "nether star"
      }
    }
  }

  for _, rule in ipairs(rules) do
    if amount <= rule.max and containsAny(text, rule.needles) then
      return rule
    end
  end
  return nil
end

local function set(fg, bg)
  mon.setTextColor(fg or colors.white)
  mon.setBackgroundColor(bg or colors.black)
end

local function clearLine(y, bg)
  local w = mon.getSize()
  mon.setCursorPos(1, y)
  set(colors.white, bg or colors.black)
  mon.write(string.rep(" ", w))
end

local function writeAt(x, y, text, fg, bg, maxLen)
  local w = mon.getSize()
  if x > w then return end
  if maxLen then text = string.sub(text, 1, maxLen) end
  mon.setCursorPos(x, y)
  set(fg, bg)
  mon.write(string.sub(text, 1, math.max(0, w - x + 1)))
end

local function fillRect(x, y, rw, rh, bg)
  local w, h = mon.getSize()
  set(colors.white, bg)
  for yy = y, math.min(h, y + rh - 1) do
    if yy >= 1 then
      mon.setCursorPos(x, yy)
      mon.write(string.rep(" ", math.max(0, math.min(rw, w - x + 1))))
    end
  end
end

local function tile(x, y, w, title, value, sub, bg)
  fillRect(x, y, w, 3, bg)
  writeAt(x + 1, y, title, colors.black, bg, w - 2)
  writeAt(x + 1, y + 1, value, colors.black, bg, w - 2)
  writeAt(x + 1, y + 2, sub, colors.black, bg, w - 2)
end

local function bar(x, y, w, label, used, total, color)
  local p = pct(used, total)
  local sw = mon.getSize()
  local labelW = math.min(20, math.max(10, math.floor(sw * 0.34)))
  local barX = x + labelW + 1
  local pctW = 4
  local actualW = math.max(6, sw - barX - pctW)
  local fill = math.floor((p / 100) * actualW + 0.5)
  local totalText = total > 0 and fmt(total) or "?"
  writeAt(x, y, label .. " " .. fmt(used) .. "/" .. totalText, colors.white, colors.black, labelW)
  fillRect(barX, y, actualW, 1, colors.gray)
  fillRect(barX, y, fill, 1, color)
  writeAt(sw - 3, y, string.format("%3d%%", math.floor(p + 0.5)), colors.white, colors.black, 4)
end

local function typeSlots(cells)
  local itemCells, fluidCells = 0, 0
  for _, cell in pairs(cells or {}) do
    local info = ""
    for k, v in pairs(cell) do
      if type(v) == "string" or type(v) == "number" then
        info = info .. " " .. tostring(k) .. "=" .. tostring(v)
      end
    end
    info = info:lower()
    if string.find(info, "fluid") or string.find(info, "chemical") then
      fluidCells = fluidCells + 1
    elseif string.find(info, "item") or string.find(info, "storage") or info ~= "" then
      itemCells = itemCells + 1
    end
  end
  return itemCells * 63, fluidCells * 63, itemCells, fluidCells
end

local function loadState()
  if not fs.exists(STATE_FILE) then return {last = {}, tracked = {}, warnings = {}, ignored = {}, stateVersion = STATE_VERSION, lastSample = 0} end
  local h = fs.open(STATE_FILE, "r")
  if not h then return {last = {}, tracked = {}, warnings = {}, ignored = {}, stateVersion = STATE_VERSION, lastSample = 0} end
  local raw = h.readAll()
  h.close()
  local ok, data = pcall(textutils.unserialize, raw)
  if ok and type(data) == "table" then
    if data.stateVersion ~= STATE_VERSION then
      return {last = {}, tracked = {}, warnings = {}, ignored = data.ignored or {}, stateVersion = STATE_VERSION, lastSample = 0}
    end
    data.last = data.last or {}
    data.tracked = data.tracked or {}
    data.warnings = data.warnings or {}
    data.recent = data.recent or {}
    data.recentCandidates = data.recentCandidates or {}
    data.ignored = data.ignored or {}
    data.lastSample = data.lastSample or 0
    return data
  end
  return {last = {}, tracked = {}, warnings = {}, ignored = {}, stateVersion = STATE_VERSION, lastSample = 0}
end

local function saveState(state)
  local h = fs.open(STATE_FILE, "w")
  if not h then return end
  h.write(textutils.serialize(state))
  h.close()
end

local usageState = loadState()
local warningButtons = {}
local bulkButtons = {}
local uiButtons = {}
local currentPages = {}
local listPages = {}
local craftHistory = {}
local statusMessage = nil
local statusUntil = 0
local setStatus

local PAGE_ORDER = {"overview", "crafting", "stock", "storage", "system"}
local PAGE_TITLES = {
  overview = "OVERVIEW",
  crafting = "CRAFTING",
  stock = "STOCK WATCH",
  storage = "STORAGE",
  system = "SYSTEM"
}

local function nowSeconds()
  return os.epoch and math.floor(os.epoch("utc") / 1000) or os.time()
end

local function filteredWarnings(warnings)
  local filtered = {}
  for _, warning in ipairs(warnings or {}) do
    if not usageState.ignored[warning.key] then
      filtered[#filtered + 1] = warning
    end
  end
  return filtered
end

local function callAnyArg(names, arg, default)
  for _, name in ipairs(names or {}) do
    local f = bridge[name]
    if type(f) == "function" then
      local ok, result = pcall(f, arg)
      if ok and result ~= nil then return result end
      ok, result = pcall(f)
      if ok and result ~= nil then return result end
    end
  end
  return default
end

local function methodValue(object, names, default)
  if type(object) ~= "table" then return default end
  for _, name in ipairs(names or {}) do
    local value = object[name]
    if type(value) == "function" then
      local ok, result = pcall(value)
      if not ok then ok, result = pcall(value, object) end
      if ok and result ~= nil then return result end
    elseif value ~= nil then
      return value
    end
  end
  return default
end

local function firstField(object, names, default)
  if type(object) ~= "table" then return default end
  for _, name in ipairs(names or {}) do
    local value = object[name]
    if value ~= nil and type(value) ~= "function" then return value end
  end
