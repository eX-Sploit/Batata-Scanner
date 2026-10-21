-- Batata Scanner: GuildHQ's scanner browser.
-- Addon name and private namespace supplied by the TOC loader.
local ADDON,
    NS = ...

-- Scanner page: browses stored players and controls the Who census scan.
local Panel = {}
NS.ScannerPanel = Panel -- Exposes the panel to the UI shell.

local Widgets             = NS.Widgets -- Shared widget factory and style helpers.
local TABLE_TOP           = 76 -- Vertical offset where the player table starts below the filters.
local REFRESH_INTERVAL    = 30 -- Minimum seconds between automatic re-searches after data changes.
local RESULT_CACHE_GRACE  = 300 -- Seconds completed search results stay cached after the main window closes.
local CLASS_COLUMNS       = 3 -- Class checkboxes per row in the scan settings dialog.
local CLASS_COLUMN_WIDTH  = 82 -- Horizontal spacing between class checkbox columns.
local CLASS_ICON_TEXTURE  = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes" -- Sliced by CLASS_ICON_TCOORDS.
local sortKey             = "lastSeen" -- Column key the player table is sorted by.
-- Newest timestamps first, so the displayed ages ascend.
local descending      = true
local generation      = 0 -- Search generation; bumping it abandons in-flight search steps.
local refreshPending  = true -- True when results are stale and a re-search is due.
local lastSearchAt    = -REFRESH_INTERVAL -- Start time of the last search; initially allows one at once.
local refreshTimer -- True while a delayed re-search refresh is scheduled.
local results -- Last completed search request feeding the player table.
local activeRequest -- Search request currently being prepared or matched in bounded steps.
local resumeOffset -- Scroll offset restored after a completed replacement search.
local classRevision -- Database revision the class filter options were last checked against.
local classSignature -- Joined class names of the current class options, to skip redundant rebuilds.
local ageTicker -- Visible-panel ticker used to refresh relative first/last-seen labels.
local searchTicker -- Window-scoped ticker that refreshes the browser search every 30 seconds.
local releaseGeneration = 0 -- Invalidates delayed result cleanup when the window is reopened.

-- Guild-status dropdown choices; values map to the searchGuildStatus setting.
local GUILD_FILTERS = {
    { label = "Any guild", value = "" },
    { label = "Guilded", value = "guilded" },
    { label = "Unguilded", value = "unguilded" },
}
-- Last-seen dropdown choices in seconds; zero means no age limit.
local SEEN_FILTERS = {
    { label = "Seen any time", value = 0 },
    { label = "Seen last hour", value = 3600 },
    { label = "Seen last day", value = 86400 },
    { label = "Seen last 7 days", value = 604800 },
    { label = "Seen last 30 days", value = 2592000 },
}

-- Returns guild display text: Unguilded, the guild name, or Unknown.
-- @param player Player row whose tri-state guild value is formatted.
local function GuildText(player)
    return player.guild == "" and "Unguilded" or player.guild or "Unknown"
end

-- Returns the class icon texture and coords, or nil for an unrecognized class.
-- @param player Player row whose class token selects an icon.
local function ClassIcon(player)
    local classToken  = Widgets.ClassToken(player.class)
    local coords      = classToken and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classToken]
    if not coords then
        return nil
    end
    return CLASS_ICON_TEXTURE, coords
end

-- Returns a compact relative age such as Now, 5m ago, 3h ago, or 2d ago.
-- @param timestamp Unix timestamp to compare with the current time.
local function FormatAge(timestamp)
    if not timestamp then
        return "Unknown"
    end
    local elapsed = math.max(0, NS.Now() - timestamp)
    if elapsed < 60 then
        return "Now"
    elseif elapsed < 3600 then
        return math.floor(elapsed / 60) .. "m ago"
    elseif elapsed < 86400 then
        return math.floor(elapsed / 3600) .. "h ago"
    end
    return math.floor(elapsed / 86400) .. "d ago"
end

-- Player table column definitions passed to Widgets.CreateTable.
local columns = {
    {
        key    = "level",
        label  = "Lvl",
        width  = 28,
        sort   = true,
        -- Formats a readable player level as the compact table-cell string.
        -- @param player Player record currently bound to the row.
        text   = function(player)
            return tostring(player.level or "")
        end,
    },
    { key = "class", label = "Class", width = 20, sort = true, icon = ClassIcon },
    {
        key       = "name",
        label     = "Name",
        minWidth  = 80,
        ellipsis  = true,
        sort      = true,
        -- Displays the player's recorded name in the name column.
        -- @param player Player record currently bound to the row.
        text      = function(player)
            return player.name
        end,
        -- Colors the name with the player's class color.
        -- @param player Player record whose class determines the text color.
        color = function(player)
            return Widgets.ClassColor(player.class)
        end,
    },
    { key = "guild", label = "Guild", width = 140, ellipsis = true, sort = true, text = GuildText },
    {
        key    = "firstSeen",
        label  = "First seen",
        width  = 64,
        sort   = true,
        -- Formats the first-seen timestamp as a compact relative age.
        -- @param player Player record currently bound to the row.
        text   = function(player)
            return FormatAge(player.firstSeen)
        end,
    },
    {
        key    = "lastSeen",
        label  = "Last seen",
        width  = 64,
        sort   = true,
        -- Formats the last-seen timestamp as a compact relative age.
        -- @param player Player record currently bound to the row.
        text   = function(player)
            return FormatAge(player.lastSeen)
        end,
    },
}

-- Updates the footer summary with the input error, search progress, or result count.
local function RefreshSummary()
    if Panel.inputError then
        Panel.scanSummary:SetText(Panel.inputError)
    elseif Panel.searching then
        Panel.scanSummary:SetText(string.format("Searching: %d%%", Panel.searchProgress or 0))
    elseif results and results.truncated then
        Panel.scanSummary:SetText(string.format("Showing first %d matches; narrow your search for more.", results.total))
    else
        Panel.scanSummary:SetText(string.format("Showing %d players", results and results.total or 0))
    end
end

-- Cancels and releases the active in-progress search request, if any.
local function CancelSearch()
    if activeRequest then
        activeRequest:Cancel()
        activeRequest = nil
    end
end

-- Binds completed results only while the Scanner tab is visible.
local function BindResults(preserveScroll)
    if not results or not Panel.root:IsVisible() then
        return
    end
    Panel.list:SetProvider(results.total, function(index)
        return results:GetPlayer(index)
    end, preserveScroll)
end

-- Releases retained results and provider rows after the closed-window grace period.
local function ReleaseResults()
    CancelSearch()
    if results then
        results:Cancel()
        results = nil
    end
    resumeOffset    = FauxScrollFrame_GetOffset(Panel.list.scroll)
    refreshPending  = true
    lastSearchAt    = -REFRESH_INTERVAL
    Panel.list:SetItems({})
    generation       = generation + 1
    Panel.searching  = false
end

-- Starts or schedules a stale browser search while the main window is open.
function Panel:RefreshSearch()
    if
        not self.mainFrame
        or not self.mainFrame:IsShown()
        or self.refreshPaused
        or self.searching
        or not refreshPending
    then
        return
    end
    local wait = math.max(0, lastSearchAt + REFRESH_INTERVAL - GetTime())
    if not results or wait == 0 then
        self:Submit(true)
    elseif not refreshTimer then
        refreshTimer = true
        C_Timer.After(wait, function()
            refreshTimer = nil
            Panel:RefreshSearch()
        end)
    end
end

-- Closes scan settings or cancels a running search on Escape; returns true if handled.
function Panel:Escape()
    if self.scanSettings:IsShown() then
        self.scanSettings:Hide()
        return true
    elseif self.searching then
        CancelSearch()
        generation          = generation + 1
        self.searching      = false
        self.refreshPaused  = true
        self.inputError     = "Cancelled. Press Enter to search."
        RefreshSummary()
        return true
    end
    return false
end

-- Search filters narrow the stored-player list only; they never change Who queries.
local function SearchFilters()
    local settings    = NS.db.settings
    local seenWithin  = settings.searchSeenWithin
    return {
        faction      = NS.context.faction,
        minLevel     = settings.searchMinLevel,
        maxLevel     = settings.searchMaxLevel,
        class        = settings.searchClass,
        guildStatus  = settings.searchGuildStatus,
        seenAfter    = seenWithin and math.max(0, NS.Now() - seenWithin) or nil,
    }
end

-- Rebuilds class filter options from recorded classes after the database revision changes.
local function RefreshClassOptions()
    if classRevision == NS.db.revision then
        return
    end
    classRevision = NS.db.revision
    local selectedClass  = NS.db.settings.searchClass
    local classNames     = NS.Store:GetClassNames()
    local selectedFound  = false
    for classIndex, className in ipairs(classNames) do
        if className == selectedClass then
            selectedFound = true
            break
        end
    end
    if selectedClass and not selectedFound then
        classNames[#classNames + 1] = selectedClass
    end
    table.sort(classNames)
    local signature = table.concat(classNames, "\031")
    if signature == classSignature then
        return
    end
    classSignature = signature
    local options = { { label = "All classes", value = "" } }
    for classIndex, className in ipairs(classNames) do
        options[#options + 1] = { label = className, value = className }
    end
    Panel.classFilter:SetOptions(options)
    Panel.classFilter:SetValue(selectedClass or "")
end

-- Starts a frame-sliced search for the input, sort, and filters; supersedes older ones.
function Panel:Submit(preserveScroll)
    CancelSearch()
    if not preserveScroll then
        resumeOffset = nil
    end
    generation      = generation + 1
    self.searching  = false
    local request,
        failure = NS.Store:CreateSearch(self.input:GetText(), sortKey, descending, SearchFilters())
    if not request then
        self.inputError     = failure
        self.refreshPaused  = true
        NS.UI:SyncEscape()
        RefreshSummary()
        return
    end
    activeRequest        = request
    self.inputError      = nil
    self.refreshPaused   = false
    self.searchProgress  = 0
    local currentGeneration = generation
    self.searching = true
    NS.UI:SyncEscape()
    refreshPending  = false
    lastSearchAt    = GetTime()
    -- Advances the search one slice per frame, then binds results to the table when complete.
    local function Step()
        if currentGeneration ~= generation or not Panel.mainFrame:IsShown() then
            request:Cancel()
            if activeRequest == request then
                activeRequest = nil
            end
            return
        end
        local completed = request:Step()
        Panel.searchProgress = math.floor(100 * request.progress / math.max(1, request.limit))
        RefreshSummary()
        if not completed then
            C_Timer.After(0, Step)
            return
        end
        if results then
            results:Cancel()
        end
        results          = request
        activeRequest    = nil
        Panel.searching  = false
        NS.UI:SyncEscape()
        if resumeOffset then
            Panel.list.scroll.offset  = resumeOffset
            resumeOffset              = nil
        end
        -- Fetches a detached player copy for a one-based visible table index.
        -- @param index One-based result position requested by the table provider.
        BindResults(preserveScroll)
        RefreshSummary()
        if Panel.root:IsVisible() then
            Panel:Refresh()
        else
            Panel:RefreshSearch()
        end
    end
    C_Timer.After(0, Step)
end

-- Marks results stale so the next refresh re-runs the search.
-- @param immediate Whether the next refresh may bypass the normal search interval.
function Panel:Invalidate(immediate)
    refreshPending = true
    if immediate then
        lastSearchAt = -REFRESH_INTERVAL
    end
end

-- Syncs scan controls with scanner status and schedules a throttled re-search if stale.
function Panel:Refresh()
    self:RefreshSearch()
    if not self.root or not self.root:IsVisible() then
        return
    end
    RefreshClassOptions()
    local status    = Batata_Scanner.GetScanStatus()
    local pausable  = status.running and not status.paused
    self.scanButton.playIcon:SetShown(not pausable)
    for iconIndex, icon in ipairs(self.scanButton.pauseIcon) do
        icon:SetShown(pausable)
    end
    local label       = "Stopped"
    local labelColor  = { 1, 0.3, 0.3 }
    if status.inCombat and pausable then
        label       = "Paused: Combat"
        labelColor  = { 1, 0.82, 0 }
    elseif status.inBattleground and pausable then
        label       = "Paused: Battleground"
        labelColor  = { 1, 0.82, 0 }
    elseif status.environmentUnavailable and pausable then
        label       = "Paused: Unavailable"
        labelColor  = { 1, 0.82, 0 }
    elseif status.pendingLateResponse then
        label       = string.format(pausable and "Retry in %ds" or "Cooldown: %ds", status.cooldown)
        labelColor  = { 1, 0.82, 0 }
    elseif status.externalQueryPending then
        label       = "Waiting for Who"
        labelColor  = { 1, 0.82, 0 }
    elseif status.nativeWhoOpen and pausable then
        label       = "Paused: Who"
        labelColor  = { 1, 0.82, 0 }
    elseif status.cooldown > 0 and not status.awaiting and not pausable then
        label       = string.format("Cooldown: %ds", status.cooldown)
        labelColor  = { 1, 0.82, 0 }
    elseif status.paused then
        label       = "Paused"
        labelColor  = { 1, 0.82, 0 }
    elseif status.running or status.awaiting then
        label       = "Scanning"
        labelColor  = { 0.3, 1, 0.3 }
    end
    self.scanStatus:SetText(label)
    self.scanStatus:SetTextColor(unpack(labelColor))
    self.stopBtn:SetEnabled(status.running or status.paused or status.awaiting)
    self.scanButton:SetEnabled(
        pausable
            or (
                not status.pendingLateResponse
                and not status.externalQueryPending
                and not status.nativeWhoOpen
                and not status.inCombat
                and not status.inBattleground
                and not status.environmentUnavailable
                and not status.awaiting
                and status.cooldown == 0
            )
    )
    RefreshSummary()
end

-- Switches a widget between its enabled and disabled states.
-- @param control Widget whose enabled state should change.
-- @param enabled Whether the widget should accept input.
local function SetControlEnabled(control, enabled)
    if enabled then
        control:Enable()
    else
        control:Disable()
    end
end

-- Dims and locks the level and class editors unless Override Defaults is checked.
local function SyncOverride()
    local enabled = Panel.overrideCheck:GetChecked() and true or false
    Panel.overrideGroup:SetAlpha(enabled and 1 or 0.5)
    SetControlEnabled(Panel.minLevel, enabled)
    SetControlEnabled(Panel.maxLevel, enabled)
    for classIndex, classCheck in ipairs(Panel.classChecks) do
        SetControlEnabled(classCheck, enabled)
    end
end

-- Every class checked is stored as nil so newly available classes stay included.
local function StagedClasses()
    local selected = {}
    for classIndex, classCheck in ipairs(Panel.classChecks) do
        if classCheck:GetChecked() then
            selected[#selected + 1] = classCheck.className
        end
    end
    return #selected < #Panel.classChecks and selected or nil
end

-- Returns a key for the configured scan levels and classes, used to detect scope changes.
-- @param settings Current scanner settings table.
local function ScanScope(settings)
    if not settings.overrideDefaults then
        return "default:" .. settings.scanBehavior
    end
    local classes = settings.scanClasses and table.concat(settings.scanClasses, "\031") or "all"
    return settings.minLevel .. "-" .. settings.maxLevel .. ":" .. classes .. ":" .. settings.scanBehavior
end

-- Runs from the Save click, so a changed scope can restart and send its first query.
local function ApplySettings()
    Widgets.CommitFocus(Panel.scanSettings)
    local override  = Panel.overrideCheck:GetChecked() and true or false
    local classes   = StagedClasses()
    if override and classes and #classes == 0 then
        NS:Print("Choose at least one class to scan.")
        return false
    end
    local settings       = NS.db.settings
    local previousScope  = ScanScope(settings)
    local minimum        = NS.Number(tonumber(Panel.minLevel:GetText()), 1, 60, 1)
    settings.overrideDefaults  = override
    settings.minLevel          = minimum
    settings.maxLevel          = NS.Number(tonumber(Panel.maxLevel:GetText()), minimum, 60, 60)
    settings.scanClasses       = classes
    settings.queryInterval     = Panel.speedDropdown:GetValue()
    settings.scanBehavior      = Panel.behaviorDropdown:GetValue()
    settings.retentionDays     = Panel.retentionDropdown:GetValue()
    local removed = NS.Store:PruneExpired()
    if removed > 0 then
        Panel:Invalidate(true)
        Panel:Submit(true)
        NS:Print(string.format("Removed %d players outside the saved history period.", removed))
    end
    if ScanScope(settings) ~= previousScope then
        local succeeded,
            reason = NS.Scanner:Restart()
        if succeeded == false and reason then
            NS:Print(reason)
        end
    end
    return true
end

-- Builds the scan settings dialog and the footer button that toggles it.
-- @param mainFrame Main window used to anchor the settings dialog.
local function BuildSettings(mainFrame)
    local dialog = Widgets.SettingsDialog("Batata_Scanner_ScanSettings", 300, 400)
    Panel.scanSettings = dialog
    dialog.doneButton:SetText("Save")
    local classNames    = NS.Scanner:ClassChoices()
    local groupHeight   = 52 + math.ceil(#classNames / CLASS_COLUMNS) * 24
    local behaviorTop   = 0
    local speedTop      = behaviorTop + 34
    local retentionTop  = speedTop + 34
    local overrideTop   = retentionTop + 34
    local section       = Widgets.SettingsSection(dialog.content, "Settings", overrideTop + 30 + groupHeight + 24)
    section:SetPoint("TOPLEFT")
    section:SetPoint("TOPRIGHT")
    local content = section.content
    Panel.overrideCheck = Widgets.Check(content, "Override Defaults")
    Panel.overrideCheck:SetPoint("TOPLEFT", -4, -overrideTop)
    Panel.overrideCheck:SetScript("OnClick", SyncOverride)
    local group = CreateFrame("Frame", nil, content)
    Panel.overrideGroup = group
    group:SetPoint("TOPLEFT", 0, -overrideTop - 30)
    group:SetPoint("TOPRIGHT", 0, -overrideTop - 30)
    group:SetHeight(groupHeight)
    local levelLabel = Widgets.Label(group, "Levels", "GameFontHighlightSmall")
    levelLabel:SetPoint("TOPLEFT", 0, -4)
    Panel.minLevel = Widgets.EditBox(group, 44, true)
    Panel.minLevel:SetPoint("LEFT", levelLabel, "RIGHT", 12, 0)
    local through = Widgets.Label(group, "to", "GameFontHighlightSmall")
    through:SetPoint("LEFT", Panel.minLevel, "RIGHT", 8, 0)
    Panel.maxLevel = Widgets.EditBox(group, 44, true)
    Panel.maxLevel:SetPoint("LEFT", through, "RIGHT", 8, 0)
    local classLabel = Widgets.Label(group, "Classes", "GameFontHighlightSmall")
    classLabel:SetPoint("TOPLEFT", 0, -36)
    Panel.classChecks = {}
    for classIndex, className in ipairs(classNames) do
        local column      = (classIndex - 1) % CLASS_COLUMNS
        local row         = math.floor((classIndex - 1) / CLASS_COLUMNS)
        local classCheck  = Widgets.Check(group, className)
        classCheck.className = className
        classCheck:SetPoint("TOPLEFT", column * CLASS_COLUMN_WIDTH - 4, -52 - row * 24)
        Panel.classChecks[classIndex] = classCheck
    end
    local behaviorLabel = Widgets.Label(content, "Behavior", "GameFontHighlightSmall")
    behaviorLabel:SetPoint("TOPLEFT", 0, -behaviorTop)
    Panel.behaviorDropdown = Widgets.Dropdown(content, 130)
    Panel.behaviorDropdown:SetPoint("LEFT", behaviorLabel, "RIGHT", 12, 0)
    Panel.behaviorDropdown:SetOptions({
        { label = "In Order", value = "ordered" },
        { label = "Reversed", value = "reversed" },
        { label = "Random", value = "random" },
    })
    local speedLabel = Widgets.Label(content, "Scan speed", "GameFontHighlightSmall")
    speedLabel:SetPoint("TOPLEFT", 0, -speedTop)
    Panel.speedDropdown = Widgets.Dropdown(content, 130)
    Panel.speedDropdown:SetPoint("LEFT", speedLabel, "RIGHT", 12, 0)
    Panel.speedDropdown:SetOptions({
        { label = "Fast", value = 6 },
        { label = "Balanced", value = 15 },
        { label = "Slow", value = 30 },
    })
    local retentionLabel = Widgets.Label(content, "Delete unseen after", "GameFontHighlightSmall")
    retentionLabel:SetPoint("TOPLEFT", 0, -retentionTop)
    Panel.retentionDropdown = Widgets.Dropdown(content, 130)
    Panel.retentionDropdown:SetPoint("LEFT", retentionLabel, "RIGHT", 12, 0)
    Panel.retentionDropdown:SetOptions({
        { label = "Never", value = 0 },
        { label = "30 days", value = 30 },
        { label = "90 days", value = 90 },
        { label = "180 days", value = 180 },
        { label = "365 days", value = 365 },
    })
    Widgets.Tooltip(
        Panel.retentionDropdown,
        "Delete unseen after",
        "Permanently deletes older observations from both factions on Save, login, and logout. Unknown dates are kept."
    )
    -- Editors only tidy their staged text; the Save button commits it.
    -- Clamps and normalizes staged level text without committing settings.
    local function NormalizeLevels()
        local minimum = NS.Number(tonumber(Panel.minLevel:GetText()), 1, 60, 1)
        Panel.minLevel:SetText(tostring(minimum))
        Panel.maxLevel:SetText(tostring(NS.Number(tonumber(Panel.maxLevel:GetText()), minimum, 60, 60)))
    end
    for editorIndex, editor in ipairs({ Panel.minLevel, Panel.maxLevel }) do
        editor:HookScript("OnEditFocusLost", NormalizeLevels)
    end
    -- Saves staged settings and closes the dialog only when validation succeeds.
    -- Saves staged settings and closes the dialog only when validation succeeds.
    dialog.doneButton:SetScript("OnClick", function()
        if ApplySettings() then
            dialog:Hide()
        end
    end)
    -- Reopening always shows the saved settings, discarding edits closed without Save.
    -- Restores saved settings on every open, discarding unsaved edits.
    -- Loads saved values whenever the dialog opens, replacing any unsaved edits.
    dialog:HookScript("OnShow", function()
        local settings  = NS.db.settings
        local included  = {}
        for classIndex, className in ipairs(settings.scanClasses or {}) do
            included[className] = true
        end
        Panel.overrideCheck:SetChecked(settings.overrideDefaults)
        for classIndex, classCheck in ipairs(Panel.classChecks) do
            classCheck:SetChecked(settings.scanClasses == nil or included[classCheck.className] == true)
        end
        SyncOverride()
        Panel.minLevel:SetText(tostring(NS.db.settings.minLevel))
        Panel.maxLevel:SetText(tostring(NS.db.settings.maxLevel))
        local interval = settings.queryInterval
        Panel.speedDropdown:SetValue(interval <= 6 and 6 or (interval <= 15 and 15 or 30))
        Panel.behaviorDropdown:SetValue(settings.scanBehavior)
        Panel.retentionDropdown:SetValue(settings.retentionDays)
        NS.UI:SyncEscape()
    end)
    -- Commits focus and restores the main window's Escape routing after close.
    -- Commits focus and returns Escape handling to the main UI.
    dialog:HookScript("OnHide", function()
        Widgets.CommitFocus(dialog)
        NS.UI:SyncEscape()
    end)
    dialog:SetContentHeight(section:GetHeight())
    Panel.scanSettingsButton = Widgets.SettingsButton(Panel.panelRoot)
    Panel.scanSettingsButton:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -12, 8)
    -- Toggles the settings dialog next to the main window.
    -- Toggles the settings dialog beside the scanner window.
    Panel.scanSettingsButton:SetScript("OnClick", function()
        if dialog:IsShown() then
            dialog:Hide()
        else
            dialog:ClearAllPoints()
            dialog:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMRIGHT", 0, 0)
            dialog:Show()
        end
    end)
end

-- Builds the search filter row: level range, class, guild, and last seen.
-- @param parent Frame that owns the filter controls.
local function BuildFilters(parent)
    local settings   = NS.db.settings
    local filterRow  = CreateFrame("Frame", nil, parent)
    Panel.filterRow = filterRow
    filterRow:SetHeight(24)
    filterRow:SetPoint("TOPLEFT", 16, -44)
    filterRow:SetPoint("RIGHT", parent, "RIGHT", -12, 0)
    local levelLabel = Widgets.Label(filterRow, "Level", "GameFontHighlightSmall")
    levelLabel:SetPoint("LEFT")
    Panel.searchMinLevel = Widgets.EditBox(filterRow, 36, true)
    Panel.searchMinLevel:SetPoint("LEFT", levelLabel, "RIGHT", 6, 0)
    local levelDash = Widgets.Label(filterRow, "-", "GameFontHighlightSmall")
    levelDash:SetPoint("LEFT", Panel.searchMinLevel, "RIGHT", 4, 0)
    Panel.searchMaxLevel = Widgets.EditBox(filterRow, 36, true)
    Panel.searchMaxLevel:SetPoint("LEFT", levelDash, "RIGHT", 4, 0)
    -- Blank level boxes leave that bound open.
    -- Normalizes both staged level bounds and submits when either saved filter changes.
    local function ApplyLevels()
        local minimum  = NS.Number(tonumber(Panel.searchMinLevel:GetText()), 1, 255, nil)
        local maximum  = NS.Number(tonumber(Panel.searchMaxLevel:GetText()), 1, 255, nil)
        if minimum and maximum and minimum > maximum then
            minimum, maximum = maximum, minimum
        end
        Panel.searchMinLevel:SetText(minimum and tostring(minimum) or "")
        Panel.searchMaxLevel:SetText(maximum and tostring(maximum) or "")
        if NS.db.settings.searchMinLevel ~= minimum or NS.db.settings.searchMaxLevel ~= maximum then
            NS.db.settings.searchMinLevel  = minimum
            NS.db.settings.searchMaxLevel  = maximum
            Panel:Submit()
        end
    end
    for editorIndex, editor in ipairs({ Panel.searchMinLevel, Panel.searchMaxLevel }) do
        editor:SetMaxLetters(3)
        editor:HookScript("OnEditFocusLost", ApplyLevels)
    end
    Panel.searchMinLevel:SetText(settings.searchMinLevel and tostring(settings.searchMinLevel) or "")
    Panel.searchMaxLevel:SetText(settings.searchMaxLevel and tostring(settings.searchMaxLevel) or "")
    -- Saves the selected class filter and starts a replacement browser search.
    Panel.classFilter = Widgets.Dropdown(filterRow, 120, function(className)
        NS.db.settings.searchClass = className ~= "" and className or nil
        Panel:Submit()
    end)
    Panel.classFilter:SetPoint("LEFT", Panel.searchMaxLevel, "RIGHT", 12, 0)
    -- Saves the selected guild state and starts a replacement browser search.
    Panel.guildFilter = Widgets.Dropdown(filterRow, 120, function(guildStatus)
        NS.db.settings.searchGuildStatus = guildStatus ~= "" and guildStatus or nil
        Panel:Submit()
    end)
    Panel.guildFilter:SetPoint("LEFT", Panel.classFilter, "RIGHT", 8, 0)
    Panel.guildFilter:SetOptions(GUILD_FILTERS)
    Panel.guildFilter:SetValue(settings.searchGuildStatus or "")
    -- Saves the recency window in seconds and starts a replacement browser search.
    Panel.seenFilter = Widgets.Dropdown(filterRow, 120, function(seenWithin)
        NS.db.settings.searchSeenWithin = seenWithin > 0 and seenWithin or nil
        Panel:Submit()
    end)
    Panel.seenFilter:SetPoint("LEFT", Panel.guildFilter, "RIGHT", 8, 0)
    Panel.seenFilter:SetOptions(SEEN_FILTERS)
    Panel.seenFilter:SetValue(settings.searchSeenWithin or 0)
    RefreshClassOptions()
end

-- Builds the scanner page: search box, scan controls, filters, player table, and footer.
-- @param root Frame that owns the scanner page.
-- @param mainFrame Main window used to anchor the footer and settings dialog.
function Panel:Build(root, mainFrame)
    self.panelRoot  = root
    self.mainFrame  = mainFrame
    Widgets.Footer(root, mainFrame)
    self.root = CreateFrame("Frame", nil, root)
    self.root:SetPoint("TOPLEFT", 8, -6)
    self.root:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -10, 44)
    self.resultsGroup = CreateFrame("Frame", nil, self.root, "BackdropTemplate")
    Widgets.ProfileSurface(self.resultsGroup)
    self.resultsGroup:SetAllPoints()
    self.scrollBarBox  = Widgets.ScrollBarBox(self.resultsGroup, TABLE_TOP + Widgets.HEADER_H)
    self.input         = Widgets.SearchBox(self.resultsGroup, 180)
    self.input:SetHeight(20)
    self.input:SetPoint("TOPLEFT", 21, -14)
    self.input.Instructions:SetText("Search")
    -- Submits the current player search when Enter is pressed.
    self.input:HookScript("OnEnterPressed", function()
        Panel:Submit()
    end)
    -- Clears or submits the search using the search box's clear control.
    self.input.clearButton:HookScript("OnClick", function()
        Panel:Submit()
    end)
    self.scanControls = CreateFrame("Frame", nil, self.resultsGroup)
    self.scanControls:SetHeight(28)
    self.scanControls:SetPoint("LEFT", self.input, "RIGHT", 8, 0)
    self.scanControls:SetPoint("RIGHT", self.resultsGroup, "RIGHT", -12, 0)
    self.scanButton = Widgets.Button(self.scanControls, "", 32)
    self.scanButton:SetPoint("LEFT")
    self.scanButton.playIcon = self.scanButton:CreateTexture(nil, "ARTWORK")
    self.scanButton.playIcon:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
    self.scanButton.playIcon:SetSize(16, 16)
    self.scanButton.playIcon:SetPoint("CENTER", 2, 0)
    -- Returns an accent-colored bar texture used to draw the pause and stop icons.
    local function Bar(button, width, offset)
        local texture = button:CreateTexture(nil, "ARTWORK")
        texture:SetColorTexture(unpack(Widgets.Colors.accent))
        texture:SetSize(width, 10)
        texture:SetPoint("CENTER", offset, 0)
        return texture
    end
    self.scanButton.pauseIcon  = { Bar(self.scanButton, 3, -3), Bar(self.scanButton, 3, 3) }
    self.stopBtn               = Widgets.Button(self.scanControls, "", 32)
    Bar(self.stopBtn, 10, 0)
    self.stopBtn:SetPoint("LEFT", self.scanButton, "RIGHT", 4, 0)
    -- Stops the active sweep while preserving collected player data.
    self.stopBtn:SetScript("OnClick", function()
        NS.Scanner:Stop()
    end)
    self.scanStatus = Widgets.Label(self.scanControls, "", "GameFontHighlightSmall")
    self.scanStatus:SetPoint("LEFT", self.stopBtn, "RIGHT", 8, 0)
    self.scanStatus:SetPoint("RIGHT", self.scanControls, "RIGHT")
    self.scanStatus:SetJustifyH("LEFT")
    self.scanStatus:SetWordWrap(false)
    self.scanStatusHint = CreateFrame("Frame", nil, self.scanControls)
    self.scanStatusHint:SetAllPoints(self.scanStatus)
    self.scanStatusHint:EnableMouse(true)
    -- Adds scanner-specific reason details to a shared status tooltip.
    -- @param widget Control whose tooltip is being bound.
    -- @param title Tooltip heading passed to the shared widget helper.
    local function BindStatusTooltip(widget, title)
        Widgets.Tooltip(widget, title)
        -- Adds current scanner status details to the tooltip on hover.
        widget:HookScript("OnEnter", function()
            local status = NS.Scanner:GetStatus()
            if status.reason ~= "" then
                GameTooltip:AddLine(status.reason, 1, 1, 1, true)
            end
            if status.nativeWhoOpen then
                GameTooltip:AddLine("Paused while the Who list is open.", 1, 0.82, 0, true)
            end
            if status.externalQueryPending then
                GameTooltip:AddLine(
                    "Waiting for the user's Who response; a timeout will schedule a later retry.",
                    1,
                    0.82,
                    0,
                    true
                )
            end
            if status.cooldown > 0 then
                GameTooltip:AddLine(string.format("Who cooldown: %ds", status.cooldown), 1, 0.82, 0)
            end
            GameTooltip:Show()
        end)
    end
    BindStatusTooltip(self.scanButton, "Play or pause")
    BindStatusTooltip(self.stopBtn, "Stop sweep")
    BindStatusTooltip(self.scanStatusHint, "Who scan")
    BuildFilters(self.resultsGroup)
    -- Pauses, continues, or starts the sweep according to the current scanner state.
    self.scanButton:SetScript("OnClick", function()
        local status = NS.Scanner:GetStatus()
        local succeeded
        local reason
        if status.running and not status.paused then
            succeeded = NS.Scanner:Pause()
        elseif status.running then
            succeeded, reason = NS.Scanner:Continue()
        else
            succeeded, reason = NS.Scanner:Start()
        end
        if succeeded == false and reason then
            NS:Print(reason)
        end
        Panel:Refresh()
    end)
    self.tableContent = CreateFrame("Frame", nil, self.resultsGroup)
    self.tableContent:SetPoint("TOPLEFT", 8, -TABLE_TOP)
    self.tableContent:SetPoint("BOTTOMRIGHT", -self.scrollBarBox:GetWidth() - 12, 8)
    self.list = Widgets.CreateTable(self.tableContent, columns, {
        scrollBarBox         = self.scrollBarBox,
        alwaysShowScrollBar  = true,
        -- Reverses the current sort or selects the default direction for a new column.
        -- @param key Column key selected by the table header.
        onSort               = function(key)
            local timeColumn = key == "lastSeen" or key == "firstSeen"
            descending  = sortKey == key and not descending or (sortKey ~= key and timeColumn)
            sortKey     = key
            Panel:Submit()
        end,
        -- Selects empty-state text according to whether a search is still running.
        emptyText = function()
            return Panel.searching and "Searching the saved player database..." or "No player matches this search."
        end,
    })
    self.list.frame:SetAllPoints(self.tableContent)
    self.list.frame.batataInset:Hide()
    if self.list.frame.batataTableInset then
        self.list.frame.batataTableInset:Hide()
    end
    self.scanSummary = Widgets.Label(root, "", "GameFontHighlightSmall")
    self.scanSummary:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 20, 12)
    self.scanSummary:SetHeight(20)
    self.scanSummary:SetJustifyH("LEFT")
    self.scanSummary:SetTextColor(unpack(Widgets.Colors.muted))
    BuildSettings(mainFrame)
    self.scanSummary:SetPoint("RIGHT", self.scanSettingsButton, "LEFT", -8, 0)
    self.scanSummary:SetWordWrap(false)
    self.minWidth = 742
    -- Binds cached results and starts relative-age refreshes while the Scanner tab is visible.
    self.root:HookScript("OnShow", function()
        if results then
            BindResults(true)
        else
            Panel:RefreshSearch()
        end
        Panel.list:Bind()
        if not ageTicker then
            -- Refreshes age labels only while the scanner panel is visible.
            ageTicker = C_Timer.NewTicker(30, function()
                if Panel.root:IsVisible() then
                    Panel.list:Bind()
                end
            end)
        end
        Panel:Refresh()
    end)
    -- Stops row-age work when leaving the Scanner tab; search data remains warm while the window stays open.
    self.root:HookScript("OnHide", function()
        if ageTicker then
            ageTicker:Cancel()
            ageTicker = nil
        end
    end)
    -- Closes transient settings UI when leaving Scanner, without discarding warm search results.
    root:HookScript("OnHide", function()
        Panel.scanSettings:Hide()
    end)
    -- Starts background browser warming on window open and releases all result data on window close.
    mainFrame:HookScript("OnShow", function()
        releaseGeneration = releaseGeneration + 1
        if searchTicker then
            return
        end
        if not Panel.searching and not results then
            Panel:Invalidate(true)
        end
        Panel:RefreshSearch()
        searchTicker = C_Timer.NewTicker(REFRESH_INTERVAL, function()
            if Panel.mainFrame:IsShown() then
                if not refreshPending then
                    Panel:Invalidate()
                end
                Panel:RefreshSearch()
            end
        end)
    end)
    mainFrame:HookScript("OnHide", function()
        releaseGeneration = releaseGeneration + 1
        local pendingRelease = releaseGeneration
        if searchTicker then
            searchTicker:Cancel()
            searchTicker = nil
        end
        local interruptedSearch = Panel.searching
        CancelSearch()
        if interruptedSearch then
            refreshPending = true
        end
        generation       = generation + 1
        Panel.searching  = false
        Panel.input:ClearFocus()
        Panel.scanSettings:Hide()
        C_Timer.After(RESULT_CACHE_GRACE, function()
            if pendingRelease == releaseGeneration and not mainFrame:IsShown() then
                ReleaseResults()
            end
        end)
    end)
end
