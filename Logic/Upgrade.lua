-- GearLink - evaluación de mejoras: ¿este item de mis bolsas le sirve a un amigo?
--
-- ns.Upgrade:Evaluate(itemLink, friendSnapshot) -> isUpgrade, score, reason, slotID
--   isUpgrade = nil si falta cargar datos de algún item (el llamador debe cargarlos y reintentar).
--
-- Reglas, en orden:
--   1. ¿Puede usarlo? Armadura por clase (malla/placas desde 40), armas por clase, doble arma, nivel requerido,
--      restricción "Clases: ..." del tooltip.
--   2. ¿El stat principal coincide con el suyo? (si el item tiene stats principales)
--   3. Slot: anillos/abalorios/armas a una mano se comparan contra el PEOR de los dos slots; con un arma a dos
--      manos equipada, la mano izquierda cuenta como ocupada por ella.
--   4. ¿Es mejor? Primero nivel de item; si empata, stats ponderadas por rol (ns.StatWeights).
--
-- Sin estado: solo lee la caché de items del cliente. Se puede probar con /gl eval.
local _, ns = ...
local L = ns.L

local Upgrade = {}
ns.Upgrade = Upgrade

---------------------------------------------------------------------------
-- Pesos de stats (editables). Se busca primero por árbol (ns.StatWeights.PROT) y si no, por rol_stat.
---------------------------------------------------------------------------

ns.StatWeights = {
    TANK_STR = { STA = 1.0, STR = 0.8, AGI = 0.5, DEF = 1.0, DODGE = 0.8, PARRY = 0.8, BLOCK = 0.5, BLOCKVALUE = 0.2, ARMOR = 0.02 },
    TANK_AGI = { STA = 1.0, AGI = 0.8, STR = 0.5, DEF = 1.0, DODGE = 0.8, ARMOR = 0.02 },
    DAMAGER_STR = { STR = 1.0, AGI = 0.6, STA = 0.3, AP = 0.5, CRIT = 0.8, HIT = 0.9 },
    DAMAGER_AGI = { AGI = 1.0, STR = 0.4, STA = 0.3, AP = 0.5, RAP = 0.4, CRIT = 0.8, HIT = 0.9 },
    DAMAGER_INT = { INT = 1.0, SPI = 0.4, STA = 0.3, SP = 0.9, CRIT = 0.6, HIT = 0.7 },
    HEALER_INT = { INT = 1.0, SPI = 0.7, STA = 0.3, HEAL = 0.8, SP = 0.6, MP5 = 1.2 },
}

local STAT_KEYS = {
    ITEM_MOD_STRENGTH_SHORT = "STR", ITEM_MOD_AGILITY_SHORT = "AGI", ITEM_MOD_INTELLECT_SHORT = "INT",
    ITEM_MOD_STAMINA_SHORT = "STA", ITEM_MOD_SPIRIT_SHORT = "SPI",
    ITEM_MOD_ATTACK_POWER_SHORT = "AP", ITEM_MOD_MELEE_ATTACK_POWER_SHORT = "AP",
    ITEM_MOD_RANGED_ATTACK_POWER_SHORT = "RAP",
    ITEM_MOD_SPELL_POWER_SHORT = "SP", ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = "SP",
    ITEM_MOD_SPELL_HEALING_DONE_SHORT = "HEAL",
    ITEM_MOD_CRIT_RATING_SHORT = "CRIT", ITEM_MOD_CRIT_MELEE_RATING_SHORT = "CRIT", ITEM_MOD_CRIT_SPELL_RATING_SHORT = "CRIT",
    ITEM_MOD_HIT_RATING_SHORT = "HIT", ITEM_MOD_HIT_MELEE_RATING_SHORT = "HIT", ITEM_MOD_HIT_SPELL_RATING_SHORT = "HIT",
    ITEM_MOD_DEFENSE_SKILL_RATING_SHORT = "DEF", ITEM_MOD_DODGE_RATING_SHORT = "DODGE",
    ITEM_MOD_PARRY_RATING_SHORT = "PARRY", ITEM_MOD_BLOCK_RATING_SHORT = "BLOCK", ITEM_MOD_BLOCK_VALUE_SHORT = "BLOCKVALUE",
    ITEM_MOD_MANA_REGENERATION_SHORT = "MP5", ITEM_MOD_POWER_REGEN0_SHORT = "MP5",
    RESISTANCE0_NAME = "ARMOR",
}
local PRIMARY = { STR = true, AGI = true, INT = true }
-- Un stat principal con peso menor que esto "no le sirve" al rol (ej. Intelecto para un guerrero).
local USEFUL_PRIMARY_WEIGHT = 0.5

local function GetWeights(snap)
    local W = ns.StatWeights
    return (snap.tree and W[snap.tree]) or W[(snap.role or "DAMAGER") .. "_" .. (snap.mainStat or "STR")] or W.DAMAGER_STR
end

---------------------------------------------------------------------------
-- Competencias (reglas clásicas). Armadura: subclase -> nivel requerido.
---------------------------------------------------------------------------

local ARMOR = {
    WARRIOR = { [0] = 1, [1] = 1, [2] = 1, [3] = 1, [4] = 40, [6] = 1 },
    PALADIN = { [0] = 1, [1] = 1, [2] = 1, [3] = 1, [4] = 40, [6] = 1, [7] = 1 },
    HUNTER = { [0] = 1, [1] = 1, [2] = 1, [3] = 40 },
    ROGUE = { [0] = 1, [1] = 1, [2] = 1 },
    PRIEST = { [0] = 1, [1] = 1 },
    SHAMAN = { [0] = 1, [1] = 1, [2] = 1, [3] = 40, [6] = 1, [9] = 1 },
    MAGE = { [0] = 1, [1] = 1 },
    WARLOCK = { [0] = 1, [1] = 1 },
    DRUID = { [0] = 1, [1] = 1, [2] = 1, [8] = 1 },
}

local function Set(...)
    local t = {}
    for i = 1, select("#", ...) do t[select(i, ...)] = true end
    return t
end

-- Enum.ItemWeaponSubclass: 0 hacha 1M, 1 hacha 2M, 2 arco, 3 arma de fuego, 4 maza 1M, 5 maza 2M, 6 arma de asta,
-- 7 espada 1M, 8 espada 2M, 10 bastón, 13 puño, 15 daga, 16 arrojadiza, 18 ballesta, 19 varita
local WEAPONS = {
    WARRIOR = Set(0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 13, 15, 16, 18),
    PALADIN = Set(0, 1, 4, 5, 6, 7, 8),
    HUNTER = Set(0, 1, 2, 3, 6, 7, 8, 10, 13, 15, 16, 18),
    ROGUE = Set(2, 3, 4, 7, 13, 15, 16, 18),
    PRIEST = Set(4, 10, 15, 19),
    SHAMAN = Set(0, 1, 4, 5, 10, 13, 15),
    MAGE = Set(7, 10, 15, 19),
    WARLOCK = Set(7, 10, 15, 19),
    DRUID = Set(4, 5, 10, 13, 15),
}
local DUAL_WIELD = Set("WARRIOR", "ROGUE", "HUNTER")

local ITEM_CLASS_WEAPON = (Enum.ItemClass and Enum.ItemClass.Weapon) or 2
local ITEM_CLASS_ARMOR = (Enum.ItemClass and Enum.ItemClass.Armor) or 4

-- equipLoc -> slots candidatos
local EQUIP_LOC_SLOTS = {
    INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 },
    INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 },
    INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 },
    INVTYPE_WEAPON = { 16, 17 }, INVTYPE_WEAPONMAINHAND = { 16 }, INVTYPE_WEAPONOFFHAND = { 17 },
    INVTYPE_2HWEAPON = { 16 }, INVTYPE_SHIELD = { 17 }, INVTYPE_HOLDABLE = { 17 },
    INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 }, INVTYPE_RELIC = { 18 },
}

---------------------------------------------------------------------------
-- Datos de items (con caché por sesión)
---------------------------------------------------------------------------

local CLASSES_PATTERN = ns.FormatToPattern(ITEM_CLASSES_ALLOWED, true)

local itemCache, itemCacheSize = {}, 0

-- Devuelve una tabla con la info del item, o nil si el cliente todavía no la tiene cargada.
function Upgrade:GetItemData(link)
    if type(link) ~= "string" then return nil end
    local cached = itemCache[link]
    if cached then return cached end

    local name, _, quality, _, minLevel, _, _, _, equipLoc, _, _, classID, subclassID = C_Item.GetItemInfo(link)
    if not name then return nil end
    local ilvl = (C_Item.GetDetailedItemLevelInfo and C_Item.GetDetailedItemLevelInfo(link)) or 0

    local stats = {}
    local raw = C_Item.GetItemStats and C_Item.GetItemStats(link)
    if raw then
        for key, value in pairs(raw) do
            local stat = STAT_KEYS[key]
            if stat and type(value) == "number" then stats[stat] = (stats[stat] or 0) + value end
        end
    end

    -- "Clases: Mago, Brujo" (texto localizado del tooltip)
    local classesAllowed
    if CLASSES_PATTERN and C_TooltipInfo and C_TooltipInfo.GetHyperlink then
        local data = C_TooltipInfo.GetHyperlink(link)
        for _, line in ipairs(data and data.lines or {}) do
            local text = line.leftText
            if type(text) == "string" and not ns.IsSecret(text) then
                local list = text:match(CLASSES_PATTERN)
                if list then classesAllowed = list break end
            end
        end
    end

    cached = {
        name = name, quality = quality, ilvl = ilvl, minLevel = minLevel or 0, equipLoc = equipLoc,
        classID = classID, subclassID = subclassID, stats = stats, classesAllowed = classesAllowed,
    }
    if itemCacheSize > 500 then itemCache, itemCacheSize = {}, 0 end
    itemCache[link] = cached
    itemCacheSize = itemCacheSize + 1
    return cached
end

local function StatScore(data, weights)
    local score = 0
    for stat, value in pairs(data.stats) do
        score = score + value * (weights[stat] or 0)
    end
    return score
end

local function ClassAllowedByTooltip(data, classFile)
    if not data.classesAllowed then return true end
    local male = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classFile]
    local female = LOCALIZED_CLASS_NAMES_FEMALE and LOCALIZED_CLASS_NAMES_FEMALE[classFile]
    return (male and data.classesAllowed:find(male, 1, true)) or (female and data.classesAllowed:find(female, 1, true)) or false
end

-- Regla 1. Devuelve true o false, motivo.
function Upgrade:CanUse(data, classFile, level)
    if not classFile then return false, L.WHY_NO_CLASS end
    if data.minLevel > (level or 1) then return false, L.WHY_LEVEL:format(data.minLevel) end
    if data.classID == ITEM_CLASS_ARMOR and data.equipLoc ~= "INVTYPE_CLOAK" then
        local req = ARMOR[classFile] and ARMOR[classFile][data.subclassID or 0]
        if not req then return false, L.WHY_ARMOR end
        if (level or 1) < req then return false, L.WHY_ARMOR_LEVEL:format(req) end
    elseif data.classID == ITEM_CLASS_WEAPON then
        if not (WEAPONS[classFile] and WEAPONS[classFile][data.subclassID or -1]) then return false, L.WHY_WEAPON end
        if data.equipLoc == "INVTYPE_WEAPONOFFHAND" and not DUAL_WIELD[classFile] then return false, L.WHY_DUAL_WIELD end
    end
    if not ClassAllowedByTooltip(data, classFile) then return false, L.WHY_CLASS_RESTRICTED end
    return true
end

local function SlotName(slotID)
    local keys = { "HEADSLOT", "NECKSLOT", "SHOULDERSLOT", "SHIRTSLOT", "CHESTSLOT", "WAISTSLOT", "LEGSSLOT",
        "FEETSLOT", "WRISTSLOT", "HANDSSLOT", "FINGER0SLOT", "FINGER1SLOT", "TRINKET0SLOT", "TRINKET1SLOT",
        "BACKSLOT", "MAINHANDSLOT", "SECONDARYHANDSLOT", "RANGEDSLOT", "TABARDSLOT" }
    return _G[keys[slotID] or ""] or ("slot " .. slotID)
end
Upgrade.SlotName = SlotName

-- Stats principales que tienen sentido para cada clase (para amigos sin GearLink, de los que no sabemos el rol).
local CLASS_PRIMARIES = {
    WARRIOR = Set("STR", "AGI"), PALADIN = Set("STR", "INT"), HUNTER = Set("AGI"), ROGUE = Set("AGI"),
    PRIEST = Set("INT"), SHAMAN = Set("INT", "AGI", "STR"), MAGE = Set("INT"), WARLOCK = Set("INT"),
    DRUID = Set("INT", "AGI", "STR"),
}

---------------------------------------------------------------------------
-- Evaluación
---------------------------------------------------------------------------

-- Para amigos SIN GearLink: solo sabemos clase y nivel (lista de amigos / Battle.net), no su equipo.
-- Devuelve true si puede usarlo ("para regalar"), con una puntuación baja para que las mejoras reales vayan antes.
-- isUsable = nil si faltan datos del item.
function Upgrade:EvaluateUsable(itemLink, classFile, level)
    local data = self:GetItemData(itemLink)
    if not data then return nil, 0, "LOADING" end
    if not EQUIP_LOC_SLOTS[data.equipLoc] then return false, 0, L.WHY_SLOT end
    local ok, why = self:CanUse(data, classFile, level)
    if not ok then return false, 0, why end
    local allowed = CLASS_PRIMARIES[classFile]
    if allowed then
        local hasPrimary, matches = false, false
        for stat in pairs(data.stats) do
            if PRIMARY[stat] then
                hasPrimary = true
                if allowed[stat] then matches = true end
            end
        end
        if hasPrimary and not matches then return false, 0, L.WHY_STAT end
    end
    return true, (data.ilvl or 0) / 100, L.REASON_USABLE:format(EQUIP_LOC_SLOTS[data.equipLoc] and SlotName(EQUIP_LOC_SLOTS[data.equipLoc][1]) or "?")
end

-- Devuelve: isUpgrade (nil = faltan datos), score, reason, slotID
function Upgrade:Evaluate(itemLink, snap)
    local data = self:GetItemData(itemLink)
    if not data then return nil, 0, "LOADING" end
    local slots = EQUIP_LOC_SLOTS[data.equipLoc]
    if not slots then return false, 0, L.WHY_SLOT end

    -- 1. ¿Puede usarlo?
    local ok, why = self:CanUse(data, snap.class, snap.level)
    if not ok then return false, 0, why end

    -- 2. Stat principal: el item no debe ser "para otro rol". Se compara lo que aporta al rol del amigo (stats con
    --    peso, armadura incluida para tanques) contra los stats principales que no le sirven (peso < 0.5).
    --    Ej.: un escudo con +1 Intelecto, +1 Aguante y más armadura SÍ le sirve a un guerrero tanque;
    --    una túnica de Intelecto/Espíritu, no.
    local weights = GetWeights(snap)
    local useless = 0
    for stat, value in pairs(data.stats) do
        if PRIMARY[stat] and (weights[stat] or 0) < USEFUL_PRIMARY_WEIGHT then useless = useless + value end
    end
    if useless > 0 and StatScore(data, weights) < useless then return false, 0, L.WHY_STAT end

    -- 2b. ¿Ya tiene ese mismo item? (equipado en alguno de sus slots posibles, o en sus bolsas si las comparte)
    local itemID = tonumber(itemLink:match("item:(%d+)"))
    if itemID then
        for _, slot in ipairs(slots) do
            local current = snap.equipped and snap.equipped[slot]
            if current and tonumber(current:match("item:(%d+)")) == itemID then return false, 0, L.WHY_SAME_EQUIPPED end
        end
        for _, bagItem in ipairs(snap.bags or {}) do
            if type(bagItem.link) == "string" and tonumber(bagItem.link:match("item:(%d+)")) == itemID then
                return false, 0, L.WHY_SAME_IN_BAGS
            end
        end
    end

    -- 3. Slot a comparar: el peor de los candidatos. Con un arma a dos manos equipada, la mano izquierda
    --    cuenta como ocupada por ella (cambiar un 2M por un arma a una mano / escudo se compara contra el 2M).
    local equipped = snap.equipped or {}
    local mainHand = equipped[16] and self:GetItemData(equipped[16])
    if equipped[16] and not mainHand then return nil, 0, "LOADING" end
    local twoHander = mainHand and mainHand.equipLoc == "INVTYPE_2HWEAPON"

    local worstSlot, worstIlvl, worstScore
    for _, slot in ipairs(slots) do
        if slot ~= 17 or data.equipLoc ~= "INVTYPE_WEAPON" or DUAL_WIELD[snap.class] then
            local current = equipped[slot]
            if slot == 17 and not current and twoHander then current = equipped[16] end
            local ilvl, score = 0, 0
            if current then
                local cur = self:GetItemData(current)
                if not cur then return nil, 0, "LOADING" end
                ilvl, score = cur.ilvl or 0, StatScore(cur, weights)
            end
            if not worstSlot or ilvl < worstIlvl or (ilvl == worstIlvl and score < worstScore) then
                worstSlot, worstIlvl, worstScore = slot, ilvl, score
            end
        end
    end
    if not worstSlot then return false, 0, L.WHY_SLOT end

    -- 4. ¿Es mejor?
    local diff = (data.ilvl or 0) - worstIlvl
    local newScore = StatScore(data, weights)
    local slotName = SlotName(worstSlot)
    if not equipped[worstSlot] and not (worstSlot == 17 and twoHander) then
        return true, 1000 + (data.ilvl or 0), L.REASON_EMPTY:format(slotName), worstSlot
    end
    if diff > 0 then
        return true, diff * 10 + newScore / 100, L.REASON_ILVL:format(diff, slotName), worstSlot
    end
    if diff == 0 and newScore > worstScore + 0.01 then
        return true, newScore - worstScore, L.REASON_STATS:format(slotName), worstSlot
    end
    return false, 0, diff < 0 and L.WHY_LOWER:format(-diff, slotName) or L.WHY_NOT_BETTER:format(slotName)
end
