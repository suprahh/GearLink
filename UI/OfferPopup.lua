-- GearLink - popup "X te ofrece [item]" con comparación contra lo que llevo equipado y botones Aceptar / No, gracias.
local _, ns = ...
local L = ns.L

local OfferPopup = {}
ns.OfferPopup = OfferPopup

local FRAME_NAME = "GearLinkOfferPopup" -- nombre global solo para cerrar con ESC (UISpecialFrames)
local MAX_QUEUE = 5

local queue = {}

local function QualityColor(quality)
    if quality and C_Item.GetItemQualityColor then
        local r, g, b = C_Item.GetItemQualityColor(quality)
        if r then return r, g, b end
    end
    return 1, 1, 1
end

-- Pinta nombre (color de calidad) y nivel de un item en una FontString cuando el item está cargado.
local function SetItemText(fontString, link, prefix)
    if not link then
        fontString:SetText(prefix .. "|cff808080" .. L.NOTHING_EQUIPPED .. "|r")
        return
    end
    fontString:SetText(prefix .. L.LOADING)
    local item = Item:CreateFromItemLink(link)
    if item:IsItemEmpty() then return end
    local token = {}
    fontString.token = token
    item:ContinueOnItemLoad(function()
        if fontString.token ~= token then return end
        local r, g, b = QualityColor(item:GetItemQuality())
        local ilvl = (C_Item.GetDetailedItemLevelInfo and C_Item.GetDetailedItemLevelInfo(link)) or item:GetCurrentItemLevel() or 0
        local floor = math.floor
        fontString:SetText(("%s|cff%02x%02x%02x%s|r  |cffaaaaaa(%s)|r"):format(prefix, floor(r * 255), floor(g * 255), floor(b * 255),
            item:GetItemName() or "?", L.ITEM_LEVEL_SHORT:format(ilvl)))
    end)
end

local function Create()
    local f = CreateFrame("Frame", FRAME_NAME, UIParent, "BackdropTemplate")
    f:SetSize(380, 190)
    f:SetPoint("CENTER", 0, 120)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    tinsert(UISpecialFrames, FRAME_NAME)

    -- El fondo del diálogo es semitransparente: una capa sólida debajo evita que se lea lo que hay detrás.
    local solid = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    solid:SetPoint("TOPLEFT", 11, -12)
    solid:SetPoint("BOTTOMRIGHT", -12, 11)
    solid:SetColorTexture(0.05, 0.05, 0.05, 1)

    f.title =f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -20)

    -- Ícono del item (tooltip al pasar el mouse, shift-click para enlazar)
    f.itemButton = CreateFrame("Button", nil, f)
    f.itemButton:SetSize(40, 40)
    f.itemButton:SetPoint("TOPLEFT", 24, -48)
    f.itemButton.icon = f.itemButton:CreateTexture(nil, "ARTWORK")
    f.itemButton.icon:SetAllPoints()
    f.itemButton:SetScript("OnEnter", function(self)
        if not f.offer then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(f.offer.item)
        GameTooltip:Show()
    end)
    f.itemButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.itemButton:SetScript("OnClick", function()
        if f.offer then
            local fullLink = select(2, C_Item.GetItemInfo(f.offer.item))
            if fullLink then HandleModifiedItemClick(fullLink) end
        end
    end)

    f.itemName = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.itemName:SetPoint("TOPLEFT", f.itemButton, "TOPRIGHT", 10, -2)
    f.itemName:SetPoint("RIGHT", -24, 0)
    f.itemName:SetJustifyH("LEFT")
    f.itemName:SetWordWrap(false)

    f.reason = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.reason:SetPoint("TOPLEFT", f.itemName, "BOTTOMLEFT", 0, -6)
    f.reason:SetPoint("RIGHT", -24, 0)
    f.reason:SetJustifyH("LEFT")
    f.reason:SetTextColor(0.12, 1, 0)

    f.current = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.current:SetPoint("TOPLEFT", f.itemButton, "BOTTOMLEFT", 0, -12)
    f.current:SetPoint("RIGHT", -24, 0)
    f.current:SetJustifyH("LEFT")
    f.current:SetWordWrap(false)

    f.accept = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.accept:SetSize(130, 24)
    f.accept:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -6, 20)
    f.accept:SetText(L.BTN_ACCEPT)
    f.accept:SetScript("OnClick", function() OfferPopup:Answer(true) end)

    f.decline = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.decline:SetSize(130, 24)
    f.decline:SetPoint("BOTTOMLEFT", f, "BOTTOM", 6, 20)
    f.decline:SetText(L.BTN_DECLINE)
    f.decline:SetScript("OnClick", function() OfferPopup:Answer(false) end)

    -- Cerrar con ESC o la X = no responder (no se envía nada)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)
    f:SetScript("OnHide", function() OfferPopup:Next() end)

    f:Hide()
    return f
end

function OfferPopup:Display(offer)
    self.frame = self.frame or Create()
    local f = self.frame
    f.offer = offer
    f.title:SetText(L.OFFER_POPUP_TITLE:format(offer.from))
    f.itemButton.icon:SetTexture(select(5, C_Item.GetItemInfoInstant(offer.item)) or 134400)
    SetItemText(f.itemName, offer.item, "")
    f.reason:SetText(offer.reason ~= "" and offer.reason or "")
    local equipped = offer.slot and GetInventoryItemLink("player", offer.slot) or nil
    local slotName = offer.slot and ns.Upgrade.SlotName(offer.slot) or "?"
    SetItemText(f.current, equipped, L.OFFER_POPUP_CURRENT:format(slotName))
    f:Show()
    local sound = SOUNDKIT and (SOUNDKIT.IG_MAINMENU_OPEN or SOUNDKIT.TELL_MESSAGE)
    if sound then PlaySound(sound) end
end

function OfferPopup:Show(offer)
    if self.frame and self.frame:IsShown() then
        if #queue < MAX_QUEUE then queue[#queue + 1] = offer end
        return
    end
    self:Display(offer)
end

-- Al cerrarse uno, muestra la siguiente oferta en cola.
function OfferPopup:Next()
    if self.frame then self.frame.offer = nil end
    local nextOffer = table.remove(queue, 1)
    if nextOffer then C_Timer.After(0.2, function() self:Display(nextOffer) end) end
end

function OfferPopup:Answer(accepted)
    local f = self.frame
    local offer = f and f.offer
    if offer then ns.Trade:Reply(offer, accepted) end
    f:Hide()
end
