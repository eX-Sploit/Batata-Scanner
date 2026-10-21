-- BatataScanner: player census store with persistence, filtering, sorting, and search.
-- Addon folder name and the shared private namespace supplied by the client.
local ADDON,
    NS = ...

-- Owns player records: loads and saves rows, records observations, and answers queries.
local Store = {}
NS.Store = Store -- Shares the store with other internal modules.

local cachedCensus -- Unfiltered census copy reused until stored data changes.
local MAX_CACHED_ORDERS    = 2 -- Number of most recently used sorted identity arrays retained.
local MAX_SEARCH_RESULTS   = 1000 -- Maximum matching records retained by one scanner-browser search.
local recentOrders         = {} -- Sort fields ordered from least to most recently used.
local cachedOrders         = {} -- Sorted identity arrays keyed by sort field; cleared when their order changes.
local notificationPending  = false -- True while a deferred DATA_UPDATED notification is queued.
local batchDepth           = 0 -- Nesting depth of open BeginBatch calls.
local batchChanged         = false -- True when data changed inside the current batch.
local players              = {} -- Live player records keyed by lowercase name.
local summaries            = {} -- Maintained all-faction and per-faction census aggregates.
local playerKeys           = {} -- Stable lowercase identities used to collect search snapshots.
local searchSnapshots      = setmetatable({}, { __mode = "k" }) -- Pre-update records retained only for active searches.

-- Ordered player fields; positions define the saved row layout and copied record shape.
local playerFields = {
    "name",
    "faction",
    "level",
    "class",
    "race",
    "guild",
    "firstSeen",
    "lastSeen",
    "zone",
}
local observedFields  = { "faction", "level", "class", "race", "guild", "lastSeen", "zone" } -- Updated per sighting.
local sortFields      = { -- Fields accepted as sort keys.
    name       = true,
    level      = true,
    firstSeen  = true,
    lastSeen   = true,
    guild      = true,
    class      = true,
    race       = true,
    zone       = true,
    faction    = true,
}
local optionFields   = { sort = true, offset = true, limit = true, descending = true } -- Allowed page/sort option names.
local matchFields    = { "faction", "class", "race", "guild", "zone" } -- Exact-match player filters.
local summaryFields  = { faction = true, level = true, class = true, race = true, guild = true } -- Fields affecting aggregates.

-- Stores a sorted identity array and evicts the least-recently used sort when over capacity.
-- @param sort Player field whose order is cached.
-- @param order Optional identity array; nil clears the cache entry for this field.
local function CacheOrder(sort, order)
    for orderIndex, field in ipairs(recentOrders) do
        if field == sort then
            table.remove(recentOrders, orderIndex)
            break
        end
    end
    cachedOrders[sort] = order
    if order then
        recentOrders[#recentOrders + 1] = sort
        if #recentOrders > MAX_CACHED_ORDERS then
            cachedOrders[table.remove(recentOrders, 1)] = nil
        end
    end
end

-- Creates an empty census accumulator with every count field initialized.
local function NewCensus()
    return {
        total         = 0,
        byClass       = {},
        byRace        = {},
        byGuild       = {},
        byLevel       = {},
        guilded       = 0,
        unguilded     = 0,
        unknownGuild  = 0,
    }
end

-- Adds an amount to one keyed count and removes the key when its result reaches zero.
-- @param counts Count table to mutate.
-- @param key Category being counted.
-- @param amount Signed change, usually one or negative one.
local function Increment(counts, key, amount)
    local count = (counts[key] or 0) + amount
    counts[key] = count ~= 0 and count or nil
end

-- Adds or removes one player's values from every relevant census breakdown.
-- @param census Census accumulator to update.
-- @param player Stored player record being counted.
-- @param amount Signed contribution to each count.
local function CountPlayer(census, player, amount)
    census.total = census.total + amount
    Increment(census.byClass, player.class or "Unknown", amount)
    Increment(census.byRace, player.race or "Unknown", amount)
    Increment(census.byLevel, player.level or 0, amount)
    if player.guild ~= nil then
        Increment(census.byGuild, player.guild, amount)
    end
    local guildStatus = player.guild == nil and "unknownGuild" or (player.guild == "" and "unguilded" or "guilded")
    census[guildStatus] = census[guildStatus] + amount
end

-- Returns the maintained census aggregate for a faction or the combined collection.
-- @param faction Optional faction key; nil selects the combined summary.
local function GetSummary(faction)
    local scope = faction or "all"
    if not summaries[scope] then
        summaries[scope] = { census = NewCensus(), races = {} }
    end
    return summaries[scope]
end

-- Updates a faction summary's total counts and nested race/class breakdown.
-- @param summary Summary accumulator to mutate.
-- @param player Player record contributing to the summary.
-- @param amount Signed contribution to add or remove.
local function UpdateSummary(summary, player, amount)
    CountPlayer(summary.census, player, amount)
    local race      = player.race or "Unknown"
    local snapshot  = summary.races[race] or { total = 0, byClass = {} }
    snapshot.total = snapshot.total + amount
    Increment(snapshot.byClass, player.class or "Unknown", amount)
    summary.races[race] = snapshot.total ~= 0 and snapshot or nil
end

-- Updates both the combined summary and the player's faction-specific summary.
-- @param player Player record whose counts changed.
-- @param amount Signed contribution to apply to each summary.
local function UpdateSummaries(player, amount)
    UpdateSummary(GetSummary(), player, amount)
    if player.faction == "Alliance" or player.faction == "Horde" then
        UpdateSummary(GetSummary(player.faction), player, amount)
    end
end

-- Returns a shallow copy of a player record limited to the stored player fields.
-- @param player Internal player record to copy.
function NS.CopyPlayer(player)
    local result = {}
    for fieldIndex, field in ipairs(playerFields) do
        result[field] = player[field]
    end
    return result
end

-- Saved rows list playerFields by position, with false for unknown values; older saves use named fields.
-- @param entry Saved positional or legacy named player row to validate and decode.
local function DecodePlayer(entry)
    if not NS.Accessible(entry) or not NS.Readable(entry.name) then
        return nil
    end
    local player  = {}
    local named   = entry.name ~= nil
    for fieldIndex, field in ipairs(playerFields) do
        local value = entry[named and field or fieldIndex]
        if field == "name" then
            player[field] = NS.NormalizeName(value)
        elseif field == "faction" then
            local faction = NS.Text(value)
            if faction == "Alliance" or faction == "Horde" then
                player[field] = faction
            end
        elseif field == "level" or field == "firstSeen" or field == "lastSeen" then
            local minimum  = field == "level" and 1 or 0
            local maximum  = field == "level" and 255 or 9007199254740000
            local number   = NS.Number(value, minimum, maximum, nil)
            if NS.Readable(value) and number == value then
                player[field] = number
            end
        else
            player[field] = NS.Text(value, field == "guild")
        end
    end
    if not player.name then
        return nil
    end
    return player
end

-- Rebuilds players from saved rows, keeping the newest per name; resets caches and returns it.
-- @param saved Saved player rows loaded from the account-wide database.
function Store:Load(saved)
    players          = {}
    cachedCensus     = nil
    cachedOrders     = {}
    recentOrders     = {}
    summaries        = {}
    playerKeys       = {}
    searchSnapshots  = setmetatable({}, { __mode = "k" })
    for entryKey, entry in pairs(type(saved) == "table" and saved or {}) do
        local player = DecodePlayer(entry)
        if player then
            local key       = player.name:lower()
            local existing  = players[key]
            if not existing or (player.lastSeen or 0) > (existing.lastSeen or 0) then
                players[key] = player
            end
        end
    end
    for playerKey, player in pairs(players) do
        playerKeys[#playerKeys + 1] = playerKey
        UpdateSummaries(player, 1)
    end
    return players
end

-- Writes players to NS.db.players as positional rows with false for unknown values.
function Store:Save()
    self:PruneExpired()
    local rows = {}
    for playerKey, player in pairs(players) do
        local row = {}
        for fieldIndex, field in ipairs(playerFields) do
            local value = player[field]
            if value == nil then
                value = false
            end
            row[fieldIndex] = value
        end
        rows[#rows + 1] = row
    end
    NS.db.players = rows
end

-- Queues one debounced DATA_UPDATED after 0.2 seconds, or sends it now without C_Timer.
local function NotifyChanged()
    if notificationPending then
        return
    end
    notificationPending = true
    -- Clears the pending flag and broadcasts DATA_UPDATED to internal listeners.
    local function Publish()
        notificationPending = false
        NS:Notify("DATA_UPDATED")
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(0.2, Publish)
    else
        Publish()
    end
end

-- Opens a batch level that defers change notifications until the outermost EndBatch.
function Store:BeginBatch()
    batchDepth = batchDepth + 1
end

-- Closes a batch level and sends one notification if the finished batch changed data.
function Store:EndBatch()
    batchDepth = math.max(0, batchDepth - 1)
    if batchDepth == 0 and batchChanged then
        batchChanged = false
        NotifyChanged()
    end
end

-- Journals a record for active searches before its live stored version is changed or removed.
-- @param key Lowercase player identity used by the search snapshot.
-- @param player Current record version to preserve.
local function PreserveSnapshots(key, player)
    local retained = false
    for request, snapshot in pairs(searchSnapshots) do
        retained = true
        if snapshot and not snapshot[key] then
            snapshot[key] = player
        end
    end
    return retained
end

-- Deletes retained players older than the configured cutoff and refreshes aggregates and caches.
function Store:PruneExpired()
    local days = NS.Number(NS.db.settings.retentionDays, 0, 365, 0)
    if days == 0 then
        return 0
    end
    local cutoff   = NS.Now() - days * 86400
    local removed  = 0
    for playerKey, player in pairs(players) do
        if player.lastSeen and player.lastSeen < cutoff then
            PreserveSnapshots(playerKey, player)
            UpdateSummaries(player, -1)
            players[playerKey]  = nil
            removed             = removed + 1
        end
    end
    if removed > 0 then
        playerKeys    = {}
        cachedOrders  = {}
        recentOrders  = {}
        cachedCensus  = nil
        for playerKey in pairs(players) do
            playerKeys[#playerKeys + 1] = playerKey
        end
        NS.db.revision = NS.db.revision + 1
        if NS.ready then
            NotifyChanged()
        end
    end
    return removed
end

-- Records an observed player, bumping revision on change; returns isNew and changed.
-- @param info Readable observation fields collected from Who or passive unit APIs.
function Store:Observe(info)
    if not NS.ready or not NS.Accessible(info) then
        return false, false
    end
    local name = NS.NormalizeName(info.name)
    if not name then
        return false, false
    end
    local key     = name:lower()
    local player  = players[key]
    local isNew   = type(player) ~= "table"
    local now     = NS.Now()
    local values  = {
        faction  = NS.context.faction,
        level    = NS.Readable(info.level)
                and type(info.level) == "number"
                and info.level >= 1
                and info.level <= 255
                and info.level == math.floor(info.level)
                and info.level
            or nil,
        class     = NS.ClassName(info.className, info.class),
        race      = NS.Text(info.race),
        guild     = NS.Text(info.guild, true),
        lastSeen  = now,
        zone      = NS.Text(info.zone),
    }
    if isNew then
        player = {
            name       = name,
            faction    = values.faction,
            level      = values.level,
            class      = values.class,
            race       = values.race,
            guild      = values.guild,
            firstSeen  = now,
            lastSeen   = now,
            zone       = values.zone,
        }
        players[key]                 = player
        playerKeys[#playerKeys + 1]  = key
    end
    local changed         = isNew
    local summaryChanged  = isNew
    for fieldIndex, field in ipairs(observedFields) do
        local value = values[field]
        if value ~= nil and player[field] ~= value then
            if not changed and PreserveSnapshots(key, player) then
                player        = NS.CopyPlayer(player)
                players[key]  = player
            end
            if summaryFields[field] and not summaryChanged then
                UpdateSummaries(player, -1)
                summaryChanged = true
            end
            player[field]  = value
            changed        = true
            CacheOrder(field, nil)
        end
    end
    if summaryChanged then
        UpdateSummaries(player, 1)
    end
    if changed then
        NS.db.revision  = NS.db.revision + 1
        cachedCensus    = nil
        if isNew then
            cachedOrders  = {}
            recentOrders  = {}
        end
        if batchDepth > 0 then
            batchChanged = true
        else
            NotifyChanged()
        end
    end
    return isNew, changed
end

-- Returns a validated filter copy with a lowercase name; raises caller errors on bad input.
-- @param filters Optional caller filter table to validate and copy.
local function ValidateFilters(filters)
    if filters == nil then
        return {}
    end
    if not NS.Accessible(filters) then
        error("filters must be a table", 3)
    end
    local result = {}
    for field, value in pairs(filters) do
        if not NS.Readable(field) or type(field) ~= "string" then
            error("filter names must be readable strings", 3)
        end
        if field == "minLevel" or field == "maxLevel" or field == "seenAfter" or field == "seenBefore" then
            local timestamp  = field == "seenAfter" or field == "seenBefore"
            local maximum    = timestamp and 9007199254740000 or 255
            local minimum    = timestamp and 0 or 1
            local number     = NS.Number(value, minimum, maximum, nil)
            if number == nil or number ~= value then
                error(field .. " must be a whole number in range", 3)
            end
            result[field] = number
        elseif
            field == "name"
            or field == "class"
            or field == "race"
            or field == "guild"
            or field == "zone"
            or field == "faction"
            or field == "guildStatus"
        then
            local text = NS.Text(value, true)
            if text == nil then
                error(field .. " must be a readable string", 3)
            end
            result[field] = text
        else
            error("Unknown filter: " .. tostring(field), 3)
        end
    end
    if result.minLevel and result.maxLevel and result.minLevel > result.maxLevel then
        error("minLevel must not exceed maxLevel", 3)
    end
    if result.seenAfter and result.seenBefore and result.seenAfter > result.seenBefore then
        error("seenAfter must not exceed seenBefore", 3)
    end
    if result.faction and result.faction ~= "Alliance" and result.faction ~= "Horde" then
        error("faction must be Alliance or Horde", 3)
    end
    if
        result.guildStatus
        and result.guildStatus ~= "guilded"
        and result.guildStatus ~= "unguilded"
        and result.guildStatus ~= "unknown"
    then
        error("guildStatus must be guilded, unguilded, or unknown", 3)
    end
    if result.name then
        result.name = result.name:lower()
    end
    return result
end

-- Returns whether a player record satisfies every validated filter.
-- @param player Stored player record being tested.
-- @param filters Normalized filters from ValidateFilters.
local function Matches(player, filters)
    if type(player) ~= "table" or type(player.name) ~= "string" then
        return false
    end
    if filters.name and not player.name:lower():find(filters.name, 1, true) then
        return false
    end
    for fieldIndex, field in ipairs(matchFields) do
        if filters[field] ~= nil and player[field] ~= filters[field] then
            return false
        end
    end
    if filters.minLevel and (not player.level or player.level < filters.minLevel) then
        return false
    end
    if filters.maxLevel and (not player.level or player.level > filters.maxLevel) then
        return false
    end
    if filters.seenAfter and (not player.lastSeen or player.lastSeen < filters.seenAfter) then
        return false
    end
    if filters.seenBefore and (not player.lastSeen or player.lastSeen > filters.seenBefore) then
        return false
    end
    if filters.guildStatus then
        local status = player.guild == nil and "unknown" or (player.guild == "" and "unguilded" or "guilded")
        if status ~= filters.guildStatus then
            return false
        end
    end
    return true
end

-- Returns a copy of the named player, or nil when the name is unreadable or unknown.
-- @param name Full character name to look up.
function Store:GetPlayer(name)
    local normalized = NS.NormalizeName(name)
    if not normalized then
        return nil
    end
    local player = players[normalized:lower()]
    return type(player) == "table" and NS.CopyPlayer(player) or nil
end

-- Validates query options; returns sort field, offset, limit, and descending flag.
-- @param options Optional sort and pagination settings supplied by the caller.
local function Options(options)
    if options ~= nil and not NS.Accessible(options) then
        error("options must be a table", 3)
    end
    options = options or {}
    for field in pairs(options) do
        if not NS.Readable(field) or type(field) ~= "string" then
            error("option names must be readable strings", 3)
        end
        if not optionFields[field] then
            error("Unknown option: " .. field, 3)
        end
    end
    local sort = options.sort
    if sort == nil then
        sort = "name"
    end
    if not NS.Readable(sort) or type(sort) ~= "string" or not sortFields[sort] then
        error("Unsupported sort field", 3)
    end
    local offset  = options.offset
    local limit   = options.limit
    if not NS.Readable(offset) or not NS.Readable(limit) then
        error("offset and limit must be readable numbers", 3)
    end
    if offset == nil then
        offset = 0
    end
    if limit == nil then
        limit = 100
    end
    if NS.Number(offset, 0, 9007199254740000, nil) ~= offset then
        error("offset must be a nonnegative whole number", 3)
    end
    if NS.Number(limit, 1, 500, nil) ~= limit then
        error("limit must be a whole number from 1 to 500", 3)
    end
    if not NS.Readable(options.descending) or (options.descending ~= nil and type(options.descending) ~= "boolean") then
        error("descending must be a boolean", 3)
    end
    return sort, offset, limit, options.descending == true
end

-- Builds the strict ascending comparator used to sort player records by one field.
-- @param sort Stored player field to compare, with names used for ties.
local function PlayerOrder(sort)
    -- Compares two player records by sort, using name as a stable tiebreaker.
    return function(leftPlayer, rightPlayer)
        local leftValue   = leftPlayer[sort]
        local rightValue  = rightPlayer[sort]
        if sort == "level" or sort == "firstSeen" or sort == "lastSeen" then
            leftValue   = type(leftValue) == "number" and leftValue or 0
            rightValue  = type(rightValue) == "number" and rightValue or 0
        else
            leftValue   = type(leftValue) == "string" and leftValue:lower() or ""
            rightValue  = type(rightValue) == "string" and rightValue:lower() or ""
        end
        if leftValue == rightValue then
            return leftPlayer.name < rightPlayer.name
        end
        return leftValue < rightValue
    end
end

-- Returns player keys sorted ascending by a field with name tiebreaks, cached per sort field.
-- @param sort Stored player field used to order identities.
local function OrderedPlayers(sort)
    if cachedOrders[sort] then
        CacheOrder(sort, cachedOrders[sort])
        return cachedOrders[sort]
    end
    local records = {}
    for playerKey, player in pairs(players) do
        if type(player) == "table" and type(player.name) == "string" then
            records[#records + 1] = playerKey
        end
    end
    local precedes = PlayerOrder(sort)
    -- Orders two keys by their current player records through the shared comparator.
    table.sort(records, function(leftKey, rightKey)
        return precedes(players[leftKey], players[rightKey])
    end)
    CacheOrder(sort, records)
    return records
end

-- Returns a page of copied matching players with total, hasMore, and revision.
-- @param filters Optional player filters for the page.
-- @param options Optional sort order and pagination controls.
function Store:FindPlayers(filters, options)
    filters = ValidateFilters(filters)
    local sort,
        offset,
        limit,
        descending = Options(options)
    local result = {
        players   = {},
        total     = 0,
        offset    = offset,
        limit     = limit,
        revision  = NS.db.revision,
        hasMore   = false,
    }
    local ordered = OrderedPlayers(sort)
    for recordIndex = 1, #ordered do
        local player = players[ordered[descending and (#ordered - recordIndex + 1) or recordIndex]]
        if Matches(player, filters) then
            result.total = result.total + 1
            if result.total > offset and #result.players < limit then
                result.players[#result.players + 1] = NS.CopyPlayer(player)
            end
        end
    end
    result.hasMore = result.total > offset + #result.players
    return result
end

-- Browser searches capture record versions in bounded steps and only copy visible results.
-- @param text Search text split into up to eight literal terms.
-- @param sort Player field used to order matching records.
-- @param descending Whether results are returned in reverse sort order.
-- @param filters Optional validated player filters applied before text matching.
function Store:CreateSearch(text, sort, descending, filters)
    text     = NS.Text(text, true) or ""
    filters  = ValidateFilters(filters)
    if #text > 256 then
        return nil, "Search is limited to 256 bytes."
    end
    local terms = {}
    for term in text:lower():gmatch("%S+") do
        if #terms >= 8 then
            return nil, "Search is limited to eight words."
        end
        terms[#terms + 1] = term
    end
    sort = sort or "name"
    if not sortFields[sort] then
        return nil, "Unsupported sort field."
    end
    local cachedOrder   = cachedOrders[sort]
    if cachedOrder then
        CacheOrder(sort, cachedOrder)
    end
    local sourceKeys    = cachedOrder or playerKeys
    local sourceCount   = #sourceKeys
    local matches       = {}
    local nextPosition  = 1
    local request       = {
        total      = 0,
        progress   = 0,
        limit      = cachedOrder and sourceCount or 0,
        revision   = NS.db.revision,
        complete   = false,
        truncated  = false,
    }
    local records             = {}
    local buffer              = {}
    local precedes            = PlayerOrder(sort)
    local collecting          = true
    local collectionPosition  = 1
    local cachePosition       = 1
    local cacheOrder          = {}
    local snapshot            = {}
    local runWidth            = 1
    local runStart            = 1
    local sourcePlayers       = players
    local ordered
    local leftPosition
    local rightPosition
    local middle
    local runEnd
    local destination
    searchSnapshots[request] = snapshot
    -- Prepares a stable sorted identity order incrementally within the caller's time budget.
    local function PrepareOrder()
        if collecting then
            if collectionPosition > sourceCount then
                collecting                = false
                request.limit             = #records
                searchSnapshots[request]  = false
                snapshot                  = nil
                if cachedOrder then
                    ordered = records
                    return true
                end
            else
                local playerKey = sourceKeys[collectionPosition]
                records[#records + 1]  = snapshot[playerKey] or sourcePlayers[playerKey]
                collectionPosition     = collectionPosition + 1
            end
        elseif runWidth >= #records then
            if request.revision == NS.db.revision and cachePosition <= #records then
                cacheOrder[cachePosition]  = records[cachePosition].name:lower()
                cachePosition              = cachePosition + 1
                return false
            end
            ordered  = records
            buffer   = nil
            if request.revision == NS.db.revision then
                CacheOrder(sort, cacheOrder)
            end
            return true
        elseif runStart > #records then
            records, buffer  = buffer, records
            runWidth         = runWidth * 2
            runStart         = 1
        elseif not leftPosition then
            middle         = math.min(runStart + runWidth - 1, #records)
            runEnd         = math.min(runStart + runWidth * 2 - 1, #records)
            leftPosition   = runStart
            rightPosition  = middle + 1
            destination    = runStart
        elseif destination > runEnd then
            runStart      = runStart + runWidth * 2
            leftPosition  = nil
        else
            if
                rightPosition <= runEnd
                and (leftPosition > middle or precedes(records[rightPosition], records[leftPosition]))
            then
                buffer[destination]  = records[rightPosition]
                rightPosition        = rightPosition + 1
            else
                buffer[destination]  = records[leftPosition]
                leftPosition         = leftPosition + 1
            end
            destination = destination + 1
        end
        return false
    end
    -- Returns whether a player passes the filters and every term, including formatted dates.
    -- @param player Snapshot record tested against the filters and search terms.
    local function MatchesTerms(player)
        if not Matches(player, filters) then
            return false
        end
        if #terms == 0 then
            return true
        end
        local values = {
            player.name,
            player.class or "Unknown",
            player.race or "Unknown",
            player.zone or "Unknown",
            player.guild == "" and "Unguilded" or player.guild or "Unknown",
            tostring(player.level or "Unknown"),
            tostring(player.firstSeen or "Unknown"),
            tostring(player.lastSeen or "Unknown"),
        }
        local document = table.concat(values, "\031"):lower()
        for termIndex, term in ipairs(terms) do
            if not document:find(term, 1, true) then
                if not term:match("^[%d%-%:]+$") then
                    return false
                end
                local dates = date
                        and (date("%Y-%m-%d %H:%M:%S", player.firstSeen or 0) .. " " .. date(
                            "%Y-%m-%d %H:%M:%S",
                            player.lastSeen or 0
                        ))
                    or ""
                if not dates:find(term, 1, true) then
                    return false
                end
            end
        end
        return true
    end
    -- Releases temporary sort, snapshot, and source references once search work is finished.
    local function ReleasePreparation()
        records        = nil
        buffer         = nil
        ordered        = nil
        sourceKeys     = nil
        sourcePlayers  = nil
        cachedOrder    = nil
        cacheOrder     = nil
        snapshot       = nil
    end
    -- Cancels this search and releases its retained records immediately.
    function request:Cancel()
        searchSnapshots[self] = nil
        ReleasePreparation()
        matches         = {}
        self.total      = 0
        self.complete   = true
        self.cancelled  = true
    end
    -- Scans up to 200 more players within about 1 ms; returns whether the search is complete.
    -- @param self Search request whose preparation and matching state advance.
    function request:Step()
        if self.complete then
            return true
        end
        local started          = debugprofilestop and debugprofilestop()
        local preparationWork  = 0
        while not ordered do
            if PrepareOrder() then
                break
            end
            preparationWork = preparationWork + 1
            if preparationWork >= 4000 or (started and debugprofilestop() - started >= 1) then
                return false
            end
        end
        local stop                = math.min(self.limit, nextPosition + 199)
        local resultLimitReached  = false
        while nextPosition <= stop do
            local position = descending and (self.limit - nextPosition + 1) or nextPosition
            if MatchesTerms(ordered[position]) then
                matches[#matches + 1] = ordered[position]
                if #matches >= MAX_SEARCH_RESULTS and nextPosition < self.limit then
                    self.truncated      = true
                    resultLimitReached  = true
                end
            end
            ordered[position]  = nil
            nextPosition       = nextPosition + 1
            if resultLimitReached then
                break
            end
            if started and debugprofilestop() - started >= 1 then
                break
            end
        end
        self.total     = #matches
        self.progress  = nextPosition - 1
        self.complete  = self.truncated or nextPosition > self.limit
        if self.complete then
            ReleasePreparation()
            if self.total == 0 then
                searchSnapshots[self] = nil
            end
        end
        return self.complete
    end
    -- Returns a copy of the match at a result index, or nil beyond the matches found so far.
    -- @param index One-based index within the matches collected so far.
    function request:GetPlayer(index)
        local player = matches[index]
        return player and NS.CopyPlayer(player) or nil
    end
    return request
end

-- Returns the number of stored players matching the filters.
-- @param filters Optional player fields used to restrict the count.
function Store:CountPlayers(filters)
    filters = ValidateFilters(filters)
    local firstFilter = next(filters)
    if not firstFilter or (firstFilter == "faction" and next(filters, firstFilter) == nil) then
        return GetSummary(filters.faction).census.total
    end
    local count = 0
    for playerKey, player in pairs(players) do
        if Matches(player, filters) then
            count = count + 1
        end
    end
    return count
end

-- Returns a copy of a census result, duplicating its one-level count tables.
-- @param census Census table whose nested count tables are copied.
local function CopyCensus(census)
    local result = {}
    for field, value in pairs(census) do
        if type(value) == "table" then
            result[field] = {}
            for key, item in pairs(value) do
                result[field][key] = item
            end
        else
            result[field] = value
        end
    end
    return result
end

-- Returns sorted known class names from the combined player collection.
function Store:GetClassNames()
    local names = {}
    for className in pairs(GetSummary().census.byClass) do
        if className ~= "Unknown" then
            names[#names + 1] = className
        end
    end
    table.sort(names)
    return names
end

-- Returns detached census and race/class summaries for a faction, or all factions when nil.
-- @param faction Optional faction key to scope the overview.
function Store:GetCensusOverview(faction)
    local summary  = GetSummary(faction)
    local census   = CopyCensus(summary.census)
    local races    = {}
    census.revision = NS.db.revision
    for race, snapshot in pairs(summary.races) do
        races[race] = CopyCensus(snapshot)
    end
    return census, races
end

-- Returns copied census totals and breakdowns for matches; caches the unfiltered result.
-- @param filters Optional player fields used to scope the census.
function Store:GetCensus(filters)
    filters = ValidateFilters(filters)
    local unfiltered = next(filters) == nil
    if unfiltered and cachedCensus then
        local result = CopyCensus(cachedCensus)
        result.revision = NS.db.revision
        return result
    end
    local census = NewCensus()
    census.revision = NS.db.revision
    for playerKey, player in pairs(players) do
        if Matches(player, filters) then
            CountPlayer(census, player, 1)
            if player.firstSeen then
                census.oldestSeen = math.min(census.oldestSeen or player.firstSeen, player.firstSeen)
            end
            if player.lastSeen then
                census.newestSeen = math.max(census.newestSeen or player.lastSeen, player.lastSeen)
            end
        end
    end
    if unfiltered then
        cachedCensus = census
    end
    return CopyCensus(census)
end
