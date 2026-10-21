"""Census table behavior using the real Lua panel and mocked native widgets."""

from pathlib import Path
import unittest

from harness import Harness


UI_SUPPORT = Path(__file__).with_name("ui_support.lua").read_text(encoding="utf-8")  # Shared native widget mocks.


class CensusUIContracts(unittest.TestCase):
    """Checks Census charts, faction scope, and interaction behavior."""
    def setUp(self):
        """Creates a fresh test fixture before each test."""
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
            function RaceChart(race)
                for chartIndex,chart in ipairs(panel.raceCharts) do
                    if chart:IsShown() and chart.race==race then return chart end
                end
                error("Missing race donut: "..race)
            end
            function PointAtDonut(chart,fraction,radiusMultiplier)
                local centerX,centerY=chart.ring:GetCenter()
                local scale=chart.ring:GetEffectiveScale()
                local angle=fraction*2*math.pi
                cursorX=(centerX+math.sin(angle)*chart.radius*radiusMultiplier)*scale
                cursorY=(centerY+math.cos(angle)*chart.radius*radiusMultiplier)*scale
                local update=chart.ring:GetScript("OnUpdate") or chart.ring:GetScript("OnEnter")
                update(chart.ring)
            end
        ''')

    def check(self, source):
        """Runs a Lua assertion or statement in the current test fixture."""
        self.client.execute(source)

    def test_overview_combines_centered_class_donut_races_and_population_details(self):
        """Verifies that overview combines centered class donut races and population details."""
        self.check('''
            Observe("One","MAGE","Human","Alpha")
            Observe("Two","MAGE","Human","")
            Observe("Three","WARRIOR","Dwarf",nil)
            Observe("Four",nil,nil,nil)
            panel:Refresh()
            assert(#panel.navigation.links==3 and panel.navigation.selected==1)
            assert(panel.navigation.links[1]:GetText()=="Overview")
            assert(panel.navigation.links[2]:GetText()=="Levels")
            assert(panel.navigation.links[3]:GetText()=="Guilds")
            assert(panel.classBox==nil and panel.classScroll==nil and panel.raceLegend==nil)
            local chart=panel.classChart
            assert(chart:IsVisible() and chart.total==4 and #chart.entries==3)
            assert(chart.entries[1].token=="MAGE" and chart.entries[1].count==2)
            assert(chart.count:GetText()=="4" and chart.label:GetText()=="Classes")
            local centerX=chart.ring:GetCenter()
            local overviewCenter=panel.overviewArea:GetCenter()
            assert(math.abs(centerX-overviewCenter)<0.01)
            assert(RaceChart("Human"):IsVisible() and chart:GetBottom()>panel.raceArea:GetTop())
            assert(panel.populationStats.metrics[1].value:GetText()=="60.0")
            assert(panel.populationStats.metrics[2].value:GetText()=="Mage (50%)")
            assert(panel.populationStats.metrics[3].value:GetText()=="Human (50%)")
            assert(panel.guildStats.metrics[1].value:GetText()=="1 (25%)")
            assert(panel.guildStats.metrics[2].value:GetText()=="1 (25%)")
            assert(panel.guildStats.metrics[3].value:GetText()=="2 (50%)")
            assert(panel.summary:GetText():find("Unique players: |cffffffff4|r",1,true))
            assert(panel.summary:GetText():find("Guilds: |cffffffff1|r",1,true))
            assert(panel.summary:GetText():find("Unknown: |cffffffff2|r",1,true))
            assert(#whoCalls==0 and #errors==0)
        ''')

    def test_all_census_stats_follow_current_faction_without_a_scope_selector(self):
        """Verifies that all census stats follow current faction without a scope selector."""
        self.check('''
            NS.db.settings.myFactionOnly=false
            NS.Store:Observe({name="Alliance Player",class="MAGE",race="Human",guild="Alliance Guild",level=20},"who")
            NS.context.faction="Horde"
            for playerIndex=1,9 do
                Observe("Horde Player "..playerIndex,"WARRIOR","Orc","Horde Guild")
            end
            NS.context.faction="Alliance"
            panel:Refresh()
            assert(panel.scopeFilter==nil and panel.snapshot.total==1)
            assert(panel.classChart.total==1 and panel.classChart.entries[1].token=="MAGE")
            assert(panel.populationStats.metrics[1].value:GetText()=="20.0")
            assert(panel.populationStats.metrics[3].value:GetText()=="Human (100%)")
            assert(panel.guildStats.metrics[1].value:GetText()=="1 (100%)")
            assert(panel.summary:GetText():find("Unique players: |cffffffff1|r",1,true))
            assert(#panel.raceOptions==5 and RaceChart("Human").total==1)
            ClickWidget(panel.navigation.links[2])
            assert(panel.levelBars[20].count==1 and panel.levelBars[20].total==1)
            assert(panel.levelBars[60].count==0)
            ClickWidget(panel.navigation.links[3])
            local rows=VisibleRows(panel.guildBox)
            assert(#rows==1 and rows[1].label:GetText()=="Alliance Guild")
            NS.context.faction="Horde"
            panel:Refresh()
            assert(panel.snapshot.total==9)
            rows=VisibleRows(panel.guildBox)
            assert(#rows==1 and rows[1].label:GetText()=="Horde Guild")
            ClickWidget(panel.navigation.links[2])
            assert(panel.levelBars[20].count==0 and panel.levelBars[60].count==9)
            assert(panel.levelBars[60].total==9)
            ClickWidget(panel.navigation.links[1])
            assert(panel.classChart.total==9 and panel.classChart.entries[1].token=="WARRIOR")
            assert(panel.populationStats.metrics[1].value:GetText()=="60.0")
            assert(panel.populationStats.metrics[3].value:GetText()=="Orc (100%)")
            assert(RaceChart("Orc").total==9)
            assert(panel.guildStats.metrics[1].value:GetText()=="9 (100%)")
            assert(panel.summary:GetText():find("Unique players: |cffffffff9|r",1,true))
            assert(Batata_Scanner.GetCensus().total==10, "shared records and public API stay unchanged")
            NS.context.faction=nil
            panel:Refresh()
            assert(panel.snapshot.total==0, "missing faction must not fall back to all factions")
            assert(#whoCalls==0 and #errors==0)
        ''')

    def test_levels_tab_precedes_guilds_and_charts_each_level_in_numeric_order(self):
        """Verifies that levels tab precedes guilds and charts each level in numeric order."""
        self.check('''
            NS.Store:Observe({name="Low",class="MAGE",race="Human",level=1},"who")
            NS.Store:Observe({name="Middle",class="MAGE",race="Human",level=10},"who")
            NS.Store:Observe({name="Second middle",class="MAGE",race="Human",level=10},"who")
            NS.Store:Observe({name="High",class="WARRIOR",race="Dwarf",level=60},"who")
            NS.Store:Observe({name="Unknown",level=0},"who")
            panel:Refresh()
            assert(#panel.navigation.links==3)
            assert(panel.navigation.links[1]:GetText()=="Overview")
            assert(panel.navigation.links[2]:GetText()=="Levels")
            assert(panel.navigation.links[3]:GetText()=="Guilds")
            ClickWidget(panel.navigation.links[2])
            assert(panel.navigation.selected==2 and panel.levelArea:IsVisible())
            assert(not panel.classChart:IsVisible() and not panel.guildBox:IsVisible())
            assert(#panel.levelBars==60)
            assert(panel.levelBars[1].level==1 and panel.levelBars[1].count==1)
            assert(panel.levelBars[10].level==10 and panel.levelBars[10].count==2)
            assert(panel.levelBars[60].level==60 and panel.levelBars[60].count==1)
            assert(panel.levelBars[2].count==0 and not panel.levelBars[2].fill:IsShown())
            assert(math.abs(panel.levelBars[10].fill:GetHeight()-2*panel.levelBars[1].fill:GetHeight())<0.01)
            assert(panel.levelUnknown:GetText()=="Unknown level: 1 (20%)")
            assert(panel.levelBars[1]:GetLeft()<panel.levelBars[10]:GetLeft())
            assert(panel.levelBars[10]:GetLeft()<panel.levelBars[60]:GetLeft())
            assert(#whoCalls==0 and #errors==0)
        ''')

    def test_guild_sort_headers_toggle_without_refetching(self):
        """Verifies that guild sort headers toggle without refetching."""
        self.check('''
            Observe("One","MAGE","Human","Zeta")
            Observe("Two","WARRIOR","Human","Alpha")
            panel:Refresh()
            ClickWidget(panel.navigation.links[3])
            local original=Batata_Scanner.GetCensus
            censusCalls=0
            Batata_Scanner=setmetatable({GetCensus=function(...)
                censusCalls=censusCalls+1
                return original(...)
            end},{__index=Batata_Scanner})
            ClickWidget(panel.toggles.guild[1])
            local rows=VisibleRows(panel.guildBox)
            assert(rows[1].label:GetText()=="Alpha")
            ClickWidget(panel.toggles.guild[1])
            rows=VisibleRows(panel.guildBox)
            assert(rows[1].label:GetText()=="Zeta")
            ClickWidget(panel.toggles.guild[2])
            rows=VisibleRows(panel.guildBox)
            assert(rows[1].label:GetText()=="Alpha" and rows[2].label:GetText()=="Zeta")
            assert(censusCalls==0)
            assert(NS.db.settings.censusSort.guild.key=="count")
            assert(#errors==0)
        ''')

    def test_race_donuts_show_all_races_class_distribution_and_cache_snapshots(self):
        """Verifies that race donuts show all races class distribution and cache snapshots."""
        self.check('''
            Observe("One","MAGE","Human","")
            Observe("Two","WARRIOR","Dwarf","")
            Observe("Three","MAGE","Unusual Race",nil)
            Observe("Four","WARRIOR",nil,nil)
            panel:Refresh()
            local added={}
            for optionIndex,option in ipairs(panel.raceOptions) do added[option.value]=true end
            assert(added.Human and added.Dwarf and added["Unusual Race"] and added.Unknown)
            assert(panel.raceDropdown==nil and panel.raceScroll==nil)
            local charts={}
            for chartIndex,chart in ipairs(panel.raceCharts) do
                assert(chart:IsVisible())
                charts[chart.race]=chart
            end
            assert(charts.Human.total==1 and #charts.Human.entries==7)
            assert(charts.Human.entries[1].token=="MAGE")
            assert(charts.Human.count:GetText()=="1")
            assert(charts.Human.share:GetText()=="25% of census")
            assert(charts.Dwarf.total==1 and #charts.Dwarf.entries==6)
            assert(charts.Unknown.entries[1].token=="WARRIOR")
            assert(charts["Unusual Race"].entries[1].token=="MAGE")
            local original=Batata_Scanner.GetCensus
            censusCalls=0
            Batata_Scanner=setmetatable({GetCensus=function(...)
                censusCalls=censusCalls+1
                return original(...)
            end},{__index=Batata_Scanner})
            panel:Draw()
            assert(censusCalls==0)
            assert(Batata_Scanner.GetCensus().total==4)
            assert(#errors==0)
        ''')

    def test_race_grid_hides_opposing_faction_even_from_native_filters_and_observations(self):
        """Verifies that race grid hides opposing faction even from native filters and observations."""
        self.check('''
            NS.db.settings.myFactionOnly=false
            C_CreatureInfo.GetRaceInfo=function(raceID)
                if raceID==2 then return {raceName="Orque"} end
            end
            C_FriendList.GetWhoRaceFilters=function()
                return {{name="Human"},{name="Orc"},{name="Orque"},{name="Troll"}}
            end
            Observe("Friendly","MAGE","Human","")
            NS.context.faction="Horde"
            Observe("Opposing","WARRIOR","Orque","")
            NS.context.faction="Alliance"
            panel:Refresh()
            assert(#panel.raceOptions==5)
            local hidden={Orc=true,Orque=true,Undead=true,Tauren=true,Troll=true,["Windshaper Skyborne"]=true}
            for optionIndex,option in ipairs(panel.raceOptions) do
                assert(not hidden[option.value], "opposing race must not reappear through filters or observations")
            end
            assert(RaceChart("Human").total==1)
            assert(Batata_Scanner.GetPlayer("Opposing")~=nil, "presentation must not delete stored observations")
            NS.context.faction="Horde"
            C_FriendList.GetWhoRaceFilters=function() return {{name="Human"},{name="Orque"}} end
            panel:Refresh()
            assert(#panel.raceOptions==5 and RaceChart("Orque").total==1)
            for optionIndex,option in ipairs(panel.raceOptions) do
                assert(option.value~="Human" and option.value~="Dwarf")
            end
            assert(#whoCalls==0 and #errors==0)
        ''')

    def test_empty_class_chart_does_not_invent_observations_and_race_extras_are_retained(self):
        """Verifies that empty class chart does not invent observations and race extras are retained."""
        self.check('''
            panel:Refresh()
            assert(#panel.classChart.entries==0 and panel.classChart.total==0)
            Observe("Unexpected","DRUID","Human",nil)
            panel:Refresh()
            local chart=RaceChart("Human")
            assert(#chart.entries==8 and chart.entries[1].token=="DRUID")
            assert(chart.total==1 and #chart.slices==1)
            assert(chart.slices[1].entry.count==1)
            assert(Batata_Scanner.GetPlayer("Unexpected").class=="Druid")
            assert(#errors==0)
        ''')

    def test_known_race_class_definitions_localize_and_keep_forever_combinations(self):
        """Verifies that known race class definitions localize and keep forever combinations."""
        self.check('''
            C_CreatureInfo.GetRaceInfo=function(raceID)
                if raceID==1 then return {raceName="Humain"} end
            end
            C_FriendList.GetWhoRaceFilters=function() return {{name="Humain"},{name="Dwarf"}} end
            Observe("Localized","MAGE","Humain",nil)
            panel:Refresh()
            local localizedRaces=0
            for optionIndex,option in ipairs(panel.raceOptions) do
                if option.value=="Humain" then localizedRaces=localizedRaces+1 end
            end
            assert(localizedRaces==1)
            local chart=RaceChart("Humain")
            assert(#chart.entries==7 and chart.entries[1].token=="MAGE")
            local classes={}
            for entryIndex,entry in ipairs(RaceChart("Dwarf").entries) do classes[entry.token]=entry.count end
            assert(classes.SHAMAN==0 and classes.PALADIN==0 and classes.MAGE==nil)
            assert(#RaceChart("High Order Skyborne").entries==5)
            assert(#errors==0)
        ''')

    def test_donut_hover_enlarges_only_the_hit_slice_and_shows_population_details(self):
        """Verifies that donut hover enlarges only the hit slice and shows population details."""
        self.check('''
            Observe("One","MAGE","Human","")
            Observe("Two","MAGE","Human","")
            Observe("Three","WARRIOR","Human","")
            Observe("Four","WARRIOR","Dwarf","")
            panel:Refresh()
            root:SetScale(0.75)
            local chart=RaceChart("Human")
            local normalWidth=chart.quads[1]:GetWidth()
            PointAtDonut(chart,0.25,0.8)
            assert(chart.hoveredEntry.token=="MAGE")
            assert(math.abs(chart.quads[1]:GetWidth()-normalWidth*1.08)<0.001)
            assert(math.abs(chart.quads[#chart.quads]:GetWidth()-normalWidth)<0.001)
            assert(GameTooltip:IsOwned(chart.ring) and GameTooltip:IsShown())
            assert(GameTooltip.lines[1]=="Human" and GameTooltip.lines[2]=="Mage")
            assert(GameTooltip.lines[3]=="Players: 2 of 3")
            assert(GameTooltip.lines[4]=="66.7% of this race")
            assert(GameTooltip.lines[5]=="50.0% of census")
            PointAtDonut(chart,0.25,1.04)
            assert(chart.hoveredEntry.token=="MAGE", "expanded edge must retain hover")
            PointAtDonut(chart,0.8,0.8)
            assert(chart.hoveredEntry.token=="WARRIOR")
            assert(math.abs(chart.quads[1]:GetWidth()-normalWidth)<0.001)
            PointAtDonut(chart,0.8,0.3)
            assert(chart.hoveredEntry==nil and not GameTooltip:IsShown())
            PointAtDonut(chart,0.25,1.12)
            assert(chart.hoveredEntry==nil)
            PointAtDonut(chart,0.25,0.8)
            chart.ring.scripts.OnLeave(chart.ring)
            assert(chart.hoveredEntry==nil and chart.ring.scripts.OnUpdate==nil)
            assert(not GameTooltip:IsShown())
            PointAtDonut(chart,0.25,0.8)
            ClickWidget(panel.navigation.links[2])
            assert(chart.hoveredEntry==nil and chart.ring.scripts.OnUpdate==nil)
            assert(not GameTooltip:IsShown() and #errors==0)
        ''')

    def test_malformed_saved_fields_cannot_crash_census_rendering(self):
        """Verifies that malformed saved fields cannot crash census rendering."""
        self.check('''
            NS.db.players=NS.Store:Load({
                {"Broken","Alliance","10",{}, {}, {}, "first", "last", {}},
                {name="Named Broken",faction="Alliance",level={},class={},race={},guild={},lastSeen={}},
                {"Valid","Alliance",10,"Mage","Human","",1,2,false}
            })
            panel:Refresh()
            assert(panel.snapshot.total==3 and panel.classChart.total==3)
            assert(panel.snapshot.byClass.Unknown==2 and RaceChart("Unknown").total==2)
            ClickWidget(panel.navigation.links[2])
            assert(panel.levelUnknown:GetText()=="Unknown level: 2 (67%)")
            ClickWidget(panel.navigation.links[3])
            assert(#VisibleRows(panel.guildBox)==0 and #errors==0)
        ''')

    def test_donut_repaints_only_changed_slices_and_skips_unchanged_redraws(self):
        """Verifies that donut repaints only changed slices and skips unchanged redraws."""
        self.check('''
            Observe("Mage","MAGE","Human","")
            Observe("Warrior","WARRIOR","Human","")
            Observe("Druid","DRUID","Human","")
            panel:Refresh()
            local chart=RaceChart("Human")
            local writes={}
            for quadIndex,quad in ipairs(chart.quads) do
                hooksecurefunc(quad,"SetVertexOffset",function()
                    writes[quadIndex]=(writes[quadIndex] or 0)+1
                end)
            end
            panel:Draw()
            assert(next(writes)==nil, "unchanged redraws must reuse existing geometry")
            local first=chart.slices[1]
            local second=chart.slices[2]
            local firstSteps=math.ceil((first.finish-first.start)*144)
            local secondSteps=math.ceil((second.finish-second.start)*144)
            PointAtDonut(chart,(first.start+first.finish)/2,0.8)
            for quadIndex=1,#chart.quads do
                assert((writes[quadIndex] or 0)==(quadIndex<=firstSteps and 4 or 0))
            end
            writes={}
            PointAtDonut(chart,(first.start+first.finish)/2,0.8)
            assert(next(writes)==nil, "moving within one slice must not repaint")
            PointAtDonut(chart,(second.start+second.finish)/2,0.8)
            for quadIndex=1,#chart.quads do
                assert((writes[quadIndex] or 0)==(quadIndex<=firstSteps+secondSteps and 4 or 0),
                    "a direct hover transition must repaint only the old and new slices once")
            end
            chart.ring:GetScript("OnLeave")(chart.ring)
            writes={}
            panel:Draw()
            assert(next(writes)==nil)
            mainFrame:SetSize(742,480)
            assert(next(writes)~=nil, "resizing must update cached geometry")
            writes={}
            panel:Draw()
            assert(next(writes)==nil and #errors==0)
        ''')

    def test_donut_cache_tracks_colors_distribution_and_reactivated_textures(self):
        """Verifies that donut cache tracks colors distribution and reactivated textures."""
        self.check('''
            Observe("Mage","MAGE","Human","")
            Observe("Warrior","WARRIOR","Human","")
            Observe("Druid","DRUID","Human","")
            panel:Refresh()
            local chart=RaceChart("Human")
            local firstQuad=chart.quads[1]
            local created=#chart.quads
            local function CheckTextures()
                local used=0
                for sliceIndex,slice in ipairs(chart.slices) do
                    used=used+math.max(1,math.ceil((slice.finish-slice.start)*144))
                end
                for quadIndex,quad in ipairs(chart.quads) do
                    assert(quad:IsShown()==(quadIndex<=used))
                end
                assert(#chart.paintedSlices==#chart.slices)
            end
            Observe("Warrior","MAGE","Human","")
            Observe("Druid","MAGE","Human","")
            panel:Refresh()
            assert(#chart.slices==1 and #chart.quads==created and chart.quads[1]==firstQuad)
            CheckTextures()
            RAID_CLASS_COLORS.MAGE.r=0.123
            panel:Draw()
            assert(chart.paintedSlices[1].red==0.123)
            assert(firstQuad.colorTexture[1]==0.123)
            Observe("Warrior","WARRIOR","Human","")
            Observe("Druid","DRUID","Human","")
            panel:Refresh()
            assert(#chart.slices==3 and #chart.quads==created and chart.quads[1]==firstQuad)
            CheckTextures()
            NS.db.players=NS.Store:Load({})
            NS.db.revision=NS.db.revision+1
            panel:Refresh()
            assert(chart.total==0 and #chart.slices==1 and chart.slices[1].entry==nil)
            CheckTextures()
            assert(#errors==0)
        ''')

    def test_empty_donuts_do_not_invent_slices_or_tooltips(self):
        """Verifies that empty donuts do not invent slices or tooltips."""
        self.check('''
            panel:Refresh()
            assert(#panel.raceOptions>=5)
            for chartIndex,chart in ipairs(panel.raceCharts) do
                assert(chart.total==0 and chart.count:GetText()=="0")
                assert(chart.share:GetText()=="No observations")
                assert(#chart.slices==1 and chart.slices[1].entry==nil)
                PointAtDonut(chart,0.25,0.8)
                assert(chart.hoveredEntry==nil)
                chart.ring.scripts.OnLeave(chart.ring)
            end
            assert(not GameTooltip:IsShown() or GameTooltip.owner==nil)
            assert(Batata_Scanner.GetCensus().total==0 and #whoCalls==0 and #errors==0)
        ''')

    def test_donut_grid_fits_both_window_sizes_with_all_races_and_reuses_artwork(self):
        """Verifies that donut grid fits both window sizes with all races and reuses artwork."""
        self.check('''
            NS.db.settings.myFactionOnly=false
            Observe("Unknown","MAGE",nil,nil)
            Observe("Extra","WARRIOR","Unusual Race",nil)
            panel:Refresh()
            assert(#panel.raceOptions==7)
            local chartsCreated=#panel.raceCharts
            for sizeIndex,size in ipairs({{800,790},{742,480},{800,790}}) do
                mainFrame:SetSize(size[1],size[2])
                panel:Draw()
                local classCenter=panel.classChart.ring:GetCenter()
                local overviewCenter=panel.overviewArea:GetCenter()
                assert(math.abs(classCenter-overviewCenter)<0.01)
                assert(panel.classChart:GetBottom()>panel.raceArea:GetTop())
                assert(panel.populationStats:GetRight()<panel.classChart:GetLeft())
                assert(panel.guildStats:GetLeft()>panel.classChart:GetRight())
                local populationCenter=panel.populationStats:GetCenter()
                local guildCenter=panel.guildStats:GetCenter()
                assert(math.abs(populationCenter+guildCenter-2*classCenter)<0.01)
                assert(math.abs(panel.populationStats.title:GetTop()-panel.guildStats.title:GetTop())<0.01)
                for groupIndex,group in ipairs({panel.populationStats,panel.guildStats}) do
                    assert(group:GetLeft()>=panel.overviewArea:GetLeft()-0.01)
                    assert(group:GetRight()<=panel.overviewArea:GetRight()+0.01)
                    assert(group.metrics[3].value:GetBottom()>panel.raceArea:GetTop())
                    assert(group.title.properties.SetJustifyH[1]=="CENTER")
                    for metricIndex,metric in ipairs(group.metrics) do
                        assert(metric.value:GetStringHeight()<=metric.value:GetHeight())
                        assert(metric.label.properties.SetJustifyH[1]=="CENTER")
                        assert(metric.value.properties.SetJustifyH[1]=="CENTER")
                        local opposite=panel.guildStats.metrics[metricIndex]
                        assert(math.abs(metric.label:GetTop()-opposite.label:GetTop())<0.01)
                        assert(math.abs(metric.value:GetTop()-opposite.value:GetTop())<0.01)
                    end
                end
                for chartIndex,chart in ipairs(panel.raceCharts) do
                    assert(chart:IsVisible() and chart.radius>20)
                    assert(chart:GetLeft()>=panel.raceArea:GetLeft()-0.01)
                    assert(chart:GetRight()<=panel.raceArea:GetRight()+0.01)
                    assert(chart:GetTop()<=panel.raceArea:GetTop()+0.01)
                    assert(chart.share:GetBottom()>=panel.raceArea:GetBottom()-0.01)
                    assert(chart.ring:GetBottom()>chart.label:GetTop())
                    assert(chart.share:GetTop()<chart.label:GetBottom())
                    assert(chart.label:GetStringHeight()<=chart.label:GetHeight())
                    assert(#chart.quads<=155)
                    for neighborIndex=chartIndex+1,#panel.raceCharts do
                        local neighbor=panel.raceCharts[neighborIndex]
                        assert(chart:GetRight()<=neighbor:GetLeft()+0.01
                            or neighbor:GetRight()<=chart:GetLeft()+0.01
                            or chart:GetTop()<=neighbor:GetBottom()+0.01
                            or neighbor:GetTop()<=chart:GetBottom()+0.01)
                    end
                end
            end
            local chart=RaceChart("Unknown")
            local firstQuad=chart.quads[1]
            panel:Draw()
            assert(#panel.raceCharts==chartsCreated and RaceChart("Unknown").quads[1]==firstQuad)
            Observe("Unknown","MAGE","Human",nil)
            Observe("Extra","WARRIOR","Human",nil)
            NS.db.settings.myFactionOnly=true
            panel:Refresh()
            assert(#panel.raceOptions==5)
            for chartIndex=#panel.raceOptions+1,#panel.raceCharts do
                assert(not panel.raceCharts[chartIndex]:IsShown())
            end
            assert(#errors==0)
        ''')

    def test_expanded_overview_preserves_compact_race_rows_and_order(self):
        """Verifies that expanded overview preserves compact race rows and order."""
        self.check('''
            panel:Refresh()
            local expandedColumns=math.floor(panel.raceArea:GetWidth()/panel.raceCharts[1]:GetWidth()+0.5)
            assert(expandedColumns==5, "opening expanded must preserve the compact five-race row")
            for extras=0,1 do
                if extras==1 then
                    Observe("Unknown","MAGE",nil,nil)
                    Observe("Extra","WARRIOR","Unusual Race",nil)
                end
                mainFrame:SetSize(742,480)
                panel:Refresh()
                local compactColumns=math.floor(panel.raceArea:GetWidth()/panel.raceCharts[1]:GetWidth()+0.5)
                local compactRadius=panel.raceCharts[1].radius
                local compactSlots={}
                for chartIndex,chart in ipairs(panel.raceCharts) do
                    compactSlots[chartIndex]={
                        race=chart.race,
                        row=math.floor((panel.raceArea:GetTop()-chart:GetTop())/chart:GetHeight()+0.5),
                        column=math.floor((chart:GetLeft()-panel.raceArea:GetLeft())/chart:GetWidth()+0.5)
                    }
                end
                for sizeIndex,size in ipairs({{800,790},{742,480},{800,790}}) do
                    mainFrame:SetSize(size[1],size[2])
                    panel:Draw()
                    local columns=math.floor(panel.raceArea:GetWidth()/panel.raceCharts[1]:GetWidth()+0.5)
                    assert(columns==compactColumns, "expanding must not reflow the race grid")
                    for chartIndex,chart in ipairs(panel.raceCharts) do
                        local slot=compactSlots[chartIndex]
                        local row=math.floor((panel.raceArea:GetTop()-chart:GetTop())/chart:GetHeight()+0.5)
                        local column=math.floor((chart:GetLeft()-panel.raceArea:GetLeft())/chart:GetWidth()+0.5)
                        assert(chart.race==slot.race and row==slot.row and column==slot.column)
                        assert(chart.radius>=compactRadius)
                        if size[1]==800 then assert(chart.radius>compactRadius) end
                    end
                end
            end
            assert(#errors==0)
        ''')

    def test_donut_quads_join_into_a_continuous_ring_without_line_fragments(self):
        """Verifies that donut quads join into a continuous ring without line fragments."""
        self.check('''
            Observe("One","MAGE","Human","")
            Observe("Two","WARRIOR","Human","")
            panel:Refresh()
            local chart=RaceChart("Human")
            local function Vertex(quad,vertexIndex)
                local offset=quad.vertexOffsets[vertexIndex]
                local baseX=(vertexIndex<=2 and -1 or 1)*quad:GetWidth()/2
                local baseY=(vertexIndex%2==1 and 1 or -1)*quad:GetHeight()/2
                return {baseX+offset[1],baseY+offset[2]}
            end
            local area=0
            for quadIndex,quad in ipairs(chart.quads) do
                assert(quad:GetObjectType()=="Texture" and quad:IsShown())
                assert(quad.properties.SetSnapToPixelGrid[1]==false)
                local outerStart=Vertex(quad,1)
                local innerStart=Vertex(quad,2)
                local outerEnd=Vertex(quad,3)
                local innerEnd=Vertex(quad,4)
                local nextQuad=chart.quads[quadIndex%#chart.quads+1]
                local nextOuter=Vertex(nextQuad,1)
                local nextInner=Vertex(nextQuad,2)
                for coordinateIndex=1,2 do
                    assert(math.abs(outerEnd[coordinateIndex]-nextOuter[coordinateIndex])<0.00001)
                    assert(math.abs(innerEnd[coordinateIndex]-nextInner[coordinateIndex])<0.00001)
                end
                assert(math.abs(math.sqrt(outerStart[1]^2+outerStart[2]^2)-chart.radius)<0.00001)
                assert(math.abs(math.sqrt(innerStart[1]^2+innerStart[2]^2)-chart.radius*0.6)<0.00001)
                local vertices={outerStart,innerStart,innerEnd,outerEnd}
                for vertexIndex,vertex in ipairs(vertices) do
                    local neighbor=vertices[vertexIndex%4+1]
                    area=area+(vertex[1]*neighbor[2]-neighbor[1]*vertex[2])/2
                end
            end
            local expectedArea=math.pi*chart.radius^2*(1-0.6^2)
            assert(math.abs(math.abs(area)/expectedArea-1)<0.001)
            assert(#chart.quads==144 and #errors==0)
        ''')

    def test_combined_donuts_remain_readable_in_both_window_modes(self):
        """Verifies that combined donuts remain readable in both window modes."""
        self.check('''
            panel:Refresh()
            assert(#panel.raceOptions==5 and RaceChart("Human").radius>50)
            assert(panel.classChart.radius>72)
            mainFrame:SetSize(742,480)
            assert(RaceChart("Human").radius>35 and panel.classChart.radius>55)
            assert(#errors==0)
        ''')

    def test_donut_refresh_updates_cached_counts_and_releases_stale_hover(self):
        """Verifies that donut refresh updates cached counts and releases stale hover."""
        self.check('''
            Observe("One","MAGE","Human","")
            panel:Refresh()
            local chart=RaceChart("Human")
            PointAtDonut(chart,0.25,0.8)
            assert(chart.hoveredEntry.count==1)
            Observe("Two","WARRIOR","Human","")
            panel:Refresh()
            assert(chart.total==2 and #chart.slices==2 and chart.hoveredEntry==nil)
            assert(not GameTooltip:IsShown())
            PointAtDonut(chart,0.25,0.8)
            assert(GameTooltip.lines[3]=="Players: 1 of 2")
            root:Hide()
            assert(chart.ring.scripts.OnUpdate==nil and chart.hoveredEntry==nil)
            assert(not GameTooltip:IsShown() and #errors==0)
        ''')

    def test_guild_search_excludes_unguilded_and_uses_unfiltered_scaling(self):
        """Verifies that guild search excludes unguilded and uses unfiltered scaling."""
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
        """Verifies that guild overflow is bounded and resets scroll after filtering."""
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

    def test_hidden_window_does_not_fetch_and_chart_entries_do_not_mutate_store(self):
        """Stops Census reads while the window is closed and keeps chart data detached."""
        self.check('''
            Observe("One","MAGE","Human","Alpha")
            panel:Refresh()
            panel.classChart.entries[1].count=999
            assert(Batata_Scanner.GetCensus().byClass.Mage==1)
            local original=NS.Store.GetCensusOverview
            censusCalls=0
            NS.Store.GetCensusOverview=function(...)
                censusCalls=censusCalls+1
                return original(...)
            end
            mainFrame:Hide()
            panel:Refresh()
            assert(censusCalls==0)
            mainFrame:Show()
            panel:Refresh()
            assert(censusCalls==0)
            mainFrame:Hide()
            Observe("Two","WARRIOR","Dwarf","")
            panel:Refresh()
            assert(censusCalls==0)
            mainFrame:Show()
            panel:Refresh()
            assert(censusCalls==1)
            assert(#errors==0)
        ''')

    def test_class_donut_hover_uses_census_percentages_and_cleans_up_on_navigation(self):
        """Verifies that class donut hover uses census percentages and cleans up on navigation."""
        self.check('''
            Observe("One","MAGE","Human","")
            Observe("Two","MAGE","Human","")
            Observe("Three","WARRIOR","Dwarf","")
            Observe("Four",nil,nil,nil)
            panel:Refresh()
            local chart=panel.classChart
            local normalWidth=chart.quads[1]:GetWidth()
            PointAtDonut(chart,0.25,0.8)
            assert(chart.hoveredEntry.token=="MAGE")
            assert(chart.quads[1]:GetWidth()>normalWidth)
            assert(GameTooltip:IsOwned(chart.ring) and GameTooltip:IsShown())
            assert(GameTooltip.lines[1]=="Classes" and GameTooltip.lines[2]=="Mage")
            assert(GameTooltip.lines[3]=="Players: 2 of 4")
            assert(GameTooltip.lines[4]=="50.0% of census" and #GameTooltip.lines==4)
            ClickWidget(panel.navigation.links[2])
            assert(chart.hoveredEntry==nil and chart.ring.scripts.OnUpdate==nil)
            assert(not GameTooltip:IsShown())
            ClickWidget(panel.navigation.links[1])
            assert(chart:IsVisible() and RaceChart("Human"):IsVisible())
            assert(#errors==0)
        ''')

    def test_population_details_handle_empty_data_unknown_levels_and_stable_ties(self):
        """Verifies that population details handle empty data unknown levels and stable ties."""
        self.check('''
            panel:Refresh()
            for metricIndex,metric in ipairs(panel.populationStats.metrics) do
                assert(metric.value:GetText()=="--")
            end
            for metricIndex,metric in ipairs(panel.guildStats.metrics) do
                assert(metric.value:GetText()=="0 (0%)")
            end
            NS.Store:Observe({name="Low",class="MAGE",race="Human",level=10,guild="Alpha"},"who")
            NS.Store:Observe({name="High",class="WARRIOR",race="Dwarf",level=50,guild=""},"who")
            NS.Store:Observe({name="Unknown",level=0},"who")
            panel:Refresh()
            assert(panel.populationStats.metrics[1].value:GetText()=="30.0")
            assert(panel.populationStats.metrics[2].value:GetText()=="Mage (33%)")
            assert(panel.populationStats.metrics[3].value:GetText()=="Dwarf (33%)")
            assert(panel.guildStats.metrics[3].value:GetText()=="1 (33%)")
            local count=panel.classChart.total
            panel:Draw()
            assert(panel.classChart.total==count and #whoCalls==0 and #errors==0)
        ''')


    def test_level_hover_reports_counts_and_cleans_up_on_refresh_and_navigation(self):
        """Verifies that level hover reports counts and cleans up on refresh and navigation."""
        self.check('''
            NS.Store:Observe({name="One",level=10},"who")
            NS.Store:Observe({name="Two",level=10},"who")
            NS.Store:Observe({name="Three",level=60},"who")
            panel:Refresh()
            ClickWidget(panel.navigation.links[2])
            local bar=panel.levelBars[10]
            bar.scripts.OnEnter(bar)
            assert(GameTooltip:IsOwned(bar) and GameTooltip:IsShown())
            assert(GameTooltip.lines[1]=="Level 10" and GameTooltip.lines[2]=="Players: 2")
            assert(GameTooltip.lines[3]=="66.7% of census")
            bar.scripts.OnLeave(bar)
            assert(not GameTooltip:IsShown())
            local empty=panel.levelBars[1]
            empty.scripts.OnEnter(empty)
            assert(GameTooltip.lines[2]=="Players: 0" and GameTooltip.lines[3]=="0.0% of census")
            empty.scripts.OnLeave(empty)
            bar.scripts.OnEnter(bar)
            NS.Store:Observe({name="Four",level=10},"who")
            panel:Refresh()
            assert(not GameTooltip:IsShown() and bar.count==3)
            bar.scripts.OnEnter(bar)
            assert(GameTooltip.lines[2]=="Players: 3" and GameTooltip.lines[3]=="75.0% of census")
            ClickWidget(panel.navigation.links[3])
            assert(not GameTooltip:IsShown() and not panel.levelArea:IsVisible())
            ClickWidget(panel.navigation.links[2])
            local original=Batata_Scanner.GetCensus
            censusCalls=0
            Batata_Scanner=setmetatable({GetCensus=function(...)
                censusCalls=censusCalls+1
                return original(...)
            end},{__index=Batata_Scanner})
            panel:Draw()
            assert(censusCalls==0 and panel.levelBars[10]==bar)
            bar.scripts.OnEnter(bar)
            root:Hide()
            assert(not GameTooltip:IsShown() and #whoCalls==0 and #errors==0)
        ''')

    def test_level_chart_handles_empty_unknown_only_and_known_level_data(self):
        """Verifies that level chart handles empty unknown only and known level data."""
        self.check('''
            panel:Refresh()
            ClickWidget(panel.navigation.links[2])
            assert(panel.noLevels:IsShown() and panel.noLevels:GetText()=="No players recorded yet.")
            assert(not panel.levelUnknown:IsShown())
            for levelIndex,bar in ipairs(panel.levelBars) do
                assert(bar.count==0 and not bar.fill:IsShown())
            end
            NS.Store:Observe({name="Unknown",level=0},"who")
            panel:Refresh()
            assert(panel.noLevels:IsShown() and panel.noLevels:GetText()=="No known levels recorded yet.")
            assert(panel.levelUnknown:GetText()=="Unknown level: 1 (100%)")
            NS.Store:Observe({name="Known",level=25},"who")
            panel:Refresh()
            assert(not panel.noLevels:IsShown() and panel.levelBars[25].count==1)
            assert(panel.levelUnknown:GetText()=="Unknown level: 1 (50%)")
            assert(Batata_Scanner.GetCensus().total==2 and #errors==0)
        ''')

    def test_level_chart_resizes_extends_range_and_reuses_bars_without_overlapping_labels(self):
        """Verifies that level chart resizes extends range and reuses bars without overlapping labels."""
        self.check('''
            NS.Store:Observe({name="Highest",level=61},"who")
            panel:Refresh()
            ClickWidget(panel.navigation.links[2])
            local firstBar=panel.levelBars[1]
            for rangeIndex,highest in ipairs({61,255,60}) do
                NS.Store:Observe({name="Highest",level=highest},"who")
                panel:Refresh()
                for sizeIndex,size in ipairs({{742,480},{800,790}}) do
                    mainFrame:SetSize(size[1],size[2])
                    panel:Draw()
                    local lastLabel
                    for level=1,highest do
                        local bar=panel.levelBars[level]
                        assert(bar:IsVisible() and bar.level==level)
                        assert(bar:GetLeft()>=panel.levelArea:GetLeft()-0.01)
                        assert(bar:GetRight()<=panel.levelArea:GetRight()+0.01)
                        assert(bar.fill:GetTop()<=panel.levelArea:GetTop()+0.01)
                        if bar.label:IsShown() then
                            assert(bar.label:GetStringWidth()<=bar.label:GetWidth())
                            if lastLabel then assert(lastLabel:GetRight()<=bar.label:GetLeft()) end
                            lastLabel=bar.label
                        end
                    end
                    for level=highest+1,#panel.levelBars do
                        assert(not panel.levelBars[level]:IsShown())
                    end
                    assert(panel.levelBars[highest].count==1)
                    assert(panel.levelBars[1]==firstBar and #panel.levelGrid<=5)
                    assert(panel.levelArea:GetFrameLevel()>panel.navigation.sections[2].backgroundFrame.batataInset:GetFrameLevel())
                end
            end
            assert(#panel.levelBars==255 and #errors==0)
        ''')


if __name__ == "__main__":
    unittest.main()
