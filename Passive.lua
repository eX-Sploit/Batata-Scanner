-- BatataScanner: bounded same-faction proximity observations; no server queries.
local ADDON,
    NS = ...

local Passive = {}
NS.Passive = Passive

local BATCH_SIZE           = 8
local QUEUE_LIMIT          = 256
local RECHECK_LIMIT        = 128
local GUILD_RECHECK_DELAY  = 2
local eventFrame           = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_LEAVING_WORLD")
local running  = false
local inWorld  = true
local ticker
local queue         = {}
local queued        = {}
local queueFirst    = 1
local queueLast     = 0
local rechecks      = {}
local recheckOrder  = {}
local recheckFirst  = 1
local recheckLast   = 0

local function ClearQueues()
    queue         = {}
    queued        = {}
    queueFirst    = 1
    queueLast     = 0
    rechecks      = {}
    recheckOrder  = {}
    recheckFirst  = 1
    recheckLast   = 0
end

local function Enqueue(unitToken)
    local token = NS.Text(unitToken)
    if not token or #token > 64 or queued[token] or queueLast - queueFirst + 1 >= QUEUE_LIMIT then
        return
    end
    queueLast         = queueLast + 1
    queue[queueLast]  = token
    queued[token]     = true
end

local function ReadBoolean(reader, unitToken)
    if not reader then
        return false
    end
    local value = reader(unitToken)
    return NS.Readable(value) and type(value) == "boolean" and value
end

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

local function ProcessBatch()
    if not running or not inWorld or not NS.ready or not NS.context then
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
                NS.Store:Observe(info, "passive")
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
            NS.Store:Observe(info, "passive")
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
end

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
    ticker = C_Timer.NewTicker(0.5, ProcessBatch)
    SeedUnits()
    return true
end

function Passive:Stop()
    running = false
    eventFrame:UnregisterAllEvents()
    -- Keep world readiness current while observations are disabled.
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("PLAYER_LEAVING_WORLD")
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
    ClearQueues()
end

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
