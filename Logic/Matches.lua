-- GearLink - cruza mis items intercambiables con los snapshots guardados de mis contactos.
-- Resultado: para cada item de mis bolsas, la lista de amigos a los que les sirve (con motivo y puntuación).
-- Se recalcula (con debounce) cuando cambia mi inventario, llega un snapshot de un amigo o cambian los contactos.
local _, ns = ...
local L = ns.L
local GearLink = ns.addon
local Snapshot = ns.Snapshot

local Matches = GearLink:NewModule("Matches", "AceEvent-3.0")
ns.Matches = Matches

local RUN_DELAY = 0.3

local results = {}      -- itemString -> { { key, name, score, reason, slot, online }, ... } (mejor primero)
local loadRequested = {} -- link -> true (pedido una vez por sesión)
local knownBagItems     -- itemString -> true: lo que había en mis bolsas (nil hasta el primer cálculo)
local pendingNew = {}   -- itemString -> GetTime(): items recién llegados aún sin evaluar (para el aviso)

-- Items de mis bolsas para los que hay al menos un amigo (nil si ninguno).
function Matches:Get(link)
    local key = Snapshot.ToItemString(link)
    return key and results[key] or nil
end

local function RequestLoad(link)
    if loadRequested[link] then return end
    loadRequested[link] = true
    local item = Item:CreateFromItemLink(link)
    if item:IsItemEmpty() then return end
    item:ContinueOnItemLoad(function() Matches:RequestRun() end)
end

-- Contactos con la casilla "Sugerir" marcada:
--   con snapshot (usan GearLink)  -> { snap }           : se compara contra su equipo
--   sin snapshot pero clase/nivel -> { class, level }   : solo "puede usarlo" (para regalar)
local function FriendTargets()
    local list = {}
    local snapshots = GearLink.db.global.friendSnapshots
    for key, c in pairs(ns.Friends.contacts) do
        if ns.Friends:IsTracked(key) then
            local snap = snapshots[key]
            if snap then
                list[#list + 1] = { key = key, contact = c, snap = snap }
            else
                local view = ns.Friends:GetView(c)
                if view.class and view.level then
                    list[#list + 1] = { key = key, contact = c, class = view.class, level = view.level }
                end
            end
        end
    end
    return list
end

-- Evalúa un item para un destino de FriendTargets().
local function EvaluateFor(link, f)
    if f.snap then return ns.Upgrade:Evaluate(link, f.snap) end
    return ns.Upgrade:EvaluateUsable(link, f.class, f.level)
end

function Matches:Run()
    local mine = ns.Scanner:GetSnapshot()
    if not mine then return end
    local friends = FriendTargets()
    local newResults = {}

    for _, item in ipairs(mine.bags) do
        local itemKey = Snapshot.ToItemString(item.link)
        local reserved = itemKey and ns.Deliveries:GetReservation(itemKey)
        if item.tradeable and reserved then
            -- Oferta aceptada: el item queda reservado para ese amigo (pendiente de enviar por correo).
            local c = ns.Friends:GetContact(reserved.key)
            newResults[itemKey] = { {
                key = reserved.key, name = reserved.display, score = 1e6, reason = L.RESERVED_REASON,
                reserved = true, online = c and (c.hasAddonSession or c.online) and true or false,
            } }
        elseif item.tradeable and itemKey and not newResults[itemKey] then
            local list = {}
            for _, f in ipairs(friends) do
                local isUpgrade, score, reason, slot = EvaluateFor(item.link, f)
                if isUpgrade == nil then
                    -- Faltan datos: cargar el item y lo que el amigo lleva equipado, y reintentar.
                    RequestLoad(item.link)
                    for _, link in pairs(f.snap and f.snap.equipped or {}) do RequestLoad(link) end
                elseif isUpgrade then
                    local view = ns.Friends:GetView(f.contact)
                    list[#list + 1] = {
                        key = f.key, name = view.displayName, score = score, reason = reason, slot = slot,
                        online = (f.contact.hasAddonSession or f.contact.online) and true or false,
                        giftOnly = f.snap == nil,
                    }
                end
            end
            if #list > 0 then
                table.sort(list, function(a, b) return a.score > b.score end)
                newResults[itemKey] = list
            end
        end
    end
    results = newResults

    self:CheckNewLoot(mine)
    GearLink:SendMessage(ns.MSG_MATCHES_UPDATED)
end

function Matches:RequestRun()
    ns.Debounce("matches", RUN_DELAY, function() self:Run() end)
end

---------------------------------------------------------------------------
-- Aviso de loot nuevo que le sirve a un amigo
---------------------------------------------------------------------------

function Matches:CheckNewLoot(mine)
    local current = {}
    for _, item in ipairs(mine.bags) do
        local key = Snapshot.ToItemString(item.link)
        if key then current[key] = item.link end
    end
    if knownBagItems then
        for key in pairs(current) do
            if not knownBagItems[key] then pendingNew[key] = GetTime() end
        end
    end
    knownBagItems = current

    local now = GetTime()
    for key, at in pairs(pendingNew) do
        if not current[key] or now - at > 30 then
            pendingNew[key] = nil
        elseif results[key] then
            pendingNew[key] = nil
            if GearLink.db.global.notifyLoot then
                local names = {}
                for i, m in ipairs(results[key]) do
                    if i > 3 then names[#names + 1] = "..." break end
                    names[#names + 1] = m.name
                end
                ns.Toast:Show(current[key], L.TOAST_TITLE, L.TOAST_TEXT:format(table.concat(names, ", ")))
            end
        end
    end
end

---------------------------------------------------------------------------
-- Diagnóstico: /gl eval
---------------------------------------------------------------------------

function Matches:PrintEvaluation()
    local mine = ns.Scanner:GetSnapshot()
    local friends = FriendTargets()
    if not mine then return GearLink:Print(L.NO_SNAPSHOT) end
    if #friends == 0 then return GearLink:Print(L.EVAL_NO_FRIENDS) end
    local any = false
    for _, item in ipairs(mine.bags) do
        any = true
        local data = ns.Upgrade:GetItemData(item.link)
        print(("%s  |cffaaaaaa(%s %s)|r %s"):format(item.link, L.REQ_LEVEL, data and tostring(data.minLevel) or "?",
            item.tradeable and "" or ("|cff808080(" .. L.TRADE_SOULBOUND .. ")|r")))
        for _, f in ipairs(friends) do
            local isUpgrade, score, reason = EvaluateFor(item.link, f)
            local view = ns.Friends:GetView(f.contact)
            local name = ("%s (nv %s)"):format(view.displayName, tostring(f.snap and f.snap.level or f.level))
            local verdict = isUpgrade == nil and "|cffffd200…|r" or (isUpgrade and "|cff1eff00SÍ|r" or "|cffff5555no|r")
            print(("     %s %s: %s %s"):format(verdict, name, tostring(reason), isUpgrade and ("(%.1f)"):format(score) or ""))
        end
    end
    if not any then GearLink:Print(L.NO_BAG_ITEMS) end
end

function Matches:OnEnable()
    self:RegisterMessage(ns.MSG_SNAPSHOT_UPDATED, "RequestRun")
    self:RegisterMessage(ns.MSG_FRIEND_SNAPSHOT, "RequestRun")
    self:RegisterMessage(ns.MSG_CONTACTS_UPDATED, "RequestRun")
end
