-- GearLink - intercambio de snapshots entre contactos (fase 3). Siempre bajo demanda (click en un contacto).
--
-- Flujo:  REQ_HASH -> HASH  ->  (hash igual a la caché)  : "Al día", no se pide nada más
--                               (hash distinto o sin caché): REQ_SNAPSHOT -> SNAPSHOT -> validar -> caché
-- La caché vive en db.global.friendSnapshots (nivel de cuenta) y se muestra aunque el amigo se desconecte.
local _, ns = ...
local L = ns.L
local GearLink = ns.addon
local Comm = ns.Comm
local T = Comm.T
local Snapshot = ns.Snapshot

local Sync = GearLink:NewModule("Sync", "AceEvent-3.0")
ns.Sync = Sync

local REQUEST_TIMEOUT = 60     -- s esperando cada respuesta (el servidor de la beta puede tardar ~30 s en entregar)
local LATE_ACCEPT_WINDOW = 180 -- s durante los que se acepta un SNAPSHOT pedido aunque ya se haya dado por perdido
local SERVE_THROTTLE = 3       -- s mínimo entre snapshots completos al mismo contacto
local AUTO_SYNC_INTERVAL = 10  -- s entre pedidos automáticos (uno por vez)

Sync.STATE = {
    REQUESTING = "REQUESTING",
    UP_TO_DATE = "UP_TO_DATE",
    UPDATED = "UPDATED",
    OFFLINE = "OFFLINE",
    NO_DATA = "NO_DATA",
    TIMEOUT = "TIMEOUT",
    INVALID = "INVALID",
}
local S = Sync.STATE

local states = {}     -- clave -> { state, at }
local pending = {}    -- clave -> { stage = "HASH"|"SNAPSHOT", timer }
local lastServed = {} -- clave -> GetTime()
local lastRequested = {} -- clave -> GetTime() del último REQ_SNAPSHOT enviado

---------------------------------------------------------------------------
-- Lo que comparto yo
---------------------------------------------------------------------------

function Sync:ShareBags()
    return GearLink.db.char.shareBags ~= false
end

function Sync:SetShareBags(enabled)
    GearLink.db.char.shareBags = enabled and true or false
    GearLink:Print(enabled and L.SHARE_ON or L.SHARE_OFF)
    -- Repinta "Mi equipo" (casilla) sin reescanear.
    GearLink:SendMessage(ns.MSG_SNAPSHOT_UPDATED, ns.Scanner:GetSnapshot(), false)
end

-- Hash de lo que comparto (cambia si activo/desactivo compartir bolsas).
function Sync:GetPublicHash()
    local snap = ns.Scanner:GetSnapshot()
    return snap and Snapshot.PublicHash(snap, self:ShareBags()) or nil
end

---------------------------------------------------------------------------
-- Estado y caché de amigos
---------------------------------------------------------------------------

function Sync:GetCached(key)
    return GearLink.db.global.friendSnapshots[key]
end

function Sync:GetState(key)
    return states[key]
end

local function SetState(key, state)
    states[key] = { state = state, at = time() }
    GearLink:SendMessage(ns.MSG_FRIEND_SNAPSHOT, key)
end

local function ClearPending(key)
    local p = pending[key]
    if p and p.timer then p.timer:Cancel() end
    pending[key] = nil
end

local function StartPending(key, stage)
    ClearPending(key)
    local p = { stage = stage }
    p.timer = C_Timer.NewTimer(REQUEST_TIMEOUT, function()
        if pending[key] == p then
            pending[key] = nil
            SetState(key, S.TIMEOUT)
        end
    end)
    pending[key] = p
end

-- Pide (si hace falta) el snapshot de un contacto. Lo cacheado se muestra mientras tanto.
function Sync:Request(key)
    local c = ns.Friends:GetContact(key)
    local target = c and ns.Friends:GetTarget(c)
    if not (c and target and c.hasAddonSession) then
        ClearPending(key)
        SetState(key, self:GetCached(key) and S.OFFLINE or S.NO_DATA)
        return
    end
    StartPending(key, "HASH")
    SetState(key, S.REQUESTING)
    Comm:Send(target, { t = T.REQ_HASH })
end

local function Reply(c, msg, prio)
    local target = ns.Friends:GetTarget(c)
    if target then Comm:Send(target, msg, prio) end
    if msg.t == T.REQ_SNAPSHOT then lastRequested[c.key] = GetTime() end
end

---------------------------------------------------------------------------
-- Sincronización automática suave (fase 4): cuando un contacto saluda con un hash distinto al de la caché, se pide
-- su snapshot. Uno por vez, cada AUTO_SYNC_INTERVAL s. Así "Le sirve a" funciona sin abrir cada ficha.
---------------------------------------------------------------------------

local autoQueue, autoQueued, autoTicker = {}, {}, nil

local function ProcessAutoQueue()
    local key = table.remove(autoQueue, 1)
    if not key then
        if autoTicker then autoTicker:Cancel() end
        autoTicker = nil
        return
    end
    autoQueued[key] = nil
    local c = ns.Friends:GetContact(key)
    if c and c.hasAddonSession and not pending[key] then
        ns.Debug("Auto-sync:", key)
        StartPending(key, "SNAPSHOT")
        SetState(key, S.REQUESTING)
        Reply(c, { t = T.REQ_SNAPSHOT })
    end
end

-- Llamado por Friends al recibir HELLO/HELLO_ACK.
function Sync:MaybeAutoSync(c, hash)
    if not GearLink.db.global.autoSync then return end
    if not c.hasAddonSession or pending[c.key] or autoQueued[c.key] then return end
    local cached = self:GetCached(c.key)
    if cached and hash and cached.hash == hash then return end
    autoQueued[c.key] = true
    autoQueue[#autoQueue + 1] = c.key
    if not autoTicker then
        autoTicker = C_Timer.NewTicker(AUTO_SYNC_INTERVAL, ProcessAutoQueue)
    end
end

function Sync:SetAutoSync(enabled)
    GearLink.db.global.autoSync = enabled and true or false
    GearLink:Print(enabled and L.AUTOSYNC_ON or L.AUTOSYNC_OFF)
end

---------------------------------------------------------------------------
-- Handlers
---------------------------------------------------------------------------

local function OnReqHash(_, c)
    Reply(c, { t = T.HASH, h = Sync:GetPublicHash() })
end

local function OnHash(msg, c)
    local p = pending[c.key]
    if not p or p.stage ~= "HASH" then return end -- respuesta que no pedimos
    local cached = Sync:GetCached(c.key)
    local hash = type(msg.h) == "string" and #msg.h <= 16 and msg.h or nil
    if cached and hash and cached.hash == hash then
        ClearPending(c.key)
        cached.checkedAt = time()
        SetState(c.key, S.UP_TO_DATE)
        return
    end
    StartPending(c.key, "SNAPSHOT")
    Reply(c, { t = T.REQ_SNAPSHOT })
end

local function OnReqSnapshot(_, c)
    local now = GetTime()
    if lastServed[c.key] and now - lastServed[c.key] < SERVE_THROTTLE then
        ns.Debug("REQ_SNAPSHOT ignorado (demasiado seguido):", c.key)
        return
    end
    local snap = ns.Scanner:GetSnapshot()
    if not snap then return end
    lastServed[c.key] = now
    local msg = Snapshot.ToNetwork(snap, Sync:ShareBags())
    msg.t = T.SNAPSHOT
    Reply(c, msg, "BULK")
end

local function OnSnapshot(msg, c)
    -- Solo se guarda lo que pedimos. Si la espera ya venció pero lo pedimos hace poco, igual se acepta
    -- (con la demora del servidor, la respuesta puede llegar después del tiempo límite).
    local requestedAt = lastRequested[c.key]
    if not pending[c.key] and not (requestedAt and GetTime() - requestedAt < LATE_ACCEPT_WINDOW) then return end
    ClearPending(c.key)
    lastRequested[c.key] = nil
    local snap, reason = Snapshot.FromNetwork(msg)
    if not snap then
        ns.Debug("SNAPSHOT inválido de", c.key, reason)
        SetState(c.key, S.INVALID)
        return
    end
    snap.checkedAt = snap.receivedAt
    GearLink.db.global.friendSnapshots[c.key] = snap
    SetState(c.key, S.UPDATED)
end

function Sync:OnEnable()
    Comm:RegisterHandler(T.REQ_HASH, OnReqHash)
    Comm:RegisterHandler(T.HASH, OnHash)
    Comm:RegisterHandler(T.REQ_SNAPSHOT, OnReqSnapshot)
    Comm:RegisterHandler(T.SNAPSHOT, OnSnapshot)
end
