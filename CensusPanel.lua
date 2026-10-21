-- BatataScanner: the scanner census in GuildHQ's native table presentation.
local ADDON,
    NS = ...

local Panel = {}
NS.CensusPanel = Panel

local Widgets       = NS.Widgets
local ROW_HEIGHT    = 20
local COUNT_WIDTH   = 76
local CLASS_TOKENS  = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local labelWidth    = 110

-- GuildHQ's Forever race/class display definitions; observations are never constrained by these rows.
local FACTION_RACES = {
    Alliance = {
        {
            id       = 1,
            name     = "Human",
            classes  = { "WARRIOR", "HUNTER", "MAGE", "ROGUE", "PRIEST", "WARLOCK", "PALADIN" },
        },
        { id = 3, name = "Dwarf", classes = { "WARRIOR", "HUNTER", "ROGUE", "PRIEST", "PALADIN", "SHAMAN" } },
        { id = 4, name = "Night Elf", classes = { "WARRIOR", "HUNTER", "ROGUE", "PRIEST", "DRUID" } },
        { id = 7, name = "Gnome", classes = { "WARRIOR", "MAGE", "ROGUE", "PRIEST", "WARLOCK" } },
        { id = 95, name = "High Order Skyborne", classes = { "WARRIOR", "HUNTER", "MAGE", "ROGUE", "DRUID" } },
    },
    Horde = {
        { id = 2, name = "Orc", classes = { "WARRIOR", "HUNTER", "MAGE", "ROGUE", "WARLOCK", "SHAMAN" } },
        { id = 5, name = "Undead", classes = { "WARRIOR", "MAGE", "ROGUE", "PRIEST", "WARLOCK", "PALADIN" } },
        { id = 6, name = "Tauren", classes = { "WARRIOR", "HUNTER", "DRUID", "SHAMAN" } },
        { id = 8, name = "Troll", classes = { "WARRIOR", "HUNTER", "MAGE", "ROGUE", "PRIEST", "WARLOCK", "SHAMAN" } },
        { id = 96, name = "Windshaper Skyborne", classes = { "WARRIOR", "HUNTER", "ROGUE", "DRUID", "SHAMAN" } },
    },
}

local function ClassName(token)
    if token == "Unknown" or token == "UNKNOWN" then
        return "Unknown"
    end
    local names = LOCALIZED_CLASS_NAMES_MALE
    return names and NS.Readable(names[token]) and names[token] or token
end

local function ClassEntries(counts, allowedClasses)
    local entries   = {}
    local included  = {}
    local function AddClass(token)
        if included[token] then
            return
        end
        included[token] = true
        local colors = RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
            or GRAY_FONT_COLOR
            or { r = 0.5, g = 0.5, b = 0.5 }
        entries[#entries + 1] = {
            label  = ClassName(token),
            token  = token,
            count  = counts[token] or 0,
            red    = colors.r,
            green  = colors.g,
            blue   = colors.b,
        }
    end
    for classIndex, token in ipairs(allowedClasses or {}) do
        AddClass(token)
    end
    for token in pairs(counts) do
        if counts[token] > 0 then
            AddClass(token)
        end
    end
    return entries
end

local function SortOption(section)
    local settings  = NS.db and NS.db.settings
    local choices   = settings and settings.censusSort or Panel.sortOptions or {}
    local choice    = choices[section] or {}
    return choice.key == "name" and "name" or "count", choice.ascending == true
end

local function SortEntries(entries, section)
    local key,
        ascending = SortOption(section)
    for entryIndex, entry in ipairs(entries) do
        entry.sortName = entry.label:lower()
    end
    table.sort(entries, function(leftEntry, rightEntry)
        local leftValue   = key == "name" and leftEntry.sortName or leftEntry.count
        local rightValue  = key == "name" and rightEntry.sortName or rightEntry.count
        if leftValue ~= rightValue then
            if ascending then
                return leftValue < rightValue
            end
            return leftValue > rightValue
        end
        if leftEntry.sortName ~= rightEntry.sortName then
            return leftEntry.sortName < rightEntry.sortName
        end
        return (leftEntry.token or leftEntry.label) < (rightEntry.token or rightEntry.label)
    end)
end

local function ResetScroll(scroll)
    if not scroll then
        return
    end
    scroll.offset = 0
    local scrollBar = scroll.ScrollBar or _G[scroll:GetName() .. "ScrollBar"]
    if scrollBar then
        scrollBar:SetValue(0)
    end
end

function Panel:SetSort(section, key)
    local settings  = NS.db and NS.db.settings
    local choices   = settings and settings.censusSort or self.sortOptions or {}
    if settings then
        settings.censusSort = choices
    else
        self.sortOptions = choices
    end
    local oldKey,
        ascending = SortOption(section)
    choices[section] = { key = key, ascending = oldKey == key and not ascending or (oldKey ~= key and key == "name") }
    ResetScroll(self[section .. "Scroll"])
    self:Draw()
end

local function CreateBarRow(box, rowIndex)
    local row = CreateFrame("Frame", nil, box.rowContainer)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(rowIndex - 1) * ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", 0, -(rowIndex - 1) * ROW_HEIGHT)
    Widgets.TableRow(row)

    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.label:SetPoint("LEFT", 4, 0)
    row.label:SetWidth(labelWidth)
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)

    row.count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.count:SetPoint("RIGHT", -4, 0)
    row.count:SetWidth(COUNT_WIDTH)
    row.count:SetJustifyH("RIGHT")

    row.background = row:CreateTexture(nil, "BACKGROUND")
    row.background:SetPoint("LEFT", row.label, "RIGHT", 6, 0)
    row.background:SetPoint("RIGHT", row.count, "LEFT", -6, 0)
    row.background:SetHeight(14)
    row.background:SetColorTexture(1, 1, 1, 0.06)

    row.fill = row:CreateTexture(nil, "ARTWORK")
    row.fill:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
    row.fill:SetPoint("LEFT", row.background, "LEFT")
    row.fill:SetHeight(14)

    box.rows[rowIndex] = row
    return row
end

local function LayoutChart(box, scroll, gutter, height)
    local page = scroll:GetParent()
    scroll:SetPoint("TOPLEFT", page, "TOPLEFT", 24, -scroll.topInset)
    scroll:SetPoint("TOPRIGHT", page, "TOPRIGHT", -24 - gutter, -scroll.topInset)
    scroll:SetHeight(height)
end

local function DrawChart(box, scroll, entries, total, maximum, tintLabel)
    local page             = scroll:GetParent()
    local availableHeight  = math.max(1, page:GetHeight() - scroll.topInset - 14 - 18 - scroll.bottomInset)
    local visible          = math.max(1, math.floor(availableHeight / ROW_HEIGHT))
    local height           = math.min(math.max(1, math.min(#entries, visible)) * ROW_HEIGHT, availableHeight)
    local offset           = math.min(FauxScrollFrame_GetOffset(scroll), math.max(0, #entries - visible))
    LayoutChart(box, scroll, #entries > visible and Widgets.TABLE_SCROLL_GUTTER or 0, height)
    if offset ~= FauxScrollFrame_GetOffset(scroll) then
        scroll.offset = offset
        local scrollBar = scroll.ScrollBar or _G[scroll:GetName() .. "ScrollBar"]
        if scrollBar then
            scrollBar:SetValue(offset * ROW_HEIGHT)
        end
    end
    local barWidth  = math.max(0, box:GetWidth() - labelWidth - COUNT_WIDTH - 20)
    local shown     = 0
    for rowIndex = 1, visible do
        local entry = entries[offset + rowIndex]
        if not entry then
            break
        end
        local row = box.rows[rowIndex] or CreateBarRow(box, rowIndex)
        row.entry = entry
        Widgets.BindTableRow(row, offset + rowIndex)
        row.label:SetText(entry.label)
        if tintLabel then
            row.label:SetTextColor(entry.red, entry.green, entry.blue)
        else
            row.label:SetTextColor(1, 1, 1)
        end
        row.fill:SetVertexColor(entry.red, entry.green, entry.blue, 0.9)
        row.fill:SetWidth(entry.count > 0 and math.max(1, barWidth * entry.count / math.max(maximum, 1)) or 0)
        row.count:SetText(string.format("%d (%.0f%%)", entry.count, 100 * entry.count / math.max(total, 1)))
        row:Show()
        shown = rowIndex
    end
    for rowIndex = shown + 1, #box.rows do
        box.rows[rowIndex].entry = nil
        box.rows[rowIndex]:Hide()
    end
    FauxScrollFrame_Update(scroll, #entries, visible, ROW_HEIGHT)
end

local function Maximum(entries)
    local maximum = 1
    for entryIndex, entry in ipairs(entries) do
        maximum = math.max(maximum, entry.count)
    end
    return maximum
end

local function ScopeFilters(race)
    local context = NS.context or {}
    return { realm = context.realm, faction = context.faction, race = race }
end

local function UpdateRaceSelector(snapshot)
    local races        = {}
    local added        = {}
    local definitions  = {}
    local faction      = NS.context and NS.context.faction
    for factionName, factionRaces in pairs(FACTION_RACES) do
        for raceIndex, definition in ipairs(factionRaces) do
            local localizedName = definition.name
            if C_CreatureInfo and C_CreatureInfo.GetRaceInfo then
                local succeeded,
                    info = pcall(C_CreatureInfo.GetRaceInfo, definition.id)
                if succeeded and NS.Accessible(info) then
                    localizedName = NS.Text(info.raceName) or localizedName
                end
            end
            definitions[definition.name:lower()]  = definition.classes
            definitions[localizedName:lower()]    = definition.classes
            if factionName == faction then
                races[#races + 1]     = { value = localizedName, label = localizedName }
                added[localizedName]  = true
            end
        end
    end
    Panel.raceClasses = definitions
    local function AddRace(value)
        local race = NS.Text(value)
        if race and not added[race] then
            added[race]        = true
            races[#races + 1]  = { value = race, label = race }
        end
    end
    if C_FriendList and C_FriendList.GetWhoRaceFilters then
        local succeeded,
            filters = pcall(C_FriendList.GetWhoRaceFilters)
        if succeeded and NS.Accessible(filters) then
            for filterIndex = 1, math.min(#filters, 64) do
                local filter = filters[filterIndex]
                if NS.Accessible(filter) then
                    AddRace(filter.name)
                end
            end
        end
    end
    local observedRaces = {}
    for race in pairs(snapshot.byRace) do
        observedRaces[#observedRaces + 1] = race
    end
    table.sort(observedRaces)
    for raceIndex, race in ipairs(observedRaces) do
        AddRace(race)
    end
    local signatureParts = {}
    for raceIndex, race in ipairs(races) do
        signatureParts[raceIndex] = #race.value .. ":" .. race.value
    end
    local signature = table.concat(signatureParts, "|")
    if signature ~= Panel.raceSignature then
        Panel.raceSignature  = signature
        Panel.raceOptions    = races
        if not added[Panel.selectedRace] then
            Panel.selectedRace = races[1] and races[1].value
            ResetScroll(Panel.raceScroll)
        end
        Panel.raceDropdown:SetOptions(races)
        Panel.raceDropdown:SetValue(Panel.selectedRace)
    end
    Panel.raceDropdown:SetShown(#races > 0)
    Panel.raceLabel:SetShown(#races > 0)
end

local function RaceSnapshot(race)
    if Panel.raceSnapshots[race] then
        return Panel.raceSnapshots[race]
    end
    local snapshot
    if race == "Unknown" then
        -- The API's Unknown aggregate includes absent race values, which an exact race filter cannot select.
        local counts = {}
        for token, count in pairs(Panel.snapshot.byClass) do
            counts[token] = count
        end
        for knownRace in pairs(Panel.snapshot.byRace) do
            if knownRace ~= "Unknown" then
                local knownSnapshot = RaceSnapshot(knownRace)
                for token, count in pairs(knownSnapshot.byClass) do
                    counts[token] = math.max(0, (counts[token] or 0) - count)
                end
            end
        end
        snapshot = { total = Panel.snapshot.byRace.Unknown or 0, byClass = counts }
    else
        snapshot = BatataScanner.GetCensus(ScopeFilters(race))
    end
    Panel.raceSnapshots[race] = snapshot
    return snapshot
end

local function GuildView(snapshot)
    local key,
        ascending = SortOption("guild")
    local filter     = Panel.guildFilter or ""
    local signature  = key .. tostring(ascending) .. "\031" .. filter
    if Panel.guildView and Panel.guildViewSnapshot == snapshot and Panel.guildViewSignature == signature then
        return Panel.guildView
    end
    local entries     = {}
    local maximum     = 1
    local guildCount  = 0
    for guildName, count in pairs(snapshot.byGuild) do
        if guildName ~= "" then
            guildCount  = guildCount + 1
            maximum     = math.max(maximum, count)
            if filter == "" or guildName:lower():find(filter, 1, true) then
                entries[#entries + 1] = { label = guildName, count = count, red = 0.25, green = 0.6, blue = 1 }
            end
        end
    end
    SortEntries(entries, "guild")
    Panel.guildViewSnapshot   = snapshot
    Panel.guildViewSignature  = signature
    Panel.guildView           = { entries = entries, maximum = maximum, total = guildCount }
    return Panel.guildView
end

function Panel:Draw()
    if not (self.root and self.root:IsVisible() and self.snapshot) then
        return
    end
    local snapshot = self.snapshot
    if self.navigation.selected == 1 then
        local entries = ClassEntries(snapshot.byClass)
        SortEntries(entries, "class")
        DrawChart(self.classBox, self.classScroll, entries, snapshot.total, Maximum(entries), true)
    elseif self.navigation.selected == 2 then
        local race          = self.selectedRace
        local raceSnapshot  = race and RaceSnapshot(race) or { total = 0, byClass = {} }
        local entries       = ClassEntries(raceSnapshot.byClass, race and self.raceClasses[race:lower()])
        SortEntries(entries, "race")
        DrawChart(self.raceBox, self.raceScroll, entries, raceSnapshot.total, Maximum(entries), true)
        self.raceHeader:SetText(
            race
                    and string.format(
                        "%s (%d, %.0f%%)",
                        race,
                        raceSnapshot.total,
                        100 * raceSnapshot.total / math.max(snapshot.total, 1)
                    )
                or "Races"
        )
        self.raceNote:SetText(
            not race and "No races recorded yet."
                or (raceSnapshot.total == 0 and ("No " .. race .. " players recorded yet.") or "")
        )
    else
        local view = GuildView(snapshot)
        DrawChart(self.guildBox, self.guildScroll, view.entries, snapshot.guilded, view.maximum, false)
        self.noGuilds:SetText(view.total == 0 and "No guilded players seen yet." or "No guild matches the search.")
        self.noGuilds:SetShown(#view.entries == 0)
    end
end

function Panel:Refresh()
    if not (self.root and self.root:IsVisible() and BatataScanner.IsReady()) then
        return
    end
    local snapshot = BatataScanner.GetCensus(ScopeFilters())
    if
        not self.snapshot
        or self.snapshot.revision ~= snapshot.revision
        or self.snapshot.context.key ~= snapshot.context.key
    then
        self.raceSnapshots = {}
    end
    self.snapshot = snapshot
    local guildCount = 0
    for guildName in pairs(snapshot.byGuild) do
        if guildName ~= "" then
            guildCount = guildCount + 1
        end
    end
    self.summary:SetText(
        string.format(
            "Unique players: |cffffffff%d|r    In a guild: |cffffffff%d|r    Unguilded: |cffffffff%d|r    Guilds: |cffffffff%d|r%s",
            snapshot.total,
            snapshot.guilded,
            snapshot.unguilded,
            guildCount,
            snapshot.unknownGuild > 0 and string.format("    Unknown: |cffffffff%d|r", snapshot.unknownGuild) or ""
        )
    )
    UpdateRaceSelector(snapshot)
    self:Draw()
end

local function SortBar(page, box, section, nameLabel, countLabel)
    local countButton = Widgets.TableHeader(page, countLabel, function()
        Panel:SetSort(section, "count")
    end)
    countButton:SetWidth(math.max(COUNT_WIDTH + 4, countButton.labelWidth + 12))
    countButton.fs:SetJustifyH("RIGHT")
    countButton:SetPoint("BOTTOMRIGHT", box, "TOPRIGHT", 0, 1)
    local nameButton = Widgets.TableHeader(page, nameLabel, function()
        Panel:SetSort(section, "name")
    end)
    nameButton:SetPoint("BOTTOMLEFT", box, "TOPLEFT", -4, 1)
    nameButton:SetPoint("RIGHT", countButton, "LEFT", 2, 0)
    Panel.toggles[section] = { nameButton, countButton }
    Widgets.TableBackground(box)
    return nameButton.labelWidth + 12 + countButton:GetWidth()
end

local function CreateChart(page, name, section, nameLabel, countLabel, topInset, bottomInset)
    page.backgroundFrame = CreateFrame("Frame", nil, page, "BackdropTemplate")
    page.backgroundFrame:SetPoint("TOPLEFT", page, "TOPLEFT", 8, -6)
    page.backgroundFrame:SetPoint("BOTTOMRIGHT", page.headerFrame, "BOTTOMRIGHT", -10, 44)
    local inset = page.headerFrame.Inset
    page.backgroundFrame:SetFrameLevel(inset and inset:GetFrameLevel() or page:GetFrameLevel())
    page.backgroundFrame:EnableMouse(false)
    Widgets.ProfileSurface(page.backgroundFrame)

    local scroll = CreateFrame("ScrollFrame", name, page, "FauxScrollFrameTemplate")
    scroll.topInset     = topInset
    scroll.bottomInset  = bottomInset or 0
    scroll:SetScript("OnVerticalScroll", function(frame, offset)
        FauxScrollFrame_OnVerticalScroll(frame, offset, ROW_HEIGHT, function()
            Panel:Draw()
        end)
    end)

    local box = CreateFrame("Frame", nil, page, "BackdropTemplate")
    box:SetPoint("TOPLEFT", scroll, "TOPLEFT")
    box:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT")
    box.rows          = {}
    box.rowContainer  = CreateFrame("Frame", nil, box)
    box.rowContainer:SetAllPoints()
    box.rowContainer:SetClipsChildren(true)
    local sortWidth = SortBar(page, box, section, nameLabel, countLabel)
    Widgets.TableScrollBar(box, scroll)
    LayoutChart(box, scroll, 0, ROW_HEIGHT)
    return box, scroll, sortWidth
end

local function ChartCaption(page, box)
    local caption = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    caption:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -8)
    caption:SetPoint("TOPRIGHT", box, "BOTTOMRIGHT", 0, -8)
    caption:SetHeight(20)
    caption:SetJustifyH("RIGHT")
    caption:SetWordWrap(false)
    caption:SetTextColor(unpack(Widgets.Colors.muted))
    return caption
end

function Panel:Build(root, mainFrame)
    if self.root then
        return
    end
    self.root           = root
    self.toggles        = {}
    self.sortOptions    = {}
    self.raceSnapshots  = {}
    local navigation = { sections = {}, links = {} }
    self.navigation = navigation
    function navigation.Select(sectionId)
        navigation.selected = sectionId
        for sectionIndex, section in ipairs(navigation.sections) do
            section:SetShown(sectionIndex == sectionId)
            navigation.links[sectionIndex]:SetSelected(sectionIndex == sectionId)
        end
        Panel:Draw()
        if NS.UI and NS.UI.UpdateFooterInset then
            NS.UI:UpdateFooterInset()
        end
    end
    for sectionIndex, sectionName in ipairs({ "Classes", "Races", "Guilds" }) do
        local button = Widgets.NavigationButton(root, sectionName)
        if sectionIndex == 1 then
            button:SetPoint("TOPLEFT", root, "TOPLEFT", 18, 0)
        else
            button:SetPoint("LEFT", navigation.links[sectionIndex - 1], "RIGHT", 1, 0)
        end
        button:SetScript("OnClick", function()
            navigation.Select(sectionIndex)
        end)
        navigation.links[sectionIndex] = button
        local section = CreateFrame("Frame", nil, root)
        section.headerFrame = mainFrame
        section:SetPoint("TOPLEFT", root, "TOPLEFT", 0, -24)
        section:SetPoint("BOTTOMRIGHT")
        section:Hide()
        navigation.sections[sectionIndex] = section
    end

    local probe = root:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    for classIndex, token in ipairs(CLASS_TOKENS) do
        probe:SetText(ClassName(token))
        labelWidth = math.max(labelWidth, math.ceil(probe:GetStringWidth()) + 4)
    end
    probe:Hide()
    Widgets.Footer(root, mainFrame, 44)
    self.summary = root:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.summary:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 20, 12)
    self.summary:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -20, 12)
    self.summary:SetHeight(20)
    self.summary:SetJustifyH("LEFT")
    self.summary:SetWordWrap(false)
    self.summary:SetTextColor(unpack(Widgets.Colors.muted))

    local classSortWidth
    self.classBox, self.classScroll, classSortWidth = CreateChart(
        navigation.sections[1],
        "BatataScanner_ClassScroll",
        "class",
        "Class",
        "Players",
        Widgets.HEADER_H + 20
    )
    local racePage = navigation.sections[2]
    self.raceLabel = Widgets.Label(racePage, "Race:", "GameFontHighlightSmall")
    self.raceLabel:SetPoint("TOPLEFT", racePage, "TOPLEFT", 24, -26)
    self.raceDropdown = Widgets.Dropdown(racePage, 200, function(race)
        if not race or race == Panel.selectedRace then
            return
        end
        Panel.selectedRace = race
        ResetScroll(Panel.raceScroll)
        Panel:Draw()
    end)
    self.raceDropdown:SetPoint("LEFT", self.raceLabel, "RIGHT", 8, 0)
    self.raceBox, self.raceScroll =
        CreateChart(racePage, "BatataScanner_RaceScroll", "race", "Class", "Players", Widgets.HEADER_H + 52, 48)
    self.raceHeader  = ChartCaption(racePage, self.raceBox)
    self.raceNote    = racePage:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.raceNote:SetPoint("TOPLEFT", self.raceHeader, "BOTTOMLEFT", 0, -2)
    self.raceNote:SetPoint("TOPRIGHT", self.raceHeader, "BOTTOMRIGHT", 0, -2)
    self.raceNote:SetHeight(16)
    self.raceNote:SetWordWrap(false)

    local guildPage  = navigation.sections[3]
    local search     = CreateFrame("EditBox", nil, guildPage, "SearchBoxTemplate")
    self.guildSearch = search
    search:SetSize(180, 20)
    search:SetPoint("TOPLEFT", guildPage, "TOPLEFT", 24, -20)
    search.Instructions:SetText("Search guilds")
    search:SetScript("OnEscapePressed", function(frame)
        frame:SetText("")
        frame:ClearFocus()
    end)
    search:SetScript("OnEnterPressed", search.ClearFocus)
    search:HookScript("OnTextChanged", function(frame)
        Panel.guildFilter = (NS.Text(frame:GetText(), true) or ""):lower()
        ResetScroll(Panel.guildScroll)
        Panel:Draw()
    end)
    local guildSortWidth
    self.guildBox, self.guildScroll, guildSortWidth = CreateChart(
        guildPage,
        "BatataScanner_GuildScroll",
        "guild",
        "Guild",
        "Population",
        20 + 20 + Widgets.HEADER_H + 8
    )
    self.noGuilds = self.guildBox.rowContainer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.noGuilds:SetPoint("TOPLEFT", self.guildBox, "TOPLEFT", 4, -4)
    self.noGuilds:SetText("No guilded players seen yet.")
    self.minWidth = 48
        + Widgets.TABLE_SCROLL_GUTTER
        + math.max(classSortWidth, guildSortWidth, labelWidth + COUNT_WIDTH + 20, search:GetWidth())
    for sectionIndex, section in ipairs(navigation.sections) do
        section:HookScript("OnSizeChanged", function()
            Panel:Draw()
        end)
    end
    navigation.Select(1)
end
