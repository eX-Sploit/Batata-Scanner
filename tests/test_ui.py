"""Combined scanner and shell bindings; native artwork still needs in-game inspection."""

from pathlib import Path
import unittest

from harness import Harness


UI_SUPPORT = Path(__file__).with_name("ui_support.lua").read_text(encoding="utf-8")
MODULES = ("Core.lua", "Store.lua", "Scanner.lua", "Passive.lua", "API.lua",
           "Widgets.lua", "ScannerPanel.lua", "CensusPanel.lua", "UI.lua")


class UIContracts(unittest.TestCase):
    def setUp(self):
        self.client = Harness(setup=UI_SUPPORT, modules=MODULES)

    def check(self, source):
        self.client.execute(source)

    def test_shell_uses_right_icon_tabs_and_original_window_dimensions(self):
        self.check(r'''
            assert(BatataScanner_MainFrame==nil)
            NS.UI:Show()
            local frame=NS.UI.frame
            assert(frame==BatataScanner_MainFrame and frame:IsShown())
            assert(frame.template=="PortraitFrameTemplateMinimizable")
            assert(frame:GetTitleText():GetText()=="BatataScanner")
            assert(frame:GetHeight()==480 and frame:GetWidth()>=742)
            assert(#frame.Tabs==2)
            local first,second=frame.Tabs[1],frame.Tabs[2]
            assert(first.template=="LargeSideTabButtonTemplate" and first.tooltipText=="Scanner")
            assert(second.template=="LargeSideTabButtonTemplate" and second.tooltipText=="Census")
            local point,parent,relative,x,y=first:GetPoint()
            assert(point=="TOPLEFT" and parent==frame and relative=="TOPRIGHT" and x==0 and y==-60)
            assert(first.SelectedTexture:IsShown() and not second.SelectedTexture:IsShown())
            assert(NS.ScannerPanel.root:IsVisible() and not NS.CensusPanel.root:IsVisible())
            assert(#whoCalls==0)
            ClickWidget(NS.UI.modeButton)
            assert(frame:GetWidth()==800 and frame:GetHeight()==790)
            ClickWidget(NS.UI.modeButton)
            assert(frame:GetHeight()==480)
            NS.UI:Toggle()
            assert(not frame:IsShown())
            NS.UI:Toggle()
            assert(frame:IsShown())
            local registrations=0
            for _,name in ipairs(UISpecialFrames) do
                if name=="BatataScanner_MainFrame" or name=="BatataScanner_Dismiss" then
                    registrations=registrations+1
                end
            end
            assert(registrations==1 and #whoCalls==0 and #errors==0)
        ''')

    def test_navigation_shares_native_subsections_and_hides_settings_with_scanner(self):
        self.check(r'''
            NS.UI:Show()
            ClickWidget(NS.ScannerPanel.scanSettingsButton)
            assert(NS.ScannerPanel.scanSettings:IsShown())
            Tab("Census")
            assert(NS.CensusPanel.root:IsVisible() and not NS.ScannerPanel.root:IsVisible())
            assert(not NS.ScannerPanel.scanSettings:IsShown())
            assert(NS.UI.frame.Tabs[2].SelectedTexture:IsShown())
            assert(NS.CensusPanel.navigation.links[1].template=="TabSystemTopButtonTemplate")
            Tab("Guilds")
            assert(NS.CensusPanel.navigation.selected==3)
            Tab("Scanner")
            assert(NS.ScannerPanel.root:IsVisible() and not NS.CensusPanel.root:IsVisible())
            assert(not NS.ScannerPanel.scanSettings:IsShown())
            assert(#whoCalls==0 and #errors==0)
        ''')

    def test_escape_dismisses_search_settings_and_selection_before_window(self):
        self.check(r'''
            NS.Store:Observe({name="Alpha",level=60,class="MAGE",race="Human",guild=""},"who")
            NS.UI:Show()
            local frame=NS.UI.frame
            local panel=NS.ScannerPanel
            assert(panel.searching and BatataScanner_Dismiss:IsShown())
            BatataScanner_Dismiss:Hide()
            assert(frame:IsShown() and not panel.searching)
            Advance(1)
            assert(not panel.searching and not BatataScanner_Dismiss:IsShown())
            ClickWidget(panel.scanSettingsButton)
            assert(panel.scanSettings:IsShown() and BatataScanner_Dismiss:IsShown())
            BatataScanner_Dismiss:Hide()
            assert(frame:IsShown() and not panel.scanSettings:IsShown())
            panel.input.scripts.OnEnterPressed(panel.input)
            Advance(0)
            ClickWidget(panel.list.rows[1])
            assert(panel.selectedKey and BatataScanner_Dismiss:IsShown())
            BatataScanner_Dismiss:Hide()
            assert(frame:IsShown() and panel.selectedKey==nil)
            assert(#UISpecialFrames==1 and UISpecialFrames[1]=="BatataScanner_MainFrame")
            frame:Hide()
            assert(not frame:IsShown() and #whoCalls==0 and #errors==0)
        ''')

    def test_scanner_settings_and_playback_require_real_input_callbacks(self):
        self.check(r'''
            NS.UI:Show()
            local panel=NS.ScannerPanel
            ClickWidget(panel.scanSettingsButton)
            panel.passiveCheck:SetChecked(false)
            ClickWidget(panel.passiveCheck)
            assert(NS.db.settings.passiveEnabled==false)
            panel.worldClickCheck:SetChecked(true)
            ClickWidget(panel.worldClickCheck)
            assert(NS.db.settings.worldClickEnabled==true)
            panel.worldClickCheck:SetChecked(false)
            ClickWidget(panel.worldClickCheck)
            panel.minLevel:SetText("0")
            panel.maxLevel:SetText("99")
            panel.maxLevel:SetFocus(); panel.maxLevel:ClearFocus()
            panel.intervalEB:SetText("1")
            panel.intervalEB:SetFocus()
            ClickWidget(panel.scanSettings.doneButton)
            assert(NS.db.settings.minLevel==1 and NS.db.settings.maxLevel==60)
            assert(NS.db.settings.queryInterval==5)
            ClickWidget(panel.scanSettingsButton)
            assert(panel.minLevel:GetText()=="1" and panel.maxLevel:GetText()=="60")
            assert(panel.intervalEB:GetText()=="5")
            panel.customQuery:SetText('n-"Test"')
            panel.customQuery:SetFocus(); panel.customQuery:ClearFocus()
            ClickWidget(panel.scanSettings.doneButton)
            assert(not panel.scanSettings:IsShown())
            assert(#whoCalls==0)
            ClickWidget(panel.scanButton)
            assert(#whoCalls==1 and whoCalls[1]=='n-"Test"')
            assert(BatataScanner.GetScanStatus().awaiting)
            ClickWidget(panel.scanButton)
            assert(BatataScanner.GetScanStatus().paused)
            Advance(1)
            assert(#whoCalls==1)
            ClickWidget(panel.stopBtn)
            assert(not BatataScanner.GetScanStatus().running)
            assert(#whoCalls==1 and #errors==0)
        ''')

    def test_scanner_search_selects_detached_records_in_the_details_panel(self):
        self.check(r'''
            NS.Store:Observe({name="Alpha",level=60,class="MAGE",race="Human",guild="First Guild",zone="Stormwind"},"who")
            NS.Store:Observe({name="Beta",level=20,class="WARRIOR",race="Dwarf",guild="",zone="Ironforge"},"passive")
            NS.Store:Observe({name="Gamma",level=10,class="MAGE",race="Human",guild="Second Guild",zone="Stormwind"},"passive")
            NS.UI:Show()
            local panel=NS.ScannerPanel
            assert(panel.input.template=="SearchBoxTemplate")
            assert(panel.input:GetWidth()==180 and panel.input:GetHeight()==20)
            assert(panel.details:GetWidth()==320)
            assert(panel.list.headers[1]:GetText()=="Lvl")
            assert(panel.list.headers[2]:GetText()=="Name")
            assert(panel.list.headers[3]:GetText()=="Class")
            assert(panel.list.headers[4]:GetText()=="Guild")
            assert(panel.list.headers[5]:GetText()=="Last seen")
            panel.input:SetText("mage stormwind")
            panel.input.scripts.OnEnterPressed(panel.input)
            Advance(0)
            assert(panel.list:ItemCount()==2)
            local row=panel.list.rows[1]
            ClickWidget(row)
            assert(panel.selectedKey and row.sel:IsShown())
            assert(panel.detailsTitle:GetText()==row.item.name)
            assert(panel.detailsText:GetText():find("Stormwind",1,true))
            assert(panel.detailsText:GetText():find("Human",1,true))
            local storedName=row.item.name
            row.item.zone="Changed only in a result copy"
            assert(BatataScanner.GetPlayer(storedName).zone=="Stormwind")
            assert(panel:Escape() and panel.selectedKey==nil)
            assert(panel.detailsTitle:GetText()=="Entry details")
            panel.input:SetText("absent-player")
            panel.input.scripts.OnEnterPressed(panel.input)
            Advance(0)
            assert(panel.list:ItemCount()==0)
            assert(row.item==nil and not row:IsShown())
            assert(#errors==0)
        ''')

    def test_updates_coalesce_and_search_refresh_pauses_while_hidden(self):
        self.check(r'''
            local original=NS.Store.CreateSearch
            searchCount=0
            NS.Store.CreateSearch=function(...)
                searchCount=searchCount+1
                return original(...)
            end
            NS.UI:Show()
            Advance(0)
            local initial=searchCount
            assert(initial==1)
            NS:Notify("DATA_UPDATED"); NS:Notify("DATA_UPDATED"); NS:Notify("DATA_UPDATED")
            Advance(.2)
            assert(searchCount==initial,"observations should respect the browser refresh interval")
            Advance(29.8)
            assert(searchCount==initial+1,"coalesced updates should cause one refresh")
            NS.UI:Toggle()
            NS:Notify("DATA_UPDATED"); NS:Notify("DATA_UPDATED")
            Advance(31)
            assert(searchCount==initial+1,"hidden panels must not fetch or search")
            NS.UI:Show()
            Advance(0)
            assert(searchCount==initial+2,"opening the dirty scanner should refresh it")
            assert(#whoCalls==0 and #errors==0)
        ''')

    def test_search_sorting_reverses_and_scroll_fetches_only_visible_records(self):
        self.check(r'''
            NS.Store:BeginBatch()
            for index=1,1000 do
                NS.Store:Observe({name=string.format("Player%04d",index),level=index%60+1,class="MAGE",race="Human",guild="",zone="Stormwind"},"who")
            end
            NS.Store:EndBatch()
            local original=NS.CopyPlayer
            copyCount=0
            NS.CopyPlayer=function(...)
                copyCount=copyCount+1
                return original(...)
            end
            NS.UI:Show()
            local panel=NS.ScannerPanel
            panel.input:SetText("")
            panel.input.scripts.OnEnterPressed(panel.input)
            Advance(0)
            local list=panel.list
            assert(list:ItemCount()==1000)
            local visibleRows=0
            for _,row in ipairs(list.rows) do if row:IsShown() then visibleRows=visibleRows+1 end end
            assert(visibleRows<=list.renderRows and #list.rows<50)
            assert(copyCount<100,"search must not create copies for every matching record")
            local firstRow=list.rows[1]
            local initialFrames=#frames
            list.scroll.scripts.OnVerticalScroll(list.scroll,1000*NS.Widgets.ROW_H)
            local foundLast=false
            for _,row in ipairs(list.rows) do
                if row.item and row.item.name=="Player1000" then foundLast=true end
            end
            assert(foundLast and list.rows[1]==firstRow and #frames==initialFrames)
            assert(copyCount<200,"scrolling must fetch only its next visible window")
            ClickWidget(list.headers[1])
            Advance(0)
            local firstLevel=list.rows[1].item.level
            ClickWidget(list.headers[1])
            Advance(0)
            assert(list.rows[1].item.level~=firstLevel,"repeated header clicks reverse sorting")
            assert(#errors==0)
        ''')


    def test_completed_submitted_search_restores_window_escape_after_clearing_selection(self):
        self.check(r'''
            NS.Store:Observe({name="Alpha",class="MAGE"},"who")
            NS.UI:Show()
            Advance(1)
            local panel=NS.ScannerPanel
            ClickWidget(panel.list.rows[1])
            assert(panel.selectedKey=="Alpha" and BatataScanner_Dismiss:IsShown())
            panel.input:SetText("Alpha")
            panel.input.scripts.OnEnterPressed(panel.input)
            Advance(0)
            assert(panel.selectedKey==nil and not panel.searching)
            assert(not BatataScanner_Dismiss:IsShown(), "a completed search must release the selection escape proxy")
            assert(#UISpecialFrames==1 and UISpecialFrames[1]=="BatataScanner_MainFrame")
            assert(NS.UI.frame:IsShown() and #errors==0)
        ''')

    def test_hidden_interrupted_refresh_retries_when_reopened_with_existing_results(self):
        self.check(r'''
            NS.Store:Observe({name="Alpha",class="MAGE"},"who")
            NS.UI:Show()
            Advance(1)
            local panel=NS.ScannerPanel
            assert(panel.list:ItemCount()==1)
            NS.Store:Observe({name="Beta",class="MAGE"},"who")
            Advance(.3)
            assert(panel.list:ItemCount()==1, "refresh delay should retain the older visible results")
            panel:Submit(true)
            assert(panel.searching)
            NS.UI:Toggle()
            assert(not panel.searching)
            Advance(31)
            assert(panel.list:ItemCount()==1, "hidden work must stop")
            NS.UI:Show()
            Advance(0)
            assert(panel.list:ItemCount()==2 and not panel.searching)
            assert(panel.list.rows[2].item.name=="Beta")
            assert(#errors==0)
        ''')

if __name__ == "__main__":
    unittest.main()
