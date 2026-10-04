-- GearLink - ofertas de items por whisper (fase 5).
--
-- Solo se ofrece como respuesta a un click del usuario (nunca whispers automáticos).
-- Modos (db.global.offerMode):
--   CHAT   - abre el chat de whisper con el mensaje escrito (el usuario lo envía con Enter).
--   DIRECT - envía el whisper al instante.
-- En ambos modos el OFFER por addon sale en el momento del click (con prioridad alta): así el popup del amigo no
-- depende de que el servidor confirme el whisper, que en la beta puede tardar.
-- Anti-spam: el mismo item al mismo amigo, como mucho una vez cada db.global.offerCooldown minutos.
-- Uno a la vez: cada item tiene como mucho UNA oferta abierta. Se libera si el amigo rechaza o si pasa el tiempo de
-- espera; si acepta, el item queda reservado (Deliveries).
local _, ns = ...
local L = ns.L
local GearLink = ns.addon
local Comm = ns.Comm
local T = Comm.T
local Snapshot = ns.Snapshot

local Trade = GearLink:NewModule("Trade", "AceEvent-3.0")
ns.Trade = Trade

local POPUP_THROTTLE = 30 -- s mínimo entre popups del mismo amigo
local INTERACTIVE_PRIO = "ALERT" -- ofertas y respuestas pasan antes que saludos y snapshots en la cola

local lastPopup = {} -- clave del contacto -> GetTime()

local SendChat = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage

---------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------

local function CooldownKey(friendKey, link)
    return friendKey .. "|" .. (Snapshot.ToItemString(link) or link)
end

-- Segundos que faltan para poder volver a ofrecer (nil si ya se puede).
function Trade:CooldownLeft(friendKey, link)
    local at = GearLink.db.char.offers[CooldownKey(friendKey, link)]
    if not at then return nil end
    local left = at + (GearLink.db.global.offerCooldown or 10) * 60 - time()
    return left > 0 and left or nil
end

-- Oferta abierta (sin respuesta y dentro del tiempo de espera) para este item, o nil.
function Trade:GetOpenOffer(link)
    local itemKey = Snapshot.ToItemString(link) or link
    local open = GearLink.db.char.openOffers[itemKey]
    if not open then return nil end
    if open.at + (GearLink.db.global.offerCooldown or 10) * 60 <= time() then
        GearLink.db.char.openOffers[itemKey] = nil -- venció sin respuesta: se libera
        return nil
    end
    return open
end

local function CloseOpenOffer(itemKey, friendKey)
    local open = GearLink.db.char.openOffers[itemKey]
    if open and (not friendKey or open.key == friendKey) then GearLink.db.char.openOffers[itemKey] = nil end
end

function Trade:GetTemplate()
    return GearLink.db.global.offerTemplate or L.OFFER_TEMPLATE_DEFAULT
end

function Trade:GetAcceptTemplate()
    return GearLink.db.global.acceptTemplate or L.ACCEPT_TEMPLATE_DEFAULT
end

-- Reemplazo literal (sin patrones): el link del item puede contener caracteres especiales.
local function Replace(text, token, value)
    local s, e = text:find(token, 1, true)
    while s do
        text = text:sub(1, s - 1) .. value .. text:sub(e + 1)
        s, e = text:find(token, s + #value, true)
    end
    return text
end

function Trade:BuildMessage(link, match)
    local text = self:GetTemplate()
    text = Replace(text, "%item%", link)
    text = Replace(text, "%reason%", match.reason or "")
    text = Replace(text, "%slot%", match.slot and ns.Upgrade.SlotName(match.slot) or "")
    text = Replace(text, "%name%", match.name or "")
    return text
end

-- Nombre al que se le escribe: "Nombre-Apellido".
local function WhisperName(c)
    local view = ns.Friends:GetView(c)
    local name = ns.Friends.NormalizeName(view.name)
    if name and name:find("-", 1, true) then return name end
    return name or ns.Friends.NormalizeName(c.bnCharName)
end

-- VERIFICAR EN FOREVER: ChatFrameUtil.SendTell (12.x) / ChatFrame_SendTell (antes) -> /dump ChatFrameUtil.SendTell
-- SendTell escribe "/w Nombre " y el juego lo convierte en modo whisper en el cuadro siguiente, vaciando el texto.
-- Por eso el mensaje se inserta un instante después (si se inserta enseguida, a veces se borra).
local INSERT_DELAY = 0.05

local function OpenWhisperWithText(name, text)
    local sendTell = (ChatFrameUtil and ChatFrameUtil.SendTell) or ChatFrame_SendTell
    local getActive = (ChatFrameUtil and ChatFrameUtil.GetActiveWindow) or ChatEdit_GetActiveWindow
    if not (sendTell and getActive) then return false end
    sendTell(name)
    C_Timer.After(INSERT_DELAY, function()
        local editBox = getActive()
        if not editBox then return end
        local current = editBox:GetText() or ""
        if not current:find(text, 1, true) then editBox:Insert(text) end
    end)
    return true
end

-- Envía (o deja escrito) un whisper según el modo configurado. Devuelve "SENT", "OPENED" o nil si falló.
function Trade:Whisper(name, text)
    if GearLink.db.global.offerMode == "DIRECT" then
        SendChat(text, "WHISPER", nil, name)
        return "SENT"
    end
    if OpenWhisperWithText(name, text) then return "OPENED" end
    -- Sin API para abrir el chat: se envía directo para no perder la acción del usuario.
    SendChat(text, "WHISPER", nil, name)
    return "SENT"
end

---------------------------------------------------------------------------
-- Ofrecer (llamado desde el click en el indicador 🎁)
---------------------------------------------------------------------------

local function FinalizeOffer(c, link, match)
    GearLink.db.char.offers[CooldownKey(c.key, link)] = time()
    GearLink.db.char.openOffers[Snapshot.ToItemString(link) or link] = {
        key = c.key, display = ns.Friends:GetView(c).displayName, at = time(),
    }
    local target = ns.Friends:GetTarget(c)
    if target and c.hasAddonSession then
        Comm:Send(target, { t = T.OFFER, i = Snapshot.ToItemString(link), r = match.reason, sl = match.slot }, INTERACTIVE_PRIO)
    end
    GearLink:SendMessage(ns.MSG_MATCHES_UPDATED) -- refresca el tooltip del indicador (cooldown)
end

function Trade:Offer(link, match)
    local c = ns.Friends:GetContact(match.key)
    if not c then return end
    local view = ns.Friends:GetView(c)
    if not view.receiveOffers then
        return GearLink:Print(L.OFFER_DISABLED_BY_FRIEND:format(view.displayName))
    end
    local open = self:GetOpenOffer(link)
    if open and open.key ~= c.key then
        local left = open.at + (GearLink.db.global.offerCooldown or 10) * 60 - time()
        return GearLink:Print(L.OFFER_ONE_AT_A_TIME:format(open.display, math.ceil(left / 60)))
    end
    local left = self:CooldownLeft(c.key, link)
    if left then
        return GearLink:Print(L.OFFER_COOLDOWN:format(view.displayName, math.ceil(left / 60)))
    end
    local name = WhisperName(c)
    if not name then return GearLink:Print(L.OFFER_NO_NAME:format(view.displayName)) end

    -- Primero la oferta por addon (llega rápido), después el whisper.
    FinalizeOffer(c, link, match)
    local result = self:Whisper(name, self:BuildMessage(link, match))
    GearLink:Print((result == "SENT" and L.OFFER_SENT or L.OFFER_CHAT_OPENED):format(view.displayName))
end

---------------------------------------------------------------------------
-- Recibir ofertas
---------------------------------------------------------------------------

local function ValidItemString(s)
    return type(s) == "string" and #s <= 250 and s:match("^item:[%d:%-]+$") ~= nil
end

local function OnOffer(msg, c)
    if not GearLink.db.global.receiveOffers then return end
    if not ValidItemString(msg.i) then return end
    local slot = tonumber(msg.sl)
    if slot and (slot < INVSLOT_FIRST_EQUIPPED or slot > INVSLOT_LAST_EQUIPPED or slot % 1 ~= 0) then slot = nil end
    local reason = type(msg.r) == "string" and #msg.r <= 120 and msg.r or ""

    local now = GetTime()
    if lastPopup[c.key] and now - lastPopup[c.key] < POPUP_THROTTLE then return end
    lastPopup[c.key] = now

    local view = ns.Friends:GetView(c)
    ns.OfferPopup:Show({
        key = c.key, from = view.displayName, fromName = WhisperName(c),
        item = msg.i, reason = reason, slot = slot,
    })
end

local function OnOfferReply(msg, c)
    local view = ns.Friends:GetView(c)
    local itemKey = ValidItemString(msg.i) and msg.i or nil
    if itemKey then CloseOpenOffer(itemKey, c.key) end

    if msg.a == true then
        -- Aceptó tarde y el item ya está reservado para otra persona: se le avisa y no se crea otra entrega.
        local reserved = itemKey and ns.Deliveries:GetReservation(itemKey)
        if reserved and reserved.key ~= c.key then
            GearLink:Print(L.OFFER_ACCEPTED_LATE:format(view.displayName, reserved.display))
            local target = ns.Friends:GetTarget(c)
            if target then Comm:Send(target, { t = T.OFFER_TAKEN, i = itemKey }, INTERACTIVE_PRIO) end
            return
        end
        local zone = type(msg.z) == "string" and #msg.z <= 80 and msg.z or "?"
        GearLink:Print(L.OFFER_ACCEPTED:format(view.displayName, zone))
        -- Queda como entrega pendiente: se recuerda (y se prepara el correo) al abrir el buzón.
        if itemKey then ns.Deliveries:Add(c, itemKey) end
        local sound = SOUNDKIT and SOUNDKIT.TELL_MESSAGE
        if sound then PlaySound(sound) end
    else
        GearLink:Print(L.OFFER_DECLINED:format(view.displayName))
    end
    GearLink:SendMessage(ns.MSG_MATCHES_UPDATED) -- el 🎁 vuelve a permitir ofrecerlo a otros
end

local function OnOfferTaken(_, c)
    GearLink:Print(L.OFFER_TAKEN:format(ns.Friends:GetView(c).displayName))
end

-- Respuesta desde el popup (click del usuario).
function Trade:Reply(offer, accepted)
    local c = ns.Friends:GetContact(offer.key)
    local target = c and ns.Friends:GetTarget(c)
    if accepted then
        local zone = GetZoneText() or ""
        local sub = GetSubZoneText()
        if sub and sub ~= "" and sub ~= zone then zone = zone .. " - " .. sub end
        if offer.fromName then
            -- Link completo del item (el popup ya lo cargó); si no, su nombre.
            local name, fullLink = C_Item.GetItemInfo(offer.item)
            local text = self:GetAcceptTemplate()
            text = Replace(text, "%item%", fullLink or name or L.THE_ITEM)
            text = Replace(text, "%zone%", zone)
            text = Replace(text, "%reason%", offer.reason or "")
            self:Whisper(offer.fromName, text)
        end
        if target then Comm:Send(target, { t = T.OFFER_REPLY, a = true, z = zone, i = offer.item }, INTERACTIVE_PRIO) end
    elseif target then
        Comm:Send(target, { t = T.OFFER_REPLY, a = false, i = offer.item }, INTERACTIVE_PRIO)
    end
end

function Trade:OnEnable()
    Comm:RegisterHandler(T.OFFER, OnOffer)
    Comm:RegisterHandler(T.OFFER_REPLY, OnOfferReply)
    Comm:RegisterHandler(T.OFFER_TAKEN, OnOfferTaken)
end
