import unittest

from harness import Harness, ROOT


# Exercises read-only facade behavior against actual addon modules in the Lua mock.
class ReadOnlyAPITests(unittest.TestCase):
    """Checks the detached, read-only consumer API contract."""
    def setUp(self):
        """Creates a fresh test fixture before each test."""
        self.harness = Harness()
        self.lua = self.harness.lua

    def test_ready_metadata_and_no_mutation_surface(self):
        """Verifies that ready metadata and no mutation surface."""
        self.harness.execute('''
            assert(Batata_Scanner.IsReady())
            assert(Batata_Scanner.GetVersion()=="1.0.0")
            assert(Batata_Scanner.GetAPIVersion()==1)
            assert(Batata_Scanner.GetVersion()==TOC_VERSION)
            assert(Batata_Scanner.GetAPIVersion()==tonumber(TOC_METADATA["X-API-Version"]))
            assert(Batata_Scanner.Observe==nil and Batata_Scanner.Store==nil and Batata_Scanner.Scanner==nil)
            assert(Batata_Scanner.db==nil and Batata_Scanner.SetPlayer==nil and Batata_Scanner.Start==nil)
            assert(not pcall(function() Batata_Scanner.GetPlayer=function() end end))
            assert(not pcall(function() setmetatable(Batata_Scanner,{}) end))
        ''')

    def test_incompatible_saved_database_resets_to_schema_one(self):
        """Verifies incompatible pre-release data resets to initial schema defaults."""
        harness = Harness(setup='''
            Batata_Scanner_DB={schemaVersion=6,settings={minLevel=30},players={
                {"Old Player","Alliance",30,false,false,false,1,2,false}
            }}
        ''')
        harness.execute('''
            assert(Batata_Scanner.IsReady())
            assert(Batata_Scanner_DB.schemaVersion==1)
            assert(Batata_Scanner.CountPlayers()==0)
            assert(NS.db.settings.minLevel==1)
            assert(NS.db.settings.queryInterval==15)
        ''')

    def test_all_nested_results_are_detached(self):
        """Verifies that all nested results are detached."""
        self.harness.execute('''
            NS.Store:Observe({name="Alice Stone",level=31,class="MAGE",guild="Guild",race="Human"},"who")
            local player=Batata_Scanner.GetPlayer("alice stone")
            player.guild="Edited"
            local page=Batata_Scanner.FindPlayers()
            page.players[1].name="Edited"
            local census=Batata_Scanner.GetCensus()
            census.total=500;census.byClass.Mage=999
            local context=Batata_Scanner.GetContext();context.faction="Edited"
            local status=Batata_Scanner.GetScanStatus();status.state="Edited"
            local actual=Batata_Scanner.GetPlayer("Alice Stone")
            assert(actual.name=="Alice Stone" and actual.guild=="Guild" and actual.sources==nil)
            assert(Batata_Scanner_DB.players["alice stone"].sources==nil and Batata_Scanner_DB.scopes==nil)
            assert(Batata_Scanner.GetCensus().total==1 and Batata_Scanner.GetCensus().byClass.Mage==1)
            assert(Batata_Scanner.GetCensus().context==nil)
            assert(Batata_Scanner.GetContext().faction=="Alliance" and Batata_Scanner.GetContext().realm==nil)
            assert(actual.realm==nil)
            assert(Batata_Scanner.GetScanStatus().state~="Edited")
        ''')

    def test_native_who_status_is_detached_and_notifies_visibility_changes(self):
        """Verifies that native who status is detached and notifies visibility changes."""
        self.harness.execute('''
            local original=Batata_Scanner.GetScanStatus()
            assert(original.nativeWhoOpen==false)
            local observedStates={}
            local token=Batata_Scanner.RegisterCallback("SCAN_STATUS_CHANGED",function(eventName,revision)
                assert(eventName=="SCAN_STATUS_CHANGED" and type(revision)=="number")
                observedStates[#observedStates+1]=Batata_Scanner.GetScanStatus()
            end)
            LFGWhoListFrame:Show()
            assert(#observedStates==1 and observedStates[1].nativeWhoOpen==true)
            assert(observedStates[1].state==original.state and observedStates[1].paused==original.paused)
            assert(observedStates[1].reason==original.reason)
            observedStates[1].nativeWhoOpen=false
            assert(Batata_Scanner.GetScanStatus().nativeWhoOpen==true)
            LFGWhoListFrame:Hide()
            assert(#observedStates==2 and observedStates[2].nativeWhoOpen==false)
            assert(Batata_Scanner.UnregisterCallback(token))
            assert(#whoCalls==0 and #errors==0)
        ''')

    def test_environment_status_is_detached_and_notifies_without_dispatching(self):
        """Verifies that environment status is detached and notifies without dispatching."""
        self.harness.execute('''
            local original=Batata_Scanner.GetScanStatus()
            assert(original.inCombat==false and original.inBattleground==false)
            assert(original.environmentUnavailable==false)
            local observedStates={}
            local token=Batata_Scanner.RegisterCallback("SCAN_STATUS_CHANGED",function(eventName,revision)
                assert(eventName=="SCAN_STATUS_CHANGED" and type(revision)=="number")
                observedStates[#observedStates+1]=Batata_Scanner.GetScanStatus()
            end)
            playerCombat=true; instanceKind="pvp"
            Emit("PLAYER_REGEN_DISABLED")
            assert(#observedStates==1 and observedStates[1].inCombat and observedStates[1].inBattleground)
            assert(observedStates[1].state==original.state and observedStates[1].paused==original.paused)
            observedStates[1].inCombat=false
            observedStates[1].inBattleground=false
            observedStates[1].environmentUnavailable=true
            local actual=Batata_Scanner.GetScanStatus()
            assert(actual.inCombat and actual.inBattleground and not actual.environmentUnavailable)
            playerCombat=false
            Emit("PLAYER_REGEN_ENABLED")
            assert(#observedStates==2 and not observedStates[2].inCombat and observedStates[2].inBattleground)
            instanceKind="none"; IsInInstance=nil
            Emit("ZONE_CHANGED_NEW_AREA")
            assert(#observedStates==3 and observedStates[3].environmentUnavailable)
            IsInInstance=function() return false,"none" end
            Emit("PLAYER_ENTERING_WORLD",false,false)
            assert(#observedStates==4 and not observedStates[4].environmentUnavailable)
            assert(not original.inCombat and not original.inBattleground)
            assert(Batata_Scanner.UnregisterCallback(token))
            assert(#whoCalls==0 and #errors==0)
        ''')

    def test_start_held_by_native_who_notifies_the_prepared_sweep(self):
        """Verifies that start held by native who notifies the prepared sweep."""
        self.harness.execute('''
            NS.Scanner:Stop()
            LFGWhoListFrame:Show()
            local observedStatus
            local token=Batata_Scanner.RegisterCallback("SCAN_STATUS_CHANGED",function(eventName,revision)
                observedStatus=Batata_Scanner.GetScanStatus()
            end)
            Click(function()
                assert(not NS.Scanner:Start({minLevel=1,maxLevel=20}))
            end)
            assert(observedStatus and observedStatus.running and observedStatus.nativeWhoOpen)
            assert(observedStatus.remainingQueries==2 and not observedStatus.awaiting)
            assert(Batata_Scanner.UnregisterCallback(token))
            assert(#whoCalls==0 and #errors==0)
        ''')

    def test_guild_tristate_and_case_insensitive_full_identity(self):
        """Verifies that guild tristate and case insensitive full identity."""
        self.harness.execute('''
            NS.Store:Observe({name="  Alice   Stone-Hill  ",level=20},"passive")
            assert(Batata_Scanner.GetCensus().unknownGuild==1)
            NS.Store:Observe({name="alice stone-hill",guild=""},"who")
            assert(Batata_Scanner.CountPlayers()==1 and Batata_Scanner.GetCensus().unguilded==1)
            NS.Store:Observe({name="Alice Stone-Hill",level=21},"passive")
            local record=Batata_Scanner.GetPlayer("ALICE STONE-HILL")
            assert(record.guild=="" and record.level==21)
            NS.Store:Observe({name="Alice Stone-Hill",guild="New Guild"},"who")
            assert(Batata_Scanner.GetCensus().guilded==1)
        ''')

    def test_pagination_sort_filters_counts_and_aggregates_agree(self):
        """Verifies that pagination sort filters counts and aggregates agree."""
        self.harness.execute('''
            for playerIndex=1,53 do
                NS.Store:Observe({name=string.format("Player %03d",playerIndex),level=playerIndex,
                    class=playerIndex%2==0 and "MAGE" or "DRUID",guild=playerIndex%2==0 and "" or "Guild",
                    race="Human",zone="Town"},"who")
            end
            local filters={class="Mage",minLevel=10,maxLevel=40,zone="Town",guild=""}
            local first=Batata_Scanner.FindPlayers(filters,{sort="level",descending=true,limit=5})
            local second=Batata_Scanner.FindPlayers(filters,{sort="level",descending=true,limit=5,offset=5})
            assert(first.total==16 and #first.players==5 and first.hasMore)
            assert(first.players[1].level==40 and second.players[1].level==30)
            assert(Batata_Scanner.CountPlayers(filters)==16 and Batata_Scanner.GetCensus(filters).total==16)
            assert(Batata_Scanner.GetCensus(filters).unguilded==16)
            assert(Batata_Scanner.CountPlayers({name="Player 0"})==53)
            assert(Batata_Scanner.CountPlayers({name=".*"})==0)
            assert(#Batata_Scanner.FindPlayers(nil,{offset=1000}).players==0)
        ''')

    def test_first_seen_and_faction_sorts(self):
        """Verifies that first seen and faction sorts."""
        self.harness.execute('''
            NS.Store:Observe({name="Zed"})
            epoch=epoch+60
            local original=NS.context
            NS.context={faction="Horde",key="Horde"}
            NS.Store:Observe({name="Amy"})
            NS.context=original
            local byFirstSeen=Batata_Scanner.FindPlayers(nil,{sort="firstSeen"})
            assert(byFirstSeen.players[1].name=="Zed" and byFirstSeen.players[2].name=="Amy")
            local byFaction=Batata_Scanner.FindPlayers(nil,{sort="faction",descending=true})
            assert(byFaction.players[1].faction=="Horde" and byFaction.players[2].faction=="Alliance")
        ''')

    def test_read_apis_do_not_write_saved_data(self):
        """Verifies that read apis do not write saved data."""
        self.harness.execute('''
            NS.Store:Observe({name="Alice",level=10},"who")
            function Fingerprint(value)
                if type(value)~="table" then return type(value)..":"..tostring(value) end
                local keys={};for key in pairs(value) do keys[#keys+1]=key end
                table.sort(keys,function(left,right) return tostring(left)<tostring(right) end)
                local parts={};for position,key in ipairs(keys) do
                    parts[#parts+1]=Fingerprint(key).."="..Fingerprint(value[key])
                end
                return "{"..table.concat(parts,";").."}"
            end
            local before=Fingerprint(Batata_Scanner_DB)
            Batata_Scanner.GetPlayer("Alice");Batata_Scanner.GetCensus();Batata_Scanner.FindPlayers()
            Batata_Scanner.CountPlayers();Batata_Scanner.GetContext();Batata_Scanner.GetScanStatus()
            assert(before==Fingerprint(Batata_Scanner_DB))
        ''')

    def test_retention_defaults_to_disabled_and_preserves_unknown_and_boundary_dates(self):
        """Verifies that retention defaults to disabled and preserves unknown and boundary dates."""
        self.harness.execute('''
            NS.Store:Observe({name="Old",guild="Former",race="Human",class="MAGE"})
            epoch=epoch+86400
            NS.Store:Observe({name="Boundary",guild="",race="Dwarf",class="WARRIOR"})
            epoch=epoch+30*86400
            NS.Store:Observe({name="Current",race="Human",class="MAGE"})
            NS.db.players.unknown={name="Unknown"}
            NS.db.players=NS.Store:Load(NS.db.players)
            assert(NS.db.settings.retentionDays==0 and NS.Store:PruneExpired()==0)
            assert(Batata_Scanner.CountPlayers()==4)
            NS.db.settings.retentionDays=30
            local revision=NS.db.revision
            assert(NS.Store:PruneExpired()==1 and NS.db.revision==revision+1)
            assert(Batata_Scanner.GetPlayer("Old")==nil and Batata_Scanner.GetPlayer("Unknown"))
            assert(Batata_Scanner.GetPlayer("Boundary") and Batata_Scanner.CountPlayers()==3)
            local census=Batata_Scanner.GetCensus()
            local overview=NS.Store:GetCensusOverview()
            assert(census.total==3 and overview.total==3 and overview.byGuild.Former==nil)
            assert(overview.byClass.Mage==1 and overview.byClass.Warrior==1)
            assert(NS.Store:PruneExpired()==0 and NS.db.revision==revision+1)
            assert(Batata_Scanner.PruneExpired==nil)
        ''')

    def test_retention_preserves_running_snapshots_and_reobserved_identities(self):
        """Verifies that retention preserves running snapshots and reobserved identities."""
        self.harness.execute('''
            NS.Store:Observe({name="Old",level=10,class="MAGE"})
            local originalContext=NS.context
            NS.context={faction="Horde",key="Horde"}
            NS.Store:Observe({name="Other",level=20,class="WARRIOR"})
            NS.context=originalContext
            local request=NS.Store:CreateSearch("", "name")
            epoch=epoch+31*86400
            NS.Store:Observe({name="Current",level=30})
            Batata_Scanner.FindPlayers()
            NS.db.settings.retentionDays=30
            assert(NS.Store:PruneExpired()==2)
            NS.Store:Observe({name="Old",level=40})
            while not request:Step() do end
            assert(request.total==2 and request:GetPlayer(1).level==10)
            assert(request:GetPlayer(2).name=="Other")
            local fresh=NS.Store:CreateSearch("", "name")
            while not fresh:Step() do end
            assert(fresh.total==2 and fresh:GetPlayer(1).name=="Current")
            assert(fresh:GetPlayer(2).name=="Old" and fresh:GetPlayer(2).level==40)
            assert(Batata_Scanner.CountPlayers({faction="Horde"})==0)
            local census=NS.Store:GetCensusOverview("Horde")
            assert(census.total==0 and next(census.byClass)==nil)
            assert(Batata_Scanner.FindPlayers().total==2)
        ''')

    def test_retention_runs_on_load_and_logout_and_invalid_settings_preserve_history(self):
        """Verifies that retention runs on load and logout and invalid settings preserve history."""
        for retention_value, expected_count in (("30", 1), ("0", 2), ("false", 2), ("-1", 2)):
            with self.subTest(retention=retention_value):
                harness = Harness(setup='''
                    Batata_Scanner_DB={schemaVersion=1,settings={retentionDays=%s},players={
                        {name="Old",lastSeen=epoch-31*86400,faction="Alliance"},
                        {name="Recent",lastSeen=epoch,faction="Horde"}
                    }}
                ''' % retention_value)
                self.assertEqual(harness.execute("return Batata_Scanner.CountPlayers()"), expected_count)
                harness.execute('''
                    NS.db.settings.retentionDays=30
                    epoch=epoch+31*86400
                    Emit("PLAYER_LOGOUT")
                    assert(#Batata_Scanner_DB.players==0)
                ''')

    def test_players_of_both_factions_share_one_collection(self):
        """Verifies that players of both factions share one collection."""
        self.harness.execute('''
            NS.Store:Observe({name="Alice",level=10},"who")
            local original=NS.context
            NS.context={faction="Horde",key="Horde"}
            NS.Store:Observe({name="Bob",level=30},"who")
            NS.context=original
            assert(Batata_Scanner.GetPlayer("Bob").faction=="Horde" and Batata_Scanner.GetPlayer("Alice").level==10)
            assert(Batata_Scanner.CountPlayers()==2 and Batata_Scanner.GetCensus().total==2)
            assert(Batata_Scanner.CountPlayers({faction="Horde"})==1)
            assert(Batata_Scanner.GetCensus({faction="Alliance"}).total==1)
            local search=NS.Store:CreateSearch("","name",false,{faction="Alliance"})
            while not search:Step() do end
            assert(search.total==1 and search:GetPlayer(1).name=="Alice")
            assert(not pcall(Batata_Scanner.CountPlayers,{realm="Test Realm"}))
            assert(Batata_Scanner_DB.players.bob.faction=="Horde")
        ''')

    def test_legacy_schema_one_scopes_reset_to_initial_database(self):
        """Verifies legacy schema-one scopes reset to the initial database."""
        harness = Harness(setup='''
            Batata_Scanner_DB={schemaVersion=1,revision=7,scopes={
                ["6:Realm1:Alliance"]={realm="Realm1",faction="Alliance",revision=3,players={
                    alice={name="Alice",realm="Realm1",faction="Alliance",level=10,guild="Old",
                        firstSeen=100,lastSeen=200,sources={who=true}}}},
                ["6:Realm2:Alliance"]={realm="Realm2",faction="Alliance",revision=5,players={
                    alice={name="Alice",realm="Realm2",faction="Alliance",level=20,
                        firstSeen=150,lastSeen=300,sources={passive=true}},
                    bob={name="Bob",realm="Realm2",faction="Alliance",firstSeen=1,lastSeen=2,sources={}}}},
                ["6:Realm1:Horde"]={realm="Realm1",faction="Horde",players={
                    carl={name="Carl",realm="Realm1",faction="Horde",firstSeen=1,lastSeen=2,sources={}}}}}}
        ''')
        harness.execute('''
            assert(Batata_Scanner_DB.schemaVersion==1 and Batata_Scanner_DB.scopes==nil)
            assert(Batata_Scanner.CountPlayers()==0 and NS.db.revision==0)
        ''')

    def test_legacy_schema_four_scopes_reset_to_initial_database(self):
        """Verifies legacy schema-four scopes reset to the initial database."""
        harness = Harness(setup='''
            Batata_Scanner_DB={schemaVersion=4,revision=9,scopes={
                Alliance={faction="Alliance",revision=4,players={
                    alice={name="Alice",faction="Alliance",level=10,guild="Old",firstSeen=100,lastSeen=200},
                    bob={name="Bob",faction="Alliance",level=5,firstSeen=1,lastSeen=2}}},
                Horde={faction="Horde",revision=5,players={
                    alice={name="Alice",faction="Horde",level=20,firstSeen=150,lastSeen=300}}}}}
        ''')
        harness.execute('''
            assert(Batata_Scanner_DB.schemaVersion==1 and Batata_Scanner_DB.scopes==nil)
            assert(Batata_Scanner.CountPlayers()==0 and NS.db.revision==0)
        ''')

    def test_legacy_schema_three_scopes_reset_to_initial_database(self):
        """Verifies legacy schema-three scopes reset to the initial database."""
        harness = Harness(setup='''
            Batata_Scanner_DB={schemaVersion=3,scopes={Alliance={faction="Alliance",revision=1,players={
                ["ashley cutie"]={name="Ashley Cutie",faction="Alliance",class="PRIEST",className="Priest"},
                alice={name="Alice",faction="Alliance",class="MAGE"},
                bob={name="Bob",faction="Alliance"}}}}}
        ''')
        harness.execute('''
            assert(Batata_Scanner_DB.schemaVersion==1 and Batata_Scanner_DB.scopes==nil)
            assert(Batata_Scanner.CountPlayers()==0 and NS.db.revision==0)
        ''')

    def test_rejects_bad_filters_and_page_sizes(self):
        """Verifies that rejects bad filters and page sizes."""
        self.harness.execute('''
            for position,options in ipairs({{limit=0},{limit=501},{limit=-1},{limit=1.5},{offset=-1},
                {offset=math.huge},{sort="password"},{descending="yes"},{limit=false},{offset=false},
                {sort=false},{unknown=true},{limit={secret=true}},{descending={secret=true}}}) do
                assert(not pcall(Batata_Scanner.FindPlayers,nil,options))
            end
            for position,filters in ipairs({{minLevel=0},{minLevel=256},{maxLevel=1,minLevel=2},
                {seenAfter=-1},{unknown="x"},{class={secret=true}},{faction="invalid"},{faction=""}}) do
                assert(not pcall(Batata_Scanner.FindPlayers,filters))
                assert(not pcall(Batata_Scanner.CountPlayers,filters))
                assert(not pcall(Batata_Scanner.GetCensus,filters))
            end
            local defaults=Batata_Scanner.FindPlayers(nil,{offset=0,descending=false})
            assert(defaults.offset==0 and defaults.limit==100)
        ''')

    def test_unreadable_observations_skipped_without_losing_known_values(self):
        """Verifies that unreadable observations skipped without losing known values."""
        self.harness.execute('''
            NS.Store:Observe({name="Alice",level=10,guild="Guild"},"who")
            NS.Store:Observe({name={secret=true},level=30},"who")
            NS.Store:Observe({name="Hidden",inaccessible=true},"who")
            NS.Store:Observe({name="Alice",guild={secret=true},level={secret=true}},"passive")
            assert(Batata_Scanner.CountPlayers()==1)
            assert(Batata_Scanner.GetPlayer("Alice").guild=="Guild")
            assert(Batata_Scanner.GetPlayer("Alice").level==10)
        ''')

    def test_notifications_coalesce_and_errors_are_isolated(self):
        """Verifies that notifications coalesce and errors are isolated."""
        self.harness.execute('''
            received=0
            Batata_Scanner.RegisterCallback("DATA_UPDATED",function() error("consumer failure") end)
            token=Batata_Scanner.RegisterCallback("DATA_UPDATED",function(event,revision)
                assert(event=="DATA_UPDATED" and revision>0);received=received+1
            end)
            NS.Store:BeginBatch()
            for position=1,50 do NS.Store:Observe({name="Player "..position},"who") end
            NS.Store:EndBatch()
            assert(received==0)
        ''')
        self.harness.advance(0.3)
        self.harness.execute('''
            assert(received==1 and #errors==1)
            assert(Batata_Scanner.UnregisterCallback(token))
            assert(not Batata_Scanner.UnregisterCallback(token))
            assert(not pcall(Batata_Scanner.RegisterCallback,"WRITE",function() end))
        ''')

    def test_schema_one_values_survive_and_incompatible_schema_resets(self):
        """Verifies schema-one values survive and incompatible schemas reset."""
        harness = Harness(setup='''
            Batata_Scanner_DB={schemaVersion=1,settings={passiveEnabled=false,worldClickEnabled=false,minLevel=10,
                myFactionOnly=true},players={keep={name="Keep",faction="Horde"}},unknownField="preserve"}
        ''')
        harness.execute('''
            assert(NS.db.settings.passiveEnabled==nil and NS.db.settings.worldClickEnabled==nil)
            assert(NS.db.settings.minLevel==10 and NS.db.settings.myFactionOnly==true)
            assert(NS.db.unknownField=="preserve" and Batata_Scanner.GetPlayer("Keep").faction=="Horde")
        ''')
        filtered = Harness(setup='''
            Batata_Scanner_DB={schemaVersion=1,settings={searchMinLevel=70,searchMaxLevel=20,searchClass=" Mage ",
                searchGuildStatus="unknown",searchSeenWithin=3600,overrideDefaults="yes",scanClasses={" Mage ",5}}}
        ''')
        filtered.execute('''
            local settings=NS.db.settings
            assert(settings.searchMinLevel==70 and settings.searchMaxLevel==70 and settings.searchClass=="Mage")
            assert(settings.searchGuildStatus==nil and settings.searchSeenWithin==3600)
            assert(settings.overrideDefaults==false and #settings.scanClasses==1 and settings.scanClasses[1]=="Mage")
        ''')
        future = Harness(setup='Batata_Scanner_DB={schemaVersion=99,marker="keep"}')
        future.execute('''
            assert(Batata_Scanner.IsReady() and Batata_Scanner_DB.schemaVersion==1)
            assert(Batata_Scanner_DB.marker==nil and Batata_Scanner.CountPlayers()==0)
        ''')

    def test_players_save_as_positional_rows_and_load_back(self):
        """Verifies that players save as positional rows and load back."""
        self.harness.execute('''
            NS.Store:Observe({name="Alice",level=10,race="Dwarf"})
            Emit("PLAYER_LOGOUT")
            local row=Batata_Scanner_DB.players[1]
            assert(#Batata_Scanner_DB.players==1 and row.name==nil)
            assert(row[1]=="Alice" and row[2]=="Alliance" and row[3]==10 and row[4]==false)
            assert(row[5]=="Dwarf" and row[6]==false and row[7]==row[8] and row[9]==false)
        ''')
        harness = Harness(setup='''
            Batata_Scanner_DB={schemaVersion=1,players={
                {"Alice","Horde",20,"Mage","Orc",false,100,300,false},
                {"ALICE","Horde",10,false,false,"Old",50,200,false},
                {"Bob","Alliance",5,false,false,"",1,2,"Elwynn Forest"},
                {false,"Horde"},"broken"}}
        ''')
        harness.execute('''
            local alice=Batata_Scanner.GetPlayer("alice")
            assert(Batata_Scanner.CountPlayers()==2 and alice.name=="Alice" and alice.level==20)
            assert(alice.guild==nil and alice.class=="Mage" and alice.zone==nil and alice.lastSeen==300)
            local bob=Batata_Scanner.GetPlayer("Bob")
            assert(bob.guild=="" and bob.zone=="Elwynn Forest" and bob.class==nil)
        ''')

    def test_saved_player_fields_are_validated_before_aggregation(self):
        """Verifies that saved player fields are validated before aggregation."""
        harness = Harness(setup='''
            Batata_Scanner_DB={schemaVersion=1,players={
                {"Broken","Invalid","10",{}, {}, {}, "first", "last", {}},
                {name="  Valid   Name  ",faction=" Horde ",level=255,class=" Mage ",race=" Orc ",
                    guild="",firstSeen=0,lastSeen=100,zone=" Town "},
                {"Duplicate","Alliance",20,"Mage","Human",false,1,200,false},
                {name="Duplicate",level=5,lastSeen={}},
                {"   ","Alliance"},
                {name={secret=true}},
                {name="Inaccessible",inaccessible=true}}}
        ''')
        harness.execute('''
            assert(Batata_Scanner.IsReady() and Batata_Scanner.CountPlayers()==3)
            local broken=Batata_Scanner.GetPlayer("Broken")
            for fieldIndex,field in ipairs({"faction","level","class","race","guild","firstSeen","lastSeen","zone"}) do
                assert(broken[field]==nil,field)
            end
            broken.class={}
            assert(Batata_Scanner.GetPlayer("Broken").class==nil)
            local valid=Batata_Scanner.GetPlayer("valid name")
            assert(valid.name=="Valid Name" and valid.faction=="Horde" and valid.level==255)
            assert(valid.class=="Mage" and valid.race=="Orc" and valid.guild=="")
            assert(valid.firstSeen==0 and valid.lastSeen==100 and valid.zone=="Town")
            assert(Batata_Scanner.GetPlayer("Duplicate").lastSeen==200)
            local census=Batata_Scanner.GetCensus()
            assert(census.total==3 and census.unknownGuild==2 and census.unguilded==1)
            assert(census.byClass.Unknown==1 and census.byClass.Mage==2 and census.byRace.Unknown==1)
            assert(census.oldestSeen==0 and census.newestSeen==200)
            assert(Batata_Scanner.FindPlayers({minLevel=1}).total==2)
            local request=assert(NS.Store:CreateSearch("", "lastSeen"))
            while not request:Step() do end
            assert(request.total==3)
            Emit("PLAYER_LOGOUT")
            NS.db.players=NS.Store:Load(NS.db.players)
            assert(Batata_Scanner.CountPlayers()==3 and Batata_Scanner.GetCensus().unguilded==1)
            assert(#errors==0)
        ''')

    def test_saved_numeric_fields_reject_nonfinite_fractional_and_out_of_range_values(self):
        """Verifies that saved numeric fields reject nonfinite fractional and out of range values."""
        harness = Harness(setup='''
            local invalidNumbers={-1,1.5,math.huge,-math.huge,0/0,9007199254740001,"10",{secret=true}}
            local rows={}
            for valueIndex,value in ipairs(invalidNumbers) do
                rows[#rows+1]={name="Invalid "..valueIndex,faction="Alliance",level=value,
                    firstSeen=value,lastSeen=value}
            end
            rows[#rows+1]={"Zero","Alliance",0,false,false,"",0,0,false}
            rows[#rows+1]={"High","Alliance",256,false,false,false,1,2,false}
            Batata_Scanner_DB={schemaVersion=1,players=rows}
        ''')
        harness.execute('''
            for valueIndex=1,8 do
                local player=Batata_Scanner.GetPlayer("Invalid "..valueIndex)
                assert(player.level==nil and player.firstSeen==nil and player.lastSeen==nil)
            end
            local zero=Batata_Scanner.GetPlayer("Zero")
            assert(zero.level==nil and zero.guild=="" and zero.firstSeen==0 and zero.lastSeen==0)
            assert(Batata_Scanner.GetPlayer("High").level==nil)
            local census=Batata_Scanner.GetCensus()
            assert(census.total==10 and census.byLevel[0]==10 and census.newestSeen==2)
            assert(#errors==0)
        ''')

    def test_ready_registration_before_load(self):
        """Verifies that ready registration before load."""
        harness = Harness(initialize=False)
        harness.execute('''
            readyEvents=0
            assert(not Batata_Scanner.IsReady() and Batata_Scanner.GetContext()==nil)
            Batata_Scanner.RegisterCallback("READY",function() readyEvents=readyEvents+1 end)
        ''')
        harness.emit("ADDON_LOADED", "Unrelated")
        harness.emit("ADDON_LOADED", "Batata Scanner")
        harness.emit("PLAYER_LOGIN")
        harness.emit("PLAYER_ENTERING_WORLD")
        harness.execute('assert(readyEvents==1 and Batata_Scanner.IsReady())')

    def test_guild_status_and_time_filters_do_not_confuse_unknown_guild_name(self):
        """Verifies that guild status and time filters do not confuse unknown guild name."""
        self.harness.execute('''
            NS.Store:Observe({name="Unread Guild"})
            NS.Store:Observe({name="No Guild",guild=""})
            NS.Store:Observe({name="Real Guild",guild="Unknown"})
            assert(Batata_Scanner.CountPlayers({guildStatus="unknown"})==1)
            assert(Batata_Scanner.CountPlayers({guildStatus="guilded",guild="Unknown"})==1)
            local census=Batata_Scanner.GetCensus()
            assert(census.byGuild.Unknown==1 and census.unknownGuild==1 and census.byGuild[""]==1)
            assert(Batata_Scanner.CountPlayers({seenAfter=epoch,seenBefore=epoch})==3)
            assert(Batata_Scanner.CountPlayers({seenBefore=epoch-1})==0)
            assert(not pcall(Batata_Scanner.CountPlayers,{seenAfter=2,seenBefore=1}))
            assert(not pcall(Batata_Scanner.CountPlayers,{guildStatus="invalid"}))
            assert(not pcall(Batata_Scanner.CountPlayers,{source="passive"}))
        ''')

    def test_private_overview_tracks_updates_factions_and_reload_without_player_scans(self):
        """Verifies that private overview tracks updates factions and reload without player scans."""
        self.harness.execute('''
            local function CheckOverview(faction)
                local expected=Batata_Scanner.GetCensus({faction=faction})
                local overview,races=NS.Store:GetCensusOverview(faction)
                for fieldIndex,field in ipairs({"total","guilded","unguilded","unknownGuild","revision"}) do
                    assert(overview[field]==expected[field],field)
                end
                for fieldIndex,field in ipairs({"byClass","byRace","byGuild","byLevel"}) do
                    for key,count in pairs(expected[field]) do assert(overview[field][key]==count,field) end
                    for key,count in pairs(overview[field]) do assert(expected[field][key]==count,field) end
                end
                for race,snapshot in pairs(races) do
                    assert(snapshot.total==overview.byRace[race])
                    local total=0
                    for className,count in pairs(snapshot.byClass) do total=total+count end
                    assert(total==snapshot.total)
                end
            end
            NS.Store:Observe({name="One"})
            NS.Store:Observe({name="Two",class="MAGE",race="Human",guild="",level=10})
            NS.context={faction="Horde",key="Horde"}
            NS.Store:Observe({name="Three",class="WARRIOR",race="Orc",guild="Unknown",level=60})
            CheckOverview()
            CheckOverview("Alliance")
            CheckOverview("Horde")
            NS.Store:Observe({name="One",class="MAGE",race="Orc",guild="Guild",level=30})
            NS.Store:Observe({name="Two",class="DRUID",race="Tauren",guild="Guild",level=20})
            epoch=epoch+1
            NS.Store:Observe({name="Three",zone="Town"})
            CheckOverview()
            CheckOverview("Alliance")
            CheckOverview("Horde")
            NS.Store:Save()
            NS.db.players=NS.Store:Load(NS.db.players)
            CheckOverview()
            CheckOverview("Alliance")
            CheckOverview("Horde")
            local originalPairs=pairs
            pairs=function(value)
                assert(value~=NS.db.players,"overview reads must not traverse players")
                return originalPairs(value)
            end
            local overview,races=NS.Store:GetCensusOverview()
            overview.byClass.Mage=999
            races.Orc.byClass.Mage=999
            local fresh,freshRaces=NS.Store:GetCensusOverview()
            assert(fresh.byClass.Mage==1 and freshRaces.Orc.byClass.Mage==1)
            assert(table.concat(NS.Store:GetClassNames(),",")=="Druid,Mage,Warrior")
            assert(Batata_Scanner.GetCensusOverview==nil and Batata_Scanner.GetClassNames==nil)
            pairs=originalPairs
        ''')

    def test_unfiltered_and_faction_counts_use_maintained_totals(self):
        """Verifies that unfiltered and faction counts use maintained totals."""
        self.harness.execute('''
            NS.Store:Observe({name="Alliance Player",level=10})
            NS.context.faction="Horde"
            NS.Store:Observe({name="Horde Player",level=20})
            NS.Store:Observe({name="Alliance Player",level=30})
            local originalPairs=pairs
            pairs=function(value)
                assert(value~=NS.db.players, "aggregate counts must not traverse players")
                return originalPairs(value)
            end
            assert(Batata_Scanner.CountPlayers()==2)
            assert(Batata_Scanner.CountPlayers({})==2)
            assert(Batata_Scanner.CountPlayers({faction="Alliance"})==0)
            assert(Batata_Scanner.CountPlayers({faction="Horde"})==2)
            pairs=originalPairs
            assert(Batata_Scanner.CountPlayers({faction="Horde",minLevel=25})==1)
            assert(Batata_Scanner.CountPlayers({name="Horde"})==1)
        ''')

    def test_large_collection_has_bounded_detached_pages(self):
        """Verifies that large collection has bounded detached pages."""
        self.harness.execute('''
            NS.Store:BeginBatch()
            for playerIndex=1,10000 do
                NS.Store:Observe({name=string.format("Player %05d",playerIndex),level=playerIndex%60+1,
                    class="MAGE",race="Human",guild=""},"who")
            end
            NS.Store:EndBatch()
            local page=Batata_Scanner.FindPlayers(nil,{offset=9990,limit=500})
            assert(page.total==10000 and #page.players==10 and not page.hasMore)
            assert(Batata_Scanner.GetCensus().total==10000)
            NS.Store:Observe({name="Player 00001",guild="Changed"},"who")
            assert(Batata_Scanner.GetCensus().guilded==1)
        ''')


if __name__ == "__main__":
    unittest.main()
