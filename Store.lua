local ADDON,
    NS = ...

local Store = {}
NS.Store = Store

local cachedCensus         = {}
local cachedOrders         = {}
local notificationPending  = false
local batchDepth           = 0
local batchChanged         = false

local playerFields = {
    "name",
    "realm",
    "faction",
    "class",
    "className",
    "race",
    "level",
    "guild",
    "zone",
    "firstSeen",
    "lastSeen",
}
local sortFields = { name = true, level = true, lastSeen = true, guild = true, class = true, race = true, zone = true }

function NS.CopyPlayer(player)
    local result = {}
    for fieldIndex, field in ipairs(playerFields) do
        result[field] = player[field]
    end
    result.sources = {}
    for source, observed in pairs(player.sources or {}) do
        if type(source) == "string" and observed == true then
            result.sources[source] = true
        end
    end
    return result
end

function Store:Context(scope)
    local current = NS.context
    if not current then
        return nil
    end
    if scope ~= nil and not NS.Accessible(scope) then
        error("scope must be a table", 3)
    end
    local realm    = scope and scope.realm or current.realm
    local faction  = scope and scope.faction or current.faction
    realm    = NS.Text(realm)
    faction  = NS.Text(faction)
    if not realm or (faction ~= "Alliance" and faction ~= "Horde") then
        error("scope requires a realm and Alliance or Horde faction", 3)
    end
    return { realm = realm, faction = faction, key = #realm .. ":" .. realm .. ":" .. faction }
end

function Store:Scope(context, create)
    local scope = NS.db.scopes[context.key]
    if type(scope) ~= "table" and create then
        scope                      = { realm = context.realm, faction = context.faction, players = {}, revision = 0 }
        NS.db.scopes[context.key]  = scope
    end
    if type(scope) ~= "table" then
        return nil
    end
    if type(scope.players) ~= "table" then
        if not create then
            return nil
        end
        scope.players = {}
    end
    if create then
        scope.revision = NS.Number(scope.revision, 0, 9007199254740000, 0)
    end
    return scope
end

function Store:Initialize()
    self:Scope(NS.context, true)
end

local function NotifyChanged()
    if notificationPending then
        return
    end
    notificationPending = true
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

function Store:BeginBatch()
    batchDepth = batchDepth + 1
end

function Store:EndBatch()
    batchDepth = math.max(0, batchDepth - 1)
    if batchDepth == 0 and batchChanged then
        batchChanged = false
        NotifyChanged()
    end
end

local function ClassToken(value)
    local text = NS.Text(value)
    if not text then
        return nil
    end
    local classes = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
    for classIndex, token in ipairs(classes) do
        local male    = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]
        local female  = LOCALIZED_CLASS_NAMES_FEMALE and LOCALIZED_CLASS_NAMES_FEMALE[token]
        if text:upper() == token or text == male or text == female then
            return token
        end
    end
    return nil
end

function Store:Observe(info, source)
    if not NS.ready or not NS.Accessible(info) or (source ~= "who" and source ~= "passive") then
        return false, false
    end
    local name = NS.NormalizeName(info.name)
    if not name then
        return false, false
    end
    local scope   = self:Scope(NS.context, true)
    local key     = name:lower()
    local player  = scope.players[key]
    local isNew   = type(player) ~= "table"
    local now     = NS.Now()
    if isNew then
        player = { name = name, realm = NS.context.realm, faction = NS.context.faction, firstSeen = now, sources = {} }
        scope.players[key] = player
    end
    local changed  = isNew
    local values   = {
        class      = ClassToken(info.class) or ClassToken(info.className),
        className  = NS.Text(info.className),
        race       = NS.Text(info.race),
        zone       = NS.Text(info.zone),
        guild      = NS.Text(info.guild, true),
        level      = NS.Readable(info.level)
                and type(info.level) == "number"
                and info.level >= 1
                and info.level <= 255
                and info.level == math.floor(info.level)
                and info.level
            or nil,
        lastSeen = now,
    }
    for field, value in pairs(values) do
        if value ~= nil and player[field] ~= value then
            player[field]  = value
            changed        = true
        end
    end
    if type(player.sources) ~= "table" then
        player.sources = {}
    end
    if not player.sources[source] then
        player.sources[source]  = true
        changed                 = true
    end
    if changed then
        scope.revision                = scope.revision + 1
        NS.db.revision                = NS.db.revision + 1
        cachedCensus[NS.context.key]  = nil
        cachedOrders[NS.context.key]  = nil
        if batchDepth > 0 then
            batchChanged = true
        else
            NotifyChanged()
        end
    end
    return isNew, changed
end

local function ValidateFilters(filters)
    if filters == nil then
        return {}
    end
    if not NS.Accessible(filters) then
        error("filters must be a table", 3)
    end
    local result = {}
    for field, value in pairs(filters) do
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
            or field == "realm"
            or field == "faction"
            or field == "guildStatus"
            or field == "source"
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
    if
        result.guildStatus
        and result.guildStatus ~= "guilded"
        and result.guildStatus ~= "unguilded"
        and result.guildStatus ~= "unknown"
    then
        error("guildStatus must be guilded, unguilded, or unknown", 3)
    end
    if result.source and result.source ~= "who" and result.source ~= "passive" then
        error("source must be who or passive", 3)
    end
    if result.name then
        result.name = result.name:lower()
    end
    if result.class then
        result.class = result.class:upper()
    end
    return result
end

local function Matches(player, filters)
    if type(player) ~= "table" or type(player.name) ~= "string" then
        return false
    end
    if filters.name and not player.name:lower():find(filters.name, 1, true) then
        return false
    end
    for fieldIndex, field in ipairs({ "class", "race", "guild", "zone" }) do
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
    if filters.source and not (player.sources and player.sources[filters.source]) then
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

function Store:GetPlayer(name, scope)
    local context     = self:Context(scope)
    local normalized  = NS.NormalizeName(name)
    if not normalized then
        return nil
    end
    local saved   = self:Scope(context)
    local player  = saved and saved.players[normalized:lower()]
    return player and NS.CopyPlayer(player) or nil
end

local function Options(options)
    if options ~= nil and not NS.Accessible(options) then
        error("options must be a table", 3)
    end
    options = options or {}
    local sort = options.sort or "name"
    if not NS.Readable(sort) or not sortFields[sort] then
        error("Unsupported sort field", 3)
    end
    local offset  = options.offset or 0
    local limit   = options.limit or 100
    if NS.Number(offset, 0, 9007199254740000, nil) ~= offset then
        error("offset must be a nonnegative whole number", 3)
    end
    if NS.Number(limit, 1, 500, nil) ~= limit then
        error("limit must be a whole number from 1 to 500", 3)
    end
    if options.descending ~= nil and type(options.descending) ~= "boolean" then
        error("descending must be a boolean", 3)
    end
    return sort, offset, limit, options.descending == true
end

local function OrderedPlayers(scope, context, sort)
    cachedOrders[context.key] = cachedOrders[context.key] or {}
    local orders = cachedOrders[context.key]
    if orders[sort] then
        return orders[sort]
    end
    local records = {}
    for playerKey, player in pairs(scope and scope.players or {}) do
        if type(player) == "table" and type(player.name) == "string" then
            records[#records + 1] = player
        end
    end
    table.sort(records, function(leftPlayer, rightPlayer)
        local leftValue   = leftPlayer[sort]
        local rightValue  = rightPlayer[sort]
        if sort == "level" or sort == "lastSeen" then
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
    end)
    orders[sort] = records
    return records
end

function Store:FindPlayers(filters, options)
    filters = ValidateFilters(filters)
    local context  = self:Context(filters)
    local scope    = self:Scope(context)
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
    local ordered = OrderedPlayers(scope, context, sort)
    for recordIndex = 1, #ordered do
        local player = ordered[descending and (#ordered - recordIndex + 1) or recordIndex]
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

-- Browser searches retain matching positions and only copy visible records.
function Store:CreateSearch(text, sort, descending)
    text = NS.Text(text, true) or ""
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
    local context       = self:Context()
    local ordered       = OrderedPlayers(self:Scope(context), context, sort)
    local positions     = {}
    local nextPosition  = 1
    local request       = { total = 0, progress = 0, limit = #ordered, revision = NS.db.revision, complete = false }
    local function MatchesTerms(player)
        if #terms == 0 then
            return true
        end
        local values = {
            player.name,
            player.class or "Unknown",
            player.className or "Unknown",
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
    function request:Step()
        local stop     = math.min(#ordered, nextPosition + 199)
        local started  = debugprofilestop and debugprofilestop()
        while nextPosition <= stop do
            local position = descending and (#ordered - nextPosition + 1) or nextPosition
            if MatchesTerms(ordered[position]) then
                positions[#positions + 1] = position
            end
            nextPosition = nextPosition + 1
            if started and debugprofilestop() - started >= 1 then
                break
            end
        end
        self.total     = #positions
        self.progress  = nextPosition - 1
        self.complete  = nextPosition > #ordered
        return self.complete
    end
    function request:GetPlayer(index)
        local position = positions[index]
        return position and NS.CopyPlayer(ordered[position]) or nil
    end
    return request
end

function Store:CountPlayers(filters)
    filters = ValidateFilters(filters)
    local scope  = self:Scope(self:Context(filters))
    local count  = 0
    for playerKey, player in pairs(scope and scope.players or {}) do
        if Matches(player, filters) then
            count = count + 1
        end
    end
    return count
end

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

local function Increment(counts, key)
    counts[key] = (counts[key] or 0) + 1
end

function Store:GetCensus(filters)
    filters = ValidateFilters(filters)
    local context     = self:Context(filters)
    local scope       = self:Scope(context)
    local unfiltered  = true
    for field, value in pairs(filters) do
        if field ~= "realm" and field ~= "faction" then
            unfiltered = false
            break
        end
    end
    if unfiltered and cachedCensus[context.key] then
        local result = CopyCensus(cachedCensus[context.key])
        result.revision = NS.db.revision
        return result
    end
    local census = {
        total         = 0,
        byClass       = {},
        byRace        = {},
        byGuild       = {},
        byLevel       = {},
        guilded       = 0,
        unguilded     = 0,
        unknownGuild  = 0,
        revision      = NS.db.revision,
        context       = { realm = context.realm, faction = context.faction, key = context.key },
    }
    for playerKey, player in pairs(scope and scope.players or {}) do
        if Matches(player, filters) then
            census.total = census.total + 1
            Increment(census.byClass, player.class or "Unknown")
            Increment(census.byRace, player.race or "Unknown")
            if player.guild ~= nil then
                Increment(census.byGuild, player.guild)
            end
            Increment(census.byLevel, player.level or 0)
            if player.guild == nil then
                census.unknownGuild = census.unknownGuild + 1
            elseif player.guild == "" then
                census.unguilded = census.unguilded + 1
            else
                census.guilded = census.guilded + 1
            end
            if player.firstSeen then
                census.oldestSeen = math.min(census.oldestSeen or player.firstSeen, player.firstSeen)
            end
            if player.lastSeen then
                census.newestSeen = math.max(census.newestSeen or player.lastSeen, player.lastSeen)
            end
        end
    end
    if unfiltered then
        cachedCensus[context.key] = census
    end
    return CopyCensus(census)
end
