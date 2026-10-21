"""Exercise the real scanner using mocked Who responses and hardware callbacks."""

import unittest

from harness import Harness


# Shared class/race filters and saved settings used by scanner state-machine tests.
SCANNER_SETUP = '''
BatataScanner_DB={schemaVersion=1,settings={queryInterval=5}}
C_FriendList.GetWhoRaceFilters=function()
    return {{name="Human",ID=1},{name="Dwarf",ID=3}}
end
-- Returns the deterministic mock GetClassInfo result.
-- @param classID Numeric class identifier passed to the client API.
function GetClassInfo(classID)
    if classID==1 then return "Warrior","WARRIOR"
    elseif classID==8 then return "Mage","MAGE" end
end
Enum.SocialWhoOrigin={Social=1}
'''

# Most tests begin a sweep explicitly, so they start from a stopped scanner.
STOPPED_SETUP = SCANNER_SETUP + 'BatataScanner_DB={schemaVersion=1,settings={scanBehavior="ordered",queryInterval=5},scanner={state="stopped"}}\n'

# Expected WoW Forever race/class matrix used by query-planning regressions.
FOREVER_RACES = {
    "Alliance": {
        "Human": "Warrior Hunter Mage Rogue Priest Warlock Paladin".split(),
        "Dwarf": "Warrior Hunter Rogue Priest Paladin Shaman".split(),
        "Night Elf": "Warrior Hunter Rogue Priest Druid".split(),
        "Gnome": "Warrior Mage Rogue Priest Warlock".split(),
        "High Order Skyborne": "Warrior Hunter Mage Rogue Druid".split(),
    },
    "Horde": {
        "Orc": "Warrior Hunter Mage Rogue Warlock Shaman".split(),
        "Undead": "Warrior Mage Rogue Priest Warlock Paladin".split(),
        "Tauren": "Warrior Hunter Druid Shaman".split(),
        "Troll": "Warrior Hunter Mage Rogue Priest Warlock Shaman".split(),
        "Windshaper Skyborne": "Warrior Hunter Rogue Druid Shaman".split(),
    },
}

# Lua serializer used to model SavedVariables across a harness reload.
SERIALIZE = r'''
-- Implements mocked Serialize behavior for addon tests.
-- @param value Value read or written by the mocked API.
function Serialize(value)
    if type(value)=="table" then
        local parts={}
        for key,item in pairs(value) do parts[#parts+1]="["..Serialize(key).."]="..Serialize(item) end
        return "{"..table.concat(parts,",").."}"
    elseif type(value)=="string" then
        return string.format("%q",value)
    end
    return tostring(value)
end
'''


class ScannerTests(unittest.TestCase):
    """Checks Who scan state, dispatch, persistence, and replies."""
    def setUp(self):
        """Creates a fresh test fixture before each test."""
        self.harness = Harness(setup=STOPPED_SETUP)

    def check(self, expression):
        """Runs a Lua assertion or statement in the current test fixture."""
        self.assertTrue(self.harness.execute("return " + expression), expression)

    def reload(self):
        """Serializes saved state and starts a fresh harness at the same client clock."""
        database, clock = self.harness.execute(
            SERIALIZE + "Emit('PLAYER_LOGOUT'); return Serialize(BatataScanner_DB), clock")
        self.harness = Harness(setup=SCANNER_SETUP + f"BatataScanner_DB={database}\nclock={clock!r}\n")

    def test_default_state_is_playing_without_dispatching(self):
        """Verifies that default state is playing without dispatching."""
        self.harness = Harness(setup=SCANNER_SETUP + 'BatataScanner_DB=nil')
        self.check("NS.db.settings.queryInterval==15")
        self.check("NS.db.settings.scanBehavior=='random'")
        self.check("NS.Scanner:GetStatus().running and not NS.Scanner:GetStatus().paused")
        self.check("NS.Scanner:GetStatus().state=='ready' and NS.Scanner:GetStatus().remainingQueries==6")
        self.harness.advance(30)
        self.check("#whoCalls==0")
        first_query = self.harness.execute("return NS.Scanner:GetStatus().currentQuery")
        self.harness.click("assert(NS.Scanner:Continue())")
        self.check(f"#whoCalls==1 and whoCalls[1]=='{first_query}'")

    def test_reload_keeps_a_running_sweep_running(self):
        """Verifies that reload keeps a running sweep running."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=30}))")
        self.harness.execute("Deliver({{fullName='Alice',level=5}})")
        self.reload()
        self.check("NS.Scanner:GetStatus().running and not NS.Scanner:GetStatus().paused")
        self.check("NS.Scanner:GetStatus().remainingQueries==2 and NS.Scanner:GetStatus().completedQueries==1")
        self.check("NS.Scanner:GetStatus().newPlayers==1 and #whoCalls==0")
        self.harness.click("assert(not NS.Scanner:Continue())")
        self.harness.advance(6)
        self.harness.click("assert(NS.Scanner:Continue())")
        self.harness.execute("Deliver({{fullName='ALICE',level=15}})")
        self.check("whoCalls[1]=='11-20' and NS.Scanner:GetStatus().newPlayers==1")

    def test_faction_change_replans_without_dispatch_and_preserves_manual_pause(self):
        """Verifies that faction change replans without dispatch and preserves manual pause."""
        for paused in (False, True):
            with self.subTest(paused=paused):
                self.harness = Harness(setup=STOPPED_SETUP)
                self.harness.execute('''
                    NS.db.settings.overrideDefaults=true
                    NS.db.settings.maxLevel=20
                ''')
                self.harness.click("assert(NS.Scanner:Start())")
                self.harness.execute("Deliver({{fullName='Alliance Player',level=5}})")
                if paused:
                    self.harness.execute("NS.Scanner:Pause()")
                database, clock = self.harness.execute(
                    SERIALIZE + "Emit('PLAYER_LOGOUT'); return Serialize(BatataScanner_DB), clock")
                self.harness = Harness(setup=SCANNER_SETUP +
                    f'BatataScanner_DB={database}\nclock={clock!r}\n' +
                    'function UnitFactionGroup() return "Horde" end')
                self.check("NS.Scanner:GetStatus().completedQueries==0")
                self.check("NS.Scanner:GetStatus().remainingQueries==2")
                self.check("NS.Scanner:GetStatus().newPlayers==0")
                self.check("NS.Scanner:GetStatus().currentQuery=='1-10' and #whoCalls==0")
                self.check(f"NS.Scanner:GetStatus().paused=={str(paused).lower()}")
                self.check("NS.Scanner:GetStatus().cooldown==6")
                self.harness.advance(6)
                self.harness.click("assert(NS.Scanner:Continue())")
                self.harness.execute("Deliver({{fullName='Horde Low',level=5}})")
                self.harness.advance(6)
                self.harness.click("assert(NS.Scanner:Continue())")
                self.harness.execute("Deliver({{fullName='Horde High',level=15}})")
                self.check("whoCalls[1]=='1-10' and whoCalls[2]=='11-20'")
                self.check("NS.Scanner:GetStatus().state=='complete' and not NS.Scanner:GetStatus().incomplete")
                self.check("NS.Scanner:GetStatus().newPlayers==2")

    def test_legacy_queue_without_faction_cannot_claim_complete_coverage(self):
        """Verifies that legacy queue without faction cannot claim complete coverage."""
        self.harness = Harness(setup=SCANNER_SETUP + '''
            BatataScanner_DB={schemaVersion=1,scanner={state="ready",running=true,
                queue={{minLevel=11,maxLevel=20}},completedQueries=1,plannedQueries=2}}
        ''')
        self.harness.click("assert(NS.Scanner:Continue())")
        self.harness.execute("Deliver({})")
        self.check("NS.Scanner:GetStatus().state=='complete' and NS.Scanner:GetStatus().incomplete")

    def test_saved_scanner_state_keeps_only_resume_fields(self):
        """Verifies that saved scanner state keeps only resume fields."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=30}))")
        self.harness.execute("Deliver({{fullName='Alice',level=5}},1); Emit('PLAYER_LOGOUT')")
        self.check("BatataScanner_DB.scanner.seen==nil and BatataScanner_DB.scanner.observed==nil")
        self.check("BatataScanner_DB.scanner.faction=='Alliance'")
        self.check("BatataScanner_DB.scanner.returned==nil and BatataScanner_DB.scanner.total==nil")
        self.check("BatataScanner_DB.scanner.reason==nil and BatataScanner_DB.scanner.newPlayers==1")
        self.check("#BatataScanner_DB.scanner.queue==2 and BatataScanner_DB.scanner.running")

    def test_incomplete_reason_is_saved_and_restored(self):
        """Verifies that incomplete reason is saved and restored."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=30}))")
        self.harness.execute("Deliver({}); NS.Scanner:Stop()")
        reason = self.harness.execute("return NS.Scanner:GetStatus().reason")
        self.reload()
        self.check("NS.Scanner:GetStatus().incomplete and NS.Scanner:GetStatus().state=='stopped'")
        self.assertEqual(self.harness.execute("return NS.Scanner:GetStatus().reason"), reason)

    def test_incomplete_warning_survives_pause_retry_completion_and_reload(self):
        """Verifies that incomplete warning survives pause retry completion and reload."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=1}))")
        self.harness.advance(10)
        self.harness.execute("NS.Scanner:Pause()")
        self.check("NS.Scanner:GetStatus().reason:find('timed out',1,true)~=nil")
        self.reload()
        self.check("NS.Scanner:GetStatus().paused and NS.Scanner:GetStatus().incomplete")
        self.check("NS.Scanner:GetStatus().reason:find('timed out',1,true)~=nil")
        self.harness.advance(10)
        self.harness.click("assert(NS.Scanner:Continue())")
        self.check("NS.Scanner:GetStatus().reason:find('Waiting for a Who response.',1,true)~=nil")
        self.harness.execute("Deliver({})")
        for reload_index in range(2):
            self.check("NS.Scanner:GetStatus().state=='complete' and NS.Scanner:GetStatus().incomplete")
            self.check("NS.Scanner:GetStatus().reason:find('Sweep finished',1,true)~=nil")
            self.check("NS.Scanner:GetStatus().reason:find('timed out',1,true)~=nil")
            self.check("not NS.Scanner:GetStatus().reason:find('Sweep paused.',1,true)")
            self.reload()

    def test_restart_drops_the_queue_and_quarantines_an_outstanding_reply(self):
        """Verifies that restart drops the queue and quarantines an outstanding reply."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=30}))")
        self.harness.execute("NS.db.settings.overrideDefaults=true; NS.db.settings.minLevel=51")
        self.harness.click("assert(not NS.Scanner:Restart())")
        self.check("NS.Scanner:GetStatus().running and NS.Scanner:GetStatus().remainingQueries==1")
        self.check("NS.Scanner:GetStatus().pendingLateResponse and NS.Scanner:GetStatus().currentQuery=='51-60'")
        self.harness.execute("Deliver({{fullName='Late',level=5}})")
        self.check("BatataScanner.CountPlayers()==0 and NS.Scanner:GetStatus().pendingLateResponse")
        self.harness.advance(10)
        self.harness.click("assert(NS.Scanner:Continue())")
        self.check("#whoCalls==2 and whoCalls[2]=='51-60'")

    def test_override_defaults_controls_level_range_and_classes(self):
        """Verifies that override defaults controls level range and classes."""
        self.harness.execute("NS.db.settings.minLevel=41; NS.db.settings.maxLevel=50")
        self.harness.execute("NS.db.settings.scanClasses={'Mage','Warrior'}")
        self.harness.click("assert(NS.Scanner:Start())")
        self.check("whoCalls[1]=='1-10' and NS.Scanner:GetStatus().plannedQueries==6")
        self.harness.execute("Deliver({}); NS.Scanner:Stop(); NS.db.settings.overrideDefaults=true")
        self.harness.advance(6)
        self.harness.click("assert(NS.Scanner:Start())")
        self.check("whoCalls[2]=='c-\"Mage\" 41-50' and NS.Scanner:GetStatus().plannedQueries==2")
        self.harness.execute("Deliver({}); NS.Scanner:Stop(); NS.db.settings.scanClasses={}")
        self.harness.advance(6)
        self.check("select(2,NS.Scanner:Start())=='Choose at least one class to scan.' and #whoCalls==2")
        self.check("table.concat(NS.Scanner:ClassChoices(),',')=="
               "'Druid,Hunter,Mage,Paladin,Priest,Rogue,Shaman,Warlock,Warrior'")

    def test_saved_scan_behavior_is_validated_before_planning(self):
        """Verifies that saved scan behavior is validated before planning."""
        for saved_value in ("nil", "'sideways'", "false", "{}", "'ordered'", "'reversed'", "'random'"):
            with self.subTest(saved_value=saved_value):
                self.harness = Harness(setup=SCANNER_SETUP + 'math.random=function(choiceCount) return 1 end; ' +
                                       f"BatataScanner_DB={{schemaVersion=1,settings={{scanBehavior={saved_value}}}}}")
                expected_behavior = saved_value.strip("'") if saved_value in ("'ordered'", "'reversed'") else "random"
                expected_query = "1-10" if expected_behavior == "ordered" else "51-60"
                self.check(f"NS.db.settings.scanBehavior=='{expected_behavior}'")
                self.check(f"NS.Scanner:GetStatus().currentQuery=='{expected_query}'")

    def test_random_behavior_processes_each_range_and_class_once(self):
        """Verifies that random behavior processes each range and class once."""
        self.harness.execute("NS.db.settings.scanBehavior='random'; math.random=function(choiceCount) return 1 end")
        self.harness.click("assert(NS.Scanner:Start({minLevel=3,maxLevel=25,classes={'Mage','Warrior'}}))")
        expected_queries = [
            f'c-"{class_name}" {level_range}'
            for level_range in ("23-25", "13-22", "3-12")
            for class_name in ("Warrior", "Mage")
        ]
        for query_number, expected_query in enumerate(expected_queries, start=1):
            self.check(f"whoCalls[{query_number}]==[[{expected_query}]]")
            self.harness.execute("Deliver({})")
            if query_number < len(expected_queries):
                self.harness.advance(6)
                self.harness.click("assert(NS.Scanner:Continue())")
        self.check("#whoCalls==6 and NS.Scanner:GetStatus().state=='complete'")

    def test_random_behavior_preserves_remaining_subdivisions_across_reload(self):
        """Verifies that random behavior preserves remaining subdivisions across reload."""
        self.harness.execute("NS.db.settings.scanBehavior='random'; math.random=function(choiceCount) return 1 end")
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=30}))")
        self.harness.execute("Deliver({},75)")
        self.check("whoCalls[1]=='21-30' and NS.Scanner:GetStatus().plannedQueries==5")
        self.reload()
        self.check("NS.db.scanner.scanBehavior=='random' and NS.db.settings.scanBehavior=='random'")
        for expected_query in ("21-25", "26-30", "11-20", "1-10"):
            self.check(f"NS.Scanner:GetStatus().currentQuery=='{expected_query}'")
            self.harness.advance(6)
            self.harness.click("assert(NS.Scanner:Continue())")
            self.harness.execute("Deliver({})")
        self.check("#whoCalls==4 and NS.Scanner:GetStatus().state=='complete'")
        self.check("NS.Scanner:GetStatus().completedQueries==5")

    def test_random_behavior_retries_only_the_throttled_chunk(self):
        """Verifies that random behavior retries only the throttled chunk."""
        self.harness.execute("NS.db.settings.scanBehavior='random'; math.random=function(choiceCount) return 1 end")
        self.harness.click("assert(NS.Scanner:Start())")
        self.harness.execute("Emit('CHAT_MSG_SYSTEM','You must wait a moment longer before using /who again')")
        self.harness.advance(12)
        self.harness.click("assert(NS.Scanner:Continue())")
        self.check("#whoCalls==2 and whoCalls[1]==whoCalls[2] and whoCalls[2]=='51-60'")
        self.harness.execute("Deliver({})")
        self.harness.advance(6)
        self.harness.click("assert(NS.Scanner:Continue())")
        self.check("#whoCalls==3 and whoCalls[3]=='41-50'")

    def test_reversed_behavior_scans_high_to_low_without_overrides(self):
        """Verifies that reversed behavior scans high to low without overrides."""
        self.harness.execute("NS.db.settings.scanBehavior='reversed'")
        self.harness.click("assert(NS.Scanner:Start())")
        for query_number, expected_query in enumerate(
                ("51-60", "41-50", "31-40", "21-30", "11-20", "1-10"), start=1):
            self.check(f"whoCalls[{query_number}]=='{expected_query}'")
            self.harness.execute("Deliver({})")
            if query_number < 6:
                self.harness.advance(6)
                self.harness.click("assert(NS.Scanner:Continue())")
        self.check("NS.Scanner:GetStatus().state=='complete'")

    def test_reversed_behavior_preserves_custom_range_and_class_order(self):
        """Verifies that reversed behavior preserves custom range and class order."""
        self.harness.execute("NS.db.settings.scanBehavior='reversed'")
        self.harness.click("assert(NS.Scanner:Start({minLevel=3,maxLevel=25,classes={'Mage','Warrior'}}))")
        expected_queries = [
            f'c-"{class_name}" {level_range}'
            for level_range in ("23-25", "13-22", "3-12")
            for class_name in ("Mage", "Warrior")
        ]
        for query_number, expected_query in enumerate(expected_queries, start=1):
            self.check(f"whoCalls[{query_number}]==[[{expected_query}]]")
            self.harness.execute("Deliver({})")
            if query_number < len(expected_queries):
                self.harness.advance(6)
                self.harness.click("assert(NS.Scanner:Continue())")
        self.check("NS.Scanner:GetStatus().state=='complete'")

    def test_reversed_behavior_survives_reload_and_splits_high_levels_first(self):
        """Verifies that reversed behavior survives reload and splits high levels first."""
        self.harness.execute("NS.db.settings.scanBehavior='reversed'")
        self.harness.click("assert(NS.Scanner:Start({minLevel=51,maxLevel=60}))")
        self.harness.execute("Deliver({{fullName='High Player',level=60}},75)")
        self.reload()
        self.check("NS.db.settings.scanBehavior=='reversed' and #whoCalls==0")
        for expected_query in ("56-60", "59-60"):
            self.check(f"NS.Scanner:GetStatus().currentQuery=='{expected_query}'")
            self.harness.advance(6)
            self.harness.click("assert(NS.Scanner:Continue())")
            self.harness.execute("Deliver({{fullName='High Player',level=60}},75)")
        self.check("NS.Scanner:GetStatus().currentQuery=='60-60'")
        self.harness.advance(6)
        self.harness.click("assert(NS.Scanner:Continue())")
        self.harness.execute("Deliver({})")
        self.check("NS.Scanner:GetStatus().currentQuery=='59-59'")

    def test_response_replaces_the_waiting_reason(self):
        """Verifies that response replaces the waiting reason."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=30}))")
        self.check("NS.Scanner:GetStatus().reason=='Waiting for a Who response.'")
        self.harness.execute("Deliver({})")
        self.check("NS.Scanner:GetStatus().reason=='Ready for the next Who query.'")

    def test_debug_command_reports_query_and_response_size(self):
        """Verifies that debug command reports query and response size."""
        self.harness.execute("SlashCmdList.BATATASCANNER('debug')")
        self.check("chat[1]:find('Who query debug enabled.',1,true)~=nil")
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=10}))")
        self.check("whoCalls[1]=='1-10' and chat[2]:find('Who query: 1-10',1,true)~=nil")
        self.harness.execute("Deliver({{fullName='Alice',level=5}},2)")
        self.check("chat[3]:find('Who response: 1 rows received (server total: 2).',1,true)~=nil")
        self.harness.execute("SlashCmdList.BATATASCANNER('debug')")
        self.check("chat[4]:find('Who query debug disabled.',1,true)~=nil")

    def test_reload_keeps_a_paused_sweep_paused(self):
        """Verifies that reload keeps a paused sweep paused."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=30}))")
        self.harness.execute("Deliver({}); NS.Scanner:Pause()")
        self.reload()
        self.check("NS.Scanner:GetStatus().paused and NS.Scanner:GetStatus().state=='paused'")
        self.check("NS.Scanner:GetStatus().running and NS.Scanner:GetStatus().remainingQueries==2")
        self.harness.advance(6)
        self.harness.click("assert(NS.Scanner:Continue())")
        self.check("whoCalls[1]=='11-20' and not NS.Scanner:GetStatus().paused")

    def test_reload_recomputes_environment_holds_and_preserves_manual_pause(self):
        """Verifies that reload recomputes environment holds and preserves manual pause."""
        for manually_paused in (False, True):
            with self.subTest(manually_paused=manually_paused):
                self.harness = Harness(setup=STOPPED_SETUP)
                self.harness.execute('playerCombat=true; instanceKind="pvp"')
                self.harness.click("assert(not NS.Scanner:Start({minLevel=1,maxLevel=30}))")
                if manually_paused:
                    self.harness.execute("NS.Scanner:Pause()")
                self.reload()
                self.check("NS.db.scanner.inCombat==nil and NS.db.scanner.inBattleground==nil")
                self.check("NS.db.scanner.environmentUnavailable==nil")
                self.check("not NS.Scanner:GetStatus().inCombat and not NS.Scanner:GetStatus().inBattleground")
                self.check("not NS.Scanner:GetStatus().environmentUnavailable")
                self.check("NS.Scanner:GetStatus().running and NS.Scanner:GetStatus().remainingQueries==3")
                self.check(f"NS.Scanner:GetStatus().paused=={str(manually_paused).lower()}")
                self.check("not NS.Scanner:GetStatus().reason:find('combat',1,true)")
                self.harness.advance(6)
                self.check("#whoCalls==0")
                self.harness.click('WorldFrame:GetScript("OnMouseDown")(WorldFrame)')
                self.check(f"#whoCalls=={0 if manually_paused else 1}")

    def test_reload_keeps_a_stopped_scanner_stopped(self):
        """Verifies that reload keeps a stopped scanner stopped."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=30}))")
        self.harness.execute("Deliver({}); NS.Scanner:Stop()")
        self.reload()
        self.check("not NS.Scanner:GetStatus().running and NS.Scanner:GetStatus().state=='stopped'")
        self.check("NS.Scanner:GetStatus().remainingQueries==0 and NS.Scanner:GetStatus().incomplete")

    def test_reload_during_a_query_retries_it_after_the_response_window(self):
        """Verifies that reload during a query retries it after the response window."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=10}))")
        self.harness.emit("PLAYER_LOGOUT")
        self.check("LFGWhoListFrame:IsEventRegistered('WHO_LIST_UPDATE') and not whoRouting")
        self.reload()
        self.check("NS.Scanner:GetStatus().running and not NS.Scanner:GetStatus().awaiting")
        self.check("NS.Scanner:GetStatus().incomplete and NS.Scanner:GetStatus().pendingLateResponse")
        self.harness.execute("Deliver({{fullName='Late',level=5}})")
        self.check("BatataScanner.CountPlayers()==0 and NS.Scanner:GetStatus().pendingLateResponse")
        self.harness.advance(5)
        self.harness.click("assert(not NS.Scanner:Continue())")
        self.harness.advance(5)
        self.harness.click("assert(NS.Scanner:Continue())")
        self.check("#whoCalls==1 and whoCalls[1]=='1-10'")
        self.harness.execute("Deliver({})")
        self.check("NS.Scanner:GetStatus().state=='complete' and NS.Scanner:GetStatus().incomplete")

    def test_reload_after_an_interrupted_hold_expires_keeps_the_warning(self):
        """Verifies that reload after an interrupted hold expires keeps the warning."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=10}))")
        database, clock = self.harness.execute(
            SERIALIZE + "Emit('PLAYER_LOGOUT'); return Serialize(BatataScanner_DB),clock")
        self.harness = Harness(setup=SCANNER_SETUP + f"BatataScanner_DB={database}\nclock={clock + 30!r}\n")
        self.check("NS.Scanner:GetStatus().incomplete and not NS.Scanner:GetStatus().pendingLateResponse")
        self.check("NS.Scanner:GetStatus().cooldown==0")
        self.harness.click("assert(NS.Scanner:Continue())")
        self.harness.execute("Deliver({})")
        self.check("NS.Scanner:GetStatus().state=='complete' and NS.Scanner:GetStatus().incomplete")

    def test_world_transition_keeps_the_sweep(self):
        """Verifies that world transition keeps the sweep."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=30}))")
        self.harness.emit("PLAYER_LEAVING_WORLD")
        self.harness.execute("Deliver({{fullName='Alice',level=5}})")
        self.check("NS.Scanner:GetStatus().running and BatataScanner.CountPlayers()==1")

    def test_invalid_saved_queries_are_dropped_and_reported(self):
        """Verifies that invalid saved queries are dropped and reported."""
        self.harness = Harness(setup=SCANNER_SETUP + '''
            BatataScanner_DB={schemaVersion=1,scanner={running=true,plannedQueries=3,queue={
                {minLevel=1,maxLevel=10},{minLevel=20,maxLevel=5},{raw="a\\nb"}}}}
        ''')
        self.check("NS.Scanner:GetStatus().running and NS.Scanner:GetStatus().remainingQueries==1")
        self.check("NS.Scanner:GetStatus().incomplete")

    def test_next_queries_require_a_fresh_click(self):
        """Verifies that next queries require a fresh click."""
        self.harness.click("assert(NS.Scanner:Start())")
        self.harness.advance(5)
        self.check("#whoCalls==1 and whoCalls[1]=='1-10'")
        self.harness.execute("Deliver({{fullName='One Surname',level=5,fullGuildName=''}})")
        self.harness.advance(6)
        self.check("#whoCalls==1 and NS.Scanner:GetStatus().state=='ready'")
        self.harness.click("assert(NS.Scanner:Continue())")
        self.check("#whoCalls==2 and whoCalls[2]=='11-20'")

    def test_reported_total_splits_a_level_range(self):
        """Verifies that reported total splits a level range."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=10}))")
        self.harness.execute("Deliver({{fullName='A',level=2}},51)")
        self.check("NS.Scanner:GetStatus().returned==1 and NS.Scanner:GetStatus().total==51")
        self.check("NS.Scanner:GetStatus().remainingQueries==2 and NS.Scanner:GetStatus().plannedQueries==3")
        self.harness.advance(6)
        self.harness.click("assert(NS.Scanner:Continue())")
        self.check("whoCalls[2]=='1-5'")

    def test_single_level_splits_using_forever_races_then_valid_classes(self):
        """Verifies that single level splits using forever races then valid classes."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=60,maxLevel=60}))")
        self.harness.execute("Deliver({{fullName='A',level=60,raceStr='Dwarf'}},75)")
        self.harness.advance(6)
        self.harness.click("assert(NS.Scanner:Continue())")
        self.check("whoCalls[2]=='r-\"Dwarf\" 60-60'")
        self.harness.execute("Deliver({{fullName='A',level=60,raceStr='Dwarf',classStr='Hunter'}},75)")
        self.harness.advance(6)
        self.harness.click("assert(NS.Scanner:Continue())")
        self.check("whoCalls[3]=='r-\"Dwarf\" c-\"Hunter\" 60-60'")

    def test_class_subdivision_excludes_incompatible_races(self):
        """Verifies that class subdivision excludes incompatible races."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=60,maxLevel=60,classes={'Mage'}}))")
        self.harness.execute("Deliver({{fullName='Human Mage',level=60,raceStr='Human',classStr='Mage'}},75)")
        self.check("NS.Scanner:GetStatus().remainingQueries==3")
        self.harness.advance(6)
        self.harness.click("assert(NS.Scanner:Continue())")
        self.check("whoCalls[2]=='r-\"Gnome\" c-\"Mage\" 60-60'")

    def test_saturated_class_query_splits_by_race_then_finishes_incomplete(self):
        """Verifies that saturated class query splits by race then finishes incomplete."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=60,maxLevel=60,classes={'Mage'}}))")
        self.check("whoCalls[1]=='c-\"Mage\" 60-60'")
        self.harness.execute("Deliver({{fullName='Someone',level=60,raceStr='Human',classStr='Mage'}},100)")
        self.check("NS.Scanner:GetStatus().remainingQueries==3")
        for race in ("Gnome", "High Order Skyborne", "Human"):
            self.harness.advance(6)
            self.harness.click("assert(NS.Scanner:Continue())")
            self.harness.execute(
                f"Deliver({{{{fullName='{race} Mage',level=60,raceStr='{race}',classStr='Mage'}}}},100)")
        self.check("whoCalls[2]=='r-\"Gnome\" c-\"Mage\" 60-60' and whoCalls[4]=='r-\"Human\" c-\"Mage\" 60-60'")
        self.check("NS.Scanner:GetStatus().state=='complete' and NS.Scanner:GetStatus().incomplete")
        self.check("NS.Scanner:GetStatus().newPlayers==4")

    def test_every_forever_race_splits_into_exactly_its_supported_classes(self):
        """Verifies that every forever race splits into exactly its supported classes."""
        for faction, races in FOREVER_RACES.items():
            for race, classes in races.items():
                with self.subTest(faction=faction, race=race):
                    self.harness = Harness(setup=STOPPED_SETUP +
                                           f"function UnitFactionGroup() return '{faction}' end")
                    self.harness.execute(f'''
                        NS.db.scanner={{faction='{faction}',running=true,scanBehavior='ordered',plannedQueries=1,queue={{
                            {{minLevel=60,maxLevel=60,race='{race}'}}
                        }}}}
                        NS.Scanner:Restore()
                    ''')
                    self.harness.click("assert(NS.Scanner:Continue())")
                    self.harness.execute("Deliver({},100)")
                    self.check(f"NS.Scanner:GetStatus().remainingQueries=={len(classes)}")
                    for class_name in sorted(classes):
                        self.harness.advance(6)
                        self.harness.click("assert(NS.Scanner:Continue())")
                        self.check(f'''whoCalls[#whoCalls]==[[r-"{race}" c-"{class_name}" 60-60]]''')
                        self.harness.execute("Deliver({})")
                    self.check("NS.Scanner:GetStatus().state=='complete' and not NS.Scanner:GetStatus().incomplete")

    def test_every_forever_class_splits_into_exactly_its_supported_faction_races(self):
        """Verifies that every forever class splits into exactly its supported faction races."""
        for faction, races in FOREVER_RACES.items():
            class_names = sorted({class_name for classes in races.values() for class_name in classes})
            for class_name in class_names:
                with self.subTest(faction=faction, class_name=class_name):
                    self.harness = Harness(setup=STOPPED_SETUP +
                                           f"function UnitFactionGroup() return '{faction}' end")
                    self.harness.click("assert(NS.Scanner:Start({minLevel=60,maxLevel=60,classes={"
                                       f"'{class_name}'" + "}}))")
                    self.harness.execute("Deliver({},100)")
                    expected_races = sorted(race for race, classes in races.items() if class_name in classes)
                    self.check(f"NS.Scanner:GetStatus().remainingQueries=={len(expected_races)}")
                    for race in expected_races:
                        self.harness.advance(6)
                        self.harness.click("assert(NS.Scanner:Continue())")
                        self.check(f'''whoCalls[#whoCalls]==[[r-"{race}" c-"{class_name}" 60-60]]''')
                        self.harness.execute("Deliver({})")
                    self.check("NS.Scanner:GetStatus().state=='complete' and not NS.Scanner:GetStatus().incomplete")

    def test_unsupported_classes_are_neither_offered_nor_dispatched(self):
        """Verifies that unsupported classes are neither offered nor dispatched."""
        self.harness.execute('''
            LOCALIZED_CLASS_NAMES_MALE.DEATHKNIGHT="Death Knight"
            C_SpecializationInfo.GetAllClassIDs=function() return {1,6,8,10,12,13} end
        ''')
        self.check("#NS.Scanner:ClassChoices()==9")
        self.harness.click("assert(not NS.Scanner:Start({classes={'Death Knight'}}))")
        self.check("#whoCalls==0 and not NS.Scanner:GetStatus().running")

    def test_saved_impossible_or_unsupported_pairs_are_discarded(self):
        """Verifies that saved impossible or unsupported pairs are discarded."""
        self.harness = Harness(setup=SCANNER_SETUP + '''
            BatataScanner_DB={schemaVersion=1,scanner={running=true,plannedQueries=4,queue={
                {minLevel=60,maxLevel=60,race="Dwarf",className="Mage"},
                {minLevel=60,maxLevel=60,race="Vulpera",className="Warrior"},
                {minLevel=60,maxLevel=60,race="Human",className="Death Knight"},
                {minLevel=60,maxLevel=60,race="Dwarf",className="Shaman"}
            }}}
        ''')
        self.check("NS.Scanner:GetStatus().remainingQueries==1 and NS.Scanner:GetStatus().incomplete")
        self.reload()
        self.harness.click("assert(NS.Scanner:Continue())")
        self.check("whoCalls[1]=='r-\"Dwarf\" c-\"Shaman\" 60-60'")

    def test_localized_race_and_class_names_preserve_the_same_matrix(self):
        """Verifies that localized race and class names preserve the same matrix."""
        localized_setup = STOPPED_SETUP + '''
            C_FriendList.GetWhoRaceFilters=function() return {{name="Nain",ID=3}} end
            C_CreatureInfo.GetRaceInfo=function(raceID)
                if raceID==1 then return {raceName="Humain"}
                elseif raceID==95 then return {raceName="Skyborne Haut"} end
            end
            local originalGetClassInfo=GetClassInfo
            GetClassInfo=function(classID)
                if classID==8 then return "Magicien","MAGE"
                elseif classID==7 then return "Chaman","SHAMAN" end
                return originalGetClassInfo(classID)
            end
            LOCALIZED_CLASS_NAMES_FEMALE.MAGE="Magicienne"
        '''
        self.harness = Harness(setup=localized_setup)
        self.harness.click("assert(NS.Scanner:Start({minLevel=60,maxLevel=60,classes={'Magicienne'}}))")
        self.check("whoCalls[1]=='c-\"Magicien\" 60-60'")
        self.harness.execute("Deliver({},100)")
        for race in ("Gnome", "Humain", "Skyborne Haut"):
            self.harness.advance(6)
            self.harness.click("assert(NS.Scanner:Continue())")
            self.check(f'''whoCalls[#whoCalls]==[[r-"{race}" c-"Magicien" 60-60]]''')
            self.harness.execute("Deliver({})")
        self.check("NS.Scanner:GetStatus().state=='complete' and not NS.Scanner:GetStatus().incomplete")
        self.harness = Harness(setup=localized_setup)
        self.harness.execute('''
            NS.db.scanner={running=true,scanBehavior="ordered",plannedQueries=1,
                queue={{minLevel=60,maxLevel=60,race="Nain"}}}
            NS.Scanner:Restore()
        ''')
        self.harness.click("assert(NS.Scanner:Continue())")
        self.harness.execute("Deliver({},100)")
        self.check("NS.Scanner:GetStatus().remainingQueries==6")
        self.harness.advance(6)
        self.harness.click("assert(NS.Scanner:Continue())")
        self.check("whoCalls[2]=='r-\"Nain\" c-\"Chaman\" 60-60'")

    def test_gendered_who_class_names_match_the_class_query(self):
        """Verifies that gendered who class names match the class query."""
        for class_name, class_token in (("Magicienne", "'MAGE'"), ("Magicienne", "nil"), ("Magicien", "nil")):
            with self.subTest(class_name=class_name, class_token=class_token):
                self.harness = Harness(setup=STOPPED_SETUP + '''
                    LOCALIZED_CLASS_NAMES_MALE.MAGE="Magicien"
                    LOCALIZED_CLASS_NAMES_FEMALE.MAGE="Magicienne"
                    function GetClassInfo(classID)
                        if classID==8 then return "Magicien","MAGE" end
                    end
                ''')
                self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=10,classes={'Magicien'}}))")
                self.harness.execute(
                    f"Deliver({{{{fullName='Localized Player',level=5,classStr='{class_name}',filename={class_token}}}}})")
                self.check("NS.Scanner:GetStatus().state=='complete' and NS.Scanner:GetStatus().completedQueries==1")
                self.check("BatataScanner.CountPlayers()==1 and not NS.Scanner:GetStatus().incomplete")

    def test_reference_roster_remains_available_without_native_lookup_apis(self):
        """Verifies that reference roster remains available without native lookup apis."""
        self.harness.execute('''
            C_FriendList.GetWhoRaceFilters=nil
            C_CreatureInfo=nil
            GetClassInfo=nil
            LOCALIZED_CLASS_NAMES_MALE=nil
        ''')
        self.check("#NS.Scanner:ClassChoices()==9")
        self.harness.click("assert(NS.Scanner:Start({minLevel=60,maxLevel=60}))")
        self.harness.execute("Deliver({},100)")
        self.check("NS.Scanner:GetStatus().remainingQueries==5")
        for race in sorted(FOREVER_RACES["Alliance"]):
            self.harness.advance(6)
            self.harness.click("assert(NS.Scanner:Continue())")
            self.check(f'''whoCalls[#whoCalls]==[[r-"{race}" 60-60]]''')
            self.harness.execute("Deliver({})")

    def test_fifty_delivered_rows_trigger_conservative_splitting(self):
        """Verifies that fifty delivered rows trigger conservative splitting."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=10}))")
        self.harness.execute('''
            local rows={}
            for index=1,50 do rows[index]={fullName="Player"..index,level=5} end
            Deliver(rows,50)
        ''')
        self.check("NS.Scanner:GetStatus().remainingQueries==2")

    def test_unanswered_chunk_retries_after_a_bounded_cooldown(self):
        """Verifies that unanswered chunk retries after a bounded cooldown."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=20}))")
        self.harness.advance(10)
        self.check("NS.Scanner:GetStatus().running and not NS.Scanner:GetStatus().paused")
        self.check("NS.Scanner:GetStatus().pendingLateResponse and NS.Scanner:GetStatus().cooldown==10")
        self.check("NS.Scanner:GetStatus().remainingQueries==2 and NS.Scanner:GetStatus().completedQueries==0")
        self.check("not NS.Scanner:GetStatus().reason:lower():find('reload',1,true)")
        self.harness.advance(10)
        self.check("#whoCalls==1 and not NS.Scanner:GetStatus().pendingLateResponse")
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.check("#whoCalls==2 and whoCalls[1]=='1-10' and whoCalls[2]=='1-10'")
        self.harness.execute("Deliver({{fullName='Retried',level=5}})")
        self.check("NS.Scanner:GetStatus().completedQueries==1 and NS.Scanner:GetStatus().remainingQueries==1")
        self.check("BatataScanner.CountPlayers()==1 and NS.Scanner:GetStatus().incomplete")

    def test_external_query_without_a_reply_does_not_stall_the_sweep(self):
        """Verifies that external query without a reply does not stall the sweep."""
        self.harness = Harness(setup=SCANNER_SETUP)
        self.harness.execute("firstQuery=NS.Scanner:GetStatus().currentQuery")
        self.harness.click("C_FriendList.SendWho('5-5')")
        self.harness.advance(10)
        self.check("not NS.Scanner:GetStatus().externalQueryPending and NS.Scanner:GetStatus().pendingLateResponse")
        self.check("NS.Scanner:GetStatus().running and not NS.Scanner:GetStatus().paused")
        self.harness.execute("Deliver({{fullName='External',level=5}})")
        self.harness.advance(10)
        self.check("#whoCalls==1 and BatataScanner.CountPlayers()==0")
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.check("#whoCalls==2 and whoCalls[2]==firstQuery")

    def test_failed_send_keeps_the_chunk_playing_for_a_later_retry(self):
        """Verifies that failed send keeps the chunk playing for a later retry."""
        self.harness.execute('''
            local originalSend=C_FriendList.SendWho
            local failNext=true
            C_FriendList.SendWho=function(...)
                if failNext then
                    failNext=false
                    error("Who send failed")
                end
                return originalSend(...)
            end
        ''')
        self.harness.click("assert(not NS.Scanner:Start({minLevel=1,maxLevel=20}))")
        self.check("NS.Scanner:GetStatus().running and not NS.Scanner:GetStatus().paused")
        self.check("NS.Scanner:GetStatus().remainingQueries==2 and NS.Scanner:GetStatus().pendingLateResponse")
        self.check("LFGWhoListFrame:IsEventRegistered('WHO_LIST_UPDATE') and not whoRouting")
        self.harness.advance(10)
        self.check("#whoCalls==0")
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.check("#whoCalls==1 and whoCalls[1]=='1-10'")

    def test_client_blocked_sends_retry_after_cooldown(self):
        """Verifies that client blocked sends retry after cooldown."""
        for event_name in ("ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN"):
            with self.subTest(event_name=event_name):
                self.harness = Harness(setup=STOPPED_SETUP)
                self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=20}))")
                self.harness.emit(event_name, "BatataScanner")
                self.check("NS.Scanner:GetStatus().running and not NS.Scanner:GetStatus().paused")
                self.check("NS.Scanner:GetStatus().pendingLateResponse and not NS.Scanner:GetStatus().awaiting")
                self.harness.execute("Deliver({{fullName='Late',level=5}})")
                self.harness.advance(10)
                self.check("#whoCalls==1 and BatataScanner.CountPlayers()==0")
                self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
                self.check("#whoCalls==2 and whoCalls[2]==whoCalls[1]")

    def test_timeout_retry_preserves_manual_pause_and_cooldown_across_reload(self):
        """Verifies that timeout retry preserves manual pause and cooldown across reload."""
        for pause_before_timeout in (True, False):
            with self.subTest(pause_before_timeout=pause_before_timeout):
                self.harness = Harness(setup=STOPPED_SETUP)
                self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=20}))")
                if pause_before_timeout:
                    self.harness.execute("NS.Scanner:Pause()")
                self.harness.advance(10)
                if not pause_before_timeout:
                    self.harness.execute("NS.Scanner:Pause()")
                self.reload()
                self.check("NS.Scanner:GetStatus().paused and NS.Scanner:GetStatus().cooldown==10")
                self.check("NS.Scanner:GetStatus().pendingLateResponse and NS.Scanner:GetStatus().incomplete")
                self.harness.advance(30)
                self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
                self.check("#whoCalls==0 and NS.Scanner:GetStatus().paused")
                self.harness.click("assert(NS.Scanner:Continue())")
                self.check("#whoCalls==1 and whoCalls[1]=='1-10'")

    def test_saved_reload_required_state_recovers_its_queued_work(self):
        """Verifies that saved reload required state recovers its queued work."""
        self.harness = Harness(setup=SCANNER_SETUP + '''
            BatataScanner_DB={schemaVersion=1,settings={queryInterval=5},scanner={state="blocked",running=false,paused=false,
                queue={{minLevel=1,maxLevel=10}},plannedQueries=1,incomplete=true,
                sentAt=100,reason="Overlapping Who requests. Reload the UI before scanning again."}}
        ''')
        self.check("NS.Scanner:GetStatus().running and NS.Scanner:GetStatus().state=='ready'")
        self.check("not NS.Scanner:GetStatus().blockedUntilReload and NS.Scanner:GetStatus().cooldown==10")
        self.check("not NS.Scanner:GetStatus().reason:lower():find('reload',1,true)")
        self.harness.advance(10)
        self.check("#whoCalls==0")
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.check("#whoCalls==1 and whoCalls[1]=='1-10'")

    def test_timeout_discards_late_response_before_retry(self):
        """Verifies that timeout discards late response before retry."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=5,maxLevel=5}))")
        self.harness.advance(11)
        self.check("not NS.Scanner:GetStatus().paused and NS.Scanner:GetStatus().pendingLateResponse")
        self.harness.click("assert(not NS.Scanner:Continue())")
        self.check("#whoCalls==1")
        self.harness.execute("Deliver({{fullName='Late Player',level=5}})")
        self.check("BatataScanner.CountPlayers()==0 and NS.Scanner:GetStatus().pendingLateResponse")
        self.harness.advance(9)
        self.harness.click("assert(NS.Scanner:Continue())")
        self.harness.execute("Deliver({{fullName='Fresh Player',level=5}})")
        self.check("#whoCalls==2 and BatataScanner.CountPlayers()==1")
        self.check("NS.Scanner:GetStatus().state=='complete'")

    def test_unanswered_query_cooldown_expires_even_after_stop(self):
        """Verifies that unanswered query cooldown expires even after stop."""
        self.harness.click("assert(NS.Scanner:Start())")
        self.harness.advance(11)
        self.check("NS.Scanner:GetStatus().pendingLateResponse")
        self.check("not NS.Scanner:GetStatus().reason:lower():find('reload',1,true)")
        self.harness.execute("NS.Scanner:Stop()")
        self.check("NS.Scanner:GetStatus().pendingLateResponse")
        self.check("not NS.Scanner:GetStatus().reason:lower():find('reload',1,true)")
        self.harness.click("assert(not NS.Scanner:Start())")
        self.check("#whoCalls==1 and BatataScanner.CountPlayers()==0")
        self.harness.advance(9)
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.check("not NS.Scanner:GetStatus().pendingLateResponse and #whoCalls==1")
        self.harness.click("assert(NS.Scanner:Start())")
        self.check("#whoCalls==2")

    def test_system_who_throttle_retries_the_unfinished_query_on_a_fresh_click(self):
        """Verifies that system who throttle retries the unfinished query on a fresh click."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=5,maxLevel=5}))")
        self.harness.emit("CHAT_MSG_SYSTEM", "You must wait a moment longer before using /who again")
        self.check("NS.Scanner:GetStatus().running and not NS.Scanner:GetStatus().paused")
        self.check("NS.Scanner:GetStatus().state=='ready' and not NS.Scanner:GetStatus().awaiting")
        self.check("not NS.Scanner:GetStatus().pendingLateResponse and NS.Scanner:GetStatus().cooldown==12")
        self.check("NS.Scanner:GetStatus().remainingQueries==1 and NS.Scanner:GetStatus().completedQueries==0")
        self.check("LFGWhoListFrame:IsEventRegistered('WHO_LIST_UPDATE') and not whoRouting")
        self.harness.execute("Deliver({{fullName='Unexpected',level=5}})")
        self.harness.advance(6)
        self.harness.click("assert(not NS.Scanner:Continue())")
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.check("#whoCalls==1 and BatataScanner.CountPlayers()==0")
        self.harness.advance(6)
        self.check("NS.Scanner:GetStatus().cooldown==0 and #whoCalls==1")
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.harness.execute("Deliver({{fullName='Fresh',level=5}})")
        self.check("#whoCalls==2 and whoCalls[2]=='5-5' and NS.Scanner:GetStatus().state=='complete'")
        self.check("BatataScanner.CountPlayers()==1")

    def test_delayed_who_throttle_recovers_a_timed_out_query(self):
        """Verifies that delayed who throttle recovers a timed out query."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=5,maxLevel=5}))")
        self.harness.advance(11)
        self.check("NS.Scanner:GetStatus().pendingLateResponse and not NS.Scanner:GetStatus().paused")
        self.harness.emit("CHAT_MSG_SYSTEM", "You must wait a moment longer before using /who again")
        self.check("NS.Scanner:GetStatus().running and not NS.Scanner:GetStatus().paused")
        self.check("not NS.Scanner:GetStatus().pendingLateResponse and not NS.Scanner:GetStatus().awaiting")
        self.check("NS.Scanner:GetStatus().cooldown==12 and NS.Scanner:GetStatus().completedQueries==0")
        self.harness.advance(11.75)
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.check("#whoCalls==1")
        self.harness.advance(0.25)
        self.check("#whoCalls==1")
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.harness.execute("Deliver({{fullName='Fresh',level=5}})")
        self.check("#whoCalls==2 and whoCalls[2]=='5-5' and NS.Scanner:GetStatus().state=='complete'")
        self.check("BatataScanner.CountPlayers()==1")

    def test_delayed_who_throttle_preserves_an_explicit_pause(self):
        """Verifies that delayed who throttle preserves an explicit pause."""
        for pause_before_timeout in (True, False):
            with self.subTest(pause_before_timeout=pause_before_timeout):
                self.harness = Harness(setup=STOPPED_SETUP)
                self.harness.click("assert(NS.Scanner:Start({minLevel=5,maxLevel=5}))")
                if pause_before_timeout:
                    self.harness.execute("NS.Scanner:Pause()")
                self.harness.advance(11)
                if not pause_before_timeout:
                    self.harness.execute("NS.Scanner:Pause()")
                self.harness.emit("UI_ERROR_MESSAGE", 123,
                                  "You must wait a moment longer before using /who again.")
                self.check("NS.Scanner:GetStatus().paused and not NS.Scanner:GetStatus().pendingLateResponse")
                self.harness.advance(12)
                self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
                self.check("#whoCalls==1 and NS.Scanner:GetStatus().paused")
                self.harness.click("assert(NS.Scanner:Continue())")
                self.check("#whoCalls==2 and whoCalls[2]=='5-5'")

    def test_delayed_who_throttle_does_not_clear_a_stopped_query_quarantine(self):
        """Verifies that delayed who throttle does not clear a stopped query quarantine."""
        for stop_after_timeout in (True, False):
            with self.subTest(stop_after_timeout=stop_after_timeout):
                self.harness = Harness(setup=STOPPED_SETUP)
                self.harness.click("assert(NS.Scanner:Start())")
                if stop_after_timeout:
                    self.harness.advance(11)
                self.harness.execute("NS.Scanner:Stop()")
                self.harness.emit("CHAT_MSG_SYSTEM", "You must wait a moment longer before using /who again")
                self.check("NS.Scanner:GetStatus().pendingLateResponse and not NS.Scanner:GetStatus().running")
                self.harness.advance(20)
                self.check("not NS.Scanner:GetStatus().pendingLateResponse")
                self.check("#whoCalls==1")
                self.harness.click("assert(NS.Scanner:Start())")
                self.check("#whoCalls==2")

    def test_delayed_who_throttle_does_not_change_cooldown_after_a_late_response(self):
        """Verifies that delayed who throttle does not change cooldown after a late response."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=5,maxLevel=5}))")
        self.harness.advance(11)
        self.harness.execute("Deliver({{fullName='Late',level=5}})")
        self.harness.emit("CHAT_MSG_SYSTEM", "You must wait a moment longer before using /who again")
        self.check("not NS.Scanner:GetStatus().paused and NS.Scanner:GetStatus().pendingLateResponse")
        self.check("NS.Scanner:GetStatus().cooldown==9 and BatataScanner.CountPlayers()==0")
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.check("#whoCalls==1")
        self.harness.advance(9)
        self.check("#whoCalls==1")
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.check("#whoCalls==2")

    def test_delayed_who_throttle_does_not_release_an_external_overlap(self):
        """Verifies that delayed who throttle does not release an external overlap."""
        self.harness.click("assert(NS.Scanner:Start())")
        self.harness.advance(11)
        self.harness.click("C_FriendList.SendWho('n-\"External\"')")
        self.harness.emit("CHAT_MSG_SYSTEM", "You must wait a moment longer before using /who again")
        self.check("NS.Scanner:GetStatus().pendingLateResponse and NS.Scanner:GetStatus().running")
        self.check("not NS.Scanner:GetStatus().blockedUntilReload and NS.Scanner:GetStatus().cooldown==10")
        self.harness.advance(20)
        self.check("#whoCalls==2 and BatataScanner.CountPlayers()==0")
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.check("#whoCalls==3")

    def test_who_interval_starts_at_dispatch_after_routing_preparation(self):
        """Verifies that who interval starts at dispatch after routing preparation."""
        self.harness.execute('''
            NS.db.settings.queryInterval=12
            local setWhoToUi=C_FriendList.SetWhoToUi
            C_FriendList.SetWhoToUi=function(enabled)
                setWhoToUi(enabled)
                if enabled then clock=clock+2 end
            end
        ''')
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=20}))")
        self.harness.execute("Deliver({})")
        self.check("NS.Scanner:GetStatus().cooldown==12")
        self.harness.advance(11.75)
        self.harness.click("assert(not NS.Scanner:Continue())")
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.check("#whoCalls==1")
        self.harness.advance(0.25)
        self.check("#whoCalls==1")
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.check("#whoCalls==2 and whoCalls[2]=='11-20'")

    def test_localized_ui_who_throttle_and_duplicate_notification(self):
        """Verifies that localized ui who throttle and duplicate notification."""
        self.harness.execute("ERR_WHO_LIST_WAIT='Localized Who cooldown'")
        self.harness.click("assert(NS.Scanner:Start())")
        self.harness.emit("UI_ERROR_MESSAGE", 123, "Localized Who cooldown")
        self.check("not NS.Scanner:GetStatus().paused and NS.Scanner:GetStatus().cooldown==12")
        self.harness.advance(6)
        self.harness.emit("CHAT_MSG_SYSTEM", "Localized Who cooldown")
        self.check("NS.Scanner:GetStatus().cooldown==6 and not NS.Scanner:GetStatus().pendingLateResponse")
        self.harness.advance(6)
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.check("#whoCalls==2 and whoCalls[2]=='1-10'")

    def test_stop_after_who_throttle_allows_start_after_cooldown(self):
        """Verifies that stop after who throttle allows start after cooldown."""
        self.harness.click("assert(NS.Scanner:Start())")
        self.harness.emit("CHAT_MSG_SYSTEM", "You must wait a moment longer before using /who again.")
        self.harness.execute("NS.Scanner:Stop()")
        self.check("not NS.Scanner:GetStatus().running and not NS.Scanner:GetStatus().pendingLateResponse")
        self.harness.advance(12)
        self.harness.click("assert(NS.Scanner:Start())")
        self.check("#whoCalls==2 and whoCalls[2]=='1-10'")

    def test_reload_preserves_the_remaining_who_throttle_backoff(self):
        """Verifies that reload preserves the remaining who throttle backoff."""
        self.harness.execute("NS.db.settings.queryInterval=20")
        self.harness.click("assert(NS.Scanner:Start({minLevel=5,maxLevel=5}))")
        self.harness.emit("CHAT_MSG_SYSTEM", "You must wait a moment longer before using /who again")
        self.harness.advance(5)
        self.reload()
        self.check("NS.Scanner:GetStatus().running and not NS.Scanner:GetStatus().paused")
        self.check("NS.Scanner:GetStatus().state=='ready' and NS.Scanner:GetStatus().cooldown==35")
        self.harness.advance(34)
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.check("#whoCalls==0")
        self.harness.advance(1)
        self.check("#whoCalls==0")
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.check("#whoCalls==1 and whoCalls[1]=='5-5'")

    def test_who_throttle_after_reload_keeps_the_resumed_sweep_playing(self):
        """Verifies that who throttle after reload keeps the resumed sweep playing."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=20}))")
        self.harness.execute("Deliver({{fullName='First',level=5}})")
        self.harness.advance(6)
        self.harness.click("assert(NS.Scanner:Continue())")
        self.reload()
        self.harness.advance(10)
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.check("#whoCalls==1 and whoCalls[1]=='11-20'")
        self.harness.emit("CHAT_MSG_SYSTEM", "You must wait a moment longer before using /who again")
        self.check("NS.Scanner:GetStatus().running and not NS.Scanner:GetStatus().paused")
        self.check("NS.Scanner:GetStatus().completedQueries==1 and NS.Scanner:GetStatus().remainingQueries==1")
        self.check("NS.Scanner:GetStatus().newPlayers==1 and NS.Scanner:GetStatus().cooldown==12")
        self.harness.advance(12)
        self.check("#whoCalls==1")
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.harness.execute("Deliver({{fullName='Resumed',level=15}})")
        self.check("#whoCalls==2 and whoCalls[2]=='11-20' and NS.Scanner:GetStatus().state=='complete'")
        self.check("NS.Scanner:GetStatus().newPlayers==2 and BatataScanner.CountPlayers()==2")

    def test_who_throttle_preserves_explicit_pause_across_reload(self):
        """Verifies that who throttle preserves explicit pause across reload."""
        for pause_before_throttle in (True, False):
            with self.subTest(pause_before_throttle=pause_before_throttle):
                self.harness = Harness(setup=STOPPED_SETUP)
                self.harness.click("assert(NS.Scanner:Start({minLevel=5,maxLevel=5}))")
                if pause_before_throttle:
                    self.harness.execute("NS.Scanner:Pause()")
                self.harness.emit("CHAT_MSG_SYSTEM", "You must wait a moment longer before using /who again")
                if not pause_before_throttle:
                    self.harness.execute("NS.Scanner:Pause()")
                self.check("NS.Scanner:GetStatus().paused and NS.Scanner:GetStatus().state=='paused'")
                self.reload()
                self.harness.advance(12)
                self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
                self.check("#whoCalls==0 and NS.Scanner:GetStatus().paused")
                self.harness.click("assert(NS.Scanner:Continue())")
                self.check("#whoCalls==1 and whoCalls[1]=='5-5'")

    def test_native_who_throttle_does_not_leave_an_external_request_pending(self):
        """Verifies that native who throttle does not leave an external request pending."""
        self.harness.click("C_FriendList.SendWho('5-5')")
        self.harness.emit("CHAT_MSG_SYSTEM", "You must wait a moment longer before using /who again")
        self.check("not NS.Scanner:GetStatus().externalQueryPending")
        self.harness.advance(12)
        self.harness.click("assert(NS.Scanner:Start())")
        self.check("#whoCalls==2 and BatataScanner.CountPlayers()==0")

    def test_unrelated_or_unreadable_notifications_do_not_release_a_query(self):
        """Verifies that unrelated or unreadable notifications do not release a query."""
        self.harness.click("assert(NS.Scanner:Start())")
        self.harness.emit("CHAT_MSG_SYSTEM", "Someone is using /who again")
        self.harness.emit("UI_ERROR_MESSAGE", 123, "You are too far away")
        self.harness.execute("Emit('CHAT_MSG_SYSTEM',{secret=true}); Emit('UI_ERROR_MESSAGE',123,{secret=true})")
        self.check("NS.Scanner:GetStatus().awaiting and not NS.Scanner:GetStatus().paused")
        self.harness.advance(11)
        self.harness.emit("CHAT_MSG_SYSTEM", "You must wait a moment longer before doing that")
        self.check("NS.Scanner:GetStatus().pendingLateResponse and #whoCalls==1")

    def test_stop_restores_only_suspended_native_registration(self):
        """Verifies that stop restores only suspended native registration."""
        self.harness.click("assert(NS.Scanner:Start())")
        self.check("not LFGWhoListFrame:IsEventRegistered('WHO_LIST_UPDATE')")
        self.harness.execute("NS.Scanner:Stop()")
        self.check("LFGWhoListFrame:IsEventRegistered('WHO_LIST_UPDATE')")
        self.check("not WhoFrame:IsEventRegistered('WHO_LIST_UPDATE') and not whoRouting")
        self.harness.click("assert(not NS.Scanner:Start())")
        self.harness.execute("Deliver({{fullName='Late',level=1}})")
        self.check("BatataScanner.CountPlayers()==0")
        self.harness.advance(10)
        self.harness.click("assert(NS.Scanner:Start())")

    def test_pause_finishes_outstanding_response_without_dispatching(self):
        """Verifies that pause finishes outstanding response without dispatching."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=20}))")
        self.harness.execute("NS.Scanner:Pause(); Deliver({{fullName='A',level=5}})")
        self.harness.advance(15)
        self.check("NS.Scanner:GetStatus().paused and #whoCalls==1 and BatataScanner.CountPlayers()==1")
        self.harness.click("assert(NS.Scanner:Continue())")
        self.check("#whoCalls==2")

    def test_external_query_overlap_cannot_be_attributed_to_the_scan(self):
        """Verifies that external query overlap cannot be attributed to the scan."""
        self.harness.click("assert(NS.Scanner:Start())")
        self.harness.click("C_FriendList.SendWho('n-\"External\"')")
        self.harness.execute("Deliver({{fullName='External',level=5}})")
        self.check("NS.Scanner:GetStatus().pendingLateResponse and NS.Scanner:GetStatus().incomplete")
        self.check("NS.Scanner:GetStatus().running and not NS.Scanner:GetStatus().blockedUntilReload")
        self.check("BatataScanner.CountPlayers()==0 and LFGWhoListFrame:IsEventRegistered('WHO_LIST_UPDATE')")
        self.harness.click("assert(not NS.Scanner:Start())")
        self.check("#whoCalls==2")
        self.harness.advance(10)
        self.check("#whoCalls==2")
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.harness.execute("Deliver({{fullName='Fresh',level=5}})")
        self.check("#whoCalls==3 and whoCalls[3]==whoCalls[1] and BatataScanner.CountPlayers()==1")

    def test_native_query_before_scanning_must_finish_first(self):
        """Verifies that native query before scanning must finish first."""
        self.harness.click("C_FriendList.SendWho('5-5')")
        self.harness.click("assert(not NS.Scanner:Start())")
        self.harness.execute("Deliver({{fullName='External',level=5}})")
        self.harness.advance(6)
        self.harness.click("assert(NS.Scanner:Start())")
        self.check("#whoCalls==2 and BatataScanner.CountPlayers()==0")

    def test_mismatched_response_discards_the_entire_batch(self):
        """Verifies that mismatched response discards the entire batch."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=10}))")
        self.harness.execute("Deliver({{fullName='Valid',level=5},{fullName='Wrong',level=60}})")
        self.check("BatataScanner.CountPlayers()==0 and NS.Scanner:GetStatus().paused")
        self.check("NS.Scanner:GetStatus().completedQueries==0")

    def test_unreadable_rows_and_guilds_preserve_unknown_state(self):
        """Verifies that unreadable rows and guilds preserve unknown state."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=10}))")
        self.harness.execute('''
            Deliver({{fullName="Readable",level=5,fullGuildName={secret=true}},
                     {fullName={secret=true},level=5}, {inaccessible=true}})
        ''')
        self.check("BatataScanner.CountPlayers()==1 and NS.Scanner:GetStatus().incomplete")
        self.check("BatataScanner.GetPlayer('Readable').guild==nil")

    def test_partial_native_choices_never_claim_full_coverage(self):
        """Verifies that partial native choices never claim full coverage."""
        self.harness.execute('''
            C_FriendList.GetWhoRaceFilters=function()
                return {{name="Human",ID=1},{name={secret=true},ID=3}}
            end
        ''')
        self.harness.click("assert(NS.Scanner:Start({minLevel=5,maxLevel=5}))")
        self.harness.execute("Deliver({{fullName='A',level=5}},100)")
        self.check("NS.Scanner:GetStatus().incomplete and NS.Scanner:GetStatus().remainingQueries==5")

    def test_environment_holds_block_all_dispatch_paths_without_manual_pause(self):
        """Verifies that environment holds block all dispatch paths without manual pause."""
        for combat, instance_kind in ((True, "none"), (False, "pvp"), (True, "pvp")):
            with self.subTest(combat=combat, instance_kind=instance_kind):
                self.harness = Harness(setup=STOPPED_SETUP +
                    f'combatLockdown={str(combat).lower()}; instanceKind="{instance_kind}"')
                self.harness.click("assert(not NS.Scanner:Start({minLevel=1,maxLevel=20}))")
                self.check("NS.Scanner:GetStatus().running and not NS.Scanner:GetStatus().paused")
                self.check("NS.Scanner:GetStatus().remainingQueries==2 and NS.Scanner:GetStatus().completedQueries==0")
                self.check(f"NS.Scanner:GetStatus().inCombat=={str(combat).lower()}")
                self.check(f"NS.Scanner:GetStatus().inBattleground=={str(instance_kind == 'pvp').lower()}")
                self.harness.click("assert(not NS.Scanner:Continue()); assert(not NS.Scanner:Restart())")
                self.harness.click("SlashCmdList.BATATASCANNER('next'); SlashCmdList.BATATASCANNER('scan')")
                self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
                self.check("#whoCalls==0 and not NS.Scanner:GetStatus().awaiting")
                self.check("LFGWhoListFrame:IsEventRegistered('WHO_LIST_UPDATE') and not whoRouting")

    def test_player_combat_holds_dispatch_without_lockdown(self):
        """Verifies that player combat holds dispatch without lockdown."""
        self.harness.execute('''
            playerCombat=true
            assert(not InCombatLockdown())
            Click(function() assert(not NS.Scanner:Start()) end)
            assert(NS.Scanner:GetStatus().inCombat and not NS.Scanner:GetStatus().environmentUnavailable)
            playerCombat=false
            Emit("PLAYER_REGEN_ENABLED")
            assert(#whoCalls==0 and not NS.Scanner:GetStatus().inCombat)
            Click(function() assert(NS.Scanner:Continue()) end)
            assert(#whoCalls==1)
        ''')

    def test_environment_holds_clear_independently_without_dispatching(self):
        """Verifies that environment holds clear independently without dispatching."""
        self.harness = Harness(setup=SCANNER_SETUP + 'combatLockdown=true; instanceKind="pvp"')
        self.harness.execute('''
            local notifications=0
            BatataScanner.RegisterCallback("SCAN_STATUS_CHANGED",function() notifications=notifications+1 end)
            Emit("PLAYER_ENTERING_WORLD",true,false)
            combatLockdown=false
            Emit("PLAYER_REGEN_ENABLED")
            assert(not NS.Scanner:GetStatus().inCombat and NS.Scanner:GetStatus().inBattleground)
            Click(function() WorldFrame:GetScript("OnMouseDown")(WorldFrame) end)
            assert(#whoCalls==0)
            instanceKind="none"
            Emit("ZONE_CHANGED_NEW_AREA")
            assert(not NS.Scanner:GetStatus().inBattleground and notifications==3)
            Advance(30)
            assert(#whoCalls==0)
            Click(function() WorldFrame:GetScript("OnMouseDown")(WorldFrame) end)
            assert(#whoCalls==1 and not NS.Scanner:GetStatus().paused)
        ''')

    def test_environment_holds_preserve_manual_pause_and_stop(self):
        """Verifies that environment holds preserve manual pause and stop."""
        for stop in (False, True):
            with self.subTest(stop=stop):
                self.harness = Harness(setup=SCANNER_SETUP)
                self.harness.execute('combatLockdown=true; instanceKind="pvp"; Emit("PLAYER_REGEN_DISABLED")')
                self.harness.execute("NS.Scanner:Stop()" if stop else "NS.Scanner:Pause()")
                self.harness.execute('''
                    combatLockdown=false; Emit("PLAYER_REGEN_ENABLED")
                    instanceKind="none"; Emit("ZONE_CHANGED_NEW_AREA")
                    Advance(30)
                    Click(function() WorldFrame:GetScript("OnMouseDown")(WorldFrame) end)
                    assert(#whoCalls==0)
                ''')
                self.check("not NS.Scanner:GetStatus().running" if stop else "NS.Scanner:GetStatus().paused")

    def test_environment_hold_keeps_outstanding_reply_and_cooldown(self):
        """Verifies that environment hold keeps outstanding reply and cooldown."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=20}))")
        self.harness.execute('''
            combatLockdown=true; instanceKind="pvp"; Emit("PLAYER_REGEN_DISABLED")
            assert(NS.Scanner:GetStatus().awaiting)
            Deliver({{fullName="Owned",level=5}})
            assert(NS.Scanner:GetStatus().completedQueries==1 and NS.Scanner:GetStatus().remainingQueries==1)
            assert(BatataScanner.CountPlayers()==1 and NS.Scanner:GetStatus().cooldown==6)
            assert(LFGWhoListFrame:IsEventRegistered("WHO_LIST_UPDATE") and not whoRouting)
            Advance(6)
            Click(function() assert(not NS.Scanner:Continue()) end)
            combatLockdown=false; instanceKind="none"; Emit("PLAYER_REGEN_ENABLED")
            assert(#whoCalls==1 and not NS.Scanner:GetStatus().incomplete)
            Click(function() assert(NS.Scanner:Continue()) end)
            assert(#whoCalls==2 and whoCalls[2]=="11-20")
        ''')

    def test_environment_is_rechecked_without_events_and_non_battlegrounds_are_allowed(self):
        """Verifies that environment is rechecked without events and non battlegrounds are allowed."""
        for instance_kind in ("none", "party", "raid", "arena", "scenario"):
            with self.subTest(instance_kind=instance_kind):
                self.harness = Harness(setup=SCANNER_SETUP + f'instanceKind="{instance_kind}"')
                self.harness.execute('''
                    combatLockdown=true
                    Click(function() assert(not NS.Scanner:Continue()) end)
                    combatLockdown=false
                    Click(function() assert(NS.Scanner:Continue()) end)
                    assert(#whoCalls==1 and not NS.Scanner:GetStatus().inBattleground)
                ''')

    def test_environment_failures_hold_dispatch_until_a_readable_state_returns(self):
        """Verifies that environment failures hold dispatch until a readable state returns."""
        for broken_api in (
            "UnitAffectingCombat=nil",
            "UnitAffectingCombat=function() return {secret=true} end",
            "InCombatLockdown=nil",
            "InCombatLockdown=function() error('unavailable') end",
            "InCombatLockdown=function() return nil end",
            "InCombatLockdown=function() return {secret=true} end",
            "IsInInstance=nil",
            "IsInInstance=function() error('unavailable') end",
            "IsInInstance=function() return false,nil end",
            "IsInInstance=function() return {secret=true},'none' end",
            "IsInInstance=function() return false,{secret=true} end",
        ):
            with self.subTest(broken_api=broken_api):
                self.harness = Harness(setup=SCANNER_SETUP + broken_api)
                self.harness.click("assert(not NS.Scanner:Continue())")
                self.check("NS.Scanner:GetStatus().environmentUnavailable and #whoCalls==0")
                self.harness.execute('''
                    InCombatLockdown=function() return false end
                    UnitAffectingCombat=function() return false end
                    IsInInstance=function() return false,"none" end
                    Emit("PLAYER_ENTERING_WORLD",false,true)
                    assert(#whoCalls==0 and not NS.Scanner:GetStatus().environmentUnavailable)
                    Click(function() assert(NS.Scanner:Continue()) end)
                    assert(#whoCalls==1)
                ''')

    def test_passive_observations_continue_during_combat_and_battleground_holds(self):
        """Verifies that passive observations continue during combat and battleground holds."""
        self.harness.execute('''
            combatLockdown=true; instanceKind="pvp"
            UnitExists=function(unit) return unit=="target" end
            UnitIsPlayer=function() return true end
            UnitNameUnmodified=function() return "Passive Observer" end
            UnitLevel=function() return 30 end
            GetGuildInfo=function() return "" end
            UnitGUID=function() return "Player-Passive" end
            Emit("PLAYER_REGEN_DISABLED")
            Emit("ZONE_CHANGED_NEW_AREA")
            Emit("PLAYER_TARGET_CHANGED")
            Click(function() assert(not NS.Scanner:Start()) end)
            Advance(1)
            assert(BatataScanner.GetPlayer("Passive Observer").level==30)
            assert(#whoCalls==0 and NS.Scanner:GetStatus().inCombat and NS.Scanner:GetStatus().inBattleground)
        ''')

    def test_native_who_blocks_start_restart_and_slash_dispatch(self):
        """Verifies that native who blocks start restart and slash dispatch."""
        self.harness.execute("LFGWhoListFrame:Show()")
        self.harness.click("assert(not NS.Scanner:Start({minLevel=1,maxLevel=20}))")
        self.check("NS.Scanner:GetStatus().running and NS.Scanner:GetStatus().remainingQueries==2")
        self.harness.click("assert(not NS.Scanner:Restart())")
        self.harness.click("SlashCmdList.BATATASCANNER('next')")
        self.harness.click("SlashCmdList.BATATASCANNER('scan')")
        self.check("#whoCalls==0 and not NS.Scanner:GetStatus().awaiting")
        self.check("LFGWhoListFrame:IsEventRegistered('WHO_LIST_UPDATE') and not whoRouting")

    def test_native_who_hold_is_not_saved_as_a_manual_pause(self):
        """Verifies that native who hold is not saved as a manual pause."""
        self.harness.execute("LFGWhoListFrame:Show()")
        self.harness.click("assert(not NS.Scanner:Start({minLevel=1,maxLevel=20}))")
        self.harness.execute("Emit('PLAYER_LOGOUT')")
        self.check("BatataScanner_DB.scanner.running and not BatataScanner_DB.scanner.paused")
        self.check("BatataScanner_DB.scanner.nativeWhoOpen==nil")
        self.reload()
        self.check("NS.Scanner:GetStatus().running and not NS.Scanner:GetStatus().nativeWhoOpen")
        self.harness.advance(30)
        self.check("#whoCalls==0")
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.check("#whoCalls==1 and whoCalls[1]=='1-10'")

    def test_native_who_preserves_manual_pause_before_or_during_the_hold(self):
        """Verifies that native who preserves manual pause before or during the hold."""
        for pause_before_open in (True, False):
            with self.subTest(pause_before_open=pause_before_open):
                self.harness = Harness(setup=SCANNER_SETUP)
                if pause_before_open:
                    self.harness.execute("NS.Scanner:Pause()")
                self.harness.execute("LFGWhoListFrame:Show()")
                if not pause_before_open:
                    self.harness.execute("NS.Scanner:Pause()")
                self.harness.click("assert(not NS.Scanner:Continue())")
                self.harness.execute("LFGWhoListFrame:Hide()")
                self.check("NS.Scanner:GetStatus().paused")
                self.reload()
                self.harness.advance(30)
                self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
                self.check("NS.Scanner:GetStatus().paused and #whoCalls==0")

    def test_native_who_opened_mid_query_keeps_the_owned_reply(self):
        """Verifies that native who opened mid query keeps the owned reply."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=20}))")
        self.harness.execute("LFGWhoListFrame:Show(); C_FriendList.SetWhoToUi(true)")
        self.check("NS.Scanner:GetStatus().awaiting and NS.Scanner:GetStatus().nativeWhoOpen")
        self.harness.execute("Deliver({{fullName='Owned',level=5}})")
        self.check("BatataScanner.CountPlayers()==1 and NS.Scanner:GetStatus().completedQueries==1")
        self.check("LFGWhoListFrame:IsEventRegistered('WHO_LIST_UPDATE') and whoRouting")
        self.harness.advance(6)
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.check("#whoCalls==1 and not NS.Scanner:GetStatus().paused")
        self.harness.execute("NS.Scanner:Stop(); LFGWhoListFrame:Hide()")
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.check("#whoCalls==1 and NS.Scanner:GetStatus().state=='stopped'")

    def test_late_loaded_native_who_hooks_preserve_scripts_and_install_once(self):
        """Verifies that late loaded native who hooks preserve scripts and install once."""
        self.harness = Harness(setup=SCANNER_SETUP + "LFGWhoListFrame=nil; WhoFrame=nil")
        self.harness.execute('''
            nativeHookCount=0
            nativeShowCount=0
            nativeHideCount=0
            LFGWhoListFrame=CreateFrame("Frame","LFGWhoListFrame")
            LFGWhoListFrame:RegisterEvent("WHO_LIST_UPDATE")
            LFGWhoListFrame:SetScript("OnShow",function()
                nativeShowCount=nativeShowCount+1
            end)
            LFGWhoListFrame:SetScript("OnHide",function()
                nativeHideCount=nativeHideCount+1
            end)
            local originalHook=LFGWhoListFrame.HookScript
            function LFGWhoListFrame:HookScript(scriptName,callback)
                nativeHookCount=nativeHookCount+1
                originalHook(self,scriptName,callback)
            end
            Emit("ADDON_LOADED","Blizzard_GroupFinder_VanillaStyle")
            Emit("ADDON_LOADED","Blizzard_GroupFinder_VanillaStyle")
            LFGWhoListFrame:Hide()
            LFGWhoListFrame:Show()
        ''')
        self.check("nativeHookCount==2 and nativeShowCount==1 and nativeHideCount==1")
        self.check("NS.Scanner:GetStatus().nativeWhoOpen and #whoCalls==0")
        self.harness.click("assert(not NS.Scanner:Continue())")
        self.check("LFGWhoListFrame:IsEventRegistered('WHO_LIST_UPDATE') and #whoCalls==0")

    def test_external_query_and_native_visibility_holds_clear_independently(self):
        """Verifies that external query and native visibility holds clear independently."""
        for hide_before_reply in (True, False):
            with self.subTest(hide_before_reply=hide_before_reply):
                self.harness = Harness(setup=SCANNER_SETUP)
                self.harness.execute("LFGWhoListFrame:Show(); Enum.SocialWhoOrigin.Chat=2")
                self.harness.click("C_FriendList.SendWho('5-5',Enum.SocialWhoOrigin.Chat)")
                if hide_before_reply:
                    self.harness.execute("LFGWhoListFrame:Hide()")
                self.harness.advance(6)
                self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
                self.check("#whoCalls==1 and NS.Scanner:GetStatus().externalQueryPending")
                self.harness.execute("Deliver({{fullName='External',level=5}})")
                self.check("not NS.Scanner:GetStatus().externalQueryPending and BatataScanner.CountPlayers()==0")
                if not hide_before_reply:
                    self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
                    self.check("#whoCalls==1 and NS.Scanner:GetStatus().nativeWhoOpen")
                    self.harness.execute("LFGWhoListFrame:Hide()")
                self.harness.advance(30)
                self.check("#whoCalls==1 and not NS.Scanner:GetStatus().paused")
                self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
                self.check("#whoCalls==2")

    def test_repeated_external_queries_discard_all_replies_until_cooldown_ends(self):
        """Verifies that repeated external queries discard all replies until cooldown ends."""
        self.harness = Harness(setup=SCANNER_SETUP)
        self.harness.click("C_FriendList.SendWho('5-5')")
        self.harness.click("C_FriendList.SendWho('1-10')")
        self.check("NS.Scanner:GetStatus().pendingLateResponse and NS.Scanner:GetStatus().incomplete")
        self.check("not NS.Scanner:GetStatus().blockedUntilReload and NS.Scanner:GetStatus().running")
        self.harness.emit("CHAT_MSG_SYSTEM", "You must wait a moment longer before using /who again")
        self.harness.execute("Deliver({{fullName='External',level=5}})")
        self.harness.advance(5)
        self.harness.execute("LFGWhoListFrame:Show(); LFGWhoListFrame:Hide()")
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.harness.execute("Deliver({{fullName='OtherExternal',level=5}})")
        self.check("NS.Scanner:GetStatus().pendingLateResponse and #whoCalls==2")
        self.check("BatataScanner.CountPlayers()==0")
        self.harness.advance(5)
        self.check("not NS.Scanner:GetStatus().pendingLateResponse and #whoCalls==2")
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.check("#whoCalls==3")

    def test_native_who_visibility_holds_dispatch_until_the_next_click(self):
        """Verifies that native who visibility holds dispatch until the next click."""
        for frame_name in ("LFGWhoListFrame", "WhoFrame"):
            with self.subTest(frame_name=frame_name):
                self.harness = Harness(setup=STOPPED_SETUP)
                self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=30}))")
                self.harness.execute("Deliver({})")
                self.harness.advance(6)
                self.harness.execute(f"{frame_name}:Show()")
                self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
                self.check("#whoCalls==1")
                self.harness.click("assert(not NS.Scanner:Continue())")
                self.check("NS.Scanner:GetStatus().nativeWhoOpen and not NS.Scanner:GetStatus().paused")
                self.check("NS.Scanner:GetStatus().remainingQueries==2 and not NS.Scanner:GetStatus().awaiting")
                self.check("LFGWhoListFrame:IsEventRegistered('WHO_LIST_UPDATE') and not whoRouting")
                self.harness.execute(f"{frame_name}:Hide()")
                self.harness.advance(30)
                self.check("#whoCalls==1 and not NS.Scanner:GetStatus().nativeWhoOpen")
                self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
                self.check("#whoCalls==2 and whoCalls[2]=='11-20'")

    def test_world_click_dispatch_respects_cooldown_and_pause(self):
        """Verifies that world click dispatch respects cooldown and pause."""
        self.check("NS.db.settings.queryInterval==6")
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=30}))")
        self.harness.execute("Deliver({})")
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.check("#whoCalls==1")
        self.harness.advance(5)
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.check("#whoCalls==1 and NS.Scanner:GetStatus().cooldown==1")
        self.harness.click("assert(not NS.Scanner:Continue())")
        self.harness.advance(1)
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.check("#whoCalls==2")
        self.harness.execute("Deliver({}); NS.Scanner:Pause()")
        self.harness.advance(6)
        self.harness.click("WorldFrame:GetScript('OnMouseDown')(WorldFrame)")
        self.check("#whoCalls==2")

    def test_malformed_levels_are_omitted_instead_of_clamped(self):
        """Verifies that malformed levels are omitted instead of clamped."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=10}))")
        self.harness.execute('''
            Deliver({{fullName="Zero",level=0},{fullName="Infinite",level=math.huge},
                     {fullName="Fraction",level=1.5},{fullName="Valid",level=5}})
        ''')
        self.check("BatataScanner.CountPlayers()==1 and NS.Scanner:GetStatus().incomplete")
        self.check("BatataScanner.GetPlayer('Valid')~=nil")

    def test_invalid_result_counts_pause_without_accepting_a_response(self):
        """Verifies that invalid result counts pause without accepting a response."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=10}))")
        self.harness.execute('''
            C_FriendList.GetNumWhoResults=function() return -1,100 end
            Deliver({{fullName="Player",level=5}})
        ''')
        self.check("NS.Scanner:GetStatus().paused and NS.Scanner:GetStatus().completedQueries==0")
        self.check("BatataScanner.CountPlayers()==0")

    def test_native_routing_changes_during_wait_are_preserved(self):
        """Verifies that native routing changes during wait are preserved."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=10}))")
        self.harness.execute("C_FriendList.SetWhoToUi(true); Deliver({})")
        self.check("whoRouting and LFGWhoListFrame:IsEventRegistered('WHO_LIST_UPDATE')")

    def test_newly_loaded_native_who_listener_is_restored(self):
        """Verifies that newly loaded native who listener is restored."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=1,maxLevel=10}))")
        self.harness.execute("WhoFrame:RegisterEvent('WHO_LIST_UPDATE'); Emit('ADDON_LOADED','Blizzard_Who')")
        self.check("not WhoFrame:IsEventRegistered('WHO_LIST_UPDATE')")
        self.harness.execute("Deliver({})")
        self.check("WhoFrame:IsEventRegistered('WHO_LIST_UPDATE')")

    def test_new_player_count_matches_store_name_case_rules(self):
        """Verifies that new player count matches store name case rules."""
        self.harness.click("assert(NS.Scanner:Start({minLevel=5,maxLevel=5}))")
        self.harness.execute("Deliver({{fullName='First Last',level=5,raceStr='Dwarf'}},100)")
        self.harness.advance(6)
        self.harness.click("assert(NS.Scanner:Continue())")
        self.harness.execute("Deliver({{fullName='FIRST LAST',level=5,raceStr='Dwarf'}})")
        self.check("NS.Scanner:GetStatus().newPlayers==1 and BatataScanner.CountPlayers()==1")

    def test_sweep_query_budget_is_bounded_and_reported(self):
        """Verifies that sweep query budget is bounded and reported."""
        self.harness.click("NS.Scanner:Start({minLevel=1,maxLevel=255})")
        self.harness.execute('''
            for index=1,600 do
                local status=NS.Scanner:GetStatus()
                if not status.running then break end
                local query=whoCalls[#whoCalls]
                local minimum=query:match("(%d+)%-%d+$")
                local race=query:match('r-"([^"]+)"') or "Human"
                local class=query:match('c-"([^"]+)"') or "Mage"
                Deliver({{fullName="Player"..index,level=tonumber(minimum),raceStr=race,classStr=class}},100)
                clock=clock+6
                if NS.Scanner:GetStatus().running then Click(function() NS.Scanner:Continue() end) end
            end
        ''')
        self.check("#whoCalls<=500 and not NS.Scanner:GetStatus().running and NS.Scanner:GetStatus().incomplete")


if __name__ == "__main__":
    unittest.main()
