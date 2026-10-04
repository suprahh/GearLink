-- GearLink - escaneo del equipo equipado y de los items equipables en las bolsas.
-- Escanea por eventos con debounce; nunca en combate (se pospone con la cola de combate).
local _, ns = ...
local L = ns.L
local GearLink = ns.addon

local Scanner = GearLink:NewModule("Scanner", "AceEvent-3.0")
ns.Scanner = Scanner

local SCAN_DELAY = 0.15 -- segundos de debounce (criterio de aceptación: < 1 s)
local TRADE_WINDOW_RECHECK = 60 -- s entre reescaneos mientras haya items con ventana de intercambio

local FIRST_BAG = BACKPACK_CONTAINER or 0
local LAST_BAG = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4

-- Equipables que no son equipo de personaje.
local EXCLUDED_EQUIP_LOC = {
    [""] = true,
    INVTYPE_BAG = true,
    INVTYPE_QUIVER = true,
    INVTYPE_AMMO = true, -- munición: consumible, no es equipo que valga la pena ofrecer
    INVTYPE_NON_EQUIP_IGNORE = true,
}

---------------------------------------------------------------------------
-- Estado de intercambio leyendo el tooltip (constantes globales de texto, nunca strings en español)
---------------------------------------------------------------------------

local TRADE_WINDOW_PATTERN = ns.FormatToPattern(BIND_TRADE_TIME_REMAINING)

-- Textos que indican que el item ya no se puede dar a otro jugador.
local BOUND_TEXTS = {}
for _, key in ipairs({ "ITEM_SOULBOUND", "ITEM_ACCOUNTBOUND", "ITEM_BNETACCOUNTBOUND", "ITEM_BIND_TO_ACCOUNT",
    "ITEM_BIND_TO_BNETACCOUNT", "ITEM_ACCOUNTBOUND_UNTIL_EQUIP", "ITEM_BIND_QUEST" }) do
    local text = _G[key]
    if type(text) == "string" then BOUND_TEXTS[text] = true end
end

local function GetTooltipLines(bag, slot)
    if not (C_TooltipInfo and C_TooltipInfo.GetBagItem) then return nil end
    local data = C_TooltipInfo.GetBagItem(bag, slot)
    if not (data and data.lines and #data.lines > 0) then return nil end
    -- Clientes antiguos (10.0.x) necesitaban "SurfaceArgs" para rellenar leftText.
    if data.lines[1].leftText == nil and TooltipUtil and TooltipUtil.SurfaceArgs then
        for _, line in ipairs(data.lines) do TooltipUtil.SurfaceArgs(line) end
    end
    return data.lines
end

-- Devuelve: tradeable (bool), bind (string), needsData (bool: el tooltip no estaba listo)
local function GetTradeStatus(bag, slot, info)
    local lines = GetTooltipLines(bag, slot)
    local hasTradeWindow, hasBoundText, hasBoE = false, false, false
    if lines then
        for _, line in ipairs(lines) do
            local text = line.leftText
            if type(text) == "string" and not ns.IsSecret(text) then
                if TRADE_WINDOW_PATTERN and text:find(TRADE_WINDOW_PATTERN) then
                    hasTradeWindow = true
                elseif BOUND_TEXTS[text] then
                    hasBoundText = true
                elseif text == ITEM_BIND_ON_EQUIP or text == ITEM_BIND_ON_USE then
                    hasBoE = true
                end
            end
        end
    end

    -- Ligado pero dentro de la ventana de 2 h para dárselo a quien estuvo en el botín.
    if hasTradeWindow then return true, "TRADE_WINDOW", false end

    -- VERIFICAR EN FOREVER: ContainerItemInfo.isBound -> /dump C_Container.GetContainerItemInfo(0, 1)
    local bound = info.isBound
    if bound == nil then
        if not lines then return false, "UNKNOWN", true end
        bound = hasBoundText
    end
    if bound then return false, "SOULBOUND", false end
    return true, hasBoE and "BOE" or "UNBOUND", lines == nil
end

local function IsGear(link)
    if not C_Item.IsEquippableItem(link) then return false end
    local _, _, _, equipLoc = C_Item.GetItemInfoInstant(link)
    return equipLoc ~= nil and not EXCLUDED_EQUIP_LOC[equipLoc]
end

---------------------------------------------------------------------------
-- Escaneo
---------------------------------------------------------------------------

local loadRequested = {} -- link -> true: ya pedimos cargar este item; evita bucles de reescaneo

function Scanner:OnEnable()
    -- Último snapshot guardado: la ventana tiene algo que mostrar antes del primer escaneo.
    self.snapshot = GearLink.db.char.snapshot

    self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", "RequestScan")
    self:RegisterEvent("BAG_UPDATE_DELAYED", "RequestScan")
    self:RegisterEvent("PLAYER_LEVEL_UP", "RequestScan")
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnTalentEvent")
    -- Cambios de spec / talentos. Algunos pueden no existir en Forever: se registran solo si existen.
    for _, event in ipairs({ "PLAYER_SPECIALIZATION_CHANGED", "ACTIVE_TALENT_GROUP_CHANGED", "PLAYER_TALENT_UPDATE",
        "TRAIT_CONFIG_UPDATED", "TRAIT_CONFIG_LIST_UPDATED", "CHARACTER_POINTS_CHANGED" }) do
        ns.SafeRegisterEvent(self, event, "OnTalentEvent")
    end

    -- OnEnable corre en PLAYER_LOGIN.
    self:RequestScan()
end

function Scanner:OnTalentEvent()
    ns.Player:InvalidateTree()
    self:RequestScan()
end

function Scanner:RequestScan()
    ns.Debounce("scan", SCAN_DELAY, function()
        ns.RunOutOfCombat("scan", function() self:ScanNow(false) end)
    end)
end

function Scanner:ScanNow(verbose)
    if InCombatLockdown() then
        if verbose then GearLink:Print(L.SCAN_DEFERRED) end
        ns.RunOutOfCombat("scan", function() self:ScanNow(verbose) end)
        return
    end
    local started = debugprofilestop()

    local player = ns.Player:GetInfo()
    self.playerInfo = player

    local equipped = {}
    for slot = INVSLOT_FIRST_EQUIPPED, INVSLOT_LAST_EQUIPPED do
        local link = GetInventoryItemLink("player", slot)
        if link and not ns.IsSecret(link) then equipped[slot] = link end
    end

    local bags = {}
    for bag = FIRST_BAG, LAST_BAG do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            local link = info and info.hyperlink
            if link and not ns.IsSecret(link) and IsGear(link) then
                local tradeable, bind, needsData = GetTradeStatus(bag, slot, info)
                bags[#bags + 1] = {
                    link = link, count = info.stackCount or 1, bag = bag, slot = slot,
                    tradeable = tradeable, bind = bind,
                }
                -- El tooltip no estaba listo: cargamos el item y reescaneamos una vez.
                if needsData and not loadRequested[link] then
                    loadRequested[link] = true
                    Item:CreateFromBagAndSlot(bag, slot):ContinueOnItemLoad(function() self:RequestScan() end)
                end
            end
        end
    end
    -- Intercambiables primero; dentro de cada grupo, por posición en las bolsas.
    table.sort(bags, function(a, b)
        if a.tradeable ~= b.tradeable then return a.tradeable end
        if a.bag ~= b.bag then return a.bag < b.bag end
        return a.slot < b.slot
    end)

    local snap = ns.Snapshot.New(player, equipped, bags)
    local changed = not self.snapshot or self.snapshot.hash ~= snap.hash
    self.snapshot = snap
    GearLink.db.char.snapshot = snap

    if verbose then
        local nEquipped = 0
        for _ in pairs(equipped) do nEquipped = nEquipped + 1 end
        GearLink:Print(L.SCAN_SUMMARY:format(debugprofilestop() - started, nEquipped, #bags,
            ns.Snapshot.CountTradeable(snap), snap.hash, changed and L.HASH_CHANGED or L.HASH_SAME))
    else
        ns.Debug(("scan %.1f ms, hash %s%s"):format(debugprofilestop() - started, snap.hash, changed and " (cambió)" or ""))
    end

    -- La ventana de intercambio (2 h tras el loot) expira sin ningún evento: mientras haya items así, se reescanea
    -- cada minuto para que el indicador de oferta desaparezca a tiempo.
    local hasTradeWindow = false
    for _, item in ipairs(bags) do
        if item.bind == "TRADE_WINDOW" then hasTradeWindow = true break end
    end
    if hasTradeWindow and not self.tradeWindowTimer then
        self.tradeWindowTimer = C_Timer.NewTimer(TRADE_WINDOW_RECHECK, function()
            self.tradeWindowTimer = nil
            self:RequestScan()
        end)
    end

    -- Siempre se avisa a la UI: aunque el hash no cambie, los items pueden haberse movido de slot.
    GearLink:SendMessage(ns.MSG_SNAPSHOT_UPDATED, snap, changed)
end

function Scanner:GetSnapshot()
    return self.snapshot
end

-- Metadatos del último escaneo (roleSource/statSource) para la vista propia.
function Scanner:GetPlayerInfo()
    return self.playerInfo
end
