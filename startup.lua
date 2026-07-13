-- AE2 Visual Monitor for CC:Tweaked + Advanced Peripherals
-- Requires an Advanced Peripherals ME Bridge on the AE2 network.
-- Install as startup.lua on the ComputerCraft computer.

local bridge = peripheral.find("me_bridge")
if not bridge then error("No me_bridge found. Attach an Advanced Peripherals ME Bridge.") end

local monitorTargets = {}
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "monitor" then
    local device = peripheral.wrap(name)
    if device then
      if device.setTextScale then
        device.setTextScale(1)
        local mw, mh = device.getSize()
        if mw < 42 or mh < 18 then device.setTextScale(0.5) end
      end
      monitorTargets[#monitorTargets + 1] = {name = name, device = device}
    end
  end
end
if #monitorTargets == 0 then
  monitorTargets[1] = {name = "terminal", device = term.current()}
end

local mon = monitorTargets[1].device

local VERSION = "2026-07-13.1"
local STATE_VERSION = 6
local UPDATE_URL = "https://raw.githubusercontent.com/crameep/ae2-cc-monitor/main/startup.lua"
local DUMP_URL = "https://raw.githubusercontent.com/crameep/ae2-cc-monitor/main/ae2-dump.lua"
local DUMP_SCRIPT = "ae2-dump.lua"
local DUMP_FILE = "ae2-dump.txt"
local LAST_PASTE_FILE = ".ae2_last_paste"
local PASTEBIN_KEY_FILE = ".ae2_pastebin_key"
local STATE_FILE = ".ae2_usage_state"
local BULK_HINTS_FILE = ".ae2_bulk_items"
local SAMPLE_SECONDS = 90
local WARMUP_SAMPLES = 3
local MIN_REAL_DROP = 512
local RECENT_DROP = 64
local RECENT_EVENTS_REQUIRED = 2
local RECENT_CONFIRM_SECONDS = 1800
local CONSUMED_WATCH = 2048
local DROP_EVENTS_REQUIRED = 2
local LOW_STOCK = 4096
local FAST_DROP = 1024
local PATTERN_REFRESH_SECONDS = 30

local function call(name, default)
  local f = bridge[name]
  if type(f) ~= "function" then return default end
  local ok, result = pcall(f)
  if ok and result ~= nil then return result end
  return default
end

local function callAny(names, default)
  for _, name in ipairs(names) do
    local f = bridge[name]
    if type(f) == "function" then
      local ok, result = pcall(f)
      if ok and result ~= nil then return result end
    end
  end
  return default
end

local function n(v)
  if type(v) == "number" then return v end
  if type(v) == "string" then return tonumber(v) or 0 end
  return 0
end

local function countTable(t)
  local c = 0
  for _ in pairs(t or {}) do c = c + 1 end
  return c
end

local function fmt(v)
  v = n(v)
  if v >= 1000000000 then return string.format("%.1fB", v / 1000000000) end
  if v >= 1000000 then return string.format("%.1fM", v / 1000000) end
  if v >= 1000 then return string.format("%.1fk", v / 1000) end
  return tostring(math.floor(v))
end

local function pct(used, total)
  used, total = n(used), n(total)
  if total <= 0 then return 0 end
  return math.max(0, math.min(100, (used / total) * 100))
end

local function amountOf(item)
  return n(item.amount or item.count or item.qty)
end

local function itemKey(item)
  return tostring(item.name or item.id or item.displayName or "unknown")
end

local function titleCase(text)
  return string.gsub(text, "(%a)([%w']*)", function(first, rest)
    return string.upper(first) .. string.lower(rest)
  end)
end

local function cleanLabel(text)
  text = tostring(text or "unknown")
  text = string.gsub(text, "^%[(.-)%]$", "%1")
  text = string.gsub(text, "^item%.", "")
  text = string.gsub(text, "^block%.", "")
  text = string.gsub(text, "^fluid%.", "")
  if string.find(text, ":", 1, true) and not string.find(text, " ", 1, true) then
    text = string.match(text, ":(.+)$") or text
  end
  text = string.gsub(text, "[_%.]+", " ")
  text = string.gsub(text, "%s+", " ")
  text = string.gsub(text, "^%s+", "")
  text = string.gsub(text, "%s+$", "")
  if text == "" then text = "unknown" end
  if not string.find(text, "%u") then text = titleCase(text) end
  return text
end

local function itemLabel(item)
  return cleanLabel(item.displayName or item.name or item.id or "unknown")
end

local function norm(text)
  text = string.lower(tostring(text or ""))
  text = string.gsub(text, "^item%.", "")
  text = string.gsub(text, "^block%.", "")
  text = string.gsub(text, "^fluid%.", "")
  text = string.gsub(text, "[_%.]+", " ")
  text = string.gsub(text, "%s+", " ")
  text = string.gsub(text, "^%s+", "")
  text = string.gsub(text, "%s+$", "")
  return text
end

local function gatherText(value, depth)
  depth = depth or 0
  if depth > 4 then return "" end
  local tv = type(value)
  if tv == "string" or tv == "number" or tv == "boolean" then
    return " " .. tostring(value)
  elseif tv ~= "table" then
    return ""
  end

  local parts = {}
  for k, v in pairs(value) do
    parts[#parts + 1] = gatherText(k, depth + 1)
    parts[#parts + 1] = gatherText(v, depth + 1)
  end
  return table.concat(parts, " ")
end

local function loadBulkHints()
  local hints = {}
  if not fs.exists(BULK_HINTS_FILE) then return hints end
  local h = fs.open(BULK_HINTS_FILE, "r")
  if not h then return hints end
  local raw = h.readAll() or ""
  h.close()
  for rawLine in string.gmatch(raw, "[^\r\n]+") do
    local line = string.gsub(rawLine, "#.*$", "")
    line = string.gsub(line, "^%s+", "")
    line = string.gsub(line, "%s+$", "")
    if line ~= "" then
      hints[norm(line)] = true
      hints[line] = true
    end
  end
  return hints
end

local function loadBulkHintLines()
  local lines = {}
  if not fs.exists(BULK_HINTS_FILE) then return lines end
  local h = fs.open(BULK_HINTS_FILE, "r")
  if not h then return lines end
  local raw = h.readAll() or ""
  h.close()
  for line in string.gmatch(raw, "[^\r\n]+") do
    local trimmed = string.gsub(line, "^%s+", "")
    trimmed = string.gsub(trimmed, "%s+$", "")
    if trimmed ~= "" then lines[#lines + 1] = trimmed end
  end
  return lines
end

local function saveBulkHintLines(lines)
  local h = fs.open(BULK_HINTS_FILE, "w")
  if not h then return false end
  for _, line in ipairs(lines or {}) do
    h.write(line .. "\n")
  end
  h.close()
  return true
end

local function toggleBulkHint(key, label)
  key = tostring(key or "")
  label = tostring(label or key)
  local keyNorm = norm(key)
  local labelNorm = norm(label)
  local lines = loadBulkHintLines()
  local kept = {}
  local removed = false

  for _, line in ipairs(lines) do
    local raw = string.gsub(line, "#.*$", "")
    raw = string.gsub(raw, "^%s+", "")
    raw = string.gsub(raw, "%s+$", "")
    local rawNorm = norm(raw)
    if rawNorm ~= "" and (rawNorm == keyNorm or rawNorm == labelNorm) then
      removed = true
    else
      kept[#kept + 1] = line
    end
  end

  if not removed then kept[#kept + 1] = key ~= "" and key or label end
  if not saveBulkHintLines(kept) then return nil end
  return not removed
end

local function isBulkCell(cell)
  local text = norm(gatherText(cell))
  return string.find(text, "bulk", 1, true)
    or string.find(text, "mega item cell", 1, true)
    or string.find(text, "mega bulk", 1, true)
    or string.find(text, "megacells:bulk", 1, true)
end

local function cellMatchesItem(cellText, item)
  local key = itemKey(item)
  local label = itemLabel(item)
  if key ~= "unknown" and string.find(cellText, norm(key), 1, true) then return true end
  local name = tostring(item.name or item.id or "")
  if name ~= "" and string.find(cellText, norm(name), 1, true) then return true end
  local fingerprint = tostring(item.fingerprint or "")
  if fingerprint ~= "" and string.find(cellText, norm(fingerprint), 1, true) then return true end
  if label ~= "unknown" and #label >= 6 and string.find(cellText, norm(label), 1, true) then return true end
  return false
end

local function cellExposesStoredItem(cell)
  if type(cell) ~= "table" then return false end
  local keys = {"storedItem", "partition", "partitionedItem", "filter", "config", "contents", "fingerprint"}
  for _, key in ipairs(keys) do
    if cell[key] ~= nil then return true end
  end
  return false
end

local function buildBulkIndex(cells, items)
  local index = {}
  local bulkCells = 0
  local matched = 0
  local autoAvailable = false
  local hints = loadBulkHints()

  for _, item in pairs(items or {}) do
    local key = itemKey(item)
    local label = itemLabel(item)
    if hints[norm(key)] or hints[key] or hints[norm(label)] then
      index[key] = "hint"
      matched = matched + 1
    end
  end

  for _, cell in pairs(cells or {}) do
    if isBulkCell(cell) then
      bulkCells = bulkCells + 1
      if cellExposesStoredItem(cell) then
        autoAvailable = true
        local cellText = norm(gatherText(cell))
        for _, item in pairs(items or {}) do
          local key = itemKey(item)
          if not index[key] and cellMatchesItem(cellText, item) then
            index[key] = "auto"
            matched = matched + 1
          end
        end
      end
    end
  end

  return index, bulkCells, matched, autoAvailable
end

local function shouldWatchItem(key, label)
  local text = string.lower(tostring(label or "") .. " " .. tostring(key or ""))
  if string.find(text, "spatial", 1, true) then return false end
  if string.find(text, "storage cell", 1, true) then return false end
  if string.find(text, "cell component", 1, true) then return false end
  if string.find(text, "crafting storage", 1, true) then return false end
  if string.find(text, "encoded pattern", 1, true) then return false end
  if string.find(text, "blank pattern", 1, true) then return false end
  if string.find(text, "pattern provider", 1, true) then return false end
  if string.find(text, "annihilation plane", 1, true) then return false end
  if string.find(text, "formation plane", 1, true) then return false end
  if string.find(text, "upgrade card", 1, true) then return false end
  return true
end

local function containsAny(text, needles)
  for _, needle in ipairs(needles) do
    if string.find(text, needle, 1, true) then return true end
  end
  return false
end

local function stockSearchText(key, label)
  local path = tostring(key or "")
  path = string.match(path, ":(.+)$") or path
  path = string.gsub(path, "[_%.]+", " ")
  return string.lower(tostring(label or "") .. " " .. path)
end

local function atm10StockRule(key, label, amount)
  if amount <= 0 then return nil end
  local text = stockSearchText(key, label)
  if not shouldWatchItem(key, label) then return false end

  local rules = {
    {
      label = "ATM metals", short = "ATM METAL", max = 512, priority = 100,
      needles = {"allthemodium", "vibranium", "unobtainium"},
      requireAny = {"ingot", "nugget", "raw", "ore", "block"},
      excludeAny = {"smithing template", "teleport pad", "sword", "pickaxe", "axe", "shovel", "hoe", "helmet", "chestplate", "leggings", "boots"}
    },
    {
      label = "ATM rares", short = "ATM RARE", max = 512, priority = 99,
      needles = {"piglich heart", "patrick star", "atm star", "star shard"}
    },
    {
      label = "ATM alloys", short = "ATM ALLOY", max = 1024, priority = 95,
      needles = {"vibranium allthemodium", "unobtainium vibranium", "unobtainium allthemodium", "awakened alloy", "alloy block"}
    },
    {
      label = "Mystical tiers", short = "MYSTICAL", max = 4096, priority = 90,
      needles = {
        "inferium essence", "prudentium essence", "tertium essence", "imperium essence",
        "supremium essence", "insanium essence", "awakened supremium essence",
        "prosperity shard", "soulium dust", "soulium ingot", "master infusion crystal"
      }
    },
    {
      label = "Mekanism chain", short = "MEKANISM", max = 2048, priority = 85,
      needles = {
        "osmium", "refined obsidian", "refined glowstone", "fluorite",
        "sulfur", "substrate", "hdpe", "polonium", "plutonium",
        "pellet antimatter", "antimatter", "fissile", "ultimate control circuit"
      },
      excludeAny = {"osmium compressor", "osmium armor", "osmium sword", "osmium pickaxe", "osmium axe", "osmium shovel", "osmium hoe"}
    },
    {
      label = "AE2 crafting", short = "AE2", max = 4096, priority = 80,
      needles = {
        "certus", "fluix", "sky stone", "charged certus", "quartz glass",
        "logic processor", "calculation processor", "engineering processor",
        "printed logic", "printed calculation", "printed engineering",
        "printed silicon", "annihilation core", "formation core", "singularity"
      }
    },
    {
      label = "Productive Bees", short = "BEES", max = 2048, priority = 75,
      needles = {"honey treat", "gene sample", "bee gene", "bee cage", "configurable honeycomb", "productivity upgrade"}
    },
    {
      label = "Powah", short = "POWAH", max = 2048, priority = 70,
      needles = {
        "uraninite", "dielectric paste", "blazing crystal", "niotic crystal",
        "spirited crystal", "nitro crystal", "energizing rod", "energizing orb", "capacitor"
      }
    },
    {
      label = "Occultism", short = "OCCULT", max = 1024, priority = 65,
      needles = {"iesnium", "spirit attuned", "otherstone", "datura", "chalk", "soul gem", "infused pickaxe", "dark gem"}
    },
    {
      label = "Ars Nouveau", short = "ARS", max = 1024, priority = 60,
      needles = {"source gem", "source jar", "magebloom", "archwood", "wilden horn", "wilden wing", "wilden spike", "blank glyph", "spell parchment"}
    },
    {
      label = "Create", short = "CREATE", max = 2048, priority = 55,
      needles = {"andesite alloy", "brass", "precision mechanism", "electron tube", "sturdy sheet", "chromatic compound", "shaft", "cogwheel", "belt connector"}
    },
    {
      label = "Industrial", short = "INDUSTRIAL", max = 2048, priority = 50,
      needles = {"stainless steel", "titanium", "tungsten", "platinum", "iridium", "kanthal", "cupronickel", "electrum", "invar", "constantan"},
      requireAny = {"ingot", "dust", "plate", "rod", "wire", "coil", "gear", "nugget"}
    },
    {
      label = "Pack utility", short = "UTILITY", max = 512, priority = 45,
      needles = {"eternal stella", "nether star crux", "dragon egg", "wither skeleton skull", "nether star"}
    }
  }

  for _, rule in ipairs(rules) do
    local matches = containsAny(text, rule.needles)
    local required = not rule.requireAny or containsAny(text, rule.requireAny)
    local excluded = rule.excludeAny and containsAny(text, rule.excludeAny)
    if amount <= rule.max and matches and required and not excluded then return rule end
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

local function cellHealth(cells)
  local nearFull, empty = 0, 0
  for _, cell in pairs(cells or {}) do
    local total = n(cell.bytes or cell.capacity)
    local used = n(cell.usedBytes or cell.used)
    if total > 0 then
      if used <= 0 then empty = empty + 1 end
      if used / total >= 0.95 then nearFull = nearFull + 1 end
    end
  end
  return nearFull, empty
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
local stockCraftHistory = {}
local patternCache = {}
local patternCacheTime = 0
local statusMessage = nil
local statusUntil = 0
local setStatus
local toolBusy = false
local lastPasteUrl = nil
local lastPasteError = nil
local lastDumpSize = 0

if fs.exists(LAST_PASTE_FILE) then
  local h = fs.open(LAST_PASTE_FILE, "r")
  if h then
    lastPasteUrl = h.readAll()
    h.close()
    if lastPasteUrl == "" then lastPasteUrl = nil end
  end
end

local PAGE_ORDER = {"overview", "crafting", "stock", "storage", "system", "tools"}
local PAGE_TITLES = {
  overview = "OVERVIEW",
  crafting = "CRAFTING",
  stock = "STOCK WATCH",
  storage = "STORAGE",
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
  local h = fs.open(DUMP_SCRIPT, "w")
  if not h then return false, "Cannot write " .. DUMP_SCRIPT end
  h.write(body)
  h.close()
  return true
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

local function uploadDumpToPastebin()
  if not http or not http.post then return nil, "HTTP POST is disabled" end
  local pastebinKey = loadPastebinKey()
  if not pastebinKey then return nil, "Missing " .. PASTEBIN_KEY_FILE end
  if not fs.exists(DUMP_FILE) or fs.isDir(DUMP_FILE) then return nil, "Diagnostic file was not created" end
  local h = fs.open(DUMP_FILE, "r")
  if not h then return nil, "Cannot read " .. DUMP_FILE end
  local body = h.readAll()
  h.close()
  lastDumpSize = #body
  if #body < 100 then return nil, "Diagnostic file is empty" end

  local response, err = http.post(
    "https://pastebin.com/api/api_post.php",
    "api_option=paste&" ..
    "api_dev_key=" .. textutils.urlEncode(pastebinKey) .. "&" ..
    "api_paste_format=lua&" ..
    "api_paste_name=" .. textutils.urlEncode("AE2 diagnostic " .. tostring(os.getComputerID())) .. "&" ..
    "api_paste_code=" .. textutils.urlEncode(body)
  )
  if not response then return nil, err or "Pastebin upload failed" end
  local result = response.readAll()
  response.close()
  if not result or not string.match(result, "^https?://pastebin%.com/[%a%d]+$") then
    return nil, result or "Pastebin returned no link"
  end
  return result
end

local function runDiagnosticUpload()
  if toolBusy then
    setStatus("Diagnostic already running")
    return true
  end
  toolBusy = true
  lastPasteError = nil
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
    setStatus("Dump failed: " .. lastPasteError)
    return true
  end

  setStatus("Uploading diagnostic to Pastebin...")
  local url, uploadError = uploadDumpToPastebin()
  toolBusy = false
  if not url then
    lastPasteError = tostring(uploadError)
    setStatus("Upload failed: " .. lastPasteError)
    return true
  end

  lastPasteUrl = url
  local h = fs.open(LAST_PASTE_FILE, "w")
  if h then h.write(url); h.close() end
  setStatus("Paste ready: " .. url)
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
      elseif button.action == "diagnostic" then
        return runDiagnosticUpload()
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
    and {"OVERVIEW", "CRAFTING", "STOCK", "STORAGE", "SYSTEM", "TOOLS"}
    or {"HOME", "CRAFT", "STOCK", "STORE", "SYS", "MORE"}
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
  local bottom = h - 1
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
  pageControls(screen, "crafting", 3, pageNumber, pageCount)

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
  local bottom = h - 1
  local y = 3

  clearLine(y, colors.black)
  local summary = #data.warnings .. " warning" .. (#data.warnings == 1 and "" or "s")
    .. "  |  " .. #data.recent .. " moving"
    .. "  |  " .. #data.lowStock .. " low"
  writeAt(2, y, summary, colors.lightGray, colors.black, w - 2)
  y = y + 1

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
  writeAt(2, headerY, "ATM10 LOW STOCK", colors.black, colors.yellow, math.max(8, w - 18))
  local pageText = tostring(pageNumber) .. "/" .. tostring(pageCount)
  local nextX = math.max(1, w - 2)
  local pageX = math.max(1, nextX - #pageText - 2)
  local prevX = math.max(1, pageX - 4)
  writeAt(prevX, headerY, " < ", pageNumber > 1 and colors.white or colors.gray, colors.blue, 3)
  writeAt(pageX, headerY, pageText, colors.black, colors.yellow, #pageText)
  writeAt(nextX, headerY, ">", pageNumber < pageCount and colors.white or colors.gray, colors.blue, 1)
  if pageNumber > 1 then registerButton(screen, {x = prevX, x2 = prevX + 2, y = headerY, action = "page", page = "stock", delta = -1}) end
  if pageNumber < pageCount then registerButton(screen, {x = nextX, x2 = w, y = headerY, action = "page", page = "stock", delta = 1}) end

  local amountW = w >= 70 and 13 or 10
  local groupW = w >= 70 and 12 or 8
  local amountX = w - amountW + 1
  local groupX = amountX - groupW - 1
  local itemW = math.max(8, groupX - 3)

  clearLine(columnY, colors.lightGray)
  writeAt(2, columnY, "ITEM", colors.black, colors.lightGray, itemW)
  writeAt(groupX, columnY, "GROUP", colors.black, colors.lightGray, groupW)
  writeAt(amountX, columnY, "COUNT/TARGET", colors.black, colors.lightGray, amountW)

  if #data.lowStock == 0 then
    writeAt(2, firstRowY, "No watched ATM10 bottlenecks are low", colors.lightGray, colors.black, w - 2)
    return
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
    rowY = rowY + 1
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
  local bulkText = data.bulkAutoAvailable and (data.bulkItemMatches .. " bulk-marked") or (data.bulkItemMatches .. " manual bulk | auto unavailable")
  writeAt(2, y, #data.top .. " item types  |  " .. bulkText .. "  |  " .. data.nearFullCellCount .. " cells >95%", colors.lightGray, colors.black, math.max(8, w - 24))
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
    tile(1, y, tileW, "CELLS", tostring(data.cellCount), data.nearFullCellCount .. " near full / " .. data.emptyCellCount .. " empty", colors.green)
    tile(tileW + gap + 1, y, tileW, "PATTERNS", tostring(data.patternCount), data.driveDataAvailable and (data.driveCount .. " drives") or "drive data N/A", colors.yellow)
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
    local netText = (data.powerNet >= 0 and "+" or "") .. fmt(data.powerNet) .. "/t net"
    writeAt(15, y, fmt(data.input) .. "/t in  " .. fmt(data.usage) .. "/t used  " .. netText, colors.white, colors.black, w - 15)
    y = y + 1
    if data.powerNet < 0 and data.powerBufferSeconds > 0 then
      writeAt(2, y, "Buffer", colors.lightGray, colors.black, 12)
      writeAt(15, y, "~" .. duration(data.powerBufferSeconds) .. " at current drain", colors.orange, colors.black, w - 15)
      y = y + 1
    end
    y = y + 1
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

  if y <= bottom then
    y = math.max(y + 1, bottom - 1)
    if y <= bottom then
      writeAt(2, y, "v" .. VERSION .. "  |  refresh 3s  |  usage sample " .. SAMPLE_SECONDS .. "s", colors.lightGray, colors.black, w - 2)
    end
  end
end

local function renderTools(screen, data, h)
  local w = mon.getSize()
  local bottom = h - 1
  local y = 3

  clearLine(y, colors.lightGray)
  writeAt(2, y, "AE2 DIAGNOSTIC", colors.black, colors.lightGray, w - 2)
  y = y + 2

  local buttonText = toolBusy and " DIAGNOSTIC RUNNING... " or " CREATE + UPLOAD AE2 DUMP "
  local buttonWidth = math.min(w - 4, #buttonText + 4)
  local buttonX = math.max(2, math.floor((w - buttonWidth) / 2) + 1)
  fillRect(buttonX, y, buttonWidth, 3, toolBusy and colors.gray or colors.blue)
  centerText(y + 1, buttonText, colors.white, toolBusy and colors.gray or colors.blue, buttonWidth)
  if not toolBusy then
    registerButton(screen, {x = buttonX, x2 = buttonX + buttonWidth - 1, y = y, y2 = y + 2, action = "diagnostic"})
  end
  y = y + 5

  if y <= bottom then
    writeAt(2, y, "Scans peripherals and safe ME Bridge getters, then uploads", colors.lightGray, colors.black, w - 2)
    y = y + 1
  end
  if y <= bottom then
    writeAt(2, y, "ae2-dump.txt and uploads if " .. PASTEBIN_KEY_FILE .. " exists.", colors.lightGray, colors.black, w - 2)
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
  elseif page == "system" then
    renderSystem(screen, data, h)
  elseif page == "tools" then
    renderTools(screen, data, h)
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
  local patterns = getPatternCache()
  enrichTasks(tasks, items, patterns)

  local itemTypes, itemCount = 0, 0
  local bulkIndex, bulkCellCount, bulkItemMatches, bulkAutoAvailable = buildBulkIndex(cells, items)
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
        lowStock[#lowStock + 1] = {name = label, amount = amount, target = stockRule.max, ratio = amount / math.max(1, stockRule.max), priority = stockRule.priority, group = stockRule.short or stockRule.label}
      end
    end
  end
  table.sort(top, function(a, b) return a.amount > b.amount end)
  table.sort(lowStock, function(a, b)
    if a.priority ~= b.priority then return a.priority > b.priority end
    if a.ratio ~= b.ratio then return a.ratio < b.ratio end
    return a.name < b.name
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
  local powerNet = input - usage
  local powerBufferSeconds = powerNet < 0 and energy / math.max(1, (-powerNet) * 20) or 0
  local nearFullCellCount, emptyCellCount = cellHealth(cells)
  local driveCount = countTable(drives)
  local driveDataAvailable = driveCount > 0 or countTable(cells) == 0

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
  elseif powerNet < 0 and powerBufferSeconds > 0 and powerBufferSeconds < 1800 then
    health, healthColor, healthDetail = "POWER DRAIN", colors.orange, "~" .. duration(powerBufferSeconds) .. " buffer remaining"
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
    driveCount = driveCount,
    driveDataAvailable = driveDataAvailable,
    patternCount = countTable(patterns),
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
    powerNet = powerNet,
    powerBufferSeconds = powerBufferSeconds,
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
    bulkAutoAvailable = bulkAutoAvailable,
    nearFullCellCount = nearFullCellCount,
    emptyCellCount = emptyCellCount,
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
