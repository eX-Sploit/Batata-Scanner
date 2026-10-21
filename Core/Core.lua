-- Batata Scanner: startup, value helpers, internal events, DB migration, and slash commands.
-- Addon folder name and the shared private namespace supplied by the client.
local ADDON,
    NS = ...

-- Returns a TOC metadata field for this addon via C_AddOns or the legacy global API.
-- @param field Metadata key such as Version or X-API-Version.
local function ReadMetadata(field)
    return C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, field)
        or (GetAddOnMetadata and GetAddOnMetadata(ADDON, field))
end

NS.name         = ADDON -- Addon folder name shared with other modules.
NS.ready        = false -- True once saved data and faction context are initialized.
NS.version      = ReadMetadata("Version") -- Release version from the TOC.
NS.apiVersion   = tonumber(ReadMetadata("X-API-Version")) -- Consumer API version from the TOC.
NS.iconTexture  = "Interface\\AddOns\\" .. ADDON .. "\\Assets\\batata-scanner-icon.png" -- Shared addon brand artwork.

NS.FactionRaces = {
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

local listeners   = {} -- Internal event subscriptions keyed by listener token.
local nextToken   = 0 -- Most recently issued listener token.
local savedReady  = false -- True after Batata_Scanner_DB has been migrated and normalized.

-- Returns whether a value is neither a secret value nor otherwise inaccessible to addon code.
-- @param value Candidate value whose readability is checked before use.
function NS.Readable(value)
    return not (issecretvalue and issecretvalue(value)) and not (canaccessvalue and not canaccessvalue(value))
end

-- Returns whether a value is a readable table whose contents addon code may access.
-- @param value Candidate table to validate before iterating or indexing.
function NS.Accessible(value)
    return NS.Readable(value) and type(value) == "table" and not (canaccesstable and not canaccesstable(value))
end

-- Returns a readable string with outer whitespace trimmed; empty yields nil unless allowEmpty.
-- @param value Candidate string to validate and trim.
-- @param allowEmpty Whether an empty trimmed string is a valid result.
function NS.Text(value, allowEmpty)
    if not NS.Readable(value) or type(value) ~= "string" then
        return nil
    end
    local text = value:match("^%s*(.-)%s*$")
    if text == "" and not allowEmpty then
        return nil
    end
    return text
end

-- Returns trimmed text with inner whitespace runs collapsed to single spaces, or nil.
-- @param value Candidate player name or other text to normalize.
function NS.NormalizeName(value)
    local text = NS.Text(value)
    return text and text:gsub("%s+", " ")
end

-- Prefer the client's male localized name for a known token so gendered class strings share one value.
-- @param className Fallback display name supplied with the observation.
-- @param classToken Localized-class lookup token, when known.
function NS.ClassName(className, classToken)
    local token      = NS.Text(classToken)
    local names      = LOCALIZED_CLASS_NAMES_MALE
    local localized  = token and NS.Accessible(names) and NS.Text(names[token:upper()])
    return localized or NS.Text(className) or token
end

-- Returns a readable finite number floored and clamped to the range, otherwise fallback.
-- @param value Candidate numeric setting or count.
-- @param minimum Inclusive lower bound for the result.
-- @param maximum Inclusive upper bound for the result.
-- @param fallback Value returned when the candidate is invalid or unreadable.
function NS.Number(value, minimum, maximum, fallback)
    if not NS.Readable(value) or type(value) ~= "number" or value ~= value then
        return fallback
    end
    if value == math.huge or value == -math.huge then
        return fallback
    end
    return math.max(minimum, math.min(maximum, math.floor(value)))
end

-- Returns the current Unix timestamp from the client clock.
function NS.Now()
    return time()
end

-- Writes a message to the default chat frame with the addon prefix.
-- @param message Text to display to the player.
function NS:Print(message)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffcc66Batata Scanner|r: " .. tostring(message))
    end
end

-- Registers a callback for an internal event; returns its token, or nil for invalid input.
-- @param event Internal event name to subscribe to.
-- @param callback Function invoked when that event is notified.
function NS.On(event, callback)
    if type(event) ~= "string" or type(callback) ~= "function" then
        return nil
    end
    nextToken             = nextToken + 1
    listeners[nextToken]  = { event = event, callback = callback }
    return nextToken
end

-- Removes a listener by token; returns whether it was registered.
-- @param token Subscription token returned by NS.On.
function NS.Off(token)
    if type(token) ~= "number" then
        return false
    end
    local existed = listeners[token] ~= nil
    listeners[token] = nil
    return existed
end

-- Calls listeners for an event with the current revision, routing errors to the handler.
-- @param event Internal event name whose listeners should be called.
function NS:Notify(event)
    local callbacks = {}
    for token, listener in pairs(listeners) do
        if listener.event == event then
            callbacks[#callbacks + 1] = { token = token, callback = listener.callback }
        end
    end
    for callbackIndex, listener in ipairs(callbacks) do
        if listeners[listener.token] then
            local succeeded,
                failure = pcall(listener.callback, event, NS.db and NS.db.revision or 0)
            if not succeeded and geterrorhandler then
                geterrorhandler()(failure)
            end
        end
    end
end

-- Resets incompatible saved data to schema 1 and normalizes current settings once.
local function InitializeSavedState()
    if savedReady then
        return
    end
    local database = Batata_Scanner_DB
    if
        type(database) ~= "table"
        or database.schemaVersion ~= 1
        or database.scopes ~= nil
    then
        if type(database) == "table" then
            NS:Print("Saved census data was reset for database schema 1.")
        end
        database = {}
    end
    database.schemaVersion  = 1
    database.players        = NS.Store:Load(database.players)
    database.settings       = type(database.settings) == "table" and database.settings or {}
    database.window         = type(database.window) == "table" and database.window or {}
    database.minimap        = type(database.minimap) == "table" and database.minimap or {}
    database.revision       = NS.Number(database.revision, 0, 9007199254740000, 0)
    database.minimap.angle  = NS.Number(database.minimap.angle, 0, 359, 225)
    local settings = database.settings
    if settings.scanBehavior ~= "ordered" and settings.scanBehavior ~= "reversed" then
        settings.scanBehavior = "random"
    end
    settings.passiveEnabled     = nil
    settings.worldClickEnabled  = nil
    settings.myFactionOnly      = settings.myFactionOnly == true
    settings.overrideDefaults   = settings.overrideDefaults == true
    settings.minLevel           = NS.Number(settings.minLevel, 1, 60, 1)
    settings.maxLevel           = NS.Number(settings.maxLevel, settings.minLevel, 60, 60)
    settings.queryInterval      = NS.Number(settings.queryInterval, 6, 60, 15)
    settings.queryTimeout       = NS.Number(settings.queryTimeout, 6, 120, 10)
    settings.searchMinLevel     = NS.Number(settings.searchMinLevel, 1, 255, nil)
    settings.searchMaxLevel     = NS.Number(settings.searchMaxLevel, settings.searchMinLevel or 1, 255, nil)
    settings.searchClass        = NS.Text(settings.searchClass)
    settings.searchSeenWithin   = NS.Number(settings.searchSeenWithin, 1, 31536000, nil)
    local retentionDays = settings.retentionDays
    if retentionDays ~= 30 and retentionDays ~= 90 and retentionDays ~= 180 and retentionDays ~= 365 then
        retentionDays = 0
    end
    settings.retentionDays = retentionDays
    local guildStatus = settings.searchGuildStatus
    if guildStatus ~= "guilded" and guildStatus ~= "unguilded" then
        settings.searchGuildStatus = nil
    end
    -- Missing scan classes mean every class; an empty list is an explicit choice of none.
    if type(settings.scanClasses) == "table" then
        local scanClasses = {}
        for classIndex, className in ipairs(settings.scanClasses) do
            scanClasses[#scanClasses + 1] = NS.Text(className)
        end
        settings.scanClasses = scanClasses
    else
        settings.scanClasses = nil
    end
    Batata_Scanner_DB  = database
    NS.db              = database
    savedReady         = true
    NS.Store:PruneExpired()
end

-- Sets faction context, restores the scanner, starts passive collection, and signals READY.
local function StartReady()
    if NS.ready or not savedReady then
        return
    end
    local faction = NS.Text(UnitFactionGroup and UnitFactionGroup("player"))
    if faction ~= "Alliance" and faction ~= "Horde" then
        return
    end
    NS.context = { faction = faction, key = faction }
    if NS.Scanner then
        NS.Scanner:Restore()
    end
    NS.ready = true
    NS.Passive:Start()
    NS:Notify("READY")
end

local eventFrame = CreateFrame("Frame") -- Drives saved-data setup, readiness, and logout persistence.
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
-- Handles addon load, world readiness, and logout; loadedAddon identifies ADDON_LOADED events.
eventFrame:SetScript("OnEvent", function(frame, event, loadedAddon)
    if event == "ADDON_LOADED" and loadedAddon == ADDON then
        InitializeSavedState()
        frame:UnregisterEvent("ADDON_LOADED")
        if IsLoggedIn and IsLoggedIn() then
            StartReady()
        end
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        StartReady()
    elseif event == "PLAYER_LOGOUT" then
        if NS.Scanner then
            NS.Scanner:Shutdown()
        end
        if NS.Passive then
            NS.Passive:Stop()
        end
        if savedReady then
            NS.Store:Save()
        end
    end
end)

SLASH_BATATA_SCANNER1  = "/batata-scanner" -- Primary slash command.
SLASH_BATATA_SCANNER2  = "/bs" -- Short slash command alias.
-- Dispatches /bs chat commands; message is the text following the slash command.
SlashCmdList.BATATA_SCANNER  = function(message)
    local command = (message or ""):match("^%s*(%S*)"):lower()
    if not NS.ready then
        NS:Print("Waiting for saved data and character information.")
    elseif command == "debug" then
        NS.Scanner:ToggleDebug()
    elseif command == "scan" then
        NS.Scanner:Start()
    elseif command == "next" then
        NS.Scanner:Continue()
    elseif command == "pause" then
        NS.Scanner:Pause()
    elseif command == "stop" then
        NS.Scanner:Stop()
    elseif command == "status" then
        local status = NS.Scanner:GetStatus()
        NS:Print(
            (status.state or "idle")
                .. ": "
                .. (status.reason or "Ready")
                .. " | stored players: "
                .. tostring(Batata_Scanner.CountPlayers())
        )
    elseif command == "" then
        NS.UI:Toggle()
    else
        NS:Print("/bs: open | /bs scan | /bs next | /bs pause | /bs stop | /bs status | /bs debug")
    end
end
