-- Batata Scanner: click-driven, bounded Who census collection.
-- Addon folder name and the shared private namespace supplied by the client.
local ADDON,
    NS = ...

-- Plans, dispatches, and collects one click-driven Who census sweep at a time.
local Scanner = {}
NS.Scanner = Scanner -- Publishes the scanner to core lifecycle, the API, and the scanner panel.

-- These are conservative addon policies, not measured server guarantees.
local SATURATION_ROWS      = 50 -- Reply size treated as possibly truncated, so the query is split.
local MAX_QUERIES          = 500 -- Upper bound on Who queries planned or sent per sweep.
local MAX_RESULT_ROWS      = 500 -- Most rows read from one Who reply; more marks coverage incomplete.
local MAX_CHOICES          = 64 -- Most race or class names used when splitting a single-level query.
local INITIAL_LEVEL_WIDTH  = 10 -- Level span of each initial query before any subdivision.
local READY_REASON         = "Ready for the next Who query." -- Status text while the next query may be sent.
local NATIVE_WHO_FRAMES    = { "LFGWhoListFrame", "WhoFrame" } -- Blizzard Who frames checked and silenced in sweeps.
-- Canonical class definitions used to validate supported Who filters and race combinations.
local CLASSES              = {
    { id = 1, token = "WARRIOR", name = "Warrior" },
    { id = 2, token = "PALADIN", name = "Paladin" },
    { id = 3, token = "HUNTER", name = "Hunter" },
    { id = 4, token = "ROGUE", name = "Rogue" },
    { id = 5, token = "PRIEST", name = "Priest" },
    { id = 7, token = "SHAMAN", name = "Shaman" },
    { id = 8, token = "MAGE", name = "Mage" },
    { id = 9, token = "WARLOCK", name = "Warlock" },
    { id = 11, token = "DRUID", name = "Druid" },
}
local FACTION_RACES = NS.FactionRaces -- Canonical race/class availability by character faction.

local THROTTLED_REASON = "Who request throttled; waiting for the cooldown before retrying." -- Throttle status text.

local eventFrame = CreateFrame("Frame") -- Receives Who replies, addon loads, and blocked-action events.
-- Live sweep progress reported by GetStatus and partly saved at shutdown.
local state = {
    state             = "idle", -- Phase: idle, ready, waiting, paused, complete, stopped, or unavailable.
    running           = false, -- Whether a sweep is active, including while paused.
    paused            = false, -- Whether world clicks are held until an explicit Continue.
    awaiting          = false, -- Whether a sent query is still waiting for its Who reply.
    completedQueries  = 0, -- Queries whose replies were processed this sweep.
    plannedQueries    = 0, -- Queries planned this sweep, including subdivided children.
    newPlayers        = 0, -- Players first recorded from this sweep's replies.
    returned          = 0, -- Rows read from the latest Who reply.
    total             = 0, -- Match count the server reported for the latest reply.
    incomplete        = false, -- Whether this sweep's coverage is known to be partial.
    reason            = "", -- User-facing explanation of the current phase.
}
local scanBehavior  = "random" -- Ordering policy used to insert and restore sweep queries.
local queue         = {} -- Pending sweep queries; the head stays queued until its reply is processed.
local sentQueries   = 0 -- Queries dispatched this sweep, capped at MAX_QUERIES.
local sentAt        = -1000 -- Clock time of the latest Who send by anyone; drives cooldown and timeout.
local holdUntil     = -1000 -- Earliest send time after an interrupted query or throttle.
local pendingQuery -- Query whose reply is outstanding; cleared on receipt, timeout, or stop.
local pendingContext -- Faction context key captured when the pending query was sent.
local pauseBeforeTimeout -- Manual pause state preserved while a timed-out throttle result is classified.
local coverageReason -- Incomplete-coverage explanation retained across transient status changes.
local drainPending       = false -- Whether Who replies are discarded during the retry cooldown.
local externalPending    = false -- Whether the next reply answers a non-addon Who query and is skipped.
local sending            = false -- True only during the addon's own SendWho call so the hook ignores it.
local debugEnabled       = false -- Whether slash-command diagnostics are enabled for new requests.
local pendingDebug       = false -- Whether to report the response for the outstanding request.
local routing            = false -- Whether Who replies are currently routed for an addon query.
local routingInternally  = false -- True while the addon calls SetWhoToUi so the hook keeps the user choice.
local preferredRouting -- Player's own SetWhoToUi choice, restored when addon routing ends.
local suspendedListeners  = {} -- Set of native frames whose WHO_LIST_UPDATE registration is suspended.
local hookedNativeFrames  = {} -- Native Who frames already hooked for visibility changes.
local statusTicker -- Ticker polling timeout and cooldown while either is active.
local lastCooldown = 0 -- Cooldown seconds last notified, so only changes trigger refreshes.

-- Returns the client uptime clock used for cooldowns, timeouts, and saved send times.
local function Clock()
    return GetTime()
end

local Number = NS.Number -- Shared numeric validator used for settings and reply bounds.

-- Returns a readable in-range integer from client data unchanged, or nil when invalid.
-- @param value Candidate result value to validate.
-- @param minimum Inclusive lower bound for the integer.
-- @param maximum Inclusive upper bound for the integer.
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

-- Returns the configured seconds between Who sends, clamped to 6-120 with default 15.
local function Interval()
    return Number(NS.db and NS.db.settings.queryInterval, 6, 120, 15)
end

-- Returns the configured Who reply timeout in seconds, clamped to 5-120 with default 10.
local function Timeout()
    return Number(NS.db and NS.db.settings.queryTimeout, 5, 120, 10)
end

-- Returns whole seconds until another query may be sent, honoring interval and retry holds.
local function Cooldown()
    return math.max(0, math.ceil(math.max(sentAt + Interval(), holdUntil) - Clock()))
end

-- Notifies internal listeners and API subscribers that scan status changed.
local function Notify()
    NS:Notify("SCAN_STATUS_CHANGED")
end

-- Returns whether a Blizzard Who list frame is currently visible.
local function NativeWhoShown()
    for frameIndex, frameName in ipairs(NATIVE_WHO_FRAMES) do
        local nativeFrame = _G[frameName]
        if nativeFrame and nativeFrame.IsVisible and nativeFrame:IsVisible() then
            return true
        end
    end
    return false
end

-- Safely reads one boolean from a client getter; trailing arguments are passed to that getter.
-- @param reader Client API function that returns the state being checked.
-- @param ... Arguments required by reader, such as the player unit token.
local function ReadBoolean(reader, ...)
    if type(reader) ~= "function" then
        return nil
    end
    local succeeded,
        value = pcall(reader, ...)
    if succeeded and NS.Readable(value) and type(value) == "boolean" then
        return value
    end
end

-- Reads combat and instance context, treating unknown state as a dispatch hold.
local function ReadEnvironment()
    local playerCombat    = ReadBoolean(UnitAffectingCombat, "player")
    local locked          = ReadBoolean(InCombatLockdown)
    local inCombat        = playerCombat == true or locked == true
    local inBattleground  = false
    local combatKnown     = playerCombat ~= nil and locked ~= nil
    local instanceKnown   = false
    if type(IsInInstance) == "function" then
        local succeeded,
            inside,
            instanceType = pcall(IsInInstance)
        if
            succeeded
            and NS.Readable(inside)
            and type(inside) == "boolean"
            and NS.Readable(instanceType)
            and type(instanceType) == "string"
            and instanceType ~= ""
        then
            inBattleground  = instanceType == "pvp"
            instanceKnown   = true
        end
    end
    return inCombat, inBattleground, not combatKnown or not instanceKnown
end

-- Returns the user-facing reason that currently blocks a new Who query, if any.
-- @param inCombat Whether player combat or combat lockdown is active.
-- @param inBattleground Whether the current instance is a battleground.
-- @param environmentUnavailable Whether a required environment getter was unreadable.
local function EnvironmentHold(inCombat, inBattleground, environmentUnavailable)
    if inCombat then
        return "Who scanning is paused during combat."
    elseif inBattleground then
        return "Who scanning is paused inside a battleground."
    elseif environmentUnavailable then
        return "Who scanning is paused because combat or instance state is unavailable."
    end
end

-- Hooks available native Who frames once so visibility changes refresh scan status.
local function HookNativeWhoFrames()
    local installed = false
    for frameIndex, frameName in ipairs(NATIVE_WHO_FRAMES) do
        local nativeFrame = _G[frameName]
        if nativeFrame and nativeFrame.HookScript and not hookedNativeFrames[nativeFrame] then
            nativeFrame:HookScript("OnShow", Notify)
            nativeFrame:HookScript("OnHide", Notify)
            hookedNativeFrames[nativeFrame]  = true
            installed                        = true
        end
    end
    if installed then
        Notify()
    end
end

-- Calls SetWhoToUi while flagging the change as internal so the hook ignores it.
-- @param value Routing preference to set for the addon's Who request.
local function SetRouting(value)
    if C_FriendList and C_FriendList.SetWhoToUi then
        routingInternally = true
        pcall(C_FriendList.SetWhoToUi, value)
        routingInternally = false
    end
end

-- Unregisters WHO_LIST_UPDATE from native Who frames and remembers them for restoration.
local function SuspendNativeListeners()
    for frameIndex, frameName in ipairs(NATIVE_WHO_FRAMES) do
        local nativeFrame = _G[frameName]
        if nativeFrame and nativeFrame.IsEventRegistered and nativeFrame:IsEventRegistered("WHO_LIST_UPDATE") then
            nativeFrame:UnregisterEvent("WHO_LIST_UPDATE")
            suspendedListeners[nativeFrame] = true
        end
    end
end

-- Captures the routing preference, silences native Who frames, and routes replies to the UI.
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

-- Restores the player's Who routing choice and re-registers suspended native frames.
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

-- Cancels the status ticker if one is running.
local function StopTicker()
    if statusTicker then
        statusTicker:Cancel()
        statusTicker = nil
    end
end

-- Quarantines a possibly late reply and retains queued work through the retry cooldown.
-- @param reason User-facing explanation for the interrupted request.
local function HoldForRetry(reason)
    holdUntil         = math.max(holdUntil, Clock() + math.max(Interval(), Timeout()))
    state.awaiting    = false
    state.state       = state.running and (state.paused and "paused" or "ready") or state.state
    state.incomplete  = state.incomplete or state.running
    state.reason      = reason
    if state.running then
        coverageReason = reason
    end
    drainPending        = true
    externalPending     = false
    pauseBeforeTimeout  = nil
    pendingQuery        = nil
    pendingContext      = nil
    pendingDebug        = false
    EndRouting()
end

-- Quarantines overdue replies, notifies cooldown changes, and stops ticking once idle.
local function Tick()
    if (state.awaiting or externalPending) and Clock() - sentAt >= Timeout() then
        -- Ignore replies during a bounded cooldown before retrying the queued chunk.
        local ownedTimeout = state.awaiting
        HoldForRetry(
            ownedTimeout
                    and "Who response timed out; retained the unfinished chunk for retry. Coverage may be incomplete."
                or "External Who response timed out; scanning can resume after the cooldown."
        )
        if ownedTimeout then
            pauseBeforeTimeout = state.paused
        end
        Notify()
    end
    if drainPending and Clock() >= holdUntil then
        drainPending        = false
        pauseBeforeTimeout  = nil
        Notify()
    end
    local cooldown = Cooldown()
    if cooldown == 0 and state.reason == THROTTLED_REASON then
        state.reason = "Who cooldown finished; ready to retry the unfinished query."
    end
    if cooldown ~= lastCooldown then
        lastCooldown = cooldown
        Notify()
    end
    if not state.awaiting and not externalPending and cooldown == 0 then
        StopTicker()
    end
end

-- Starts the quarter-second status ticker when C_Timer exists and none is running.
local function StartTicker()
    if not statusTicker and C_Timer and C_Timer.NewTicker then
        statusTicker = C_Timer.NewTicker(0.25, Tick)
    end
end

-- Recognizes a supported Who throttle message and extends the local retry cooldown.
-- @param message System or UI error text emitted by the client.
local function WhoThrottled(message)
    if not (state.awaiting or externalPending or pauseBeforeTimeout ~= nil) then
        return
    end
    local text = NS.Text(message)
    if
        not text
        or (
            text ~= NS.Text(ERR_WHO_LIST_WAIT)
            and text ~= "You must wait a moment longer before using /who again"
            and text ~= "You must wait a moment longer before using /who again."
        )
    then
        return
    end
    if pauseBeforeTimeout ~= nil then
        state.paused        = pauseBeforeTimeout
        pauseBeforeTimeout  = nil
        drainPending        = false
    end
    holdUntil        = math.max(holdUntil, Clock() + math.max(Interval() * 2, Timeout()))
    state.awaiting   = false
    state.state      = state.running and (state.paused and "paused" or "ready") or state.state
    state.reason     = THROTTLED_REASON
    pendingQuery     = nil
    pendingContext   = nil
    pendingDebug     = false
    externalPending  = false
    EndRouting()
    StartTicker()
    Notify()
end

-- Builds the SendWho filter text from a query's race, class, and level range.
-- @param query Query record containing bounds and optional race/class filters.
local function QueryText(query)
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

-- Returns readable text safe to quote in a Who filter, or nil if it has quotes or newlines.
-- @param value Candidate race/class name to validate for query syntax.
local function ChoiceName(value)
    local text = NS.Text(value)
    if text and not text:find('["\r\n]') then
        return text
    end
end

-- Resolves one class definition to its localized Who-filter display name.
-- @param classDefinition Class ID, token, and fallback name from the supported class list.
local function ClassName(classDefinition)
    if GetClassInfo then
        local succeeded,
            name = pcall(GetClassInfo, classDefinition.id)
        local localizedName = succeeded and ChoiceName(name)
        if localizedName then
            return localizedName
        end
    end
    if NS.Accessible(LOCALIZED_CLASS_NAMES_MALE) then
        local localizedName = ChoiceName(LOCALIZED_CLASS_NAMES_MALE[classDefinition.token])
        if localizedName then
            return localizedName
        end
    end
    return classDefinition.name
end

-- Resolves a localized or canonical class name to its token and display name.
-- @param className Class label from settings, a query, or a Who result.
local function ClassToken(className)
    if not className then
        return nil
    end
    local normalizedName = className:lower()
    for classIndex, classDefinition in ipairs(CLASSES) do
        local localizedName  = ClassName(classDefinition)
        local femaleName     = NS.Accessible(LOCALIZED_CLASS_NAMES_FEMALE)
            and ChoiceName(LOCALIZED_CLASS_NAMES_FEMALE[classDefinition.token])
        if
            normalizedName == classDefinition.token:lower()
            or normalizedName == classDefinition.name:lower()
            or normalizedName == localizedName:lower()
            or (femaleName and normalizedName == femaleName:lower())
        then
            return classDefinition.token, localizedName
        end
    end
end

-- Builds current-faction race choices and reports whether native choices were complete.
local function RaceChoices()
    local nativeNames  = {}
    local complete     = true
    if C_FriendList and C_FriendList.GetWhoRaceFilters then
        local succeeded,
            filters = pcall(C_FriendList.GetWhoRaceFilters)
        if succeeded and NS.Accessible(filters) then
            complete = #filters <= MAX_CHOICES
            for filterIndex = 1, math.min(#filters, MAX_CHOICES) do
                local filter = filters[filterIndex]
                if NS.Accessible(filter) then
                    local raceID  = ReceivedNumber(filter.ID, 1, 1000)
                    local name    = ChoiceName(filter.name)
                    if raceID and name then
                        nativeNames[raceID] = name
                    else
                        complete = false
                    end
                else
                    complete = false
                end
            end
        else
            complete = false
        end
    end
    local races = {}
    for raceIndex, raceDefinition in ipairs(FACTION_RACES[NS.context and NS.context.faction] or {}) do
        local name = nativeNames[raceDefinition.id]
        if not name and C_CreatureInfo and C_CreatureInfo.GetRaceInfo then
            local succeeded,
                info = pcall(C_CreatureInfo.GetRaceInfo, raceDefinition.id)
            if succeeded and NS.Accessible(info) then
                name = ChoiceName(info.raceName)
            end
        end
        races[#races + 1] = { name = name or raceDefinition.name, definition = raceDefinition }
    end
    return races, complete
end

-- Finds a current-faction race definition matching a displayed or canonical name.
-- @param raceName Race label from a saved or active query.
local function FindRace(raceName)
    for raceIndex, race in ipairs(RaceChoices()) do
        if raceName:lower() == race.name:lower() or raceName:lower() == race.definition.name:lower() then
            return race.definition
        end
    end
end

-- Checks whether a class token is available to one race in the Forever class matrix.
-- @param raceDefinition Race record whose allowed class list is checked.
-- @param classToken Canonical class token to find in that list.
local function RaceAllowsClass(raceDefinition, classToken)
    for classIndex, allowedToken in ipairs(raceDefinition.classes) do
        if classToken == allowedToken then
            return true
        end
    end
    return false
end

-- Returns sorted native race labels compatible with an optional class filter.
-- @param className Optional class label used to restrict available races.
local function NativeRaceNames(className)
    local names       = {}
    local classToken  = ClassToken(className)
    local races,
        complete = RaceChoices()
    for raceIndex, race in ipairs(races) do
        if not classToken or RaceAllowsClass(race.definition, classToken) then
            names[#names + 1] = race.name
        end
    end
    table.sort(names)
    return names, complete and (not className or classToken ~= nil)
end

-- Returns sorted localized class labels compatible with an optional race filter.
-- @param raceName Optional race label used to restrict available classes.
local function NativeClassNames(raceName)
    local names           = {}
    local raceDefinition  = raceName and FindRace(raceName)
    for classIndex, classDefinition in ipairs(CLASSES) do
        if not raceDefinition or RaceAllowsClass(raceDefinition, classDefinition.token) then
            names[#names + 1] = ClassName(classDefinition)
        end
    end
    table.sort(names)
    return names, not raceName or raceDefinition ~= nil
end

-- Inserts a query at the requested position or at a randomized sweep position.
-- @param query Query record with level bounds and optional race/class filters.
-- @param position Queue insertion position used by ordered sweep behavior.
local function Enqueue(query, position)
    table.insert(queue, scanBehavior == "random" and math.random(#queue + 1) or position, query)
end

-- Splits a query by level halves, then race, then class; returns children and completeness.
-- @param query Saturated query record to subdivide.
local function Subdivide(query)
    if query.minLevel < query.maxLevel then
        local midpoint  = math.floor((query.minLevel + query.maxLevel) / 2)
        local children  = {
            { minLevel = query.minLevel, maxLevel = midpoint, race = query.race, className = query.className },
            { minLevel = midpoint + 1, maxLevel = query.maxLevel, race = query.race, className = query.className },
        }
        if scanBehavior == "reversed" then
            return { children[2], children[1] }, true
        end
        return children, true
    end
    local names
    local splitField
    local choicesComplete
    if not query.race then
        names, choicesComplete  = NativeRaceNames(query.className)
        splitField              = "race"
    elseif not query.className then
        names, choicesComplete  = NativeClassNames(query.race)
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

-- Flags the sweep's coverage as incomplete and records the reason.
-- @param reason User-facing explanation for why this sweep may have missed results.
local function MarkIncomplete(reason)
    state.incomplete  = true
    state.reason      = reason
    coverageReason    = reason
end

-- Marks the sweep complete, restores Who routing, and notifies listeners.
local function Finish()
    state.running   = false
    state.paused    = false
    state.awaiting  = false
    state.state     = "complete"
    if state.incomplete then
        state.reason = "Sweep finished with incomplete coverage."
    else
        state.reason =
            "Sweep finished. Observations describe this faction and scan period, not a live population total."
    end
    EndRouting()
    StartTicker()
    Notify()
end

-- Returns one Who result as an observation record, or nil if unreadable or invalid.
-- @param resultIndex One-based row index in the current native Who result list.
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

-- Returns whether a Who result fits the query's level range and race and class filters.
-- @param info Readable observation created from one Who row.
-- @param query Query record that requested the row.
local function MatchesQuery(info, query)
    if info.level < query.minLevel or info.level > query.maxLevel then
        return false
    end
    if query.race and (not info.race or info.race:lower() ~= query.race:lower()) then
        return false
    end
    if query.className then
        local expectedClass  = ClassToken(query.className)
        local receivedClass  = ClassToken(info.class) or ClassToken(info.className)
        if not expectedClass or receivedClass ~= expectedClass then
            return false
        end
    end
    return true
end

-- Handles a Who reply: discards late or foreign replies, else records rows and splits.
local function ReceiveWho()
    if drainPending then
        pauseBeforeTimeout = nil
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
    local query        = pendingQuery
    local context      = pendingContext
    local reportDebug  = pendingDebug
    pendingQuery    = nil
    pendingContext  = nil
    pendingDebug    = false
    state.awaiting  = false
    EndRouting()
    if not NS.context or context ~= NS.context.key then
        if reportDebug then
            NS:Print("Who response: discarded because the character context changed; size unavailable.")
        end
        state.running  = false
        state.paused   = false
        state.state    = "stopped"
        MarkIncomplete("Character faction changed; the outstanding response was discarded.")
        Notify()
        return
    end
    local succeeded,
        delivered,
        total = pcall(C_FriendList.GetNumWhoResults)
    local deliveredCount  = ReceivedNumber(delivered, 0, 1000000)
    local returnedCount   = deliveredCount and math.min(deliveredCount, MAX_RESULT_ROWS)
    local totalCount      = ReceivedNumber(total, 0, 1000000)
    if reportDebug then
        local responseSize = deliveredCount and tostring(deliveredCount) .. " rows received" or "size unavailable"
        if totalCount then
            responseSize = responseSize .. " (server total: " .. tostring(totalCount) .. ")"
        end
        NS:Print("Who response: " .. responseSize .. ".")
    end
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
        if NS.Store:Observe(info) then
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
                Enqueue(children[childIndex], 1)
            end
            state.plannedQueries = state.plannedQueries + #children
        else
            MarkIncomplete("A saturated query could not be split further or reached the 500-query planning bound.")
        end
    end
    NS:Notify("WHO_RESULTS_RECEIVED")
    if #queue == 0 then
        Finish()
    else
        state.state   = state.paused and "paused" or "ready"
        state.reason  = state.paused and "Sweep paused." or READY_REASON
        Notify()
    end
end

-- Builds a sweep without dispatching; only a user action may send its first query.
-- @param options Optional level range and selected class list for the sweep.
local function PrepareSweep(options)
    local settings  = NS.db.settings
    local override  = settings.overrideDefaults
    local minimum   = Number(options.minLevel or (override and settings.minLevel), 1, 255, 1)
    local maximum   = Number(options.maxLevel or (override and settings.maxLevel), 1, 255, 60)
    local classes   = options.classes or (override and settings.scanClasses) or nil
    if minimum > maximum then
        return false, "The minimum level must not exceed the maximum level."
    end
    local classNames = {}
    for classIndex, className in ipairs(type(classes) == "table" and classes or {}) do
        local name = ChoiceName(className)
        if name then
            local classToken,
                localizedName = ClassToken(name)
            if not classToken then
                return false, "Choose a supported Forever class to scan."
            end
            classNames[#classNames + 1] = localizedName
        end
    end
    if type(classes) == "table" and #classNames == 0 then
        return false, "Choose at least one class to scan."
    end
    scanBehavior = (settings.scanBehavior == "ordered" or settings.scanBehavior == "reversed") and settings.scanBehavior
        or "random"
    queue = {}
    local rangeCount = math.ceil((maximum - minimum + 1) / INITIAL_LEVEL_WIDTH)
    for rangeIndex = 1, rangeCount do
        local rangeOffset  = scanBehavior == "reversed" and (rangeCount - rangeIndex) or (rangeIndex - 1)
        local firstLevel   = minimum + rangeOffset * INITIAL_LEVEL_WIDTH
        local lastLevel    = math.min(firstLevel + INITIAL_LEVEL_WIDTH - 1, maximum)
        if #classNames == 0 then
            Enqueue({ minLevel = firstLevel, maxLevel = lastLevel }, #queue + 1)
        end
        for classIndex, className in ipairs(classNames) do
            Enqueue({ minLevel = firstLevel, maxLevel = lastLevel, className = className }, #queue + 1)
        end
    end
    sentQueries             = 0
    state.state             = "ready"
    state.running           = true
    state.paused            = false
    state.awaiting          = false
    state.completedQueries  = 0
    state.plannedQueries    = #queue
    state.newPlayers        = 0
    state.returned          = 0
    state.total             = 0
    state.incomplete        = drainPending
    state.reason = drainPending and "An interrupted Who request may leave late replies; coverage may be incomplete."
        or READY_REASON
    coverageReason = state.incomplete and state.reason or nil
    return true
end

-- Returns a validated query rebuilt from saved data, or nil if any field is invalid.
-- @param saved Candidate query record read from SavedVariables.
local function RestoredQuery(saved)
    if type(saved) ~= "table" then
        return nil
    end
    local minimum    = Number(saved.minLevel, 1, 255, nil)
    local maximum    = Number(saved.maxLevel, 1, 255, nil)
    local race       = saved.race ~= nil and ChoiceName(saved.race) or nil
    local className  = saved.className ~= nil and ChoiceName(saved.className) or nil
    if not minimum or not maximum or minimum > maximum then
        return nil
    end
    if (saved.race ~= nil and not race) or (saved.className ~= nil and not className) then
        return nil
    end
    local raceDefinition  = race and FindRace(race)
    local classToken      = className and ClassToken(className)
    if (race and not raceDefinition) or (className and not classToken) then
        return nil
    end
    if raceDefinition and classToken and not RaceAllowsClass(raceDefinition, classToken) then
        return nil
    end
    return { minLevel = minimum, maxLevel = maximum, race = race, className = className }
end

-- Restores the sweep saved at logout, or prepares a playing sweep when none was saved.
function Scanner:Restore()
    local saved = NS.db.scanner
    if type(saved) ~= "table" then
        PrepareSweep({})
        Notify()
        return
    end
    local savedQueue   = type(saved.queue) == "table" and saved.queue or {}
    local interrupted  = saved.awaiting == true or saved.state == "blocked"
    scanBehavior = (saved.scanBehavior == "ordered" or saved.scanBehavior == "reversed") and saved.scanBehavior
        or "random"
    queue = {}
    for queryIndex = 1, math.min(#savedQueue, MAX_QUERIES) do
        queue[#queue + 1] = RestoredQuery(savedQueue[queryIndex])
    end
    sentQueries = Number(saved.sentQueries, 0, MAX_QUERIES, 0)
    -- GetTime continues across reloads; a later value means the computer restarted.
    if type(saved.sentAt) == "number" and saved.sentAt == saved.sentAt and saved.sentAt <= Clock() then
        sentAt = saved.sentAt
        if type(saved.holdUntil) == "number" and saved.holdUntil >= sentAt and saved.holdUntil <= sentAt + 240 then
            holdUntil = saved.holdUntil
        end
        if interrupted then
            holdUntil = math.max(holdUntil, sentAt + math.max(Interval(), Timeout()))
        end
    end
    drainPending = interrupted and Clock() < holdUntil
    if
        saved.faction
        and saved.faction ~= NS.context.faction
        and (saved.running == true or saved.state == "blocked")
    then
        local prepared,
            reason = PrepareSweep({})
        state.paused = prepared and saved.paused == true
        if not prepared then
            queue          = {}
            state.running  = false
            state.state    = "stopped"
            MarkIncomplete(reason)
        else
            state.incomplete = state.incomplete or interrupted
            if state.incomplete and not coverageReason then
                coverageReason = "An earlier Who request was interrupted; coverage may be incomplete."
            end
            state.state   = state.paused and "paused" or "ready"
            state.reason  = state.paused and "New faction sweep prepared; still manually paused."
                or "Character faction changed; prepared a new sweep for this faction."
        end
        StartTicker()
        Notify()
        return
    end
    state.completedQueries  = Number(saved.completedQueries, 0, MAX_QUERIES, 0)
    state.plannedQueries    = Number(saved.plannedQueries, 0, MAX_QUERIES, 0)
    state.newPlayers        = Number(saved.newPlayers, 0, 1000000000, 0)
    state.returned          = 0
    state.total             = 0
    state.incomplete = saved.incomplete == true or saved.state == "blocked" or (interrupted and saved.running == true)
    state.reason = state.incomplete
            and (NS.Text(saved.reason) or "An earlier Who request was interrupted; coverage may be incomplete.")
        or ""
    state.awaiting = false
    if state.reason:find("/reload", 1, true) or state.reason:find("Reload the UI", 1, true) then
        state.reason = "An earlier Who request was interrupted; coverage may be incomplete."
    end
    coverageReason = state.incomplete and state.reason or nil
    if #queue < #savedQueue then
        MarkIncomplete("Some saved Who queries could not be restored; coverage may be incomplete.")
    end
    if not saved.faction and #queue > 0 then
        MarkIncomplete("The saved sweep has no faction context; coverage may be incomplete.")
    end
    state.running  = (saved.running == true or saved.state == "blocked") and #queue > 0
    state.paused   = state.running and saved.paused == true
    if state.paused then
        state.state   = "paused"
        state.reason  = "Sweep paused."
    elseif state.running then
        state.state   = "ready"
        state.reason  = READY_REASON
    else
        queue        = {}
        state.state  = saved.state == "complete" and "complete" or "stopped"
        if state.state == "complete" and state.incomplete then
            state.reason = "Sweep finished with incomplete coverage."
        end
    end
    StartTicker()
    Notify()
end

-- Saves the sweep for the next load and returns Who routing to the player's preference.
function Scanner:Shutdown()
    if not NS.ready then
        return
    end
    NS.db.scanner = {
        faction           = NS.context.faction,
        state             = state.state,
        running           = state.running,
        paused            = state.paused,
        awaiting          = state.awaiting or drainPending or externalPending,
        scanBehavior      = scanBehavior,
        queue             = queue,
        sentQueries       = sentQueries,
        sentAt            = sentAt,
        holdUntil         = holdUntil,
        completedQueries  = state.completedQueries,
        plannedQueries    = state.plannedQueries,
        newPlayers        = state.newPlayers,
        incomplete        = state.incomplete,
        reason            = state.incomplete and (coverageReason or state.reason) or nil,
    }
    EndRouting()
    StopTicker()
end

-- Returns the localized class names offered as sweep class filters.
function Scanner:ClassChoices()
    local names = NativeClassNames()
    return names
end

-- Returns a fresh status snapshot of progress, current query, cooldown, and quarantine.
function Scanner:GetStatus()
    local inCombat,
        inBattleground,
        environmentUnavailable = ReadEnvironment()
    local reason = state.reason
    if state.incomplete and coverageReason and reason ~= coverageReason then
        reason = reason .. " " .. coverageReason
    end
    local holdReason = EnvironmentHold(inCombat, inBattleground, environmentUnavailable)
    if state.running and holdReason then
        reason = reason .. " " .. holdReason
    end
    return {
        state                   = state.state,
        running                 = state.running,
        paused                  = state.paused,
        awaiting                = state.awaiting,
        completedQueries        = state.completedQueries,
        plannedQueries          = state.plannedQueries,
        remainingQueries        = #queue,
        newPlayers              = state.newPlayers,
        returned                = state.returned,
        total                   = state.total,
        incomplete              = state.incomplete,
        reason                  = reason,
        currentQuery            = pendingQuery and QueryText(pendingQuery) or (queue[1] and QueryText(queue[1]) or ""),
        cooldown                = Cooldown(),
        pendingLateResponse     = drainPending,
        externalQueryPending    = externalPending,
        nativeWhoOpen           = NativeWhoShown(),
        inCombat                = inCombat,
        inBattleground          = inBattleground,
        environmentUnavailable  = environmentUnavailable,
        blockedUntilReload      = false,
    }
end

-- Toggles per-session diagnostics for Who requests and their matching responses.
function Scanner:ToggleDebug()
    debugEnabled = not debugEnabled
    NS:Print("Who query debug " .. (debugEnabled and "enabled." or "disabled.") .. " Applies to new requests.")
    return debugEnabled
end

-- Called only synchronously from a user action; timers never invoke this method.
function Scanner:Continue()
    Tick()
    if drainPending or externalPending then
        return false, "Who requests are cooling down before the next query."
    end
    if not state.running or #queue == 0 then
        return false, "Start a census sweep first."
    end
    if state.awaiting then
        return false, "Waiting for the current Who response."
    end
    local holdReason = EnvironmentHold(ReadEnvironment())
    if holdReason then
        Notify()
        return false, holdReason
    end
    if NativeWhoShown() then
        Notify()
        return false, "Paused while the Who list is open."
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
    state.reason    = "Waiting for a Who response."
    pendingQuery    = queue[1]
    pendingContext  = NS.context.key
    local queryText = QueryText(pendingQuery)
    pendingDebug  = debugEnabled
    sentAt        = Clock()
    sentQueries   = sentQueries + 1
    BeginRouting()
    local origin = Enum and Enum.SocialWhoOrigin and Enum.SocialWhoOrigin.Social or nil
    sending = true
    if pendingDebug then
        NS:Print("Who query: " .. queryText)
    end
    local succeeded = pcall(C_FriendList.SendWho, queryText, origin)
    sentAt   = Clock()
    sending  = false
    if not succeeded then
        HoldForRetry("The Who call failed; retained the unfinished chunk for retry after the cooldown.")
    end
    StartTicker()
    Notify()
    return succeeded, succeeded and nil or state.reason
end

-- Prepares a sweep from options and sends its first query; continues one already running.
-- @param options Optional level bounds and class selection for a new sweep.
function Scanner:Start(options)
    Tick()
    if state.running then
        return self:Continue()
    end
    if drainPending or externalPending then
        return false, "Who requests are cooling down before a new sweep can start."
    end
    if not NS.ready then
        return false, "The character is not ready."
    end
    local prepared,
        reason = PrepareSweep(options or {})
    if not prepared then
        return false, reason
    end
    return self:Continue()
end

-- Pauses a running sweep while still collecting any outstanding reply; returns success.
function Scanner:Pause()
    if not state.running then
        return false
    end
    if pauseBeforeTimeout ~= nil then
        pauseBeforeTimeout = true
    end
    state.paused  = true
    state.state   = "paused"
    state.reason  = state.awaiting and "Paused; the outstanding response will still be collected." or "Sweep paused."
    Notify()
    return true
end

-- Ends the sweep, quarantines any outstanding reply, and restores native Who routing.
function Scanner:Stop()
    if state.awaiting then
        HoldForRetry("Sweep stopped; the Who retry cooldown is still active.")
    end
    pauseBeforeTimeout  = nil
    pendingQuery        = nil
    pendingContext      = nil
    pendingDebug        = false
    queue               = {}
    state.running       = false
    state.paused        = false
    state.awaiting      = false
    state.state         = "stopped"
    if state.completedQueries < state.plannedQueries then
        MarkIncomplete("Sweep stopped before all queries finished.")
    end
    if drainPending then
        state.reason = "Sweep stopped; the Who retry cooldown is still active."
    end
    EndRouting()
    StartTicker()
    Notify()
end

-- Drops the queue for a sweep built from current settings; any outstanding reply is quarantined.
function Scanner:Restart()
    if not NS.ready then
        return false, "The character is not ready."
    end
    self:Stop()
    local prepared,
        reason = PrepareSweep({})
    if not prepared then
        return false, reason
    end
    Notify()
    return self:Continue()
end

-- Tracks outside SendWho calls; overlaps defer the queued chunk through a retry cooldown.
local function ExternalWho()
    if sending then
        return
    end
    sentAt = Clock()
    if state.awaiting or drainPending or externalPending then
        HoldForRetry("Overlapping Who requests; queued work will retry after the cooldown. Coverage may be incomplete.")
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
        -- Tracks the external routing choice; value is the preference supplied to SetWhoToUi.
        pcall(hooksecurefunc, C_FriendList, "SetWhoToUi", function(value)
            if not routingInternally and NS.Readable(value) and type(value) == "boolean" then
                preferredRouting = value
            end
        end)
    end
end

eventFrame:RegisterEvent("WHO_LIST_UPDATE")
eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")
eventFrame:RegisterEvent("UI_ERROR_MESSAGE")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("ADDON_ACTION_BLOCKED")
eventFrame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
-- Handles Who results, throttle text, addon load, combat/zone changes, and blocked actions.
-- @param frame Event receiver registered above.
-- @param event Name of the client event being handled.
-- @param eventValue First payload, such as the addon name or system message.
-- @param eventMessage UI error message used for throttle detection.
eventFrame:SetScript("OnEvent", function(frame, event, eventValue, eventMessage)
    if event == "WHO_LIST_UPDATE" then
        ReceiveWho()
    elseif event == "CHAT_MSG_SYSTEM" then
        WhoThrottled(eventValue)
    elseif event == "UI_ERROR_MESSAGE" then
        WhoThrottled(eventMessage)
    elseif
        event == "PLAYER_REGEN_DISABLED"
        or event == "PLAYER_REGEN_ENABLED"
        or event == "PLAYER_ENTERING_WORLD"
        or event == "ZONE_CHANGED_NEW_AREA"
    then
        Notify()
    elseif event == "ADDON_LOADED" then
        if routing then
            SuspendNativeListeners()
        end
        HookNativeWhoFrames()
    elseif (event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN") and state.awaiting then
        if NS.Text(eventValue) == ADDON then
            HoldForRetry(
                "The client blocked the Who request; retained the unfinished chunk for retry after the cooldown."
            )
            StartTicker()
            Notify()
        end
    end
end)

HookNativeWhoFrames()

if WorldFrame and WorldFrame.HookScript then
    -- Sends one queued Who request after an eligible world click; event arguments are unused.
    WorldFrame:HookScript("OnMouseDown", function()
        if
            NS.ready
            and state.running
            and not state.paused
            and not NativeWhoShown()
            and Cooldown() == 0
            and not EnvironmentHold(ReadEnvironment())
        then
            Scanner:Continue()
        end
    end)
end
