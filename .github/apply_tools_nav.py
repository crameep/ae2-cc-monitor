from pathlib import Path

path = Path("startup.lua")
text = path.read_text()


def replace_once(old, new):
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Expected one match, found {count}: {old[:100]!r}")
    text = text.replace(old, new, 1)


replace_once('local VERSION = "2026-07-09.1"', 'local VERSION = "2026-07-09.2"')
replace_once(
    'local UPDATE_URL = "https://raw.githubusercontent.com/crameep/ae2-cc-monitor/main/startup.lua"\nlocal STATE_FILE = ".ae2_usage_state"',
    'local UPDATE_URL = "https://raw.githubusercontent.com/crameep/ae2-cc-monitor/main/startup.lua"\nlocal DUMP_URL = "https://raw.githubusercontent.com/crameep/ae2-cc-monitor/main/ae2-dump.lua"\nlocal DUMP_SCRIPT = "ae2-dump.lua"\nlocal DUMP_FILE = "ae2-dump.txt"\nlocal LAST_PASTE_FILE = ".ae2_last_paste"\nlocal PASTEBIN_DEV_KEY = "0ec2eb25b6166c0c27a394ae118ad829"\nlocal STATE_FILE = ".ae2_usage_state"',
)
replace_once(
    'local statusMessage = nil\nlocal statusUntil = 0\nlocal setStatus\n\nlocal PAGE_ORDER = {"overview", "crafting", "stock", "storage", "system"}\nlocal PAGE_TITLES = {\n  overview = "OVERVIEW",\n  crafting = "CRAFTING",\n  stock = "STOCK WATCH",\n  storage = "STORAGE",\n  system = "SYSTEM"\n}',
    '''local statusMessage = nil
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
}''',
)

marker = "local function ignoreWarning(button)\n"
insert = '''local function downloadDumpScript()
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

local function uploadDumpToPastebin()
  if not http or not http.post then return nil, "HTTP POST is disabled" end
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
    "api_dev_key=" .. PASTEBIN_DEV_KEY .. "&" ..
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

'''
if marker not in text:
    raise SystemExit("ignoreWarning marker missing")
text = text.replace(marker, insert + marker, 1)

replace_once(
    '      elseif button.action == "update" then\n        return runUpdater()\n      end',
    '      elseif button.action == "update" then\n        return runUpdater()\n      elseif button.action == "diagnostic" then\n        return runDiagnosticUpload()\n      end',
)
replace_once(
    '  local labels = w >= 58\n    and {"OVERVIEW", "CRAFTING", "STOCK", "STORAGE", "SYSTEM"}\n    or {"HOME", "CRAFT", "STOCK", "STORE", "SYS"}',
    '  local labels = w >= 68\n    and {"OVERVIEW", "CRAFTING", "STOCK", "STORAGE", "SYSTEM", "TOOLS"}\n    or {"HOME", "CRAFT", "STOCK", "STORE", "SYS", "TOOLS"}',
)

marker = "local function renderScreen(target, data)\n"
tools_func = '''local function renderTools(screen, data, h)
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
    writeAt(2, y, "ae2-dump.txt and keeps the last Pastebin link.", colors.lightGray, colors.black, w - 2)
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

'''
if marker not in text:
    raise SystemExit("renderScreen marker missing")
text = text.replace(marker, tools_func + marker, 1)
replace_once(
    '  elseif page == "system" then\n    renderSystem(screen, data, h)\n  else',
    '  elseif page == "system" then\n    renderSystem(screen, data, h)\n  elseif page == "tools" then\n    renderTools(screen, data, h)\n  else',
)
path.write_text(text)

readme = Path("README.md")
r = readme.read_text()
needle = '- **System** — grid status, cells, drives, power flow, crafting CPUs, version, and updater.\n'
if needle not in r:
    raise SystemExit("README navigation marker missing")
r = r.replace(needle, needle + '- **Tools** — one-touch AE2 diagnostic generation and Pastebin upload, with the latest link shown on the monitor.\n', 1)
needle = 'Open **System** and tap `UPDATE`. The script downloads the latest `startup.lua` from this repository and reboots.\n'
if needle not in r:
    raise SystemExit("README update marker missing")
r = r.replace(needle, needle + '\n## Tools and diagnostic upload\n\nOpen **Tools** and tap `CREATE + UPLOAD AE2 DUMP`. The dashboard downloads the latest `ae2-dump.lua`, collects a one-shot read-only snapshot, saves `ae2-dump.txt`, uploads it to Pastebin, and displays the resulting URL and paste code. The last successful URL is saved in `.ae2_last_paste`.\n', 1)
readme.write_text(r)
