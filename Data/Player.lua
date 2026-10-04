-- GearLink - información del jugador: nombre, clase, nivel, spec/árbol de talentos, rol y stat principal.
--
-- En Forever cada clase tiene una sola "spec" del sistema moderno, y los talentos son los árboles clásicos montados
-- sobre C_Traits. Por eso el rol/stat se resuelve en este orden:
--   1) override manual (/gl role, /gl stat o botones de la ventana)
--   2) spec del juego, solo si el juego deja elegirla (IsSpecSelectionEnabled)
--   3) árbol de talentos con más puntos gastados
--   4) valor por defecto de la clase
local _, ns = ...

local Player = {}
ns.Player = Player

-- Rol y stat principal por clase y por árbol. Valores por defecto simples y editables.
-- (Mejora y Feral usan Agilidad como en retail; si en Forever conviene Fuerza, cambiarlo aquí o con /gl stat.)
local CLASS_PROFILES = {
    WARRIOR = { default = { "DAMAGER", "STR" }, ARMS = { "DAMAGER", "STR" }, FURY = { "DAMAGER", "STR" }, PROT = { "TANK", "STR" } },
    PALADIN = { default = { "DAMAGER", "STR" }, HOLY = { "HEALER", "INT" }, PROT = { "TANK", "STR" }, RET = { "DAMAGER", "STR" } },
    HUNTER = { default = { "DAMAGER", "AGI" } },
    ROGUE = { default = { "DAMAGER", "AGI" } },
    PRIEST = { default = { "HEALER", "INT" }, DISC = { "HEALER", "INT" }, HOLY = { "HEALER", "INT" }, SHADOW = { "DAMAGER", "INT" } },
    SHAMAN = { default = { "DAMAGER", "INT" }, ELE = { "DAMAGER", "INT" }, ENH = { "DAMAGER", "AGI" }, RESTO = { "HEALER", "INT" } },
    MAGE = { default = { "DAMAGER", "INT" } },
    WARLOCK = { default = { "DAMAGER", "INT" } },
    DRUID = { default = { "DAMAGER", "INT" }, BALANCE = { "DAMAGER", "INT" }, FERAL = { "DAMAGER", "AGI" }, RESTO = { "HEALER", "INT" } },
    -- Clases modernas por si existieran en Forever.
    DEATHKNIGHT = { default = { "DAMAGER", "STR" } },
    MONK = { default = { "DAMAGER", "AGI" } },
    DEMONHUNTER = { default = { "DAMAGER", "AGI" } },
    EVOKER = { default = { "DAMAGER", "INT" } },
}
ns.CLASS_PROFILES = CLASS_PROFILES

-- Árboles clásicos reconocidos por su skill line (IDs de Classic).
local TREE_BY_SKILL_LINE = {
    [26] = "ARMS", [256] = "FURY", [257] = "PROT",
    [594] = "HOLY", [267] = "PROT", [184] = "RET",
    [50] = "BM", [163] = "MM", [51] = "SV",
    [253] = "ASSA", [38] = "COMBAT", [39] = "SUB",
    [613] = "DISC", [56] = "HOLY", [78] = "SHADOW",
    [375] = "ELE", [373] = "ENH", [374] = "RESTO",
    [237] = "ARCANE", [8] = "FIRE", [6] = "FROST",
    [355] = "AFFLI", [354] = "DEMO", [593] = "DESTRO",
    [574] = "BALANCE", [134] = "FERAL", [573] = "RESTO",
}
-- Respaldo por nombre (español e inglés), en minúsculas.
local TREE_BY_NAME = {
    ["armas"] = "ARMS", ["arms"] = "ARMS", ["furia"] = "FURY", ["fury"] = "FURY",
    ["protección"] = "PROT", ["protection"] = "PROT", ["sagrado"] = "HOLY", ["holy"] = "HOLY",
    ["reprensión"] = "RET", ["retribution"] = "RET",
    ["dominio de bestias"] = "BM", ["beast mastery"] = "BM", ["puntería"] = "MM", ["marksmanship"] = "MM",
    ["supervivencia"] = "SV", ["survival"] = "SV",
    ["asesinato"] = "ASSA", ["assassination"] = "ASSA", ["combate"] = "COMBAT", ["combat"] = "COMBAT",
    ["sutileza"] = "SUB", ["subtlety"] = "SUB",
    ["disciplina"] = "DISC", ["discipline"] = "DISC", ["sombra"] = "SHADOW", ["shadow"] = "SHADOW",
    ["elemental"] = "ELE", ["mejora"] = "ENH", ["enhancement"] = "ENH",
    ["restauración"] = "RESTO", ["restoration"] = "RESTO",
    ["arcano"] = "ARCANE", ["arcane"] = "ARCANE", ["fuego"] = "FIRE", ["fire"] = "FIRE",
    ["escarcha"] = "FROST", ["frost"] = "FROST",
    ["aflicción"] = "AFFLI", ["affliction"] = "AFFLI", ["demonología"] = "DEMO", ["demonology"] = "DEMO",
    ["destrucción"] = "DESTRO", ["destruction"] = "DESTRO",
    ["equilibrio"] = "BALANCE", ["balance"] = "BALANCE", ["combate feral"] = "FERAL", ["feral combat"] = "FERAL",
}
-- Último respaldo: posición del árbol en la ventana (orden clásico).
local TREE_ORDER = {
    WARRIOR = { "ARMS", "FURY", "PROT" }, PALADIN = { "HOLY", "PROT", "RET" }, HUNTER = { "BM", "MM", "SV" },
    ROGUE = { "ASSA", "COMBAT", "SUB" }, PRIEST = { "DISC", "HOLY", "SHADOW" }, SHAMAN = { "ELE", "ENH", "RESTO" },
    MAGE = { "ARCANE", "FIRE", "FROST" }, WARLOCK = { "AFFLI", "DEMO", "DESTRO" }, DRUID = { "BALANCE", "FERAL", "RESTO" },
}

-- LE_UNIT_STAT_* -> nuestra clave
local PRIMARY_STAT = { [1] = "STR", [2] = "AGI", [4] = "INT" }

local function SafeString(value)
    if type(value) == "string" and not ns.IsSecret(value) then return value end
end

local function SafeNumber(value)
    if type(value) == "number" and not ns.IsSecret(value) then return value end
end

---------------------------------------------------------------------------
-- Árbol de talentos
---------------------------------------------------------------------------

-- VERIFICAR EN FOREVER: ruta de C_Traits para leer los puntos por árbol (tomada de cómo lo hace Lootified):
--   /dump C_SpecializationInfo.GetCombatConfigIDForSpecGroup(C_SpecializationInfo.GetActiveSpecGroup())
--   /dump C_Traits.GetGroupDisplayInfoByTreeID(C_Traits.GetConfigInfo(<configID>).treeIDs[1])
local function ReadTalentTree(classFile)
    local SI = C_SpecializationInfo
    if not (C_Traits and C_Traits.GetConfigInfo and C_Traits.GetGroupDisplayInfoByTreeID and C_Traits.GetGroupCurrencyInfo
        and SI and SI.GetActiveSpecGroup and SI.GetCombatConfigIDForSpecGroup) then
        return nil
    end
    local configID = SI.GetCombatConfigIDForSpecGroup(SI.GetActiveSpecGroup())
    local config = configID and C_Traits.GetConfigInfo(configID)
    local treeID = config and config.treeIDs and config.treeIDs[1]
    if not treeID then return nil end

    local groups = C_Traits.GetGroupDisplayInfoByTreeID(treeID)
    if not groups or #groups == 0 then return nil end
    local groupIDs = {}
    for i, group in ipairs(groups) do groupIDs[i] = group.groupID end

    local spentByGroup = {}
    for _, info in ipairs(C_Traits.GetGroupCurrencyInfo(configID, groupIDs) or {}) do
        local currency = info.currencyInfos and info.currencyInfos[1]
        local spent = currency and SafeNumber(currency.spent)
        if spent and info.traitNodeGroupID then spentByGroup[info.traitNodeGroupID] = spent end
    end

    local order = TREE_ORDER[classFile]
    local best, bestSpent = nil, 0
    for i, group in ipairs(groups) do
        local spent = spentByGroup[group.groupID] or 0
        if spent > bestSpent then
            local name = SafeString(group.displayName)
            best = TREE_BY_SKILL_LINE[group.skillLineID]
                or (name and TREE_BY_NAME[name:lower()])
                or (order and order[i])
            bestSpent = spent
        end
    end
    return best, bestSpent
end

local cachedTree, treeCached = nil, false

function Player:InvalidateTree()
    treeCached = false
end

function Player:GetTalentTree(classFile)
    if not treeCached then
        local ok, tree = pcall(ReadTalentTree, classFile)
        if not ok then
            ns.Debug("Error leyendo talentos:", tree)
            tree = nil
        end
        cachedTree = tree
        -- Si todavía no hay datos (justo al conectar) no lo cacheamos; se reintenta en el próximo escaneo.
        treeCached = tree ~= nil
    end
    return cachedTree
end

---------------------------------------------------------------------------
-- Spec del sistema moderno (solo si el juego deja elegirla)
---------------------------------------------------------------------------

-- VERIFICAR EN FOREVER: /dump C_SpecializationInfo.IsSpecSelectionEnabled(select(3, UnitClass("player")))
local function ReadSelectableSpec()
    local SI = C_SpecializationInfo
    local getSpec = (SI and SI.GetSpecialization) or GetSpecialization
    local getInfo = (SI and SI.GetSpecializationInfo) or GetSpecializationInfo
    if not (getSpec and getInfo) then return nil end

    local classID = select(3, UnitClass("player"))
    if SI and SI.IsSpecSelectionEnabled and classID and not SI.IsSpecSelectionEnabled(classID) then
        return nil -- spec única de clase: no aporta información
    end
    local index = getSpec()
    if not index or index <= 0 then return nil end
    local specID, _, _, _, role, primaryStat = getInfo(index)
    specID = SafeNumber(specID)
    if not specID then return nil end
    role = SafeString(role)
    return specID, (role == "TANK" or role == "HEALER" or role == "DAMAGER") and role or nil, PRIMARY_STAT[SafeNumber(primaryStat) or 0]
end

---------------------------------------------------------------------------
-- API pública
---------------------------------------------------------------------------

function Player:GetFullName()
    local name, realm = UnitFullName("player")
    realm = realm or (GetNormalizedRealmName and GetNormalizedRealmName())
    if realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

-- Forever usa nombres únicos por región con apellido. En ese modo UnitNameUnmodified devuelve (nombre, apellido);
-- en retail normal el segundo valor es el reino, por eso solo se lee si RegionalUniqueNamesEnabled() es true.
-- VERIFICAR EN FOREVER: /dump RegionalUniqueNamesEnabled(), UnitNameUnmodified("player")
function Player:GetSurname()
    if not (RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled() and UnitNameUnmodified) then return nil end
    local _, surname = UnitNameUnmodified("player")
    surname = SafeString(surname)
    if surname and surname ~= "" then return surname end
end

-- Devuelve el bloque de datos del jugador que se copia al snapshot, más metadatos para la UI (roleSource, statSource).
function Player:GetInfo()
    local _, classFile = UnitClass("player")
    local info = {
        name = self:GetFullName(),
        surname = self:GetSurname(),
        class = classFile,
        level = UnitLevel("player"),
        race = select(3, UnitRace("player")), -- raceID (para el modelo 3D en la ficha de los amigos)
        sex = UnitSex("player"),              -- 2 = masculino, 3 = femenino
    }

    local specID, specRole, specStat = ReadSelectableSpec()
    info.spec = specID
    info.tree = self:GetTalentTree(classFile)

    local profile = CLASS_PROFILES[classFile] or { default = { "DAMAGER", "STR" } }
    local treeProfile = info.tree and profile[info.tree]
    local autoRole, autoStat, autoSource
    if specRole or specStat then
        autoRole, autoStat, autoSource = specRole, specStat, "SPEC"
    end
    if treeProfile then
        autoRole = autoRole or treeProfile[1]
        autoStat = autoStat or treeProfile[2]
        autoSource = autoSource or "TREE"
    end
    autoRole = autoRole or profile.default[1]
    autoStat = autoStat or profile.default[2]
    autoSource = autoSource or "CLASS"

    local override = ns.addon.db.char.override
    info.role = override.role or autoRole
    info.mainStat = override.mainStat or autoStat
    info.roleSource = override.role and "MANUAL" or autoSource
    info.statSource = override.mainStat and "MANUAL" or autoSource
    return info
end

-- key: "role" | "mainStat"; value: false = automático.
function Player:SetOverride(key, value)
    ns.addon.db.char.override[key] = value or false
    ns.Scanner:RequestScan()
end
