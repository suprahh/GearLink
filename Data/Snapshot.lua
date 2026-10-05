-- GearLink - modelo de datos del snapshot (equipo + bolsas). Se usa en local y, desde la fase 3, por red.
--
-- Esquema v1:
-- {
--   v = 1,                     -- versión del esquema
--   name = "Nombre-Reino",     -- identidad técnica (clave de caché, destino de whispers)
--   surname = "Apellido",      -- solo para mostrar; nil si el cliente no usa apellidos
--   class = "WARRIOR",         -- classFile
--   level = 12,
--   spec = nil,                -- specID solo si el juego deja elegir spec (en Forever normalmente nil)
--   tree = "PROT",             -- árbol de talentos con más puntos (nil si no se pudo leer)
--   role = "TANK",             -- TANK | HEALER | DAMAGER (efectivo, ya con el override manual)
--   mainStat = "STR",          -- STR | AGI | INT (efectivo)
--   ts = 1700000000,           -- time() del escaneo
--   equipped = { [slotID] = itemLink },
--   bags = { { link = itemLink, count = 1, bag = 0, slot = 3, tradeable = true, bind = "BOE" }, ... },
--   hash = "1a2b3c4d",
-- }
-- bind: "UNBOUND" | "BOE" | "TRADE_WINDOW" | "SOULBOUND" | "UNKNOWN"
local _, ns = ...
local L = ns.L

local Snapshot = {}
ns.Snapshot = Snapshot

Snapshot.SCHEMA_VERSION = 1

-- Orden de los slots como en la ficha de personaje.
Snapshot.SLOT_ORDER = { 1, 2, 3, 15, 5, 4, 19, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17, 18 }

-- "|cff...|Hitem:123:...|h[Nombre]|h|r" -> "item:123:..." (la forma corta que viajará por red en la fase 3).
function Snapshot.ToItemString(link)
    if type(link) ~= "string" then return nil end
    return link:match("|H(item:[^|]+)|h") or (link:match("^item:") and link) or nil
end

-- Hash djb2 de 32 bits (cabe exacto en un double; no necesita la librería bit).
local function HashString(str)
    local h = 5381
    for i = 1, #str do
        h = (h * 33 + str:byte(i)) % 4294967296
    end
    return ("%08x"):format(h)
end

-- El hash ignora en qué bolsa/slot está cada item: mover cosas dentro de las bolsas no cuenta como cambio.
function Snapshot.ComputeHash(snap)
    local parts = {
        snap.class or "", tostring(snap.level or 0), tostring(snap.spec or ""),
        snap.tree or "", snap.role or "", snap.mainStat or "",
        tostring(snap.race or ""), tostring(snap.sex or ""),
    }
    for slot = INVSLOT_FIRST_EQUIPPED, INVSLOT_LAST_EQUIPPED do
        parts[#parts + 1] = slot .. "=" .. (Snapshot.ToItemString(snap.equipped[slot]) or "")
    end
    local bagParts = {}
    for i, item in ipairs(snap.bags) do
        bagParts[i] = (Snapshot.ToItemString(item.link) or "?") .. "x" .. (item.count or 1) .. (item.tradeable and "T" or "B")
    end
    table.sort(bagParts)
    parts[#parts + 1] = table.concat(bagParts, ",")
    return HashString(table.concat(parts, "|"))
end

-- player: tabla de ns.Player:GetInfo(); equipped/bags: resultado del escaneo.
function Snapshot.New(player, equipped, bags)
    local snap = {
        v = Snapshot.SCHEMA_VERSION,
        name = player.name,
        surname = player.surname,
        class = player.class,
        level = player.level,
        race = player.race,
        sex = player.sex,
        spec = player.spec,
        tree = player.tree,
        role = player.role,
        mainStat = player.mainStat,
        ts = time(),
        equipped = equipped,
        bags = bags,
    }
    snap.hash = Snapshot.ComputeHash(snap)
    return snap
end

function Snapshot.CountTradeable(snap)
    local n = 0
    for _, item in ipairs(snap.bags) do
        if item.tradeable then n = n + 1 end
    end
    return n
end

---------------------------------------------------------------------------
-- Formato de red (fase 3)
--
-- { t="S", v=1, n, sn, c, l, tr, r, s, ts, h,
--   e = { [slotID] = "item:..." },
--   b = { { "item:...", count, bindCode }, ... }   -- nil si no comparte las bolsas
--   sb = true|false }                              -- comparte bolsas
---------------------------------------------------------------------------

local BIND_TO_CODE = { UNBOUND = "U", BOE = "E", TRADE_WINDOW = "W", SOULBOUND = "S", UNKNOWN = "?" }
local CODE_TO_BIND = {}
for bind, code in pairs(BIND_TO_CODE) do CODE_TO_BIND[code] = bind end
local TRADEABLE_BIND = { UNBOUND = true, BOE = true, TRADE_WINDOW = true }

local MAX_BAG_ITEMS = 300
local VALID_ROLE = { TANK = true, HEALER = true, DAMAGER = true }
local VALID_STAT = { STR = true, AGI = true, INT = true }

-- Hash de lo que realmente se comparte: sin bolsas si el jugador no las comparte.
function Snapshot.PublicHash(snap, includeBags)
    if includeBags then return snap.hash end
    local copy = {}
    for k, v in pairs(snap) do copy[k] = v end
    copy.bags = {}
    return Snapshot.ComputeHash(copy)
end

function Snapshot.ToNetwork(snap, includeBags)
    local e = {}
    for slot, link in pairs(snap.equipped) do e[slot] = Snapshot.ToItemString(link) end
    local b
    if includeBags then
        b = {}
        for i, item in ipairs(snap.bags) do
            b[i] = { Snapshot.ToItemString(item.link), item.count, BIND_TO_CODE[item.bind] or "?" }
        end
    end
    return {
        v = Snapshot.SCHEMA_VERSION,
        n = snap.name, sn = snap.surname,
        c = snap.class, l = snap.level, tr = snap.tree, r = snap.role, s = snap.mainStat,
        ra = snap.race, sx = snap.sex,
        ts = snap.ts, h = Snapshot.PublicHash(snap, includeBags),
        e = e, b = b, sb = includeBags and true or false,
    }
end

local function ValidItemString(s)
    return type(s) == "string" and #s <= 250 and s:match("^item:[%d:%-]+$") ~= nil
end

local function OptString(v, maxLen, pattern)
    if type(v) ~= "string" or #v == 0 or #v > maxLen then return nil end
    if pattern and not v:match(pattern) then return nil end
    return v
end

-- Muestra corta y segura de un valor rechazado (para diagnóstico en /gl debug).
local function Sample(v)
    if type(v) ~= "string" then return type(v) end
    return (v:sub(1, 80):gsub("|", "||"))
end

-- Convierte un SNAPSHOT recibido en un snapshot local.
-- Estructura inválida (esquema, tipos) -> nil, motivo.
-- Items sueltos inválidos -> se descartan uno a uno (snap.skipped, snap.skippedSample) y el resto se muestra.
-- Nunca lanza errores: todo se comprueba antes de usarse.
function Snapshot.FromNetwork(msg)
    if type(msg) ~= "table" then return nil, "no es tabla" end
    if msg.v ~= Snapshot.SCHEMA_VERSION then return nil, "esquema " .. tostring(msg.v) end
    if type(msg.e) ~= "table" then return nil, "sin equipo" end
    if msg.b ~= nil and type(msg.b) ~= "table" then return nil, "bolsas inválidas" end

    local skipped, sample = 0, nil
    local function Skip(what)
        skipped = skipped + 1
        sample = sample or what
    end

    local equipped, n = {}, 0
    for slot, itemString in pairs(msg.e) do
        n = n + 1
        if n > 40 then break end -- más de lo posible: se ignora el resto
        if type(slot) ~= "number" or slot < INVSLOT_FIRST_EQUIPPED or slot > INVSLOT_LAST_EQUIPPED or slot % 1 ~= 0 then
            Skip("slot " .. Sample(tostring(slot)))
        elseif not ValidItemString(itemString) then
            Skip("slot " .. slot .. ": " .. Sample(itemString))
        else
            equipped[slot] = itemString
        end
    end

    local bags = {}
    if msg.b ~= nil then
        for i = 1, MAX_BAG_ITEMS do
            local entry = msg.b[i]
            if entry == nil then break end
            if type(entry) ~= "table" or not ValidItemString(entry[1]) then
                Skip("bolsa " .. i .. ": " .. Sample(type(entry) == "table" and entry[1] or entry))
            else
                local count = tonumber(entry[2]) or 1
                if count < 1 or count > 10000 then count = 1 end
                local bind = CODE_TO_BIND[entry[3]] or "UNKNOWN"
                bags[#bags + 1] = { link = entry[1], count = math.floor(count), tradeable = TRADEABLE_BIND[bind] or false, bind = bind }
            end
        end
    end

    local level = tonumber(msg.l)
    local ts = tonumber(msg.ts)
    local race = tonumber(msg.ra)
    return {
        v = Snapshot.SCHEMA_VERSION,
        name = OptString(msg.n, 64),
        surname = OptString(msg.sn, 32),
        class = OptString(msg.c, 20, "^[A-Z]+$"),
        level = (level and level >= 1 and level <= 200) and math.floor(level) or nil,
        tree = OptString(msg.tr, 12, "^[A-Z]+$"),
        role = VALID_ROLE[msg.r] and msg.r or nil,
        mainStat = VALID_STAT[msg.s] and msg.s or nil,
        race = (race and race >= 1 and race <= 200 and race % 1 == 0) and race or nil,
        sex = (msg.sx == 2 or msg.sx == 3) and msg.sx or nil,
        ts =(ts and ts > 0 and ts < 4e9) and math.floor(ts) or time(),
        hash = OptString(msg.h, 16, "^%x+$"),
        equipped = equipped,
        bags = bags,
        sharedBags = msg.sb ~= false and msg.b ~= nil,
        receivedAt = time(),
        skipped = skipped > 0 and skipped or nil,
        skippedSample = sample,
    }
end

-- Volcado legible al chat (/gl dump).
function Snapshot.Print(snap)
    local addon = ns.addon
    if not snap then return addon:Print(L.NO_SNAPSHOT) end
    addon:Print(("v=%d  %s  apellido=%s  %s  nivel %d  spec=%s  tree=%s  role=%s  stat=%s"):format(
        snap.v, snap.name or "?", tostring(snap.surname), snap.class or "?", snap.level or 0, tostring(snap.spec),
        tostring(snap.tree), tostring(snap.role), tostring(snap.mainStat)))
    addon:Print(("ts=%s (%s)  hash=%s"):format(snap.ts, date("%H:%M:%S", snap.ts), snap.hash))
    addon:Print("equipped:")
    for _, slot in ipairs(Snapshot.SLOT_ORDER) do
        local link = snap.equipped[slot]
        if link then print(("   [%d] %s"):format(slot, link)) end
    end
    addon:Print(("bags (%d):"):format(#snap.bags))
    for _, item in ipairs(snap.bags) do
        print(("   %d/%d  %s x%d  %s"):format(item.bag, item.slot, item.link, item.count, item.bind))
    end
end
