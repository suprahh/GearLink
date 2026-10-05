-- GearLink - pestaña "Amigos": contactos detectados con GearLink, lista manual y saludo.
-- Click en un contacto: su ficha (GearView en modo solo lectura) con los datos cacheados y actualización bajo demanda.
local _, ns = ...
local L = ns.L

local ROW_HEIGHT = 22
local LIST_WIDTH = 740

-- Columnas: clave, x, ancho, alineación
local COLUMNS = {
    { "name", 40, 160, "LEFT", L.COL_NAME },
    { "source", 205, 80, "LEFT", L.COL_SOURCE },
    { "detail", 290, 210, "LEFT", L.COL_DETAIL },
    { "level", 505, 40, "RIGHT", L.COL_LEVEL },
    { "version", 555, 70, "RIGHT", L.COL_VERSION },
    { "seen", 630, 90, "RIGHT", L.COL_SEEN },
}

local SOURCE_LABEL = { CHAR = L.CONTACT_CHAR, BN = L.CONTACT_BN, MANUAL = L.CONTACT_MANUAL }

-- Confirmación al quitar un contacto manual desde la X. (StaticPopupDialogs es la tabla global de Blizzard para
-- diálogos; la clave lleva el prefijo del addon para no chocar con nadie.)
StaticPopupDialogs["GEARLINK_CONFIRM_REMOVE"] = {
    text = L.CONFIRM_REMOVE,
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, data)
        if data then ns.Friends:RemoveManual(data) end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3, -- evita el slot 1-2 que comparten otros addons (problema clásico de taint en popups)
}

local function ClassColored(classFile, text)
    local color = classFile and ((C_ClassColor and C_ClassColor.GetClassColor(classFile)) or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]))
    if color and color.WrapTextInColorCode then return color:WrapTextInColorCode(text) end
    return text
end

local function SourcesText(sources)
    local parts = {}
    for _, key in ipairs({ "CHAR", "BN", "MANUAL" }) do
        if sources[key] then parts[#parts + 1] = SOURCE_LABEL[key] end
    end
    return table.concat(parts, ", ")
end

local function StatusColor(v)
    if v.hasAddon and not v.compatible then return 1, 0.2, 0.2 end
    if v.hasAddon then return 0.12, 1, 0 end
    if v.online then return 1, 0.82, 0 end
    return 0.4, 0.4, 0.4
end

local function StatusText(v)
    if v.hasAddon and not v.compatible then return L.STATUS_INCOMPATIBLE end
    if v.hasAddon then return L.STATUS_WITH_ADDON end
    if v.online then return L.STATUS_ONLINE_NO_ADDON end
    if v.online == false then return L.STATUS_OFFLINE end
    return L.STATUS_UNKNOWN
end

---------------------------------------------------------------------------
-- Filas
---------------------------------------------------------------------------

local function Row_OnEnter(self)
    local v = self.view
    if not v then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(ClassColored(v.class, v.displayName))
    if v.battleTag then GameTooltip:AddLine(v.battleTag, 0.5, 0.75, 1) end
    GameTooltip:AddLine(StatusText(v), StatusColor(v))
    GameTooltip:AddDoubleLine(L.COL_SOURCE, SourcesText(v.sources), 0.7, 0.7, 0.7, 1, 1, 1)
    if v.addonVersion then
        GameTooltip:AddDoubleLine(L.COL_VERSION, ("%s (%s %s)"):format(v.addonVersion, L.PROTOCOL, tostring(v.protocol)), 0.7, 0.7, 0.7, 1, 1, 1)
    end
    if v.lastSeen then
        GameTooltip:AddDoubleLine(L.COL_SEEN, date("%d/%m %H:%M", v.lastSeen), 0.7, 0.7, 0.7, 1, 1, 1)
    end
    if v.isManual then GameTooltip:AddLine(L.REMOVE_HINT, 0.5, 0.5, 0.5) end
    GameTooltip:AddLine(L.CLICK_TO_VIEW, 0.3, 0.8, 1)
    GameTooltip:Show()
end

local function CreateRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(LIST_WIDTH, ROW_HEIGHT)

    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.08)

    -- Casilla "Sugerir": evaluar mis items para este contacto
    row.track = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.track:SetSize(20, 20)
    row.track:SetPoint("LEFT", 0, 0)
    local templateLabel = row.track.text or row.track.Text
    if templateLabel then templateLabel:SetText("") end
    row.track:SetScript("OnClick", function(self)
        if row.view then ns.Friends:SetTracked(row.view.key, self:GetChecked()) end
    end)
    row.track:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L.TRACK_TITLE, 1, 1, 1)
        GameTooltip:AddLine(L.TRACK_HELP, 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    row.track:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row.dot = row:CreateTexture(nil, "ARTWORK")
    row.dot:SetSize(8, 8)
    row.dot:SetPoint("LEFT", 26, 0)

    row.cols = {}
    for _, col in ipairs(COLUMNS) do
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", col[2], 0)
        fs:SetWidth(col[3])
        fs:SetJustifyH(col[4])
        fs:SetWordWrap(false)
        row.cols[col[1]] = fs
    end

    row.remove = CreateFrame("Button", nil, row)
    row.remove:SetSize(14, 14)
    row.remove:SetPoint("RIGHT", -4, 0)
    row.remove:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
    row.remove:SetHighlightTexture("Interface\\Buttons\\UI-StopButton", "ADD")
    row.remove:SetScript("OnClick", function()
        if row.view then
            StaticPopup_Show("GEARLINK_CONFIRM_REMOVE", row.view.displayName, nil, row.view.name)
        end
    end)
    row.remove:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L.REMOVE_MANUAL)
        GameTooltip:Show()
    end)
    row.remove:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row:SetScript("OnEnter", Row_OnEnter)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function()
        if row.view and row.onClick then row.onClick(row.view) end
    end)
    return row
end

local function FillRow(row, v)
    row.view = v
    row.track:SetChecked(v.tracked)
    row.dot:SetColorTexture(StatusColor(v))
    row.cols.name:SetText(ClassColored(v.class, v.displayName))
    row.cols.source:SetText(SourcesText(v.sources))

    local detail = {}
    if v.class then detail[#detail + 1] = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[v.class]) or v.class end
    if v.tree then detail[#detail + 1] = L["TREE_" .. v.tree] end
    if v.role then detail[#detail + 1] = L["ROLE_" .. v.role] end
    -- Sin sesión de GearLink: el estado va siempre visible (antes lo tapaba la clase que da la lista de amigos).
    if not v.hasAddon then
        local status = (v.online and not v.everHadAddon) and L.STATUS_NO_ADDON_SHORT or StatusText(v)
        detail[#detail + 1] = "|cff808080" .. status .. "|r"
    end
    row.cols.detail:SetText(table.concat(detail, " · "))

    row.cols.level:SetText(v.level and tostring(v.level) or "")
    if v.addonVersion then
        row.cols.version:SetText(v.compatible and v.addonVersion or ("|cffff3333" .. v.addonVersion .. "|r"))
    else
        row.cols.version:SetText("")
    end

    if v.hasAddon then
        row.cols.seen:SetText("|cff1eff00" .. L.SEEN_NOW .. "|r")
    elseif v.lastSeen then
        row.cols.seen:SetText(L.SEEN_AGO:format(ns.FormatAgo(time() - v.lastSeen)))
    else
        row.cols.seen:SetText("")
    end
    row.remove:SetShown(v.isManual)
end

---------------------------------------------------------------------------
-- Panel de lista
---------------------------------------------------------------------------

local function BuildListPane(pane, onOpen)
    local list = { rows = {} }

    local title = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 4, -4)
    title:SetText(L.FRIENDS_TITLE)

    local countText = pane:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    countText:SetPoint("LEFT", title, "RIGHT", 10, 0)

    -- Agregar contacto manual / saludar
    local helloButton = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    helloButton:SetSize(110, 22)
    helloButton:SetPoint("TOPRIGHT", -4, -2)
    helloButton:SetText(L.BTN_HELLO)
    helloButton:SetScript("OnClick", function() ns.Friends:SendHelloAll(true) end)

    local addButton = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    addButton:SetSize(80, 22)
    addButton:SetPoint("RIGHT", helloButton, "LEFT", -10, 0)
    addButton:SetText(L.BTN_ADD)

    local input = CreateFrame("EditBox", nil, pane, "InputBoxTemplate")
    input:SetSize(170, 20)
    input:SetPoint("RIGHT", addButton, "LEFT", -8, 0)
    input:SetAutoFocus(false)
    input:SetMaxLetters(48)
    local placeholder = input:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    placeholder:SetPoint("LEFT", 2, 0)
    placeholder:SetText(L.ADD_PLACEHOLDER)

    local function Submit()
        local text = strtrim(input:GetText() or "")
        if text ~= "" then ns.Friends:AddManual(text) end
        input:SetText("")
        input:ClearFocus()
    end
    addButton:SetScript("OnClick", Submit)
    input:SetScript("OnEnterPressed", Submit)
    input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    input:HookScript("OnTextChanged", function(self) placeholder:SetShown((self:GetText() or "") == "") end)

    local help = pane:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    help:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    help:SetPoint("RIGHT", -4, 0)
    help:SetJustifyH("LEFT")
    help:SetText(L.FRIENDS_HELP)

    -- Cabecera de columnas
    local header = CreateFrame("Frame", nil, pane)
    header:SetSize(LIST_WIDTH, 16)
    header:SetPoint("TOPLEFT", 0, -56)
    for _, col in ipairs(COLUMNS) do
        local fs = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("LEFT", col[2], 0)
        fs:SetWidth(col[3])
        fs:SetJustifyH(col[4])
        fs:SetText(col[5])
    end
    local trackHeader = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    trackHeader:SetPoint("LEFT", 0, 0)
    trackHeader:SetText(L.COL_TRACK)

    -- Lista con scroll
    local scroll = CreateFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    scroll:SetPoint("BOTTOMLEFT", 0, 0)
    scroll:SetWidth(LIST_WIDTH)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(LIST_WIDTH, 1)
    scroll:SetScrollChild(content)

    local empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    empty:SetPoint("TOPLEFT", 4, -6)
    empty:SetWidth(LIST_WIDTH - 8)
    empty:SetJustifyH("LEFT")
    empty:SetText(L.NO_CONTACTS_UI)

    function list:Refresh()
        local views = ns.Friends:GetList()
        local withAddon = 0
        for i, v in ipairs(views) do
            local row = self.rows[i]
            if not row then
                row = CreateRow(content)
                row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
                row.onClick = onOpen
                self.rows[i] = row
            end
            FillRow(row, v)
            row:Show()
            if v.hasAddon then withAddon = withAddon + 1 end
        end
        for i = #views + 1, #self.rows do
            self.rows[i]:Hide()
            self.rows[i].view = nil
        end
        local height = #views * ROW_HEIGHT
        content:SetHeight(math.max(1, height))
        empty:SetShown(#views == 0)
        countText:SetText(L.FRIENDS_COUNT:format(withAddon, #views))

        local scrollBar = scroll.ScrollBar
        if scrollBar then
            local needsScroll = height > scroll:GetHeight()
            scrollBar:SetShown(needsScroll)
            if not needsScroll then scroll:SetVerticalScroll(0) end
        end
    end

    return list
end

---------------------------------------------------------------------------
-- Ficha de un amigo
---------------------------------------------------------------------------

local STATE_TEXT = {
    REQUESTING = { L.SYNC_REQUESTING, "|cffffd200" },
    UP_TO_DATE = { L.SYNC_UP_TO_DATE, "|cff1eff00" },
    UPDATED = { L.SYNC_UPDATED, "|cff1eff00" },
    OFFLINE = { L.SYNC_OFFLINE, "|cff808080" },
    NO_DATA = { L.SYNC_NO_DATA, "|cff808080" },
    TIMEOUT = { L.SYNC_TIMEOUT, "|cffff8000" },
    INVALID = { L.SYNC_INVALID, "|cffff3333" },
}

local function BuildDetailPane(pane, onBack)
    local detail = {}

    local back = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    back:SetSize(90, 22)
    back:SetPoint("TOPLEFT", 0, -2)
    back:SetText(L.BTN_BACK)
    back:SetScript("OnClick", onBack)

    local refresh = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    refresh:SetSize(100, 22)
    refresh:SetPoint("TOPRIGHT", -4, -2)
    refresh:SetText(L.BTN_REFRESH)
    refresh:SetScript("OnClick", function()
        if detail.key then ns.Sync:Request(detail.key) end
    end)

    local status = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("LEFT", back, "RIGHT", 12, 0)
    status:SetPoint("RIGHT", refresh, "LEFT", -12, 0)
    status:SetJustifyH("LEFT")

    local host = CreateFrame("Frame", nil, pane)
    host:SetPoint("TOPLEFT", 0, -32)
    host:SetPoint("BOTTOMRIGHT")
    local view = ns.GearView:Create(host, { live = false, editable = false })

    local noData = pane:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    noData:SetPoint("TOPLEFT", host, "TOPLEFT", 4, -8)
    noData:SetPoint("RIGHT", -4, 0)
    noData:SetJustifyH("LEFT")

    function detail:Open(key)
        self.key = key
        self:Refresh()
        ns.Sync:Request(key)
    end

    function detail:Refresh()
        local key = self.key
        if not key then return end
        local snap = ns.Sync:GetCached(key)
        local state = ns.Sync:GetState(key)
        local stateInfo = state and STATE_TEXT[state.state]
        local text = stateInfo and (stateInfo[2] .. stateInfo[1] .. "|r") or ""
        if state and state.detail then
            text = text .. " |cff808080(" .. tostring(state.detail) .. ")|r"
        end
        if snap and snap.skipped then
            text = text .. "  |cffff8000" .. L.SYNC_SKIPPED:format(snap.skipped) .. "|r"
        end
        if snap and snap.checkedAt then
            text = text .. "  |cff808080" .. L.CHECKED_AGO:format(ns.FormatAgo(time() - snap.checkedAt)) .. "|r"
        end
        status:SetText(text)

        if snap then
            noData:Hide()
            host:Show()
            view:SetSnapshot(snap)
        else
            host:Hide()
            local c = ns.Friends:GetContact(key)
            local name = c and ns.Friends:GetView(c).displayName or key
            noData:SetText(L.FRIEND_NO_DATA:format(name))
            noData:Show()
        end
    end

    return detail
end

---------------------------------------------------------------------------
-- Pestaña
---------------------------------------------------------------------------

ns.MainFrame:RegisterTab("friends", L.TAB_FRIENDS, function(container)
    local tab = LibStub("AceEvent-3.0"):Embed({})

    local listPane = CreateFrame("Frame", nil, container)
    listPane:SetAllPoints()
    local detailPane = CreateFrame("Frame", nil, container)
    detailPane:SetAllPoints()
    detailPane:Hide()

    local list, detail
    list = BuildListPane(listPane, function(view)
        listPane:Hide()
        detailPane:Show()
        detail:Open(view.key)
    end)
    detail = BuildDetailPane(detailPane, function()
        detail.key = nil
        detailPane:Hide()
        listPane:Show()
        list:Refresh()
    end)

    function tab:OnShow()
        if detail.key then
            detail:Refresh()
        else
            list:Refresh()
            ns.Friends:SendHelloAll(false) -- como mucho una vez cada 30 s
        end
    end

    tab:RegisterMessage(ns.MSG_CONTACTS_UPDATED, function()
        if listPane:IsVisible() then list:Refresh() end
    end)
    tab:RegisterMessage(ns.MSG_FRIEND_SNAPSHOT, function(_, key)
        if detailPane:IsVisible() and key == detail.key then detail:Refresh() end
    end)

    return tab
end)

