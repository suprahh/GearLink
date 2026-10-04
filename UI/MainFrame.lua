-- GearLink - ventana principal movible con pestañas.
-- Las pestañas se registran con MainFrame:RegisterTab() antes de que la ventana se cree (se crea al abrirla por
-- primera vez). La fase 2 agregará "Amigos" desde UI/FriendsTab.lua sin tocar este archivo.
local _, ns = ...
local L = ns.L

local MainFrame = {}
ns.MainFrame = MainFrame

local FRAME_NAME = "GearLinkMainFrame" -- nombre global necesario solo para cerrar con ESC (UISpecialFrames)
local WIDTH, HEIGHT = 820, 620
local ICON = "Interface\\Icons\\INV_Misc_Bag_10"

local tabs = {} -- { key, label, factory, container, object, button }

-- factory(container) -> objeto de la pestaña (opcional: object:OnShow())
function MainFrame:RegisterTab(key, label, factory)
    tabs[#tabs + 1] = { key = key, label = label, factory = factory }
end

local function SavePosition(frame)
    local point, _, relPoint, x, y = frame:GetPoint()
    local pos = ns.addon.db.global.window
    pos.point, pos.relPoint, pos.x, pos.y = point, relPoint, x, y
end

function MainFrame:SelectTab(index)
    local frame = self.frame
    for i, tab in ipairs(tabs) do
        if i == index then
            if not tab.object then tab.object = tab.factory(tab.container) or {} end
            tab.container:Show()
            if tab.object.OnShow then tab.object:OnShow() end
        else
            tab.container:Hide()
        end
    end
    PanelTemplates_SetTab(frame, index)
    ns.addon.db.global.window.tab = index
end

-- Retrato redondo del marco: el personaje (o el ícono del addon si no se puede).
function MainFrame:RefreshPortrait()
    local frame = self.frame
    if not (frame and frame.native) then return end
    if frame.SetPortraitToUnit then
        frame:SetPortraitToUnit("player")
    elseif frame.SetPortraitToAsset then
        frame:SetPortraitToAsset(ICON)
    end
end

-- Marco nativo (el mismo de las ventanas del juego: metal, retrato redondo y título). Si el cliente no tuviera la
-- plantilla, se usa el marco básico.
local function CreateWindow()
    local ok, frame = pcall(CreateFrame, "Frame", FRAME_NAME, UIParent, "PortraitFrameTemplate")
    if ok and frame then
        frame.native = true
        if frame.SetTitle then frame:SetTitle(L.ADDON_NAME .. " |cff888888v" .. ns.VERSION .. "|r") end
        -- Panel interior oscuro debajo del retrato
        local insetOk, inset = pcall(CreateFrame, "Frame", nil, frame, "InsetFrameTemplate")
        if insetOk and inset then
            inset:SetPoint("TOPLEFT", 6, -60)
            inset:SetPoint("BOTTOMRIGHT", -6, 6)
            frame.GLInset = inset
        end
        return frame
    end
    frame = CreateFrame("Frame", FRAME_NAME, UIParent, "BasicFrameTemplateWithInset")
    local title = frame.TitleText
    if not title then
        title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        title:SetPoint("TOP", 0, -5)
    end
    title:SetText(L.ADDON_NAME .. " |cff888888v" .. ns.VERSION .. "|r")
    return frame
end

function MainFrame:Create()
    local frame = CreateWindow()
    self.frame = frame
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        SavePosition(f)
    end)

    local pos = ns.addon.db.global.window
    frame:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)

    tinsert(UISpecialFrames, FRAME_NAME)

    -- Con el marco nativo el contenido empieza debajo del retrato redondo.
    local top = frame.native and -66 or -30
    frame.Tabs = {}
    for i, tab in ipairs(tabs) do
        local container = CreateFrame("Frame", nil, frame)
        container:SetPoint("TOPLEFT", 14, top)
        container:SetPoint("BOTTOMRIGHT", -14, 12)
        container:Hide()
        tab.container = container

        local button = CreateFrame("Button", nil, frame, "PanelTabButtonTemplate")
        button:SetID(i)
        button:SetText(tab.label)
        if i == 1 then
            button:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 8, 2)
        else
            button:SetPoint("LEFT", frame.Tabs[i - 1], "RIGHT", -12, 0)
        end
        button:SetScript("OnClick", function() MainFrame:SelectTab(i) end)
        if PanelTemplates_TabResize then PanelTemplates_TabResize(button, 0) end
        frame.Tabs[i] = button
        tab.button = button
    end
    PanelTemplates_SetNumTabs(frame, #tabs)

    frame:SetScript("OnShow", function()
        MainFrame:RefreshPortrait()
        local index = ns.addon.db.global.window.tab
        MainFrame:SelectTab((index and tabs[index]) and index or 1)
    end)
    frame:Hide()
end

-- Abre la ventana directamente en una pestaña (por clave: "mygear", "friends").
function MainFrame:Open(key)
    if not self.frame then self:Create() end
    for i, tab in ipairs(tabs) do
        if tab.key == key then ns.addon.db.global.window.tab = i end
    end
    if self.frame:IsShown() then
        self:SelectTab(ns.addon.db.global.window.tab)
    else
        self.frame:Show() -- OnShow selecciona la pestaña guardada
    end
end

function MainFrame:Toggle()
    if not self.frame then self:Create() end
    self.frame:SetShown(not self.frame:IsShown())
end

---------------------------------------------------------------------------
-- Pestaña "Mi equipo"
---------------------------------------------------------------------------

MainFrame:RegisterTab("mygear", L.TAB_MY_GEAR, function(container)
    local view = ns.GearView:Create(container, { live = true, editable = true })
    -- Cada pestaña lleva su propio AceEvent: AceEvent admite un solo handler por mensaje y por objeto.
    local tab = LibStub("AceEvent-3.0"):Embed({})

    function tab:Refresh()
        view:SetSnapshot(ns.Scanner:GetSnapshot(), ns.Scanner:GetPlayerInfo())
    end

    function tab:OnShow()
        self:Refresh()
    end

    -- Solo se repinta si está visible; si no, se repinta al volver a mostrarse.
    tab:RegisterMessage(ns.MSG_SNAPSHOT_UPDATED, function()
        if container:IsVisible() then tab:Refresh() end
    end)
    tab:RegisterMessage(ns.MSG_MATCHES_UPDATED, function()
        if container:IsVisible() then tab:Refresh() end
    end)

    return tab
end)
