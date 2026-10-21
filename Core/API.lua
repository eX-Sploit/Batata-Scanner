-- Batata Scanner: read-only public API exposed through the Batata_Scanner global.
-- Addon folder name and the shared private namespace supplied by the client.
local ADDON,
    NS = ...

local methods      = {} -- Public API methods; the read-only facade forwards lookups here.
local validEvents  = { READY = true, DATA_UPDATED = true, SCAN_STATUS_CHANGED = true } -- Event names accepted by RegisterCallback.

-- Raises a caller-facing error when saved data or character context is not ready yet.
local function RequireReady()
    if not NS.ready then
        error("Batata Scanner is not ready; check IsReady() or subscribe to READY", 3)
    end
end

-- Returns whether saved data and character context are initialized.
function methods.IsReady()
    return NS.ready
end

-- Returns the addon release version from the TOC.
function methods.GetVersion()
    return NS.version
end

-- Returns the consumer API version from the TOC.
function methods.GetAPIVersion()
    return NS.apiVersion
end

-- Returns a copy of the current character's faction context, or nil before it is known.
function methods.GetContext()
    if not NS.context then
        return nil
    end
    return { faction = NS.context.faction, key = NS.context.key }
end

-- Returns a stored player copy; name is the full character name and matching is case-insensitive.
function methods.GetPlayer(name)
    RequireReady()
    return NS.Store:GetPlayer(name)
end

-- Returns filtered, sorted player copies; filters select records and options control sorting and pagination.
function methods.FindPlayers(filters, options)
    RequireReady()
    return NS.Store:FindPlayers(filters, options)
end

-- Counts matching stored players; filters optionally restrict the count by player fields.
function methods.CountPlayers(filters)
    RequireReady()
    return NS.Store:CountPlayers(filters)
end

-- Returns a census summary; filters optionally restrict which stored players are counted.
function methods.GetCensus(filters)
    RequireReady()
    return NS.Store:GetCensus(filters)
end

-- Returns a copy of the scanner status, or a placeholder before readiness.
function methods.GetScanStatus()
    if not NS.ready then
        return { state = "initializing", running = false, awaiting = false, incomplete = false }
    end
    return NS.Scanner:GetStatus()
end

-- Subscribes to event (READY, DATA_UPDATED, or SCAN_STATUS_CHANGED) with a callback receiving event name and revision.
function methods.RegisterCallback(event, callback)
    if not NS.Readable(event) or not validEvents[event] then
        error("Unsupported Batata Scanner event", 2)
    end
    if type(callback) ~= "function" then
        error("callback must be a function", 2)
    end
    return NS.On(event, callback)
end

-- Removes a subscription and reports success; token is returned by RegisterCallback.
function methods.UnregisterCallback(token)
    return NS.Off(token)
end

-- Global read-only consumer facade; only detached projections leave it, while runtime modules and saved data stay private.
Batata_Scanner = setmetatable({}, {
    __index     = methods,
    -- Rejects consumer attempts to add or replace methods on the public facade.
    __newindex  = function()
        error("Batata Scanner API is read-only", 2)
    end,
    __metatable = "Batata Scanner read-only API",
})
