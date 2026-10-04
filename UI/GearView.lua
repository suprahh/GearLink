-- GearLink - vista de equipo (estilo ficha de personaje, con modelo 3D) + equipables en bolsas, a partir de un snapshot.
-- Reutilizable: modo propio (live = tooltips del item real, editable = botones de rol/stat) o solo lectura (amigo).
local _, ns = ...
local L = ns.L

local GearView = {}
ns.GearView = GearView

local ROW_HEIGHT = 20
local ICON_SIZE = 18
local HEADER_HEIGHT = 62
local DOLL_WIDTH = 400
local SLOT_SIZE = 40
local SLOT_GAP = 6
local RIGHT_WIDTH = 344
local BAG_INFO_WIDTH = 150

-- Distribución de la ficha de personaje: columna izquierda, columna derecha y armas abajo.
local DOLL_LEFT = { 1, 2, 3, 15, 5, 4, 19, 9 }
local DOLL_RIGHT = { 10, 6, 7, 8, 11, 12, 13, 14 }
local DOLL_BOTTOM = { 16, 17, 18 }
-- Slots que cuentan para el nivel de item promedio (camisa y tabardo no).
local AVG_SLOTS = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 }

local ROLE_CYCLE = { false, "TANK", "HEALER", "DAMAGER" }
local STAT_CYCLE = { false, "STR", "AGI", "INT" }

local BIND_TEXT = {
    UNBOUND = { L.TRADE_UNBOUND, "|cff1eff00" },
    BOE = { L.TRADE_BOE, "|cff1eff00" },
    TRADE_WINDOW = { L.TRADE_WINDOW, "|cffffd200" },
    SOULBOUND = { L.TRADE_SOULBOUND, "|cff808080" },
    UNKNOWN = { L.TRADE_UNKNOWN, "|cffff8000" },
}

---------------------------------------------------------------------------
-- Slots
---------------------------------------------------------------------------

local SLOT_KEYS = {
    [1] = "HeadSlot", [2] = "NeckSlot", [3] = "ShoulderSlot", [4] = "ShirtSlot", [5] = "ChestSlot",
    [6] = "WaistSlot", [7] = "LegsSlot", [8] = "FeetSlot", [9] = "WristSlot", [10] = "HandsSlot",
    [11] = "Finger0Slot", [12] = "Finger1Slot", [13] = "Trinket0Slot", [14] = "Trinket1Slot", [15] = "BackSlot",
    [16] = "MainHandSlot", [17] = "SecondaryHandSlot", [18] = "RangedSlot", [19] = "TabardSlot",
}

local slotInfoCache = {}
-- VERIFICAR EN FOREVER: slot de rango (18) -> /dump GetInventorySlotInfo("RangedSlot")
local function GetSlotInfo(slotID)
    local info = slotInfoCache[slotID]
    if info then return info end
    local key = SLOT_KEYS[slotID]
    local ok, _, texture = false, nil, nil
    if key then ok, _, texture = pcall(GetInventorySlotInfo, key) end
    info = {
        name = (key and _G[key:upper()]) or ("Slot " .. slotID),
        texture = ok and texture or nil,
        exists = ok,
    }
    slotInfoCache[slotID] = info
    return info
end

---------------------------------------------------------------------------
-- Helpers de items
---------------------------------------------------------------------------

local function GetQualityColor(quality)
    if quality and C_Item.GetItemQualityColor then
        local r, g, b = C_Item.GetItemQualityColor(quality)
        if r then return r, g, b end
    end
    local c = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

local function GetItemLevel(link, item)
    if C_Item.GetDetailedItemLevelInfo then
        local ilvl = C_Item.GetDetailedItemLevelInfo(link)
        if ilvl then return ilvl end
    end
    return item:GetCurrentItemLevel()
end

local function ClassColored(classFile, text)
    local color = (C_ClassColor and C_ClassColor.GetClassColor(classFile)) or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile])
    if color and color.WrapTextInColorCode then return color:WrapTextInColorCode(text) end
    return text
end

---------------------------------------------------------------------------
-- Filas
---------------------------------------------------------------------------

local function Row_OnEnter(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if self.link then
        if self.live and self.bag then
            GameTooltip:SetBagItem(self.bag, self.slot)
        elseif self.live and self.invSlot then
            GameTooltip:SetInventoryItem("player", self.invSlot)
        else
            GameTooltip:SetHyperlink(self.link)
        end
    elseif self.emptyText then
        GameTooltip:SetText(self.emptyText)
    end
    GameTooltip:Show()
end

local function Row_OnLeave()
    GameTooltip:Hide()
end

local function Row_OnClick(self)
    -- Shift-click: enlazar en el chat; Ctrl-click: probador (comportamiento estándar de Blizzard).
    if self.link then HandleModifiedItemClick(self.link) end
end

-- Indicador "le sirve a un amigo": ícono junto al item con el detalle al pasar el mouse.
local BADGE_ICON = "Interface\\Icons\\INV_Misc_Gift_01"

-- Estrella (ícono de marca de banda) para el amigo al que más le mejora, cuando hay varios.
local STAR = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:12|t "

-- Nombre de un candidato con su estado: mayor mejora, desconectado, oferta abierta a otro, en espera.
local function MatchLabel(m, i, matches, link)
    local name = m.name
    if i == 1 and #matches > 1 and not m.giftOnly then name = STAR .. name end
    if not m.online then name = name .. " |cff808080(" .. L.STATUS_OFFLINE:lower() .. ")|r" end
    local open = ns.Trade:GetOpenOffer(link)
    if open and open.key == m.key then
        name = name .. " |cffffd200(" .. L.OFFER_OPEN_WAITING .. ")|r"
    else
        local left = ns.Trade:CooldownLeft(m.key, link)
        if left then name = name .. " |cffff8000(" .. L.OFFERED_WAIT:format(math.ceil(left / 60)) .. ")|r" end
    end
    return name
end

local function Badge_OnEnter(self)
    local matches = self.matches
    if not matches then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(L.BADGE_TITLE, 0.3, 0.8, 1)
    for i, m in ipairs(matches) do
        GameTooltip:AddDoubleLine(MatchLabel(m, i, matches, self.link), m.reason, 1, 1, 1, 0.12, 1, 0)
    end
    GameTooltip:AddLine(" ")
    local open = ns.Trade:GetOpenOffer(self.link)
    if matches[1].reserved then
        GameTooltip:AddLine(L.BADGE_RESERVED_HINT, 0.3, 0.8, 1, true)
    elseif open then
        GameTooltip:AddLine(L.BADGE_OPEN_OFFER:format(open.display), 1, 0.82, 0, true)
    else
        GameTooltip:AddLine(#matches > 1 and L.BADGE_CLICK_MENU or L.BADGE_CLICK_ONE, 0.3, 0.8, 1)
    end
    GameTooltip:Show()
end

-- Click en el indicador: ofrecer el item. Con varios amigos, un menú para elegir.
local function Badge_OnClick(self)
    local matches, link = self.matches, self.link
    if not (matches and link) then return end
    GameTooltip:Hide()
    if matches[1].reserved then
        return ns.addon:Print(L.DELIVERY_REMINDER:format(matches[1].name))
    end
    if #matches == 1 or not (MenuUtil and MenuUtil.CreateContextMenu) then
        ns.Trade:Offer(link, matches[1])
        return
    end
    MenuUtil.CreateContextMenu(self, function(_, root)
        root:CreateTitle(L.OFFER_MENU_TITLE)
        local open = ns.Trade:GetOpenOffer(link)
        for i, m in ipairs(matches) do
            local text = ("%s  |cff1eff00%s|r"):format(MatchLabel(m, i, matches, link), m.reason)
            -- Uno a la vez: con una oferta abierta, nadie más puede recibirla; y respeta la espera por amigo.
            local blocked = (open ~= nil) or ns.Trade:CooldownLeft(m.key, link) ~= nil
            if open and open.key ~= m.key then
                text = text .. " |cff808080(" .. L.OFFER_OPEN_TO:format(open.display) .. ")|r"
            end
            local button = root:CreateButton(text, function() ns.Trade:Offer(link, m) end)
            if blocked and button.SetEnabled then button:SetEnabled(false) end
        end
    end)
end

local function CreateBadge(row)
    local badge = CreateFrame("Button", nil, row)
    badge:SetSize(16, 16)
    badge.icon = badge:CreateTexture(nil, "ARTWORK")
    badge.icon:SetAllPoints()
    badge.icon:SetTexture(BADGE_ICON)
    badge.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    badge:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    badge:SetScript("OnEnter", Badge_OnEnter)
    badge:SetScript("OnClick", Badge_OnClick)
    badge:SetScript("OnLeave", function() GameTooltip:Hide() end)
    badge:Hide()
    return badge
end

local function CreateRow(parent, width, labelWidth, withBadge)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(width, ROW_HEIGHT)
    row:RegisterForClicks("LeftButtonUp")

    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.08)

    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.label:SetPoint("LEFT", 2, 0)
    row.label:SetWidth(labelWidth)
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ICON_SIZE, ICON_SIZE)
    row.icon:SetPoint("LEFT", labelWidth + 4, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    row.ilvl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.ilvl:SetPoint("RIGHT", -4, 0)
    row.ilvl:SetWidth(30)
    row.ilvl:SetJustifyH("RIGHT")

    row.info = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.info:SetPoint("RIGHT", row.ilvl, "LEFT", -6, 0)
    row.info:SetJustifyH("RIGHT")
    row.info:SetWordWrap(false)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    if withBadge then
        row.badge = CreateBadge(row)
        row.badge:SetPoint("RIGHT", row.info, "LEFT", -4, 0)
        row.name:SetPoint("RIGHT", row.badge, "LEFT", -4, 0)
    else
        row.name:SetPoint("RIGHT", row.info, "LEFT", -6, 0)
    end
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row:SetScript("OnEnter", Row_OnEnter)
    row:SetScript("OnLeave", Row_OnLeave)
    row:SetScript("OnClick", Row_OnClick)
    return row
end

-- Pinta el item de una fila. El nombre, la calidad y el nivel se leen solo cuando el item está cargado en caché.
local function SetRowItem(row, link, emptyTexture)
    local token = {}
    row.token = token
    row.link = link
    row.ilvl:SetText("")
    if not link then
        row.icon:SetTexture(emptyTexture or 134400) -- 134400 = INV_Misc_QuestionMark
        row.icon:SetDesaturated(true)
        row.name:SetText(L.EMPTY_SLOT)
        row.name:SetTextColor(0.5, 0.5, 0.5)
        return
    end

    row.icon:SetDesaturated(false)
    row.icon:SetTexture(select(5, C_Item.GetItemInfoInstant(link)) or 134400)
    row.name:SetText(link:match("%[(.-)%]") or L.LOADING)
    row.name:SetTextColor(1, 1, 1)

    local item = Item:CreateFromItemLink(link)
    if item:IsItemEmpty() then return end
    item:ContinueOnItemLoad(function()
        if row.token ~= token then return end -- la fila ya muestra otro item
        -- Los snapshots de amigos traen "item:..." (forma corta): se reconstruye el link completo para
        -- poder enlazarlo en el chat con shift-click.
        if not link:find("|H", 1, true) then
            local fullLink = select(2, C_Item.GetItemInfo(link))
            if fullLink then row.link = fullLink end
        end
        row.name:SetText(item:GetItemName() or link)
        row.name:SetTextColor(GetQualityColor(item:GetItemQuality()))
        local ilvl = GetItemLevel(link, item)
        row.ilvl:SetText(ilvl and ilvl > 0 and tostring(ilvl) or "")
    end)
end

---------------------------------------------------------------------------
-- Botones de slot (estilo ficha de personaje)
---------------------------------------------------------------------------

local function Slot_OnEnter(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if self.link then
        if self.live then
            GameTooltip:SetInventoryItem("player", self.invSlot)
        else
            GameTooltip:SetHyperlink(self.link)
        end
    else
        GameTooltip:SetText(GetSlotInfo(self.invSlot).name)
        GameTooltip:AddLine(L.EMPTY_SLOT, 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
end

local function CreateSlotButton(parent, slotID)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(SLOT_SIZE, SLOT_SIZE)
    b.invSlot = slotID

    -- Fondo del slot vacío (la silueta del slot, como en la ficha de personaje)
    b.empty = b:CreateTexture(nil, "BACKGROUND")
    b.empty:SetAllPoints()
    b.empty:SetTexture(GetSlotInfo(slotID).texture or 134400)

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()

    -- Borde de calidad (el mismo recurso que usan los botones de item de Blizzard)
    b.border = b:CreateTexture(nil, "OVERLAY")
    b.border:SetAllPoints()
    b.border:SetTexture("Interface\\Common\\WhiteIconFrame")
    b.border:Hide()

    b.ilvl = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.ilvl:SetPoint("BOTTOMRIGHT", -2, 2)

    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b:SetScript("OnEnter", Slot_OnEnter)
    b:SetScript("OnLeave", Row_OnLeave)
    b:SetScript("OnClick", Row_OnClick)
    return b
end

-- onLevel(ilvl) se llama cuando se conoce el nivel del item (o 0 si el slot está vacío).
local function SetSlotItem(b, link, onLevel)
    local token = {}
    b.token = token
    b.link = link
    b.ilvl:SetText("")
    b.border:Hide()
    if not link then
        b.icon:Hide()
        if onLevel then onLevel(0) end
        return
    end
    b.icon:SetTexture(select(5, C_Item.GetItemInfoInstant(link)) or 134400)
    b.icon:Show()

    local item = Item:CreateFromItemLink(link)
    if item:IsItemEmpty() then return end
    item:ContinueOnItemLoad(function()
        if b.token ~= token then return end
        if not link:find("|H", 1, true) then
            local fullLink = select(2, C_Item.GetItemInfo(link))
            if fullLink then b.link = fullLink end
        end
        local quality = item:GetItemQuality()
        if quality and quality >= 2 then
            b.border:SetVertexColor(GetQualityColor(quality))
            b.border:Show()
        end
        local ilvl = GetItemLevel(link, item) or 0
        if ilvl > 0 then
            b.ilvl:SetText(ilvl)
            b.ilvl:SetTextColor(GetQualityColor(quality))
        end
        if onLevel then onLevel(ilvl) end
    end)
end

---------------------------------------------------------------------------
-- Modelo 3D (se gira arrastrando; la rueda acerca y aleja)
---------------------------------------------------------------------------

local function Model_Rotate(m)
    local x = GetCursorPosition()
    m.rotation = (m.rotation or 0) + (x - (m.lastX or x)) * 0.012
    m.lastX = x
    m:SetFacing(m.rotation)
end

local function CreateModel(parent)
    local well = CreateFrame("Frame", nil, parent)
    local bg = well:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.35)

    local ok, model = pcall(CreateFrame, "DressUpModel", nil, well)
    if not ok or not model then model = CreateFrame("PlayerModel", nil, well) end
    model:SetAllPoints()
    model.rotation = 0
    model:EnableMouse(true)
    model:EnableMouseWheel(true)
    -- OnUpdate solo mientras se arrastra (nada de OnUpdate permanente)
    model:SetScript("OnMouseDown", function(m, button)
        if button == "LeftButton" then
            m.lastX = GetCursorPosition()
            m:SetScript("OnUpdate", Model_Rotate)
        end
    end)
    model:SetScript("OnMouseUp", function(m) m:SetScript("OnUpdate", nil) end)
    model:SetScript("OnHide", function(m) m:SetScript("OnUpdate", nil) end)
    model:SetScript("OnMouseWheel", function(m, delta)
        if not m.SetCamDistanceScale then return end
        m.zoom = math.max(0.6, math.min(1.6, (m.zoom or 1) - delta * 0.08))
        m:SetCamDistanceScale(m.zoom)
    end)
    well.model = model

    -- Si no se puede mostrar el modelo de un amigo, se muestra el ícono de su clase.
    well.classIcon = well:CreateTexture(nil, "ARTWORK")
    well.classIcon:SetSize(96, 96)
    well.classIcon:SetPoint("CENTER")
    well.classIcon:Hide()

    well.hint = well:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    well.hint:SetPoint("BOTTOM", 0, 6)
    well.hint:SetText(L.DRAG_TO_ROTATE)
    return well
end

local function SetClassIcon(texture, classFile)
    if not classFile then return texture:SetTexture(134400) end
    local atlas = "classicon-" .. classFile:lower()
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
        texture:SetAtlas(atlas)
    else
        local name = classFile:sub(1, 1) .. classFile:sub(2):lower() -- "WARRIOR" -> "Warrior"
        texture:SetTexture("Interface\\Icons\\ClassIcon_" .. name)
    end
end

---------------------------------------------------------------------------
-- Vista
---------------------------------------------------------------------------

local View = {}
View.__index = View

local function CycleOverride(key, cycle)
    local current = ns.addon.db.char.override[key]
    local nextIndex = 1
    for i, value in ipairs(cycle) do
        if value == current then nextIndex = i % #cycle + 1 end
    end
    ns.Player:SetOverride(key, cycle[nextIndex])
end

local function AddCycleTooltip(button)
    button:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(L.BTN_TOOLTIP_CYCLE, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    button:HookScript("OnLeave", Row_OnLeave)
end

-- opts.live: tooltips del item real del jugador (bolsa/slot). opts.editable: botones de rol/stat.
function GearView:Create(parent, opts)
    opts = opts or {}
    local view = setmetatable({ live = opts.live, editable = opts.editable, bagRows = {}, slots = {}, slotIlvl = {} }, View)

    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints()
    view.frame = frame

    -- Cabecera
    view.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    view.title:SetPoint("TOPLEFT", 4, -4)
    view.subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    view.subtitle:SetPoint("TOPLEFT", view.title, "BOTTOMLEFT", 0, -4)
    view.roleLine = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    view.roleLine:SetPoint("TOPLEFT", view.subtitle, "BOTTOMLEFT", 0, -4)
    view.updated = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    view.updated:SetPoint("TOPRIGHT", -4, -6)

    if view.editable then
        view.statButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        view.statButton:SetSize(130, 22)
        view.statButton:SetPoint("TOPRIGHT", view.updated, "BOTTOMRIGHT", 0, -6)
        view.statButton:SetScript("OnClick", function() CycleOverride("mainStat", STAT_CYCLE) end)
        AddCycleTooltip(view.statButton)

        view.roleButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        view.roleButton:SetSize(130, 22)
        view.roleButton:SetPoint("RIGHT", view.statButton, "LEFT", -6, 0)
        view.roleButton:SetScript("OnClick", function() CycleOverride("role", ROLE_CYCLE) end)
        AddCycleTooltip(view.roleButton)

        -- "Compartir mi inventario con amigos"
        -- En la fila de los botones, a su izquierda: "Compartir mis bolsas [x]"
        local share = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
        share:SetSize(22, 22)
        share:SetPoint("RIGHT", view.roleButton, "LEFT", -10, 0)
        local templateLabel = share.text or share.Text
        if templateLabel then templateLabel:SetText("") end
        local label = share:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("RIGHT", share, "LEFT", -2, 0)
        label:SetText(L.SHARE_BAGS)
        share:SetScript("OnClick", function(self) ns.Sync:SetShareBags(self:GetChecked()) end)
        share:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText(L.SHARE_BAGS_TOOLTIP, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        share:HookScript("OnLeave", Row_OnLeave)
        view.shareCheck = share
    end

    -- Ficha de personaje: dos columnas de slots, modelo 3D en el centro y armas abajo
    local doll = CreateFrame("Frame", nil, frame)
    doll:SetPoint("TOPLEFT", 0, -HEADER_HEIGHT)
    doll:SetPoint("BOTTOMLEFT")
    doll:SetWidth(DOLL_WIDTH)
    view.doll = doll

    local step = SLOT_SIZE + SLOT_GAP
    local function place(list, x)
        for i, slotID in ipairs(list) do
            local b = CreateSlotButton(doll, slotID)
            b:SetPoint("TOPLEFT", x, -(i - 1) * step)
            b.live = view.live
            view.slots[slotID] = b
        end
    end
    place(DOLL_LEFT, 0)
    place(DOLL_RIGHT, DOLL_WIDTH - SLOT_SIZE)
    local columnHeight = #DOLL_LEFT * step - SLOT_GAP
    local bottomWidth = #DOLL_BOTTOM * step - SLOT_GAP
    for i, slotID in ipairs(DOLL_BOTTOM) do
        local b = CreateSlotButton(doll, slotID)
        b:SetPoint("TOPLEFT", (DOLL_WIDTH - bottomWidth) / 2 + (i - 1) * step, -columnHeight - 10)
        b.live = view.live
        view.slots[slotID] = b
    end

    view.modelWell = CreateModel(doll)
    view.modelWell:SetPoint("TOPLEFT", step, 0)
    view.modelWell:SetSize(DOLL_WIDTH - 2 * step, columnHeight)

    view.avgIlvl = doll:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    view.avgIlvl:SetPoint("TOP", doll, "TOPLEFT", DOLL_WIDTH / 2, -columnHeight - SLOT_SIZE - 20)

    -- Columna derecha: equipables en bolsas (con scroll)
    local rightHeader = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    rightHeader:SetPoint("TOPLEFT", doll, "TOPRIGHT", 20, 0)
    view.rightHeader = rightHeader

    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", rightHeader, "BOTTOMLEFT", 0, -6)
    scroll:SetPoint("BOTTOMLEFT", doll, "BOTTOMRIGHT", 20, 0)
    scroll:SetWidth(RIGHT_WIDTH)
    view.bagScroll = scroll
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(RIGHT_WIDTH, 1)
    scroll:SetScrollChild(content)
    view.bagContent = content

    view.emptyBags = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    view.emptyBags:SetPoint("TOPLEFT", 4, -4)
    view.emptyBags:SetText(L.NO_BAG_ITEMS)

    return view
end

function View:RefreshHeader(snap, info)
    local shortName = snap.name and snap.name:match("^[^-]+") or "?"
    if type(snap.surname) == "string" and snap.surname ~= "" then
        shortName = shortName .. " " .. snap.surname
    end
    self.title:SetText(ClassColored(snap.class, shortName))

    local className = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[snap.class]) or snap.class or "?"
    local parts = { className }
    if snap.tree then parts[#parts + 1] = L["TREE_" .. snap.tree] end
    parts[#parts + 1] = L.LEVEL:format(snap.level or 0)
    self.subtitle:SetText(table.concat(parts, "  ·  "))

    local roleText = ("%s: |cffffffff%s|r"):format(L.ROLE, L["ROLE_" .. tostring(snap.role)])
    local statText = ("%s: |cffffffff%s|r"):format(L.MAIN_STAT, L["STAT_" .. tostring(snap.mainStat)])
    if info then
        roleText = roleText .. (" |cff888888(%s)|r"):format(L["SOURCE_" .. info.roleSource])
        statText = statText .. (" |cff888888(%s)|r"):format(L["SOURCE_" .. info.statSource])
    end
    self.roleLine:SetText(roleText .. "     " .. statText)

    if self.live then
        self.updated:SetText(L.SCANNED_AT:format(date("%H:%M:%S", snap.ts)))
    else
        self.updated:SetText(L.UPDATED_AGO:format(ns.FormatAgo(time() - snap.ts)))
    end

    if self.editable then
        local override = ns.addon.db.char.override
        self.roleButton:SetText(L.BTN_CYCLE_ROLE:format(override.role and L["ROLE_" .. override.role] or L.AUTO))
        self.statButton:SetText(L.BTN_CYCLE_STAT:format(override.mainStat and L["STAT_" .. override.mainStat] or L.AUTO))
        self.shareCheck:SetChecked(ns.Sync:ShareBags())
    end
end

-- Nivel de item promedio como en el juego: slots vacíos cuentan 0; con un arma a dos manos, la mano izquierda
-- cuenta como esa arma.
function View:UpdateAverage()
    local snap = self.snap
    if not snap then return end
    local sum, count = 0, 0
    for _, slotID in ipairs(AVG_SLOTS) do
        if slotID ~= 18 or GetSlotInfo(18).exists or snap.equipped[18] then
            local ilvl = self.slotIlvl[slotID]
            if slotID == 17 and not snap.equipped[17] and self.twoHander then ilvl = self.slotIlvl[16] end
            if ilvl == nil then -- todavía cargando
                self.avgIlvl:SetText("")
                return
            end
            sum, count = sum + ilvl, count + 1
        end
    end
    self.avgIlvl:SetText(count > 0 and L.AVG_ILVL:format(sum / count) or "")
end

function View:RefreshEquipped(snap)
    local mainHand = snap.equipped[16]
    self.twoHander = mainHand and select(4, C_Item.GetItemInfoInstant(mainHand)) == "INVTYPE_2HWEAPON" or false
    self.slotIlvl = {}
    for slotID, b in pairs(self.slots) do
        local link = snap.equipped[slotID]
        -- Un slot que el cliente no tiene (p. ej. rango en retail) solo se muestra si trae item.
        b:SetShown(link ~= nil or GetSlotInfo(slotID).exists)
        SetSlotItem(b, link, function(ilvl)
            self.slotIlvl[slotID] = ilvl
            self:UpdateAverage()
        end)
    end
    self:UpdateAverage()
end

-- Modelo: el propio se toma del personaje; el de un amigo se arma con su raza/sexo y su equipo.
function View:RefreshModel(snap)
    local well = self.modelWell
    local model = well.model
    if self.live then
        well.classIcon:Hide()
        model:Show()
        if model.SetUnit then model:SetUnit("player") end
        model:SetFacing(model.rotation or 0)
        return
    end

    local parts = { tostring(snap.race), tostring(snap.sex) }
    for _, slotID in ipairs(AVG_SLOTS) do parts[#parts + 1] = snap.equipped[slotID] or "" end
    local signature = table.concat(parts, "|")
    if signature == self.modelSignature then return end
    self.modelSignature = signature

    -- VERIFICAR EN FOREVER: DressUpModel:SetCustomRace(raceID, sexo 0/1)
    local ok = snap.race and model.SetCustomRace and pcall(model.SetCustomRace, model, snap.race, snap.sex == 3 and 1 or 0)
    if ok then
        well.classIcon:Hide()
        model:Show()
        if model.Undress then model:Undress() end
        for _, link in pairs(snap.equipped) do pcall(model.TryOn, model, link) end
        model:SetFacing(model.rotation or 0)
    else
        model:Hide()
        SetClassIcon(well.classIcon, snap.class)
        well.classIcon:Show()
    end
end

function View:RefreshBags(snap)
    local bags = snap.bags
    for i, item in ipairs(bags) do
        local row = self.bagRows[i]
        if not row then
            row = CreateRow(self.bagContent, RIGHT_WIDTH, 0, self.live)
            row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
            row.info:SetWidth(BAG_INFO_WIDTH)
            self.bagRows[i] = row
        end
        row.live = self.live
        row.bag, row.slot = item.bag, item.slot
        SetRowItem(row, item.link)

        local _, _, _, equipLoc = C_Item.GetItemInfoInstant(item.link)
        local bind = BIND_TEXT[item.bind] or BIND_TEXT.UNKNOWN
        local slotName = equipLoc and _G[equipLoc]
        row.info:SetText((slotName and (slotName .. " · ") or "") .. bind[2] .. bind[1] .. "|r")
        if row.badge then
            local matches = item.tradeable and ns.Matches:Get(item.link) or nil
            row.badge.matches = matches
            row.badge.link = item.link
            row.badge:SetShown(matches ~= nil)
        end
        row:Show()
    end
    for i = #bags + 1, #self.bagRows do
        self.bagRows[i]:Hide()
        self.bagRows[i].token = nil
    end
    local contentHeight = #bags * ROW_HEIGHT
    self.bagContent:SetHeight(math.max(1, contentHeight))
    -- La barra de scroll solo se muestra si la lista no cabe.
    local scroll = self.bagScroll
    local scrollBar = scroll.ScrollBar or (scroll:GetName() and _G[scroll:GetName() .. "ScrollBar"])
    if scrollBar then
        local needsScroll = contentHeight > scroll:GetHeight()
        scrollBar:SetShown(needsScroll)
        if not needsScroll then scroll:SetVerticalScroll(0) end
    end
    self.emptyBags:SetText(snap.sharedBags == false and L.BAGS_NOT_SHARED or L.NO_BAG_ITEMS)
    self.emptyBags:SetShown(#bags == 0)
    self.rightHeader:SetText(("%s  |cff888888(%d · %s)|r"):format(L.BAG_ITEMS, #bags,
        L.TRADEABLE_COUNT:format(ns.Snapshot.CountTradeable(snap))))
end

-- info (opcional): metadatos de ns.Player:GetInfo() para mostrar de dónde sale el rol/stat.
function View:SetSnapshot(snap, info)
    self.snap = snap
    if not snap then
        self.title:SetText(L.WAITING_SCAN)
        self.subtitle:SetText("")
        self.roleLine:SetText("")
        self.updated:SetText("")
        return
    end
    self:RefreshHeader(snap, info)
    self:RefreshEquipped(snap)
    self:RefreshModel(snap)
    self:RefreshBags(snap)
end
