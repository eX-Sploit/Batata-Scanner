-- BatataScanner: GuildHQ's portrait shell and right-side navigation.
local ADDON,
    NS = ...

local UI = {}
NS.UI = UI

local Widgets = NS.Widgets
local frame
local pages          = {}
local activePage     = "Scanner"
local refreshQueued  = false

function UI:SyncEscape()
    if self.escapeRouter then
        self.escapeRouter:Sync()
    end
end

function UI:UpdateFooterInset()
    if not frame then
        return
    end
    local height = 26
    for footerIndex, footer in ipairs(Widgets.footerRoots) do
        if footer:IsVisible() then
            height = math.max(height, footer.batataFooterHeight or 44)
        end
    end
    frame.Inset:SetPoint("BOTTOMRIGHT", -6, height)
end

local function SavePosition()
    local point,
        relativeFrame,
        relativePoint,
        offsetX,
        offsetY = frame:GetPoint()
    local window = NS.db.window
    window.point          = point
    window.relativePoint  = relativePoint
    window.x              = offsetX
    window.y              = offsetY
end

function UI:ApplySize()
    if not frame then
        return
    end
    local width = self.minimized and math.max(742, NS.ScannerPanel.minWidth or 0) or 800
    frame:SetSize(
        math.max(1, math.min(width, UIParent:GetWidth() - 64)),
        math.max(1, math.min(self.minimized and 480 or 790, UIParent:GetHeight()))
    )
    NS.ScannerPanel:Layout()
    self:Refresh()
end

function UI:SelectPage(name)
    local selected = pages[name]
    if not selected then
        return false
    end
    Widgets.CommitFocus(frame)
    activePage = name
    self.pageTitle:SetText(selected.title)
    frame:SetPortraitToAsset(selected.icon)
    for pageName, page in pairs(pages) do
        page.root:SetShown(pageName == name)
        page.tab:SetSelected(pageName == name)
    end
    self:UpdateFooterInset()
    self:SyncEscape()
    self:Refresh()
    return true
end

local function QueueRefresh()
    if not frame or not frame:IsShown() or refreshQueued then
        return
    end
    refreshQueued = true
    C_Timer.After(0.1, function()
        refreshQueued = false
        UI:Refresh()
    end)
end

local function Build()
    if frame then
        return
    end
    frame     = CreateFrame("Frame", "BatataScanner_MainFrame", UIParent, "PortraitFrameTemplateMinimizable")
    UI.frame  = frame
    frame:SetTitle("BatataScanner")
    frame:SetTitleOffsets(58, -58)
    frame:GetTitleText():SetJustifyH("CENTER")
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:SetResizable(false)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    frame:SetClampedToScreen(true)
    frame:SetClampRectInsets(0, 64, 0, 0)
    frame:SetFrameStrata("HIGH")
    frame:Hide()
    frame.Inset = Widgets.Inset(frame)
    frame.Inset:SetPoint("TOPLEFT", 4, -83)
    frame.Inset:SetPoint("BOTTOMRIGHT", -6, 44)
    frame.Inset.NineSlice:Hide()
    frame.Inset.batataBorder:Hide()
    frame.TopTileStreaks:Hide()
    local background  = frame:CreateTexture(nil, "BACKGROUND", nil, -3)
    local divider     = frame.Inset:CreateTexture(nil, "BORDER")
    Widgets.StyleProfessionsBand(background, divider)
    background:SetPoint("TOPLEFT", 3, -21)
    background:SetPoint("BOTTOMRIGHT", frame.Inset, "TOPRIGHT", 0, 0)
    divider:SetPoint("TOPLEFT", frame.Inset, "TOPLEFT")
    divider:SetPoint("TOPRIGHT", frame.Inset, "TOPRIGHT")

    UI.pageTitle = Widgets.Label(frame, "Scanner", "GameFontNormalLarge")
    UI.pageTitle:SetPoint("TOPLEFT", 74, -32)
    UI.pageTitle:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -280, -32)
    UI.pageTitle:SetWordWrap(false)
    local context = Widgets.Label(frame, NS.context.realm .. " / " .. NS.context.faction, "GameFontDisableSmall")
    context:SetPoint("TOPRIGHT", -28, -36)
    frame.CloseButton:SetScript("OnClick", function()
        frame:Hide()
    end)

    local scannerRoot = CreateFrame("Frame", nil, frame)
    scannerRoot:SetPoint("TOPLEFT", 0, -84)
    scannerRoot:SetPoint("BOTTOMRIGHT", 0, 26)
    local censusRoot = CreateFrame("Frame", nil, frame)
    censusRoot:SetPoint("TOPLEFT", 0, -60)
    censusRoot:SetPoint("BOTTOMRIGHT", 0, 26)
    censusRoot:Hide()
    pages.Scanner  = { title = "Scanner", icon = "Interface\\Icons\\Spell_Nature_Farsight", root = scannerRoot }
    pages.Census   = { title = "Realm census", icon = "Interface\\Icons\\inv_misc_map02", root = censusRoot }
    frame:SetSize(800, 790)
    NS.ScannerPanel:Build(scannerRoot, frame)
    NS.CensusPanel:Build(censusRoot, frame)

    frame.Tabs = {}
    local previousTab
    for pageIndex, name in ipairs({ "Scanner", "Census" }) do
        local pageName  = name
        local page      = pages[name]
        local tab       = Widgets.IconTab(frame, name, page.icon)
        page.tab = tab
        tab:SetID(pageIndex)
        if previousTab then
            tab:SetPoint("TOPLEFT", previousTab, "BOTTOMLEFT", 0, -2)
        else
            tab:SetPoint("TOPLEFT", frame, "TOPRIGHT", 0, -60)
        end
        tab:SetCustomOnMouseUpHandler(function(button, mouseButton, upInside)
            if mouseButton == "LeftButton" and upInside then
                UI:SelectPage(pageName)
            end
        end)
        frame.Tabs[#frame.Tabs + 1]  = tab
        previousTab                  = tab
    end

    local modeButton = CreateFrame("Button", nil, frame, "UIPanelHideButtonNoScripts")
    UI.modeButton = modeButton
    modeButton:SetSize(frame.CloseButton:GetSize())
    modeButton:SetPoint("RIGHT", frame.CloseButton, "LEFT", 0, 0)
    local function SetMode(minimized)
        Widgets.CommitFocus(frame)
        UI.minimized            = minimized
        NS.db.window.minimized  = minimized
        local atlas = minimized and "RedButton-Expand" or "RedButton-Condense"
        modeButton:GetNormalTexture():SetAtlas(atlas)
        modeButton:GetPushedTexture():SetAtlas(atlas .. "-Pressed")
        modeButton
            :GetDisabledTexture()
            :SetAtlas(minimized and "RedButton-Expand-Disabled" or "RedButton-Condense-disabled")
        UI:ApplySize()
    end
    modeButton:SetScript("OnClick", function()
        SetMode(not UI.minimized)
    end)
    Widgets.Tooltip(modeButton, "Window size", "Switch between the compact and expanded window.")
    local window   = NS.db.window
    local anchors  = {
        TOPLEFT      = true,
        TOP          = true,
        TOPRIGHT     = true,
        LEFT         = true,
        CENTER       = true,
        RIGHT        = true,
        BOTTOMLEFT   = true,
        BOTTOM       = true,
        BOTTOMRIGHT  = true,
    }
    if
        anchors[window.point]
        and anchors[window.relativePoint]
        and type(window.x) == "number"
        and type(window.y) == "number"
    then
        frame:ClearAllPoints()
        frame:SetPoint(window.point, UIParent, window.relativePoint, window.x, window.y)
    end
    frame:HookScript("OnHide", function()
        Widgets.CommitFocus(frame)
        NS.ScannerPanel.scanSettings:Hide()
        GameTooltip:Hide()
        SavePosition()
        UI:SyncEscape()
    end)
    frame:HookScript("OnShow", QueueRefresh)
    UISpecialFrames[#UISpecialFrames + 1] = "BatataScanner_MainFrame"
    local proxyName  = "BatataScanner_Dismiss"
    local proxy      = CreateFrame("Frame", proxyName, UIParent)
    proxy:SetSize(1, 1)
    proxy:SetPoint("CENTER")
    proxy:Hide()
    local router = {}
    UI.escapeRouter = router
    function router:Sync()
        local panel   = NS.ScannerPanel
        local active  = frame:IsShown()
            and activePage == "Scanner"
            and (panel.scanSettings:IsShown() or panel.searching or panel.selectedKey ~= nil)
        for frameIndex, name in ipairs(UISpecialFrames) do
            if name == "BatataScanner_MainFrame" or name == proxyName then
                UISpecialFrames[frameIndex] = active and proxyName or "BatataScanner_MainFrame"
            end
        end
        self.suppress = true
        proxy:SetShown(active and true or false)
        self.suppress = false
    end
    proxy:SetScript("OnHide", function()
        if not router.suppress and frame:IsShown() then
            NS.ScannerPanel:Escape()
            router:Sync()
        end
    end)
    for frameIndex = #UISpecialFrames, 1, -1 do
        if UISpecialFrames[frameIndex] == "BatataScanner_ScanSettings" then
            table.remove(UISpecialFrames, frameIndex)
        end
    end
    SetMode(window.minimized ~= false)
    UI:SelectPage(activePage)
end

function UI:Refresh()
    if not frame or not frame:IsShown() or not NS.ready then
        return
    end
    if activePage == "Scanner" then
        NS.ScannerPanel:Refresh()
    else
        NS.CensusPanel:Refresh()
    end
end

function UI:Show()
    if not NS.ready then
        return
    end
    Build()
    frame:Show()
    self:Refresh()
end

function UI:Toggle()
    if frame and frame:IsShown() then
        frame:Hide()
    else
        self:Show()
    end
end

NS.On("DATA_UPDATED", function()
    NS.ScannerPanel:Invalidate()
    QueueRefresh()
end)
NS.On("SCAN_STATUS_CHANGED", QueueRefresh)
