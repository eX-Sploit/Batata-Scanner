-- Standalone WoW widget mocks. These exercise bindings and geometry, not game artwork.
date     = os.date -- Supplies deterministic date formatting to UI widget mocks.
tinsert  = table.insert -- Matches the global insertion helper available in WoW Lua.
-- Clears all keys from a mocked Lua table and returns that table.
-- @param values Argument named values supplied to the mocked API.
function wipe(values)
    for key in pairs(values) do
        values[key] = nil
    end
    return values
end
-- Trims leading and trailing whitespace like the WoW helper.
-- @param value Value supplied to or returned from the mocked API.
function strtrim(value)
    return (value or ""):match("^%s*(.-)%s*$")
end
-- Populate the WoW font-object globals referenced by real UI modules.
for fontIndex, name in ipairs({
    "GameFontNormal",
    "GameFontHighlight",
    "GameFontDisable",
    "GameFontHighlightSmall",
    "GameFontNormalSmall",
    "GameFontDisableSmall",
    "GameFontNormalLarge",
    "GameFontNormalMed1",
    "ChatFontNormal",
}) do
    _G[name] = { name = name }
end
-- Mock class colors and icon coordinates consumed by scanner table rendering.
RAID_CLASS_COLORS =
    { MAGE = { r = 0.2, g = 0.6, b = 1 }, WARRIOR = { r = 0.8, g = 0.6, b = 0.4 }, DRUID = { r = 1, g = 0.5, b = 0 } }
CLASS_ICON_TCOORDS  = { MAGE = { 0.25, 0.5, 0, 0.25 }, WARRIOR = { 0, 0.25, 0, 0.25 } } -- Icon atlas coordinates used by mock player rows.
GRAY_FONT_COLOR     = { r = 0.5, g = 0.5, b = 0.5 } -- Fallback color for unknown-class chart and table entries.
C_Texture           = {
    -- Provides deterministic atlas dimensions and texture coordinates for layout tests.
    -- @param atlas Atlas name requested by the widget under test.
    GetAtlasInfo = function(atlas)
        if atlas == "common-sidetab" then
            return { width = 64, height = 58 }
        end
        return {
            file            = 8164401,
            width           = 665,
            height          = 570,
            leftTexCoord    = 1 / 1024,
            rightTexCoord   = 666 / 1024,
            topTexCoord     = 1 / 1024,
            bottomTexCoord  = 571 / 1024,
        }
    end,
}
ScrollBarMixin         = { Event = { OnScroll = "OnScroll" } } -- Event key used by the mocked modern scrollbar.
ScrollControllerMixin  = { Directions = { Increase = 1, Decrease = -1 } } -- Direction constants used by scrollbar widgets.
MenuUtil               = {} -- Presence flag that enables Blizzard-style dropdown tests.
C_XMLUtil              = {
    -- Reports supported Blizzard templates used to select native widget code paths.
    -- @param name Template name requested by the addon UI.
    GetTemplateInfo = function(name)
        if name == "WowStyle1DropdownTemplate" then
            return { type = "DropdownButton" }
        end
    end,
}

local nativeCreate  = CreateFrame -- Original harness frame factory wrapped with UI test behavior.
local methods       = getmetatable(UIParent).__index -- Shared mock widget methods installed on every frame.
-- Creates a child region backed by the shared mock widget methods.
-- @param parent Parent frame that owns this mock region or widget.
-- @param kind WoW widget or region type being represented.
local function Region(parent, kind)
    return setmetatable(
        { parent = parent, kind = kind, scripts = {}, points = {}, shown = true },
        { __index = methods }
    )
end
-- Maps an anchor name to its normalized position on one axis.
-- @param point Anchor point name supplied by the caller.
-- @param axis Geometry axis being measured, x or y.
local function Fraction(point, axis)
    if axis == "x" then
        if point:find("LEFT", 1, true) then
            return 0
        end
        if point:find("RIGHT", 1, true) then
            return 1
        end
    else
        if point:find("BOTTOM", 1, true) then
            return 0
        end
        if point:find("TOP", 1, true) then
            return 1
        end
    end
    return 0.5
end
-- Recursively calculates a mock region position and size from its anchors.
-- @param region Mock region whose bounds or state are evaluated.
-- @param axis Geometry axis being measured, x or y.
-- @param visited Frames already visited during recursive bounds calculation.
local function Bounds(region, axis, visited)
    if region == UIParent then
        return 0, axis == "x" and 1920 or 1080
    end
    visited = visited or {}
    if visited[region] then
        error("cyclic mock anchors")
    end
    visited[region] = true
    local dimension = axis == "x" and region.width or region.height
    local firstFraction
    local firstPosition
    local secondFraction
    local secondPosition
    for pointIndex, point in ipairs(region.points or {}) do
        local target = point[2] or region.parent or UIParent
        local targetStart,
            targetSize = Bounds(target, axis, visited)
        local fraction  = Fraction(point[1], axis)
        local position  = targetStart + Fraction(point[3], axis) * targetSize + (point[axis == "x" and 4 or 5] or 0)
        if firstFraction == nil then
            firstFraction, firstPosition = fraction, position
        elseif fraction ~= firstFraction then
            secondFraction, secondPosition = fraction, position
        end
    end
    visited[region] = nil
    if secondFraction then
        dimension = (secondPosition - firstPosition) / (secondFraction - firstFraction)
    end
    dimension = math.max(0, dimension or 180)
    return firstPosition and firstPosition - firstFraction * dimension or 0, dimension
end
-- Returns a widget rectangle calculated from its mock anchors.
-- @param region Mock region whose bounds or state are evaluated.
function WidgetBounds(region)
    local left,
        width = Bounds(region, "x")
    local bottom,
        height = Bounds(region, "y")
    return left, bottom, width, height
end
-- Stores the mocked Point value for later UI assertions.
-- @param point Anchor point name supplied by the caller.
-- @param relativeTo Frame used as the relative anchor.
-- @param relativePoint Anchor point on the relative frame.
-- @param offsetX Horizontal anchor offset in pixels.
-- @param offsetY Vertical anchor offset in pixels.
function methods:SetPoint(point, relativeTo, relativePoint, offsetX, offsetY)
    if type(relativeTo) ~= "table" then
        if type(relativeTo) == "string" then
            relativeTo = assert(_G[relativeTo], "unknown anchor frame")
        else
            offsetX, offsetY, relativePoint, relativeTo =
                relativeTo or 0, relativePoint or 0, point, self.parent or UIParent
        end
    end
    if type(relativePoint) ~= "string" then
        offsetX, offsetY, relativePoint = relativePoint or 0, offsetX or 0, point
    end
    local value = { point, relativeTo, relativePoint, offsetX or 0, offsetY or 0 }
    self.points = self.points or {}
    for index, previous in ipairs(self.points) do
        if previous[1] == point then
            self.points[index] = value
            return
        end
    end
    self.points[#self.points + 1] = value
end
-- Returns the mocked Point value used by UI assertions.
-- @param index One-based position requested from the mock.
function methods:GetPoint(index)
    return unpack((self.points or {})[index or 1] or {})
end
-- Returns the mocked NumPoints value used by UI assertions.
function methods:GetNumPoints()
    return #(self.points or {})
end
-- Implements the mock ClearAllPoints behavior used by UI tests.
function methods:ClearAllPoints()
    self.points = {}
end
-- Stores the mocked AllPoints value for later UI assertions.
-- @param target Argument named target supplied to the mocked API.
function methods:SetAllPoints(target)
    self:ClearAllPoints()
    self:SetPoint("TOPLEFT", target or self.parent, "TOPLEFT", 0, 0)
    self:SetPoint("BOTTOMRIGHT", target or self.parent, "BOTTOMRIGHT", 0, 0)
end
local updatingGeometry = false -- Prevents recursive SetSize callbacks while layout is settling.
-- Stores the mocked Size value for later UI assertions.
-- @param width Requested width in pixels.
-- @param height Requested height in pixels.
function methods:SetSize(width, height)
    if updatingGeometry then
        self.width, self.height = width, height
        return
    end
    local watchers = {}
    for frameIndex, frame in ipairs(frames) do
        if frame.scripts.OnSizeChanged then
            local ancestor = frame
            while ancestor and ancestor ~= self do
                ancestor = ancestor.parent
            end
            if ancestor == self then
                watchers[#watchers + 1] = { frame = frame, width = frame:GetWidth(), height = frame:GetHeight() }
            end
        end
    end
    self.width, self.height  = width, height
    updatingGeometry         = true
    for iteration = 1, 100 do
        local changed = false
        for watcherIndex, watcher in ipairs(watchers) do
            local currentWidth,
                currentHeight = watcher.frame:GetSize()
            if currentWidth ~= watcher.width or currentHeight ~= watcher.height then
                watcher.width, watcher.height = currentWidth, currentHeight
                watcher.frame.scripts.OnSizeChanged(watcher.frame, currentWidth, currentHeight)
                changed = true
            end
        end
        if not changed then
            updatingGeometry = false
            return
        end
    end
    error("mock layout did not settle")
end
-- Stores the mocked Width value for later UI assertions.
-- @param width Requested width in pixels.
function methods:SetWidth(width)
    self:SetSize(width, self.height)
end
-- Stores the mocked Height value for later UI assertions.
-- @param height Requested height in pixels.
function methods:SetHeight(height)
    self:SetSize(self.width, height)
end
-- Returns the mocked Width value used by UI assertions.
function methods:GetWidth()
    local left,
        width = Bounds(self, "x")
    return width
end
-- Returns the mocked Height value used by UI assertions.
function methods:GetHeight()
    local bottom,
        height = Bounds(self, "y")
    return height
end
-- Returns the mocked Size value used by UI assertions.
function methods:GetSize()
    return self:GetWidth(), self:GetHeight()
end
-- Returns the mocked Left value used by UI assertions.
function methods:GetLeft()
    local left = Bounds(self, "x")
    return left
end
-- Returns the mocked Bottom value used by UI assertions.
function methods:GetBottom()
    local bottom = Bounds(self, "y")
    return bottom
end
-- Returns the mocked Right value used by UI assertions.
function methods:GetRight()
    return self:GetLeft() + self:GetWidth()
end
-- Returns the mocked Top value used by UI assertions.
function methods:GetTop()
    return self:GetBottom() + self:GetHeight()
end
-- Returns the mocked Name value used by UI assertions.
function methods:GetName()
    return self.name
end
-- Returns the mocked Parent value used by UI assertions.
function methods:GetParent()
    return self.parent
end
-- Stores the mocked Parent value for later UI assertions.
-- @param parent Parent frame that owns this mock region or widget.
function methods:SetParent(parent)
    self.parent = parent
end
-- Returns the mocked ObjectType value used by UI assertions.
function methods:GetObjectType()
    return self.kind
end
-- Stores the mocked FrameLevel value for later UI assertions.
-- @param level Argument named level supplied to the mocked API.
function methods:SetFrameLevel(level)
    self.frameLevel = level
end
-- Returns the mocked FrameLevel value used by UI assertions.
function methods:GetFrameLevel()
    return self.frameLevel or (self.parent and self.parent:GetFrameLevel() + 1) or 0
end
-- Stores the mocked Toplevel value for later UI assertions.
-- @param topLevel Argument named topLevel supplied to the mocked API.
function methods:SetToplevel(topLevel)
    self.topLevel = topLevel and true or false
end
-- Implements the mock IsToplevel behavior used by UI tests.
function methods:IsToplevel()
    return self.topLevel or false
end
-- Implements the mock Raise behavior used by UI tests.
function methods:Raise()
    self.raiseCount = (self.raiseCount or 0) + 1
end
-- Stores the mocked FrameStrata value for later UI assertions.
-- @param strata Argument named strata supplied to the mocked API.
function methods:SetFrameStrata(strata)
    self.strata = strata
end
-- Returns the mocked FrameStrata value used by UI assertions.
function methods:GetFrameStrata()
    return self.strata or "MEDIUM"
end
-- Returns the mocked EffectiveScale value used by UI assertions.
function methods:GetEffectiveScale()
    return (self.scale or 1) * (self.parent and self.parent:GetEffectiveScale() or 1)
end
-- Stores the mocked Scale value for later UI assertions.
-- @param scale Argument named scale supplied to the mocked API.
function methods:SetScale(scale)
    self.scale = scale
end
-- Stores the mocked ID value for later UI assertions.
-- @param widgetId Argument named widgetId supplied to the mocked API.
function methods:SetID(widgetId)
    self.id = widgetId
end
-- Returns the mocked ID value used by UI assertions.
function methods:GetID()
    return self.id
end
-- Implements the mock IsVisible behavior used by UI tests.
function methods:IsVisible()
    return self.shown and (not self.parent or self.parent:IsVisible())
end
-- Collects descendant frames and their visibility before a state change.
-- @param frame Mock frame receiving the operation.
local function Descendants(frame)
    local result = {}
    for childIndex, child in ipairs(frames) do
        local parent = child.parent
        while parent and parent ~= frame do
            parent = parent.parent
        end
        if parent == frame then
            result[#result + 1] = { frame = child, visible = child:IsVisible() }
        end
    end
    return result
end
-- Changes mock visibility and dispatches affected OnShow or OnHide scripts.
-- @param frame Mock frame receiving the operation.
-- @param shown Whether the mock widget should be visible.
local function ShowState(frame, shown)
    if frame.shown == shown then
        return
    end
    local before         = Descendants(frame)
    local visibleBefore  = frame:IsVisible()
    frame.shown = shown
    if visibleBefore ~= frame:IsVisible() then
        local callback = frame.scripts[shown and "OnShow" or "OnHide"]
        if callback then
            callback(frame)
        end
    end
    for entryIndex, entry in ipairs(before) do
        local child = entry.frame
        if entry.visible ~= child:IsVisible() then
            local callback = child.scripts[child:IsVisible() and "OnShow" or "OnHide"]
            if callback then
                callback(child)
            end
        end
    end
end
-- Implements the mock Show behavior used by UI tests.
function methods:Show()
    ShowState(self, true)
end
-- Implements the mock Hide behavior used by UI tests.
function methods:Hide()
    ShowState(self, false)
end
-- Stores the mocked Shown value for later UI assertions.
-- @param shown Whether the mock widget should be visible.
function methods:SetShown(shown)
    ShowState(self, shown and true or false)
end
-- Implements the mock Enable behavior used by UI tests.
function methods:Enable()
    self.enabled = true
end
-- Implements the mock Disable behavior used by UI tests.
function methods:Disable()
    self.enabled = false
end
-- Implements the mock IsEnabled behavior used by UI tests.
function methods:IsEnabled()
    return self.enabled ~= false
end
-- Stores the mocked Enabled value for later UI assertions.
-- @param enabled Whether the mock widget should accept input.
function methods:SetEnabled(enabled)
    self.enabled = enabled and true or false
end
-- Stores the mocked Checked value for later UI assertions.
-- @param checked Argument named checked supplied to the mocked API.
function methods:SetChecked(checked)
    self.checked = checked and true or false
end
-- Returns the mocked Checked value used by UI assertions.
function methods:GetChecked()
    return self.checked
end
-- Stores the mocked Text value for later UI assertions.
-- @param text Text value supplied to the mock widget.
function methods:SetText(text)
    self.text = tostring(text or "")
    if self.Text then
        self.Text:SetText(text)
    end
    if self.scripts.OnTextChanged then
        self.scripts.OnTextChanged(self, false)
    end
end
-- Returns the mocked Text value used by UI assertions.
function methods:GetText()
    return self.text or ""
end
-- Stores the mocked FontString value for later UI assertions.
-- @param text Text value supplied to the mock widget.
function methods:SetFontString(text)
    self.Text = text
end
-- Returns the mocked FontString value used by UI assertions.
function methods:GetFontString()
    return self.Text
end
-- Returns the mocked StringWidth value used by UI assertions.
function methods:GetStringWidth()
    return #self:GetText() * 6
end
-- Returns the mocked StringHeight value used by UI assertions.
function methods:GetStringHeight()
    local lines = 0
    for line in (self:GetText() .. "\n"):gmatch("(.-)\n") do
        lines = lines + math.max(1, math.ceil(#line * 6 / math.max(1, self:GetWidth())))
    end
    return lines * 14
end
-- Stores the mocked Focus value for later UI assertions.
function methods:SetFocus()
    keyboardFocus  = self
    self.focused   = true
    if self.scripts.OnEditFocusGained then
        self.scripts.OnEditFocusGained(self)
    end
end
-- Implements the mock ClearFocus behavior used by UI tests.
function methods:ClearFocus()
    if not self.focused then
        return
    end
    self.focused = false
    if keyboardFocus == self then
        keyboardFocus = nil
    end
    if self.scripts.OnEditFocusLost then
        self.scripts.OnEditFocusLost(self)
    end
end
-- Implements the mock HasFocus behavior used by UI tests.
function methods:HasFocus()
    return self.focused or false
end
-- Returns the widget currently holding mocked keyboard focus.
function GetCurrentKeyBoardFocus()
    return keyboardFocus
end
-- Implements the mock CreateFontString behavior used by UI tests.
-- @param name Mock API name or widget name used by the test.
-- @param layer Argument named layer supplied to the mocked API.
-- @param font Argument named font supplied to the mocked API.
function methods:CreateFontString(name, layer, font)
    local text = Region(self, "FontString")
    text.fontObject = font
    return text
end
-- Implements the mock CreateTexture behavior used by UI tests.
function methods:CreateTexture()
    return Region(self, "Texture")
end
-- Implements the mock CreateLine behavior used by UI tests.
function methods:CreateLine()
    return Region(self, "Line")
end
-- Stores the mocked StartPoint value for later UI assertions.
-- @param point Anchor point name supplied by the caller.
-- @param relativeTo Frame used as the relative anchor.
-- @param offsetX Horizontal anchor offset in pixels.
-- @param offsetY Vertical anchor offset in pixels.
function methods:SetStartPoint(point, relativeTo, offsetX, offsetY)
    self.startPoint = { point, relativeTo, offsetX, offsetY }
end
-- Stores the mocked EndPoint value for later UI assertions.
-- @param point Anchor point name supplied by the caller.
-- @param relativeTo Frame used as the relative anchor.
-- @param offsetX Horizontal anchor offset in pixels.
-- @param offsetY Vertical anchor offset in pixels.
function methods:SetEndPoint(point, relativeTo, offsetX, offsetY)
    self.endPoint = { point, relativeTo, offsetX, offsetY }
end
-- Stores the mocked Thickness value for later UI assertions.
-- @param thickness Argument named thickness supplied to the mocked API.
function methods:SetThickness(thickness)
    self.thickness = thickness
end
-- Stores the mocked VertexOffset value for later UI assertions.
-- @param vertexIndex Argument named vertexIndex supplied to the mocked API.
-- @param offsetX Horizontal anchor offset in pixels.
-- @param offsetY Vertical anchor offset in pixels.
function methods:SetVertexOffset(vertexIndex, offsetX, offsetY)
    self.vertexOffsets               = self.vertexOffsets or {}
    self.vertexOffsets[vertexIndex]  = { offsetX, offsetY }
end
for stateIndex, state in ipairs({ "Normal", "Pushed", "Disabled", "Highlight" }) do
    -- Simulates a WoW UI callback for deterministic widget tests.
    -- @param self Mock widget receiving this API call.
    methods["Get" .. state .. "Texture"] = function(self)
        self.buttonTextures         = self.buttonTextures or {}
        self.buttonTextures[state]  = self.buttonTextures[state] or self:CreateTexture()
        return self.buttonTextures[state]
    end
    -- Simulates a WoW UI callback for deterministic widget tests.
    -- @param self Mock widget receiving this API call.
    -- @param texture Argument named texture supplied to the mocked API.
    -- @param blend Argument named blend supplied to the mocked API.
    methods["Set" .. state .. "Texture"] = function(self, texture, blend)
        local target = self["Get" .. state .. "Texture"](self)
        target:SetTexture(texture)
        if blend then
            target:SetBlendMode(blend)
        end
    end
end
-- Record each rendering/input contract so tests can inspect it; no permissive catch-all.
for methodIndex, name in ipairs({
    "SetJustifyH",
    "SetJustifyV",
    "SetWordWrap",
    "SetNonSpaceWrap",
    "SetTextColor",
    "SetAtlas",
    "SetHorizTile",
    "SetVertTile",
    "SetNormalFontObject",
    "SetHighlightFontObject",
    "SetDisabledFontObject",
    "SetBackdrop",
    "SetBackdropColor",
    "SetBackdropBorderColor",
    "SetTextInsets",
    "SetAutoFocus",
    "SetFontObject",
    "SetMaxLetters",
    "SetNumeric",
    "EnableMouse",
    "EnableMouseWheel",
    "SetTexCoord",
    "SetSnapToPixelGrid",
    "SetTexelSnappingBias",
    "SetTexture",
    "SetColorTexture",
    "SetMovable",
    "SetResizable",
    "SetResizeBounds",
    "SetClampedToScreen",
    "RegisterForDrag",
    "RegisterForClicks",
    "StartMoving",
    "StopMovingOrSizing",
    "StartSizing",
    "SetBlendMode",
    "SetAlpha",
    "SetVertexColor",
    "SetClipsChildren",
    "SetOrientation",
    "SetClampRectInsets",
    "SetPropagateKeyboardInput",
    "EnableKeyboard",
    "SetAttribute",
    "SetTextureSliceMargins",
}) do
    local method = name -- Current native setter recorded in the mock's properties table.
    -- Simulates a WoW UI callback for deterministic widget tests.
    -- @param self Mock widget receiving this API call.
    methods[method] = function(self, ...)
        self.properties          = self.properties or {}
        self.properties[method]  = { ... }
    end
end
-- Stores the mocked Texture value for later UI assertions.
-- @param texture Argument named texture supplied to the mocked API.
function methods:SetTexture(texture)
    self.texture = texture
end
-- Stores the mocked Atlas value for later UI assertions.
-- @param atlas Argument named atlas supplied to the mocked API.
function methods:SetAtlas(atlas)
    self.atlas = atlas
end
-- Stores the mocked ColorTexture value for later UI assertions.
function methods:SetColorTexture(...)
    self.colorTexture = { ... }
end
-- Stores the mocked TextColor value for later UI assertions.
function methods:SetTextColor(...)
    self.color = { ... }
end
-- Stores the mocked VertexColor value for later UI assertions.
function methods:SetVertexColor(...)
    self.vertexColor = { ... }
end
-- Stores the mocked TexCoord value for later UI assertions.
function methods:SetTexCoord(...)
    self.texCoords = { ... }
end
-- Stores the mocked BlendMode value for later UI assertions.
-- @param blend Argument named blend supplied to the mocked API.
function methods:SetBlendMode(blend)
    self.blendMode = blend
end
-- Stores the mocked ValueStep value for later UI assertions.
-- @param step Argument named step supplied to the mocked API.
function methods:SetValueStep(step)
    self.valueStep = step
end
-- Returns the mocked ValueStep value used by UI assertions.
function methods:GetValueStep()
    return self.valueStep or 0
end
-- Stores the mocked MinMaxValues value for later UI assertions.
-- @param minimum Argument named minimum supplied to the mocked API.
-- @param maximum Argument named maximum supplied to the mocked API.
function methods:SetMinMaxValues(minimum, maximum)
    self.minimum, self.maximum = minimum, maximum
    self:SetValue(self:GetValue())
end
-- Returns the mocked MinMaxValues value used by UI assertions.
function methods:GetMinMaxValues()
    return self.minimum or 0, self.maximum or 0
end
-- Returns the mocked Value value used by UI assertions.
function methods:GetValue()
    return self.value or 0
end
-- Stores the mocked Value value for later UI assertions.
-- @param value Value supplied to or returned from the mocked API.
function methods:SetValue(value)
    local nextValue  = self.minimum and math.max(self.minimum, math.min(self.maximum, value)) or value
    local changed    = nextValue ~= self:GetValue()
    self.value = nextValue
    if changed and self.scripts.OnValueChanged then
        self.scripts.OnValueChanged(self, nextValue)
    end
end
-- Stores the mocked StepsPerPage value for later UI assertions.
-- @param steps Argument named steps supplied to the mocked API.
function methods:SetStepsPerPage(steps)
    self.stepsPerPage = steps
end
-- Returns the mocked ThumbTexture value used by UI assertions.
function methods:GetThumbTexture()
    self.thumb = self.thumb or self:CreateTexture()
    return self.thumb
end
-- Stores the mocked ScrollChild value for later UI assertions.
-- @param child Argument named child supplied to the mocked API.
function methods:SetScrollChild(child)
    self.scrollChild = child
end
-- Stores the mocked VerticalScroll value for later UI assertions.
-- @param value Value supplied to or returned from the mocked API.
function methods:SetVerticalScroll(value)
    local changed = value ~= self:GetVerticalScroll()
    self.verticalScroll = value
    if changed and self.scripts.OnVerticalScroll then
        self.scripts.OnVerticalScroll(self, value)
    end
end
-- Returns the mocked VerticalScroll value used by UI assertions.
function methods:GetVerticalScroll()
    return self.verticalScroll or 0
end
-- Returns the mocked VerticalScrollRange value used by UI assertions.
function methods:GetVerticalScrollRange()
    return self.scrollChild and math.max(0, self.scrollChild:GetHeight() - self:GetHeight()) or 0
end
-- Stores the mocked HorizontalScroll value for later UI assertions.
-- @param value Value supplied to or returned from the mocked API.
function methods:SetHorizontalScroll(value)
    self.horizontalScroll = value
end
-- Returns the mocked HorizontalScroll value used by UI assertions.
function methods:GetHorizontalScroll()
    return self.horizontalScroll or 0
end
-- Stores the mocked Owner value for later UI assertions.
-- @param owner Argument named owner supplied to the mocked API.
function methods:SetOwner(owner, ...)
    self.owner, self.ownerAnchor = owner, { ... }
end
-- Implements the mock IsOwned behavior used by UI tests.
-- @param owner Argument named owner supplied to the mocked API.
function methods:IsOwned(owner)
    return self.owner == owner
end
-- Implements the mock AddLine behavior used by UI tests.
-- @param text Text value supplied to the mock widget.
function methods:AddLine(text)
    self.lines                   = self.lines or {}
    self.lines[#self.lines + 1]  = text
end
-- Implements the mock ClearLines behavior used by UI tests.
function methods:ClearLines()
    self.lines = {}
end

-- Creates a mock WoW frame, template children, and default event behavior.
-- @param kind WoW widget or region type being represented.
-- @param name Mock API name or widget name used by the test.
-- @param parent Parent frame that owns this mock region or widget.
-- @param template Argument named template supplied to the mocked API.
function CreateFrame(kind, name, parent, template)
    local frame = nativeCreate(kind, name, parent, template)
    frame.kind, frame.parent, frame.template, frame.points = kind, parent, template, {}
    if template == "FauxScrollFrameTemplate" or template == "UIPanelScrollFrameTemplate" then
        local slider = CreateFrame("Slider", name and name .. "ScrollBar", frame)
        frame.ScrollBar = slider
        slider:SetMinMaxValues(0, 0)
        slider:SetValue(0)
        slider.ScrollUpButton    = CreateFrame("Button", nil, slider)
        slider.ScrollDownButton  = CreateFrame("Button", nil, slider)
        -- Simulates a WoW UI callback for deterministic widget tests.
        -- @param self Mock widget receiving this API call.
        -- @param value Value supplied to or returned from the mocked API.
        slider:SetScript("OnValueChanged", function(self, value)
            self:GetParent():SetVerticalScroll(value)
        end)
        -- Simulates a WoW UI callback for deterministic widget tests.
        -- @param self Mock widget receiving this API call.
        -- @param value Value supplied to or returned from the mocked API.
        frame:SetScript("OnVerticalScroll", function(self, value)
            self.ScrollBar:SetValue(value)
        end)
        -- Simulates a WoW UI callback for deterministic widget tests.
        -- @param self Mock widget receiving this API call.
        -- @param delta Signed mouse-wheel movement supplied by the test.
        frame:SetScript("OnMouseWheel", function(self, delta)
            self.ScrollBar:SetValue(self.ScrollBar:GetValue() - delta * (self.ScrollBar.scrollStep or 20))
        end)
        if template == "FauxScrollFrameTemplate" then
            frame.ScrollChildFrame = CreateFrame("Frame", name and name .. "ScrollChildFrame", frame)
        else
            -- Simulates a WoW UI callback for deterministic widget tests.
            -- @param self Mock widget receiving this API call.
            -- @param horizontal Argument named horizontal supplied to the mocked API.
            -- @param vertical Argument named vertical supplied to the mocked API.
            frame:SetScript("OnScrollRangeChanged", function(self, horizontal, vertical)
                self.ScrollBar:SetMinMaxValues(0, math.floor(vertical))
            end)
        end
    elseif template == "MinimalScrollBar" then
        frame:SetSize(8, 560)
        frame.Back         = CreateFrame("EventButton", nil, frame)
        frame.Forward      = CreateFrame("EventButton", nil, frame)
        frame.Track        = CreateFrame("Frame", nil, frame)
        frame.Track.Thumb  = CreateFrame("EventButton", nil, frame.Track)
        frame.Track:SetPoint("TOP", 0, -19)
        frame.Track:SetPoint("BOTTOM", 0, 19)
        frame.callbacks    = {}
        frame.allowScroll  = true
        -- Implements the mock RegisterCallback behavior used by UI tests.
        -- @param event WoW event name used by the mock callback.
        -- @param callback Function invoked when the mocked event or action occurs.
        -- @param owner Argument named owner supplied to the mocked API.
        function frame:RegisterCallback(event, callback, owner)
            self.callbacks[event] = { callback, owner }
        end
        -- Returns the mocked ScrollPercentage value used by UI assertions.
        function frame:GetScrollPercentage()
            return self.scrollPercentage or 0
        end
        -- Returns the mocked VisibleExtentPercentage value used by UI assertions.
        function frame:GetVisibleExtentPercentage()
            return self.visibleExtentPercentage or 0
        end
        -- Returns the mocked PanExtentPercentage value used by UI assertions.
        function frame:GetPanExtentPercentage()
            return self.panExtentPercentage or 0
        end
        -- Stores the mocked PanExtentPercentage value for later UI assertions.
        -- @param value Value supplied to or returned from the mocked API.
        function frame:SetPanExtentPercentage(value)
            self.panExtentPercentage = math.max(0, math.min(1, value))
        end
        -- Implements the mock Update behavior used by UI tests.
        function frame:Update()
            local fraction     = self:GetVisibleExtentPercentage()
            local scrollable   = fraction > 0 and fraction < 1
            local extent       = self.Track:GetHeight()
            local thumbExtent  = math.max(23, extent * fraction)
            self.Track.Thumb:SetHeight(math.min(extent, thumbExtent))
            self.Back:SetEnabled(scrollable and self.allowScroll and self:GetScrollPercentage() > 0)
            self.Forward:SetEnabled(scrollable and self.allowScroll and self:GetScrollPercentage() < 1)
            self.Track.Thumb:SetShown(scrollable and thumbExtent <= extent)
            self.Track:SetShown(not (thumbExtent > extent and self.hideTrackIfThumbExceedsTrack))
        end
        -- Stores the mocked VisibleExtentPercentage value for later UI assertions.
        -- @param value Value supplied to or returned from the mocked API.
        function frame:SetVisibleExtentPercentage(value)
            self.visibleExtentPercentage = math.max(0, math.min(1, value))
            self:Update()
        end
        -- Stores the mocked ScrollPercentage value for later UI assertions.
        -- @param value Value supplied to or returned from the mocked API.
        function frame:SetScrollPercentage(value)
            self.scrollPercentage = math.max(0, math.min(1, value))
            self:Update()
            local registration = self.callbacks.OnScroll
            if registration then
                registration[1](registration[2], self.scrollPercentage)
            end
        end
        -- Stores the mocked HideTrackIfThumbExceedsTrack value for later UI assertions.
        -- @param value Value supplied to or returned from the mocked API.
        function frame:SetHideTrackIfThumbExceedsTrack(value)
            self.hideTrackIfThumbExceedsTrack = value
            self:Update()
        end
        -- Implements the mock UnregisterUpdate behavior used by UI tests.
        function frame:UnregisterUpdate()
            self:SetScript("OnUpdate", nil)
        end
        -- Implements the mock ScrollStepInDirection behavior used by UI tests.
        -- @param direction Argument named direction supplied to the mocked API.
        function frame:ScrollStepInDirection(direction)
            if self.allowScroll then
                self:SetScrollPercentage(self:GetScrollPercentage() + self:GetPanExtentPercentage() * direction)
            end
        end
        -- Simulates a WoW UI callback for deterministic widget tests.
        -- @param self Mock widget receiving this API call.
        frame.Back:SetScript("OnMouseDown", function(self)
            if self:IsEnabled() then
                frame:ScrollStepInDirection(-1)
            end
        end)
        -- Simulates a WoW UI callback for deterministic widget tests.
        -- @param self Mock widget receiving this API call.
        frame.Forward:SetScript("OnMouseDown", function(self)
            if self:IsEnabled() then
                frame:ScrollStepInDirection(1)
            end
        end)
    elseif template == "SearchBoxTemplate" then
        frame.Instructions  = Region(frame, "FontString")
        frame.searchIcon    = Region(frame, "Texture")
        frame.clearButton   = CreateFrame("Button", nil, frame)
        frame.clearButton:Hide()
        -- Simulates a WoW UI callback for deterministic widget tests.
        -- @param self Mock widget receiving this API call.
        frame:SetScript("OnTextChanged", function(self)
            self.Instructions:SetShown(self:GetText() == "")
            self.clearButton:SetShown(self:HasFocus() or self:GetText() ~= "")
        end)
        -- Simulates a WoW UI callback for deterministic widget tests.
        -- @param self Mock widget receiving this API call.
        frame:SetScript("OnEditFocusGained", function(self)
            self.clearButton:Show()
        end)
        -- Simulates a WoW UI callback for deterministic widget tests.
        -- @param self Mock widget receiving this API call.
        frame:SetScript("OnEditFocusLost", function(self)
            if self:GetText() == "" then
                self.clearButton:Hide()
            end
        end)
        frame:SetScript("OnEnterPressed", frame.ClearFocus)
        frame:SetScript("OnEscapePressed", frame.ClearFocus)
        -- Simulates a WoW UI callback for deterministic widget tests.
        -- @param self Mock widget receiving this API call.
        frame.clearButton:SetScript("OnClick", function(self)
            self.parent:SetText("")
            self.parent:ClearFocus()
        end)
    elseif template == "WowStyle1DropdownTemplate" then
        -- Stores the mocked DefaultText value for later UI assertions.
        -- @param text Text value supplied to the mock widget.
        function frame:SetDefaultText(text)
            self.defaultText = text
        end
        -- Implements the mock GenerateMenu behavior used by UI tests.
        function frame:GenerateMenu()
            self.entries = {}
            local root = {}
            -- Implements the mock CreateRadio behavior used by UI tests.
            -- @param label Argument named label supplied to the mocked API.
            -- @param isSelected Argument named isSelected supplied to the mocked API.
            -- @param onSelect Argument named onSelect supplied to the mocked API.
            -- @param data Argument named data supplied to the mocked API.
            function root:CreateRadio(label, isSelected, onSelect, data)
                frame.entries[#frame.entries + 1] =
                    { label = label, selected = isSelected, select = onSelect, data = data }
            end
            -- Implements the mock CreateDivider behavior used by UI tests.
            function root:CreateDivider()
                frame.entries[#frame.entries + 1] = { divider = true }
            end
            if self.generator then
                self.generator(self, root)
            end
        end
        -- Stores the mocked upMenu value for later UI assertions.
        -- @param generator Argument named generator supplied to the mocked API.
        function frame:SetupMenu(generator)
            self.generator = generator
            self:GenerateMenu()
        end
        -- Implements the mock CloseMenu behavior used by UI tests.
        function frame:CloseMenu()
            self.menuOpen = false
        end
        -- Simulates a WoW UI callback for deterministic widget tests.
        -- @param self Mock widget receiving this API call.
        frame:SetScript("OnHide", function(self)
            self:CloseMenu()
        end)
    elseif template == "InsetFrameTemplate" then
        frame.Bg         = Region(frame, "Texture")
        frame.NineSlice  = CreateFrame("Frame", nil, frame)
    elseif template == "LargeSideTabButtonTemplate" then
        assert(kind == "Frame", "native icon tabs are frames")
        frame:SetSize(64, 53)
        frame.Icon              = Region(frame, "Texture")
        frame.SelectedTexture   = Region(frame, "Texture")
        frame.HighlightTexture  = Region(frame, "Texture")
        -- Stores the mocked FillToInterior value for later UI assertions.
        -- @param enabled Whether the mock widget should accept input.
        function frame:SetFillToInterior(enabled)
            self.fillToInterior = enabled
        end
        -- Stores the mocked Checked value for later UI assertions.
        -- @param checked Argument named checked supplied to the mocked API.
        function frame:SetChecked(checked)
            self.checked = checked
            self.SelectedTexture:SetShown(checked)
        end
        -- Stores the mocked CustomOnMouseUpHandler value for later UI assertions.
        -- @param callback Function invoked when the mocked event or action occurs.
        function frame:SetCustomOnMouseUpHandler(callback)
            self.customMouseUpHandler = callback
        end
        -- Simulates a WoW UI callback for deterministic widget tests.
        -- @param self Mock widget receiving this API call.
        -- @param button Argument named button supplied to the mocked API.
        -- @param upInside Argument named upInside supplied to the mocked API.
        frame:SetScript("OnMouseUp", function(self, button, upInside)
            if self.customMouseUpHandler then
                self.customMouseUpHandler(self, button, upInside)
            end
        end)
    elseif template == "TabSystemTopButtonTemplate" then
        frame.Text = Region(frame, "FontString")
        -- Implements the mock HandleRotation behavior used by UI tests.
        function frame:HandleRotation()
            self.rotationHandled = true
        end
        -- Stores the mocked TabHeight value for later UI assertions.
        -- @param height Requested height in pixels.
        function frame:SetTabHeight(height)
            self.tabHeight = height
        end
        -- Stores the mocked TabWidth value for later UI assertions.
        -- @param width Requested width in pixels.
        function frame:SetTabWidth(width)
            self:SetWidth(width)
        end
        -- Stores the mocked TabSelected value for later UI assertions.
        -- @param selected Argument named selected supplied to the mocked API.
        function frame:SetTabSelected(selected)
            self.selected = selected
            self:SetEnabled(not selected)
        end
    elseif template == "PortraitFrameTemplateMinimizable" or template == "DefaultPanelTemplate" then
        frame.Bg                        = Region(frame, "Texture")
        frame.TopTileStreaks            = Region(frame, "Texture")
        frame.TitleContainer            = CreateFrame("Frame", nil, frame)
        frame.TitleContainer.TitleText  = Region(frame.TitleContainer, "FontString")
        -- Returns the mocked TitleText value used by UI assertions.
        function frame:GetTitleText()
            return self.TitleContainer.TitleText
        end
        -- Stores the mocked Title value for later UI assertions.
        -- @param text Text value supplied to the mock widget.
        function frame:SetTitle(text)
            self:GetTitleText():SetText(text)
        end
        -- Stores the mocked TitleOffsets value for later UI assertions.
        function frame:SetTitleOffsets(...)
            self.titleOffsets = { ... }
        end
        if template == "PortraitFrameTemplateMinimizable" then
            frame.PortraitContainer           = CreateFrame("Frame", nil, frame)
            frame.PortraitContainer.portrait  = Region(frame.PortraitContainer, "Texture")
            -- Stores the mocked PortraitToAsset value for later UI assertions.
            -- @param texture Argument named texture supplied to the mocked API.
            function frame:SetPortraitToAsset(texture)
                self.PortraitContainer.portrait:SetTexture(texture)
            end
            frame.CloseButton = CreateFrame("Button", nil, frame, "UIPanelCloseButtonDefaultAnchors")
            frame.CloseButton:SetSize(24, 24)
            frame.CloseButton:SetPoint("TOPRIGHT", -2, 1)
        end
    end
    if
        template == "SharedButtonSmallTemplate"
        or template == "ColumnDisplayButtonNoScriptsTemplate"
        or (template and template:find("UIPanelButton", 1, true))
    then
        frame.Text = frame.Text or Region(frame, "FontString")
        for pieceIndex, key in ipairs({ "Left", "Middle", "Right" }) do
            frame[key] = Region(frame, "Texture")
        end
        if template == "ColumnDisplayButtonNoScriptsTemplate" then
            frame:SetHeight(24)
            frame:SetHighlightTexture("Interface\\PaperDollInfoFrame\\UI-Character-Tab-Highlight", "ADD")
        end
    end
    return frame
end
UIParent.kind, UIParent.points                         = "Frame", {} -- Mock root frame with no anchors.
WorldFrame.kind, WorldFrame.parent, WorldFrame.points  = "Frame", UIParent, {} -- Mock world-click surface parented to UIParent.
GameTooltip                                            = CreateFrame("GameTooltip", nil, UIParent) -- Shared tooltip frame inspected by UI tests.
Minimap                                                = CreateFrame("Frame", "Minimap", UIParent) -- Mock minimap anchor and parent for the addon button.
Minimap:SetSize(140, 140)
Minimap:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -20, -20)
cursorX  = 0 -- Mock cursor X coordinate read by hover and minimap drag handlers.
cursorY  = 0 -- Mock cursor Y coordinate read by hover and minimap drag handlers.
-- Returns the mocked cursor coordinates used by hover tests.
function GetCursorPosition()
    return cursorX, cursorY
end
-- Returns the mocked Center value used by UI assertions.
function methods:GetCenter()
    return self:GetLeft() + self:GetWidth() / 2, self:GetBottom() + self:GetHeight() / 2
end
-- Returns the shared mock GameTooltip object.
function GetAppropriateTooltip()
    return GameTooltip
end
NineSliceUtil = {
    -- Simulates a WoW UI callback for deterministic widget tests.
    -- @param frame Mock frame receiving the operation.
    -- @param layout Argument named layout supplied to the mocked API.
    ApplyLayoutByName = function(frame, layout)
        frame.appliedLayout = layout
        for pieceIndex, key in ipairs({
            "TopLeftCorner",
            "TopRightCorner",
            "BottomLeftCorner",
            "BottomRightCorner",
            "TopEdge",
            "BottomEdge",
            "LeftEdge",
            "RightEdge",
        }) do
            frame[key] = frame[key] or Region(frame, "Texture")
        end
    end,
}
-- Returns the current mocked first-row offset.
-- @param scroll Argument named scroll supplied to the mocked API.
function FauxScrollFrame_GetOffset(scroll)
    return scroll.offset or 0
end
-- Updates the mock scrollbar range and list visibility.
-- @param scroll Argument named scroll supplied to the mocked API.
-- @param total Argument named total supplied to the mocked API.
-- @param visible Argument named visible supplied to the mocked API.
-- @param rowHeight Height of one rendered list row.
function FauxScrollFrame_Update(scroll, total, visible, rowHeight)
    local slider = scroll.ScrollBar
    slider:SetMinMaxValues(0, math.max(0, (total - visible) * rowHeight))
    slider:SetValueStep(rowHeight)
    slider:SetStepsPerPage(math.max(1, visible - 1))
    scroll:SetShown(total > visible)
end
-- Updates the mock row offset and then runs its refresh callback.
-- @param scroll Argument named scroll supplied to the mocked API.
-- @param pixels Vertical scroll distance in pixels.
-- @param rowHeight Height of one rendered list row.
-- @param update Argument named update supplied to the mocked API.
function FauxScrollFrame_OnVerticalScroll(scroll, pixels, rowHeight, update)
    scroll.ScrollBar:SetValue(pixels)
    scroll.offset = math.floor(scroll.ScrollBar:GetValue() / rowHeight + 0.5)
    update()
end
-- Dispatches a widget click inside the mocked hardware-input callback.
-- @param widget Argument named widget supplied to the mocked API.
-- @param button Argument named button supplied to the mocked API.
function ClickWidget(widget, button)
    assert(widget:IsEnabled(), "disabled widget")
    -- Simulates a WoW UI callback for deterministic widget tests.
    Click(function()
        local topLevelFrame = widget
        while topLevelFrame and not topLevelFrame:IsToplevel() do
            topLevelFrame = topLevelFrame:GetParent()
        end
        if topLevelFrame then
            topLevelFrame:Raise()
        end
        if widget.scripts.OnClick then
            widget.scripts.OnClick(widget, button or "LeftButton")
        elseif widget.scripts.OnMouseUp then
            widget.scripts.OnMouseUp(widget, button or "LeftButton", true)
        else
            error("widget has no click handler")
        end
    end)
end
-- Finds and clicks a navigation tab by its visible label.
-- @param text Text value supplied to the mock widget.
function Tab(text)
    for widgetIndex, widget in ipairs(frames) do
        if
            (widget.template == "TabSystemTopButtonTemplate" and widget:GetText() == text)
            or (widget.template == "LargeSideTabButtonTemplate" and widget.tooltipText == text)
        then
            ClickWidget(widget)
            return widget
        end
    end
    error("missing tab: " .. text)
end
