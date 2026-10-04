-- GearLink - aviso propio (toast) con sonido: "¡Este loot le sirve a ...!". No toca los toasts de Blizzard.
local _, ns = ...

local Toast = {}
ns.Toast = Toast

local SHOW_TIME = 6

local function Create()
    local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    f:SetSize(340, 58)
    f:SetPoint("TOP", 0, -140)
    f:SetFrameStrata("HIGH")
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0, 0, 0, 0.85)
    f:SetBackdropBorderColor(0.3, 0.8, 1, 1)

    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(38, 38)
    f.icon:SetPoint("LEFT", 10, 0)
    f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 10, -2)
    f.title:SetPoint("RIGHT", -10, 0)
    f.title:SetJustifyH("LEFT")

    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.text:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -4)
    f.text:SetPoint("RIGHT", -10, 0)
    f.text:SetJustifyH("LEFT")
    f.text:SetWordWrap(true)

    local fade = f:CreateAnimationGroup()
    local alpha = fade:CreateAnimation("Alpha")
    alpha:SetFromAlpha(1)
    alpha:SetToAlpha(0)
    alpha:SetDuration(0.8)
    fade:SetScript("OnFinished", function() f:Hide() end)
    f.fade = fade

    -- Click para cerrarlo antes de tiempo
    f:EnableMouse(true)
    f:SetScript("OnMouseUp", function() f.fade:Stop() f:Hide() end)
    f:Hide()
    return f
end

-- link: item a mostrar (ícono); title/text: textos ya formateados.
function Toast:Show(link, title, text)
    self.frame = self.frame or Create()
    local f = self.frame
    f.fade:Stop()
    f:SetAlpha(1)
    f.icon:SetTexture(select(5, C_Item.GetItemInfoInstant(link)) or 134400)
    f.title:SetText(title)
    f.text:SetText(text)
    f:Show()

    if self.timer then self.timer:Cancel() end
    self.timer = C_Timer.NewTimer(SHOW_TIME, function() f.fade:Play() end)

    local sound = SOUNDKIT and (SOUNDKIT.UI_EPICLOOT_TOAST or SOUNDKIT.RAID_WARNING)
    if sound then PlaySound(sound) end
end
