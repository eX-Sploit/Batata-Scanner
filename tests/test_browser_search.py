"""The private browser search is incremental and never publishes stored records."""
import unittest

from harness import Harness


class BrowserSearchTests(unittest.TestCase):
    """Checks bounded player search, snapshots, and sort caches."""
    def setUp(self):
        """Creates a fresh test fixture before each test."""
        self.harness = Harness()

    def test_each_slice_is_bounded_and_only_selected_records_are_copied(self):
        """Verifies that each slice is bounded and only selected records are copied."""
        self.harness.execute('''
            NS.Store:BeginBatch()
            for playerIndex=1,1000 do
                NS.Store:Observe({name=string.format("Player%04d",playerIndex),class="MAGE",level=30,
                    zone="Stormwind",guild="Guild"},"who")
            end
            NS.Store:EndBatch()
            local originalCopy=NS.CopyPlayer
            copies=0
            NS.CopyPlayer=function(...)
                copies=copies+1
                return originalCopy(...)
            end
            local request=assert(NS.Store:CreateSearch("mage stormwind", "name", false))
            assert(not request:Step() and request.progress<=200 and copies==0)
            while not request:Step() do end
            assert(request.total==1000 and not request.truncated and copies==0)
            local record=request:GetPlayer(1000)
            assert(record.name=="Player1000" and copies==1)
            record.guild="Changed"
            assert(BatataScanner.GetPlayer("Player1000").guild=="Guild")
            assert(record.sources==nil)
            assert(BatataScanner.CreateSearch==nil)
        ''')

    def test_search_retains_at_most_one_thousand_results_and_marks_truncation(self):
        """Verifies that browser matches are capped while possible extra matches are reported."""
        self.harness.execute('''
            for playerIndex=1,1200 do
                NS.Store:Observe({name=string.format("Player%04d",playerIndex),level=30})
            end
            local request=assert(NS.Store:CreateSearch("", "name", false))
            while not request:Step() do end
            assert(request.total==1000 and request.truncated)
            assert(request:GetPlayer(1).name=="Player0001")
            assert(request:GetPlayer(1000).name=="Player1000")
            assert(request:GetPlayer(1001)==nil)
            assert(BatataScanner.CountPlayers()==1200, "the browser cap must not delete stored players")
        ''')

    def test_cold_order_preparation_is_deferred_bounded_and_cached(self):
        """Verifies that cold order preparation is deferred bounded and cached."""
        self.harness.execute('''
            for playerIndex=1,1000 do
                NS.Store:Observe({name=string.format("Player%04d",playerIndex),level=playerIndex%60+1})
            end
            local profileCalls=0
            debugprofilestop=function()
                profileCalls=profileCalls+1
                return profileCalls*0.25
            end
            local originalSort=table.sort
            table.sort=function() error("browser preparation must not call a blocking sort") end
            coroutine=nil
            local request=assert(NS.Store:CreateSearch("", "level", false))
            assert(profileCalls==0 and request.limit==0)
            assert(not request:Step() and request.progress==0 and profileCalls<=6)
            while not request.complete do
                local previousCalls=profileCalls
                request:Step()
                assert(profileCalls-previousCalls<=7, "every preparation and matching slice must be bounded")
            end
            assert(request.total==1000 and request.limit==1000 and not request.truncated)
            local cached=assert(NS.Store:CreateSearch("", "level", false))
            assert(cached.limit==1000, "unchanged orders should be cached")
            while not cached:Step() do end
            assert(cached.total==1000)
            table.sort=originalSort
        ''')

    def test_incremental_order_matches_public_sorting_for_every_field(self):
        """Verifies that incremental order matches public sorting for every field."""
        self.harness.execute('''
            for playerIndex=1,257 do
                NS.Store:Observe({name=string.format("Player%04d",258-playerIndex),level=playerIndex%60+1,
                    class=playerIndex%2==0 and "MAGE" or "WARRIOR",
                    guild=playerIndex%3==0 and "Guild" or nil,race=playerIndex%2==0 and "Human" or "Dwarf",
                    zone=playerIndex%3==0 and "Town" or "Forest"})
                epoch=epoch+1
            end
            for fieldIndex,field in ipairs({"name","level","class","race","guild","zone","faction","firstSeen","lastSeen"}) do
                for directionIndex,descending in ipairs({false,true}) do
                    local expected=BatataScanner.FindPlayers(nil,{sort=field,descending=descending,limit=500})
                    NS.db.players=NS.Store:Load(NS.db.players)
                    local request=assert(NS.Store:CreateSearch("",field,descending))
                    while not request:Step() do end
                    assert(request.total==expected.total)
                    for playerIndex,player in ipairs(expected.players) do
                        assert(request:GetPlayer(playerIndex).name==player.name, field.." order mismatch")
                    end
                end
            end
        ''')

    def test_observations_during_preparation_preserve_the_snapshot_without_caching_it(self):
        """Verifies that observations during preparation preserve the snapshot without caching it."""
        self.harness.execute('''
            for playerIndex=1,900 do
                NS.Store:Observe({name=string.format("Player%04d",playerIndex),level=30})
            end
            local request=assert(NS.Store:CreateSearch("", "level"))
            assert(not request:Step())
            NS.Store:Observe({name="Changed",level=1})
            while not request:Step() do end
            local current=assert(NS.Store:CreateSearch("", "level"))
            assert(request.total==900 and request:GetPlayer(1).name~="Changed")
            assert(current.limit==0 and current.revision>request.revision)
            while not current:Step() do end
            assert(current.total==901 and current:GetPlayer(1).name=="Changed")
        ''')

    def test_insertion_during_collection_cannot_duplicate_or_skip_players(self):
        """Verifies that insertion during collection cannot duplicate or skip players."""
        self.harness.execute('''
            for playerIndex=1,800 do
                NS.Store:Observe({name=string.format("Player%06d",playerIndex),level=30})
            end
            local request=assert(NS.Store:CreateSearch("", "name"))
            assert(not request:Step())
            NS.Store:Observe({name="Inserted During Collection",level=30})
            while not request:Step() do end
            assert(request.total==800 and not request.truncated and request.revision<NS.db.revision)
            local seen={}
            for resultIndex=1,request.total do
                local player=request:GetPlayer(resultIndex)
                assert(not seen[player.name], "a search must not duplicate identities")
                seen[player.name]=true
            end
            assert(not seen["Inserted During Collection"])
            for playerIndex=1,800 do
                assert(seen[string.format("Player%06d",playerIndex)], "a search must not skip identities")
            end
            local current=assert(NS.Store:CreateSearch("", "name"))
            while not current:Step() do end
            assert(current.total==801)
        ''')

    def test_cached_orders_read_live_data_but_searches_preserve_matching_values(self):
        """Verifies that cached orders read live data but searches preserve matching values."""
        self.harness.execute('''
            for playerIndex=1,1000 do
                NS.Store:Observe({name=string.format("Player%06d",playerIndex),guild="Original"})
            end
            BatataScanner.FindPlayers(nil,{sort="name"})
            local request=assert(NS.Store:CreateSearch("", "name", false, {guild="Original"}))
            assert(not request:Step())
            NS.Store:Observe({name="Player000999",guild="Changed"})
            while not request:Step() do end
            assert(request.total==1000 and request:GetPlayer(999).guild=="Original")
            local page=BatataScanner.FindPlayers({guild="Changed"},{sort="name"})
            assert(page.total==1 and page.players[1].name=="Player000999")
        ''')

    def test_only_affected_sort_orders_are_invalidated(self):
        """Verifies that only affected sort orders are invalidated."""
        self.harness.execute('''
            NS.Store:Observe({name="Alice",level=10})
            NS.Store:Observe({name="Bob",level=20})
            for fieldIndex,field in ipairs({"name","lastSeen"}) do
                BatataScanner.FindPlayers(nil,{sort=field})
            end
            epoch=epoch+1
            NS.Store:Observe({name="Alice"})
            assert(NS.Store:CreateSearch("","name").limit==2)
            assert(NS.Store:CreateSearch("","lastSeen").limit==0)
            BatataScanner.FindPlayers(nil,{sort="level"})
            assert(NS.Store:CreateSearch("","level").limit==2)
            NS.Store:Observe({name="Alice",level=30})
            assert(NS.Store:CreateSearch("","level").limit==0)
            assert(NS.Store:CreateSearch("","name").limit==2)
            NS.Store:Observe({name="Carol",level=40})
            assert(NS.Store:CreateSearch("","name").limit==0)
        ''')

    def test_sort_cache_evicts_least_recently_used_order_without_breaking_searches(self):
        """Verifies that sort cache evicts least recently used order without breaking searches."""
        self.harness.execute('''
            NS.Store:Observe({name="Alice",level=20})
            NS.Store:Observe({name="Bob",level=10})
            BatataScanner.FindPlayers(nil,{sort="name"})
            BatataScanner.FindPlayers(nil,{sort="level"})
            local active=NS.Store:CreateSearch("", "level")
            BatataScanner.FindPlayers(nil,{sort="name"})
            local third=NS.Store:CreateSearch("", "guild")
            while not third:Step() do end
            assert(NS.Store:CreateSearch("","level").limit==0)
            assert(NS.Store:CreateSearch("","name").limit==2)
            assert(NS.Store:CreateSearch("","guild").limit==2)
            while not active:Step() do end
            assert(active:GetPlayer(1).name=="Bob" and active.total==2)
            BatataScanner.FindPlayers(nil,{sort="race"})
            assert(NS.Store:CreateSearch("","name").limit==0)
            assert(NS.Store:CreateSearch("","guild").limit==2)
            assert(NS.Store:CreateSearch("","race").limit==2)
        ''')

    def test_search_finishes_during_sustained_observations(self):
        """Verifies that search finishes during sustained observations."""
        self.harness.execute('''
            for playerIndex=1,5000 do
                NS.Store:Observe({name=string.format("Player%06d",playerIndex),level=30})
            end
            local request=assert(NS.Store:CreateSearch("", "lastSeen", true))
            local snapshotRevision=request.revision
            local snapshotTime=epoch
            for stepIndex=1,2000 do
                epoch=epoch+1
                NS.Store:Observe({name="Player000001",level=60})
                if request:Step() then break end
            end
            assert(request.complete, "ongoing observations must not starve a search")
            assert(request.total==1000 and request.truncated and request.revision==snapshotRevision)
            for resultIndex=1,request.total do
                local player=request:GetPlayer(resultIndex)
                assert(player.lastSeen==snapshotTime and player.level==30)
            end
            assert(BatataScanner.GetPlayer("Player000001").level==60)
        ''')

    def test_completed_search_releases_nonmatches_and_cancel_releases_matches(self):
        """Verifies that completed search releases nonmatches and cancel releases matches."""
        self.harness.execute('''
            NS.Store:Observe({name="Alice",level=10})
            NS.Store:Observe({name="Bob",level=20})
            local originals=setmetatable({NS.db.players.alice,NS.db.players.bob},{__mode="v"})
            local request=assert(NS.Store:CreateSearch("Alice", "name"))
            while not request:Step() do end
            epoch=epoch+1
            NS.Store:Observe({name="Alice",level=30})
            NS.Store:Observe({name="Bob",level=40})
            collectgarbage("collect")
            assert(originals[1] and not originals[2], "only matching versions should remain retained")
            assert(request:GetPlayer(1).level==10 and request.total==1)
            request:Cancel()
            collectgarbage("collect")
            assert(not originals[1] and request:GetPlayer(1)==nil)
            assert(request:Step() and request.cancelled)
        ''')

    def test_updates_without_searches_do_not_copy_records(self):
        """Verifies that updates without searches do not copy records."""
        self.harness.execute('''
            NS.Store:Observe({name="Alice",level=10})
            local originalCopy=NS.CopyPlayer
            local copies=0
            NS.CopyPlayer=function(player)
                copies=copies+1
                return originalCopy(player)
            end
            epoch=epoch+1
            NS.Store:Observe({name="Alice",level=20})
            assert(copies==0)
            local request=NS.Store:CreateSearch("absent", "name")
            while not request:Step() do end
            epoch=epoch+1
            NS.Store:Observe({name="Alice",level=30})
            assert(copies==0, "empty completed searches must not require copying")
            local active=NS.Store:CreateSearch("", "name")
            epoch=epoch+1
            NS.Store:Observe({name="Alice",level=40})
            assert(copies==1)
            active:Cancel()
            epoch=epoch+1
            NS.Store:Observe({name="Alice",level=50})
            assert(copies==1, "cancelled searches must release their journals immediately")
        ''')

    def test_words_match_across_fields_and_punctuation_is_literal(self):
        """Verifies that words match across fields and punctuation is literal."""
        self.harness.execute('''
            NS.Store:Observe({name="Alice Stone-Hill",level=30,class="MAGE",race="Human",guild=""},"who")
            NS.Store:Observe({name="Bob",level=40,class="WARRIOR",guild="Named"},"passive")
            local function Count(text)
                local request=assert(NS.Store:CreateSearch(text))
                while not request:Step() do end
                return request.total
            end
            assert(Count("alice MAGE unguilded")==1)
            assert(Count("stone-hill 30")==1 and Count(".*")==0)
            assert(Count("unknown named")==1)
            assert(Count(tostring(epoch))==2)
        ''')

    def test_invalid_queries_reject_and_sort_reverses(self):
        """Verifies that invalid queries reject and sort reverses."""
        self.harness.execute('''
            NS.Store:Observe({name="Alice",level=10},"who")
            NS.Store:Observe({name="Bob",level=20},"who")
            assert(not NS.Store:CreateSearch(string.rep("x",257)))
            assert(not NS.Store:CreateSearch("one two three four five six seven eight nine"))
            assert(not NS.Store:CreateSearch("", "unsupported"))
            local ascending=assert(NS.Store:CreateSearch("", "level", false))
            local descending=assert(NS.Store:CreateSearch("", "level", true))
            ascending:Step();descending:Step()
            assert(ascending:GetPlayer(1).level==10 and descending:GetPlayer(1).level==20)
        ''')


if __name__ == "__main__":
    unittest.main()
