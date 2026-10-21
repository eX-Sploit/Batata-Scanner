"""Run the real addon Lua in Lua 5.1 with mocked WoW APIs; never contacts WoW."""

from pathlib import Path

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]  # Repository root for manifest and addon-module lookup.

# Shared fake WoW globals and event/timer helpers loaded before the real addon Lua.
BOOTSTRAP = r'''
NS = {}
frames, timers, errors, chat, whoCalls = {}, {}, {}, {}, {}
clock, epoch, hardwareEvent = 100, 2000000000, false
combatLockdown, playerCombat, instanceKind = false, false, "none"
SlashCmdList, UISpecialFrames = {}, {}
LOCALIZED_CLASS_NAMES_MALE = {MAGE="Mage", WARRIOR="Warrior", DRUID="Druid"}
LOCALIZED_CLASS_NAMES_FEMALE = {}
-- Implements mocked time behavior for addon tests.
function time() return epoch end
-- Returns the deterministic mock GetTime result.
function GetTime() return clock end
-- Returns the deterministic mock GetRealmName result.
function GetRealmName() return "Test Realm" end
-- Implements mocked UnitFactionGroup behavior for addon tests.
function UnitFactionGroup() return "Alliance" end
-- Implements mocked IsLoggedIn behavior for addon tests.
function IsLoggedIn() return true end
-- Implements mocked UnitExists behavior for addon tests.
function UnitExists() return false end
-- Implements mocked UnitIsPlayer behavior for addon tests.
function UnitIsPlayer() return false end
-- Implements mocked UnitGUID behavior for addon tests.
function UnitGUID() return nil end
-- Implements mocked UnitName behavior for addon tests.
function UnitName() return nil end
-- Implements mocked UnitNameUnmodified behavior for addon tests.
function UnitNameUnmodified() return nil end
-- Implements mocked UnitClass behavior for addon tests.
function UnitClass() return nil end
-- Implements mocked UnitRace behavior for addon tests.
function UnitRace() return nil end
-- Implements mocked UnitLevel behavior for addon tests.
function UnitLevel() return 0 end
-- Returns the deterministic mock GetGuildInfo result.
function GetGuildInfo() return nil end
-- Returns the deterministic mock GetRealZoneText result.
function GetRealZoneText() return "Test Zone" end
-- Returns the deterministic mock GetNumGroupMembers result.
function GetNumGroupMembers() return 0 end
-- Implements mocked IsInRaid behavior for addon tests.
function IsInRaid() return false end
-- Implements mocked InCombatLockdown behavior for addon tests.
function InCombatLockdown() return combatLockdown end
-- Implements mocked UnitAffectingCombat behavior for addon tests.
-- @param unit Unit token passed to the mocked client API.
function UnitAffectingCombat(unit) assert(unit=="player"); return playerCombat end
-- Implements mocked IsInInstance behavior for addon tests.
function IsInInstance() return instanceKind~="none",instanceKind end
-- Returns the deterministic mock GetWhoRaceFilters result.
function GetWhoRaceFilters() return { {name="Human", raceID=1}, {name="Dwarf",raceID=3} } end
C_AddOns = {GetAddOnMetadata=function(addon, field)
    assert(addon=="BatataScanner")
    return TOC_METADATA[field]
end}
DEFAULT_CHAT_FRAME = {AddMessage=function(self,message) chat[#chat+1]=message end}
-- Implements mocked geterrorhandler behavior for addon tests.
function geterrorhandler() return function(message) errors[#errors+1]=message end end
-- Implements mocked issecretvalue behavior for addon tests.
-- @param value Value read or written by the mocked API.
function issecretvalue(value) return type(value)=="table" and value.secret==true end
-- Implements mocked canaccessvalue behavior for addon tests.
-- @param value Value read or written by the mocked API.
function canaccessvalue(value) return not issecretvalue(value) end
-- Implements mocked canaccesstable behavior for addon tests.
-- @param value Value read or written by the mocked API.
function canaccesstable(value) return not value.inaccessible end
local frameMethods = {}
-- Implements mocked RegisterEvent behavior for addon tests.
-- @param event Client event name being dispatched.
function frameMethods:RegisterEvent(event) self.events[event]=true end
-- Implements mocked RegisterUnitEvent behavior for addon tests.
-- @param event Client event name being dispatched.
function frameMethods:RegisterUnitEvent(event) self.events[event]=true end
-- Implements mocked UnregisterEvent behavior for addon tests.
-- @param event Client event name being dispatched.
function frameMethods:UnregisterEvent(event) self.events[event]=nil end
-- Implements mocked UnregisterAllEvents behavior for addon tests.
function frameMethods:UnregisterAllEvents() self.events={} end
-- Implements mocked IsEventRegistered behavior for addon tests.
-- @param event Client event name being dispatched.
function frameMethods:IsEventRegistered(event) return self.events[event] or false end
-- Stores inputs passed to the mocked SetScript API.
-- @param event Client event name being dispatched.
-- @param callback Function invoked by the mocked event or timer.
function frameMethods:SetScript(event,callback) self.scripts[event]=callback end
-- Returns the deterministic mock GetScript result.
-- @param event Client event name being dispatched.
function frameMethods:GetScript(event) return self.scripts[event] end
-- Implements mocked HookScript behavior for addon tests.
-- @param event Client event name being dispatched.
-- @param callback Function invoked by the mocked event or timer.
function frameMethods:HookScript(event,callback)
    local previous=self.scripts[event]
    self.scripts[event]=function(...)
        if previous then previous(...) end
        callback(...)
    end
end
-- Implements mocked Show behavior for addon tests.
function frameMethods:Show()
    local changed=not self.shown
    self.shown=true
    if changed and self.scripts.OnShow then self.scripts.OnShow(self) end
end
-- Implements mocked Hide behavior for addon tests.
function frameMethods:Hide()
    local changed=self.shown
    self.shown=false
    if changed and self.scripts.OnHide then self.scripts.OnHide(self) end
end
-- Implements mocked IsShown behavior for addon tests.
function frameMethods:IsShown() return self.shown end
-- Implements mocked IsVisible behavior for addon tests.
function frameMethods:IsVisible() return self.shown end
-- Stores inputs passed to the mocked SetShown API.
-- @param shown Argument named shown passed by the tested addon code.
function frameMethods:SetShown(shown) if shown then self:Show() else self:Hide() end end
-- Implements mocked CreateFrame behavior for addon tests.
-- @param kind Argument named kind passed by the tested addon code.
-- @param name Argument named name passed by the tested addon code.
-- @param parent Argument named parent passed by the tested addon code.
-- @param template Argument named template passed by the tested addon code.
function CreateFrame(kind,name,parent,template)
    local frame=setmetatable({events={},scripts={},shown=true,name=name}, {__index=frameMethods})
    frames[#frames+1]=frame
    if name then _G[name]=frame end
    return frame
end
UIParent=CreateFrame("Frame","UIParent")
WorldFrame=CreateFrame("Frame","WorldFrame")
WhoFrame=CreateFrame("Frame","WhoFrame"); WhoFrame:Hide()
LFGWhoListFrame=CreateFrame("Frame","LFGWhoListFrame"); LFGWhoListFrame:Hide()
LFGWhoListFrame:RegisterEvent("WHO_LIST_UPDATE")
whoRows, whoTotal, whoRouting = {}, 0, false
C_FriendList={
    GetWhoRaceFilters=GetWhoRaceFilters,
    SendWho=function(query)
        assert(hardwareEvent,"SendWho must stay in an input callback")
        whoCalls[#whoCalls+1]=query
    end,
    GetNumWhoResults=function() return #whoRows,whoTotal end,
    GetWhoInfo=function(index) return whoRows[index] end,
    SetWhoToUi=function(enabled) whoRouting=enabled end,
}
C_CreatureInfo={GetClassInfo=function(classID)
    if classID==1 then return {classID=1,className="Warrior",classFile="WARRIOR"}
    elseif classID==8 then return {classID=8,className="Mage",classFile="MAGE"} end
end}
C_SpecializationInfo={GetAllClassIDs=function() return {1,8} end}
-- Returns the deterministic mock GetClassInfo result.
-- @param classID Numeric class identifier passed to the client API.
function GetClassInfo(classID)
    local info=C_CreatureInfo.GetClassInfo(classID)
    return info and info.className,info and info.classFile
end
Enum={SocialWhoOrigin={Social=1}}
-- Implements mocked hooksecurefunc behavior for addon tests.
-- @param target Argument named target passed by the tested addon code.
-- @param key Argument named key passed by the tested addon code.
-- @param callback Function invoked by the mocked event or timer.
function hooksecurefunc(target,key,callback)
    if type(target)=="string" then callback=key;key=target;target=_G end
    local original=target[key]
    target[key]=function(...)
        local result=original(...)
        callback(...)
        return result
    end
end
C_Timer={}
-- Implements mocked After behavior for addon tests.
-- @param delay Mock seconds before the scheduled callback runs.
-- @param callback Function invoked by the mocked event or timer.
function C_Timer.After(delay,callback)
    timers[#timers+1]={at=clock+delay,callback=callback}
end
-- Implements mocked NewTicker behavior for addon tests.
-- @param delay Mock seconds before the scheduled callback runs.
-- @param callback Function invoked by the mocked event or timer.
function C_Timer.NewTicker(delay,callback)
    local timer={at=clock+delay,delay=delay,callback=callback,cancelled=false}
    -- Implements mocked Cancel behavior for addon tests.
    function timer:Cancel() self.cancelled=true end
    timers[#timers+1]=timer
    return timer
end
-- Implements mocked Emit behavior for addon tests.
-- @param event Client event name being dispatched.
function Emit(event,...)
    for frameIndex,frame in ipairs(frames) do
        if frame.events[event] and frame.scripts.OnEvent then frame.scripts.OnEvent(frame,event,...) end
    end
end
-- Implements mocked Advance behavior for addon tests.
-- @param seconds Number of mock seconds advanced.
function Advance(seconds)
    local stop=clock+seconds
    for iteration=1,10000 do
        local dueIndex,soonest=nil,stop+1
        for timerIndex,timer in ipairs(timers) do
            if not timer.cancelled and timer.at<=stop and timer.at<soonest then
                dueIndex,soonest=timerIndex,timer.at
            end
        end
        if not dueIndex then break end
        local timer=timers[dueIndex]
        clock=timer.at
        if timer.delay then timer.at=timer.at+timer.delay else table.remove(timers,dueIndex) end
        timer.callback(timer)
        assert(iteration<10000,"timer loop did not settle")
    end
    epoch=epoch+seconds
    clock=stop
end
-- Implements mocked Click behavior for addon tests.
-- @param callback Function invoked by the mocked event or timer.
function Click(callback)
    hardwareEvent=true
    local success,failure=pcall(callback)
    hardwareEvent=false
    assert(success,failure)
end
-- Implements mocked Deliver behavior for addon tests.
-- @param rows Mock Who rows returned by the client.
-- @param total Optional server-reported Who result total.
function Deliver(rows,total)
    whoRows=rows
    whoTotal=total or #rows
    Emit("WHO_LIST_UPDATE")
end
'''


class Harness:
    """Runs the addon Lua modules in a mocked WoW environment."""
    def __init__(self, initialize=True, modules=None, setup=""):
        """Loads selected addon modules into Lua 5.1 with mocked WoW APIs.

        Args:
            initialize: Whether to emit addon-loaded and player-login events.
            modules: Optional manifest filenames to load instead of the core set.
            setup: Optional Lua source executed before addon modules load.
        """
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        manifest = (ROOT / "BatataScanner.toc").read_text(encoding="utf-8")
        metadata = dict(line[3:].split(":", 1) for line in manifest.splitlines()
                        if line.startswith("## ") and ":" in line)
        metadata = {field.strip(): value.strip() for field, value in metadata.items()}
        # Tests name modules by file name; the manifest supplies each file's folder.
        module_paths = {}
        for line in manifest.splitlines():
            entry = line.strip().replace("\\", "/")
            if entry and not entry.startswith("#"):
                module_paths[Path(entry).name] = ROOT / entry
        self.lua.globals().TOC_METADATA = self.lua.table_from(metadata)
        self.lua.globals().TOC_VERSION = metadata["Version"]
        self.lua.execute(BOOTSTRAP)
        if setup:
            self.lua.execute(setup)
        modules = modules or ("Core.lua", "Store.lua", "Scanner.lua", "Passive.lua", "API.lua")
        for filename in modules:
            path = module_paths[filename]
            self.lua.execute('assert(loadstring(...))("BatataScanner",NS)',
                             path.read_text(encoding="utf-8-sig"))
        if initialize:
            self.emit("ADDON_LOADED", "BatataScanner")
            self.emit("PLAYER_LOGIN")

    def execute(self, code):
        """Executes Lua source in the harness runtime and returns its result.

        Args:
            code: Lua source string to execute.
        """
        return self.lua.execute(code)

    def emit(self, event, *args):
        """Dispatches a mocked client event with its supplied payload.

        Args:
            event: Client event name to dispatch.
            *args: Event payload values passed to registered mock frames.
        """
        return self.lua.globals().Emit(event, *args)

    def advance(self, seconds):
        """Advances the mocked client clock and runs due timers.

        Args:
            seconds: Number of mock seconds to advance.
        """
        return self.lua.globals().Advance(seconds)

    def click(self, code):
        """Runs Lua source inside a mocked hardware-input callback.

        Args:
            code: Lua statements executed during the simulated click.
        """
        self.execute("Click(function() " + code + " end)")
