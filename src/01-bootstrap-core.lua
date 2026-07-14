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

local VERSION = "2026-07-14.12"
local STATE_VERSION = 6
local UPDATE_URL = "https://raw.githubusercontent.com/crameep/ae2-cc-monitor/main/startup.lua"
local GITHUB_COMMIT_API = "https://api.github.com/repos/crameep/ae2-cc-monitor/commits/main"
local RAW_BASE_URL = "https://raw.githubusercontent.com/crameep/ae2-cc-monitor"
local MANIFEST_FILE = "version.json"
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

local function listCells(cells)
  local rows = {}
  for index, cell in pairs(cells or {}) do
    if type(cell) == "table" then
      local total = n(cell.bytes or cell.totalBytes or cell.capacity or cell.total)
      local used = n(cell.usedBytes or cell.bytesUsed or cell.used)
      rows[#rows + 1] = {
        name = cleanLabel(cellName(cell)),
        type = tostring(cell.type or "?"),
        used = used,
        total = total,
        pct = pct(used, total),
        index = index
      }
    end
  end
  table.sort(rows, function(a, b)
    if a.type ~= b.type then return a.type < b.type end
    if a.total ~= b.total then return a.total > b.total end
    if a.used ~= b.used then return a.used > b.used end
    return a.name < b.name
  end)
  return rows
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

