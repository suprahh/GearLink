-- GearLink - núcleo: AceAddon, base de datos, utilidades compartidas, cola de combate y slash commands.
local addonName, ns = ...
local L = ns.L

local GearLink = LibStub("AceAddon-3.0"):NewAddon(addonName, "AceConsole-3.0", "AceEvent-3.0")
ns.addon = GearLink

local GetMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
ns.VERSION = GetMetadata(addonName, "Version") or "?"

-- Forever comparte WOW_PROJECT_ID con retail; se reconoce por el rango de la versión de interfaz (1.60.x -> 16xxx).
local interfaceVersion = select(4, GetBuildInfo())
ns.INTERFACE = interfaceVersion
ns.IS_FOREVER = interfaceVersion >= 16000 and interfaceVersion < 17000

-- Mensajes internos (AceEvent:SendMessage) para desacoplar datos y UI.
ns.MSG_SNAPSHOT_UPDATED = "GEARLINK_SNAPSHOT_UPDATED" -- (snapshot, changed)
ns.MSG_CONTACTS_UPDATED = "GEARLINK_CONTACTS_UPDATED" -- ()
ns.MSG_FRIEND_SNAPSHOT = "GEARLINK_FRIEND_SNAPSHOT" -- (contactKey): cambió el estado o el snapshot de un amigo
ns.MSG_MATCHES_UPDATED = "GEARLINK_MATCHES_UPDATED" -- (): se recalcularon las mejoras para amigos

local defaults = {
    global = {
        debug = false,
        window = { point = "CENTER", relPoint = "CENTER", x = 0, y = 0, tab = 1 },
        minimap = { hide = false }, -- LibDBIcon guarda aquí también la posición (minimapPos)
        -- Contactos agregados a mano: clave en minúsculas -> "Nombre-Apellido" tal como se escribió.
        manual = {},
        -- Lo último que supimos de cada contacto con GearLink (persistente, a nivel de cuenta).
        -- clave -> { name, surname, class, level, tree, role, mainStat, av, pv, hash, lastSeen }
        contacts = {},
        -- Último snapshot recibido de cada contacto (se ve aunque esté desconectado). clave -> snapshot local
        friendSnapshots = {},
        -- Casilla "Sugerir" elegida a mano: clave -> true/false. Sin entrada: marcada solo si el contacto usa GearLink.
        tracking = {},
        autoSync = true,    -- pedir solo el snapshot de contactos cuyo hash cambió (uno cada 10 s)
        notifyLoot = true,  -- aviso + sonido cuando recibo loot que le sirve a un amigo
        -- Fase 5: ofertas
        offerMode = "CHAT",     -- "CHAT" = abrir el chat con el mensaje escrito | "DIRECT" = enviar el whisper directo
        offerTemplate = false,  -- false = plantilla por defecto (L.OFFER_TEMPLATE_DEFAULT)
        acceptTemplate = false, -- false = mensaje por defecto al aceptar (L.ACCEPT_TEMPLATE_DEFAULT)
        receiveOffers = true,   -- mostrar el popup cuando un amigo me ofrece algo
        offerCooldown = 10,     -- minutos entre ofertas del mismo item al mismo amigo
    },
    char = {
        shareBags = true, -- "Compartir mi inventario con amigos"; si es false solo se comparte el equipo
        offers = {},      -- "clave-amigo|item:..." -> time() de la última oferta (anti-spam)
        deliveries = {},  -- entregas pendientes (ofertas aceptadas): id -> { key, to, display, item, at }
        openOffers = {},  -- una oferta abierta por item: "item:..." -> { key, display, at }
        -- false = automático. Valores: role = "TANK"|"HEALER"|"DAMAGER", mainStat = "STR"|"AGI"|"INT".
        override = { role = false, mainStat = false },
        -- snapshot = <último snapshot propio> (sin default: nil hasta el primer escaneo)
    },
}

---------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------

-- Valores "secretos" de Midnight: no se pueden comparar ni concatenar. Hay que descartarlos.
function ns.IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value) or false
end

-- Convierte un formato de GlobalStrings ("No hay ningún personaje llamado '%s'...") en un patrón Lua.
-- capture = true: cada %s/%d se convierte en una captura "(.+)".
function ns.FormatToPattern(fmt, capture)
    if type(fmt) ~= "string" then return nil end
    local p = fmt:gsub("%%%d*%$?[sd]", "\001")
    p = p:gsub("[%(%)%.%+%-%*%?%[%]%^%$%%]", "%%%0")
    return (p:gsub("\001", capture and "(.+)" or ".+"))
end

-- 75 -> "1 min", 7200 -> "2 h"
function ns.FormatAgo(seconds)
    seconds = math.max(0, seconds or 0)
    if seconds < 60 then return ("%d s"):format(seconds) end
    if seconds < 3600 then return ("%d min"):format(seconds / 60) end
    if seconds < 86400 then return ("%d h"):format(seconds / 3600) end
    return ("%d d"):format(seconds / 86400)
end

function ns.Debug(...)
    if GearLink.db and GearLink.db.global.debug then
        -- Marca de tiempo (segundos) para poder medir demoras entre los dos clientes.
        GearLink:Print(("|cff888888[debug %s]|r"):format(date("%H:%M:%S")), ...)
    end
end

-- Registra un evento solo si existe en este cliente (registrar uno inexistente produce un error Lua).
function ns.SafeRegisterEvent(target, event, handler)
    if C_EventUtils and C_EventUtils.IsEventValid then
        if not C_EventUtils.IsEventValid(event) then
            ns.Debug("Evento no disponible:", event)
            return false
        end
        target:RegisterEvent(event, handler)
        return true
    end
    local ok = pcall(target.RegisterEvent, target, event, handler)
    if not ok then ns.Debug("Evento no disponible:", event) end
    return ok
end

-- Debounce con retraso al final: varias llamadas seguidas con la misma clave ejecutan `fn` una sola vez.
local debounceTimers = {}
function ns.Debounce(key, delay, fn)
    local timer = debounceTimers[key]
    if timer then timer:Cancel() end
    debounceTimers[key] = C_Timer.NewTimer(delay, function()
        debounceTimers[key] = nil
        fn()
    end)
end

-- Cola de combate: si estamos en combate, la acción se guarda (una por clave) y se ejecuta en PLAYER_REGEN_ENABLED.
-- Las fases de red (2+) también pasarán por aquí.
local combatQueue, combatQueueOrder = {}, {}
function ns.RunOutOfCombat(key, fn)
    if not InCombatLockdown() then
        fn()
        return true
    end
    if not combatQueue[key] then
        combatQueueOrder[#combatQueueOrder + 1] = key
    end
    combatQueue[key] = fn
    return false
end

function GearLink:PLAYER_REGEN_ENABLED()
    local order = combatQueueOrder
    combatQueueOrder = {}
    for _, key in ipairs(order) do
        local fn = combatQueue[key]
        combatQueue[key] = nil
        if fn then xpcall(fn, geterrorhandler()) end
    end
end

---------------------------------------------------------------------------
-- Ciclo de vida
---------------------------------------------------------------------------

function GearLink:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("GearLinkDB", defaults, true)
    self:RegisterChatCommand("gl", "OnSlashCommand")
    self:RegisterChatCommand("gearlink", "OnSlashCommand")
end

function GearLink:OnEnable()
    self:RegisterEvent("PLAYER_REGEN_ENABLED")
    self:Print(L.LOADED:format(ns.VERSION))
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local ROLE_ARGS = { tank = "TANK", healer = "HEALER", heal = "HEALER", damager = "DAMAGER", dps = "DAMAGER", auto = false }
local STAT_ARGS = { str = "STR", agi = "AGI", int = "INT", auto = false }

function GearLink:OnSlashCommand(input)
    -- "add El Phito" -> cmd = "add", rest = "El Phito" (el resto conserva espacios y mayúsculas)
    local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    local arg = rest ~= "" and rest:lower() or nil

    if cmd == "" then
        ns.MainFrame:Toggle()
    elseif cmd == "scan" then
        ns.Scanner:ScanNow(true)
    elseif cmd == "dump" then
        ns.Snapshot.Print(ns.Scanner:GetSnapshot())
    elseif cmd == "role" then
        local value = ROLE_ARGS[arg or ""]
        if value == nil then return self:Print(L.INVALID_VALUE:format(tostring(arg))) end
        ns.Player:SetOverride("role", value)
        self:Print(L.ROLE_SET:format(value and L["ROLE_" .. value] or L.AUTO))
    elseif cmd == "stat" then
        local value = STAT_ARGS[arg or ""]
        if value == nil then return self:Print(L.INVALID_VALUE:format(tostring(arg))) end
        ns.Player:SetOverride("mainStat", value)
        self:Print(L.STAT_SET:format(value and L["STAT_" .. value] or L.AUTO))
    elseif cmd == "whoami" then
        -- Diagnóstico de identidad: cómo nombra Forever al jugador (necesario para direccionar mensajes en la fase 2).
        local function show(label, fn, ...)
            if type(fn) ~= "function" then return self:Print(label, "= |cffff8000(no existe)|r") end
            local results = { pcall(fn, ...) }
            if not results[1] then return self:Print(label, "= |cffff0000error|r", tostring(results[2])) end
            local parts = {}
            for i = 2, #results do parts[#parts + 1] = ("%q"):format(tostring(results[i])) end
            self:Print(label, "=", table.concat(parts, ", "))
        end
        show("RegionalUniqueNamesEnabled()", RegionalUniqueNamesEnabled)
        show("UnitNameUnmodified(player)", UnitNameUnmodified, "player")
        show("UnitFullName(player)", UnitFullName, "player")
        show("UnitName(player)", UnitName, "player")
        show("GetRealmName()", GetRealmName)
        show("GetNormalizedRealmName()", GetNormalizedRealmName)
        show("Player:GetFullName()", function() return ns.Player:GetFullName() end)
        show("Player:GetSurname()", function() return ns.Player:GetSurname() end)
    elseif cmd == "friends" then
        ns.Friends:PrintList()
    elseif cmd == "add" then
        if rest == "" then return self:Print(L.USAGE_ADD) end
        ns.Friends:AddManual(rest)
    elseif cmd == "remove" then
        if rest == "" then return self:Print(L.USAGE_REMOVE) end
        ns.Friends:RemoveManual(rest)
    elseif cmd == "share" then
        if arg ~= "on" and arg ~= "off" then return self:Print(L.USAGE_SHARE) end
        ns.Sync:SetShareBags(arg == "on")
    elseif cmd == "autosync" then
        if arg ~= "on" and arg ~= "off" then return self:Print(L.USAGE_AUTOSYNC) end
        ns.Sync:SetAutoSync(arg == "on")
    elseif cmd == "notify" then
        if arg ~= "on" and arg ~= "off" then return self:Print(L.USAGE_NOTIFY) end
        self.db.global.notifyLoot = arg == "on"
        self:Print(arg == "on" and L.NOTIFY_ON or L.NOTIFY_OFF)
    elseif cmd == "minimap" then
        ns.MinimapButton:Toggle()
    elseif cmd == "offermode" then
        if arg ~= "chat" and arg ~= "direct" then return self:Print(L.USAGE_OFFERMODE) end
        self.db.global.offerMode = arg == "direct" and "DIRECT" or "CHAT"
        self:Print(arg == "direct" and L.OFFERMODE_DIRECT or L.OFFERMODE_CHAT)
    elseif cmd == "offers" then
        if arg ~= "on" and arg ~= "off" then return self:Print(L.USAGE_OFFERS) end
        self.db.global.receiveOffers = arg == "on"
        self:Print(arg == "on" and L.RECEIVE_OFFERS_ON or L.RECEIVE_OFFERS_OFF)
        ns.Friends:SendHelloAll(true) -- avisa a los contactos del cambio
    elseif cmd == "template" then
        if rest == "" then
            self:Print(L.TEMPLATE_CURRENT:format(ns.Trade:GetTemplate()))
            self:Print(L.TEMPLATE_HELP)
        elseif arg == "reset" then
            self.db.global.offerTemplate = false
            self:Print(L.TEMPLATE_CURRENT:format(ns.Trade:GetTemplate()))
        else
            self.db.global.offerTemplate = rest
            self:Print(L.TEMPLATE_CURRENT:format(rest))
        end
    elseif cmd == "accepttemplate" then
        if rest == "" then
            self:Print(L.ACCEPT_TEMPLATE_CURRENT:format(ns.Trade:GetAcceptTemplate()))
            self:Print(L.ACCEPT_TEMPLATE_HELP)
        elseif arg == "reset" then
            self.db.global.acceptTemplate = false
            self:Print(L.ACCEPT_TEMPLATE_CURRENT:format(ns.Trade:GetAcceptTemplate()))
        else
            self.db.global.acceptTemplate = rest
            self:Print(L.ACCEPT_TEMPLATE_CURRENT:format(rest))
        end
    elseif cmd == "deliveries" then
        ns.Deliveries:PrintList()
    elseif cmd == "eval" then
        ns.Matches:PrintEvaluation()
    elseif cmd == "hello" then
        ns.Friends:SendHelloAll(true)
    elseif cmd == "ping" then
        if rest == "" then return self:Print(L.USAGE_PING) end
        ns.Friends:Ping(rest)
    elseif cmd == "debug" then
        self.db.global.debug = not self.db.global.debug
        self:Print(self.db.global.debug and L.DEBUG_ON or L.DEBUG_OFF)
    elseif cmd == "help" then
        for _, line in ipairs(L.HELP) do self:Print(line) end
    else
        self:Print(L.UNKNOWN_COMMAND:format(cmd))
        for _, line in ipairs(L.HELP) do self:Print(line) end
    end
end
