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

local function buildBulkIndex(cells, items)
  local index = {}
  local bulkCells = 0
  local matched = 0
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
      local text = norm(gatherText(cell))
      for _, item in pairs(items or {}) do
        local key = itemKey(item)
        if not index[key] and cellMatchesItem(text, item) then
          index[key] = "auto"
          matched = matched + 1
        end
      end
    end
  end

  return index, bulkCells, matched
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

local function atm10StockRule(key, label, amount)
  if amount <= 0 then return nil end
  local text = string.lower(tostring(label or "") .. " " .. tostring(key or ""))
  if not shouldWatchItem(key, label) then return false end

  local rules = {
    {
      label = "ATM metals",
      max = 512,
      priority = 100,
      needles = {
        "allthemodium", "vibranium", "unobtainium", "piglich heart",
        "patrick star", "atm star", "star shard", "alloy block"
      }
    },
    {
      label = "ATM alloys",
      max = 1024,
      priority = 95,
      needles = {
        "vibranium allthemodium", "unobtainium vibranium",
        "unobtainium allthemodium", "awakened"
      }
    },
    {
      label = "Mystical tiers",
      max = 4096,
      priority = 90,
      needles = {
        "inferium", "prudentium", "tertium", "imperium", "supremium",
        "insanium", "prosperity shard", "soulium", "master infusion crystal"
      }
    },
    {
      label = "Mekanism chain",
      max = 2048,
      priority = 85,
      needles = {
        "osmium", "refined obsidian", "refined glowstone", "fluorite",
        "sulfur", "substrate", "hdpe", "polonium", "plutonium",
        "pellet antimatter", "antimatter", "fissile", "ultimate control circuit"
      }
    },
    {
      label = "AE2 crafting",
      max = 4096,
      priority = 80,
      needles = {
        "certus", "fluix", "sky stone", "charged certus", "quartz glass",
        "logic processor", "calculation processor", "engineering processor",
        "printed logic", "printed calculation", "printed engineering",
        "printed silicon", "annihilation core", "formation core", "singularity"
      }
    },
    {
      label = "Productive Bees",
      max = 2048,
      priority = 75,
      needles = {
        "honey treat", "gene sample", "gene", "bee cage",
        "configurable honeycomb", "honeycomb", "productivity upgrade"
      }
    },
    {
      label = "Powah",
      max = 2048,
      priority = 70,
      needles = {
        "uraninite", "dielectric paste", "blazing crystal", "niotic crystal",
        "spirited crystal", "nitro crystal", "energizing rod", "energizing orb",
        "capacitor"
      }
    },
    {
      label = "Occultism",
      max = 1024,
      priority = 65,
      needles = {
        "iesnium", "spirit attuned", "otherstone", "datura", "chalk",
        "soul gem", "infused pickaxe", "dark gem"
      }
    },
    {
      label = "Ars Nouveau",
      max = 1024,
      priority = 60,
      needles = {
        "source gem", "source jar", "magebloom", "archwood", "wilden horn",
        "wilden wing", "wilden spike", "blank glyph", "spell parchment"
      }
    },
    {
      label = "Create",
      max = 2048,
      priority = 55,
      needles = {
        "andesite alloy", "brass", "precision mechanism", "electron tube",
        "sturdy sheet", "chromatic compound", "shaft", "cogwheel", "belt connector"
      }
    },
    {
