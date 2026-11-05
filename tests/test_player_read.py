"""Bounded exhaustive public reads and loss-detecting change replay in mocked Lua 5.1."""
import unittest

from harness import Harness


class PlayerReadTests(unittest.TestCase):
    def setUp(self):
        self.harness = Harness()

    def test_exhaustive_pages_have_exact_total_and_detached_ownership(self):
        self.harness.execute('''
            for playerIndex=1,1207 do
                NS.Store:Observe({name=string.format("Player%05d",playerIndex),level=30,guild=""})
            end
            local originalSort=table.sort
            table.sort=function() error("public cursor must never use blocking table.sort") end
            local cursor=Batata_Scanner.OpenPlayerCursor({faction="Alliance"},{limit=37,offset=7})
            assert(cursor.request==nil and cursor.Store==nil and cursor.Step==nil)
            assert(not pcall(function() cursor.changed=true end))
            assert(not pcall(function() setmetatable(cursor,{}) end))
            local count,previousName=0,nil
            local sawPreparation=false
            for advanceIndex=1,10000 do
                local page=Batata_Scanner.AdvancePlayerCursor(cursor)
                assert(#page.players<=37 and #page.changes<=37)
                assert(not page.timed and page.workUnits<=65)
                if page.state=="preparing" then
                    sawPreparation=true
                    assert(page.total==nil and #page.players==0)
                else
                    assert(page.total==1207)
                end
                assert(page.offset==count+7)
                for playerIndex,player in ipairs(page.players) do
                    count=count+1
                    assert(not previousName or previousName<player.name)
                    previousName=player.name
                    player.guild="Caller mutation"
                end
                if page.snapshotComplete and page.caughtUp then break end
                assert(advanceIndex<10000)
            end
            assert(sawPreparation and count==1200)
            assert(Batata_Scanner.GetPlayer("Player00008").guild=="")
            assert(Batata_Scanner.ClosePlayerCursor(cursor))
            assert(not Batata_Scanner.ClosePlayerCursor(cursor))
            assert(not pcall(Batata_Scanner.AdvancePlayerCursor,cursor))
            table.sort=originalSort
        ''')

    def test_every_sort_and_direction_matches_synchronous_contract(self):
        self.harness.execute('''
            for playerIndex=1,129 do
                epoch=epoch+1
                NS.Store:Observe({name=string.format("Player%05d",130-playerIndex),level=playerIndex%60+1,
                    class=playerIndex%2==0 and "MAGE" or "WARRIOR",guild=playerIndex%3==0 and "Guild" or nil,
                    race=playerIndex%2==0 and "Human" or "Dwarf",zone=playerIndex%3==0 and "Town" or "Forest"})
            end
            for fieldIndex,field in ipairs({"name","level","firstSeen","lastSeen","guild","class","race","zone","faction"}) do
                for directionIndex,descending in ipairs({false,true}) do
                    local expected=Batata_Scanner.FindPlayers(nil,{sort=field,descending=descending,limit=500})
                    NS.db.players=NS.Store:Load(NS.db.players)
                    local cursor=Batata_Scanner.OpenPlayerCursor(nil,{sort=field,descending=descending,limit=11})
                    local count=0
                    for advanceIndex=1,10000 do
                        local page=Batata_Scanner.AdvancePlayerCursor(cursor)
                        for playerIndex,player in ipairs(page.players) do
                            count=count+1
                            assert(player.name==expected.players[count].name,field.." order differs")
                        end
                        if page.snapshotComplete then
                            assert(page.total==expected.total and not page.hasMore)
                            break
                        end
                        assert(advanceIndex<10000)
                    end
                    assert(count==129)
                    Batata_Scanner.ClosePlayerCursor(cursor)
                end
            end
        ''')

    def test_one_deadline_covers_preparation_copying_and_publication(self):
        self.harness.execute('''
            for playerIndex=1,300 do
                NS.Store:Observe({name=string.format("Player%05d",playerIndex),level=30})
            end
            local profileCalls=0
            debugprofilestop=function()
                profileCalls=profileCalls+1
                return profileCalls*0.25
            end
            local cursor=Batata_Scanner.OpenPlayerCursor(nil,{limit=100})
            assert(profileCalls==0,"creation must not prepare or copy the database")
            local count=0
            for advanceIndex=1,10000 do
                local page=Batata_Scanner.AdvancePlayerCursor(cursor,1)
                assert(page.timed and page.elapsedMs<=1.25 and page.maxOperationMs==0.25)
                assert(page.workUnits<=5)
                count=count+#page.players
                if page.snapshotComplete then break end
                assert(advanceIndex<10000)
            end
            assert(count==300)
            Batata_Scanner.ClosePlayerCursor(cursor)
        ''')

    def test_expensive_record_copies_share_the_deadline(self):
        self.harness.execute('''
            for playerIndex=1,40 do NS.Store:Observe({name="Player"..playerIndex}) end
            local milliseconds=0
            debugprofilestop=function() return milliseconds end
            local originalCopy=NS.CopyPlayer
            NS.CopyPlayer=function(player)
                milliseconds=milliseconds+0.6
                return originalCopy(player)
            end
            local cursor=Batata_Scanner.OpenPlayerCursor(nil,{limit=40})
            local count=0
            for advanceIndex=1,1000 do
                local page=Batata_Scanner.AdvancePlayerCursor(cursor,1)
                assert(#page.players<=2,"copying must not occur outside the advancement budget")
                assert(page.elapsedMs<=1.201)
                count=count+#page.players
                if page.snapshotComplete then break end
                assert(advanceIndex<1000)
            end
            assert(count==40)
            Batata_Scanner.ClosePlayerCursor(cursor)
        ''')

    def test_same_timestamp_changes_are_all_replayed_and_detached(self):
        self.harness.execute('''
            NS.Store:Observe({name="Alice",level=10})
            local cursor=Batata_Scanner.OpenPlayerCursor({seenAfter=epoch,seenBefore=epoch},{limit=1})
            local revision=NS.db.revision
            NS.Store:Observe({name="Alice",level=20,guild=""})
            NS.Store:Observe({name="Alice",level=30,guild="Guild"})
            NS.Store:Observe({name="Bob",level=40,guild=""})
            local players,changes={},{}
            for advanceIndex=1,1000 do
                local page=Batata_Scanner.AdvancePlayerCursor(cursor)
                assert(page.revision==revision)
                for playerIndex,player in ipairs(page.players) do players[#players+1]=player end
                for changeIndex,change in ipairs(page.changes) do changes[#changes+1]=change end
                if page.snapshotComplete and page.caughtUp then break end
                assert(advanceIndex<1000)
            end
            assert(#players==1 and players[1].level==10 and players[1].guild==nil)
            assert(#changes==3 and changes[1].player.level==20 and changes[1].player.guild=="")
            assert(changes[2].player.level==30 and changes[2].player.guild=="Guild")
            assert(changes[3].name=="Bob" and changes[1].sequence+1==changes[2].sequence)
            changes[2].player.guild="Corrupted"
            assert(Batata_Scanner.GetPlayer("Alice").guild=="Guild")
            assert(#Batata_Scanner.ReadPlayerChanges(cursor).changes==0)
            Batata_Scanner.ClosePlayerCursor(cursor)
        ''')

    def test_filters_emit_removals_and_faction_guild_states_are_preserved(self):
        self.harness.execute('''
            NS.Store:Observe({name="Unknown"})
            NS.Store:Observe({name="Empty",guild="",level=30})
            local all=Batata_Scanner.OpenPlayerCursor({faction=Batata_Scanner.GetContext().faction})
            local filtered=Batata_Scanner.OpenPlayerCursor({faction="Alliance",guildStatus="unguilded",minLevel=20})
            NS.Store:Observe({name="Unknown",guild="",level=30})
            NS.Store:Observe({name="Empty",guild="Named"})
            local previousContext=NS.context
            NS.context={faction="Horde",key="Horde"}
            NS.Store:Observe({name="Other",guild="",level=30})
            NS.Store:Observe({name="Unknown",guild="",level=30})
            NS.context=previousContext
            local page=Batata_Scanner.ReadPlayerChanges(filtered)
            assert(page.caughtUp and not page.snapshotComplete and #page.changes==3)
            assert(page.changes[1].kind=="upsert" and page.changes[1].name=="Unknown")
            assert(page.changes[2].kind=="remove" and page.changes[2].name=="Empty" and page.changes[2].player==nil)
            assert(page.changes[3].kind=="remove" and page.changes[3].name=="Unknown")
            local snapshot={}
            for advanceIndex=1,1000 do
                local result=Batata_Scanner.AdvancePlayerCursor(all)
                for playerIndex,player in ipairs(result.players) do snapshot[player.name]=player end
                if result.snapshotComplete then break end
            end
            assert(snapshot.Unknown.guild==nil and snapshot.Empty.guild=="")
            Batata_Scanner.ClosePlayerCursor(all)
            Batata_Scanner.ClosePlayerCursor(filtered)
        ''')

    def test_retention_deletion_and_reinsertion_do_not_change_initial_snapshot(self):
        self.harness.execute('''
            NS.Store:Observe({name="Old",level=10,guild=""})
            local cursor=Batata_Scanner.OpenPlayerCursor({faction="Alliance"})
            epoch=epoch+31*86400
            NS.db.settings.retentionDays=30
            assert(NS.Store:PruneExpired()==1)
            NS.Store:Observe({name="Old",level=40,guild="New"})
            NS.Store:Observe({name="New",level=50})
            local page
            repeat page=Batata_Scanner.AdvancePlayerCursor(cursor) until page.snapshotComplete
            assert(page.total==1 and page.players[1].name=="Old" and page.players[1].level==10)
            assert(#page.changes==3 and page.changes[1].kind=="remove")
            assert(page.changes[2].player.level==40 and page.changes[3].name=="New")
            Batata_Scanner.ClosePlayerCursor(cursor)
        ''')

    def test_sustained_mutations_do_not_restart_or_starve_snapshot(self):
        self.harness.execute('''
            for playerIndex=1,1500 do
                NS.Store:Observe({name=string.format("Initial%05d",playerIndex),level=10})
            end
            local cursor=Batata_Scanner.OpenPlayerCursor(nil,{limit=41,sort="lastSeen"})
            local initialRevision=NS.db.revision
            local count,changeCount,mutationCount=0,0,0
            local complete=false
            for advanceIndex=1,10000 do
                epoch=epoch+1
                NS.Store:Observe({name="Initial00001",level=advanceIndex%60+1})
                NS.Store:Observe({name="Added"..advanceIndex,level=30})
                mutationCount=mutationCount+2
                local page=Batata_Scanner.AdvancePlayerCursor(cursor)
                assert(page.state~="resetRequired" and page.revision==initialRevision)
                for playerIndex,player in ipairs(page.players) do
                    assert(player.name:find("Initial",1,true)==1 and player.level==10)
                    count=count+1
                end
                changeCount=changeCount+#page.changes
                if page.snapshotComplete then complete=true;break end
            end
            assert(complete and count==1500,"mutations must never restart an exhaustive snapshot")
            for advanceIndex=1,10000 do
                local page=Batata_Scanner.ReadPlayerChanges(cursor)
                changeCount=changeCount+#page.changes
                if page.caughtUp then break end
                assert(advanceIndex<10000)
            end
            -- One earlier finite boundary may complete before mutations from later calls.
            repeat
                local page=Batata_Scanner.ReadPlayerChanges(cursor)
                changeCount=changeCount+#page.changes
            until page.caughtUp
            assert(changeCount==mutationCount)
            Batata_Scanner.ClosePlayerCursor(cursor)
        ''')

    def test_finite_feed_boundary_completes_under_continued_writes(self):
        self.harness.execute('''
            NS.Store:Observe({name="Alice",level=10})
            local cursor=Batata_Scanner.OpenPlayerCursor()
            for changeIndex=1,10 do NS.Store:Observe({name="Alice",level=changeIndex+10}) end
            local profileCalls=0
            debugprofilestop=function() profileCalls=profileCalls+1;return profileCalls*0.6 end
            local first=Batata_Scanner.ReadPlayerChanges(cursor,1)
            local target=first.throughSequence
            assert(not first.caughtUp)
            local caughtUp=false
            for advanceIndex=1,20 do
                NS.Store:Observe({name="New"..advanceIndex})
                local page=Batata_Scanner.ReadPlayerChanges(cursor,1)
                assert(page.throughSequence==target)
                if page.caughtUp then caughtUp=true;break end
            end
            assert(caughtUp,"a changing current revision must not move an in-flight boundary")
            Batata_Scanner.ClosePlayerCursor(cursor)
        ''')

    def test_early_feed_and_late_snapshot_reconcile_to_current_filtered_state(self):
        self.harness.execute('''
            for playerIndex=1,250 do
                NS.Store:Observe({name=string.format("Player%04d",playerIndex),level=20,guild=""})
            end
            local filters={faction="Alliance",minLevel=20,guildStatus="unguilded"}
            local cursor=Batata_Scanner.OpenPlayerCursor(filters,{limit=7})
            local applied,versions={},{}
            local snapshotCount=0
            local function Apply(page)
                for playerIndex,player in ipairs(page.players) do
                    snapshotCount=snapshotCount+1
                    assert(player.level==20 and player.guild=="")
                    local key=player.name:lower()
                    if not versions[key] or page.snapshotSequence>versions[key] then
                        applied[key]=player
                        versions[key]=page.snapshotSequence
                    end
                end
                for changeIndex,change in ipairs(page.changes) do
                    local key=change.name:lower()
                    if not versions[key] or change.sequence>versions[key] then
                        applied[key]=change.player
                        versions[key]=change.sequence
                    end
                end
            end
            local complete=false
            for advanceIndex=1,10000 do
                if advanceIndex==5 then
                    epoch=epoch+31*86400
                    NS.db.settings.retentionDays=30
                    NS.Store:PruneExpired()
                end
                NS.Store:Observe({name=string.format("Player%04d",advanceIndex%270+1),
                    level=advanceIndex%60+1,guild=advanceIndex%3==0 and "Guild" or ""})
                Apply(Batata_Scanner.ReadPlayerChanges(cursor))
                local page=Batata_Scanner.AdvancePlayerCursor(cursor)
                Apply(page)
                if page.snapshotComplete then complete=true;break end
            end
            assert(complete and snapshotCount==250)
            local currentSequence=NS.Store:GetReadPosition()
            for advanceIndex=1,10000 do
                local page=Batata_Scanner.ReadPlayerChanges(cursor)
                Apply(page)
                if page.caughtUp and page.sequence==currentSequence then break end
                assert(advanceIndex<10000)
            end
            local expected=Batata_Scanner.FindPlayers(filters,{limit=500})
            local count=0
            for key,player in pairs(applied) do count=count+1 end
            assert(count==expected.total)
            for playerIndex,player in ipairs(expected.players) do
                local actual=assert(applied[player.name:lower()])
                assert(actual.level==player.level and actual.guild==player.guild and actual.lastSeen==player.lastSeen)
            end
            Batata_Scanner.ClosePlayerCursor(cursor)
        ''')

    def test_overflow_is_explicit_and_new_snapshot_recovers_incrementally(self):
        self.harness.execute('''
            NS.Store:Observe({name="Alice",level=10})
            local cursor=Batata_Scanner.OpenPlayerCursor()
            for changeIndex=1,16385 do NS.Store:Observe({name="Alice",level=changeIndex%60+1}) end
            local page=Batata_Scanner.ReadPlayerChanges(cursor)
            assert(page.state=="resetRequired" and page.reason=="historyExpired" and not page.caughtUp)
            assert(not page.hasMore and #page.changes==0)
            assert(Batata_Scanner.AdvancePlayerCursor(cursor).state=="resetRequired")
            Batata_Scanner.ClosePlayerCursor(cursor)
            local recovered=Batata_Scanner.OpenPlayerCursor()
            repeat page=Batata_Scanner.AdvancePlayerCursor(recovered) until page.snapshotComplete
            assert(page.total==1 and page.players[1].level==16385%60+1 and page.caughtUp)
            Batata_Scanner.ClosePlayerCursor(recovered)
        ''')

    def test_collection_reload_invalidates_existing_read(self):
        self.harness.execute('''
            NS.Store:Observe({name="Alice"})
            local cursor=Batata_Scanner.OpenPlayerCursor()
            NS.db.players=NS.Store:Load(NS.db.players)
            local page=Batata_Scanner.AdvancePlayerCursor(cursor)
            assert(page.state=="resetRequired" and page.reason=="collectionReloaded")
            Batata_Scanner.ClosePlayerCursor(cursor)
        ''')

    def test_readers_have_independent_positions_and_release_record_versions(self):
        self.harness.execute('''
            NS.Store:Observe({name="Alice",level=10})
            local originals=setmetatable({NS.db.players.alice},{__mode="v"})
            local first=Batata_Scanner.OpenPlayerCursor()
            local second=Batata_Scanner.OpenPlayerCursor()
            NS.Store:Observe({name="Alice",level=20})
            local page=Batata_Scanner.ReadPlayerChanges(first)
            page.changes[1].player.level=200
            local other=Batata_Scanner.ReadPlayerChanges(second)
            assert(other.changes[1].player.level==20)
            Batata_Scanner.ClosePlayerCursor(first)
            collectgarbage("collect")
            assert(originals[1],"the second reader must retain its own snapshot")
            Batata_Scanner.ClosePlayerCursor(second)
            collectgarbage("collect")
            assert(not originals[1])
            local originalCopy=NS.CopyPlayer
            NS.CopyPlayer=function() error("closed readers must not force observation copies") end
            NS.Store:Observe({name="Alice",level=30})
            NS.CopyPlayer=originalCopy
        ''')

    def test_validation_readiness_capacity_and_empty_offset(self):
        unready = Harness(initialize=False)
        unready.execute('''
            assert(not pcall(Batata_Scanner.OpenPlayerCursor))
            assert(not pcall(Batata_Scanner.AdvancePlayerCursor,{}))
            assert(not pcall(Batata_Scanner.ReadPlayerChanges,{}))
        ''')
        self.harness.execute('''
            assert(not pcall(Batata_Scanner.OpenPlayerCursor,{faction="invalid"}))
            assert(not pcall(Batata_Scanner.OpenPlayerCursor,nil,{sort=false}))
            assert(not pcall(Batata_Scanner.AdvancePlayerCursor,{}))
            local cursors={}
            for cursorIndex=1,8 do cursors[cursorIndex]=Batata_Scanner.OpenPlayerCursor(nil,{offset=100}) end
            assert(not pcall(Batata_Scanner.OpenPlayerCursor))
            for budgetIndex,value in ipairs({false,0,-1,2.1,"1",math.huge,0/0}) do
                assert(not pcall(Batata_Scanner.AdvancePlayerCursor,cursors[1],value))
            end
            local page=Batata_Scanner.AdvancePlayerCursor(cursors[1])
            assert(page.snapshotComplete and page.caughtUp and page.total==0 and page.offset==100)
            for cursorIndex,cursor in ipairs(cursors) do Batata_Scanner.ClosePlayerCursor(cursor) end
        ''')

    def test_profiler_absence_failures_and_reset_use_bounded_fallback(self):
        self.harness.execute('''
            for playerIndex=1,200 do NS.Store:Observe({name="Player"..playerIndex}) end
            for modeIndex=1,3 do
                local samples=0
                debugprofilestop=function()
                    samples=samples+1
                    if modeIndex==1 then error("unavailable profiler") end
                    if modeIndex==2 then return {secret=true} end
                    return 100-samples
                end
                local cursor=Batata_Scanner.OpenPlayerCursor()
                local page=Batata_Scanner.AdvancePlayerCursor(cursor)
                assert(not page.timed and page.elapsedMs==nil and page.maxOperationMs==nil)
                assert(page.workUnits<=65 and not page.snapshotComplete)
                Batata_Scanner.ClosePlayerCursor(cursor)
            end
        ''')


if __name__ == "__main__":
    unittest.main()
