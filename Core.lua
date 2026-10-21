local ADDON,
    NS = ...

NS.name     = ADDON
NS.ready    = false
NS.version  = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")
    or (GetAddOnMetadata and GetAddOnMetadata(ADDON, "Version"))

local listeners   = {}
local nextToken   = 0
local savedReady  = false

function NS.Readable(value)
    return not (issecretvalue and issecretvalue(value)) and not (canaccessvalue and not canaccessvalue(value))
end

function NS.Accessible(value)
    return NS.Readable(value) and type(value) == "table" and not (canaccesstable and not canaccesstable(value))
end

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

function NS.NormalizeName(value)
    local text = NS.Text(value)
    return text and text:gsub("%s+", " ")
end

function NS.Number(value, minimum, maximum, fallback)
    if not NS.Readable(value) or type(value) ~= "number" or value ~= value then
        return fallback
    end
    if value == math.huge or value == -math.huge then
        return fallback
    end
    return math.max(minimum, math.min(maximum, math.floor(value)))
end

function NS.Now()
    return time()
end

function NS:Print(message)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffcc66BatataScanner|r: " .. tostring(message))
    end
end

function NS.On(event, callback)
    if type(event) ~= "string" or type(callback) ~= "function" then
        return nil
    end
    nextToken             = nextToken + 1
    listeners[nextToken]  = { event = event, callback = callback }
    return nextToken
end

function NS.Off(token)
    if type(token) ~= "number" then
        return false
    end
    local existed = listeners[token] ~= nil
    listeners[token] = nil
    return existed
end

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

local function InitializeSavedState()
    if savedReady then
        return
    end
    local database = BatataScanner_DB
    if type(database) == "table" and type(database.schemaVersion) == "number" and database.schemaVersion > 1 then
        NS:Print("This database needs a newer BatataScanner. Existing data has been preserved.")
        return
    end
    if type(database) ~= "table" then
        database = {}
    end
    database.schemaVersion  = 1
    database.scopes         = type(database.scopes) == "table" and database.scopes or {}
    database.settings       = type(database.settings) == "table" and database.settings or {}
    database.window         = type(database.window) == "table" and database.window or {}
    database.revision       = NS.Number(database.revision, 0, 9007199254740000, 0)
    local settings = database.settings
    settings.passiveEnabled     = settings.passiveEnabled ~= false
    settings.worldClickEnabled  = settings.worldClickEnabled == true
    settings.minLevel           = NS.Number(settings.minLevel, 1, 60, 1)
    settings.maxLevel           = NS.Number(settings.maxLevel, settings.minLevel, 60, 60)
    settings.queryInterval      = NS.Number(settings.queryInterval, 5, 60, 5)
    settings.queryTimeout       = NS.Number(settings.queryTimeout, 6, 120, 10)
    BatataScanner_DB            = database
    NS.db                       = database
    savedReady                  = true
end

local function StartReady()
    if NS.ready or not savedReady then
        return
    end
    local realm    = NS.Text(GetRealmName and GetRealmName())
    local faction  = NS.Text(UnitFactionGroup and UnitFactionGroup("player"))
    if not realm or (faction ~= "Alliance" and faction ~= "Horde") then
        return
    end
    NS.context = { realm = realm, faction = faction, key = #realm .. ":" .. realm .. ":" .. faction }
    NS.Store:Initialize()
    NS.ready = true
    if NS.db.settings.passiveEnabled and NS.Passive then
        NS.Passive:Start()
    end
    NS:Notify("READY")
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
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
            NS.Scanner:Stop()
        end
        if NS.Passive then
            NS.Passive:Stop()
        end
    end
end)

SLASH_BATATASCANNER1        = "/batatascanner"
SLASH_BATATASCANNER2        = "/bs"
SlashCmdList.BATATASCANNER  = function(message)
    local command = (message or ""):match("^%s*(%S*)"):lower()
    if not NS.ready then
        NS:Print("Waiting for saved data and character information.")
    elseif command == "scan" then
        NS.Scanner:Start({ minLevel = NS.db.settings.minLevel, maxLevel = NS.db.settings.maxLevel })
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
                .. tostring(BatataScanner.CountPlayers())
        )
    elseif command == "" then
        NS.UI:Toggle()
    else
        NS:Print("/bs: open | /bs scan | /bs next | /bs pause | /bs stop | /bs status")
    end
end
