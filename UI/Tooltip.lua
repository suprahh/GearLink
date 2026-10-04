-- GearLink - línea extra en el tooltip de items: "Le sirve a: Pedro, Ana".
-- Usa TooltipDataProcessor (no modifica frames de bolsas de Blizzard ni de otros addons: funciona con
-- Baganator, etc., porque engancha el tooltip, no la bolsa).
local _, ns = ...
local L = ns.L

local MAX_NAMES = 4

local function GetTooltipLink(tooltip)
    if TooltipUtil and TooltipUtil.GetDisplayedItem then
        local _, link = TooltipUtil.GetDisplayedItem(tooltip)
        return link
    end
    if tooltip.GetItem then
        local _, link = tooltip:GetItem()
        return link
    end
end

local function OnItemTooltip(tooltip)
    if not tooltip or (tooltip.IsForbidden and tooltip:IsForbidden()) then return end
    local link = GetTooltipLink(tooltip)
    if type(link) ~= "string" or ns.IsSecret(link) then return end
    local matches = ns.Matches:Get(link)
    if not matches then return end

    local names = {}
    for i, m in ipairs(matches) do
        if i > MAX_NAMES then
            names[#names + 1] = L.AND_MORE:format(#matches - MAX_NAMES)
            break
        end
        names[#names + 1] = m.name
    end
    tooltip:AddLine(L.TOOLTIP_USEFUL_FOR:format(table.concat(names, ", ")), 0.3, 0.8, 1, true)
end

-- VERIFICAR EN FOREVER: /dump TooltipDataProcessor and Enum.TooltipDataType.Item  (Leatrix_Plus ya lo usa aquí)
if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)
end
