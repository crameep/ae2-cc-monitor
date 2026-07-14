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
    data.movers = data.movers or {}
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
local sectionTabs = {}
local craftHistory = {}
local stockCraftHistory = {}
local patternCache = {}
local patternCacheTime = 0
local statusMessage = nil
local statusUntil = 0
local setStatus
local toolBusy = false
local diagnosticRequested = false
local lastPasteUrl = nil
local lastPasteError = nil
local lastDumpSize = 0
local lastDumpPreview = nil
local powerStats = {trendReady = false, netPerSecond = 0, netPerTick = 0, netPerMinute = 0, eta = 0, etaMode = nil}

if fs.exists(LAST_PASTE_FILE) then
  local h = fs.open(LAST_PASTE_FILE, "r")
  if h then
    lastPasteUrl = h.readAll()
    h.close()
    if lastPasteUrl == "" then lastPasteUrl = nil end
  end
end

local PAGE_ORDER = {"overview", "crafting", "stock", "storage", "movers", "system", "tools"}
local PAGE_TITLES = {
  overview = "OVERVIEW",
  crafting = "CRAFTING",
  stock = "STOCK WATCH",
  storage = "STORAGE",
  movers = "MOVERS",
  system = "SYSTEM",
  tools = "TOOLS"
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

local function getSectionTab(screen, page, fallback)
  sectionTabs[screen] = sectionTabs[screen] or {}
  return sectionTabs[screen][page] or fallback
end

local function setSectionTab(screen, page, tab)
  sectionTabs[screen] = sectionTabs[screen] or {}
  sectionTabs[screen][page] = tab
end

function setStatus(message, seconds)
  statusMessage = message
  statusUntil = nowSeconds() + (seconds or 8)
end

