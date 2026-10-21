"""The private browser search is incremental and never publishes stored records."""
import unittest

from harness import Harness


class BrowserSearchTests(unittest.TestCase):
    def setUp(self):
        self.harness = Harness()

    def test_each_slice_is_bounded_and_only_selected_records_are_copied(self):
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
            assert(request.total==1000 and copies==0)
            local record=request:GetPlayer(1000)
            assert(record.name=="Player1000" and copies==1)
            record.guild="Changed";record.sources.who=false
            assert(BatataScanner.GetPlayer("Player1000").guild=="Guild")
            assert(BatataScanner.GetPlayer("Player1000").sources.who)
            assert(BatataScanner.CreateSearch==nil)
        ''')

    def test_words_match_across_fields_and_punctuation_is_literal(self):
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
