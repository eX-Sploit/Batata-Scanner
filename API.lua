local ADDON,
    NS = ...

local methods      = {}
local validEvents  = { READY = true, DATA_UPDATED = true, SCAN_STATUS_CHANGED = true }

local function RequireReady()
    if not NS.ready then
        error("BatataScanner is not ready; check IsReady() or subscribe to READY", 3)
    end
end

function methods.IsReady()
    return NS.ready
end

function methods.GetVersion()
    return NS.version
end

function methods.GetAPIVersion()
    return 1
end

function methods.GetContext()
    if not NS.context then
        return nil
    end
    return { realm = NS.context.realm, faction = NS.context.faction, key = NS.context.key }
end

function methods.GetPlayer(name, scope)
    RequireReady()
    return NS.Store:GetPlayer(name, scope)
end

function methods.FindPlayers(filters, options)
    RequireReady()
    return NS.Store:FindPlayers(filters, options)
end

function methods.CountPlayers(filters)
    RequireReady()
    return NS.Store:CountPlayers(filters)
end

function methods.GetCensus(filters)
    RequireReady()
    return NS.Store:GetCensus(filters)
end

function methods.GetScanStatus()
    if not NS.ready then
        return { state = "initializing", running = false, awaiting = false, incomplete = false }
    end
    return NS.Scanner:GetStatus()
end

function methods.RegisterCallback(event, callback)
    if not NS.Readable(event) or not validEvents[event] then
        error("Unsupported BatataScanner event", 2)
    end
    if type(callback) ~= "function" then
        error("callback must be a function", 2)
    end
    return NS.On(event, callback)
end

function methods.UnregisterCallback(token)
    return NS.Off(token)
end

-- Only detached projections leave this facade. Runtime modules and the database stay private to the addon namespace.
BatataScanner = setmetatable({}, {
    __index     = methods,
    __newindex  = function()
        error("BatataScanner API is read-only", 2)
    end,
    __metatable = "BatataScanner read-only API",
})
