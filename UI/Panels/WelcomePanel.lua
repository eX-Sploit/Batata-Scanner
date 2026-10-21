-- Batata Scanner: welcome overview and quick start, adapted from GuildHQ.
-- Addon folder name and the private namespace table shared by all addon files.
local ADDON,
    NS = ...

-- Welcome page module: builds and lays out the Overview and Quick start sections.
local Panel = {}
NS.WelcomePanel = Panel -- Exposes the panel so UI.lua can build it and read its icon.

local Widgets = NS.Widgets -- Shared widget factories, colors, and footer metrics.
Panel.icon = "Interface\\Icons\\INV_Misc_Spyglass_03" -- Welcome tab/portrait icon and Overview logo.

-- Section definitions: tab label, layout style, heading text, and cards for each section.
local CONTENT = {
    {
        tab       = "Overview",
        layout    = "features",
        title     = "Batata Scanner",
        subtitle  = "A handy field journal for the players you meet on your WoW Forever adventures.",
        logo      = true,
        footer = "Your collection follows every character on this account. Scanner shows players from the faction you're playing now.",
        cards = {
            {
                title        = "Scanner",
                text         = "Start a /who sweep, keep track of players you encounter, and find them again later.",
                icon         = "Interface\\Icons\\Spell_Nature_Farsight",
                destination  = "Scanner",
            },
            {
                title        = "Census",
                text         = "Take a look at your collection by class, race, level, and guild.",
                icon         = "Interface\\Icons\\inv_misc_map02",
                destination  = "Census",
            },
        },
    },
    {
        tab       = "Quick start",
        layout    = "steps",
        title     = "Your first steps",
        subtitle  = "Start collecting sightings in just a few clicks.",
        cards     = {
            {
                title = "Start scanning",
                text = "Open Scanner, press Play, then click in the world to send the next /who query. Pause whenever you like; your place is saved.",
            },
            {
                title  = "Keep adventuring",
                text   = "Your target, group, and some nearby players are recorded automatically as you play.",
            },
            {
                title  = "Find a familiar face",
                text   = "Use the search box in Scanner to find anyone you've recorded.",
            },
            {
                title  = "Browse your census",
                text   = "Check classes, races, level ranges, and guilds on the Census page.",
            },
            {
                title  = "Prefer chat commands?",
                text   = "Type /bs to open or close this window. Try /bs scan, /bs next, /bs pause, /bs stop, or /bs status in chat.",
            },
        },
    },
}

-- Creates a left-justified, word-wrapping label; defaults to GameFontHighlightSmall.
-- @param parent Frame that owns the label.
-- @param text Initial label text.
-- @param font Optional WoW font object name.
local function Label(parent, text, font)
    local label = Widgets.Label(parent, text, font or "GameFontHighlightSmall")
    label:SetJustifyH("LEFT")
    label:SetWordWrap(true)
    return label
end

-- Builds a clickable Overview card that opens its destination page.
-- @param parent Frame that owns the card.
-- @param entry Feature title, text, icon, and destination from CONTENT.
local function BuildFeatureCard(parent, entry)
    local card = CreateFrame("Button", nil, parent)
    card.padding     = 16
    card.iconSize    = 40
    card.background  = card:CreateTexture(nil, "BACKGROUND")
    card.background:SetAtlas("Profession-overview-Card")
    card.background:SetTextureSliceMargins(12, 12, 12, 12)
    card.background:SetAllPoints()
    card:SetHighlightTexture("Interface\\FriendsFrame\\UI-FriendsFrame-HighlightBar", "ADD")
    card:GetHighlightTexture():SetPoint("TOPLEFT", card, "TOPLEFT", 8, -8)
    card:GetHighlightTexture():SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -8, 8)
    card:GetHighlightTexture():SetAlpha(0.35)

    card.title = Label(card, entry.title, "GameFontNormal")
    card.title:SetPoint("TOP", 0, -25)
    card.title:SetJustifyH("CENTER")
    card.icon = card:CreateTexture(nil, "ARTWORK")
    card.icon:SetTexture(entry.icon)
    card.icon:SetSize(card.iconSize, card.iconSize)
    card.icon:SetPoint("TOP", card.title, "BOTTOM", 0, -12)
    card.body = Label(card, entry.text, "GameFontHighlightSmall2")
    card.body:SetPoint("TOP", card.icon, "BOTTOM", 0, -12)
    card.body:SetJustifyH("CENTER")
    card.body:SetJustifyV("TOP")
    -- Opens the page named by this feature card.
    card:SetScript("OnClick", function()
        NS.UI:SelectPage(entry.destination)
    end)

    -- Fits title, icon, and body to the width; returns the card height, at least 210.
    -- @param width Available card width in pixels.
    function card:Measure(width)
        self:SetWidth(width)
        local textWidth = math.max(1, width - self.padding * 2)
        self.title:SetWidth(textWidth)
        self.body:SetWidth(textWidth)
        local iconSize = math.min(self.iconSize, textWidth)
        self.icon:SetSize(iconSize, iconSize)
        return math.max(
            210,
            25 + self.title:GetStringHeight() + 12 + iconSize + 12 + self.body:GetStringHeight() + self.padding
        )
    end
    return card
end

-- Builds a table-row card with an icon or step number; delegates destination cards.
-- @param parent Frame that owns the card.
-- @param entry Step or feature content used to populate the card.
-- @param cardIndex One-based position used as the step number when no icon exists.
local function BuildCard(parent, entry, cardIndex)
    if entry.destination then
        return BuildFeatureCard(parent, entry)
    end
    local card = CreateFrame("Frame", nil, parent)
    card.padding   = 6
    card.iconSize  = 24
    card.textLeft  = 40

    if entry.icon then
        card.icon = card:CreateTexture(nil, "ARTWORK")
        card.icon:SetTexture(entry.icon)
        card.icon:SetSize(card.iconSize, card.iconSize)
        card.icon:SetPoint("TOPLEFT", card.padding, -card.padding)
    else
        card.number = Label(card, string.format("%02d", cardIndex), "GameFontNormal")
        card.number:SetPoint("TOPLEFT", card.padding, -card.padding)
    end
    card.title = Label(card, entry.title, "GameFontNormal")
    card.title:SetPoint("TOPLEFT", card.textLeft, -card.padding)
    card.body = Label(card, entry.text)
    card.body:SetPoint("TOPLEFT", card.title, "BOTTOMLEFT", 0, -4)

    -- Sets text widths for the card width and returns the padded row height.
    function card:Measure(width)
        self:SetWidth(width)
        local textWidth = math.max(1, width - self.textLeft - self.padding)
        self.title:SetWidth(textWidth)
        self.body:SetWidth(textWidth)
        return math.max(
            self.icon and self.iconSize or 24,
            self.title:GetStringHeight() + 4 + self.body:GetStringHeight()
        ) + self.padding * 2
    end
    return card
end

-- Creates section links, footer credit and version, and scrollable section pages once.
function Panel:Build(root, mainFrame)
    if self.root then
        return
    end
    self.root       = root
    self.mainFrame  = mainFrame
    self.pages      = {}
    local navigation = { sections = {}, links = {} }
    self.navigation = navigation
    -- Shows the chosen section, highlights its link, and re-lays out the panel.
    -- @param sectionId One-based section index to display.
    function navigation.Select(sectionId)
        navigation.selected = sectionId
        for sectionIndex, section in ipairs(navigation.sections) do
            section:SetShown(sectionIndex == sectionId)
            navigation.links[sectionIndex]:SetSelected(sectionIndex == sectionId)
        end
        Panel:Layout()
    end
    for sectionIndex, pageContent in ipairs(CONTENT) do
        local button = Widgets.NavigationButton(root, pageContent.tab)
        if sectionIndex == 1 then
            button:SetPoint("TOPLEFT", root, "TOPLEFT", 18, 0)
        else
            button:SetPoint("LEFT", navigation.links[sectionIndex - 1], "RIGHT", 1, 0)
        end
        -- Selects the section represented by this navigation button.
        -- Selects the subsection represented by this navigation button.
        button:SetScript("OnClick", function()
            navigation.Select(sectionIndex)
        end)
        navigation.links[sectionIndex] = button
        local section = CreateFrame("Frame", nil, root)
        section:SetPoint("TOPLEFT", root, "TOPLEFT", 0, -24)
        section:SetPoint("BOTTOMRIGHT")
        section:Hide()
        navigation.sections[sectionIndex] = section
    end

    Widgets.Footer(root, mainFrame)
    self.credit = Label(root, "Created by |cffffd100Rani|r for WoW Forever")
    self.credit:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 20, 14)
    self.credit:SetTextColor(unpack(Widgets.Colors.muted))
    self.credit:SetWordWrap(false)
    self.credit:SetHeight(14)
    self.version = Label(root, "Version " .. (NS.version or ""))
    self.version:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -20, 14)
    self.version:SetTextColor(unpack(Widgets.Colors.muted))
    self.version:SetJustifyH("RIGHT")
    self.version:SetWordWrap(false)
    self.version:SetHeight(14)

    for pageIndex, pageContent in ipairs(CONTENT) do
        local page = { cards = {}, layout = pageContent.layout }
        self.pages[pageIndex]  = page
        page.root              = navigation.sections[pageIndex]
        page.surface           = CreateFrame("Frame", nil, page.root, "BackdropTemplate")
        Widgets.ProfileSurface(page.surface)
        page.surface:SetPoint("TOPLEFT", page.root, "TOPLEFT", 8, -6)
        page.surface:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -10, Widgets.FOOTER_HEIGHT)
        page.scroll = Widgets.ScrollSection(page.root)
        page.scroll:SetPoint("TOPLEFT", page.root, "TOPLEFT", 24, -18)
        local content = page.scroll.content
        page.header = CreateFrame("Frame", nil, content)
        page.header:SetPoint("TOPLEFT")
        if pageContent.logo then
            page.logo = page.header:CreateTexture(nil, "ARTWORK")
            page.logo:SetTexture(self.icon)
            page.logo:SetSize(48, 48)
            page.logo:SetPoint("TOPLEFT")
        end
        page.title     = Label(page.header, pageContent.title, "GameFontNormalLarge")
        page.subtitle  = Label(page.header, pageContent.subtitle, "GameFontHighlightSmall")
        page.subtitle:SetTextColor(unpack(Widgets.Colors.muted))
        for cardIndex, entry in ipairs(pageContent.cards) do
            page.cards[cardIndex] = BuildCard(content, entry, cardIndex)
        end
        if pageContent.footer then
            page.footer = Label(content, pageContent.footer)
            page.footer:SetTextColor(unpack(Widgets.Colors.muted))
        end
    end

    -- Reflows section cards and scroll content after the Welcome page is resized.
    root:HookScript("OnSizeChanged", function()
        Panel:Layout()
    end)
    -- Recalculates section layout when the Welcome page becomes visible.
    root:HookScript("OnShow", function()
        Panel:Layout()
    end)
    navigation.Select(1)
end

-- Positions the logo, title, and subtitle; returns the header height plus spacing.
-- @param page Page record containing header widgets.
-- @param width Width available for the header content.
local function LayoutHeader(page, width)
    local left       = page.logo and 60 or 0
    local textWidth  = math.max(1, width - left)
    local offset     = 0
    page.header:SetWidth(width)
    page.title:SetWidth(textWidth)
    page.title:ClearAllPoints()
    page.title:SetPoint("TOPLEFT", left, -offset)
    offset = offset + page.title:GetStringHeight() + 6
    page.subtitle:SetWidth(textWidth)
    page.subtitle:ClearAllPoints()
    page.subtitle:SetPoint("TOPLEFT", left, -offset)
    offset = offset + page.subtitle:GetStringHeight()
    local height = math.max(page.logo and 48 or 0, offset)
    page.header:SetHeight(height)
    return height + 10
end

-- Lays out each section's header, card grid, and footer for the current root size.
function Panel:Layout()
    if not self.root then
        return
    end
    -- Leave room for the subsection tabs, the scroll inset, and the footer above the page root.
    local width   = math.max(1, self.root:GetWidth() - 48)
    local height  = math.max(1, self.root:GetHeight() - 24 - 32 - (Widgets.FOOTER_HEIGHT - 26))
    self.version:SetWidth(math.min(120, width / 3))
    self.credit:SetWidth(math.max(1, width - self.version:GetWidth() - 12))
    for pageIndex, page in ipairs(self.pages) do
        -- Sizes cards for the measured content width and returns the required scroll height.
        -- @param contentWidth Width available inside the page's scroll child.
        page.scroll:Layout(width, height, function(contentWidth)
            local offset     = LayoutHeader(page, contentWidth)
            local columns    = page.layout == "features" and #page.cards or 1
            local gap        = page.layout == "steps" and 4 or 8
            local cardWidth  = math.max(1, (contentWidth - gap * (columns - 1)) / columns)
            for rowStart = 1, #page.cards, columns do
                local rowHeight = 0
                for cardIndex = rowStart, math.min(#page.cards, rowStart + columns - 1) do
                    rowHeight = math.max(rowHeight, page.cards[cardIndex]:Measure(cardWidth))
                end
                for cardIndex = rowStart, math.min(#page.cards, rowStart + columns - 1) do
                    local card = page.cards[cardIndex]
                    card:ClearAllPoints()
                    card:SetPoint(
                        "TOPLEFT",
                        page.scroll.content,
                        "TOPLEFT",
                        (cardIndex - rowStart) * (cardWidth + gap),
                        -offset
                    )
                    card:SetHeight(rowHeight)
                end
                offset = offset + rowHeight + gap
            end
            if page.footer then
                page.footer:SetWidth(contentWidth)
                page.footer:ClearAllPoints()
                page.footer:SetPoint("TOPLEFT", page.scroll.content, "TOPLEFT", 0, -offset - 4)
                offset = offset + 4 + page.footer:GetStringHeight()
            end
            return offset
        end)
    end
end
