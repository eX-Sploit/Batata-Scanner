-- Batata Scanner: the scanner census in GuildHQ's native table presentation.
-- Addon name and private namespace supplied by the TOC loader.
local ADDON,
    NS = ...

-- Census page: charts class, race, and guild populations from stored observations.
local Panel = {}
NS.CensusPanel = Panel -- Exposes the panel to the UI shell.

local Widgets      = NS.Widgets -- Shared widget factory and style helpers.
local ROW_HEIGHT   = 20 -- Pixel height of each chart row and of one scroll step.
local COUNT_WIDTH  = 76 -- Width of the right-aligned count and percentage column.
local labelWidth   = 110 -- Chart label column width.

local FACTION_RACES = NS.FactionRaces -- Canonical race definitions used to scope Census options to the current faction.

-- Seconds between shared Census snapshot refreshes while the main window is open.
local REFRESH_INTERVAL = 30
-- Window-scoped timer; hidden Census sections reuse its snapshot without drawing.
local refreshTicker

-- Returns the localized name for a class token, falling back to the token itself.
-- @param token Canonical class token or Unknown marker.
local function ClassName(token)
    if token == "Unknown" or token == "UNKNOWN" then
        return "Unknown"
    end
    local names = LOCALIZED_CLASS_NAMES_MALE
    return names and NS.Readable(names[token]) and names[token] or token
end

-- Returns colored chart entries for the allowed classes and any class with players.
-- @param counts Class names mapped to observed player counts.
-- @param allowedClasses Optional canonical classes that should appear even with zero observations.
local function ClassEntries(counts, allowedClasses)
    local entries   = {}
    local included  = {}
    -- Appends a class entry with its count and class color unless already added.
    -- @param className Localized class label to add once.
    local function AddClass(className)
        if included[className] then
            return
        end
        included[className] = true
        local token   = Widgets.ClassToken(className)
        local colors  = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
            or GRAY_FONT_COLOR
            or { r = 0.5, g = 0.5, b = 0.5 }
        entries[#entries + 1] = {
            label  = className,
            token  = token,
            count  = counts[className] or 0,
            red    = colors.r,
            green  = colors.g,
            blue   = colors.b,
        }
    end
    for classIndex, token in ipairs(allowedClasses or {}) do
        AddClass(ClassName(token))
    end
    for className, count in pairs(counts) do
        if count > 0 then
            AddClass(className)
        end
    end
    return entries
end

-- Returns a section's saved sort key (name or count) and whether it ascends.
-- @param section Sort setting key, such as race or guild.
local function SortOption(section)
    local settings  = NS.db and NS.db.settings
    local choices   = settings and settings.censusSort or Panel.sortOptions or {}
    local choice    = choices[section] or {}
    return choice.key == "name" and "name" or "count", choice.ascending == true
end

-- Sorts entries in place by the section's sort option, breaking ties by name.
-- @param entries Chart entries to sort in place.
-- @param section Sort setting key used to select field and direction.
local function SortEntries(entries, section)
    local key,
        ascending = SortOption(section)
    for entryIndex, entry in ipairs(entries) do
        entry.sortName = entry.label:lower()
    end
    -- Orders two chart entries by the saved key, then stable labels and tokens.
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

-- Scrolls a faux scroll frame back to its first row.
-- @param scroll Faux scroll frame whose vertical offset should be reset.
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

-- Switches or reverses a section's sort, persists it, resets its scroll, and redraws.
-- @param section Census section whose sort state should change.
-- @param key Sort field selected by the user, name or count.
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

-- Creates and caches a chart row with label, bar track, fill, and count text.
-- @param box Chart frame that owns the row collection.
-- @param rowIndex One-based row slot to create.
local function CreateBarRow(box, rowIndex)
    local row = CreateFrame("Frame", nil, box.rowContainer)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(rowIndex - 1) * ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", 0, -(rowIndex - 1) * ROW_HEIGHT)

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

-- Anchors a chart's scroll frame in its page, reserving a scrollbar gutter when needed.
-- @param box Chart frame associated with the scrolling rows.
-- @param scroll Scroll frame to position.
-- @param gutter Horizontal space reserved for a scrollbar.
-- @param height Visible chart height in pixels.
local function LayoutChart(box, scroll, gutter, height)
    local page = scroll:GetParent()
    scroll:SetPoint("TOPLEFT", page, "TOPLEFT", 24, -scroll.topInset)
    scroll:SetPoint("TOPRIGHT", page, "TOPRIGHT", -24 - gutter, -scroll.topInset)
    scroll:SetHeight(height)
end

-- Renders the visible entries as scaled bar rows and updates the faux scroll range.
-- @param box Chart row container and bar geometry source.
-- @param scroll Faux scroll frame controlling the visible entry range.
-- @param entries Ordered display entries to render.
-- @param total Total population used to calculate percentages.
-- @param maximum Largest entry count used to scale bar widths.
-- @param tintLabel Whether each row label uses its entry color.
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

-- Builds race filter options from the current faction, native filters, and observed race names.
-- @param snapshot Current-faction census snapshot containing observed race counts.
local function UpdateRaceOptions(snapshot)
    local races         = {}
    local added         = {}
    local definitions   = {}
    local raceFactions  = {}
    local faction       = NS.context and NS.context.faction
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
            definitions[definition.name:lower()]   = definition.classes
            definitions[localizedName:lower()]     = definition.classes
            raceFactions[definition.name:lower()]  = factionName
            raceFactions[localizedName:lower()]    = factionName
            if not faction or factionName == faction then
                races[#races + 1]     = { value = localizedName, label = localizedName }
                added[localizedName]  = true
            end
        end
    end
    Panel.raceClasses = definitions
    -- Appends a readable race option once.
    -- @param value Candidate localized race name from client filters or observations.
    local function AddRace(value)
        local race         = NS.Text(value)
        local raceFaction  = race and raceFactions[race:lower()]
        if race and not added[race] and (not faction or not raceFaction or raceFaction == faction) then
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
    Panel.raceOptions = races
end

-- Returns or creates the current-faction class-count snapshot for one race.
-- @param race Race label used as the snapshot key.
local function RaceSnapshot(race)
    if not Panel.raceSnapshots[race] then
        Panel.raceSnapshots[race] = { total = 0, byClass = {} }
    end
    return Panel.raceSnapshots[race]
end

-- Repaints only donut slices whose geometry, color, or hover radius changed.
-- @param chart Donut chart holding entries, slices, quad textures, and paint cache.
local function PaintDonut(chart)
    local used = 0
    for sliceIndex, slice in ipairs(chart.slices) do
        local entry        = slice.entry
        local outerRadius  = chart.radius * (entry and entry == chart.hoveredEntry and 1.08 or 1)
        local innerRadius  = chart.radius * 0.60
        local steps        = math.max(1, math.ceil((slice.finish - slice.start) * 144))
        local firstQuad    = used + 1
        local red          = entry and entry.red or 0.25
        local green        = entry and entry.green or 0.25
        local blue         = entry and entry.blue or 0.25
        local painted      = chart.paintedSlices[sliceIndex]
        if
            not painted
            or painted.start ~= slice.start
            or painted.finish ~= slice.finish
            or painted.firstQuad ~= firstQuad
            or painted.outerRadius ~= outerRadius
            or painted.innerRadius ~= innerRadius
            or painted.red ~= red
            or painted.green ~= green
            or painted.blue ~= blue
        then
            for stepIndex = 1, steps do
                local startAngle  = 2 * math.pi * (slice.start + (slice.finish - slice.start) * (stepIndex - 1) / steps)
                local endAngle    = 2 * math.pi * (slice.start + (slice.finish - slice.start) * stepIndex / steps)
                local quadIndex   = used + stepIndex
                local quad        = chart.quads[quadIndex]
                if not quad then
                    quad                    = chart.ring:CreateTexture(nil, "ARTWORK")
                    chart.quads[quadIndex]  = quad
                    quad:SetPoint("CENTER", chart.ring, "CENTER")
                    if quad.SetSnapToPixelGrid then
                        quad:SetSnapToPixelGrid(false)
                    end
                    if quad.SetTexelSnappingBias then
                        quad:SetTexelSnappingBias(0)
                    end
                end
                if not quad.SetVertexOffset then
                    chart.count:SetText("Unavailable")
                    quad:Hide()
                    return
                end
                local startSine    = math.sin(startAngle)
                local startCosine  = math.cos(startAngle)
                local endSine      = math.sin(endAngle)
                local endCosine    = math.cos(endAngle)
                quad:SetColorTexture(red, green, blue)
                quad:SetSize(outerRadius * 2, outerRadius * 2)
                quad:SetVertexOffset(1, outerRadius * startSine + outerRadius, outerRadius * startCosine - outerRadius)
                quad:SetVertexOffset(2, innerRadius * startSine + outerRadius, innerRadius * startCosine + outerRadius)
                quad:SetVertexOffset(3, outerRadius * endSine - outerRadius, outerRadius * endCosine - outerRadius)
                quad:SetVertexOffset(4, innerRadius * endSine - outerRadius, innerRadius * endCosine + outerRadius)
                quad:Show()
            end
            painted                          = painted or {}
            painted.start                    = slice.start
            painted.finish                   = slice.finish
            painted.firstQuad                = firstQuad
            painted.outerRadius              = outerRadius
            painted.innerRadius              = innerRadius
            painted.red                      = red
            painted.green                    = green
            painted.blue                     = blue
            chart.paintedSlices[sliceIndex]  = painted
        end
        used = used + steps
    end
    for sliceIndex = #chart.slices + 1, #chart.paintedSlices do
        chart.paintedSlices[sliceIndex] = nil
    end
    for quadIndex = used + 1, #chart.quads do
        if chart.quads[quadIndex]:IsShown() then
            chart.quads[quadIndex]:Hide()
        end
    end
end

-- Clears a chart's hovered entry, repaints its ring, and hides its tooltip.
-- @param chart Donut chart whose hover state should be cleared.
local function ClearDonutHover(chart)
    if chart.hoveredEntry then
        chart.hoveredEntry = nil
        PaintDonut(chart)
    end
    if GameTooltip:IsOwned(chart.ring) then
        GameTooltip:Hide()
    end
end

-- Finds the slice under the cursor and updates its highlight and tooltip.
-- @param ring Donut ring receiving pointer movement.
local function UpdateDonutHover(ring)
    local chart = ring.chart
    local centerX,
        centerY = ring:GetCenter()
    local cursorX,
        cursorY = GetCursorPosition()
    local scale     = ring:GetEffectiveScale()
    local offsetX   = cursorX / scale - centerX
    local offsetY   = cursorY / scale - centerY
    local distance  = math.sqrt(offsetX * offsetX + offsetY * offsetY)
    local fraction  = (math.atan2(offsetX, offsetY) / (2 * math.pi)) % 1
    local hoveredEntry
    if distance >= chart.radius * 0.60 then
        for sliceIndex, slice in ipairs(chart.slices) do
            local outerRadius = chart.radius * (slice.entry and slice.entry == chart.hoveredEntry and 1.08 or 1)
            if fraction >= slice.start and fraction < slice.finish and distance <= outerRadius then
                hoveredEntry = slice.entry
                break
            end
        end
    end
    if hoveredEntry == chart.hoveredEntry then
        return
    end
    if not hoveredEntry then
        ClearDonutHover(chart)
        return
    end
    chart.hoveredEntry = hoveredEntry
    PaintDonut(chart)
    GameTooltip:SetOwner(ring, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(chart.title)
    GameTooltip:AddLine(hoveredEntry.label, hoveredEntry.red, hoveredEntry.green, hoveredEntry.blue)
    GameTooltip:AddLine(string.format("Players: %d of %d", hoveredEntry.count, chart.total), 1, 1, 1)
    if chart.scope == "race" then
        GameTooltip:AddLine(
            string.format("%.1f%% of this race", 100 * hoveredEntry.count / math.max(chart.total, 1)),
            1,
            1,
            1
        )
    end
    GameTooltip:AddLine(
        string.format("%.1f%% of census", 100 * hoveredEntry.count / math.max(Panel.snapshot.total, 1)),
        1,
        1,
        1
    )
    GameTooltip:Show()
end

-- Creates the reusable ring, center labels, and pointer handlers for a donut chart.
-- @param parent Frame that owns the donut chart.
local function CreateDonut(parent)
    local chart = CreateFrame("Frame", nil, parent)
    chart.quads          = {}
    chart.paintedSlices  = {}
    chart.ring           = CreateFrame("Frame", nil, chart)
    chart.ring.chart     = chart
    chart.ring:EnableMouse(true)
    -- Starts cursor tracking and resolves any slice already under the pointer.
    -- @param ring Donut ring receiving pointer entry.
    chart.ring:SetScript("OnEnter", function(ring)
        ring:SetScript("OnUpdate", UpdateDonutHover)
        UpdateDonutHover(ring)
    end)
    -- Stops cursor tracking and clears the hovered slice when the pointer leaves.
    -- @param ring Donut ring being left.
    chart.ring:SetScript("OnLeave", function(ring)
        ring:SetScript("OnUpdate", nil)
        ClearDonutHover(chart)
    end)
    -- Stops cursor tracking and clears the hovered slice when the chart is hidden.
    -- @param ring Donut ring being hidden.
    chart.ring:SetScript("OnHide", function(ring)
        ring:SetScript("OnUpdate", nil)
        ClearDonutHover(chart)
    end)
    chart.count = chart.ring:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    chart.count:SetPoint("CENTER", chart.ring, "CENTER", 0, 5)
    chart.count:SetJustifyH("CENTER")
    chart.count:SetWordWrap(false)
    chart.unit = chart.ring:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    chart.unit:SetPoint("TOP", chart.count, "BOTTOM", 0, -2)
    chart.unit:SetText("players")
    chart.label = chart:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    chart.label:SetJustifyH("CENTER")
    chart.label:SetWordWrap(true)
    chart.label:SetHeight(28)
    chart.share = chart:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    chart.share:SetPoint("TOPLEFT", chart.label, "BOTTOMLEFT", 0, -2)
    chart.share:SetPoint("TOPRIGHT", chart.label, "BOTTOMRIGHT", 0, -2)
    chart.share:SetHeight(14)
    chart.share:SetWordWrap(false)
    chart.share:SetJustifyH("CENTER")
    return chart
end

-- Binds a title, population, and positive-count slices to an existing donut chart.
-- @param chart Donut chart receiving the data.
-- @param title Chart title displayed above the ring and in its tooltip.
-- @param entries Colored class or race entries with count fields.
-- @param total Population represented by the chart.
-- @param scope Chart scope used to choose percentage wording.
local function BindDonut(chart, title, entries, total, scope)
    ClearDonutHover(chart)
    chart.title    = title
    chart.total    = total
    chart.entries  = entries
    chart.scope    = scope
    chart.slices   = {}
    local fraction = 0
    for entryIndex, entry in ipairs(entries) do
        if entry.count > 0 then
            local finish = math.min(1, fraction + entry.count / math.max(total, 1))
            chart.slices[#chart.slices + 1]  = { entry = entry, start = fraction, finish = finish }
            fraction                         = finish
        end
    end
    if #chart.slices == 0 then
        chart.slices[1] = { start = 0, finish = 1 }
    else
        chart.slices[#chart.slices].finish = 1
    end
    chart.count:SetText(tostring(total))
    chart.label:SetText(title)
end

-- Creates a titled group of labeled metric/value pairs.
-- @param parent Frame that owns the group.
-- @param title Heading displayed above the metrics.
-- @param labels Ordered metric labels to create.
local function CreateStatGroup(parent, title, labels)
    local group = CreateFrame("Frame", nil, parent)
    group.title = group:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    group.title:SetPoint("TOPLEFT")
    group.title:SetPoint("TOPRIGHT")
    group.title:SetHeight(18)
    group.title:SetJustifyH("CENTER")
    group.metrics = {}
    group.title:SetText(title)
    for labelIndex, text in ipairs(labels) do
        local label = group:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        label:SetPoint("TOPLEFT", group, "TOPLEFT", 0, -22 - (labelIndex - 1) * 44)
        label:SetPoint("TOPRIGHT", group, "TOPRIGHT", 0, -22 - (labelIndex - 1) * 44)
        label:SetHeight(12)
        label:SetJustifyH("CENTER")
        label:SetWordWrap(false)
        label:SetText(text)
        local value = group:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        value:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -2)
        value:SetPoint("TOPRIGHT", label, "BOTTOMRIGHT", 0, -2)
        value:SetHeight(28)
        value:SetJustifyH("CENTER")
        value:SetJustifyV("TOP")
        value:SetWordWrap(true)
        group.metrics[labelIndex] = { label = label, value = value }
    end
    return group
end

-- Formats the most common known category and its percentage, or a placeholder.
-- @param counts Category names mapped to counts.
-- @param total Population used as the percentage denominator.
local function MostCommon(counts, total)
    local leadingName
    local leadingCount = 0
    for name, count in pairs(counts) do
        if
            name ~= "Unknown"
            and (count > leadingCount or (count == leadingCount and leadingName and name < leadingName))
        then
            leadingName   = name
            leadingCount  = count
        end
    end
    return leadingName and string.format("%s (%.0f%%)", leadingName, 100 * leadingCount / math.max(total, 1)) or "--"
end

-- Draws current-faction population statistics, class donut, and race donuts.
-- @param snapshot Current-faction census totals and breakdown tables.
local function DrawOverview(snapshot)
    local area          = Panel.overviewArea
    local width         = math.max(1, area:GetWidth())
    local headerHeight  = math.max(160, math.min(244, area:GetHeight() * 0.42))
    local chartWidth    = math.min(240, width * 0.36)
    local sideWidth     = math.max(1, (width - chartWidth) / 2 - 16)
    local sideInset     = (headerHeight - 152) / 2
    Panel.populationStats:SetSize(sideWidth, 152)
    Panel.populationStats:SetPoint("TOPLEFT", area, "TOPLEFT", 0, -sideInset)
    Panel.guildStats:SetSize(sideWidth, 152)
    Panel.guildStats:SetPoint("TOPRIGHT", area, "TOPRIGHT", 0, -sideInset)

    local levelTotal   = 0
    local knownLevels  = 0
    for level, count in pairs(snapshot.byLevel) do
        if level > 0 then
            levelTotal   = levelTotal + level * count
            knownLevels  = knownLevels + count
        end
    end
    Panel.populationStats.metrics[1].value:SetText(
        knownLevels > 0 and string.format("%.1f", levelTotal / knownLevels) or "--"
    )
    Panel.populationStats.metrics[2].value:SetText(MostCommon(snapshot.byClass, snapshot.total))
    Panel.populationStats.metrics[3].value:SetText(MostCommon(snapshot.byRace, snapshot.total))
    for metricIndex, count in ipairs({ snapshot.guilded, snapshot.unguilded, snapshot.unknownGuild }) do
        Panel.guildStats.metrics[metricIndex].value:SetText(
            string.format("%d (%.0f%%)", count, 100 * count / math.max(snapshot.total, 1))
        )
    end

    local chart    = Panel.classChart
    local entries  = ClassEntries(snapshot.byClass)
    SortEntries(entries, "class")
    BindDonut(chart, "Classes", entries, snapshot.total, "census")
    chart.radius = math.max(1, math.min(96, (headerHeight - 24) / 2.16, (chartWidth - 8) / 2.16))
    chart:SetSize(chartWidth, headerHeight)
    chart:SetPoint("TOP", area, "TOP", 0, 0)
    chart.ring:SetSize(chart.radius * 2.16, chart.radius * 2.16)
    chart.ring:SetPoint("TOP", chart, "TOP", 0, -20)
    chart.count:SetWidth(chart.radius * 1.05)
    chart.label:SetPoint("TOPLEFT", chart, "TOPLEFT", 0, 0)
    chart.label:SetPoint("TOPRIGHT", chart, "TOPRIGHT", 0, 0)
    chart.label:SetHeight(18)
    chart.share:Hide()
    PaintDonut(chart)

    Panel.raceArea:SetPoint("TOPLEFT", area, "TOPLEFT", 0, -headerHeight - 12)
    local compactFrameWidth  = math.max(742, NS.ScannerPanel and NS.ScannerPanel.minWidth or 0)
    local compactWidth       = math.max(1, math.min(width, compactFrameWidth - (Panel.mainFrame:GetWidth() - width)))
    local compactHeight      =
        math.max(1, math.min(area:GetHeight(), 480 - (Panel.mainFrame:GetHeight() - area:GetHeight())))
    compactHeight = math.max(1, compactHeight - math.max(160, math.min(244, compactHeight * 0.42)) - 12)
    local height   = math.max(1, Panel.raceArea:GetHeight())
    local count    = #Panel.raceOptions
    local columns  = 1
    local radius   = 0
    for candidateColumns = 1, math.max(1, count) do
        local candidateRows    = math.max(1, math.ceil(count / candidateColumns))
        local candidateRadius  =
            math.min(104, (compactWidth / candidateColumns - 16) / 2.16, (compactHeight / candidateRows - 52) / 2.16)
        if candidateRadius >= radius then
            columns  = candidateColumns
            radius   = candidateRadius
        end
    end
    local rows        = math.max(1, math.ceil(count / columns))
    local cellWidth   = width / columns
    local cellHeight  = height / rows
    radius = math.max(1, math.min(104, (cellWidth - 16) / 2.16, (cellHeight - 52) / 2.16))
    for raceIndex, option in ipairs(Panel.raceOptions) do
        local chart = Panel.raceCharts[raceIndex]
        if not chart then
            chart                        = CreateDonut(Panel.raceArea)
            Panel.raceCharts[raceIndex]  = chart
        end
        local raceSnapshot  = RaceSnapshot(option.value)
        local entries       = ClassEntries(raceSnapshot.byClass, Panel.raceClasses[option.value:lower()])
        SortEntries(entries, "race")
        BindDonut(chart, option.value, entries, raceSnapshot.total, "race")
        chart.race    = option.value
        chart.radius  = radius
        chart:SetSize(cellWidth, cellHeight)
        chart:SetPoint(
            "TOPLEFT",
            Panel.raceArea,
            "TOPLEFT",
            ((raceIndex - 1) % columns) * cellWidth,
            -math.floor((raceIndex - 1) / columns) * cellHeight
        )
        chart.ring:SetSize(radius * 2.16, radius * 2.16)
        chart.ring:SetPoint("TOP", chart, "TOP", 0, -(cellHeight - radius * 2.16 - 48) / 2)
        chart.count:SetWidth(radius * 1.05)
        chart.count:SetText(tostring(chart.total))
        chart.label:ClearAllPoints()
        chart.label:SetPoint("TOPLEFT", chart, "TOPLEFT", 4, -(cellHeight - radius * 2.16 - 48) / 2 - radius * 2.16 - 4)
        chart.label:SetWidth(cellWidth - 8)
        chart.label:SetText(chart.race)
        chart.share:SetText(
            chart.total > 0 and string.format("%.0f%% of census", 100 * chart.total / math.max(snapshot.total, 1))
                or "No observations"
        )
        PaintDonut(chart)
        chart:Show()
    end
    for chartIndex = count + 1, #Panel.raceCharts do
        Panel.raceCharts[chartIndex]:Hide()
    end
end

-- Returns sorted guild entries matching the search text, cached per snapshot and sort.
-- Returns cached sorted guild entries filtered by the current search text.
-- @param snapshot Current-faction census snapshot containing guild counts.
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

-- Restores a level bar's default color and hides its tooltip.
-- @param levelBar Level bar whose hover state is ending.
local function ClearLevelHover(levelBar)
    levelBar.fill:SetColorTexture(0.25, 0.6, 1, 0.9)
    if GameTooltip:IsOwned(levelBar) then
        GameTooltip:Hide()
    end
end

-- Creates a level column with hover details for count and census percentage.
-- @param area Chart frame that owns the level bar.
local function CreateLevelBar(area)
    local levelBar = CreateFrame("Frame", nil, area)
    levelBar:EnableMouse(true)
    levelBar.fill = levelBar:CreateTexture(nil, "ARTWORK")
    levelBar.fill:SetPoint("BOTTOM", levelBar, "BOTTOM", 0, 0)
    levelBar.fill:SetColorTexture(0.25, 0.6, 1, 0.9)
    levelBar.label = levelBar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    levelBar.label:SetPoint("TOP", levelBar, "BOTTOM", 0, -6)
    levelBar.label:SetSize(34, 14)
    levelBar.label:SetJustifyH("CENTER")
    levelBar.label:SetWordWrap(false)
    -- Highlights this level and reports its count and share of the current census.
    -- @param hoveredBar Level bar currently under the pointer.
    levelBar:SetScript("OnEnter", function(hoveredBar)
        hoveredBar.fill:SetColorTexture(0.4, 0.8, 1, 1)
        GameTooltip:SetOwner(hoveredBar, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        GameTooltip:AddLine("Level " .. hoveredBar.level)
        GameTooltip:AddLine(string.format("Players: %d", hoveredBar.count), 1, 1, 1)
        GameTooltip:AddLine(
            string.format("%.1f%% of census", 100 * hoveredBar.count / math.max(hoveredBar.total, 1)),
            1,
            1,
            1
        )
        GameTooltip:Show()
    end)
    levelBar:SetScript("OnLeave", ClearLevelHover)
    levelBar:SetScript("OnHide", ClearLevelHover)
    return levelBar
end

-- Draws the current-faction level histogram and unknown-level summary.
-- @param snapshot Current-faction census totals and level counts.
local function DrawLevels(snapshot)
    local area        = Panel.levelArea
    local width       = math.max(1, area:GetWidth())
    local height      = math.max(1, area:GetHeight())
    local maximum     = 1
    local maxLevel    = 60
    local knownTotal  = 0
    for level, count in pairs(snapshot.byLevel) do
        if level > 0 then
            maxLevel    = math.max(maxLevel, level)
            maximum     = math.max(maximum, count)
            knownTotal  = knownTotal + count
        end
    end
    local tickCount    = math.min(4, maximum)
    local tickStep     = math.ceil(maximum / tickCount)
    local axisMaximum  = tickCount * tickStep
    for tickIndex = 0, tickCount do
        local grid = Panel.levelGrid[tickIndex + 1]
        if not grid then
            grid = {
                line   = area:CreateTexture(nil, "BACKGROUND"),
                label  = area:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"),
            }
            grid.line:SetColorTexture(1, 1, 1, 0.10)
            grid.line:SetHeight(1)
            grid.label:SetPoint("RIGHT", grid.line, "LEFT", -8, 0)
            grid.label:SetSize(36, 14)
            grid.label:SetJustifyH("RIGHT")
            grid.label:SetWordWrap(false)
            Panel.levelGrid[tickIndex + 1] = grid
        end
        grid.line:SetPoint("BOTTOMLEFT", area, "BOTTOMLEFT", 0, height * tickIndex / tickCount)
        grid.line:SetPoint("BOTTOMRIGHT", area, "BOTTOMRIGHT", 0, height * tickIndex / tickCount)
        grid.label:SetText(string.format("%d", tickIndex * tickStep))
        grid.line:Show()
        grid.label:Show()
    end
    for gridIndex = tickCount + 2, #Panel.levelGrid do
        Panel.levelGrid[gridIndex].line:Hide()
        Panel.levelGrid[gridIndex].label:Hide()
    end
    local barWidth   = width / maxLevel
    local labelStep  = math.max(10, math.ceil(maxLevel / 80) * 10)
    for level = 1, maxLevel do
        local levelBar = Panel.levelBars[level]
        if not levelBar then
            levelBar                = CreateLevelBar(area)
            Panel.levelBars[level]  = levelBar
        end
        ClearLevelHover(levelBar)
        levelBar.level  = level
        levelBar.count  = snapshot.byLevel[level] or 0
        levelBar.total  = snapshot.total
        levelBar:SetSize(barWidth, height)
        levelBar:SetPoint("BOTTOMLEFT", area, "BOTTOMLEFT", (level - 1) * barWidth, 0)
        levelBar.fill:SetWidth(math.max(1, barWidth - 2))
        levelBar.fill:SetHeight(levelBar.count > 0 and math.max(1, height * levelBar.count / axisMaximum) or 0)
        levelBar.fill:SetShown(levelBar.count > 0)
        levelBar.label:SetText(tostring(level))
        levelBar.label:SetShown(
            level == 1 or level == maxLevel or (level % labelStep == 0 and level < maxLevel - labelStep / 2)
        )
        levelBar:Show()
    end
    for barIndex = maxLevel + 1, #Panel.levelBars do
        Panel.levelBars[barIndex]:Hide()
    end
    local unknown = snapshot.byLevel[0] or 0
    Panel.levelUnknown:SetText(
        string.format("Unknown level: %d (%.0f%%)", unknown, 100 * unknown / math.max(snapshot.total, 1))
    )
    Panel.levelUnknown:SetShown(unknown > 0)
    Panel.noLevels:SetText(snapshot.total == 0 and "No players recorded yet." or "No known levels recorded yet.")
    Panel.noLevels:SetShown(knownTotal == 0)
end

-- Draws the selected section's chart from the cached snapshot.
function Panel:Draw()
    if not (self.root and self.root:IsVisible() and self.snapshot) then
        return
    end
    local snapshot = self.snapshot
    if self.navigation.selected == 1 then
        DrawOverview(snapshot)
    elseif self.navigation.selected == 2 then
        DrawLevels(snapshot)
    else
        local view = GuildView(snapshot)
        DrawChart(self.guildBox, self.guildScroll, view.entries, snapshot.guilded, view.maximum, false)
        self.noGuilds:SetText(view.total == 0 and "No guilded players seen yet." or "No guild matches the search.")
        self.noGuilds:SetShown(#view.entries == 0)
    end
end

-- Fetches a new census snapshot, updates the summary and race options, then redraws.
-- @param deferDataChanges Reuse an existing same-faction snapshot until the next periodic refresh.
function Panel:Refresh(deferDataChanges)
    if not (self.mainFrame and self.mainFrame:IsShown() and Batata_Scanner.IsReady()) then
        return
    end
    if
        self.snapshot
        and self.snapshotFaction == NS.context.faction
        and (deferDataChanges or self.snapshot.revision == NS.db.revision)
    then
        return
    end
    local faction = NS.context.faction or "Unknown"
    local snapshot,
        raceSnapshots = NS.Store:GetCensusOverview(faction)
    self.raceSnapshots    = raceSnapshots
    self.snapshotFaction  = NS.context.faction
    self.snapshot         = snapshot
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
    UpdateRaceOptions(snapshot)
    self:Draw()
end

-- Builds the name and count sort headers above a chart; returns their combined width.
-- @param page Frame that owns the header buttons.
-- @param box Chart row container aligned beneath the headers.
-- @param section Sort setting key used by the click handlers.
-- @param nameLabel Text for the name sort header.
-- @param countLabel Text for the count sort header.
local function SortBar(page, box, section, nameLabel, countLabel)
    -- Changes this section's sort key to count when its count header is clicked.
    local countButton = Widgets.TableHeader(page, countLabel, function()
        Panel:SetSort(section, "count")
    end)
    countButton:SetWidth(math.max(COUNT_WIDTH + 4, countButton.labelWidth + 12))
    countButton.fs:SetJustifyH("RIGHT")
    countButton:SetPoint("BOTTOMRIGHT", box, "TOPRIGHT", 0, 1)
    -- Changes this section's sort key to name when its name header is clicked.
    local nameButton = Widgets.TableHeader(page, nameLabel, function()
        Panel:SetSort(section, "name")
    end)
    nameButton:SetPoint("BOTTOMLEFT", box, "TOPLEFT", -4, 1)
    nameButton:SetPoint("RIGHT", countButton, "LEFT", 2, 0)
    Panel.toggles[section] = { nameButton, countButton }
    Widgets.TableBackground(box)
    return nameButton.labelWidth + 12 + countButton:GetWidth()
end

-- Builds a section's background, scroll frame, and row box; returns box, scroll, sort width.
-- @param page Census section frame that owns the chart.
-- @param name Scroll-frame global name used to connect its scrollbar.
-- @param section Sort setting key for the chart rows.
-- @param nameLabel Text for the first column header.
-- @param countLabel Text for the count column header.
-- @param topInset Vertical space reserved above the rows.
-- @param bottomInset Optional vertical space reserved below the rows.
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
    -- Updates the faux-scroll offset from the native vertical scroll event.
    -- @param frame Chart scroll frame whose offset changed.
    -- @param offset New vertical offset in pixels.
    scroll:SetScript("OnVerticalScroll", function(frame, offset)
        -- Re-renders rows after the faux-scroll offset has been updated.
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

-- Builds the Overview, Levels, and Guilds sections with their tabs, charts, and summary.
-- @param root Census page root that owns the sections and selector controls.
-- @param mainFrame Main window frame used for chart and footer anchors.
function Panel:Build(root, mainFrame)
    if self.root then
        return
    end
    self.root           = root
    self.mainFrame      = mainFrame
    self.toggles        = {}
    self.sortOptions    = {}
    self.raceSnapshots  = {}
    local navigation = { sections = {}, links = {} }
    self.navigation = navigation
    -- Shows the chosen section, highlights its tab, redraws, and updates the footer inset.
    -- @param sectionId One-based Census section index to display.
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
    for sectionIndex, sectionName in ipairs({ "Overview", "Levels", "Guilds" }) do
        local button = Widgets.NavigationButton(root, sectionName)
        if sectionIndex == 1 then
            button:SetPoint("TOPLEFT", root, "TOPLEFT", 18, 0)
        else
            button:SetPoint("LEFT", navigation.links[sectionIndex - 1], "RIGHT", 1, 0)
        end
        -- Switches to the Census section represented by this navigation button.
        -- Opens the Census section represented by this navigation button.
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

    Widgets.Footer(root, mainFrame, 44)
    self.summary = root:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.summary:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 20, 12)
    self.summary:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -20, 12)
    self.summary:SetHeight(20)
    self.summary:SetJustifyH("LEFT")
    self.summary:SetWordWrap(false)
    self.summary:SetTextColor(unpack(Widgets.Colors.muted))

    local racePage = navigation.sections[1]
    racePage.backgroundFrame = CreateFrame("Frame", nil, racePage, "BackdropTemplate")
    racePage.backgroundFrame:SetPoint("TOPLEFT", racePage, "TOPLEFT", 8, -6)
    racePage.backgroundFrame:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -10, 44)
    racePage.backgroundFrame:EnableMouse(false)
    Widgets.ProfileSurface(racePage.backgroundFrame)
    self.overviewArea = CreateFrame("Frame", nil, racePage)
    self.overviewArea:SetPoint("TOPLEFT", racePage, "TOPLEFT", 24, -18)
    self.overviewArea:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -24, 58)
    self.classChart       = CreateDonut(self.overviewArea)
    self.populationStats  =
        CreateStatGroup(self.overviewArea, "Population", { "Average level", "Most common class", "Most common race" })
    self.guildStats  = CreateStatGroup(self.overviewArea, "Guild membership", { "Guilded", "Unguilded", "Unknown" })
    self.raceArea    = CreateFrame("Frame", nil, self.overviewArea)
    self.raceArea:SetPoint("TOPLEFT", self.overviewArea, "TOPLEFT", 0, -172)
    self.raceArea:SetPoint("BOTTOMRIGHT", self.overviewArea, "BOTTOMRIGHT", 0, 0)
    self.raceCharts = {}

    local levelPage = navigation.sections[2]
    levelPage.backgroundFrame = CreateFrame("Frame", nil, levelPage, "BackdropTemplate")
    levelPage.backgroundFrame:SetPoint("TOPLEFT", levelPage, "TOPLEFT", 8, -6)
    levelPage.backgroundFrame:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -10, 44)
    levelPage.backgroundFrame:SetFrameLevel(math.max(0, levelPage:GetFrameLevel() - 2))
    levelPage.backgroundFrame:EnableMouse(false)
    Widgets.ProfileSurface(levelPage.backgroundFrame)
    local levelTitle = Widgets.Label(levelPage, "Level distribution", "GameFontNormalSmall")
    levelTitle:SetPoint("TOPLEFT", levelPage, "TOPLEFT", 24, -20)
    self.levelArea = CreateFrame("Frame", nil, levelPage)
    self.levelArea:SetPoint("TOPLEFT", levelPage, "TOPLEFT", 60, -58)
    self.levelArea:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -32, 90)
    self.levelBars  = {}
    self.levelGrid  = {}
    local levelAxis = Widgets.Label(levelPage, "Level", "GameFontDisableSmall")
    levelAxis:SetPoint("TOP", self.levelArea, "BOTTOM", 0, -24)
    levelAxis:SetSize(80, 14)
    local countAxis = Widgets.Label(levelPage, "Players", "GameFontDisableSmall")
    countAxis:SetPoint("BOTTOMLEFT", self.levelArea, "TOPLEFT", -36, 12)
    self.levelUnknown = Widgets.Label(levelPage, "", "GameFontDisableSmall")
    self.levelUnknown:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 24, 52)
    self.levelUnknown:SetSize(260, 16)
    self.levelUnknown:SetJustifyH("LEFT")
    self.noLevels = Widgets.Label(self.levelArea, "No players recorded yet.", "GameFontDisableSmall")
    self.noLevels:SetPoint("CENTER")

    local guildPage  = navigation.sections[3]
    local search     = CreateFrame("EditBox", nil, guildPage, "SearchBoxTemplate")
    self.guildSearch = search
    search:SetSize(180, 20)
    search:SetPoint("TOPLEFT", guildPage, "TOPLEFT", 24, -20)
    search.Instructions:SetText("Search guilds")
    -- Clears the guild search and releases keyboard focus when Escape is pressed.
    -- @param frame Guild search box receiving the key event.
    search:SetScript("OnEscapePressed", function(frame)
        frame:SetText("")
        frame:ClearFocus()
    end)
    search:SetScript("OnEnterPressed", search.ClearFocus)
    -- Updates the normalized guild filter and redraws the visible guild rows.
    -- @param frame Guild search box whose text changed.
    search:HookScript("OnTextChanged", function(frame)
        Panel.guildFilter = (NS.Text(frame:GetText(), true) or ""):lower()
        ResetScroll(Panel.guildScroll)
        Panel:Draw()
    end)
    local guildSortWidth
    self.guildBox, self.guildScroll, guildSortWidth = CreateChart(
        guildPage,
        "Batata_Scanner_GuildScroll",
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
        + math.max(guildSortWidth, labelWidth + COUNT_WIDTH + 20, search:GetWidth())
    for sectionIndex, section in ipairs(navigation.sections) do
        -- Redraws the active chart after its section geometry changes.
        section:HookScript("OnSizeChanged", function()
            Panel:Draw()
        end)
    end
    -- Refreshes chart rows when the Census page becomes visible.
    root:HookScript("OnShow", function()
        Panel:Draw()
    end)
    -- Warms all Census sections on window open and starts one shared refresh timer.
    mainFrame:HookScript("OnShow", function()
        if refreshTicker then
            return
        end
        Panel:Refresh()
        -- Copies changed aggregates; only the visible Census section is redrawn.
        refreshTicker = C_Timer.NewTicker(REFRESH_INTERVAL, function()
            Panel:Refresh()
        end)
    end)
    -- Stops periodic Census work when the whole window closes, not when tabs change.
    mainFrame:HookScript("OnHide", function()
        if refreshTicker then
            refreshTicker:Cancel()
            refreshTicker = nil
        end
    end)
    navigation.Select(1)
end
