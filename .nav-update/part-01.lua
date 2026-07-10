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

local VERSION = "2026-07-09.1"
local STATE_VERSION = 6
local UPDATE_URL = "https://raw.githubusercontent.com/crameep/ae2-cc-monitor/main/startup.lua"
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
