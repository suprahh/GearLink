-- GearLink - entregas pendientes: items que un amigo aceptó y que hay que mandarle por correo.
--
-- Al abrir el buzón aparece un panel propio (anclado al lado del buzón, sin modificar el frame de Blizzard) con un
-- botón "Preparar envío": pasa a la pestaña Enviar, completa destinatario y asunto y adjunta el item. El usuario
-- presiona Enviar; con MAIL_SEND_SUCCESS la entrega se da por hecha.
-- Los items ligados con ventana de intercambio no se pueden enviar por correo: solo intercambio directo.
local _, ns = ...
local L = ns.L
local GearLink = ns.addon
local Snapshot = ns.Snapshot

local Deliveries = GearLink:NewModule("Deliveries", "AceEvent-3.0")
ns.Deliveries = Deliveries

local ROW_HEIGHT = 44
local PANEL_WIDTH = 280

local function Store()
    return GearLink.db.char.deliveries
end

---------------------------------------------------------------------------
-- Datos
---------------------------------------------------------------------------

function Deliveries:Add(c, itemString)
    local view = ns.Friends:GetView(c)
    local to = ns.Friends.NormalizeName(view.name)
    local id = c.key .. "|" .. itemString
    Store()[id] = { key = c.key, to = to, display = view.displayName, item = itemString, at = time() }
    GearLink:Print(L.DELIVERY_ADDED:format(view.displayName))
    GearLink:SendMessage(ns.MSG_MATCHES_UPDATED)
    ns.Matches:RequestRun()
end

function Deliveries:Remove(id)
    Store()[id] = nil
    ns.Matches:RequestRun()
    self:RefreshPanel()
end

-- Entrega pendiente para este item (si la hay): el item queda reservado para ese amigo.
function Deliveries:GetReservation(itemString)
    for _, d in pairs(Store()) do
        if d.item == itemString then return d end
    end
end

-- Dónde está el item en mis bolsas (según el último escaneo).
function Deliveries:FindInBags(itemString)
    local snap = ns.Scanner:GetSnapshot()
    for _, item in ipairs(snap and snap.bags or {}) do
        if Snapshot.ToItemString(item.link) == itemString then return item end
    end
end

-- Entregas pendientes, de la más antigua a la más nueva: { { id, d }, ... }
function Deliveries:GetPending()
    local list = {}
    for id, d in pairs(Store()) do list[#list + 1] = { id = id, d = d } end
    table.sort(list, function(a, b) return a.d.at < b.d.at end)
    return list
end

local LOG_MAX = 30

-- Historial para la pestaña Entregas: status = "SENT" (enviado por correo) o "DECLINED" (el amigo rechazó).
function Deliveries:Log(item, display, status)
    local log = GearLink.db.char.deliveryLog
    table.insert(log, 1, { item = item, display = display, status = status, at = time() })
    for i = #log, LOG_MAX + 1, -1 do log[i] = nil end
end

function Deliveries:GetLog()
    return GearLink.db.char.deliveryLog
end

function Deliveries:ClearLog()
    wipe(GearLink.db.char.deliveryLog)
    GearLink:SendMessage(ns.MSG_MATCHES_UPDATED)
end

---------------------------------------------------------------------------
-- Preparar el correo
---------------------------------------------------------------------------

local MAX_ATTACHMENTS = ATTACHMENTS_MAX_SEND or 12
local LAST_BAG = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4

local function SendTabShown()
    return SendMailFrame and SendMailFrame:IsShown()
end

-- Pestaña "Enviar". Si el botón de la pestaña no existe o no cambia nada, se usa la función de Blizzard.
local function ShowSendTab()
    if SendTabShown() then return end
    if MailFrameTab2 then MailFrameTab2:Click() end
    if not SendTabShown() and MailFrameTab_OnClick then MailFrameTab_OnClick(nil, 2) end
end

-- Bolsa y slot actuales del item. El snapshot puede estar desfasado (el escaneo tiene debounce): se mira la bolsa en vivo.
local function FindLiveSlot(itemString, hint)
    local function Matches(bag, slot)
        local info = C_Container.GetContainerItemInfo(bag, slot)
        local link = info and not info.isLocked and info.hyperlink
        return link and not ns.IsSecret(link) and Snapshot.ToItemString(link) == itemString
    end
    if hint and Matches(hint.bag, hint.slot) then return hint.bag, hint.slot end
    for bag = BACKPACK_CONTAINER or 0, LAST_BAG do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            if Matches(bag, slot) then return bag, slot end
        end
    end
end

local function AttachedIndex(itemString)
    if not GetSendMailItemLink then return nil end
    for i = 1, MAX_ATTACHMENTS do
        local link = GetSendMailItemLink(i)
        if link and not ns.IsSecret(link) and Snapshot.ToItemString(link) == itemString then return i end
    end
end

-- Entregas cuyo item va adjunto en el correo que se está armando. Un mismo correo puede llevar varias.
local function AttachedDeliveries()
    local list = {}
    for id, d in pairs(Store()) do
        if AttachedIndex(d.item) then list[#list + 1] = id end
    end
    return list
end

local function FreeAttachmentIndex()
    for i = 1, MAX_ATTACHMENTS do
        if not (HasSendMailItem and HasSendMailItem(i)) then return i end
    end
end

-- Toma el item de la bolsa y lo suelta en el primer adjunto libre.
local function Attach(itemString, hint)
    if AttachedIndex(itemString) then return end
    local bag, slot = FindLiveSlot(itemString, hint)
    local index = FreeAttachmentIndex()
    if not (bag and index) then return end
    ClearCursor()
    C_Container.PickupContainerItem(bag, slot)
    if ClickSendMailItemButton and CursorHasItem() then
        ClickSendMailItemButton(index)
    else
        ClearCursor()
        C_Container.UseContainerItem(bag, slot) -- con la pestaña Enviar abierta, usar el item lo adjunta
    end
    if CursorHasItem() then ClearCursor() end
end

local function FillFields(d)
    SendMailNameEditBox:SetText(d.to or "")
    local name = C_Item.GetItemInfo(d.item)
    SendMailSubjectEditBox:SetText(L.MAIL_SUBJECT:format(name or L.THE_ITEM))
end

-- VERIFICAR EN FOREVER: MailFrameTab2, SendMailNameEditBox, SendMailSubjectEditBox, ClickSendMailItemButton
function Deliveries:Prepare(id)
    local d = Store()[id]
    if not d then return end
    local item = self:FindInBags(d.item)
    if not item then return GearLink:Print(L.DELIVERY_NOT_IN_BAGS) end
    if item.bind == "TRADE_WINDOW" or item.bind == "SOULBOUND" then return GearLink:Print(L.DELIVERY_TRADE_ONLY) end
    if not (SendMailNameEditBox and SendMailSubjectEditBox) then return GearLink:Print(L.DELIVERY_NO_MAIL_API) end

    ShowSendTab()
    ns.Debug("preparar envío: pestaña Enviar visible =", tostring(SendTabShown()))
    if not SendTabShown() then return GearLink:Print(L.DELIVERY_NO_MAIL_API) end

    -- Varias entregas al mismo amigo pueden ir en un solo correo, pero no mezclar destinatarios.
    for _, otherId in ipairs(AttachedDeliveries()) do
        local other = Store()[otherId]
        if ns.Friends.Key(other.to) ~= ns.Friends.Key(d.to) then
            return GearLink:Print(L.DELIVERY_OTHER_RECIPIENT:format(other.display))
        end
    end

    -- Se adjunta antes de escribir el asunto: al adjuntar, el juego puede poner el nombre del item como asunto.
    Attach(d.item, item)
    FillFields(d)
    self.preparing = id

    -- El adjunto se confirma en el frame siguiente; si algo vació los campos al cambiar de pestaña, se vuelven a escribir.
    C_Timer.After(0.2, function()
        if self.preparing ~= id or not SendTabShown() then return end
        if SendMailNameEditBox:GetText() == "" then FillFields(d) end
        local attached = AttachedIndex(d.item) ~= nil
        ns.Debug("preparar envío: adjunto =", tostring(attached), "destinatario =", SendMailNameEditBox:GetText())
        if attached then
            GearLink:Print(L.DELIVERY_READY:format(d.display))
        else
            GearLink:Print(L.DELIVERY_ATTACH_FAILED:format(d.display))
        end
    end)
end

-- Al pulsar Enviar se fija qué entregas van en el correo (al confirmarse el envío los adjuntos ya se vaciaron).
function Deliveries:OnSendMail()
    self.sending = AttachedDeliveries()
end

function Deliveries:MAIL_SEND_SUCCESS()
    local ids = (self.sending and #self.sending > 0) and self.sending or { self.preparing }
    self.sending, self.preparing = nil, nil
    local any = false
    for _, id in ipairs(ids) do
        local d = Store()[id]
        if d then
            GearLink:Print(L.DELIVERY_DONE:format(d.display))
            self:Log(d.item, d.display, "SENT")
            Store()[id] = nil
            any = true
        end
    end
    if any then
        ns.Matches:RequestRun()
        self:RefreshPanel()
    end
end

function Deliveries:MAIL_FAILED()
    self.sending = nil
end

---------------------------------------------------------------------------
-- Panel junto al buzón
---------------------------------------------------------------------------

local function CreateRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(PANEL_WIDTH - 20, ROW_HEIGHT)

    row.iconButton = CreateFrame("Button", nil, row)
    row.iconButton:SetSize(32, 32)
    row.iconButton:SetPoint("LEFT", 0, 0)
    row.icon = row.iconButton:CreateTexture(nil, "ARTWORK")
    row.icon:SetAllPoints()
    row.iconButton:SetScript("OnEnter", function(self)
        if not row.delivery then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(row.delivery.item)
        GameTooltip:Show()
    end)
    row.iconButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("TOPLEFT", row.iconButton, "TOPRIGHT", 6, -1)
    row.name:SetPoint("RIGHT", -20, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.to = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.to:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
    row.to:SetJustifyH("LEFT")

    row.prepare = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.prepare:SetSize(110, 20)
    row.prepare:SetPoint("BOTTOMRIGHT", -20, 0)
    row.prepare:SetText(L.BTN_PREPARE_MAIL)
    row.prepare:SetScript("OnClick", function() if row.id then Deliveries:Prepare(row.id) end end)

    row.note = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.note:SetPoint("BOTTOMRIGHT", -20, 4)

    row.remove = CreateFrame("Button", nil, row)
    row.remove:SetSize(14, 14)
    row.remove:SetPoint("TOPRIGHT", 0, -2)
    row.remove:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
    row.remove:SetHighlightTexture("Interface\\Buttons\\UI-StopButton", "ADD")
    row.remove:SetScript("OnClick", function() if row.id then Deliveries:Remove(row.id) end end)
    row.remove:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L.DELIVERY_REMOVE)
        GameTooltip:Show()
    end)
    row.remove:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

local function CreatePanel()
    local f = CreateFrame("Frame", nil, MailFrame or UIParent, "BackdropTemplate")
    f:SetWidth(PANEL_WIDTH)
    if MailFrame then
        f:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", 4, 0)
    else
        f:SetPoint("CENTER")
    end
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    local solid = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    solid:SetPoint("TOPLEFT", 6, -6)
    solid:SetPoint("BOTTOMRIGHT", -6, 6)
    solid:SetColorTexture(0.05, 0.05, 0.05, 1)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 14, -14)
    f.title:SetText(L.DELIVERY_PANEL_TITLE)
    f.rows = {}
    f:Hide()
    return f
end

function Deliveries:RefreshPanel()
    local f = self.panel
    if not f or not (MailFrame and MailFrame:IsShown()) then return end
    local list = self:GetPending()
    if #list == 0 then return f:Hide() end

    for i, entry in ipairs(list) do
        local row = f.rows[i]
        if not row then
            row = CreateRow(f)
            row:SetPoint("TOPLEFT", 14, -36 - (i - 1) * ROW_HEIGHT)
            f.rows[i] = row
        end
        local d = entry.d
        row.id, row.delivery = entry.id, d
        row.icon:SetTexture(select(5, C_Item.GetItemInfoInstant(d.item)) or 134400)
        row.name:SetText((select(2, C_Item.GetItemInfo(d.item))) or L.LOADING)
        row.to:SetText(L.DELIVERY_FOR:format(d.display))

        local item = self:FindInBags(d.item)
        local note
        if not item then
            note = L.DELIVERY_NOTE_MISSING
        elseif item.bind == "TRADE_WINDOW" or item.bind == "SOULBOUND" then
            note = L.DELIVERY_NOTE_TRADE
        end
        row.prepare:SetShown(note == nil)
        row.note:SetText(note or "")
        row:Show()
    end
    for i = #list + 1, #f.rows do f.rows[i]:Hide() end
    f:SetHeight(48 + #list * ROW_HEIGHT)
    f:Show()
end

-- MailFrame se muestra en su propio manejador de MAIL_SHOW, que puede correr después de este (o cargarse recién ahí):
-- se espera un frame para anclar el panel a un MailFrame ya visible.
function Deliveries:MAIL_SHOW()
    C_Timer.After(0, function()
        if not MailFrame then return end
        self.panel = self.panel or CreatePanel()
        self:RefreshPanel()
    end)
end

function Deliveries:MAIL_CLOSED()
    if self.panel then self.panel:Hide() end
    self.preparing = nil
end

function Deliveries:OnEnable()
    self:RegisterEvent("MAIL_SHOW")
    self:RegisterEvent("MAIL_CLOSED")
    self:RegisterEvent("MAIL_SEND_SUCCESS")
    ns.SafeRegisterEvent(self, "MAIL_FAILED")
    if SendMail then hooksecurefunc("SendMail", function() self:OnSendMail() end) end
    -- Si las bolsas cambian con el buzón abierto (p. ej. al adjuntar), se repinta el panel.
    self:RegisterMessage(ns.MSG_SNAPSHOT_UPDATED, "RefreshPanel")
end
