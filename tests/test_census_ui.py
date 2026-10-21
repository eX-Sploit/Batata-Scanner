"""Census table behavior using the real Lua panel and mocked native widgets."""

from pathlib import Path
import unittest

from harness import Harness


UI_SUPPORT = Path(__file__).with_name("ui_support.lua").read_text(encoding="utf-8")


class CensusUIContracts(unittest.TestCase):
    def setUp(self):
        self.client = Harness(setup=UI_SUPPORT, modules=(
            "Core.lua", "Store.lua", "Scanner.lua", "Passive.lua", "API.lua", "Widgets.lua", "CensusPanel.lua"))
        self.client.execute('''
            mainFrame=CreateFrame("Frame",nil,UIParent)
            mainFrame:SetSize(800,790)
            mainFrame:SetPoint("CENTER",UIParent,"CENTER",0,0)
            root=CreateFrame("Frame",nil,mainFrame)
            root:SetPoint("TOPLEFT",mainFrame,"TOPLEFT",0,-60)
            root:SetPoint("BOTTOMRIGHT",mainFrame,"BOTTOMRIGHT",0,0)
            panel=NS.CensusPanel
            panel:Build(root,mainFrame)
            function Observe(name,class,race,guild)
                NS.Store:Observe({name=name,class=class,race=race,guild=guild,level=60},"who")
            end
            function VisibleRows(box)
                local visible={}
                for _,row in ipairs(box.rows) do
                    if row:IsShown() then visible[#visible+1]=row end
                end
                return visible
            end
        ''')

    def check(self, source):
        self.client.execute(source)

    def test_class_table_shows_observed_classes_native_rows_and_population_totals(self):
        self.check('''
            Observe("One","MAGE","Human","Alpha")
            Observe("Two","MAGE","Human","")
            Observe("Three","WARRIOR","Dwarf",nil)
            Observe("Four",nil,nil,nil)
            panel:Refresh()
            assert(#panel.navigation.links==3 and panel.navigation.selected==1)
            assert(panel.navigation.links[1]:GetText()=="Classes")
            assert(panel.navigation.links[2]:GetText()=="Races")
            assert(panel.navigation.links[3]:GetText()=="Guilds")
            local rows=VisibleRows(panel.classBox)
            assert(#rows==3)
            assert(rows[1].entry.token=="MAGE" and rows[1].count:GetText()=="2 (50%)")
            assert(rows[1]:GetHeight()==20 and rows[1].fill:GetHeight()==14)
            assert(rows[1].count:GetWidth()==76)
            assert(rows[1].fill.texture=="Interface\\\\TargetingFrame\\\\UI-StatusBar")
            assert(math.abs(rows[1].fill:GetWidth()-2*rows[2].fill:GetWidth())<.01)
            assert(rows[1].label.color[1]==RAID_CLASS_COLORS.MAGE.r)
            assert(panel.classScroll.template=="FauxScrollFrameTemplate")
            assert(panel.toggles.class[1].template=="ColumnDisplayButtonNoScriptsTemplate")
            assert(panel.summary:GetText():find("Unique players: |cffffffff4|r",1,true))
            assert(panel.summary:GetText():find("Guilds: |cffffffff1|r",1,true))
            assert(panel.summary:GetText():find("Unknown: |cffffffff2|r",1,true))
            assert(#whoCalls==0 and #errors==0)
        ''')

    def test_sort_headers_toggle_per_section_without_refetching(self):
        self.check('''
            Observe("One","MAGE","Human","Zeta")
            Observe("Two","WARRIOR","Human","Alpha")
            panel:Refresh()
            local original=BatataScanner.GetCensus
            censusCalls=0
            BatataScanner=setmetatable({GetCensus=function(...)
                censusCalls=censusCalls+1
                return original(...)
            end},{__index=BatataScanner})
            ClickWidget(panel.toggles.class[1])
            local rows=VisibleRows(panel.classBox)
            assert(rows[1].label:GetText()=="Mage")
            ClickWidget(panel.toggles.class[1])
            rows=VisibleRows(panel.classBox)
            assert(rows[1].label:GetText()=="Warrior")
            ClickWidget(panel.toggles.class[2])
            rows=VisibleRows(panel.classBox)
            assert(rows[1].label:GetText()=="Mage" and rows[2].label:GetText()=="Warrior")
            assert(censusCalls==0)
            assert(NS.db.settings.censusSort.class.key=="count")
            assert(#errors==0)
        ''')

    def test_race_selector_shows_class_distribution_including_zero_rows_and_caches(self):
        self.check('''
            Observe("One","MAGE","Human","")
            Observe("Two","WARRIOR","Dwarf","")
            Observe("Three","MAGE","Unusual Race",nil)
            Observe("Four","WARRIOR",nil,nil)
            panel:Refresh()
            local added={}
            for _,option in ipairs(panel.raceOptions) do added[option.value]=true end
            assert(added.Human and added.Dwarf and added["Unusual Race"] and added.Unknown)
            ClickWidget(panel.navigation.links[2])
            panel.raceDropdown:SetValue("Human")
            panel.selectedRace="Human"
            panel:Draw()
            local rows=VisibleRows(panel.raceBox)
            assert(#rows==7 and rows[1].entry.token=="MAGE")
            assert(rows[1].count:GetText()=="1 (100%)")
            assert(panel.raceHeader:GetText()=="Human (1, 25%)")
            panel.selectedRace="Unknown"
            panel:Draw()
            rows=VisibleRows(panel.raceBox)
            assert(#rows==1 and rows[1].entry.token=="WARRIOR")
            assert(rows[1].count:GetText()=="1 (100%)")
            panel.selectedRace="Unusual Race"
            panel:Draw()
            rows=VisibleRows(panel.raceBox)
            assert(#rows==1 and rows[1].entry.token=="MAGE")
            panel.selectedRace="Dwarf"
            panel:Draw()
            rows=VisibleRows(panel.raceBox)
            assert(#rows==6 and rows[1].entry.token=="WARRIOR")
            assert(BatataScanner.GetCensus().total==4)
            assert(#errors==0)
        ''')

    def test_empty_class_chart_does_not_invent_observations_and_race_extras_are_retained(self):
        self.check('''
            panel:Refresh()
            assert(#VisibleRows(panel.classBox)==0)
            Observe("Unexpected","DRUID","Human",nil)
            panel:Refresh()
            ClickWidget(panel.navigation.links[2])
            panel.selectedRace="Human"
            panel:Draw()
            local rows=VisibleRows(panel.raceBox)
            assert(#rows==8 and rows[1].entry.token=="DRUID")
            assert(rows[1].count:GetText()=="1 (100%)")
            assert(BatataScanner.GetPlayer("Unexpected").class=="DRUID")
            assert(#errors==0)
        ''')

    def test_known_race_class_definitions_localize_and_keep_forever_combinations(self):
        self.check('''
            C_CreatureInfo.GetRaceInfo=function(raceID)
                if raceID==1 then return {raceName="Humain"} end
            end
            C_FriendList.GetWhoRaceFilters=function() return {{name="Humain"},{name="Dwarf"}} end
            Observe("Localized","MAGE","Humain",nil)
            panel:Refresh()
            assert(panel.raceOptions[1].value=="Humain")
            ClickWidget(panel.navigation.links[2])
            local rows=VisibleRows(panel.raceBox)
            assert(#rows==7 and rows[1].entry.token=="MAGE")
            panel.selectedRace="Dwarf"
            panel:Draw()
            local classes={}
            for _,row in ipairs(VisibleRows(panel.raceBox)) do classes[row.entry.token]=row.entry.count end
            assert(classes.SHAMAN==0 and classes.PALADIN==0 and classes.MAGE==nil)
            panel.selectedRace="High Order Skyborne"
            panel:Draw()
            assert(#VisibleRows(panel.raceBox)==5)
            assert(#errors==0)
        ''')

    def test_guild_search_excludes_unguilded_and_uses_unfiltered_scaling(self):
        self.check('''
            Observe("One","MAGE","Human","Alpha")
            Observe("Two","MAGE","Human","Alpha")
            Observe("Three","WARRIOR","Dwarf","Beta")
            Observe("Four","WARRIOR","Dwarf","")
            panel:Refresh()
            ClickWidget(panel.navigation.links[3])
            local rows=VisibleRows(panel.guildBox)
            assert(#rows==2 and rows[1].label:GetText()=="Alpha")
            assert(rows[1].count:GetText()=="2 (67%)")
            local fullWidth=rows[1].fill:GetWidth()
            panel.guildSearch:SetText("  bEt  ")
            rows=VisibleRows(panel.guildBox)
            assert(#rows==1 and rows[1].label:GetText()=="Beta")
            assert(math.abs(rows[1].fill:GetWidth()-fullWidth/2)<.01)
            assert(rows[1].count:GetText()=="1 (33%)")
            panel.guildSearch:SetText("missing")
            assert(#VisibleRows(panel.guildBox)==0 and panel.noGuilds:IsShown())
            assert(panel.noGuilds:GetText()=="No guild matches the search.")
            panel.guildSearch.scripts.OnEscapePressed(panel.guildSearch)
            assert(panel.guildSearch:GetText()=="" and #VisibleRows(panel.guildBox)==2)
            assert(#errors==0)
        ''')

    def test_guild_overflow_is_bounded_and_resets_scroll_after_filtering(self):
        self.check('''
            for index=1,120 do
                Observe("Player "..index,"MAGE","Human",string.format("Guild %03d",index))
            end
            panel:Refresh()
            ClickWidget(panel.navigation.links[3])
            local rows=VisibleRows(panel.guildBox)
            assert(#rows<40 and #rows>10 and panel.guildScroll:IsShown())
            panel.guildScroll.ScrollBar:SetValue(400)
            assert(FauxScrollFrame_GetOffset(panel.guildScroll)==20)
            rows=VisibleRows(panel.guildBox)
            assert(rows[1].entry.label=="Guild 021")
            local created=#panel.guildBox.rows
            panel.guildSearch:SetText("Guild 120")
            assert(FauxScrollFrame_GetOffset(panel.guildScroll)==0)
            rows=VisibleRows(panel.guildBox)
            assert(#rows==1 and rows[1].label:GetText()=="Guild 120")
            assert(not panel.guildScroll:IsShown() and #panel.guildBox.rows==created)
            assert(#errors==0)
        ''')

    def test_hidden_panel_does_not_fetch_and_snapshot_rows_do_not_mutate_store(self):
        self.check('''
            Observe("One","MAGE","Human","Alpha")
            panel:Refresh()
            panel.classBox.rows[1].entry.count=999
            assert(BatataScanner.GetCensus().byClass.MAGE==1)
            local original=BatataScanner.GetCensus
            censusCalls=0
            BatataScanner=setmetatable({GetCensus=function(...)
                censusCalls=censusCalls+1
                return original(...)
            end},{__index=BatataScanner})
            root:Hide()
            panel:Refresh()
            assert(censusCalls==0)
            root:Show()
            panel:Refresh()
            assert(censusCalls==1)
            assert(#errors==0)
        ''')


if __name__ == "__main__":
    unittest.main()
