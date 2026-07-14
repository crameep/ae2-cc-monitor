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

local VERSION = "2026-07-14.11"
local STATE_VERSION = 6
local UPDATE_URL = "https://raw.githubusercontent.com/crameep/ae2-cc-monitor/main/startup.lua"
local DUMP_URL = "https://raw.githubusercontent.com/crameep/ae2-cc-monitor/23faa7e/ae2-dump.lua"
local DUMP_SCRIPT = "ae2-dump.lua"
local DUMP_FILE = "ae2-dump.json"
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
local HUGE_ITEM_COUNT = 1000000000
local PATTERN_REFRESH_SECONDS = 30
local FLUX_FE_PER_BYTE = 1048576

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
      local state = "inf"
      local key = line
      local explicitState, explicitKey = string.match(line, "^(%S+)%s+(.+)$")
      if explicitState and explicitKey then
        local lowered = string.lower(explicitState)
        if lowered == "bulk" or lowered == "@bulk" then
          state = "bulk"
          key = explicitKey
        elseif lowered == "inf" or lowered == "@inf" or lowered == "infinity" or lowered == "@infinity" then
          state = "inf"
          key = explicitKey
        end
      end
      hints[norm(key)] = state
      hints[key] = state
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

local function parseBulkHintLine(line)
  local raw = string.gsub(tostring(line or ""), "#.*$", "")
  raw = string.gsub(raw, "^%s+", "")
  raw = string.gsub(raw, "%s+$", "")
  if raw == "" then return nil, nil end

  local state = "inf"
  local value = raw
  local explicitState, explicitValue = string.match(raw, "^(%S+)%s+(.+)$")
  if explicitState and explicitValue then
    local lowered = string.lower(explicitState)
    if lowered == "bulk" or lowered == "@bulk" then
      state = "bulk"
      value = explicitValue
    elseif lowered == "inf" or lowered == "@inf" or lowered == "infinity" or lowered == "@infinity" then
      state = "inf"
      value = explicitValue
    end
  end
  return state, value
end

local function cycleBulkHint(key, label, fallbackState)
  key = tostring(key or "")
  label = tostring(label or key)
  local keyNorm = norm(key)
  local labelNorm = norm(label)
  local lines = loadBulkHintLines()
  local kept = {}
  local currentState = nil

  for _, line in ipairs(lines) do
    local state, value = parseBulkHintLine(line)
    local valueNorm = norm(value)
    if valueNorm ~= "" and (valueNorm == keyNorm or valueNorm == labelNorm) then
      currentState = state or "inf"
    else
      kept[#kept + 1] = line
    end
  end

  local value = key ~= "" and key or label
  local nextState = nil
  if currentState == nil and fallbackState == "bulk" then
    nextState = "inf"
    kept[#kept + 1] = "inf " .. value
  elseif currentState == nil then
    nextState = "bulk"
    kept[#kept + 1] = "bulk " .. value
  elseif currentState == "bulk" then
    nextState = "inf"
    kept[#kept + 1] = "inf " .. value
  end
  if not saveBulkHintLines(kept) then return nil end
  return nextState or "normal"
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
  local manualBulk = 0
  local manualInf = 0
  local autoAvailable = false
  local hints = loadBulkHints()

  for _, item in pairs(items or {}) do
    local key = itemKey(item)
    local label = itemLabel(item)
    local hintState = hints[norm(key)] or hints[key] or hints[norm(label)]
    if hintState then
      index[key] = hintState
      matched = matched + 1
      if hintState == "inf" then manualInf = manualInf + 1 else manualBulk = manualBulk + 1 end
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
            index[key] = "bulk"
            matched = matched + 1
          end
        end
      end
    end
  end

  return index, {
    bulkCellCount = bulkCells,
    bulkItemMatches = matched,
    bulkAutoAvailable = autoAvailable,
    manualBulkCount = manualBulk,
    manualInfCount = manualInf
  }
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

local function cellName(cell)
  if type(cell) ~= "table" then return "unknown cell" end
  local item = cell.item
  if type(item) == "table" then
    return tostring(item.displayName or item.name or item.id or "unknown cell")
  end
  return tostring(cell.name or cell.id or cell.type or "unknown cell")
end

local function summarizeCells(cells)
  local groupsByKey, groups = {}, {}
  for _, cell in pairs(cells or {}) do
    if type(cell) == "table" then
      local name = cellName(cell)
      local cellType = tostring(cell.type or "?")
      local key = name .. "|" .. cellType
      local group = groupsByKey[key]
      if not group then
        group = {name = cleanLabel(name), type = cellType, count = 0, nonempty = 0, used = 0, total = 0}
        groupsByKey[key] = group
        groups[#groups + 1] = group
      end
      group.count = group.count + 1
      local used = n(cell.usedBytes or cell.bytesUsed or cell.used)
      local total = n(cell.bytes or cell.totalBytes or cell.capacity or cell.total)
      group.used = group.used + used
      group.total = group.total + total
      if used > 0 then group.nonempty = group.nonempty + 1 end
    end
  end
  table.sort(groups, function(a, b)
    if a.type ~= b.type then return a.type < b.type end
    if a.total ~= b.total then return a.total > b.total end
    return a.name < b.name
  end)
  return groups
end

local function topFluids(fluids, limit)
  local rows = {}
  for _, fluid in pairs(fluids or {}) do
    local amount = amountOf(fluid)
    if amount > 0 then
      rows[#rows + 1] = {name = itemLabel(fluid), key = itemKey(fluid), amount = amount}
    end
  end
  table.sort(rows, function(a, b) return a.amount > b.amount end)
  while limit and #rows > limit do rows[#rows] = nil end
  return rows
end

local function fluxCellCapacity(cells)
  local capacity, cellCount, usedEstimate, usedCellCount = 0, 0, 0, 0
  for _, cell in pairs(cells or {}) do
    local text = norm(gatherText(cell))
    if string.find(text, "appflux:fe_", 1, true)
      or string.find(text, "me fe storage cell", 1, true)
      or string.find(text, "fe storage cell", 1, true) then
      local bytes = n(cell.totalBytes or cell.bytes or cell.capacity or cell.total)
      if bytes > 0 then
        capacity = capacity + (bytes * FLUX_FE_PER_BYTE)
        cellCount = cellCount + 1
      end
      local usedBytes = n(cell.usedBytes or cell.bytesUsed or cell.used)
      if usedBytes > 0 then
        usedEstimate = usedEstimate + (usedBytes * FLUX_FE_PER_BYTE)
        usedCellCount = usedCellCount + 1
      end
    end
  end
  return capacity, cellCount, usedEstimate, usedCellCount
end

local function fluxKeyScore(row)
  local key = string.lower(itemKey(row))
  local name = string.lower(tostring(row.name or row.id or row.resource or ""))
  local display = norm(tostring(row.displayName or row.label or ""))
  local text = norm(gatherText(row))
  local score = 0

  if key == "appflux:fe" or name == "appflux:fe" then score = score + 100 end
  if display == "fe" or display == "energy" then score = score + 40 end
  if string.find(text, "fluxkey", 1, true) and string.find(text, "fe", 1, true) then score = score + 80 end
  if string.find(text, "appflux.type.fe", 1, true) or string.find(text, "appflux:fe", 1, true) then score = score + 60 end
  if string.find(text, "appflux.key.flux", 1, true) or string.find(text, "energytype", 1, true) then score = score + 20 end

  if string.find(text, "storage cell", 1, true) or string.find(text, "portable cell", 1, true) then score = score - 100 end
  if string.find(text, "processor", 1, true) or string.find(text, "crystal", 1, true) or string.find(text, "dust", 1, true) then score = score - 80 end
  return score
end

local function findFluxStored(...)
  local best, bestScore = nil, 0
  for i = 1, select("#", ...) do
    local rows = select(i, ...)
    for _, row in pairs(rows or {}) do
      local amount = amountOf(row)
      if amount > 0 then
        local score = fluxKeyScore(row)
        if score > bestScore then
          best = row
          bestScore = score
        end
      end
    end
  end
  if best then return amountOf(best), itemLabel(best), bestScore end
  return nil, nil, 0
end

local FLUX_PROBE_FILTERS = {
  {name = "appflux:fe"},
  {id = "appflux:fe"},
  {fingerprint = "appflux:fe"},
  {resource = "appflux:fe"},
  {type = "appflux:fe"},
  {name = "appflux:fe", displayName = "FE"}
}

local FLUX_PROBE_METHODS = {"getItem", "getChemical", "getFluid", "getAmount"}

local function addFluxProbeResult(rows, method, filter, result)
  if result == nil then return end
  if type(result) == "number" and result > 0 then
    rows[#rows + 1] = {name = "appflux:fe", displayName = "FE", amount = result, _source = method, _filter = filter}
  elseif type(result) == "table" then
    local amount = amountOf(result)
    if amount > 0 then
      result._source = method
      result._filter = filter
      rows[#rows + 1] = result
    else
      for _, child in pairs(result) do
        if type(child) == "table" and amountOf(child) > 0 then
          child._source = method
          child._filter = filter
          rows[#rows + 1] = child
        end
      end
    end
  end
end

local function collectFluxProbeRows()
  local rows = {}
  for _, method in ipairs(FLUX_PROBE_METHODS) do
    local f = bridge[method]
    if type(f) == "function" then
      for _, filter in ipairs(FLUX_PROBE_FILTERS) do
        local ok, result = pcall(f, filter)
        if ok then addFluxProbeResult(rows, method, filter, result) end
      end
      local ok, result = pcall(f, "appflux:fe")
      if ok then addFluxProbeResult(rows, method, "appflux:fe", result) end
    end
  end
  return rows
end

local function detectFluxEnergy(items, fluids, chemicals, probeRows, cells, bufferStored, bufferCapacity)
  local capacity, cellCount, usedEstimate, usedCellCount = fluxCellCapacity(cells)
  local stored, label, score = findFluxStored(probeRows, items, fluids, chemicals)
  if stored then
    return {
      stored = stored,
      capacity = capacity,
      known = true,
      estimated = false,
      source = label or "Applied Flux FE",
      score = score,
      probeCount = countTable(probeRows),
      cellCount = cellCount,
      bufferStored = n(bufferStored),
      bufferCapacity = n(bufferCapacity)
    }
  end
  if usedEstimate > 0 then
    return {
      stored = usedEstimate,
      capacity = capacity,
      known = true,
      estimated = true,
      source = "FE cell byte estimate",
      score = 1,
      probeCount = countTable(probeRows),
      cellCount = cellCount,
      usedCellCount = usedCellCount,
      bufferStored = n(bufferStored),
      bufferCapacity = n(bufferCapacity)
    }
  end
  return {
    stored = nil,
    capacity = capacity,
    known = false,
    estimated = false,
    source = cellCount > 0 and "FE cells found; stored amount not exposed" or "FE cells not visible",
    score = 0,
    probeCount = countTable(probeRows),
    cellCount = cellCount,
    usedCellCount = usedCellCount,
    bufferStored = n(bufferStored),
    bufferCapacity = n(bufferCapacity)
  }
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
  if fs.exists(DUMP_SCRIPT) then fs.delete(DUMP_SCRIPT) end
  local h = fs.open(DUMP_SCRIPT, "w")
  if not h then return false, "Cannot write " .. DUMP_SCRIPT end
  h.write(body)
  h.close()
  return true
end

local function readDumpPreview()
  if not fs.exists(DUMP_FILE) or fs.isDir(DUMP_FILE) then return nil end
  local h = fs.open(DUMP_FILE, "r")
  if not h then return nil end
  local body = h.readAll() or ""
  h.close()
  body = string.gsub(body, "\n", " ")
  body = string.gsub(body, "%s+", " ")
  if body == "" then return nil end
  return string.sub(body, 1, 160)
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

local function pastebinUrlFromOutput(output)
  output = tostring(output or "")
  local url = string.match(output, "https?://pastebin%.com/raw/[%w]+")
    or string.match(output, "https?://pastebin%.com/[%w]+")
  if url then return string.gsub(url, "/raw/", "/") end
  local code = string.match(output, "pastebin%.com/([%w]+)")
    or string.match(output, "Uploaded as%s+([%w]+)")
    or string.match(output, "uploaded as%s+([%w]+)")
  if code then return "https://pastebin.com/" .. code end
  return nil
end

local function uploadDumpWithPastebinProgram()
  if not shell or not shell.run then return nil, "shell.run unavailable" end
  if not term or not term.redirect or not term.current then return nil, "term redirect unavailable" end

  local oldTerm = term.current()
  local output = {}
  local capture = {}
  function capture.write(text) output[#output + 1] = tostring(text or "") end
  function capture.blit(text) output[#output + 1] = tostring(text or "") end
  function capture.clear() end
  function capture.clearLine() end
  function capture.scroll() end
  function capture.setCursorPos() end
  function capture.setCursorBlink() end
  function capture.setTextColor() end
  function capture.setBackgroundColor() end
  function capture.getCursorPos() return 1, 1 end
  function capture.getSize() return 80, 24 end
  function capture.isColor() return false end
  function capture.isColour() return false end
  function capture.getTextColor() return colors.white end
  function capture.getTextColour() return colors.white end
  function capture.getBackgroundColor() return colors.black end
  function capture.getBackgroundColour() return colors.black end

  local redirected = pcall(term.redirect, capture)
  local ran, result = pcall(shell.run, "pastebin", "put", DUMP_FILE)
  if redirected then pcall(term.redirect, oldTerm) end

  local text = table.concat(output)
  local url = pastebinUrlFromOutput(text)
  if ran and result ~= false and url then return url end
  if url then return url end
  if text ~= "" then return nil, text end
  return nil, ran and "pastebin put failed" or tostring(result)
end

local function uploadDumpToPastebin()
  local pastebinKey = loadPastebinKey()
  if not fs.exists(DUMP_FILE) or fs.isDir(DUMP_FILE) then return nil, "Diagnostic file was not created" end
  local h = fs.open(DUMP_FILE, "r")
  if not h then return nil, "Cannot read " .. DUMP_FILE end
  local body = h.readAll()
  h.close()
  lastDumpSize = #body
  if #body < 100 then return nil, "Diagnostic file is empty" end

  local apiError = nil
  if pastebinKey and http and http.post then
    local response, err = http.post(
      "https://pastebin.com/api/api_post.php",
      "api_option=paste&" ..
      "api_dev_key=" .. textutils.urlEncode(pastebinKey) .. "&" ..
      "api_paste_format=javascript&" ..
      "api_paste_name=" .. textutils.urlEncode("AE2 diagnostic " .. tostring(os.getComputerID())) .. "&" ..
      "api_paste_code=" .. textutils.urlEncode(body)
    )
    if response then
      local result = response.readAll()
      response.close()
      if result and string.match(result, "^https?://pastebin%.com/[%a%d]+$") then
        return result
      end
      apiError = result or "Pastebin returned no link"
    else
      apiError = err or "Pastebin API upload failed"
    end
  elseif pastebinKey then
    apiError = "HTTP POST is disabled"
  end

  local url, fallbackError = uploadDumpWithPastebinProgram()
  if url then return url end
  if apiError then return nil, apiError .. " | pastebin program: " .. tostring(fallbackError) end
  return nil, tostring(fallbackError or ("Missing " .. PASTEBIN_KEY_FILE))
end

local function runDiagnosticUpload()
  if toolBusy then
    setStatus("Diagnostic already running")
    return true
  end
  toolBusy = true
  lastPasteError = nil
  lastDumpPreview = nil
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
    setStatus("Dump failed: " .. lastPasteError, 30)
    return true
  end
  lastDumpSize = fs.getSize(DUMP_FILE) or 0
  lastDumpPreview = readDumpPreview()

  setStatus("Uploading diagnostic to Pastebin...")
  local url, uploadError = uploadDumpToPastebin()
  toolBusy = false
  if not url then
    lastPasteError = tostring(uploadError)
    setStatus("Saved " .. DUMP_FILE .. "; upload failed", 30)
    return true
  end

  lastPasteUrl = url
  lastPasteError = nil
  local h = fs.open(LAST_PASTE_FILE, "w")
  if h then h.write(url); h.close() end
  setStatus("Paste ready: " .. url, 30)
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
  local state = cycleBulkHint(button.key, button.name, button.cellState)
  if state == nil then
    setStatus("Could not save bulk marker")
  elseif state == "bulk" then
    setStatus("Bulk marker added: " .. button.name)
  elseif state == "inf" then
    setStatus("Infinity marker added: " .. button.name)
  else
    setStatus("Cell marker cleared: " .. button.name)
  end
end

local function handleTouch(screen, x, y)
  for _, button in ipairs(uiButtons[screen] or {}) do
    if y >= button.y and y <= (button.y2 or button.y) and x >= button.x and x <= button.x2 then
      if button.action == "nav" then
        currentPages[screen] = button.page
      elseif button.action == "page" then
        setListPage(screen, button.page, button.delta)
      elseif button.action == "subtab" then
        setSectionTab(screen, button.page, button.tab)
      elseif button.action == "ignore" then
        ignoreWarning(button)
      elseif button.action == "bulk" then
        toggleBulk(button)
      elseif button.action == "update" then
        return runUpdater()
      elseif button.action == "diagnostic" then
        if toolBusy or diagnosticRequested then
          setStatus("Diagnostic already running", 30)
        else
          diagnosticRequested = true
          setStatus("Diagnostic queued...", 30)
        end
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
    return usageState.warnings or {}, usageState.recent or {}, usageState.movers or {}
  end

  local current = {}
  local warnings = {}
  local recent = {}
  local movers = {}
  local elapsed = math.max(1, now - n(usageState.lastSample))
  usageState.recentCandidates = usageState.recentCandidates or {}
  for _, item in pairs(items or {}) do
    local key = itemKey(item)
    local amount = amountOf(item)
    if amount > 0 then
      current[key] = amount
      local prior = usageState.last[key]
      local label = itemLabel(item)
      local watchable = shouldWatchItem(key, label)
      if prior and amount ~= prior then
        local delta = amount - prior
        movers[#movers + 1] = {
          key = key,
          name = label,
          delta = delta,
          amount = amount,
          perMinute = delta / elapsed * 60,
          perHour = delta / elapsed * 3600,
          score = math.abs(delta / elapsed)
        }
      end
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
  table.sort(movers, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.name < b.name
  end)
  usageState.stateVersion = STATE_VERSION
  usageState.last = current
  usageState.lastSample = now
  usageState.warnings = warnings
  usageState.recent = recent
  usageState.movers = movers
  saveState(usageState)
  return warnings, recent, movers
end

local function updateFluidMovers(fluids)
  local now = nowSeconds()
  usageState.lastFluids = usageState.lastFluids or {}
  if usageState.lastFluidSample and now - usageState.lastFluidSample < SAMPLE_SECONDS then
    return usageState.fluidMovers or {}
  end

  local current = {}
  local movers = {}
  local elapsed = math.max(1, now - n(usageState.lastFluidSample))
  for _, fluid in pairs(fluids or {}) do
    local key = "fluid:" .. itemKey(fluid)
    local amount = amountOf(fluid)
    if amount > 0 then
      current[key] = amount
      local prior = usageState.lastFluids[key]
      if prior and amount ~= prior then
        local delta = amount - prior
        movers[#movers + 1] = {
          key = key,
          name = itemLabel(fluid),
          delta = delta,
          amount = amount,
          perMinute = delta / elapsed * 60,
          perHour = delta / elapsed * 3600,
          score = math.abs(delta / elapsed)
        }
      end
    end
  end
  table.sort(movers, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.name < b.name
  end)
  usageState.lastFluids = current
  usageState.lastFluidSample = now
  usageState.fluidMovers = movers
  saveState(usageState)
  return movers
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

local function signedFmt(value)
  value = n(value)
  local sign = value >= 0 and "+" or "-"
  return sign .. fmt(math.abs(value))
end

local function rateFmt(value, suffix)
  value = n(value)
  if value == 0 then return "--" .. suffix end
  local mag = math.abs(value)
  local text
  if mag < 1 then
    text = string.format("%.2f", mag)
  elseif mag < 10 then
    text = string.format("%.1f", mag)
  else
    text = fmt(mag)
  end
  return (value >= 0 and "+" or "-") .. text .. suffix
end

local function powerTrendText(stats)
  if stats and not stats.known then return "stored AE hidden" end
  if not stats or not stats.trendReady then return "trend learning" end
  return rateFmt(stats.netPerTick, " AE/t") .. "  " .. rateFmt(stats.netPerMinute, " AE/m")
end

local function powerEtaText(stats)
  if not stats or not stats.trendReady or n(stats.eta) <= 0 then return nil end
  if stats.etaMode == "full" then return "Full in " .. duration(stats.eta) end
  if stats.etaMode == "empty" then return "Empty in " .. duration(stats.eta) end
  return nil
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
    and {"OVERVIEW", "CRAFT", "STOCK", "STORAGE", "MOVERS", "SYSTEM", "TOOLS"}
    or {"HOME", "CRAFT", "STOCK", "STORE", "MOVE", "SYS", "MORE"}
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

local function bottomPageControls(screen, page, y, pageNumber, pageCount)
  local w = mon.getSize()
  pageNumber = math.max(1, math.min(pageNumber, pageCount))
  local navHeight = 2
  local buttonW = math.max(10, math.floor((w - 6) / 2))
  local prevX = 2
  local nextX = math.max(2, w - buttonW + 1)
  local pageText = tostring(pageNumber) .. "/" .. tostring(pageCount)

  fillRect(1, y, w, navHeight, colors.blue)
  writeAt(prevX + math.max(0, math.floor((buttonW - 6) / 2)), y, "< PREV", pageNumber > 1 and colors.white or colors.lightGray, colors.blue, 6)
  writeAt(nextX + math.max(0, math.floor((buttonW - 6) / 2)), y, "NEXT >", pageNumber < pageCount and colors.white or colors.lightGray, colors.blue, 6)
  writeAt(math.max(1, math.floor((w - #pageText) / 2) + 1), y + 1, pageText, colors.black, colors.yellow, #pageText)

  if pageNumber > 1 then registerButton(screen, {x = prevX, x2 = prevX + buttonW - 1, y = y, y2 = y + navHeight - 1, action = "page", page = page, delta = -1}) end
  if pageNumber < pageCount then registerButton(screen, {x = nextX, x2 = nextX + buttonW - 1, y = y, y2 = y + navHeight - 1, action = "page", page = page, delta = 1}) end
end

local function drawSubtabs(screen, page, active, tabs, y)
  local w = mon.getSize()
  local tabCount = #tabs
  local tabW = math.max(1, math.floor(w / tabCount))
  local x = 1
  for i, tab in ipairs(tabs) do
    local x2 = i == tabCount and w or math.min(w, x + tabW - 1)
    local width = math.max(1, x2 - x + 1)
    local selected = tab.key == active
    local bg = selected and colors.cyan or colors.gray
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
    if y <= bottom then
      writeAt(2, y, "AppFlux", colors.lightGray, colors.black, 12)
      local fluxText = data.feKnown and (fmt(data.feStored) .. " FE exposed") or "FE storage not exposed"
      writeAt(15, y, fluxText .. "  |  " .. data.feProbeCount .. " probe(s)", data.feKnown and colors.lightGray or colors.orange, colors.black, w - 15)
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
  d.aeEnergyInfo = {stored = d.energy, capacity = d.energyCap, known = d.energyCap > 0, estimated = false, source = "ME bridge AE energy"}
  d.powerStats = updatePowerStats(d.aeEnergyInfo)
  d.itemTypeTotal, d.fluidTypeTotal, d.itemCellCount, d.fluidCellCount = typeSlots(d.cells)
  d.cellGroups = summarizeCells(d.cells)
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
