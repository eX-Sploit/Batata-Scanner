-- Standalone WoW widget mocks. These exercise bindings and geometry, not game artwork.
date     = os.date
tinsert  = table.insert
function wipe(values)
    for key in pairs(values) do
        values[key] = nil
    end
    return values
end
function strtrim(value)
    return (value or ""):match("^%s*(.-)%s*$")
end
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
RAID_CLASS_COLORS =
    { MAGE = { r = 0.2, g = 0.6, b = 1 }, WARRIOR = { r = 0.8, g = 0.6, b = 0.4 }, DRUID = { r = 1, g = 0.5, b = 0 } }
GRAY_FONT_COLOR  = { r = 0.5, g = 0.5, b = 0.5 }
C_Texture        = {
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
ScrollBarMixin         = { Event = { OnScroll = "OnScroll" } }
ScrollControllerMixin  = { Directions = { Increase = 1, Decrease = -1 } }
MenuUtil               = {}
C_XMLUtil              = {
    GetTemplateInfo = function(name)
        if name == "WowStyle1DropdownTemplate" then
            return { type = "DropdownButton" }
        end
    end,
}

local nativeCreate  = CreateFrame
local methods       = getmetatable(UIParent).__index
local function Region(parent, kind)
    return setmetatable(
        { parent = parent, kind = kind, scripts = {}, points = {}, shown = true },
        { __index = methods }
    )
end
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
function WidgetBounds(region)
    local left,
        width = Bounds(region, "x")
    local bottom,
        height = Bounds(region, "y")
    return left, bottom, width, height
end
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
function methods:GetPoint(index)
    return unpack((self.points or {})[index or 1] or {})
end
function methods:GetNumPoints()
    return #(self.points or {})
end
function methods:ClearAllPoints()
    self.points = {}
end
function methods:SetAllPoints(target)
    self:ClearAllPoints()
    self:SetPoint("TOPLEFT", target or self.parent, "TOPLEFT", 0, 0)
    self:SetPoint("BOTTOMRIGHT", target or self.parent, "BOTTOMRIGHT", 0, 0)
end
local updatingGeometry = false
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
function methods:SetWidth(width)
    self:SetSize(width, self.height)
end
function methods:SetHeight(height)
    self:SetSize(self.width, height)
end
function methods:GetWidth()
    local left,
        width = Bounds(self, "x")
    return width
end
function methods:GetHeight()
    local bottom,
        height = Bounds(self, "y")
    return height
end
function methods:GetSize()
    return self:GetWidth(), self:GetHeight()
end
function methods:GetLeft()
    local left = Bounds(self, "x")
    return left
end
function methods:GetBottom()
    local bottom = Bounds(self, "y")
    return bottom
end
function methods:GetRight()
    return self:GetLeft() + self:GetWidth()
end
function methods:GetTop()
    return self:GetBottom() + self:GetHeight()
end
function methods:GetName()
    return self.name
end
function methods:GetParent()
    return self.parent
end
function methods:SetParent(parent)
    self.parent = parent
end
function methods:GetObjectType()
    return self.kind
end
function methods:SetFrameLevel(level)
    self.frameLevel = level
end
function methods:GetFrameLevel()
    return self.frameLevel or (self.parent and self.parent:GetFrameLevel() + 1) or 0
end
function methods:SetFrameStrata(strata)
    self.strata = strata
end
function methods:GetFrameStrata()
    return self.strata or "MEDIUM"
end
function methods:GetEffectiveScale()
    return (self.scale or 1) * (self.parent and self.parent:GetEffectiveScale() or 1)
end
function methods:SetScale(scale)
    self.scale = scale
end
function methods:SetID(widgetId)
    self.id = widgetId
end
function methods:GetID()
    return self.id
end
function methods:IsVisible()
    return self.shown and (not self.parent or self.parent:IsVisible())
end
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
function methods:Show()
    ShowState(self, true)
end
function methods:Hide()
    ShowState(self, false)
end
function methods:SetShown(shown)
    ShowState(self, shown and true or false)
end
function methods:Enable()
    self.enabled = true
end
function methods:Disable()
    self.enabled = false
end
function methods:IsEnabled()
    return self.enabled ~= false
end
function methods:SetEnabled(enabled)
    self.enabled = enabled and true or false
end
function methods:SetChecked(checked)
    self.checked = checked and true or false
end
function methods:GetChecked()
    return self.checked
end
function methods:SetText(text)
    self.text = tostring(text or "")
    if self.Text then
        self.Text:SetText(text)
    end
    if self.scripts.OnTextChanged then
        self.scripts.OnTextChanged(self, false)
    end
end
function methods:GetText()
    return self.text or ""
end
function methods:SetFontString(text)
    self.Text = text
end
function methods:GetFontString()
    return self.Text
end
function methods:GetStringWidth()
    return #self:GetText() * 6
end
function methods:GetStringHeight()
    local lines = 0
    for line in (self:GetText() .. "\n"):gmatch("(.-)\n") do
        lines = lines + math.max(1, math.ceil(#line * 6 / math.max(1, self:GetWidth())))
    end
    return lines * 14
end
function methods:SetFocus()
    keyboardFocus  = self
    self.focused   = true
    if self.scripts.OnEditFocusGained then
        self.scripts.OnEditFocusGained(self)
    end
end
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
function methods:HasFocus()
    return self.focused or false
end
function GetCurrentKeyBoardFocus()
    return keyboardFocus
end
function methods:CreateFontString(name, layer, font)
    local text = Region(self, "FontString")
    text.fontObject = font
    return text
end
function methods:CreateTexture()
    return Region(self, "Texture")
end
for stateIndex, state in ipairs({ "Normal", "Pushed", "Disabled", "Highlight" }) do
    methods["Get" .. state .. "Texture"] = function(self)
        self.buttonTextures         = self.buttonTextures or {}
        self.buttonTextures[state]  = self.buttonTextures[state] or self:CreateTexture()
        return self.buttonTextures[state]
    end
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
}) do
    local method = name
    methods[method] = function(self, ...)
        self.properties          = self.properties or {}
        self.properties[method]  = { ... }
    end
end
function methods:SetTexture(texture)
    self.texture = texture
end
function methods:SetAtlas(atlas)
    self.atlas = atlas
end
function methods:SetColorTexture(...)
    self.colorTexture = { ... }
end
function methods:SetTextColor(...)
    self.color = { ... }
end
function methods:SetVertexColor(...)
    self.vertexColor = { ... }
end
function methods:SetTexCoord(...)
    self.texCoords = { ... }
end
function methods:SetBlendMode(blend)
    self.blendMode = blend
end
function methods:SetValueStep(step)
    self.valueStep = step
end
function methods:GetValueStep()
    return self.valueStep or 0
end
function methods:SetMinMaxValues(minimum, maximum)
    self.minimum, self.maximum = minimum, maximum
    self:SetValue(self:GetValue())
end
function methods:GetMinMaxValues()
    return self.minimum or 0, self.maximum or 0
end
function methods:GetValue()
    return self.value or 0
end
function methods:SetValue(value)
    local nextValue  = self.minimum and math.max(self.minimum, math.min(self.maximum, value)) or value
    local changed    = nextValue ~= self:GetValue()
    self.value = nextValue
    if changed and self.scripts.OnValueChanged then
        self.scripts.OnValueChanged(self, nextValue)
    end
end
function methods:SetStepsPerPage(steps)
    self.stepsPerPage = steps
end
function methods:GetThumbTexture()
    self.thumb = self.thumb or self:CreateTexture()
    return self.thumb
end
function methods:SetScrollChild(child)
    self.scrollChild = child
end
function methods:SetVerticalScroll(value)
    local changed = value ~= self:GetVerticalScroll()
    self.verticalScroll = value
    if changed and self.scripts.OnVerticalScroll then
        self.scripts.OnVerticalScroll(self, value)
    end
end
function methods:GetVerticalScroll()
    return self.verticalScroll or 0
end
function methods:GetVerticalScrollRange()
    return self.scrollChild and math.max(0, self.scrollChild:GetHeight() - self:GetHeight()) or 0
end
function methods:SetHorizontalScroll(value)
    self.horizontalScroll = value
end
function methods:GetHorizontalScroll()
    return self.horizontalScroll or 0
end
function methods:SetOwner(owner, ...)
    self.owner, self.ownerAnchor = owner, { ... }
end
function methods:IsOwned(owner)
    return self.owner == owner
end
function methods:AddLine(text)
    self.lines                   = self.lines or {}
    self.lines[#self.lines + 1]  = text
end
function methods:ClearLines()
    self.lines = {}
end

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
        slider:SetScript("OnValueChanged", function(self, value)
            self:GetParent():SetVerticalScroll(value)
        end)
        frame:SetScript("OnVerticalScroll", function(self, value)
            self.ScrollBar:SetValue(value)
        end)
        frame:SetScript("OnMouseWheel", function(self, delta)
            self.ScrollBar:SetValue(self.ScrollBar:GetValue() - delta * (self.ScrollBar.scrollStep or 20))
        end)
        if template == "FauxScrollFrameTemplate" then
            frame.ScrollChildFrame = CreateFrame("Frame", name and name .. "ScrollChildFrame", frame)
        else
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
        function frame:RegisterCallback(event, callback, owner)
            self.callbacks[event] = { callback, owner }
        end
        function frame:GetScrollPercentage()
            return self.scrollPercentage or 0
        end
        function frame:GetVisibleExtentPercentage()
            return self.visibleExtentPercentage or 0
        end
        function frame:GetPanExtentPercentage()
            return self.panExtentPercentage or 0
        end
        function frame:SetPanExtentPercentage(value)
            self.panExtentPercentage = math.max(0, math.min(1, value))
        end
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
        function frame:SetVisibleExtentPercentage(value)
            self.visibleExtentPercentage = math.max(0, math.min(1, value))
            self:Update()
        end
        function frame:SetScrollPercentage(value)
            self.scrollPercentage = math.max(0, math.min(1, value))
            self:Update()
            local registration = self.callbacks.OnScroll
            if registration then
                registration[1](registration[2], self.scrollPercentage)
            end
        end
        function frame:SetHideTrackIfThumbExceedsTrack(value)
            self.hideTrackIfThumbExceedsTrack = value
            self:Update()
        end
        function frame:UnregisterUpdate()
            self:SetScript("OnUpdate", nil)
        end
        function frame:ScrollStepInDirection(direction)
            if self.allowScroll then
                self:SetScrollPercentage(self:GetScrollPercentage() + self:GetPanExtentPercentage() * direction)
            end
        end
        frame.Back:SetScript("OnMouseDown", function(self)
            if self:IsEnabled() then
                frame:ScrollStepInDirection(-1)
            end
        end)
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
        frame:SetScript("OnTextChanged", function(self)
            self.Instructions:SetShown(self:GetText() == "")
            self.clearButton:SetShown(self:HasFocus() or self:GetText() ~= "")
        end)
        frame:SetScript("OnEditFocusGained", function(self)
            self.clearButton:Show()
        end)
        frame:SetScript("OnEditFocusLost", function(self)
            if self:GetText() == "" then
                self.clearButton:Hide()
            end
        end)
        frame:SetScript("OnEnterPressed", frame.ClearFocus)
        frame:SetScript("OnEscapePressed", frame.ClearFocus)
        frame.clearButton:SetScript("OnClick", function(self)
            self.parent:SetText("")
            self.parent:ClearFocus()
        end)
    elseif template == "WowStyle1DropdownTemplate" then
        function frame:SetDefaultText(text)
            self.defaultText = text
        end
        function frame:GenerateMenu()
            self.entries = {}
            local root = {}
            function root:CreateRadio(label, isSelected, onSelect, data)
                frame.entries[#frame.entries + 1] =
                    { label = label, selected = isSelected, select = onSelect, data = data }
            end
            function root:CreateDivider()
                frame.entries[#frame.entries + 1] = { divider = true }
            end
            if self.generator then
                self.generator(self, root)
            end
        end
        function frame:SetupMenu(generator)
            self.generator = generator
            self:GenerateMenu()
        end
        function frame:CloseMenu()
            self.menuOpen = false
        end
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
        function frame:SetFillToInterior(enabled)
            self.fillToInterior = enabled
        end
        function frame:SetChecked(checked)
            self.checked = checked
            self.SelectedTexture:SetShown(checked)
        end
        function frame:SetCustomOnMouseUpHandler(callback)
            self.customMouseUpHandler = callback
        end
        frame:SetScript("OnMouseUp", function(self, button, upInside)
            if self.customMouseUpHandler then
                self.customMouseUpHandler(self, button, upInside)
            end
        end)
    elseif template == "TabSystemTopButtonTemplate" then
        frame.Text = Region(frame, "FontString")
        function frame:HandleRotation()
            self.rotationHandled = true
        end
        function frame:SetTabHeight(height)
            self.tabHeight = height
        end
        function frame:SetTabWidth(width)
            self:SetWidth(width)
        end
        function frame:SetTabSelected(selected)
            self.selected = selected
            self:SetEnabled(not selected)
        end
    elseif template == "PortraitFrameTemplateMinimizable" or template == "DefaultPanelTemplate" then
        frame.Bg                        = Region(frame, "Texture")
        frame.TopTileStreaks            = Region(frame, "Texture")
        frame.TitleContainer            = CreateFrame("Frame", nil, frame)
        frame.TitleContainer.TitleText  = Region(frame.TitleContainer, "FontString")
        function frame:GetTitleText()
            return self.TitleContainer.TitleText
        end
        function frame:SetTitle(text)
            self:GetTitleText():SetText(text)
        end
        function frame:SetTitleOffsets(...)
            self.titleOffsets = { ... }
        end
        if template == "PortraitFrameTemplateMinimizable" then
            frame.PortraitContainer           = CreateFrame("Frame", nil, frame)
            frame.PortraitContainer.portrait  = Region(frame.PortraitContainer, "Texture")
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
UIParent.kind, UIParent.points                         = "Frame", {}
WorldFrame.kind, WorldFrame.parent, WorldFrame.points  = "Frame", UIParent, {}
GameTooltip                                            = CreateFrame("GameTooltip", nil, UIParent)
function GetAppropriateTooltip()
    return GameTooltip
end
NineSliceUtil = {
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
function FauxScrollFrame_GetOffset(scroll)
    return scroll.offset or 0
end
function FauxScrollFrame_Update(scroll, total, visible, rowHeight)
    local slider = scroll.ScrollBar
    slider:SetMinMaxValues(0, math.max(0, (total - visible) * rowHeight))
    slider:SetValueStep(rowHeight)
    slider:SetStepsPerPage(math.max(1, visible - 1))
    scroll:SetShown(total > visible)
end
function FauxScrollFrame_OnVerticalScroll(scroll, pixels, rowHeight, update)
    scroll.ScrollBar:SetValue(pixels)
    scroll.offset = math.floor(scroll.ScrollBar:GetValue() / rowHeight + 0.5)
    update()
end
function ClickWidget(widget, button)
    assert(widget:IsEnabled(), "disabled widget")
    Click(function()
        if widget.scripts.OnClick then
            widget.scripts.OnClick(widget, button or "LeftButton")
        elseif widget.scripts.OnMouseUp then
            widget.scripts.OnMouseUp(widget, button or "LeftButton", true)
        else
            error("widget has no click handler")
        end
    end)
end
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
