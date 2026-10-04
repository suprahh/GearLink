-- GearLink - botón del minimapa (LibDBIcon + LibDataBroker) y entrada en el compartimento de addons.
-- Click izquierdo: abrir/cerrar la ventana. Click derecho: abrir directamente la pestaña Amigos.
-- Se arrastra alrededor del minimapa; /gl minimap lo oculta o lo muestra.
local _, ns = ...
local L = ns.L
local GearLink = ns.addon

local MinimapButton = GearLink:NewModule("MinimapButton")
ns.MinimapButton = MinimapButton

local ICON = "Interface\\Icons\\INV_Misc_Bag_10"

local function CountSummary()
    local online = 0
    for _, c in pairs(ns.Friends.contacts) do
        if c.hasAddonSession then online = online + 1 end
    end
    local gifts = 0
    local snap = ns.Scanner:GetSnapshot()
    for _, item in ipairs(snap and snap.bags or {}) do
        if item.tradeable and ns.Matches:Get(item.link) then gifts = gifts + 1 end
    end
    return online, gifts
end

function MinimapButton:OnEnable()
    local LDB = LibStub("LibDataBroker-1.1", true)
    local LDBIcon = LibStub("LibDBIcon-1.0", true)
    if not (LDB and LDBIcon) then return end

    local broker = LDB:NewDataObject("GearLink", {
        type = "launcher",
        text = "GearLink",
        icon = ICON,
        OnClick = function(_, button)
            if button == "RightButton" then
                ns.MainFrame:Open("friends")
            else
                ns.MainFrame:Toggle()
            end
        end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine("GearLink |cff888888v" .. ns.VERSION .. "|r")
            local online, gifts = CountSummary()
            tooltip:AddLine(L.MINIMAP_ONLINE:format(online), 1, 1, 1)
            if gifts > 0 then tooltip:AddLine(L.MINIMAP_GIFTS:format(gifts), 0.3, 0.8, 1) end
            tooltip:AddLine(" ")
            tooltip:AddLine(L.MINIMAP_LEFT, 0.7, 0.7, 0.7)
            tooltip:AddLine(L.MINIMAP_RIGHT, 0.7, 0.7, 0.7)
        end,
    })

    -- LibDBIcon guarda en esta tabla la posición alrededor del minimapa y si está oculto.
    LDBIcon:Register("GearLink", broker, GearLink.db.global.minimap)
    -- Compartimento de addons (botón de Blizzard junto al minimapa en el cliente moderno).
    if LDBIcon.AddButtonToCompartment then LDBIcon:AddButtonToCompartment("GearLink") end
    self.icon = LDBIcon
end

function MinimapButton:Toggle()
    if not self.icon then return end
    local db = GearLink.db.global.minimap
    db.hide = not db.hide
    if db.hide then
        self.icon:Hide("GearLink")
        GearLink:Print(L.MINIMAP_HIDDEN)
    else
        self.icon:Show("GearLink")
        GearLink:Print(L.MINIMAP_SHOWN)
    end
end
