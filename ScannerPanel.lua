-- BatataScanner: GuildHQ's combined scanner browser and stored-entry details.
local ADDON,
    NS = ...

local Panel = {}
NS.ScannerPanel = Panel

local Widgets           = NS.Widgets
local DETAILS_WIDTH     = 320
local TABLE_TOP         = 46
local REFRESH_INTERVAL  = 30
local sortKey           = "name"
local descending        = false
local generation        = 0
local refreshPending    = true
local lastSearchAt      = -REFRESH_INTERVAL
local refreshTimer
local results

local function GuildText(player)
    return player.guild == "" and "Unguilded" or player.guild or "Unknown"
end

local function ClassText(player)
    return player.className
        or (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[player.class])
        or player.class
        or "Unknown"
end

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

local columns = {
    {
        key    = "level",
        label  = "Lvl",
        width  = 28,
        sort   = true,
        text   = function(player)
            return tostring(player.level or "")
        end,
    },
    {
        key       = "name",
        label     = "Name",
        minWidth  = 80,
        ellipsis  = true,
        sort      = true,
        text      = function(player)
            return player.name
        end,
        color = function(player)
            return Widgets.ClassColor(player.class)
        end,
    },
    { key = "class", label = "Class", width = 54, ellipsis = true, sort = true, text = ClassText },
    { key = "guild", label = "Guild", width = 76, ellipsis = true, sort = true, text = GuildText },
    {
        key    = "lastSeen",
        label  = "Last seen",
        width  = 64,
        sort   = true,
        text   = function(player)
            return FormatAge(player.lastSeen)
        end,
    },
}

function Panel:Layout()
    if not self.root or self.layingOut then
        return
    end
    self.layingOut = true
    local height = math.max(1, self.root:GetHeight())
    self.resultsGroup:SetSize(math.max(1, self.root:GetWidth() - DETAILS_WIDTH - 8), height)
    self.details:SetSize(DETAILS_WIDTH, height)
    self.detailsBody:Layout(
        math.max(1, DETAILS_WIDTH - self.detailsScrollBox:GetWidth() - 24),
        math.max(1, height - 48),
        function(width)
            self.detailsText:SetWidth(math.max(1, width - 16))
            return math.max(20, self.detailsText:GetStringHeight() + 16)
        end
    )
    self.layingOut = false
end

function Panel:ShowDetails(preserveScroll)
    local player = self.selectedKey and BatataScanner.GetPlayer(self.selectedKey)
    if not player then
        self.selectedKey = nil
        self.detailsTitle:SetText("Entry details")
        self.detailsTitle:SetTextColor(unpack(Widgets.Colors.accent))
        self.detailsText:SetText("Select an entry to view its stored details.")
    else
        self.detailsTitle:SetText(player.name)
        self.detailsTitle:SetTextColor(Widgets.ClassColor(player.class))
        local function Timestamp(value)
            return value and date("%Y-%m-%d %H:%M:%S", value) or "Unknown"
        end
        local function Field(label, value)
            return "|cffe0c998" .. label .. ":|r " .. value
        end
        local sources = {}
        for source, observed in pairs(player.sources) do
            if observed then
                sources[#sources + 1] = source == "who" and "Who" or "Passive"
            end
        end
        table.sort(sources)
        local lines = {
            "|cffffd100Character|r",
            Field("Level", tostring(player.level or "Unknown")),
            Field("Class", ClassText(player)),
            Field("Race", player.race or "Unknown"),
            "",
            "|cffffd100Last known location|r",
            Field("Guild", GuildText(player)),
            Field("Zone", player.zone or "Unknown"),
            "",
            "|cffffd100Observations|r",
            Field("First seen", Timestamp(player.firstSeen)),
            Field("Last seen", Timestamp(player.lastSeen)),
            Field("Sources", table.concat(sources, ", ")),
            Field("Realm", player.realm),
            Field("Faction", player.faction),
        }
        self.detailsText:SetText(table.concat(lines, "\n"))
    end
    if not preserveScroll or not player then
        self.detailsBody:Reset()
    end
    self:Layout()
end

function Panel:Select(player)
    self.selectedKey = player and player.name
    self:ShowDetails()
    self.list:Bind()
    NS.UI:SyncEscape()
end

local function RefreshSummary()
    if Panel.inputError then
        Panel.scanSummary:SetText(Panel.inputError)
    elseif Panel.searching then
        Panel.scanSummary:SetText(string.format("Searching: %d%%", Panel.searchProgress or 0))
    else
        Panel.scanSummary:SetText(
            string.format(
                "Showing %d of %d searched players",
                results and results.total or 0,
                results and results.limit or 0
            )
        )
    end
end

function Panel:Escape()
    if self.scanSettings:IsShown() then
        self.scanSettings:Hide()
        return true
    elseif self.searching then
        generation          = generation + 1
        self.searching      = false
        self.refreshPaused  = true
        self.inputError     = "Cancelled. Press Enter to search."
        RefreshSummary()
        return true
    elseif self.selectedKey then
        self:Select(nil)
        return true
    end
    return false
end

function Panel:Submit(preserveScroll)
    local request,
        failure = NS.Store:CreateSearch(self.input:GetText(), sortKey, descending)
    if not request then
        self.inputError = failure
        RefreshSummary()
        return
    end
    self.inputError     = nil
    self.refreshPaused  = false
    generation          = generation + 1
    local currentGeneration = generation
    self.searching = true
    NS.UI:SyncEscape()
    refreshPending  = false
    lastSearchAt    = GetTime()
    local function Step()
        if currentGeneration ~= generation or not Panel.root:IsVisible() then
            return
        end
        local completed = request:Step()
        Panel.searchProgress = math.floor(100 * request.progress / math.max(1, request.limit))
        RefreshSummary()
        if not completed then
            C_Timer.After(0, Step)
            return
        end
        results          = request
        Panel.searching  = false
        if not preserveScroll then
            Panel.selectedKey = nil
        end
        NS.UI:SyncEscape()
        Panel.list:SetProvider(request.total, function(index)
            return request:GetPlayer(index)
        end, preserveScroll)
        Panel:ShowDetails(preserveScroll)
        RefreshSummary()
        if refreshPending then
            Panel:Refresh()
        end
    end
    C_Timer.After(0, Step)
end

function Panel:Invalidate()
    refreshPending = true
end

function Panel:Refresh()
    if not self.root or not self.root:IsVisible() then
        return
    end
    local status    = BatataScanner.GetScanStatus()
    local pausable  = status.running and not status.paused and (status.awaiting or NS.db.settings.worldClickEnabled)
    self.scanButton.playIcon:SetShown(not pausable)
    for iconIndex, icon in ipairs(self.scanButton.pauseIcon) do
        icon:SetShown(pausable)
    end
    local label       = "Stopped"
    local labelColor  = { 1, 0.3, 0.3 }
    if status.paused then
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
        not status.blockedUntilReload and not status.pendingLateResponse and not status.externalQueryPending
    )
    if refreshPending and not self.searching and not self.refreshPaused then
        local wait = math.max(0, lastSearchAt + REFRESH_INTERVAL - GetTime())
        if not results or wait == 0 then
            self:Submit(true)
        elseif not refreshTimer then
            refreshTimer = true
            C_Timer.After(wait, function()
                refreshTimer = nil
                Panel:Refresh()
            end)
        end
    end
    RefreshSummary()
end

local function BuildSettings(mainFrame)
    local dialog = Widgets.SettingsDialog("BatataScanner_ScanSettings", 396, 360, "Scanner settings")
    Panel.scanSettings = dialog
    local section = Widgets.SettingsSection(dialog.content, "Census collection", 242)
    section:SetPoint("TOPLEFT")
    section:SetPoint("TOPRIGHT")
    local content  = section.content
    local hint     = Widgets.Label(content, "Record players for the Census as you play.", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT")
    Panel.passiveCheck = Widgets.Check(content, "Record nearby and group players")
    Panel.passiveCheck:SetPoint("TOPLEFT", -4, -20)
    Panel.worldClickCheck = Widgets.Check(content, "Continue Who scans on world clicks")
    Panel.worldClickCheck:SetPoint("TOPLEFT", -4, -48)
    local levelLabel = Widgets.Label(content, "Levels", "GameFontHighlightSmall")
    levelLabel:SetPoint("TOPLEFT", 0, -85)
    Panel.minLevel = Widgets.EditBox(content, 44, true)
    Panel.minLevel:SetPoint("LEFT", levelLabel, "RIGHT", 12, 0)
    local through = Widgets.Label(content, "to", "GameFontHighlightSmall")
    through:SetPoint("LEFT", Panel.minLevel, "RIGHT", 8, 0)
    Panel.maxLevel = Widgets.EditBox(content, 44, true)
    Panel.maxLevel:SetPoint("LEFT", through, "RIGHT", 8, 0)
    local intervalLabel = Widgets.Label(content, "Scan interval", "GameFontHighlightSmall")
    intervalLabel:SetPoint("TOPLEFT", 0, -119)
    Panel.intervalEB = Widgets.EditBox(content, 44, true)
    Panel.intervalEB:SetPoint("LEFT", intervalLabel, "RIGHT", 12, 0)
    local unit = Widgets.Label(content, "seconds (min 5)", "GameFontHighlightSmall")
    unit:SetPoint("LEFT", Panel.intervalEB, "RIGHT", 8, 0)
    local queryLabel = Widgets.Label(content, "Custom Who query", "GameFontHighlightSmall")
    queryLabel:SetPoint("TOPLEFT", 0, -155)
    Panel.customQuery = Widgets.EditBox(content, 330)
    Panel.customQuery:SetPoint("TOPLEFT", 0, -176)
    Panel.customQuery:SetMaxLetters(255)
    Panel.customQuery:SetText("")
    Widgets.Tooltip(
        Panel.customQuery,
        "Custom Who query",
        "Leave blank for a full level-range sweep. A custom query can provide partial coverage."
    )
    Panel.passiveCheck:SetScript("OnClick", function(self)
        NS.db.settings.passiveEnabled = self:GetChecked() and true or false
        if NS.db.settings.passiveEnabled then
            NS.Passive:Start()
        else
            NS.Passive:Stop()
        end
    end)
    Panel.worldClickCheck:SetScript("OnClick", function(self)
        NS.Scanner:SetWorldClickEnabled(self:GetChecked())
        Panel:Refresh()
    end)
    local function SaveLevels()
        local minimum  = NS.Number(tonumber(Panel.minLevel:GetText()), 1, 60, 1)
        local maximum  = NS.Number(tonumber(Panel.maxLevel:GetText()), minimum, 60, 60)
        NS.db.settings.minLevel  = minimum
        NS.db.settings.maxLevel  = maximum
        Panel.minLevel:SetText(tostring(minimum))
        Panel.maxLevel:SetText(tostring(maximum))
    end
    local function SaveInterval()
        NS.db.settings.queryInterval = NS.Number(tonumber(Panel.intervalEB:GetText()), 5, 60, 5)
        Panel.intervalEB:SetText(tostring(NS.db.settings.queryInterval))
    end
    for editorIndex, editor in ipairs({ Panel.minLevel, Panel.maxLevel }) do
        editor:HookScript("OnEditFocusLost", SaveLevels)
        editor:HookScript("OnEnterPressed", SaveLevels)
    end
    Panel.intervalEB:HookScript("OnEditFocusLost", SaveInterval)
    Panel.intervalEB:HookScript("OnEnterPressed", SaveInterval)
    dialog:HookScript("OnShow", function()
        Panel.passiveCheck:SetChecked(NS.db.settings.passiveEnabled)
        Panel.worldClickCheck:SetChecked(NS.db.settings.worldClickEnabled)
        Panel.minLevel:SetText(tostring(NS.db.settings.minLevel))
        Panel.maxLevel:SetText(tostring(NS.db.settings.maxLevel))
        Panel.intervalEB:SetText(tostring(NS.db.settings.queryInterval))
        NS.UI:SyncEscape()
    end)
    dialog:HookScript("OnHide", function()
        Widgets.CommitFocus(dialog)
        NS.UI:SyncEscape()
    end)
    dialog:SetContentHeight(section:GetHeight())
    Panel.scanSettingsButton = Widgets.SettingsButton(Panel.panelRoot)
    Panel.scanSettingsButton:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -12, 8)
    Panel.scanSettingsButton:SetScript("OnClick", function()
        if dialog:IsShown() then
            dialog:Hide()
        else
            dialog:ClearAllPoints()
            dialog:SetPoint("TOP", mainFrame, "CENTER", 0, dialog:GetHeight() / 2)
            dialog:Show()
        end
    end)
end

function Panel:Build(root, mainFrame)
    self.panelRoot = root
    Widgets.Footer(root, mainFrame)
    self.root = CreateFrame("Frame", nil, root)
    self.root:SetPoint("TOPLEFT", 8, -6)
    self.root:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -10, 44)
    self.resultsGroup = CreateFrame("Frame", nil, self.root, "BackdropTemplate")
    Widgets.ProfileSurface(self.resultsGroup)
    self.resultsGroup:SetPoint("TOPLEFT")
    self.scrollBarBox  = Widgets.ScrollBarBox(self.resultsGroup, TABLE_TOP + Widgets.HEADER_H)
    self.input         = Widgets.SearchBox(self.resultsGroup, 180)
    self.input:SetHeight(20)
    self.input:SetPoint("TOPLEFT", 21, -14)
    self.input.Instructions:SetText("Search")
    self.input:HookScript("OnEnterPressed", function()
        Panel:Submit()
    end)
    self.input.clearButton:HookScript("OnClick", function()
        Panel:Submit()
    end)
    Widgets.Tooltip(
        self.input,
        "Search",
        "Press Enter to search. Every word must match a stored value. Punctuation is literal. Up to 256 bytes and 8 words."
    )
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
    self.stopBtn:SetScript("OnClick", function()
        NS.Scanner:Stop()
    end)
    self.scanStatus = Widgets.Label(self.scanControls, "", "GameFontHighlightSmall")
    self.scanStatus:SetPoint("LEFT", self.stopBtn, "RIGHT", 8, 0)
    self.scanStatus:SetPoint("RIGHT", self.scanControls, "RIGHT")
    self.scanStatus:SetJustifyH("LEFT")
    self.scanStatus:SetWordWrap(false)
    self.scanButton:SetScript("OnClick", function()
        local status = NS.Scanner:GetStatus()
        local succeeded
        local reason
        if status.running and not status.paused and (status.awaiting or NS.db.settings.worldClickEnabled) then
            succeeded = NS.Scanner:Pause()
        elseif status.running then
            succeeded, reason = NS.Scanner:Continue()
        else
            Widgets.CommitFocus(Panel.scanSettings)
            succeeded, reason = NS.Scanner:Start({
                minLevel     = NS.db.settings.minLevel,
                maxLevel     = NS.db.settings.maxLevel,
                customQuery  = Panel.customQuery:GetText(),
            })
        end
        if succeeded == false and reason then
            NS:Print(reason)
        end
        Panel:Refresh()
    end)
    Widgets.Tooltip(
        self.scanButton,
        "Scanner",
        "Start, pause, or continue scanning. With world clicks off, click Play for each next query after its cooldown. Recorded players are kept."
    )
    Widgets.Tooltip(self.stopBtn, "Stop scanning", "Stop scanning and clear queued queries. Recorded players are kept.")
    self.scanControls:EnableMouse(true)
    self.scanControls:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(NS.Scanner:GetStatus().reason or "Scanner")
        GameTooltip:Show()
    end)
    self.scanControls:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    self.tableContent = CreateFrame("Frame", nil, self.resultsGroup)
    self.tableContent:SetPoint("TOPLEFT", 8, -TABLE_TOP)
    self.tableContent:SetPoint("BOTTOMRIGHT", -self.scrollBarBox:GetWidth() - 12, 8)
    self.list = Widgets.CreateTable(self.tableContent, columns, {
        scrollBarBox         = self.scrollBarBox,
        alwaysShowScrollBar  = true,
        onClick              = function(player)
            Panel:Select(player)
        end,
        isSelected = function(player)
            return player.name == Panel.selectedKey
        end,
        onSort = function(key)
            descending  = sortKey == key and not descending or (sortKey ~= key and key == "lastSeen")
            sortKey     = key
            Panel:Submit()
        end,
        tooltip = function(player)
            return player.name, "Select to view all recorded fields."
        end,
        emptyText = function()
            return Panel.searching and "Searching the saved player database..." or "No player matches this search."
        end,
    })
    self.list.frame:SetAllPoints(self.tableContent)
    self.list.frame.batataInset:Hide()
    if self.list.frame.batataTableInset then
        self.list.frame.batataTableInset:Hide()
    end
    self.details = CreateFrame("Frame", nil, self.root, "BackdropTemplate")
    Widgets.ProfileSurface(self.details)
    self.details:SetPoint("TOPLEFT", self.resultsGroup, "TOPRIGHT", 8, 0)
    self.detailsTitle = Widgets.Label(self.details, "Entry details", "GameFontNormalMed1")
    self.detailsTitle:SetPoint("TOPLEFT", 16, -10)
    self.detailsTitle:SetSize(DETAILS_WIDTH - 32, 26)
    self.detailsTitle:SetWordWrap(false)
    self.detailsTitle:SetJustifyH("LEFT")
    self.detailsTitle:SetJustifyV("MIDDLE")
    self.detailsScrollBox  = Widgets.ScrollBarBox(self.details, 40)
    self.detailsBody       = Widgets.ScrollSection(
        self.details,
        nil,
        nil,
        { alwaysShowScrollBar = true, scrollBarBox = self.detailsScrollBox }
    )
    self.detailsBody:SetPoint("TOPLEFT", 8, -40)
    self.detailsText = Widgets.Label(self.detailsBody.content, "", "GameFontHighlightSmall")
    self.detailsText:SetPoint("TOPLEFT", 8, -8)
    self.detailsText:SetJustifyV("TOP")
    self.detailsText:SetJustifyH("LEFT")
    self.detailsText:SetWordWrap(true)
    self.scanSummary = Widgets.Label(root, "", "GameFontHighlightSmall")
    self.scanSummary:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 12, 12)
    self.scanSummary:SetHeight(20)
    self.scanSummary:SetTextColor(unpack(Widgets.Colors.muted))
    BuildSettings(mainFrame)
    self.scanSummary:SetPoint("RIGHT", self.scanSettingsButton, "LEFT", -8, 0)
    self.scanSummary:SetWordWrap(false)
    self.minWidth = 742
    self:ShowDetails()
    self.root:HookScript("OnSizeChanged", function()
        Panel:Layout()
    end)
    self.root:HookScript("OnShow", function()
        Panel:Refresh()
    end)
    root:HookScript("OnHide", function()
        if Panel.searching then
            refreshPending  = true
            lastSearchAt    = -REFRESH_INTERVAL
        end
        generation         = generation + 1
        Panel.searching    = false
        Panel.selectedKey  = nil
        Panel.input:ClearFocus()
        Panel.scanSettings:Hide()
        Panel:ShowDetails()
        if not results then
            refreshPending = true
        end
    end)
end
