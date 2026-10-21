-- BatataScanner
-- Widgets.lua : standalone adaptations of GuildHQ shared visual primitives.

-- Addon folder name and the private namespace shared by every file in the TOC.
local ADDON,
    NS = ...

-- Shared frame constructors, Blizzard-styled surfaces, and list-table layout for the panels.
local Widgets = {}
NS.Widgets = Widgets -- Publish the module to the other UI files through the namespace.

local ROW_H                = 20 -- Default pixel height of table and dropdown-list rows.
local HEADER_H             = 24 -- Pixel height of table column headers.
local CELL_GAP             = 4 -- Horizontal pixel gap between adjacent table cells.
local TABLE_SCROLL_GUTTER  = 28 -- Width reserved right of table rows for the scrollbar rail.
local FOOTER_HEIGHT        = 44 -- Default pixel height of a page's footer band.
local footerRoots          = {} -- Pages that own footer artwork, scanned when the main inset is resized.
Widgets.FOOTER_HEIGHT  = FOOTER_HEIGHT -- Export the default footer height for page layouts.
Widgets.footerRoots    = footerRoots -- Export footer pages so UI can fit its inset above visible footers.

-- Marble backdrop with a thin tooltip border for recessed, non-raised surfaces such as edit boxes.
local INSET_BACKDROP = {
    bgFile    = "Interface\\FrameGeneral\\UI-Background-Marble",
    edgeFile  = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile      = true,
    tileSize  = 256,
    edgeSize  = 8,
    insets    = { left = 2, right = 2, top = 2, bottom = 2 },
}

local ACCENT  = { 1, 0.82, 0 } -- Gold RGB for headings and focused or hovered borders.
local BORDER  = { 0.65, 0.60, 0.50 } -- Tan RGB for idle recessed-field borders.
local TEXT    = { 1, 1, 1 } -- White RGB for regular text.
local MUTED   = { 0.65, 0.65, 0.65 } -- Gray RGB for disabled or secondary labels.
Widgets.Colors = { accent = ACCENT, border = BORDER, text = TEXT, muted = MUTED } -- Shared palette for panels.

-- Use Professions surfaces for content and recessed borders for edit fields.
-- @param panel Frame whose backdrop or raised inset should be configured.
-- @param raised Whether to use the elevated Professions inset surface.
function Widgets.Surface(panel, raised)
    if raised then
        panel:SetBackdrop(nil)
        if not panel.batataInset then
            panel.batataInset = Widgets.Inset(panel)
            panel.batataInset:SetAllPoints()
            panel.batataInset:EnableMouse(false)
        end
        return
    end
    panel:SetBackdrop(INSET_BACKDROP)
    panel:SetBackdropColor(0.6, 0.6, 0.6, 1)
    panel:SetBackdropBorderColor(unpack(BORDER))
end

-- Share the brown Professions surface and its ornate, natively sliced border.
-- @param parent Frame that owns the inset.
function Widgets.Inset(parent)
    local inset = CreateFrame("Frame", nil, parent, "InsetFrameTemplate")
    inset.Bg:SetAtlas("Professions-background-summarylist")
    inset.Bg:SetHorizTile(false)
    inset.Bg:SetVertTile(false)
    inset.NineSlice:Hide()
    inset.batataBorder = inset:CreateTexture(nil, "BORDER")
    inset.batataBorder:SetAtlas("common-insideframe")
    inset.batataBorder:SetAllPoints()
    return inset
end

-- Applies the raised Professions inset surface behind a panel's content.
-- @param panel Frame that receives the raised surface.
function Widgets.ProfileSurface(panel)
    Widgets.Surface(panel, true)
end

-- Reuse the dark Professions band with a fixed-height separator, optionally rotated for a footer.
-- @param background Texture used for the band artwork.
-- @param divider Texture used for the horizontal separator.
-- @param rotated Whether the atlas coordinates should be rotated for a footer band.
function Widgets.StyleProfessionsBand(background, divider, rotated)
    local atlas          = C_Texture.GetAtlasInfo("Profession-Background-Template2")
    local textureSource  = atlas and (atlas.file or atlas.filename)
    if not textureSource then
        return false
    end

    local textureHeight  = atlas.bottomTexCoord - atlas.topTexCoord
    local dividerTop     = atlas.topTexCoord + textureHeight * 46 / 570
    local dividerBottom  = atlas.topTexCoord + textureHeight * 54 / 570
    background:SetTexture(textureSource)
    divider:SetTexture(textureSource)
    if rotated then
        background:SetTexCoord(atlas.rightTexCoord, atlas.leftTexCoord, dividerTop, atlas.topTexCoord)
        divider:SetTexCoord(atlas.rightTexCoord, atlas.leftTexCoord, dividerBottom, dividerTop)
    else
        background:SetTexCoord(atlas.leftTexCoord, atlas.rightTexCoord, atlas.topTexCoord, dividerTop)
        divider:SetTexCoord(atlas.leftTexCoord, atlas.rightTexCoord, dividerTop, dividerBottom)
    end
    divider:SetHeight(8)
    return true
end

-- A page owns its footer artwork so navigation hides it together with its controls.
-- @param parent Page frame that owns and shows the footer.
-- @param mainFrame Optional main frame used to anchor footer artwork.
-- @param height Optional footer height in pixels.
function Widgets.Footer(parent, mainFrame, height)
    if parent.batataFooterBackground then
        return parent.batataFooterBackground, parent.batataFooterDivider
    end
    mainFrame                  = mainFrame or parent.headerFrame or parent
    parent.batataFooterHeight  = height or FOOTER_HEIGHT
    local background  = parent:CreateTexture(nil, "BACKGROUND", nil, -3)
    local divider     = parent:CreateTexture(nil, "BORDER")
    if not Widgets.StyleProfessionsBand(background, divider, true) then
        return
    end
    parent.batataFooterBackground  = background
    parent.batataFooterDivider     = divider
    divider:SetPoint("TOPLEFT", mainFrame, "BOTTOMLEFT", 4, parent.batataFooterHeight)
    divider:SetPoint("TOPRIGHT", mainFrame, "BOTTOMRIGHT", -6, parent.batataFooterHeight)
    background:SetPoint("TOPLEFT", divider, "BOTTOMLEFT")
    background:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -6, 2)
    footerRoots[#footerRoots + 1] = parent
    -- Asks the main UI to refit its inset when this page's footer shows or hides.
    local function UpdateFooter()
        if NS.UI and NS.UI.UpdateFooterInset then
            NS.UI:UpdateFooterInset()
        end
    end
    parent:HookScript("OnShow", UpdateFooter)
    parent:HookScript("OnHide", UpdateFooter)
    return background, divider
end

-- Keep the native red/beveled artwork and state scripts, including secure buttons.
-- @param button Button whose font objects should be updated.
-- @param variant Optional style name; compact selects the smaller font objects.
function Widgets.StyleButton(button, variant)
    button:SetNormalFontObject(variant == "compact" and GameFontNormalSmall or GameFontNormal)
    button:SetHighlightFontObject(variant == "compact" and GameFontHighlightSmall or GameFontHighlight)
    button:SetDisabledFontObject(variant == "compact" and GameFontDisableSmall or GameFontDisable)
end

-- Match the compact top tabs used inside Blizzard's social window.
-- @param parent Frame that owns the navigation button.
-- @param text Label displayed on the tab.
-- @param width Optional fixed tab width; omitted width is measured from the label.
function Widgets.NavigationButton(parent, text, width)
    local button = CreateFrame("Button", nil, parent, "TabSystemTopButtonTemplate")
    button:SetHeight(24)
    button:SetText(text)
    button:HandleRotation()
    button:SetTabHeight(24)
    button.fs = button.Text
    button:SetTabWidth(width or math.max(100, math.min(150, math.ceil(button.fs:GetStringWidth()) + 24)))
    -- Stores the selection flag and switches the top tab to its selected artwork.
    -- @param selected Whether the button should display selected artwork.
    function button:SetSelected(selected)
        self.selected = selected and true or false
        self:SetTabSelected(self.selected)
    end
    button:SetSelected(false)
    return button
end

-- Use the masked icon frames and gold selection border from Camelot Professions.
-- @param parent Frame that owns the icon tab.
-- @param text Tooltip label describing the tab.
-- @param icon Texture path or asset used for the tab icon.
function Widgets.IconTab(parent, text, icon)
    local button = CreateFrame("Frame", nil, parent, "LargeSideTabButtonTemplate")
    button:SetFrameLevel(parent:GetFrameLevel() + 510)
    button.Icon:SetTexture(icon)
    button:SetFillToInterior(true)
    button.tooltipText = text
    -- Stores the selection flag and shows it as the side tab's checked gold border.
    -- @param selected Whether the icon tab should display its selected border.
    function button:SetSelected(selected)
        self.selected = selected and true or false
        self:SetChecked(self.selected)
    end
    button:SetSelected(false)
    return button
end

-- A stationary column keeps scrollbar controls separate from the content border.
-- @param parent Frame alongside which the scrollbar box is placed.
-- @param topInset Optional top spacing inside the box.
-- @param bottomInset Optional bottom spacing inside the box.
function Widgets.ScrollBarBox(parent, topInset, bottomInset)
    local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    Widgets.ProfileSurface(box)
    box.batataInset:Hide()
    box:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, -(topInset or 8))
    box:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -8, bottomInset or 8)
    box:SetWidth(TABLE_SCROLL_GUTTER)
    box:EnableMouse(false)
    return box
end

-- Keep existing pixel offsets and row binding while native controls own the scrollbar artwork and input.
-- @param scrollFrame Scrolling content frame whose range and value are mirrored.
-- @param slider Optional native slider; defaults to the frame's ScrollBar.
-- @param scrollBarBox Optional stationary frame that owns the replacement rail.
-- @param alwaysShowScrollBar Whether to keep the rail visible when the list fits.
function Widgets.ModernScrollBar(scrollFrame, slider, scrollBarBox, alwaysShowScrollBar)
    slider = slider or scrollFrame.ScrollBar
    if slider.batataScrollBar then
        return slider.batataScrollBar
    end

    local scrollBar = CreateFrame("EventFrame", nil, scrollBarBox or slider:GetParent(), "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollFrame, "TOPRIGHT", 10, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollFrame, "BOTTOMRIGHT", 10, 0)
    scrollBar.Background = scrollBar:CreateTexture(nil, "BACKGROUND")
    scrollBar.Background:SetTexture("Interface\\FrameGeneral\\UI-Background-Marble")
    scrollBar.Background:SetHorizTile(true)
    scrollBar.Background:SetVertTile(true)
    scrollBar.Background:SetAllPoints()
    scrollBar.Background:Hide()
    if scrollBarBox then
        scrollBar:ClearAllPoints()
        scrollBar:SetPoint("TOP", scrollBarBox, "TOP", 0, -4)
        scrollBar:SetPoint("BOTTOM", scrollBarBox, "BOTTOM", 0, 4)
        scrollBar.Background:Hide()
    end
    scrollBar:SetHideTrackIfThumbExceedsTrack(true)
    slider.batataScrollBar       = scrollBar
    scrollFrame.batataScrollBar  = scrollBar
    slider:SetAlpha(0)
    slider:EnableMouse(false)
    slider:EnableMouseWheel(false)
    if slider.ScrollUpButton then
        slider.ScrollUpButton:EnableMouse(false)
        slider.ScrollDownButton:EnableMouse(false)
    end

    local syncing = false
    -- Mirrors the hidden slider's range, step, value, and visibility onto the native scrollbar.
    local function Sync()
        if syncing then
            return
        end
        syncing = true
        local minimum,
            maximum = slider:GetMinMaxValues()
        local range           = maximum - minimum
        local viewportHeight  = math.max(1, scrollFrame:GetHeight())
        local step            = slider.scrollStep or slider:GetValueStep()
        if step <= 0 then
            step = viewportHeight / 2
        end
        -- Short detail sections retain the arrows; single-line previews use their existing mouse wheel.
        local trackInset = math.min(19, (viewportHeight - 1) / 2)
        if scrollBar.batataTrackInset ~= trackInset then
            scrollBar.batataTrackInset = trackInset
            scrollBar.Track:SetPoint("TOP", 0, -trackInset)
            scrollBar.Track:SetPoint("BOTTOM", 0, trackInset)
        end
        scrollBar:SetVisibleExtentPercentage(viewportHeight / (viewportHeight + range))
        scrollBar:SetPanExtentPercentage(range > 0 and math.min(1, step / range) or 0)
        scrollBar:SetScrollPercentage(range > 0 and (slider:GetValue() - minimum) / range or 0, true)
        local ownerShown = slider:IsShown() and (not scrollBarBox or scrollFrame:IsShown())
        scrollBar:SetShown(viewportHeight >= 24 and (alwaysShowScrollBar or ownerShown))
        syncing = false
    end

    -- Applies native scrollbar movement to the hidden slider's scroll range.
    -- @param owner Native scrollbar that emitted the callback.
    -- @param percentage Normalized scroll position from zero to one.
    scrollBar:RegisterCallback(ScrollBarMixin.Event.OnScroll, function(owner, percentage)
        if not syncing then
            local minimum,
                maximum = slider:GetMinMaxValues()
            slider:SetValue(minimum + percentage * (maximum - minimum))
        end
    end, scrollFrame)
    -- Forwards wheel movement to the existing scroll-frame handler.
    -- @param self Replacement scrollbar receiving the wheel event.
    -- @param delta Signed wheel movement supplied by the client.
    scrollBar:SetScript("OnMouseWheel", function(self, delta)
        local onMouseWheel = scrollFrame:GetScript("OnMouseWheel")
        if onMouseWheel then
            onMouseWheel(scrollFrame, delta)
        end
    end)
    -- Stops native updates when the replacement scrollbar is hidden.
    -- @param self Replacement scrollbar being hidden.
    scrollBar:HookScript("OnHide", function(self)
        self:UnregisterUpdate()
    end)
    hooksecurefunc(slider, "SetValue", Sync)
    hooksecurefunc(slider, "SetMinMaxValues", Sync)
    hooksecurefunc(slider, "SetValueStep", Sync)
    slider:HookScript("OnShow", Sync)
    slider:HookScript("OnHide", Sync)
    scrollFrame:HookScript("OnSizeChanged", Sync)
    if scrollBarBox then
        -- External controls no longer inherit the scrolling frame's visibility.
        scrollFrame:HookScript("OnShow", Sync)
        scrollFrame:HookScript("OnHide", Sync)
    end
    Sync()
    return scrollBar
end

-- Shared surfaces and headers retain each caller's data, sorting, and row lifecycle.
-- @param tableFrame Frame whose shared table surface is configured.
-- @param headerHeight Optional height reserved above the rows.
function Widgets.TableBackground(tableFrame, headerHeight)
    Widgets.Surface(tableFrame, true)
    tableFrame.batataInset:ClearAllPoints()
    tableFrame.batataInset:SetPoint("TOPLEFT", -4, 3 - (headerHeight or 0))
    tableFrame.batataInset:SetPoint("BOTTOMRIGHT")
    -- The containing panel supplies the surface; rows and the scrollbar share it.
    tableFrame.batataInset:Hide()
end

-- Place the native rail alongside the rows without adding another border.
-- @param tableFrame Frame containing the table rows and surface.
-- @param scrollFrame Native scrolling frame for the table content.
-- @param slider Optional native slider to replace.
-- @param scrollBarBox Optional frame that owns the replacement scrollbar.
-- @param alwaysShowScrollBar Whether the replacement rail remains visible for short lists.
function Widgets.TableScrollBar(tableFrame, scrollFrame, slider, scrollBarBox, alwaysShowScrollBar)
    local scrollBar = Widgets.ModernScrollBar(scrollFrame, slider, scrollBarBox, alwaysShowScrollBar)
    if scrollBarBox then
        return scrollBar
    end
    local scrollBarOffset = (TABLE_SCROLL_GUTTER - scrollBar:GetWidth()) / 2
    scrollBar:ClearAllPoints()
    scrollBar:SetPoint("TOPLEFT", scrollFrame, "TOPRIGHT", scrollBarOffset, -3)
    scrollBar:SetPoint("BOTTOMLEFT", scrollFrame, "BOTTOMRIGHT", scrollBarOffset, 2)

    tableFrame.batataInset:Hide()
    return scrollBar
end

-- Creates a column header button over rock artwork; it accepts clicks only when onClick is set.
-- @param parent Frame that owns the header.
-- @param label Header text to display.
-- @param onClick Optional sort or action callback invoked on click.
function Widgets.TableHeader(parent, label, onClick)
    local headerButton = CreateFrame("Button", nil, parent, "ColumnDisplayButtonNoScriptsTemplate")
    headerButton:SetHeight(HEADER_H)
    -- ColumnDisplayTemplate puts untinted rock behind the translucent header artwork.
    local background = headerButton:CreateTexture(nil, "BACKGROUND", nil, -1)
    background:SetTexture("Interface\\FrameGeneral\\UI-Background-Rock")
    background:SetHorizTile(true)
    background:SetVertTile(true)
    background:SetAllPoints()
    headerButton:SetNormalFontObject(GameFontHighlightSmall)
    headerButton:SetHighlightFontObject(GameFontHighlightSmall)
    headerButton:SetText(label or "")
    headerButton.fs = headerButton:GetFontString()
    headerButton.fs:ClearAllPoints()
    headerButton.labelWidth = math.ceil(headerButton.fs:GetStringWidth())
    headerButton.fs:SetPoint("LEFT", 8, 0)
    headerButton.fs:SetPoint("RIGHT", -4, 0)
    headerButton.fs:SetJustifyH("LEFT")
    headerButton.fs:SetWordWrap(false)
    headerButton:SetScript("OnClick", onClick)
    headerButton:EnableMouse(onClick ~= nil)
    return headerButton
end

-- Adds a hover highlight bar when the row is a button.
-- @param row Table row whose button highlight should be configured.
function Widgets.TableRow(row)
    if row:GetObjectType() == "Button" then
        row:SetHighlightTexture("Interface\\FriendsFrame\\UI-FriendsFrame-HighlightBar", "ADD")
        row:GetHighlightTexture():SetAllPoints()
    end
end

-- Creates a hidden additive highlight texture that marks a selected row.
-- @param row Table row that owns the selection texture.
function Widgets.TableSelection(row)
    local selection = row:CreateTexture(nil, "BACKGROUND", nil, -6)
    selection:SetAllPoints()
    selection:SetTexture("Interface\\FriendsFrame\\UI-FriendsFrame-HighlightBar")
    selection:SetBlendMode("ADD")
    selection:Hide()
    return selection
end

-- Commit only the focused editor belonging to the supplied window or dialog.
-- @param scopeFrame Window or dialog whose focused descendant may be committed.
function Widgets.CommitFocus(scopeFrame)
    local focus        = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
    local parentFrame  = focus
    while parentFrame and parentFrame ~= scopeFrame do
        parentFrame = parentFrame:GetParent()
    end
    if parentFrame then
        focus:ClearFocus()
    end
end

-- --- small helpers --------------------------------------------------------------

-- Create a font string with the requested text and optional font style.
-- @param parent Frame that owns the font string.
-- @param text Initial text to display.
-- @param font Optional WoW font object name.
local function Label(parent, text, font)
    local labelText = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormal")
    labelText:SetText(text)
    if font == "GameFontDisableSmall" then
        labelText:SetTextColor(unpack(MUTED))
    elseif not font or font == "GameFontNormal" or font == "GameFontNormalLarge" or font == "GameFontNormalSmall" then
        labelText:SetTextColor(unpack(ACCENT))
    end
    return labelText
end

-- Create a standard panel button with the requested label and width.
-- @param parent Frame that owns the button.
-- @param text Button label.
-- @param width Optional button width in pixels.
-- @param variant Optional style name; compact selects smaller dimensions and fonts.
local function Button(parent, text, width, variant)
    local button = CreateFrame("Button", nil, parent, "SharedButtonSmallTemplate")
    button:SetSize(width or 100, variant == "compact" and 20 or 28)
    button:SetText(text)
    Widgets.StyleButton(button, variant)
    return button
end

-- Create a non-autofocusing edit box with optional numeric input and focus-clearing keys.
-- @param parent Frame that owns the edit box.
-- @param width Edit-box width in pixels.
-- @param numeric Whether input should be restricted to numbers.
local function EditBox(parent, width, numeric)
    local editBox = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    editBox:SetSize(width, 20)
    Widgets.Surface(editBox)
    editBox:SetTextInsets(6, 6, 0, 0)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject(ChatFontNormal)
    if numeric then
        editBox:SetNumeric(true)
    end
    editBox:SetScript("OnEscapePressed", editBox.ClearFocus)
    editBox:SetScript("OnEnterPressed", editBox.ClearFocus)
    -- Highlights the edit-box border while it has keyboard focus.
    -- @param self Edit box receiving focus.
    editBox:HookScript("OnEditFocusGained", function(self)
        self:SetBackdropBorderColor(unpack(ACCENT))
    end)
    -- Restores the idle border color when keyboard focus leaves the edit box.
    -- @param self Edit box losing focus.
    editBox:HookScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(unpack(BORDER))
    end)
    return editBox
end

-- Create a checkbox with a text label positioned beside it.
-- @param parent Frame that owns the checkbox.
-- @param label Text displayed beside the checkbox.
local function Check(parent, label)
    local checkButton = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    checkButton:SetSize(24, 24)
    checkButton.labelFS = checkButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    checkButton.labelFS:SetPoint("LEFT", checkButton, "RIGHT", 2, 0)
    checkButton.labelFS:SetText(label)
    return checkButton
end

-- Attach hover handlers that show and hide a widget's tooltip.
-- @param widget Interactive frame receiving the hover handlers.
-- @param title First tooltip line.
-- @param text Optional wrapped description below the title.
local function Tooltip(widget, title, text)
    -- Shows this widget's configured title and optional description.
    -- @param self Hovered widget that owns the tooltip.
    widget:HookScript("OnEnter", function(self)
        -- Show the configured tooltip title and optional description above this widget.
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(title)
        if text then
            GameTooltip:AddLine(text, 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    -- Hides the tooltip when the pointer leaves the widget.
    widget:HookScript("OnLeave", function()
        -- Hide the widget tooltip when the pointer leaves.
        GameTooltip:Hide()
    end)
end

-- Map a localized class name (or token) back to its class token for color lookups.
-- @param class Localized class name or canonical class token.
local function ClassToken(class)
    if type(class) ~= "string" or class == "" then
        return nil
    end
    for listIndex, names in ipairs({ LOCALIZED_CLASS_NAMES_MALE or {}, LOCALIZED_CLASS_NAMES_FEMALE or {} }) do
        for token, localized in pairs(names) do
            if localized == class then
                return token
            end
        end
    end
    return (class:upper():gsub("%s+", ""))
end

-- Return class RGB values, falling back to white when the class color is unavailable.
-- @param class Localized class name or token used to find a class color.
local function ClassColor(class)
    local classToken  = ClassToken(class)
    local classColor  = classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
    if classColor then
        return classColor.r, classColor.g, classColor.b
    end
    return 1, 1, 1
end

-- --- dropdowns ----------------------------------------------------------------

-- Retain the small fallback for clients where Blizzard_Menu is not loaded.
local dropList -- Shared fallback option list, created on first open and reused by every dropdown.
local dropBlocker -- Full-screen click catcher beneath the fallback list that closes it.

-- Hide the shared dropdown list if it has been created.
local function CloseDropdown()
    if dropList then
        dropList:Hide()
    end
end

-- Create or reuse the shared dropdown list and bind it to this control's options.
-- @param dropdown Fallback dropdown whose options and selection own the open list.
local function OpenDropdown(dropdown)
    if not dropList then
        -- Full-screen catcher under the list: a click anywhere else closes it.
        dropBlocker = CreateFrame("Button", nil, UIParent)
        dropBlocker:SetAllPoints(UIParent)
        dropBlocker:SetFrameStrata("FULLSCREEN_DIALOG")
        dropBlocker:RegisterForClicks("AnyUp")
        dropBlocker:SetScript("OnClick", CloseDropdown)
        dropBlocker:Hide()
        dropList = CreateFrame("Frame", "BatataScanner_DropdownList", UIParent, "BackdropTemplate")
        Widgets.Surface(dropList, true)
        dropList:SetFrameStrata("FULLSCREEN_DIALOG")
        dropList:SetFrameLevel(dropBlocker:GetFrameLevel() + 10)
        dropList:EnableMouse(true)
        dropList:SetClampedToScreen(true)
        dropList.rows = {}
        -- Closes the outside-click catcher and releases the dropdown owner.
        -- @param self Shared option list being hidden.
        dropList:SetScript("OnHide", function(self)
            -- Hide the outside-click catcher and clear ownership when the dropdown list closes.
            dropBlocker:Hide()
            self.owner = nil
        end)
        dropList:Hide()
        tinsert(UISpecialFrames, "BatataScanner_DropdownList")
    end
    if dropList:IsShown() and dropList.owner == dropdown then
        CloseDropdown()
        return
    end
    dropList.owner = dropdown
    local rows = dropList.rows
    for rowIndex, dropdownOption in ipairs(dropdown.options) do
        local row = rows[rowIndex]
        if not row then
            row = CreateFrame("Button", nil, dropList)
            row:SetHeight(ROW_H)
            row:SetPoint("TOPLEFT", 6, -6 - (rowIndex - 1) * ROW_H)
            row:SetPoint("RIGHT", -6, 0)
            row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            row.check = row:CreateTexture(nil, "OVERLAY")
            row.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
            row.check:SetSize(14, 14)
            row.check:SetPoint("LEFT", 2, 0)
            row.fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.fs:SetPoint("LEFT", 20, 0)
            row.fs:SetPoint("RIGHT", -4, 0)
            row.fs:SetJustifyH("LEFT")
            -- Selects this row's option on the dropdown that owns the open list.
            -- @param self Recycled option row clicked by the user.
            row:SetScript("OnClick", function(self)
                -- Close the list and select the clicked option on the owning dropdown.
                local owner = dropList.owner
                CloseDropdown()
                if owner then
                    owner:Select(self.index)
                end
            end)
            rows[rowIndex] = row
        end
        row.index = rowIndex
        row.fs:SetText(dropdownOption.label)
        row.check:SetShown(rowIndex == dropdown.index)
        row:Show()
    end
    for rowIndex = #dropdown.options + 1, #rows do
        rows[rowIndex]:Hide()
    end
    dropList:SetSize(dropdown:GetWidth(), #dropdown.options * ROW_H + 12)
    dropList:ClearAllPoints()
    dropList:SetPoint("TOPLEFT", dropdown, "BOTTOMLEFT", 0, -2)
    dropBlocker:Show()
    dropList:Show()
end

-- Dropdown box: shows the chosen option; clicking opens the option list below it.
-- @param parent Frame that owns the fallback dropdown.
-- @param width Dropdown width in pixels.
-- @param onChange Optional callback invoked with the selected option value.
local function FallbackDropdown(parent, width, onChange)
    local dropdown = CreateFrame("Button", nil, parent, "BackdropTemplate")
    dropdown:SetSize(width, 24)
    Widgets.Surface(dropdown)
    dropdown.fs = dropdown:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dropdown.fs:SetPoint("LEFT", 8, 0)
    dropdown.fs:SetPoint("RIGHT", -24, 0)
    dropdown.fs:SetJustifyH("LEFT")
    dropdown.fs:SetWordWrap(false)
    local arrow = dropdown:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
    arrow:SetSize(20, 20)
    arrow:SetPoint("RIGHT", -2, 0)
    dropdown.options, dropdown.index = {}, 1
    -- Refresh the dropdown label from its selected option.
    -- @param self Fallback dropdown whose label should be refreshed.
    local function Refresh(self)
        local dropdownOption = self.options[self.index]
        self.fs:SetText(dropdownOption and dropdownOption.label or "")
    end
    -- Replace dropdown options, clamp the selected index, and refresh the label.
    -- @param dropdownOptions Ordered option records containing label and value fields.
    function dropdown:SetOptions(dropdownOptions)
        self.options  = dropdownOptions
        self.index    = math.min(self.index, math.max(#dropdownOptions, 1))
        Refresh(self)
    end
    -- Select a dropdown option by its stored value without firing the change callback.
    -- @param selectedValue Value to locate in the option list.
    function dropdown:SetValue(selectedValue)
        for optionIndex, dropdownOption in ipairs(self.options) do
            if dropdownOption.value == selectedValue then
                self.index = optionIndex
            end
        end
        Refresh(self)
    end
    -- Return the stored value of the selected dropdown option.
    function dropdown:GetValue()
        local dropdownOption = self.options[self.index]
        return dropdownOption and dropdownOption.value
    end
    -- Select an option by index and notify the caller of its value.
    -- @param optionIndex One-based index of the option to select.
    function dropdown:Select(optionIndex)
        self.index = optionIndex
        Refresh(self)
        if onChange then
            onChange(self:GetValue())
        end
    end
    dropdown:SetScript("OnClick", OpenDropdown)
    -- Highlights the dropdown border while the pointer is over it.
    -- @param self Fallback dropdown under the pointer.
    dropdown:SetScript("OnEnter", function(self)
        -- Highlight the dropdown border while the pointer is over it.
        self:SetBackdropBorderColor(unpack(ACCENT))
    end)
    -- Restores the idle border after the pointer leaves the dropdown.
    -- @param self Fallback dropdown no longer under the pointer.
    dropdown:SetScript("OnLeave", function(self)
        -- Restore the normal dropdown border when the pointer leaves.
        self:SetBackdropBorderColor(unpack(BORDER))
    end)
    -- Closes the shared option list if this dropdown owns it.
    -- @param self Fallback dropdown being hidden.
    dropdown:SetScript("OnHide", function(self)
        -- Close the shared option list if its owning dropdown is hidden.
        if dropList and dropList.owner == self then
            CloseDropdown()
        end
    end)
    return dropdown
end

-- Preserve the panel-facing value API while letting Blizzard own menu input and lifetime.
-- @param parent Frame that owns the dropdown.
-- @param width Dropdown width in pixels.
-- @param onChange Optional callback invoked with the selected option value.
local function Dropdown(parent, width, onChange)
    if
        not (
            MenuUtil
            and C_XMLUtil
            and C_XMLUtil.GetTemplateInfo
            and C_XMLUtil.GetTemplateInfo("WowStyle1DropdownTemplate")
        )
    then
        return FallbackDropdown(parent, width, onChange)
    end
    local dropdown = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    dropdown:SetSize(width, 24)
    dropdown.options  = {}
    dropdown.index    = 1
    dropdown:SetDefaultText("")
    -- Closes any open menu, replaces the options, clamps the selection, and rebuilds the menu.
    -- @param options Ordered option records containing label and value fields.
    function dropdown:SetOptions(options)
        self:CloseMenu()
        self.options  = options
        self.index    = math.min(self.index, math.max(#options, 1))
        self:GenerateMenu()
    end
    -- Selects the first option with a matching value without firing the change callback.
    -- @param value Option value to locate.
    function dropdown:SetValue(value)
        for optionIndex, option in ipairs(self.options) do
            if option.value == value then
                self.index = optionIndex
                break
            end
        end
        self:GenerateMenu()
    end
    -- Returns the selected option's value, or nil when no option is selected.
    function dropdown:GetValue()
        local option = self.options[self.index]
        return option and option.value
    end
    -- Selects an existing option index, refreshes the menu, and reports the new value to onChange.
    -- @param optionIndex One-based index of the option to select.
    function dropdown:Select(optionIndex)
        if not self.options[optionIndex] then
            return
        end
        self.index = optionIndex
        self:GenerateMenu()
        if onChange then
            onChange(self:GetValue())
        end
    end
    -- Adds radio entries for the owner's current options to the Blizzard menu root.
    -- @param owner Dropdown button whose options and selected index drive the menu.
    -- @param root Menu root that receives the radio entries.
    dropdown:SetupMenu(function(owner, root)
        for optionIndex, option in ipairs(owner.options) do
            -- Reports whether this option index is the selected radio entry.
            root:CreateRadio(option.label, function(index)
                return owner.index == index
            -- Selects this option index and invokes the dropdown change callback.
            end, function(index)
                owner:Select(index)
            end, optionIndex)
        end
    end)
    return dropdown
            -- Re-ellipsizes visible text after the recycled row width changes.
end

-- --- list table -----------------------------------------------------------------

local tableCount = 0 -- Running count that gives each table's scroll frame a unique global name.

-- Measure with an unconstrained font string and remove whole UTF-8 characters.
-- @param text Text to fit into the available width.
-- @param width Maximum rendered width in pixels.
-- @param measure Font string used to measure candidate text widths.
local function Ellipsize(text, width, measure)
    measure:SetText(text)
    if measure:GetStringWidth() <= width then
        return text
    end
    measure:SetText("...")
    if measure:GetStringWidth() > width then
        return ""
    end
    local ending = #text
    while ending > 0 do
        local characterStart = ending
        while characterStart > 1 and text:byte(characterStart) >= 128 and text:byte(characterStart) < 192 do
            characterStart = characterStart - 1
        end
        ending = characterStart - 1
        local shortened = text:sub(1, ending):gsub("%s+$", "") .. "..."
        measure:SetText(shortened)
        if measure:GetStringWidth() <= width then
            return shortened
        end
    end
    return "..."
end

-- Fixed-width columns run left to right; the one without a width stretches; the rest hug the right edge.
-- @param parent Row or header frame that owns the cells.
-- @param cells Ordered cell widgets to position.
-- @param columns Column definitions, including optional fixed widths.
-- @param rightPad Optional spacing at the right edge.
-- @param leftPad Optional spacing at the left edge.
-- @param headerCells Whether header-specific insets and gaps should be used.
local function LayoutCells(parent, cells, columns, rightPad, leftPad, headerCells)
    rightPad  = rightPad or 0
    leftPad   = leftPad or 4
    local cellGap     = headerCells and -2 or CELL_GAP
    local extraWidth  = headerCells and CELL_GAP + 2 or 0
    if headerCells then
        leftPad   = leftPad - 8
        rightPad  = rightPad + 2
    end
    local flexColumnIndex = #columns
    for columnIndex, column in ipairs(columns) do
        if not column.width then
            flexColumnIndex = columnIndex
            break
        end
    end
    local previousCell
    local nextCell
    for columnIndex = 1, flexColumnIndex - 1 do
        cells[columnIndex]:SetWidth(columns[columnIndex].width + extraWidth)
        if previousCell then
            cells[columnIndex]:SetPoint("LEFT", previousCell, "RIGHT", cellGap, 0)
        else
            cells[columnIndex]:SetPoint("LEFT", parent, "LEFT", leftPad, 0)
        end
        previousCell = cells[columnIndex]
    end
    for columnIndex = #columns, flexColumnIndex + 1, -1 do
        cells[columnIndex]:SetWidth(columns[columnIndex].width + extraWidth)
        if nextCell then
            cells[columnIndex]:SetPoint("RIGHT", nextCell, "LEFT", -cellGap, 0)
        else
            cells[columnIndex]:SetPoint("RIGHT", parent, "RIGHT", -(rightPad + 2), 0)
        end
        nextCell = cells[columnIndex]
    end
    local flexCell = cells[flexColumnIndex]
    if previousCell then
        flexCell:SetPoint("LEFT", previousCell, "RIGHT", cellGap, 0)
    else
        flexCell:SetPoint("LEFT", parent, "LEFT", leftPad, 0)
    end
    if nextCell then
        flexCell:SetPoint("RIGHT", nextCell, "LEFT", -cellGap, 0)
    else
        flexCell:SetPoint("RIGHT", parent, "RIGHT", -(rightPad + 2), 0)
    end
end

-- Keep column text aligned while the header artwork spans the complete row border.
-- @param parent Header frame that owns the buttons.
-- @param headers Ordered header buttons aligned with columns.
-- @param columns Matching column layout definitions.
-- @param rightPad Optional space reserved for a trailing action control.
-- @param leftPad Optional leading inset for the first header.
function Widgets.LayoutTableHeaders(parent, headers, columns, rightPad, leftPad)
    rightPad  = rightPad or 0
    leftPad   = leftPad or 4
    LayoutCells(parent, headers, columns, rightPad, leftPad, true)

    local firstHeader   = headers[1]
    local leadingSpace  = leftPad - 4
    if leadingSpace > 0 then
        firstHeader:SetPoint("LEFT", parent, "LEFT", -4, 0)
        firstHeader.fs:SetPoint("LEFT", 8 + leadingSpace, 0)
        if columns[1].width and #columns > 1 then
            firstHeader:SetWidth(firstHeader:GetWidth() + leadingSpace)
        end
    end

    local lastHeader = headers[#headers]
    if rightPad > 0 then
        local actionHeader = Widgets.TableHeader(parent, "")
        actionHeader:SetPoint("LEFT", lastHeader, "RIGHT", -2, 0)
        actionHeader:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
        return actionHeader
    end

    local fixedLastColumn = false
    for columnIndex = 1, #columns - 1 do
        if not columns[columnIndex].width then
            fixedLastColumn = true
            break
        end
    end
    if fixedLastColumn then
        lastHeader:SetWidth(lastHeader:GetWidth() + 4)
    end
    lastHeader:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
end

-- Creates a scrolling list table with optional headers and recycled rows; returns its controller.
-- @param parent Frame that owns the table.
-- @param columns Ordered column definitions for labels, values, and optional formatting.
-- @param tableOptions Optional row, scrolling, selection, click, sort, and tooltip behavior.
local function CreateTable(parent, columns, tableOptions)
    tableOptions = tableOptions or {}
    local scrollGutter  = tableOptions.scrollBarBox and 0 or TABLE_SCROLL_GUTTER
    local headerHeight  = tableOptions.hideHeader and 0 or HEADER_H
    tableCount = tableCount + 1
    local listTable   = { rows = {}, items = {}, numRows = 0, renderRows = 0, rowHeight = ROW_H }
    local tableFrame  = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    Widgets.TableBackground(tableFrame, headerHeight)
    tableFrame:SetClipsChildren(true)
    listTable.frame = tableFrame

    -- Returns the virtual provider's item count when one is set, otherwise the static list length.
    function listTable:ItemCount()
        return self.providerGet and self.providerCount or #self.items
    end

    -- Returns the item at an index from the provider or static list, or nil when out of range.
    -- @param itemIndex One-based index in the complete item collection.
    function listTable:GetItem(itemIndex)
        if itemIndex < 1 or itemIndex > self:ItemCount() then
            return nil
        end
        if self.providerGet then
            return self.providerGet(itemIndex)
        end
        return self.items[itemIndex]
    end
    local textMeasure
    for columnIndex, column in ipairs(columns) do
        if column.ellipsis then
            textMeasure = tableFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            textMeasure:SetPoint("TOPLEFT")
            textMeasure:Hide()
            break
        end
    end
    -- Fills a cell from its column definition: an icon texture, or text ellipsized when requested.
    -- @param cell Cell widget receiving the item display.
    -- @param column Column definition that formats the value or icon.
    -- @param item Record currently bound to the row.
    local function SetCellText(cell, column, item)
        if column.icon then
            local texture,
                coords = column.icon(item)
            cell.icon:SetShown(texture ~= nil)
            if texture then
                cell.icon:SetTexture(texture)
                cell.icon:SetTexCoord(unpack(coords or { 0, 1, 0, 1 }))
            end
            return
        end
        local text = column.text(item) or ""
        if column.ellipsis then
            text = Ellipsize(tostring(text), math.max(0, cell:GetWidth() - CELL_GAP), textMeasure)
        end
        cell:SetText(text)
    end

    local header
    local headers = {}
    if not tableOptions.hideHeader then
        header = CreateFrame("Frame", nil, tableFrame)
        header:SetPoint("TOPLEFT", 4, 0)
        header:SetPoint("TOPRIGHT", -scrollGutter, 0)
        header:SetHeight(headerHeight)
        for columnIndex, column in ipairs(columns) do
            local onSort
            if column.sort and tableOptions.onSort then
                -- Delegates this column header click to the table's sort handler.
                onSort = function()
                    tableOptions.onSort(column.key)
                end
            end
            local headerButton = Widgets.TableHeader(header, column.label, onSort)
            -- Native labels keep their inset without reserving space for a sort arrow.
            if column.width then
                column.width = math.max(column.width, headerButton.labelWidth + 6)
            end
            headers[columnIndex] = headerButton
        end
        -- Eight-pixel label insets and overlapping header edges align with the row cells.
        Widgets.LayoutTableHeaders(header, headers, columns)
    end
    listTable.headers  = headers
    listTable.header   = header

    -- Outer frame height needed for an exact number of visible rows.
    -- @param rowCount Number of complete data rows to fit below the header.
    function listTable:HeightForRows(rowCount)
        return headerHeight + rowCount * self.rowHeight + 2
    end

    local scroll =
        CreateFrame("ScrollFrame", "BatataScanner_Table" .. tableCount, tableFrame, "FauxScrollFrameTemplate")
    local layoutInProgress = false
    listTable.scroll = scroll
    if header then
        scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT")
    else
        scroll:SetPoint("TOPLEFT", tableFrame, "TOPLEFT", 4, 0)
    end
    scroll:SetPoint("BOTTOMRIGHT", -scrollGutter, 2)
    listTable.scrollBar =
        Widgets.TableScrollBar(tableFrame, scroll, nil, tableOptions.scrollBarBox, tableOptions.alwaysShowScrollBar)

    listTable.empty = tableFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    listTable.empty:SetPoint("TOPLEFT", scroll, "TOPLEFT", 4, -4)
    listTable.empty:SetPoint("RIGHT", scroll, "RIGHT", -4, 0)
    listTable.empty:SetJustifyH("LEFT")

    -- Create a reusable table row with cells and selection art.
    -- @param rowIndex One-based visual row slot in the scroll window.
    local function CreateRow(rowIndex)
        local row = CreateFrame("Button", nil, tableFrame)
        row:SetHeight(listTable.rowHeight)
        row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(rowIndex - 1) * listTable.rowHeight)
        row:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 0, -(rowIndex - 1) * listTable.rowHeight)
        Widgets.TableRow(row)
        if tableOptions.clickOnDown then
            row:RegisterForClicks("LeftButtonDown", "RightButtonDown")
        else
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        end
        row.sel    = Widgets.TableSelection(row)
        row.cells  = {}
        for columnIndex, column in ipairs(columns) do
            if column.icon then
                local iconCell = CreateFrame("Frame", nil, row)
                iconCell:SetHeight(listTable.rowHeight)
                iconCell.icon = iconCell:CreateTexture(nil, "OVERLAY")
                iconCell.icon:SetSize(16, 16)
                iconCell.icon:SetPoint("CENTER")
                iconCell.icon:Hide()
                row.cells[columnIndex] = iconCell
            else
                local cellText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                cellText:SetJustifyH("LEFT")
                cellText:SetWordWrap(false)
                row.cells[columnIndex] = cellText
            end
        end
        LayoutCells(row, row.cells, columns)
        if textMeasure then
            -- Recalculates ellipsized cells when a recycled row is resized.
            row:HookScript("OnSizeChanged", function()
                if row.item then
                    for columnIndex, column in ipairs(columns) do
                        if column.ellipsis then
                            SetCellText(row.cells[columnIndex], column, row.item)
                        end
                    end
                end
            end)
        end
        -- Forwards the bound record and mouse button to the configured item handler.
        -- @param self Recycled row that was clicked.
        -- @param mouseButton Mouse button used for the click.
        row:SetScript("OnClick", function(self, mouseButton)
            -- Forward row clicks and the mouse button to the table's item handler.
            if self.item and tableOptions.onClick then
                tableOptions.onClick(self.item, mouseButton, self)
            end
        end)
        if tableOptions.tooltip then
            -- Shows the configured tooltip for the row's currently bound record.
            -- @param self Recycled row currently under the pointer.
            row:SetScript("OnEnter", function(self)
                -- Show the configured item tooltip for the row currently under the pointer.
                if not self.item then
                    return
                end
                local title,
                    text = tableOptions.tooltip(self.item)
                if not title then
                    return
                end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(title)
                if text and text ~= "" then
                    GameTooltip:AddLine(text, 1, 1, 1, true)
                end
                GameTooltip:Show()
            end)
            -- Hides the row tooltip after the pointer leaves.
            row:SetScript("OnLeave", function()
                -- Hide the table-row tooltip when the pointer leaves.
                GameTooltip:Hide()
            end)
        end
        row:Hide()
        listTable.rows[rowIndex] = row
    end

    -- Bind the current scroll window to reusable rows and update text and colors.
    function listTable:Bind()
        if layoutInProgress then
            return
        end
        local offset = FauxScrollFrame_GetOffset(scroll)
        for rowIndex, row in ipairs(listTable.rows) do
            local item = rowIndex <= listTable.renderRows and listTable:GetItem(rowIndex + offset)
            if row.item and (not item or row.item.id ~= item.id or row.item ~= item) then
                if GameTooltip and GameTooltip:IsOwned(row) then
                    GameTooltip:Hide()
                end
            end
            if item then
                row.item = item
                for columnIndex, column in ipairs(columns) do
                    SetCellText(row.cells[columnIndex], column, item)
                    if column.color then
                        row.cells[columnIndex]:SetTextColor(column.color(item))
                    elseif not column.icon then
                        row.cells[columnIndex]:SetTextColor(1, 1, 1)
                    end
                end
                row.sel:SetShown(tableOptions.isSelected and tableOptions.isSelected(item) and true or false)
                row:Show()
            else
                row.item = nil
                row:Hide()
            end
        end
        FauxScrollFrame_Update(scroll, listTable:ItemCount(), listTable.numRows, self.rowHeight)
        if tableOptions.alwaysShowScrollBar and listTable:ItemCount() <= listTable.numRows then
            -- FauxScrollFrame can retain its old range when hiding a list that fits.
            local slider = scroll.ScrollBar or _G[scroll:GetName() .. "ScrollBar"]
            slider:SetMinMaxValues(0, 0)
            slider:SetValue(0)
        end
        listTable.empty:SetText(
            listTable:ItemCount() == 0 and (tableOptions.emptyText and tableOptions.emptyText() or "Nothing here.")
                or ""
        )
    end

    -- Replace table items, clamp an out-of-range scroll offset, and rebind visible rows.
    -- @param items Complete static item list to display instead of a virtual provider.
    function listTable:SetItems(items)
        self.providerGet    = nil
        self.providerCount  = nil
        listTable.items     = items or {}
        local maxOffset = math.max(0, listTable:ItemCount() - listTable.numRows)
        if FauxScrollFrame_GetOffset(scroll) > maxOffset then
            local scrollBar = scroll.ScrollBar or _G[scroll:GetName() .. "ScrollBar"]
            if scrollBar then
                scrollBar:SetValue(maxOffset * self.rowHeight)
            end
        end
        listTable:Bind()
    end

    -- Virtual providers retain the same native row window without retaining every fetched record.
    -- @param total Total number of items exposed by the provider.
    -- @param getItem Function returning the item at a one-based index.
    -- @param preserveScroll Whether to keep the current offset, clamped to the new range.
    function listTable:SetProvider(total, getItem, preserveScroll)
        assert(type(getItem) == "function", "A table provider must supply an item getter")
        self.providerCount  = math.max(0, math.floor(tonumber(total) or 0))
        self.providerGet    = getItem
        self.items          = {}
        local maxOffset  = math.max(0, self:ItemCount() - self.numRows)
        local offset     = preserveScroll and math.min(FauxScrollFrame_GetOffset(scroll), maxOffset) or 0
        local slider     = scroll.ScrollBar or _G[scroll:GetName() .. "ScrollBar"]
        FauxScrollFrame_Update(scroll, self:ItemCount(), self.numRows, self.rowHeight)
        if slider then
            slider:SetValue(offset * self.rowHeight)
        end
        -- Rebinds visible rows after restoring the requested provider scroll position.
        FauxScrollFrame_OnVerticalScroll(scroll, offset * self.rowHeight, self.rowHeight, function()
            self:Bind()
        end)
    end

    -- Converts the native vertical position to a row offset and rebinds visible items.
    -- @param self Scroll frame whose offset changed.
    -- @param offset Vertical scroll offset in pixels.
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        if layoutInProgress then
            return
        end
        -- Translate vertical scrolling into a row offset and refresh the table display.
        -- @param frame Table scroll frame receiving the native event.
        -- @param offset New scroll offset in pixels.
        FauxScrollFrame_OnVerticalScroll(self, offset, listTable.rowHeight, function()
            -- Rebind reusable table rows after the scroll offset changes.
            listTable:Bind()
        end)
    end)
    -- Recounts visible and rendered rows, repositions them, and rebinds at a clamped scroll offset.
    function listTable:Layout()
        if layoutInProgress then
            return
        end
        layoutInProgress = true
        local offset = FauxScrollFrame_GetOffset(scroll)
        -- Draw the partially visible bottom row, while paging by complete rows
        -- so the final member can still be scrolled fully into view.
        local visibleRowCount  = math.max(1, math.floor(scroll:GetHeight() / self.rowHeight))
        local renderRowCount   = math.max(1, math.ceil(scroll:GetHeight() / self.rowHeight))
        for rowIndex = #listTable.rows + 1, renderRowCount do
            CreateRow(rowIndex)
        end
        listTable.numRows     = visibleRowCount
        listTable.renderRows  = renderRowCount
        for rowIndex, row in ipairs(self.rows) do
            row:SetHeight(self.rowHeight)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(rowIndex - 1) * self.rowHeight)
            row:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 0, -(rowIndex - 1) * self.rowHeight)
        end
        local slider = scroll.ScrollBar or _G[scroll:GetName() .. "ScrollBar"]
        slider.scrollStep = self.rowHeight
        FauxScrollFrame_Update(scroll, self:ItemCount(), self.numRows, self.rowHeight)
        local maxOffset = math.max(0, self:ItemCount() - self.numRows)
        FauxScrollFrame_OnVerticalScroll(
            scroll,
            math.min(offset, maxOffset) * self.rowHeight,
            self.rowHeight,
            -- Clears the layout guard and binds rows once the native range is updated.
            function()
                layoutInProgress = false
                self:Bind()
            end
        )
    end

    -- Recalculates the visible row count when the table viewport is resized.
    scroll:HookScript("OnSizeChanged", function()
        listTable:Layout()
    end)
    return listTable
end

-- A bounded section: its heading stays still and only overflowing content scrolls.
-- measure(width) sizes the content and returns its natural height at that width.
-- @param parent Frame that owns the section.
-- @param title Optional fixed heading shown above the scrollable content.
-- @param onScroll Optional callback invoked after the scroll position changes.
-- @param options Optional inset, heading, scrollbar, and visibility settings.
function Widgets.ScrollSection(parent, title, onScroll, options)
    options = options or {}
    local section = CreateFrame("Frame", nil, parent)
    section.headingHeight        = options.headingHeight or (title and 18 or 0)
    section.contentInset         = options.contentInset or 0
    section.bottomInset          = options.bottomInset or 0
    section.alwaysShowScrollBar  = options.alwaysShowScrollBar or false
    if title then
        section.title = Label(section, title, "GameFontNormalSmall")
        section.title:SetPoint("TOPLEFT")
    end
    section.scroll = CreateFrame("ScrollFrame", nil, section)
    section.scroll:SetPoint("TOPLEFT", section.contentInset, -section.headingHeight)
    section.scroll:SetClipsChildren(true)
    section.content = CreateFrame("Frame", nil, section.scroll)
    section.scroll:SetScrollChild(section.content)
    section.bar = CreateFrame("Slider", nil, section)
    section.bar:SetOrientation("VERTICAL")
    section.bar:SetPoint("TOPRIGHT", 0, -section.headingHeight)
    section.bar:SetPoint("BOTTOMRIGHT")
    section.bar:SetWidth(8)
    section.bar:SetValueStep(1)
    section.bar:SetMinMaxValues(0, 0)
    section.bar.scrollStep  = 20
    section.range           = 0
    -- Applies scrollbar values to the content offset and notifies the caller after movement.
    -- @param slider Scrollbar whose value changed.
    -- @param value New vertical offset in pixels.
    section.bar:SetScript("OnValueChanged", function(slider, value)
        local offset = math.max(0, math.min(section.range, value))
        if offset ~= section.scroll:GetVerticalScroll() then
            section.scroll:SetVerticalScroll(offset)
            if onScroll then
                onScroll()
            end
        end
    end)
    section.scroll:EnableMouseWheel(true)
    -- Moves the scroll position by one fixed step for each mouse-wheel notch.
    -- @param scrollFrame Content frame receiving the wheel event.
    -- @param delta Signed wheel movement reported by the client.
    section.scroll:SetScript("OnMouseWheel", function(scrollFrame, delta)
        if section.range > 0 then
            section.bar:SetValue(math.max(0, math.min(section.range, scrollFrame:GetVerticalScroll() - delta * 20)))
        end
    end)
    section.scrollBar =
        Widgets.ModernScrollBar(section.scroll, section.bar, options.scrollBarBox, options.alwaysShowScrollBar)
    if not options.scrollBarBox then
        section.scrollBar:ClearAllPoints()
        section.scrollBar:SetPoint("TOPRIGHT", section, "TOPRIGHT", -5 - section.contentInset, -section.headingHeight)
        section.scrollBar:SetPoint(
            "BOTTOMRIGHT",
            section,
            "BOTTOMRIGHT",
            -5 - section.contentInset,
            section.bottomInset
        )
    end
    -- Scrolls the section content back to the top.
    function section:Reset()
        self.bar:SetValue(0)
    end
    -- Sizes the viewport and content via measure, narrowing content when an inline scrollbar is shown.
    -- @param width Available section width in pixels.
    -- @param height Available section height in pixels.
    -- @param measure Function that sizes content at a width and returns its natural height.
    function section:Layout(width, height, measure)
        local viewportHeight  = math.max(1, height - self.headingHeight - self.bottomInset)
        local contentWidth    = math.max(1, width - self.contentInset * 2)
        local contentHeight   = math.max(1, measure(contentWidth))
        local overflow        = contentHeight > viewportHeight
        local showScrollBar   = overflow or self.alwaysShowScrollBar
        if showScrollBar and viewportHeight >= 24 and not options.scrollBarBox then
            contentWidth   = math.max(1, contentWidth - 22)
            contentHeight  = math.max(1, measure(contentWidth))
        end
        self:SetSize(width, height)
        self.scroll:SetSize(contentWidth, viewportHeight)
        self.content:SetSize(contentWidth, contentHeight)
        self.range = math.max(0, contentHeight - viewportHeight)
        self.bar:SetMinMaxValues(0, self.range)
        self.bar:SetShown(showScrollBar)
        self.bar:SetValue(math.min(self.scroll:GetVerticalScroll(), self.range))
    end
    return section
end

-- Headerless Professions surface with a Done footer; Escape closes it and its owner attaches it.
-- @param name Global frame name used for Escape registration.
-- @param width Initial dialog width in pixels.
-- @param height Initial dialog height in pixels.
function Widgets.SettingsDialog(name, width, height)
    local dialog = CreateFrame("Frame", name, UIParent, "InsetFrameTemplate")
    dialog:SetSize(width, height)
    dialog:SetFrameStrata("DIALOG")
    dialog:EnableMouse(true)
    dialog:SetClampedToScreen(true)
    dialog:Hide()
    tinsert(UISpecialFrames, name)
    dialog.Bg:SetAtlas("Professions-background-summarylist")
    dialog.Bg:SetHorizTile(false)
    dialog.Bg:SetVertTile(false)
    dialog.NineSlice:Hide()
    dialog.batataBorder = dialog:CreateTexture(nil, "BORDER", nil, 1)
    dialog.batataBorder:SetAtlas("common-insideframe")
    dialog.batataBorder:SetAllPoints()

    dialog.content = CreateFrame("Frame", nil, dialog)
    dialog.content:SetPoint("TOPLEFT", 14, -14)
    dialog.content:SetPoint("BOTTOMRIGHT", -14, 36)
    dialog.doneButton = Button(dialog, "Done", 72, "compact")
    dialog.doneButton:SetPoint("BOTTOMRIGHT", -12, 8)
    -- Closes the dialog when its Done button is pressed.
    dialog.doneButton:SetScript("OnClick", function()
        dialog:Hide()
    end)
    -- Resizes the dialog to fit the content height plus its insets and Done footer.
    -- @param contentHeight Natural content height in pixels.
    function dialog:SetContentHeight(contentHeight)
        self:SetHeight(math.ceil(contentHeight) + 50)
    end
    return dialog
end

-- Borderless titled group; the settings window supplies the only frame.
-- @param parent Settings dialog or section that owns the group.
-- @param title Group heading.
-- @param height Group height in pixels.
function Widgets.SettingsSection(parent, title, height)
    local section = CreateFrame("Frame", nil, parent)
    section:SetHeight(height)
    section.title = Label(section, title, "GameFontNormalSmall")
    section.title:SetPoint("TOPLEFT")
    section.title:SetPoint("TOPRIGHT")
    section.title:SetJustifyH("LEFT")
    section.title:SetWordWrap(false)
    section.content = CreateFrame("Frame", nil, section)
    section.content:SetPoint("TOPLEFT", 0, -24)
    section.content:SetPoint("BOTTOMRIGHT")
    return section
end

-- Creates the standard Settings button that panels wire to open their settings dialog.
-- @param parent Frame that owns the button.
function Widgets.SettingsButton(parent)
    return Button(parent, "Settings", 92)
end

-- Native search artwork used by GuildHQ's player and guild tables.
local function SearchBox(parent, width)
    local editBox = CreateFrame("EditBox", nil, parent, "SearchBoxTemplate")
    editBox:SetSize(width or 200, 20)
    editBox:SetAutoFocus(false)
    editBox:SetScript("OnEscapePressed", editBox.ClearFocus)
    editBox:SetScript("OnEnterPressed", editBox.ClearFocus)
    return editBox
end

-- Export shared layout constants, constructors, and helpers for the panels.
Widgets.ROW_H                = ROW_H
Widgets.HEADER_H             = HEADER_H
Widgets.CELL_GAP             = CELL_GAP
Widgets.TABLE_SCROLL_GUTTER  = TABLE_SCROLL_GUTTER
Widgets.Label                = Label
Widgets.Button               = Button
Widgets.EditBox              = EditBox
Widgets.Check                = Check
Widgets.Tooltip              = Tooltip
Widgets.ClassToken           = ClassToken
Widgets.ClassColor           = ClassColor
Widgets.Dropdown             = Dropdown
Widgets.Ellipsize            = Ellipsize
Widgets.CreateTable          = CreateTable
Widgets.SearchBox            = SearchBox
