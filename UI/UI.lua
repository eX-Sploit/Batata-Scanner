-- Batata Scanner: portrait shell and right-side navigation.
-- Addon folder name and the private namespace table shared by all addon files.
local ADDON,
    NS = ...

-- Main window controller: portrait frame, page tabs, sizing, and Escape routing.
local UI = {}
NS.UI = UI -- Exposes the window controller to other addon modules.

local Widgets = NS.Widgets -- Shared widget factories and the footer registry.
local frame -- Main window frame, created once by Build().
local pages          = {} -- Page records (title, icon, root, inset, tab) keyed by page name.
local activePage     = "Welcome" -- Selected page; Welcome until the user switches tabs.
local refreshQueued  = false -- True while a deferred Refresh timer is pending.

-- Re-routes Escape between the dismiss proxy and the main window via the router.
function UI:SyncEscape()
    if self.escapeRouter then
        self.escapeRouter:Sync()
    end
end

-- Lifts the inset's bottom edge above the tallest visible page footer.
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

-- Saves the window's anchor points and offsets to NS.db.window.
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

-- Sizes the window for compact or expanded mode, clamped to the screen, and refreshes.
-- @param self Window controller whose minimized state selects the target size.
function UI:ApplySize()
    if not frame then
        return
    end
    local width = self.minimized and math.max(742, NS.ScannerPanel.minWidth or 0) or 800
    frame:SetSize(
        math.max(1, math.min(width, UIParent:GetWidth() - 64)),
        math.max(1, math.min(self.minimized and 480 or 790, UIParent:GetHeight()))
    )
    self:Refresh()
end

-- Shows the named page, updating title, portrait, and tabs; returns false if unknown.
-- @param name Page key registered during Build(), such as Scanner or Census.
function UI:SelectPage(name)
    local selected = pages[name]
    if not selected then
        return false
    end
    Widgets.CommitFocus(frame)
    activePage = name
    self.pageTitle:SetText(selected.title)
    frame:SetPortraitToAsset(selected.icon)
    frame.Inset:SetPoint("TOPLEFT", 4, selected.insetTop)
    for pageName, page in pairs(pages) do
        page.root:SetShown(pageName == name)
        page.tab:SetSelected(pageName == name)
    end
    self:UpdateFooterInset()
    self:SyncEscape()
    self:Refresh()
    return true
end

-- Schedules one Refresh 0.1s later while the window is shown, coalescing bursts.
local function QueueRefresh()
    if not frame or not frame:IsShown() or refreshQueued then
        return
    end
    refreshQueued = true
    -- Clears the debounce flag and refreshes the active page after the short delay.
    C_Timer.After(0.1, function()
        refreshQueued = false
        UI:Refresh()
    end)
end

-- Creates the window, pages, side tabs, mode button, and Escape proxy on first call.
local function Build()
    if frame then
        return
    end
    frame     = CreateFrame("Frame", "Batata_Scanner_MainFrame", UIParent, "PortraitFrameTemplateMinimizable")
    UI.frame  = frame
    frame:SetTitle("Batata Scanner")
    frame:SetTitleOffsets(58, -58)
    frame:GetTitleText():SetJustifyH("CENTER")
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:SetResizable(false)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    -- Saves the finished drag position; self is the main window frame.
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    frame:SetClampedToScreen(true)
    frame:SetClampRectInsets(0, 64, 0, 0)
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
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
    UI.pageTitle:SetJustifyH("LEFT")
    UI.pageTitle:SetWordWrap(false)
    -- Hides the main window when its close button is clicked.
    frame.CloseButton:SetScript("OnClick", function()
        frame:Hide()
    end)

    local scannerRoot = CreateFrame("Frame", nil, frame)
    scannerRoot:SetPoint("TOPLEFT", 0, -61)
    scannerRoot:SetPoint("BOTTOMRIGHT", 0, 26)
    scannerRoot:Hide()
    local censusRoot = CreateFrame("Frame", nil, frame)
    censusRoot:SetPoint("TOPLEFT", 0, -60)
    censusRoot:SetPoint("BOTTOMRIGHT", 0, 26)
    censusRoot:Hide()
    local welcomeRoot = CreateFrame("Frame", nil, frame)
    welcomeRoot:SetPoint("TOPLEFT", 0, -60)
    welcomeRoot:SetPoint("BOTTOMRIGHT", 0, 26)
    -- Pages with subsection tabs keep a taller header band for them.
    pages.Welcome = {
        title     = "Welcome",
        icon      = NS.WelcomePanel.icon,
        root      = welcomeRoot,
        insetTop  = -83,
    }
    pages.Scanner = {
        title     = "Scanner",
        icon      = "Interface\\Icons\\Spell_Nature_Farsight",
        root      = scannerRoot,
        insetTop  = -60,
    }
    pages.Census = {
        title     = "Census",
        icon      = "Interface\\Icons\\inv_misc_map02",
        root      = censusRoot,
        insetTop  = -83,
    }
    frame:SetSize(800, 790)
    NS.WelcomePanel:Build(welcomeRoot, frame)
    NS.ScannerPanel:Build(scannerRoot, frame)
    NS.CensusPanel:Build(censusRoot, frame)

    frame.Tabs = {}
    local previousTab
    for pageIndex, name in ipairs({ "Welcome", "Scanner", "Census" }) do
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
        -- Selects the tab's page only for a completed left-button click inside its bounds.
        -- @param button Tab widget receiving the mouse event.
        -- @param mouseButton Mouse button released by the client.
        -- @param upInside Whether the release occurred inside the tab.
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
    -- Saves compact or expanded mode, swaps the mode button atlases, and resizes.
    -- @param minimized Whether the compact window size should be selected.
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
    -- Toggles between compact and expanded window sizes.
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
    -- Commits pending focus, closes transient scanner UI, saves position, and syncs Escape.
    frame:HookScript("OnHide", function()
        Widgets.CommitFocus(frame)
        NS.ScannerPanel.scanSettings:Hide()
        GameTooltip:Hide()
        SavePosition()
        UI:SyncEscape()
    end)
    frame:HookScript("OnShow", frame.Raise)
    frame:HookScript("OnShow", QueueRefresh)
    UISpecialFrames[#UISpecialFrames + 1] = "Batata_Scanner_MainFrame"
    local proxyName  = "Batata_Scanner_Dismiss"
    local proxy      = CreateFrame("Frame", proxyName, UIParent)
    proxy:SetSize(1, 1)
    proxy:SetPoint("CENTER")
    proxy:Hide()
    local router = {}
    UI.escapeRouter = router
    -- Swaps the Escape entry to the proxy while scanner settings or search are active.
    function router:Sync()
        local panel = NS.ScannerPanel
        local active = frame:IsShown() and activePage == "Scanner" and (panel.scanSettings:IsShown() or panel.searching)
        for frameIndex, name in ipairs(UISpecialFrames) do
            if name == "Batata_Scanner_MainFrame" or name == proxyName then
                UISpecialFrames[frameIndex] = active and proxyName or "Batata_Scanner_MainFrame"
            end
        end
        self.suppress = true
        proxy:SetShown(active and true or false)
        self.suppress = false
    end
    -- Routes Escape dismissal to the active scanner subview without hiding the window.
    proxy:SetScript("OnHide", function()
        if not router.suppress and frame:IsShown() then
            NS.ScannerPanel:Escape()
            router:Sync()
        end
    end)
    for frameIndex = #UISpecialFrames, 1, -1 do
        if UISpecialFrames[frameIndex] == "Batata_Scanner_ScanSettings" then
            table.remove(UISpecialFrames, frameIndex)
        end
    end
    SetMode(window.minimized ~= false)
    UI:SelectPage(activePage)
end

-- Refreshes the visible Scanner or Census panel once the addon is ready.
function UI:Refresh()
    if not frame or not frame:IsShown() or not NS.ready then
        return
    end
    if activePage == "Scanner" then
        NS.ScannerPanel:Refresh()
    elseif activePage == "Census" then
        NS.CensusPanel:Refresh(true)
    end
end

-- Builds the window if needed and shows it; ignored until the addon is ready.
function UI:Show()
    if not NS.ready then
        return
    end
    Build()
    frame:Show()
    self:Refresh()
end

-- Hides the window when shown; otherwise shows it.
function UI:Toggle()
    if frame and frame:IsShown() then
        frame:Hide()
    else
        self:Show()
    end
end

-- Invalidates scanner results and refreshes the visible page after stored data changes.
NS.On("DATA_UPDATED", function()
    NS.ScannerPanel:Invalidate()
    QueueRefresh()
end)
-- Marks accepted Who results stale without bypassing the browser refresh interval.
NS.On("WHO_RESULTS_RECEIVED", function()
    NS.ScannerPanel:Invalidate()
    QueueRefresh()
end)
NS.On("SCAN_STATUS_CHANGED", QueueRefresh)
