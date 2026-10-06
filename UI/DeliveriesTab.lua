-- GearLink - pestaña "Entregas": qué items ofrecí y en qué quedó cada uno.
--   Esperando respuesta - ofertas abiertas (Trade:GetOpenOffers)
--   Por enviar          - ofertas aceptadas, pendientes de mandar por correo (Deliveries:GetPending)
--   Historial           - enviados por correo y rechazados (Deliveries:GetLog)
local _, ns = ...
local L = ns.L

local ROW_HEIGHT = 30
local HEADER_HEIGHT = 26
local LIST_WIDTH = 740
local REFRESH_INTERVAL = 15 -- s: cuenta regresiva de las ofertas abiertas mientras la pestaña está visible

local GREEN, YELLOW, RED, GRAY = "|cff1eff00", "|cffffd200", "|cffff5555", "|cff808080"

---------------------------------------------------------------------------
-- Filas
---------------------------------------------------------------------------

local function CreateRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(LIST_WIDTH, ROW_HEIGHT)

    local highlight = row:CreateTexture(nil, "BACKGROUND")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.04)

    row.iconButton = CreateFrame("Button", nil, row)
    row.iconButton:SetSize(24, 24)
    row.iconButton:SetPoint("LEFT", 4, 0)
    row.icon = row.iconButton:CreateTexture(nil, "ARTWORK")
    row.icon:SetAllPoints()
    row.iconButton:SetScript("OnEnter", function(self)
        if not row.item then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(row.item)
        GameTooltip:Show()
    end)
    row.iconButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("LEFT", 36, 0)
    row.name:SetWidth(250)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.to = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.to:SetPoint("LEFT", 295, 0)
    row.to:SetWidth(150)
    row.to:SetJustifyH("LEFT")
    row.to:SetWordWrap(false)

    row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.status:SetPoint("LEFT", 450, 0)
    row.status:SetWidth(200)
    row.status:SetJustifyH("LEFT")
    row.status:SetWordWrap(false)

    row.time = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.time:SetPoint("RIGHT", -26, 0)
    row.time:SetJustifyH("RIGHT")

    row.remove = CreateFrame("Button", nil, row)
    row.remove:SetSize(14, 14)
    row.remove:SetPoint("RIGHT", -6, 0)
    row.remove:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
    row.remove:SetHighlightTexture("Interface\\Buttons\\UI-StopButton", "ADD")
    row.remove:SetScript("OnClick", function() if row.deliveryId then ns.Deliveries:Remove(row.deliveryId) end end)
    row.remove:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L.DELIVERY_REMOVE)
        GameTooltip:Show()
    end)
    row.remove:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

local function FillRow(row, item, display, status, timeText, deliveryId)
    row.item, row.deliveryId = item, deliveryId
    row.icon:SetTexture(select(5, C_Item.GetItemInfoInstant(item)) or 134400)
    row.name:SetText((select(2, C_Item.GetItemInfo(item))) or L.LOADING)
    row.to:SetText(L.DELIVERY_FOR:format(display or "?"))
    row.status:SetText(status)
    row.time:SetText(timeText or "")
    row.remove:SetShown(deliveryId ~= nil)
end

-- Estado de una entrega pendiente según dónde esté el item ahora.
local function PendingStatus(d)
    local item = ns.Deliveries:FindInBags(d.item)
    if not item then return GRAY .. L.DELIVERIES_STATUS_MISSING .. "|r" end
    if item.bind == "TRADE_WINDOW" or item.bind == "SOULBOUND" then return YELLOW .. L.DELIVERIES_STATUS_TRADE .. "|r" end
    return YELLOW .. L.DELIVERIES_STATUS_TO_MAIL .. "|r"
end

local LOG_STATUS = {
    SENT = GREEN .. L.DELIVERIES_STATUS_SENT .. "|r",
    DECLINED = RED .. L.DELIVERIES_STATUS_DECLINED .. "|r",
}

---------------------------------------------------------------------------
-- Pestaña
---------------------------------------------------------------------------

ns.MainFrame:RegisterTab("deliveries", L.TAB_DELIVERIES, function(container)
    local tab = LibStub("AceEvent-3.0"):Embed({})

    local title = container:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 4, -4)
    title:SetText(L.DELIVERIES_TITLE)

    local help = container:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    help:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    help:SetPoint("RIGHT", -4, 0)
    help:SetJustifyH("LEFT")
    help:SetText(L.DELIVERIES_HELP)

    local clearButton = CreateFrame("Button", nil, container, "UIPanelButtonTemplate")
    clearButton:SetSize(130, 22)
    clearButton:SetPoint("TOPRIGHT", -4, -2)
    clearButton:SetText(L.BTN_CLEAR_LOG)
    clearButton:SetScript("OnClick", function() ns.Deliveries:ClearLog() end)

    local scroll = CreateFrame("ScrollFrame", nil, container, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -48)
    scroll:SetPoint("BOTTOMRIGHT", -26, 0)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(LIST_WIDTH, 1)
    scroll:SetScrollChild(content)

    local rows, headers = {}, {}

    -- Textos sueltos (títulos de sección y "nada por aquí"), reutilizados entre refrescos.
    local function Label(index, text, x, y, font)
        local fs = headers[index]
        if not fs then
            fs = content:CreateFontString(nil, "OVERLAY")
            headers[index] = fs
        end
        fs:SetFontObject(font)
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", x, y)
        fs:SetText(text)
        fs:Show()
    end

    function tab:Refresh()
        local y, nRows, nHeaders = 0, 0, 0
        local function AddRow(...)
            nRows = nRows + 1
            local row = rows[nRows]
            if not row then
                row = CreateRow(content)
                rows[nRows] = row
            end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, y)
            FillRow(row, ...)
            row:Show()
            y = y - ROW_HEIGHT
        end
        local function Section(text, list, fill)
            nHeaders = nHeaders + 1
            Label(nHeaders, ("%s |cff888888(%d)|r"):format(text, #list), 4, y - 6, GameFontNormal)
            y = y - HEADER_HEIGHT
            if #list == 0 then
                nHeaders = nHeaders + 1
                Label(nHeaders, L.DELIVERIES_EMPTY, 36, y, GameFontDisableSmall)
                y = y - 18
            end
            for _, entry in ipairs(list) do fill(entry) end
            y = y - 8
        end

        Section(L.DELIVERIES_SECTION_OPEN, ns.Trade:GetOpenOffers(), function(o)
            AddRow(o.item, o.display, YELLOW .. L.DELIVERIES_STATUS_WAITING:format(math.ceil(o.left / 60)) .. "|r",
                date("%d/%m %H:%M", o.at))
        end)
        Section(L.DELIVERIES_SECTION_PENDING, ns.Deliveries:GetPending(), function(e)
            AddRow(e.d.item, e.d.display, PendingStatus(e.d), date("%d/%m %H:%M", e.d.at), e.id)
        end)
        local log = ns.Deliveries:GetLog()
        Section(L.DELIVERIES_SECTION_LOG, log, function(entry)
            AddRow(entry.item, entry.display, LOG_STATUS[entry.status] or entry.status, date("%d/%m %H:%M", entry.at))
        end)
        clearButton:SetEnabled(#log > 0)

        for i = nRows + 1, #rows do rows[i]:Hide() end
        for i = nHeaders + 1, #headers do headers[i]:Hide() end
        content:SetHeight(math.max(1, -y))
    end

    function tab:OnShow()
        self:Refresh()
    end

    local function RefreshIfVisible()
        if container:IsVisible() then tab:Refresh() end
    end
    tab:RegisterMessage(ns.MSG_MATCHES_UPDATED, RefreshIfVisible)
    tab:RegisterMessage(ns.MSG_SNAPSHOT_UPDATED, RefreshIfVisible)
    -- Nombres de items que no estaban en caché
    tab:RegisterEvent("GET_ITEM_INFO_RECEIVED", function()
        ns.Debounce("deliveriesTab", 0.2, RefreshIfVisible)
    end)

    local elapsed = 0
    container:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed < REFRESH_INTERVAL then return end
        elapsed = 0
        tab:Refresh()
    end)

    return tab
end)
