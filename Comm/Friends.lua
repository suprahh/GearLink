-- GearLink - contactos de confianza y handshake.
--
-- Fuentes de contactos:
--   CHAR   - lista de amigos de personaje (C_FriendList)
--   BN     - amigos de Battle.net jugando a este mismo cliente (C_BattleNet)
--   MANUAL - agregados con /gl add o desde la pestaña Amigos
-- Solo se aceptan mensajes de contactos. Handshake: HELLO -> HELLO_ACK; BYE al salir.
--
-- Identidad en Forever: "Nombre-Apellido" (nombres únicos por región; el apellido ocupa el lugar del reino).
local _, ns = ...
local L = ns.L
local GearLink = ns.addon
local Comm = ns.Comm
local T = Comm.T

local Friends = GearLink:NewModule("Friends", "AceEvent-3.0")
ns.Friends = Friends

local LOGIN_HELLO_DELAY = 5   -- s tras entrar (la lista de amigos tarda en llegar)
local HELLO_ALL_THROTTLE = 30 -- s mínimo entre saludos a todos (salvo forzado)
local ACK_THROTTLE = 5        -- s mínimo entre respuestas al mismo contacto

-- contactos en memoria: clave -> contacto
-- contacto = { key, name, sources = {CHAR=,BN=,MANUAL=}, online, battleTag, bnGameAccountID, bnCharName,
--              friendClass, friendLevel, hasAddonSession, lastAck }
local contacts = {}
Friends.contacts = contacts

local lastHelloAll = 0

---------------------------------------------------------------------------
-- Nombres
---------------------------------------------------------------------------

-- "  El Phito " -> "El-Phito". Deja tal cual un nombre sin apellido.
function Friends.NormalizeName(name)
    if type(name) ~= "string" or ns.IsSecret(name) then return nil end
    name = strtrim(name):gsub("%s+", "-")
    if name == "" then return nil end
    return name
end

function Friends.Key(name)
    return name and name:lower()
end

local function BNKey(battleTag)
    return "bn:" .. battleTag:lower()
end

local function IsSelf(name)
    return Friends.Key(name) == Friends.Key(ns.Player:GetFullName())
end

---------------------------------------------------------------------------
-- Datos persistentes por contacto (db.global.contacts)
---------------------------------------------------------------------------

local function Persisted(key)
    local store = GearLink.db.global.contacts
    store[key] = store[key] or {}
    return store[key]
end

local VALID_ROLE = { TANK = true, HEALER = true, DAMAGER = true }
local VALID_STAT = { STR = true, AGI = true, INT = true }

local function Str(v, maxLen, pattern)
    if type(v) ~= "string" or #v == 0 or #v > maxLen then return nil end
    if pattern and not v:match(pattern) then return nil end
    return v
end

-- Copia solo los campos válidos de un HELLO/HELLO_ACK. Nada de lo recibido se usa sin pasar por aquí.
local function SanitizeHello(msg)
    local level = tonumber(msg.l)
    return {
        av = Str(msg.av, 20, "^[%w%.%-]+$"),
        pv = (type(msg.pv) == "number" and msg.pv >= 0 and msg.pv < 1000) and msg.pv or nil,
        name = Str(msg.n, 64),
        surname = Str(msg.sn, 32),
        class = Str(msg.c, 20, "^[A-Z]+$"),
        level = (level and level >= 1 and level <= 200) and math.floor(level) or nil,
        tree = Str(msg.tr, 12, "^[A-Z]+$"),
        role = VALID_ROLE[msg.r] and msg.r or nil,
        mainStat = VALID_STAT[msg.s] and msg.s or nil,
        hash = Str(msg.h, 16, "^%x+$"),
        receiveOffers = msg.ro ~= false,
    }
end

---------------------------------------------------------------------------
-- Registro de contactos
---------------------------------------------------------------------------

local function GetOrCreate(key, name)
    local c = contacts[key]
    if not c then
        c = { key = key, name = name, sources = {} }
        contacts[key] = c
    elseif name and not c.name then
        c.name = name
    end
    return c
end

local function DropSource(source, seen)
    for key, c in pairs(contacts) do
        if c.sources[source] and not seen[key] then
            c.sources[source] = nil
            if source == "BN" then c.bnGameAccountID, c.online = nil, false end
            if not next(c.sources) then contacts[key] = nil end
        end
    end
end

-- Devuelve los contactos que acaban de conectarse (para saludarlos).
function Friends:RefreshCharFriends()
    local seen, cameOnline = {}, {}
    for i = 1, C_FriendList.GetNumFriends() or 0 do
        local info = C_FriendList.GetFriendInfoByIndex(i)
        local name = info and Friends.NormalizeName(info.name)
        if name then
            local key = Friends.Key(name)
            local c = GetOrCreate(key, name)
            local wasOnline = c.online
            c.sources.CHAR = true
            c.online = info.connected and true or false
            c.friendClass = info.className
            c.friendLevel = info.level
            if c.online and not wasOnline then cameOnline[#cameOnline + 1] = c end
            seen[key] = true
        end
    end
    DropSource("CHAR", seen)
    return cameOnline
end

-- VERIFICAR EN FOREVER: cómo se ve un amigo de Battle.net jugando a Forever ->
--   /dump C_BattleNet.GetFriendGameAccountInfo(1, 1)   (clientProgram, wowProjectID, isInCurrentRegion, characterName, realmName)
local function FindForeverGameAccount(friendIndex)
    local numGameAccounts = C_BattleNet.GetFriendNumGameAccounts(friendIndex) or 0
    for j = 1, numGameAccounts do
        local ga = C_BattleNet.GetFriendGameAccountInfo(friendIndex, j)
        if ga and ga.isOnline and ga.gameAccountID and ga.clientProgram == BNET_CLIENT_WOW
            and ga.wowProjectID == WOW_PROJECT_ID and ga.isInCurrentRegion ~= false then
            return ga
        end
    end
end

function Friends:RefreshBNFriends()
    local seen, cameOnline = {}, {}
    if not (BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendAccountInfo and C_BattleNet.GetFriendNumGameAccounts) then
        return cameOnline
    end
    for i = 1, (BNGetNumFriends()) or 0 do
        local account = C_BattleNet.GetFriendAccountInfo(i)
        local battleTag = account and account.battleTag
        if type(battleTag) == "string" and not ns.IsSecret(battleTag) then
            local key = BNKey(battleTag)
            local ga = FindForeverGameAccount(i)
            if ga or contacts[key] or GearLink.db.global.contacts[key] then
                local c = GetOrCreate(key)
                local wasOnline = c.online
                c.sources.BN = true
                c.battleTag = battleTag
                c.online = ga ~= nil
                c.bnGameAccountID = ga and ga.gameAccountID or nil
                c.bnCharName = ga and ga.characterName or nil
                if ga then
                    c.friendClass = ga.className
                    c.friendLevel = ga.characterLevel
                end
                if c.online and not wasOnline then cameOnline[#cameOnline + 1] = c end
                seen[key] = true
            end
        end
    end
    DropSource("BN", seen)
    return cameOnline
end

function Friends:LoadManual()
    for key, name in pairs(GearLink.db.global.manual) do
        GetOrCreate(key, name).sources.MANUAL = true
    end
end

function Friends:NotifyChanged()
    GearLink:SendMessage(ns.MSG_CONTACTS_UPDATED)
end

---------------------------------------------------------------------------
-- Resolución del remitente (seguridad: solo contactos)
---------------------------------------------------------------------------

function Friends:ResolveOrigin(origin)
    if origin.kind == "BN" then
        for _, c in pairs(contacts) do
            if c.bnGameAccountID == origin.gameAccountID then return c end
        end
        -- Puede haberse conectado hace un instante: refrescamos y reintentamos una vez.
        self:RefreshBNFriends()
        for _, c in pairs(contacts) do
            if c.bnGameAccountID == origin.gameAccountID then return c end
        end
        return nil
    end

    local name = Friends.NormalizeName(origin.name)
    if not name or IsSelf(name) then return nil end
    local key = Friends.Key(name)
    if contacts[key] then return contacts[key] end
    -- VERIFICAR EN FOREVER: si el remitente llega sin apellido ("El"), lo aceptamos solo si hay UN contacto con ese nombre.
    if not name:find("-", 1, true) then
        local match
        for k, c in pairs(contacts) do
            if not c.sources.BN and k:sub(1, #key + 1) == key .. "-" then
                if match then return nil end -- ambiguo
                match = c
            end
        end
        if match then ns.Debug("Remitente sin apellido:", origin.name, "->", match.name) end
        return match
    end
    return nil
end

-- Destino para enviarle algo a un contacto.
local function TargetFor(c)
    if c.bnGameAccountID then return { kind = "BN", gameAccountID = c.bnGameAccountID } end
    if c.name and not c.sources.BN then return { kind = "CHAR", name = c.name } end
end

---------------------------------------------------------------------------
-- Handshake
---------------------------------------------------------------------------

function Friends:GetTarget(c)
    return TargetFor(c)
end

function Friends:GetContact(key)
    return contacts[key]
end

local function BuildHello(msgType)
    local snap = ns.Scanner:GetSnapshot()
    local p = snap or ns.Player:GetInfo()
    return {
        t = msgType,
        av = ns.VERSION,
        n = ns.Player:GetFullName(),
        sn = ns.Player:GetSurname(),
        c = p.class, l = p.level, tr = p.tree, r = p.role, s = p.mainStat,
        h = ns.Sync:GetPublicHash(),
        ro = GearLink.db.global.receiveOffers and true or false,
    }
end

function Friends:SendHello(c, msgType)
    local target = TargetFor(c)
    if target then Comm:Send(target, BuildHello(msgType or T.HELLO)) end
end

-- Saluda a los contactos conectados y a los manuales (de estos no sabemos si están conectados).
function Friends:SendHelloAll(force)
    local now = GetTime()
    if not force and now - lastHelloAll < HELLO_ALL_THROTTLE then return end
    lastHelloAll = now
    local count = 0
    for _, c in pairs(contacts) do
        if c.online or (c.sources.MANUAL and c.online ~= false) or (c.sources.MANUAL and force) then
            self:SendHello(c)
            count = count + 1
        end
    end
    if force then GearLink:Print(L.HELLO_SENT:format(count)) end
end

-- "0.10.2" > "0.9.5": compara por números, no como texto.
local function IsNewerVersion(other, mine)
    if type(other) ~= "string" or type(mine) ~= "string" then return false end
    local a, b = {}, {}
    for n in other:gmatch("%d+") do a[#a + 1] = tonumber(n) end
    for n in mine:gmatch("%d+") do b[#b + 1] = tonumber(n) end
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

-- Aviso (una vez por versión y sesión) cuando un contacto tiene un GearLink más nuevo que el mío.
local newestSeen
local function CheckNewerVersion(c, version)
    if not IsNewerVersion(version, ns.VERSION) then return end
    if newestSeen and not IsNewerVersion(version, newestSeen) then return end
    newestSeen = version
    local name = GearLink.db.global.contacts[c.key] and GearLink.db.global.contacts[c.key].name or c.name or "?"
    GearLink:Print(L.NEWER_VERSION:format((name:gsub("-", " ")), version, ns.VERSION))
end

local function ApplyHello(c, msg)
    local info = SanitizeHello(msg)
    CheckNewerVersion(c, info.av)
    local stored = Persisted(c.key)
    for k, v in pairs(info) do stored[k] = v end
    stored.lastSeen = time()
    if not c.name then c.name = info.name end
    c.online = true
    c.hasAddonSession = true
    ns.Sync:MaybeAutoSync(c, info.hash)
end

local function OnHello(msg, c)
    ApplyHello(c, msg)
    local now = GetTime()
    if not c.lastAck or now - c.lastAck > ACK_THROTTLE then
        c.lastAck = now
        Friends:SendHello(c, T.HELLO_ACK)
    end
    Friends:NotifyChanged()
end

local function OnHelloAck(msg, c)
    ApplyHello(c, msg)
    Friends:NotifyChanged()
end

local function OnBye(_, c)
    c.online = false
    c.hasAddonSession = false
    Persisted(c.key).lastSeen = time()
    Friends:NotifyChanged()
end

-- PING/PONG: diagnóstico de nombres. El PONG cuenta cómo nos vio llegar el otro.
local function OnPing(msg, c, origin)
    GearLink:Print(L.PING_RECEIVED:format(tostring(origin.name or origin.gameAccountID)))
    local target = TargetFor(c)
    if target then
        Comm:Send(target, { t = T.PONG, seenAs = tostring(origin.name or origin.gameAccountID), id = msg.id, pst = msg.st }, "ALERT")
    end
end

local function OnPong(msg, c, origin)
    GearLink:Print(L.PONG_RECEIVED:format(tostring(origin.name or origin.gameAccountID), Str(msg.seenAs, 80) or "?"))
    -- Ida y vuelta: hora de salida del PING (devuelta en el PONG) contra ahora. Válido siempre (mismo cliente).
    if type(msg.pst) == "number" then
        GearLink:Print(L.PING_RTT:format(GetTime() - msg.pst))
    end
end

function Friends:Ping(rawName)
    local name = strtrim(rawName)
    GearLink:Print(L.PING_SENT:format(name))
    Comm:Send({ kind = "CHAR", name = name }, { t = T.PING, id = math.random(1, 1e6) }, "ALERT")
end

---------------------------------------------------------------------------
-- Lista manual
---------------------------------------------------------------------------

function Friends:AddManual(rawName)
    local name = Friends.NormalizeName(rawName)
    if not name then return end
    if IsSelf(name) then return GearLink:Print(L.CANNOT_ADD_SELF) end
    local key = Friends.Key(name)
    GearLink.db.global.manual[key] = name
    local c = GetOrCreate(key, name)
    c.sources.MANUAL = true
    c.online = nil -- desconocido hasta que responda
    GearLink:Print(L.MANUAL_ADDED:format(name))
    self:SendHello(c)
    self:NotifyChanged()
end

function Friends:RemoveManual(rawName)
    local key = Friends.Key(Friends.NormalizeName(rawName))
    if not key or not GearLink.db.global.manual[key] then
        return GearLink:Print(L.MANUAL_NOT_FOUND:format(tostring(rawName)))
    end
    GearLink:Print(L.MANUAL_REMOVED:format(GearLink.db.global.manual[key]))
    GearLink.db.global.manual[key] = nil
    local c = contacts[key]
    if c then
        c.sources.MANUAL = nil
        if not next(c.sources) then contacts[key] = nil end
    end
    self:NotifyChanged()
end

-- Casilla "Sugerir": ¿se evalúan mis items para este contacto? Elegido a mano, o por defecto solo si usa GearLink
-- (así un amigo sin el addon no genera sugerencias hasta que lo marques).
function Friends:IsTracked(key)
    local explicit = GearLink.db.global.tracking[key]
    if explicit ~= nil then return explicit end
    local stored = GearLink.db.global.contacts[key]
    return stored ~= nil and stored.av ~= nil
end

function Friends:SetTracked(key, tracked)
    GearLink.db.global.tracking[key] = tracked and true or false
    self:NotifyChanged() -- Matches recalcula al recibir MSG_CONTACTS_UPDATED
end

-- Nombre de clase localizado ("Guerrero") -> classFile ("WARRIOR"). La lista de amigos y Battle.net solo dan el
-- nombre localizado; con esto se pueden sugerir items a amigos sin GearLink.
local classByLocalizedName
function Friends.ClassFileFromLocalized(name)
    if type(name) ~= "string" or ns.IsSecret(name) then return nil end
    if not classByLocalizedName then
        classByLocalizedName = {}
        for _, names in ipairs({ LOCALIZED_CLASS_NAMES_MALE or {}, LOCALIZED_CLASS_NAMES_FEMALE or {} }) do
            for classFile, localized in pairs(names) do classByLocalizedName[localized:lower()] = classFile end
        end
    end
    return classByLocalizedName[name:lower()]
end

-- Llamado por Comm cuando el servidor responde "no hay ningún personaje llamado ...".
function Friends:MarkOffline(name)
    local c = contacts[Friends.Key(Friends.NormalizeName(name))]
    if c and c.online ~= false then
        c.online = false
        c.hasAddonSession = false
        self:NotifyChanged()
    end
end

---------------------------------------------------------------------------
-- Consultas para la UI
---------------------------------------------------------------------------

-- Lo que se muestra de un contacto: mezcla datos en vivo y persistentes.
function Friends:GetView(c)
    local stored = GearLink.db.global.contacts[c.key] or {}
    local name = stored.name or c.name or c.bnCharName or c.battleTag or c.key
    return {
        key = c.key,
        name = name,
        displayName = (name:match("^[^-]+") or name) .. (stored.surname and (" " .. stored.surname) or ""),
        sources = c.sources,
        battleTag = c.battleTag,
        online = c.online,
        hasAddon = c.hasAddonSession or false,
        everHadAddon = stored.av ~= nil,
        class = stored.class or Friends.ClassFileFromLocalized(c.friendClass),
        level = stored.level or c.friendLevel,
        tree = stored.tree,
        role = stored.role,
        mainStat = stored.mainStat,
        addonVersion = stored.av,
        compatible = stored.pv == nil or stored.pv == Comm.PROTOCOL_VERSION,
        protocol = stored.pv,
        lastSeen = stored.lastSeen,
        hash = stored.hash,
        isManual = c.sources.MANUAL and true or false,
        receiveOffers = stored.receiveOffers ~= false,
        tracked = Friends:IsTracked(c.key),
    }
end

-- Contactos a mostrar: con GearLink (alguna vez), conectados o manuales. Ordenados: con addon > conectados > resto.
function Friends:GetList()
    local list = {}
    for _, c in pairs(contacts) do
        local v = self:GetView(c)
        if v.hasAddon or v.everHadAddon or v.online or v.isManual then list[#list + 1] = v end
    end
    local function rank(v) return (v.hasAddon and 0) or (v.online and 1) or 2 end
    table.sort(list, function(a, b)
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        return a.displayName:lower() < b.displayName:lower()
    end)
    return list
end

function Friends:PrintList()
    local list = self:GetList()
    if #list == 0 then return GearLink:Print(L.NO_CONTACTS) end
    GearLink:Print(L.CONTACTS_HEADER:format(#list))
    for _, v in ipairs(list) do
        local sources = {}
        for s in pairs(v.sources) do sources[#sources + 1] = s end
        local status = v.hasAddon and "|cff1eff00GearLink|r" or (v.online and L.STATUS_ONLINE) or (v.online == false and L.STATUS_OFFLINE) or "?"
        print(("   %s [%s] %s  %s nv%s  v%s%s  %s"):format(
            v.name, table.concat(sources, ","), status, tostring(v.class or "-"), tostring(v.level or "-"),
            tostring(v.addonVersion or "-"), v.compatible and "" or " |cffff0000(incompatible)|r",
            v.lastSeen and date("%d/%m %H:%M", v.lastSeen) or ""))
    end
end

---------------------------------------------------------------------------
-- Eventos
---------------------------------------------------------------------------

local function HelloList(list)
    for _, c in ipairs(list) do Friends:SendHello(c) end
end

function Friends:OnFriendListUpdate()
    ns.Debounce("friends:char", 0.5, function()
        HelloList(self:RefreshCharFriends())
        self:NotifyChanged()
    end)
end

function Friends:OnBNUpdate()
    ns.Debounce("friends:bn", 1, function()
        HelloList(self:RefreshBNFriends())
        self:NotifyChanged()
    end)
end

function Friends:PLAYER_LOGOUT()
    for _, c in pairs(contacts) do
        if c.hasAddonSession then
            local target = TargetFor(c)
            if target then Comm:SendImmediate(target, { t = T.BYE }) end
        end
    end
end

function Friends:OnEnable()
    Comm:RegisterHandler(T.HELLO, OnHello)
    Comm:RegisterHandler(T.HELLO_ACK, OnHelloAck)
    Comm:RegisterHandler(T.BYE, OnBye)
    Comm:RegisterHandler(T.PING, OnPing)
    Comm:RegisterHandler(T.PONG, OnPong)

    self:LoadManual()
    self:RegisterEvent("FRIENDLIST_UPDATE", "OnFriendListUpdate")
    for _, event in ipairs({ "BN_FRIEND_INFO_CHANGED", "BN_FRIEND_ACCOUNT_ONLINE", "BN_FRIEND_ACCOUNT_OFFLINE",
        "BN_CONNECTED", "BN_DISCONNECTED" }) do
        ns.SafeRegisterEvent(self, event, "OnBNUpdate")
    end
    self:RegisterEvent("PLAYER_LOGOUT")

    C_FriendList.ShowFriends() -- pide la lista al servidor; responde con FRIENDLIST_UPDATE
    C_Timer.After(LOGIN_HELLO_DELAY, function()
        self:RefreshCharFriends()
        self:RefreshBNFriends()
        self:SendHelloAll(false)
        self:NotifyChanged()
    end)
end
