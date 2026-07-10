from pathlib import Path

startup_path = Path('startup.lua')
readme_path = Path('README.md')
text = startup_path.read_text()


def replace_once(old: str, new: str, label: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected one match, found {count}')
    text = text.replace(old, new, 1)


replace_once('local VERSION = "2026-07-09.3"', 'local VERSION = "2026-07-09.4"', 'version')

stock_start = text.index('local function atm10StockRule(')
stock_end = text.index('\nlocal function set(', stock_start)
new_stock_rules = r'''local function stockSearchText(key, label)
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
'''
text = text[:stock_start] + new_stock_rules + text[stock_end:]

render_start = text.index('local function renderStock(')
render_end = text.index('\nlocal function renderStorage(', render_start)
new_render_stock = r'''local function renderStock(screen, data, h)
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
'''
text = text[:render_start] + new_render_stock + text[render_end:]

replace_once(
    'lowStock[#lowStock + 1] = {name = label, amount = amount, priority = stockRule.priority, group = stockRule.label}',
    'lowStock[#lowStock + 1] = {name = label, amount = amount, target = stockRule.max, ratio = amount / math.max(1, stockRule.max), priority = stockRule.priority, group = stockRule.short or stockRule.label}',
    'low stock row data',
)

replace_once(
    '''  table.sort(lowStock, function(a, b)\n    if a.priority ~= b.priority then return a.priority > b.priority end\n    return a.amount < b.amount\n  end)''',
    '''  table.sort(lowStock, function(a, b)\n    if a.priority ~= b.priority then return a.priority > b.priority end\n    if a.ratio ~= b.ratio then return a.ratio < b.ratio end\n    return a.name < b.name\n  end)''',
    'low stock sort',
)

startup_path.write_text(text)

readme = readme_path.read_text()
needle = '- A persistent bottom navigation bar\n'
addition = '- A persistent bottom navigation bar\n- A fixed-column low-stock table with compact categories, count/target values, urgency colors, and non-overlapping paging controls\n'
if addition not in readme:
    if needle not in readme:
        raise SystemExit('README readability insertion point missing')
    readme = readme.replace(needle, addition, 1)
readme_path.write_text(readme)

print('Applied stock readability and filtering improvements')
