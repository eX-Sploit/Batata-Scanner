-- BatataScanner: draggable minimap button that toggles the main window.
-- Addon folder name and the private namespace table shared by all addon files.
local ADDON,
    NS = ...

-- Minimap button module: builds the button and keeps it on the minimap rim.
local MinimapButton = {}
NS.MinimapButton = MinimapButton -- Exposes the module to other addon files.

local Widgets = NS.Widgets -- Shared widget helpers, used here for the tooltip.

-- Positions the button on the minimap rim at the given angle in degrees.
-- @param button Minimap button to reposition.
-- @param angle Angle around the minimap in degrees.
local function Place(button, angle)
    local radians  = math.rad(angle)
    local radius   = Minimap:GetWidth() / 2 + 5
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(radians) * radius, math.sin(radians) * radius)
end

-- Saves the cursor's angle around the minimap and moves the button there while dragging.
-- @param button Minimap button being dragged.
-- @param elapsed Time since the previous OnUpdate callback.
local function FollowCursor(button, elapsed)
    local centerX,
        centerY = Minimap:GetCenter()
    local cursorX,
        cursorY = GetCursorPosition()
    local scale  = Minimap:GetEffectiveScale()
    local angle  = math.deg(math.atan2(cursorY / scale - centerY, cursorX / scale - centerX)) % 360
    NS.db.minimap.angle = math.floor(angle + 0.5) % 360
    Place(button, NS.db.minimap.angle)
end

-- Creates the button once, wiring click-to-toggle, drag-to-move, and its saved angle.
function MinimapButton:Build()
    if self.button or not Minimap then
        return
    end
    local button = CreateFrame("Button", "BatataScanner_MinimapButton", Minimap)
    self.button = button
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetPoint("TOPLEFT", 7, -5)
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Spyglass_03")
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    icon:SetPoint("TOPLEFT", 7, -6)
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")
    -- Opens or closes the addon window when the minimap button is clicked.
    button:SetScript("OnClick", function()
        NS.UI:Toggle()
    end)
    -- Begins moving the button with the cursor after hiding its tooltip.
    -- @param self Minimap button being dragged.
    button:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        self:SetScript("OnUpdate", FollowCursor)
    end)
    -- Stops cursor tracking when the drag ends.
    -- @param self Minimap button whose drag ended.
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)
    Widgets.Tooltip(button, "BatataScanner", "Click to open or close the window. Drag to move this button.")
    Place(button, NS.db.minimap.angle)
end

-- Builds the minimap button once character and saved settings are ready.
NS.On("READY", function()
    MinimapButton:Build()
end)
