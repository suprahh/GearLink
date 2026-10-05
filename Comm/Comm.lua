-- GearLink - capa de red: codificación, envío (whisper de personaje y Battle.net), recepción, validación y despacho.
-- No sabe nada de amigos: pregunta a ns.Friends si un remitente es de confianza antes de despachar.
--
-- Formato en la red: LibSerialize -> LibDeflate:CompressDeflate -> EncodeForWoWAddonChannel.
-- Cada mensaje es una tabla { t = <tipo>, pv = <versión de protocolo>, ... }.
local _, ns = ...
local GearLink = ns.addon

local LibSerialize = LibStub("LibSerialize")
local LibDeflate = LibStub("LibDeflate")

local Comm = GearLink:NewModule("Comm", "AceComm-3.0", "AceEvent-3.0")
ns.Comm = Comm

Comm.PREFIX = "GearLink" -- máx. 16 caracteres
-- v2: Battle.net con mensajes en partes "id:i/n:" (fase 3).
Comm.PROTOCOL_VERSION = 2

-- Tipos de mensaje (clave corta por red)
Comm.T = {
    HELLO = "H",
    HELLO_ACK = "A",
    BYE = "B",
    PING = "P",
    PONG = "Q",
    REQ_HASH = "RH",
    HASH = "HS",
    REQ_SNAPSHOT = "RS",
    SNAPSHOT = "S",
    OFFER = "O",
    OFFER_REPLY = "OR",
    OFFER_TAKEN = "OT", -- "aceptaste tarde: ya se lo di a otro"
}

local MAX_RECEIVED_BYTES = 32000   -- se descarta todo lo más grande sin intentar decodificar
local BN_PART_DATA = 230           -- bytes de datos por parte (+ cabecera "id:i/n:" <= 255, límite de BNSendGameData)
local BN_MAX_PARTS = 120
local BN_REASSEMBLY_TIMEOUT = 60   -- s para recibir todas las partes de un mensaje
local LOCKDOWN_RETRY_DELAY = 1     -- segundos entre reintentos si el juego bloquea los mensajes
local LOCKDOWN_MAX_RETRIES = 60
local RATE_WINDOW, RATE_MAX = 10, 30 -- máx. mensajes aceptados por remitente cada 10 s

local handlers = {} -- tipo -> function(msg, contact, origin)

---------------------------------------------------------------------------
-- Codificación
---------------------------------------------------------------------------

function Comm.Encode(msg)
    local serialized = LibSerialize:Serialize(msg)
    local compressed = LibDeflate:CompressDeflate(serialized)
    return LibDeflate:EncodeForWoWAddonChannel(compressed)
end

-- Nunca lanza errores: devuelve nil si el texto no es un mensaje válido.
function Comm.Decode(text)
    if type(text) ~= "string" or #text == 0 or #text > MAX_RECEIVED_BYTES then return nil end
    local ok, result = pcall(function()
        local compressed = LibDeflate:DecodeForWoWAddonChannel(text)
        if not compressed then return nil end
        local serialized = LibDeflate:DecompressDeflate(compressed)
        if not serialized or #serialized > MAX_RECEIVED_BYTES * 8 then return nil end
        local success, msg = LibSerialize:Deserialize(serialized)
        if success and type(msg) == "table" then return msg end
    end)
    if ok then return result end
end

---------------------------------------------------------------------------
-- Envío
---------------------------------------------------------------------------

-- VERIFICAR EN FOREVER: /dump C_ChatInfo.InChatMessagingLockdown()  (true durante encuentros, mazmorras M+, etc.)
local function InMessagingLockdown()
    return C_ChatInfo.InChatMessagingLockdown ~= nil and C_ChatInfo.InChatMessagingLockdown() or false
end

local sendCounter = 0

-- Ejecuta fn cuando se pueda enviar: fuera de combate y sin bloqueo de mensajería.
local function WhenCanSend(fn, attempt)
    attempt = attempt or 0
    if InCombatLockdown() then
        if attempt == 0 then ns.Debug("Envío en espera: en combate") end
        sendCounter = sendCounter + 1
        ns.RunOutOfCombat("comm" .. sendCounter, function() WhenCanSend(fn, attempt) end)
    elseif InMessagingLockdown() then
        if attempt == 0 then ns.Debug("Envío en espera: el juego bloquea los mensajes de addon") end
        if attempt >= LOCKDOWN_MAX_RETRIES then
            ns.Debug("Mensaje descartado: mensajería bloqueada demasiado tiempo")
            return
        end
        C_Timer.After(LOCKDOWN_RETRY_DELAY, function() WhenCanSend(fn, attempt + 1) end)
    else
        fn()
    end
end

-- Nombres a los que les mandamos un whisper de addon hace poco (para silenciar "no hay ningún personaje llamado...").
-- Clave normalizada: el juego escribe el nombre con espacio ("Nadie Inventado") aunque enviemos con guion.
local recentWhisperTargets = {} -- "nombre-apellido" en minúsculas -> GetTime()

local function TargetKey(name)
    return ns.Friends.Key(ns.Friends.NormalizeName(name))
end

---------------------------------------------------------------------------
-- Battle.net: partes "id:i/n:datos". BNSendGameData no garantiza el orden, por eso cada parte lleva su índice.
---------------------------------------------------------------------------

local ID_CHARS = "0123456789abcdefghijklmnopqrstuvwxyz"
local function NewMessageID()
    local a, b, c = math.random(1, 36), math.random(1, 36), math.random(1, 36)
    return ID_CHARS:sub(a, a) .. ID_CHARS:sub(b, b) .. ID_CHARS:sub(c, c)
end

local function SplitForBN(text)
    local total = math.ceil(#text / BN_PART_DATA)
    if total > BN_MAX_PARTS then return nil end
    local id, parts = NewMessageID(), {}
    for i = 1, total do
        parts[i] = ("%s:%d/%d:"):format(id, i, total) .. text:sub((i - 1) * BN_PART_DATA + 1, i * BN_PART_DATA)
    end
    return parts
end

local bnBuffers = {} -- gameAccountID .. ":" .. id -> { total, count, parts = {}, started }

-- Devuelve el texto completo cuando llega la última parte; nil mientras falten.
local function ReassembleBN(gameAccountID, raw)
    local id, index, total, data = raw:match("^(%w+):(%d+)/(%d+):(.*)$")
    index, total = tonumber(index), tonumber(total)
    if not id or not index or not total or total < 1 or total > BN_MAX_PARTS or index < 1 or index > total then
        return nil
    end
    if total == 1 then return data end

    local now = GetTime()
    for key, buf in pairs(bnBuffers) do
        if now - buf.started > BN_REASSEMBLY_TIMEOUT then bnBuffers[key] = nil end
    end
    local key = gameAccountID .. ":" .. id
    local buf = bnBuffers[key]
    if not buf then
        buf = { total = total, count = 0, parts = {}, started = now }
        bnBuffers[key] = buf
    end
    if buf.total ~= total or buf.parts[index] then return nil end
    buf.parts[index] = data
    buf.count = buf.count + 1
    if buf.count < total then return nil end
    bnBuffers[key] = nil
    return table.concat(buf.parts)
end

-- target: { kind = "CHAR", name = "Nombre-Apellido" } | { kind = "BN", gameAccountID = 123 }
-- prio: "NORMAL" (por defecto) | "BULK" (snapshots grandes) | "ALERT"
function Comm:Send(target, msg, prio)
    prio = prio or "NORMAL"
    msg.pv = Comm.PROTOCOL_VERSION
    local queuedAt = GetTime()
    WhenCanSend(function()
        local waited = GetTime() - queuedAt
        if waited > 0.5 then ns.Debug(("%s esperó %.1f s antes de salir"):format(msg.t, waited)) end
        -- Hora de salida (GetTime): con los dos clientes en el mismo PC el receptor puede medir el viaje exacto.
        msg.st = GetTime()
        local text = Comm.Encode(msg)
        if target.kind == "BN" then
            local parts = SplitForBN(text)
            if not parts then
                ns.Debug(("BN: mensaje %s demasiado largo (%d bytes), no se envía"):format(msg.t, #text))
                return
            end
            ns.Debug(("-> BN %s  %s (%d bytes, %d partes)"):format(tostring(target.gameAccountID), msg.t, #text, #parts))
            for _, part in ipairs(parts) do
                ChatThrottleLib:BNSendGameData(prio, Comm.PREFIX, part, "WHISPER", target.gameAccountID)
            end
        else
            ns.Debug(("-> %s  %s (%d bytes, %s)"):format(target.name, msg.t, #text, prio))
            local key = TargetKey(target.name)
            if key then recentWhisperTargets[key] = GetTime() end
            -- El callback de AceComm avisa cuando ChatThrottleLib realmente entregó el último trozo al juego.
            local startedAt = GetTime()
            self:SendCommMessage(Comm.PREFIX, text, "WHISPER", target.name, prio, function(_, sent, total)
                if sent >= total then
                    local delay = GetTime() - startedAt
                    if delay > 0.5 then ns.Debug(("%s tardó %.1f s en la cola de envío"):format(msg.t, delay)) end
                end
            end)
        end
    end)
end

-- Envío inmediato sin cola (para BYE en el logout: la cola de ChatThrottleLib no alcanzaría a vaciarse).
function Comm:SendImmediate(target, msg)
    if InCombatLockdown() or InMessagingLockdown() then return end
    msg.pv = Comm.PROTOCOL_VERSION
    local text = Comm.Encode(msg)
    if target.kind == "BN" then
        local send = (C_BattleNet and C_BattleNet.SendGameData) or BNSendGameData
        local parts = SplitForBN(text)
        if send and parts and #parts == 1 then pcall(send, target.gameAccountID, Comm.PREFIX, parts[1]) end
    elseif #text <= 250 then
        pcall(C_ChatInfo.SendAddonMessage, Comm.PREFIX, text, "WHISPER", target.name)
    end
end

---------------------------------------------------------------------------
-- Recepción
---------------------------------------------------------------------------

function Comm:RegisterHandler(msgType, fn)
    handlers[msgType] = fn
end

local rate = {} -- origen -> { start, count }
local function RateLimited(originKey)
    local now = GetTime()
    local r = rate[originKey]
    if not r or now - r.start > RATE_WINDOW then
        rate[originKey] = { start = now, count = 1 }
        return false
    end
    r.count = r.count + 1
    return r.count > RATE_MAX
end

-- origin: { kind = "CHAR", name = <remitente tal cual>, } | { kind = "BN", gameAccountID = id }
function Comm:Dispatch(text, origin)
    local originKey = origin.kind == "BN" and ("bn:" .. tostring(origin.gameAccountID)) or ("c:" .. tostring(origin.name))
    if RateLimited(originKey) then return end

    local msg = Comm.Decode(text)
    if not msg or type(msg.t) ~= "string" or type(msg.pv) ~= "number" then
        ns.Debug("Mensaje malformado de", originKey)
        return
    end
    local handler = handlers[msg.t]
    if not handler then
        ns.Debug("Tipo de mensaje desconocido:", msg.t, "de", originKey)
        return
    end
    local contact = ns.Friends:ResolveOrigin(origin)
    if not contact then
        ns.Debug("Ignorado (no es contacto):", originKey, msg.t)
        return
    end
    local travel = type(msg.st) == "number" and GetTime() - msg.st or nil
    -- Solo tiene sentido con ambos clientes en el mismo PC (mismo reloj); con otro PC sale cualquier número.
    if travel and travel >= 0 and travel < 600 then
        ns.Debug(("<- %s  %s  (viaje %.1f s si ambos clientes están en este PC)"):format(originKey, msg.t, travel))
    else
        ns.Debug(("<- %s  %s"):format(originKey, msg.t))
    end
    xpcall(handler, geterrorhandler(), msg, contact, origin)
end

function Comm:OnCommReceived(prefix, text, distribution, sender)
    if prefix ~= Comm.PREFIX or distribution ~= "WHISPER" or type(sender) ~= "string" or ns.IsSecret(sender) then return end
    self:Dispatch(text, { kind = "CHAR", name = sender })
end

-- VERIFICAR EN FOREVER: argumentos de BN_CHAT_MSG_ADDON (prefix, text, channel, senderID = gameAccountID)
function Comm:BN_CHAT_MSG_ADDON(_, prefix, text, _, senderID)
    if prefix ~= Comm.PREFIX or type(senderID) ~= "number" or type(text) ~= "string" then return end
    local full = ReassembleBN(senderID, text)
    if full then self:Dispatch(full, { kind = "BN", gameAccountID = senderID }) end
end

---------------------------------------------------------------------------
-- Silenciar "No hay ningún personaje llamado '%s' conectado." para nuestros whispers de addon
---------------------------------------------------------------------------

local NOT_FOUND_PATTERN = ns.FormatToPattern(ERR_CHAT_PLAYER_NOT_FOUND_S, true)

local function SystemMessageFilter(_, _, message)
    if not NOT_FOUND_PATTERN or type(message) ~= "string" or ns.IsSecret(message) then return false end
    local name = message:match(NOT_FOUND_PATTERN)
    if not name then return false end
    local key = TargetKey(name)
    local sentAt = key and recentWhisperTargets[key]
    if sentAt and GetTime() - sentAt < 10 then
        ns.Friends:MarkOffline(name)
        return true
    end
    ns.Debug("Aviso 'no encontrado' sin envío reciente:", name, "clave", tostring(key))
    return false
end

function Comm:OnEnable()
    self:RegisterComm(Comm.PREFIX, "OnCommReceived")
    ns.SafeRegisterEvent(self, "BN_CHAT_MSG_ADDON")

    -- VERIFICAR EN FOREVER: en 12.x el filtro puede vivir en ChatFrameUtil -> /dump ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter
    local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
    if addFilter then
        addFilter("CHAT_MSG_SYSTEM", SystemMessageFilter)
        ns.Debug("Filtro de chat registrado. Patrón:", tostring(NOT_FOUND_PATTERN))
    else
        ns.Debug("No hay API de filtro de chat: los avisos de 'personaje no conectado' se verán")
    end
end
