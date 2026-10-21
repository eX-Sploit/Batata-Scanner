-- Batata Scanner: bounded same-faction proximity observations; no server queries.
-- Addon folder name and the shared private namespace supplied by the client.
local ADDON,
    NS = ...

-- Observes nearby and grouped same-faction players from unit APIs without sending queries.
local Passive = {}
NS.Passive = Passive -- Publishes the collector so core can start and stop it with the session.

local BATCH_SIZE           = 8 -- Most queued units and most guild rechecks handled per tick.
local QUEUE_LIMIT          = 256 -- Most unit tokens waiting in the observation queue.
local RECHECK_LIMIT        = 128 -- Most players awaiting a delayed guild re-read.
local GUILD_RECHECK_DELAY  = 2 -- Seconds before re-reading a guild that first read as unknown.
local eventFrame           = CreateFrame("Frame") -- Receives unit, group, and world transition events.
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_LEAVING_WORLD")
local running  = false -- Whether passive observation is enabled.
local inWorld  = true -- False between leaving and re-entering the world, which halts processing.
local ticker -- Half-second batch ticker while observation runs.
-- Forward declaration so Enqueue can start the worker before its implementation below.
local StartTicker
local queue         = {} -- Unit tokens awaiting a read, indexed by FIFO position.
local queued        = {} -- Set of tokens currently queued, used to skip duplicates.
local queueFirst    = 1 -- Position of the oldest queued token.
local queueLast     = 0 -- Position of the newest queued token.
local rechecks      = {} -- Pending guild rechecks keyed by GUID, holding unit token and read time.
local recheckOrder  = {} -- Recheck GUIDs indexed by FIFO position.
local recheckFirst  = 1 -- Position of the oldest pending recheck.
local recheckLast   = 0 -- Position of the newest pending recheck.

-- Cancels the passive batch ticker when no queued observations remain.
local function StopTicker()
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
end

-- Empties the unit and guild recheck queues and resets their positions.
local function ClearQueues()
    StopTicker()
    queue         = {}
    queued        = {}
    queueFirst    = 1
    queueLast     = 0
    rechecks      = {}
    recheckOrder  = {}
    recheckFirst  = 1
    recheckLast   = 0
end

-- Appends a unit token to the bounded FIFO unless invalid, already queued, or full.
-- @param unitToken Unit identifier to schedule for a later observation read.
local function Enqueue(unitToken)
    local token = NS.Text(unitToken)
    if not token or #token > 64 or queued[token] or queueLast - queueFirst + 1 >= QUEUE_LIMIT then
        return
    end
    queueLast         = queueLast + 1
    queue[queueLast]  = token
    queued[token]     = true
    StartTicker()
end

-- Returns a unit predicate's result only when it is a readable boolean; otherwise false.
-- @param reader Optional client API predicate to call.
-- @param unitToken Unit identifier passed to reader.
local function ReadBoolean(reader, unitToken)
    if not reader then
        return false
    end
    local value = reader(unitToken)
    return NS.Readable(value) and type(value) == "boolean" and value
end

-- Returns the unit's name joined with any surname, or nil when either part is restricted.
-- @param unitToken Unit identifier whose character name is read.
local function ReadName(unitToken)
    local reader = UnitNameUnmodified or UnitName
    if not reader then
        return nil
    end
    local firstName,
        surname = reader(unitToken)
    if not NS.Readable(surname) then
        return nil
    end
    local name      = NS.Text(firstName)
    local lastName  = NS.Text(surname)
    if not name then
        return nil
    end
    if lastName then
        local separator = " "
        if Constants and Constants.CharacterNameSeparatorConsts then
            separator = NS.Text(Constants.CharacterNameSeparatorConsts.CHARACTERNAME_SURNAME_SEPARATOR) or separator
        end
        name = name .. separator .. lastName
    end
    return name
end

-- Returns a same-faction player observation plus the unit GUID, or nil for other units.
-- @param unitToken Unit identifier to validate and read.
local function ReadUnit(unitToken)
    if not ReadBoolean(UnitExists, unitToken) or not ReadBoolean(UnitIsPlayer, unitToken) then
        return nil
    end
    local faction = UnitFactionGroup and NS.Text(UnitFactionGroup(unitToken))
    if not faction or not NS.context or faction ~= NS.context.faction then
        return nil
    end
    local name = ReadName(unitToken)
    if not name then
        return nil
    end
    local className
    local classToken
    if UnitClass then
        className, classToken = UnitClass(unitToken)
    end
    local level = UnitLevel and UnitLevel(unitToken)
    if not NS.Readable(level) or type(level) ~= "number" or level < 1 or level > 255 or level % 1 ~= 0 then
        level = nil
    end
    local guild = GetGuildInfo and NS.Text(GetGuildInfo(unitToken), true)
    -- A nil passive guild read means unknown, even after repeated nil reads.
    return {
        name       = name,
        level      = level,
        class      = NS.Text(classToken),
        className  = NS.Text(className),
        race       = UnitRace and NS.Text(UnitRace(unitToken)),
        guild      = guild,
        zone       = unitToken == "player" and GetRealZoneText and NS.Text(GetRealZoneText()) or nil,
    },
        UnitGUID and NS.Text(UnitGUID(unitToken))
end

-- Queues the player, target, mouseover, party and raid members, and visible nameplates.
local function SeedUnits()
    Enqueue("player")
    Enqueue("target")
    Enqueue("mouseover")
    for partyIndex = 1, 4 do
        Enqueue("party" .. partyIndex)
    end
    for raidIndex = 1, 40 do
        Enqueue("raid" .. raidIndex)
    end
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then
        return
    end
    local succeeded,
        nameplates = pcall(C_NamePlate.GetNamePlates)
    if succeeded and NS.Accessible(nameplates) then
        for plateIndex = 1, math.min(#nameplates, QUEUE_LIMIT) do
            local nameplate = nameplates[plateIndex]
            if NS.Accessible(nameplate) then
                Enqueue(nameplate.namePlateUnitToken)
            end
        end
    end
end

-- Observes due rechecks and queued units per tick; schedules rechecks for unknown guilds.
local function ProcessBatch()
    if not running or not inWorld or not NS.ready or not NS.context then
        StopTicker()
        return
    end
    local context  = NS.context.key
    local now      = GetTime()
    if NS.Store.BeginBatch then
        NS.Store:BeginBatch()
    end
    local rechecked = 0
    while recheckFirst <= recheckLast and rechecked < BATCH_SIZE do
        local guid     = recheckOrder[recheckFirst]
        local pending  = rechecks[guid]
        if pending and now - pending.at < GUILD_RECHECK_DELAY then
            break
        end
        recheckOrder[recheckFirst]  = nil
        recheckFirst                = recheckFirst + 1
        rechecks[guid]              = nil
        if pending then
            local succeeded,
                info,
                currentGUID = pcall(ReadUnit, pending.unit)
            if succeeded and info and currentGUID == guid and context == NS.context.key then
                NS.Store:Observe(info)
            end
        end
        rechecked = rechecked + 1
    end
    if recheckFirst > recheckLast then
        recheckFirst  = 1
        recheckLast   = 0
    end
    local processed = 0
    while queueFirst <= queueLast and processed < BATCH_SIZE do
        local unitToken = queue[queueFirst]
        queue[queueFirst]  = nil
        queueFirst         = queueFirst + 1
        queued[unitToken]  = nil
        local succeeded,
            info,
            guid = pcall(ReadUnit, unitToken)
        if succeeded and info and context == NS.context.key then
            NS.Store:Observe(info)
            if info.guild == nil and guid and not rechecks[guid] and recheckLast - recheckFirst + 1 < RECHECK_LIMIT then
                rechecks[guid]             = { unit = unitToken, at = now }
                recheckLast                = recheckLast + 1
                recheckOrder[recheckLast]  = guid
            end
        end
        processed = processed + 1
    end
    if queueFirst > queueLast then
        queueFirst  = 1
        queueLast   = 0
    end
    if NS.Store.EndBatch then
        NS.Store:EndBatch()
    end
    if queueFirst > queueLast and recheckFirst > recheckLast then
        StopTicker()
    end
end

-- Starts one half-second worker while observation is enabled and queued work exists.
StartTicker = function()
    if running and inWorld and not ticker then
        ticker = C_Timer.NewTicker(0.5, ProcessBatch)
    end
end

-- Registers unit events and starts the batch ticker; returns whether observation is running.
function Passive:Start()
    if running then
        return true
    end
    if not NS.ready or not (C_Timer and C_Timer.NewTicker) then
        return false
    end
    running = true
    eventFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    eventFrame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
    eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:RegisterEvent("UNIT_NAME_UPDATE")
    eventFrame:RegisterEvent("UNIT_LEVEL")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("PLAYER_LEAVING_WORLD")
    SeedUnits()
    return true
end

-- Disables observation, cancels the ticker, and clears queues; world events stay tracked.
function Passive:Stop()
    running = false
    eventFrame:UnregisterAllEvents()
    -- Keep world readiness current while observations are disabled.
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("PLAYER_LEAVING_WORLD")
    ClearQueues()
end

-- Queues the affected unit or refreshes world readiness after a client event.
-- @param frame Frame receiving the client event.
-- @param event Unit, group, or world event name registered above.
-- @param unitToken Unit identifier included by applicable unit events.
eventFrame:SetScript("OnEvent", function(frame, event, unitToken)
    if event == "NAME_PLATE_UNIT_ADDED" or event == "UNIT_NAME_UPDATE" or event == "UNIT_LEVEL" then
        Enqueue(unitToken)
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        Enqueue("mouseover")
    elseif event == "PLAYER_TARGET_CHANGED" then
        Enqueue("target")
    elseif event == "GROUP_ROSTER_UPDATE" then
        SeedUnits()
    elseif event == "PLAYER_LEAVING_WORLD" then
        inWorld = false
        ClearQueues()
    elseif event == "PLAYER_ENTERING_WORLD" then
        inWorld = true
        if running then
            SeedUnits()
        end
    end
end)
