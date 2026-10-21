-- BatataScanner: click-driven, bounded Who census collection.
local ADDON,
    NS = ...

local Scanner = {}
NS.Scanner = Scanner

-- These are conservative addon policies, not measured server guarantees.
local SATURATION_ROWS      = 50
local MAX_QUERIES          = 500
local MAX_RESULT_ROWS      = 500
local MAX_CHOICES          = 64
local INITIAL_LEVEL_WIDTH  = 10
local NATIVE_WHO_FRAMES    = { "LFGWhoListFrame", "WhoFrame" }
local CLASS_TOKENS         = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

local eventFrame  = CreateFrame("Frame")
local state       = {
    state             = "idle",
    running           = false,
    paused            = false,
    awaiting          = false,
    completedQueries  = 0,
    plannedQueries    = 0,
    observed          = 0,
    newPlayers        = 0,
    returned          = 0,
    total             = 0,
    incomplete        = false,
    reason            = "",
}
local queue        = {}
local seen         = {}
local sentQueries  = 0
local sentAt       = -1000
local pendingQuery
local pendingContext
local drainPending        = false
local externalPending     = false
local blockedUntilReload  = false
local sending             = false
local routing             = false
local routingInternally   = false
local preferredRouting
local suspendedListeners = {}
local statusTicker
local lastCooldown = 0

local function Clock()
    return GetTime()
end

local function Number(value, minimum, maximum, fallback)
    if
        not NS.Readable(value)
        or type(value) ~= "number"
        or value ~= value
        or value == math.huge
        or value == -math.huge
    then
        return fallback
    end
    return math.max(minimum, math.min(maximum, math.floor(value)))
end

local function ReceivedNumber(value, minimum, maximum)
    if
        not NS.Readable(value)
        or type(value) ~= "number"
        or value ~= value
        or value < minimum
        or value > maximum
        or value % 1 ~= 0
    then
        return nil
    end
    return value
end

local function Interval()
    return Number(NS.db and NS.db.settings.queryInterval, 5, 120, 5)
end

local function Timeout()
    return Number(NS.db and NS.db.settings.queryTimeout, 5, 120, 10)
end

local function Cooldown()
    return math.max(0, math.ceil(sentAt + Interval() - Clock()))
end

local function Notify()
    NS:Notify("SCAN_STATUS_CHANGED")
end

local function NativeWhoShown()
    for frameIndex, frameName in ipairs(NATIVE_WHO_FRAMES) do
        local nativeFrame = _G[frameName]
        if nativeFrame and nativeFrame.IsShown and nativeFrame:IsShown() then
            return true
        end
    end
    return false
end

local function SetRouting(value)
    if C_FriendList and C_FriendList.SetWhoToUi then
        routingInternally = true
        pcall(C_FriendList.SetWhoToUi, value)
        routingInternally = false
    end
end

local function SuspendNativeListeners()
    for frameIndex, frameName in ipairs(NATIVE_WHO_FRAMES) do
        local nativeFrame = _G[frameName]
        if nativeFrame and nativeFrame.IsEventRegistered and nativeFrame:IsEventRegistered("WHO_LIST_UPDATE") then
            nativeFrame:UnregisterEvent("WHO_LIST_UPDATE")
            suspendedListeners[nativeFrame] = true
        end
    end
end

local function BeginRouting()
    if routing then
        return
    end
    routing = true
    if preferredRouting == nil then
        preferredRouting = NativeWhoShown()
    end
    SuspendNativeListeners()
    SetRouting(true)
end

local function EndRouting()
    if not routing then
        return
    end
    routing = false
    SetRouting(preferredRouting == true)
    for nativeFrame in pairs(suspendedListeners) do
        nativeFrame:RegisterEvent("WHO_LIST_UPDATE")
    end
    suspendedListeners = {}
end

local function StopTicker()
    if statusTicker then
        statusTicker:Cancel()
        statusTicker = nil
    end
end

local function Tick()
    if state.awaiting and Clock() - sentAt >= Timeout() then
        -- Who events carry no request ID. Do not let a late reply become the next query's answer.
        state.awaiting  = false
        state.paused    = true
        state.state     = "paused"
        state.reason    = "Who response timed out; waiting for its late response before retrying."
        drainPending    = true
        pendingQuery    = nil
        pendingContext  = nil
        EndRouting()
        Notify()
    end
    local cooldown = Cooldown()
    if cooldown ~= lastCooldown then
        lastCooldown = cooldown
        Notify()
    end
    if not state.awaiting and cooldown == 0 then
        StopTicker()
    end
end

local function StartTicker()
    if not statusTicker and C_Timer and C_Timer.NewTicker then
        statusTicker = C_Timer.NewTicker(0.25, Tick)
    end
end

local function QueryText(query)
    if query.raw then
        return query.raw
    end
    local parts = {}
    if query.race then
        parts[#parts + 1] = 'r-"' .. query.race .. '"'
    end
    if query.className then
        parts[#parts + 1] = 'c-"' .. query.className .. '"'
    end
    parts[#parts + 1] = query.minLevel .. "-" .. query.maxLevel
    return table.concat(parts, " ")
end

local function ChoiceName(value)
    local text = NS.Text(value)
    if text and not text:find('["\r\n]') then
        return text
    end
end

local function NativeRaceNames()
    local names     = {}
    local added     = {}
    local complete  = true
    if not (C_FriendList and C_FriendList.GetWhoRaceFilters) then
        return names, false
    end
    local succeeded,
        filters = pcall(C_FriendList.GetWhoRaceFilters)
    if not succeeded or not NS.Accessible(filters) then
        return names, false
    end
    complete = #filters <= MAX_CHOICES
    for filterIndex = 1, math.min(#filters, MAX_CHOICES) do
        local filter = filters[filterIndex]
        if NS.Accessible(filter) then
            local name = ChoiceName(filter.name)
            if name and not added[name] then
                names[#names + 1]  = name
                added[name]        = true
            elseif not name then
                complete = false
            end
        else
            complete = false
        end
    end
    table.sort(names)
    return names, complete
end

local function NativeClassNames()
    local names     = {}
    local added     = {}
    local complete  = true
    if C_SpecializationInfo and C_SpecializationInfo.GetAllClassIDs and GetClassInfo then
        local succeeded,
            classIDs = pcall(C_SpecializationInfo.GetAllClassIDs)
        if succeeded and NS.Accessible(classIDs) then
            complete = #classIDs <= MAX_CHOICES
            for classIndex = 1, math.min(#classIDs, MAX_CHOICES) do
                local classID = classIDs[classIndex]
                if NS.Readable(classID) and type(classID) == "number" then
                    local gotClass,
                        className = pcall(GetClassInfo, classID)
                    local name = gotClass and ChoiceName(className)
                    if name and not added[name] then
                        names[#names + 1]  = name
                        added[name]        = true
                    elseif not name then
                        complete = false
                    end
                else
                    complete = false
                end
            end
        end
    end
    if #names == 0 and NS.Accessible(LOCALIZED_CLASS_NAMES_MALE) then
        complete = true
        for tokenIndex, token in ipairs(CLASS_TOKENS) do
            local name = ChoiceName(LOCALIZED_CLASS_NAMES_MALE[token])
            if name and not added[name] then
                names[#names + 1]  = name
                added[name]        = true
            elseif not name then
                complete = false
            end
        end
    end
    table.sort(names)
    return names, complete
end

local function Subdivide(query)
    if query.raw then
        return nil
    end
    if query.minLevel < query.maxLevel then
        local midpoint = math.floor((query.minLevel + query.maxLevel) / 2)
        return {
            { minLevel = query.minLevel, maxLevel = midpoint, race = query.race, className = query.className },
            { minLevel = midpoint + 1, maxLevel = query.maxLevel, race = query.race, className = query.className },
        },
            true
    end
    local names
    local splitField
    local choicesComplete
    if not query.race then
        names, choicesComplete  = NativeRaceNames()
        splitField              = "race"
    elseif not query.className then
        names, choicesComplete  = NativeClassNames()
        splitField              = "className"
    end
    if not names or #names == 0 then
        return nil
    end
    local children = {}
    for nameIndex, name in ipairs(names) do
        local child = {
            minLevel   = query.minLevel,
            maxLevel   = query.maxLevel,
            race       = query.race,
            className  = query.className,
        }
        child[splitField]        = name
        children[#children + 1]  = child
    end
    return children, choicesComplete
end

local function MarkIncomplete(reason)
    state.incomplete  = true
    state.reason      = reason
end

local function Finish()
    state.running   = false
    state.paused    = false
    state.awaiting  = false
    state.state     = "complete"
    if not state.incomplete then
        state.reason =
            "Sweep finished. Observations describe this faction and scan period, not a live population total."
    end
    EndRouting()
    StartTicker()
    Notify()
end

local function ReadWho(resultIndex)
    local succeeded,
        raw = pcall(C_FriendList.GetWhoInfo, resultIndex)
    if not succeeded or not NS.Accessible(raw) then
        return nil
    end
    local name   = NS.Text(raw.fullName)
    local level  = ReceivedNumber(raw.level, 1, 255)
    if not name or not level then
        return nil
    end
    return {
        name       = name,
        level      = level,
        class      = NS.Text(raw.filename),
        className  = NS.Text(raw.classStr),
        race       = NS.Text(raw.raceStr),
        guild      = NS.Text(raw.fullGuildName, true),
        zone       = NS.Text(raw.area),
    }
end

local function MatchesQuery(info, query)
    if query.raw then
        return true
    end
    if info.level < query.minLevel or info.level > query.maxLevel then
        return false
    end
    if query.race and (not info.race or info.race:lower() ~= query.race:lower()) then
        return false
    end
    if query.className and (not info.className or info.className:lower() ~= query.className:lower()) then
        return false
    end
    return true
end

local function ReceiveWho()
    if blockedUntilReload then
        return
    end
    if drainPending then
        drainPending  = false
        state.reason  = state.running and "Late Who response discarded. Click Continue to retry the unfinished query."
            or "Late Who response discarded. A new sweep can now be started."
        Notify()
        return
    end
    if externalPending then
        externalPending = false
        Notify()
        return
    end
    if not state.awaiting or not pendingQuery then
        return
    end
    local query    = pendingQuery
    local context  = pendingContext
    pendingQuery    = nil
    pendingContext  = nil
    state.awaiting  = false
    EndRouting()
    if not NS.context or context ~= NS.context.key then
        state.running  = false
        state.paused   = false
        state.state    = "stopped"
        MarkIncomplete("Character realm or faction changed; the outstanding response was discarded.")
        Notify()
        return
    end
    local succeeded,
        delivered,
        total = pcall(C_FriendList.GetNumWhoResults)
    local deliveredCount  = ReceivedNumber(delivered, 0, 1000000)
    local returnedCount   = deliveredCount and math.min(deliveredCount, MAX_RESULT_ROWS)
    local totalCount      = ReceivedNumber(total, 0, 1000000)
    if not succeeded or not returnedCount then
        state.paused  = true
        state.state   = "paused"
        state.reason  = "Who result counts were unavailable. Click Continue to retry."
        Notify()
        return
    end
    state.returned  = returnedCount
    state.total     = totalCount or returnedCount
    local rows = {}
    for resultIndex = 1, returnedCount do
        local info = ReadWho(resultIndex)
        if info and not MatchesQuery(info, query) then
            state.paused  = true
            state.state   = "paused"
            state.reason  = "Who results did not match this query. Click Continue to retry."
            Notify()
            return
        elseif info then
            rows[#rows + 1] = info
        end
    end
    if #rows ~= returnedCount or not totalCount or totalCount < deliveredCount or deliveredCount > MAX_RESULT_ROWS then
        MarkIncomplete("Some Who results were missing, unreadable, or exceeded the local processing bound.")
    end
    if NS.Store.BeginBatch then
        NS.Store:BeginBatch()
    end
    for rowIndex, info in ipairs(rows) do
        local key = NS.NormalizeName(info.name)
        key = key and key:lower()
        local isNew = NS.Store:Observe(info, "who")
        if key and not seen[key] then
            seen[key]       = true
            state.observed  = state.observed + 1
        end
        if isNew then
            state.newPlayers = state.newPlayers + 1
        end
    end
    if NS.Store.EndBatch then
        NS.Store:EndBatch()
    end
    table.remove(queue, 1)
    state.completedQueries = state.completedQueries + 1
    local saturated = returnedCount >= SATURATION_ROWS or (totalCount and totalCount > returnedCount)
    if saturated then
        local children,
            choicesComplete = Subdivide(query)
        if children and state.plannedQueries + #children <= MAX_QUERIES then
            if not choicesComplete then
                MarkIncomplete("Some native race or class choices were unavailable; coverage may be incomplete.")
            end
            for childIndex = #children, 1, -1 do
                table.insert(queue, 1, children[childIndex])
            end
            state.plannedQueries = state.plannedQueries + #children
        else
            MarkIncomplete("A saturated query could not be split further or reached the 500-query planning bound.")
        end
    end
    if #queue == 0 then
        Finish()
    else
        state.state = state.paused and "paused" or "ready"
        Notify()
    end
end

function Scanner:GetStatus()
    return {
        state                 = state.state,
        running               = state.running,
        paused                = state.paused,
        awaiting              = state.awaiting,
        completedQueries      = state.completedQueries,
        plannedQueries        = state.plannedQueries,
        remainingQueries      = #queue,
        observed              = state.observed,
        newPlayers            = state.newPlayers,
        returned              = state.returned,
        total                 = state.total,
        incomplete            = state.incomplete,
        reason                = state.reason,
        currentQuery          = pendingQuery and QueryText(pendingQuery) or (queue[1] and QueryText(queue[1]) or ""),
        cooldown              = Cooldown(),
        pendingLateResponse   = drainPending,
        externalQueryPending  = externalPending,
        blockedUntilReload    = blockedUntilReload,
    }
end

-- Called only synchronously from a user action; timers never invoke this method.
function Scanner:Continue()
    Tick()
    if blockedUntilReload then
        return false, "An overlapping external Who query made responses ambiguous. Reload the UI before scanning again."
    end
    if drainPending or externalPending then
        return false, "Waiting for an earlier Who response before sending another query."
    end
    if not state.running or #queue == 0 then
        return false, "Start a census sweep first."
    end
    if state.awaiting then
        return false, "Waiting for the current Who response."
    end
    if not NS.ready or not NS.context or not NS.context.key then
        return false, "The character is not ready."
    end
    if not (C_FriendList and C_FriendList.SendWho and C_FriendList.GetWhoInfo and C_FriendList.GetNumWhoResults) then
        state.state   = "unavailable"
        state.reason  = "The required Who APIs are unavailable on this client."
        Notify()
        return false, state.reason
    end
    if Cooldown() > 0 then
        StartTicker()
        return false, "Waiting for the Who query cooldown."
    end
    if sentQueries >= MAX_QUERIES then
        queue = {}
        MarkIncomplete("The sweep reached the 500-query dispatch bound.")
        Finish()
        return false, state.reason
    end
    state.paused    = false
    state.awaiting  = true
    state.state     = "waiting"
    if not state.incomplete then
        state.reason = "Waiting for a Who response."
    end
    pendingQuery    = queue[1]
    pendingContext  = NS.context.key
    sentAt          = Clock()
    sentQueries     = sentQueries + 1
    BeginRouting()
    local origin = Enum and Enum.SocialWhoOrigin and Enum.SocialWhoOrigin.Social or nil
    sending = true
    local succeeded = pcall(C_FriendList.SendWho, QueryText(pendingQuery), origin)
    sending = false
    if not succeeded then
        state.awaiting  = false
        state.paused    = true
        state.state     = "paused"
        state.reason    = "The Who call failed; waiting for any late response before retrying."
        pendingQuery    = nil
        pendingContext  = nil
        drainPending    = true
        EndRouting()
    end
    StartTicker()
    Notify()
    return succeeded, succeeded and nil or state.reason
end

function Scanner:Start(options)
    if state.running then
        return self:Continue()
    end
    if drainPending or externalPending or blockedUntilReload then
        return false, "An earlier Who request must finish before a new sweep can start."
    end
    if not NS.ready then
        return false, "The character is not ready."
    end
    options = options or {}
    local settings  = NS.db.settings
    local minimum   = Number(options.minLevel or settings.minLevel, 1, 255, 1)
    local maximum   = Number(options.maxLevel or settings.maxLevel, 1, 255, 60)
    if minimum > maximum then
        return false, "The minimum level must not exceed the maximum level."
    end
    local customQuery = NS.Text(options.customQuery)
    if customQuery and (#customQuery > 255 or customQuery:find("[\r\n]")) then
        return false, "The custom Who query must be at most 255 characters on one line."
    end
    queue = {}
    if customQuery then
        queue[1] = { raw = customQuery }
    else
        for firstLevel = minimum, maximum, INITIAL_LEVEL_WIDTH do
            queue[#queue + 1] =
                { minLevel = firstLevel, maxLevel = math.min(firstLevel + INITIAL_LEVEL_WIDTH - 1, maximum) }
        end
    end
    seen                    = {}
    sentQueries             = 0
    state.state             = "ready"
    state.running           = true
    state.paused            = false
    state.awaiting          = false
    state.completedQueries  = 0
    state.plannedQueries    = #queue
    state.observed          = 0
    state.newPlayers        = 0
    state.returned          = 0
    state.total             = 0
    state.incomplete        = false
    state.reason            = "Click Continue to send the next Who query."
    return self:Continue()
end

function Scanner:Pause()
    if not state.running then
        return false
    end
    state.paused  = true
    state.state   = "paused"
    state.reason  = state.awaiting and "Paused; the outstanding response will still be collected." or "Sweep paused."
    Notify()
    return true
end

function Scanner:Stop()
    if state.awaiting then
        drainPending = true
    end
    pendingQuery    = nil
    pendingContext  = nil
    queue           = {}
    state.running   = false
    state.paused    = false
    state.awaiting  = false
    state.state     = blockedUntilReload and "blocked" or "stopped"
    if state.completedQueries < state.plannedQueries then
        MarkIncomplete("Sweep stopped before all queries finished.")
    end
    EndRouting()
    StopTicker()
    Notify()
end

function Scanner:SetWorldClickEnabled(enabled)
    NS.db.settings.worldClickEnabled = enabled == true
    NS:Notify("SETTINGS_CHANGED")
end

local function ExternalWho()
    if sending then
        return
    end
    sentAt = Clock()
    if state.awaiting or drainPending then
        blockedUntilReload  = true
        state.running       = false
        state.paused        = false
        state.awaiting      = false
        state.state         = "blocked"
        pendingQuery        = nil
        pendingContext      = nil
        MarkIncomplete("Another Who query overlapped this sweep. Reload the UI to clear ambiguous responses.")
        EndRouting()
    else
        externalPending = true
    end
    StartTicker()
    Notify()
end

if hooksecurefunc and C_FriendList then
    if C_FriendList.SendWho then
        pcall(hooksecurefunc, C_FriendList, "SendWho", ExternalWho)
    end
    if C_FriendList.SetWhoToUi then
        pcall(hooksecurefunc, C_FriendList, "SetWhoToUi", function(value)
            if not routingInternally and NS.Readable(value) and type(value) == "boolean" then
                preferredRouting = value
            end
        end)
    end
end

eventFrame:RegisterEvent("WHO_LIST_UPDATE")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("ADDON_ACTION_BLOCKED")
eventFrame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
eventFrame:RegisterEvent("PLAYER_LEAVING_WORLD")
eventFrame:SetScript("OnEvent", function(frame, event, addonName)
    if event == "WHO_LIST_UPDATE" then
        ReceiveWho()
    elseif event == "ADDON_LOADED" and routing then
        SuspendNativeListeners()
    elseif event == "PLAYER_LEAVING_WORLD" then
        if state.running then
            Scanner:Stop()
        end
    elseif (event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN") and state.awaiting then
        if NS.Text(addonName) == ADDON then
            state.paused  = true
            state.reason  = "The client blocked the Who request; awaiting a response or timeout."
            Notify()
        end
    end
end)

if WorldFrame and WorldFrame.HookScript then
    WorldFrame:HookScript("OnMouseDown", function()
        if NS.ready and NS.db.settings.worldClickEnabled and state.running and not state.paused then
            Scanner:Continue()
        end
    end)
end
