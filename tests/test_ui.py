"""Combined scanner and shell bindings; native artwork still needs in-game inspection."""

from pathlib import Path
import unittest

from harness import Harness


# Shared UI templates, geometry helpers, and mock client globals.
UI_SUPPORT = Path(__file__).with_name("ui_support.lua").read_text(encoding="utf-8")
# Real addon modules loaded together for shell-level UI contract tests.
MODULES = ("Core.lua", "Store.lua", "Scanner.lua", "Passive.lua", "API.lua",
           "Widgets.lua", "ScannerPanel.lua", "CensusPanel.lua", "WelcomePanel.lua", "UI.lua",
           "MinimapButton.lua")


class UIContracts(unittest.TestCase):
    """Checks addon window navigation, scanner UI, and user interactions."""
    def setUp(self):
        """Creates a fresh test fixture before each test."""
        self.client = Harness(setup=UI_SUPPORT +
            'Batata_Scanner_DB={schemaVersion=1,settings={queryInterval=5}}', modules=MODULES)

    def check(self, source):
        """Runs a Lua assertion or statement in the current test fixture."""
        self.client.execute(source)

    def test_shell_uses_right_icon_tabs_and_original_window_dimensions(self):
        """Verifies that shell uses right icon tabs and original window dimensions."""
        self.check(r'''
            assert(Batata_Scanner_MainFrame==nil)
            NS.UI:Show()
            local frame=NS.UI.frame
            assert(frame==Batata_Scanner_MainFrame and frame:IsShown())
            assert(frame.template=="PortraitFrameTemplateMinimizable")
            assert(frame:GetTitleText():GetText()=="Batata Scanner")
            assert(frame:GetHeight()==480 and frame:GetWidth()>=742)
            assert(#frame.Tabs==3)
            local first,second,third=frame.Tabs[1],frame.Tabs[2],frame.Tabs[3]
            assert(first.template=="LargeSideTabButtonTemplate" and first.tooltipText=="Welcome")
            assert(second.template=="LargeSideTabButtonTemplate" and second.tooltipText=="Scanner")
            assert(third.template=="LargeSideTabButtonTemplate" and third.tooltipText=="Census")
            local point,parent,relative,x,y=first:GetPoint()
            assert(point=="TOPLEFT" and parent==frame and relative=="TOPRIGHT" and x==0 and y==-60)
            assert(first.SelectedTexture:IsShown() and not second.SelectedTexture:IsShown())
            assert(NS.WelcomePanel.root:IsVisible() and not NS.ScannerPanel.root:IsVisible())
            assert(not NS.CensusPanel.root:IsVisible())
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
                if name=="Batata_Scanner_MainFrame" or name=="Batata_Scanner_Dismiss" then
                    registrations=registrations+1
                end
            end
            assert(registrations==1 and #whoCalls==0 and #errors==0)
        ''')

    def test_window_stacks_as_one_top_level_tree_on_show_and_child_clicks(self):
        """Verifies that window stacks as one top level tree on show and child clicks."""
        self.check(r'''
            NS.UI:Show()
            local frame=NS.UI.frame
            assert(frame:IsToplevel(), "content clicks must raise the whole window")
            assert(frame.raiseCount==1, "opening must raise the window")
            assert(frame:GetFrameStrata()=="HIGH")
            local peer=CreateFrame("Frame",nil,UIParent)
            peer:SetFrameStrata("HIGH")
            peer:SetToplevel(true)
            local peerButton=CreateFrame("Button",nil,peer)
            peerButton:SetScript("OnClick",function() end)
            ClickWidget(peerButton)
            assert(peer.raiseCount==1 and frame.raiseCount==1)
            ClickWidget(NS.UI.modeButton)
            assert(frame.raiseCount==2, "clicking a child must raise its top-level owner")
            NS.UI:Toggle()
            frame:Show()
            assert(frame.raiseCount==3, "reopening directly must raise the window")
            assert(#whoCalls==0 and #errors==0)
        ''')

    def test_welcome_is_the_first_page_and_cards_open_their_pages(self):
        """Verifies that welcome is the first page and cards open their pages."""
        self.check(r'''
            NS.UI:Show()
            local welcome=NS.WelcomePanel
            assert(welcome.root:IsVisible() and NS.UI.pageTitle:GetText()=="Welcome")
            local welcomeLogo=welcome.pages[1].logo
            assert(welcome.icon=="Interface\\AddOns\\Batata Scanner\\Assets\\batata-scanner-icon.png")
            assert(welcomeLogo.texture==welcome.icon and welcomeLogo:GetWidth()==96 and welcomeLogo:GetHeight()==96)
            assert(NS.UI.pageTitle.properties.SetJustifyH[1]=="LEFT")
            assert(#welcome.navigation.links==2 and welcome.navigation.selected==1)
            assert(welcome.navigation.links[1]:GetText()=="Overview")
            assert(welcome.navigation.links[2]:GetText()=="Quick start")
            assert(welcome.navigation.links[3]==nil)
            assert(welcome.pages[1].subtitle:GetText():find("adventures",1,true))
            assert(welcome.pages[1].cards[1].body:GetText():find("players you encounter",1,true))
            assert(welcome.version:GetText()=="Version "..TOC_VERSION)
            Tab("Quick start")
            assert(welcome.pages[2].root:IsVisible() and not welcome.pages[1].root:IsVisible())
            assert(welcome.pages[2].cards[1]:GetHeight()>0)
            assert(welcome.pages[2].cards[1].title:GetText()=="Start scanning")
            assert(welcome.pages[2].cards[1].body:GetText():find("press Play",1,true))
            assert(welcome.pages[2].cards[1].body:GetText():find("click in the world",1,true))
            Tab("Overview")
            ClickWidget(welcome.pages[1].cards[2])
            assert(NS.CensusPanel.root:IsVisible() and not welcome.root:IsVisible())
            Tab("Welcome")
            ClickWidget(welcome.pages[1].cards[1])
            assert(NS.ScannerPanel.root:IsVisible() and NS.UI.pageTitle:GetText()=="Scanner")
            local point,parent,relative,offsetX,offsetY=NS.UI.frame.Inset:GetPoint(1)
            assert(point=="TOPLEFT" and offsetY==-60)
            Tab("Census")
            point,parent,relative,offsetX,offsetY=NS.UI.frame.Inset:GetPoint(1)
            assert(point=="TOPLEFT" and offsetY==-83)
            assert(#whoCalls==0 and #errors==0)
        ''')

    def test_minimap_button_toggles_window_and_saves_dragged_angle(self):
        """Verifies that minimap button toggles window and saves dragged angle."""
        self.check(r'''
            local button=Batata_Scanner_MinimapButton
            assert(button and button:GetParent()==Minimap and NS.db.minimap.angle==225)
            assert(NS.MinimapButton.iconTexture.texture==NS.iconTexture)
            assert(Batata_Scanner_MainFrame==nil)
            ClickWidget(button)
            assert(NS.UI.frame:IsShown())
            ClickWidget(button)
            assert(not NS.UI.frame:IsShown())
            local centerX,centerY=Minimap:GetCenter()
            cursorX,cursorY=centerX,centerY+50
            button.scripts.OnDragStart(button)
            button.scripts.OnUpdate(button,0)
            button.scripts.OnDragStop(button)
            assert(NS.db.minimap.angle==90 and button.scripts.OnUpdate==nil)
            local point,anchor,relative,offsetX,offsetY=button:GetPoint()
            assert(point=="CENTER" and anchor==Minimap and math.abs(offsetX)<0.001 and offsetY==75)
            assert(#whoCalls==0 and #errors==0)
        ''')

    def test_navigation_shares_native_subsections_and_hides_settings_with_scanner(self):
        """Verifies that navigation shares native subsections and hides settings with scanner."""
        self.check(r'''
            NS.UI:Show()
            Tab("Scanner")
            ClickWidget(NS.ScannerPanel.scanSettingsButton)
            local dialog=NS.ScannerPanel.scanSettings
            assert(dialog:IsShown() and dialog:GetWidth()==300)
            local point,anchor,relative,offsetX,offsetY=dialog:GetPoint()
            assert(point=="BOTTOMLEFT" and anchor==NS.UI.frame and relative=="BOTTOMRIGHT")
            assert(offsetX==0 and offsetY==0 and dialog:GetNumPoints()==1)
            assert(dialog.title==nil and dialog.closeButton==nil and dialog.scripts.OnDragStart==nil)
            assert(dialog.doneButton:GetWidth()==72 and dialog.doneButton:GetHeight()==20)
            assert(dialog.doneButton:GetText()=="Save")
            local panel=NS.ScannerPanel
            local content=panel.overrideCheck:GetParent()
            assert(content:GetParent().title:GetText()=="Settings")
            local behaviorLabel=select(2,panel.behaviorDropdown:GetPoint())
            local speedLabel=select(2,panel.speedDropdown:GetPoint())
            local retentionLabel=select(2,panel.retentionDropdown:GetPoint())
            local behaviorOffset=select(5,behaviorLabel:GetPoint())
            local speedOffset=select(5,speedLabel:GetPoint())
            local retentionOffset=select(5,retentionLabel:GetPoint())
            local overrideOffset=select(5,panel.overrideCheck:GetPoint())
            assert(speedLabel:GetText()=="Scan speed" and panel.intervalEB==nil)
            assert(behaviorOffset>speedOffset and speedOffset>overrideOffset)
            assert(behaviorOffset-speedOffset>=30 and speedOffset-overrideOffset>=30)
            assert(speedOffset-retentionOffset>=30 and retentionOffset-overrideOffset>=30)
            assert(panel.overrideCheck:GetBottom()>panel.overrideGroup:GetTop())
            assert(panel.overrideGroup:GetBottom()>=content:GetBottom())
            Tab("Census")
            assert(NS.CensusPanel.root:IsVisible() and not NS.ScannerPanel.root:IsVisible())
            assert(not NS.ScannerPanel.scanSettings:IsShown())
            assert(NS.UI.frame.Tabs[3].SelectedTexture:IsShown())
            assert(NS.CensusPanel.navigation.links[1].template=="TabSystemTopButtonTemplate")
            Tab("Guilds")
            assert(NS.CensusPanel.navigation.selected==3)
            Tab("Scanner")
            assert(NS.ScannerPanel.root:IsVisible() and not NS.CensusPanel.root:IsVisible())
            assert(not NS.ScannerPanel.scanSettings:IsShown())
            assert(#whoCalls==0 and #errors==0)
        ''')

    def test_escape_dismisses_search_and_settings_before_window(self):
        """Verifies that escape dismisses search and settings before window."""
        self.check(r'''
            NS.Store:Observe({name="Alpha",level=60,class="MAGE",race="Human",guild=""},"who")
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            local frame=NS.UI.frame
            local panel=NS.ScannerPanel
            assert(panel.searching and Batata_Scanner_Dismiss:IsShown())
            Batata_Scanner_Dismiss:Hide()
            assert(frame:IsShown() and not panel.searching)
            Advance(1)
            assert(not panel.searching and not Batata_Scanner_Dismiss:IsShown())
            ClickWidget(panel.scanSettingsButton)
            assert(panel.scanSettings:IsShown() and Batata_Scanner_Dismiss:IsShown())
            Batata_Scanner_Dismiss:Hide()
            assert(frame:IsShown() and not panel.scanSettings:IsShown())
            assert(#UISpecialFrames==1 and UISpecialFrames[1]=="Batata_Scanner_MainFrame")
            frame:Hide()
            assert(not frame:IsShown() and #whoCalls==0 and #errors==0)
        ''')

    def test_scanner_settings_and_playback_require_real_input_callbacks(self):
        """Verifies that scanner settings and playback require real input callbacks."""
        self.check(r'''
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            local panel=NS.ScannerPanel
            assert(Batata_Scanner.GetScanStatus().running and panel.scanStatus:GetText()=="Scanning")
            ClickWidget(panel.stopBtn)
            Advance(0.2)
            assert(panel.scanStatus:GetText()=="Stopped")
            ClickWidget(panel.scanSettingsButton)
            assert(panel.passiveCheck==nil and panel.worldClickCheck==nil and panel.customQuery==nil)
            assert(not panel.overrideCheck:GetChecked() and not panel.minLevel:IsEnabled())
            panel.behaviorDropdown:Select(1)
            assert(#panel.classChecks==9)
            assert(panel.classChecks[1]:GetChecked() and not panel.classChecks[2]:IsEnabled())
            panel.overrideCheck:SetChecked(true)
            ClickWidget(panel.overrideCheck)
            assert(not NS.db.settings.overrideDefaults and panel.minLevel:IsEnabled())
            panel.minLevel:SetText("0")
            panel.maxLevel:SetText("99")
            panel.maxLevel:SetFocus(); panel.maxLevel:ClearFocus()
            panel.speedDropdown:Select(1)
                for classIndex,classCheck in ipairs(panel.classChecks) do
                    classCheck:SetChecked(classCheck.className=="Mage")
                end
            assert(NS.db.settings.scanClasses==nil and #whoCalls==0)
            ClickWidget(panel.scanSettings.doneButton)
            assert(not panel.scanSettings:IsShown() and NS.db.settings.overrideDefaults)
            assert(NS.db.settings.minLevel==1 and NS.db.settings.maxLevel==60)
            assert(NS.db.settings.queryInterval==6 and #NS.db.settings.scanClasses==1)
            assert(NS.db.settings.scanClasses[1]=="Mage")
            assert(#whoCalls==1 and whoCalls[1]=='c-"Mage" 1-10', "Save restarts the changed sweep")
            assert(Batata_Scanner.GetScanStatus().awaiting)
            ClickWidget(panel.scanSettingsButton)
            assert(panel.minLevel:GetText()=="1" and panel.maxLevel:GetText()=="60")
            assert(panel.speedDropdown:GetValue()==6 and not panel.classChecks[2]:GetChecked())
            ClickWidget(panel.scanSettings.doneButton)
            assert(not panel.scanSettings:IsShown() and #whoCalls==1, "unchanged scope keeps the sweep")
            ClickWidget(panel.scanButton)
            assert(Batata_Scanner.GetScanStatus().paused)
            Advance(1)
            assert(#whoCalls==1)
            ClickWidget(panel.stopBtn)
            assert(not Batata_Scanner.GetScanStatus().running)
            assert(#whoCalls==1 and #errors==0)
        ''')

    def test_scan_speed_defaults_to_balanced_and_saved_presets_control_cooldown(self):
        """Verifies that scan speed defaults to balanced and saved presets control cooldown."""
        for preset_index, interval in enumerate((6, 15, 30), start=1):
            with self.subTest(interval=interval):
                self.client = Harness(setup=UI_SUPPORT, modules=MODULES)
                self.client.execute(f"presetIndex={preset_index}; expectedInterval={interval}")
                self.check('''
                    NS.UI:Show()
                    NS.UI:SelectPage("Scanner")
                    local panel=NS.ScannerPanel
                    local planned=NS.Scanner:GetStatus().plannedQueries
                    ClickWidget(panel.scanSettingsButton)
                    local options=panel.speedDropdown.options
                    assert(#options==3)
                    assert(options[1].label=="Fast" and options[1].value==6)
                    assert(options[2].label=="Balanced" and options[2].value==15)
                    assert(options[3].label=="Slow" and options[3].value==30)
                    assert(panel.speedDropdown:GetValue()==15 and NS.db.settings.queryInterval==15)
                    panel.speedDropdown:Select(presetIndex)
                    assert(NS.db.settings.queryInterval==15)
                    ClickWidget(panel.scanSettings.doneButton)
                    assert(NS.db.settings.queryInterval==expectedInterval)
                    assert(NS.Scanner:GetStatus().plannedQueries==planned and #whoCalls==0)
                    ClickWidget(panel.scanSettingsButton)
                    assert(panel.speedDropdown:GetValue()==expectedInterval)
                    Batata_Scanner_Dismiss:Hide()
                    Click(function() assert(NS.Scanner:Continue()) end)
                    Deliver({})
                    assert(NS.Scanner:GetStatus().cooldown==expectedInterval)
                    Advance(expectedInterval-1)
                    Click(function() assert(not NS.Scanner:Continue()) end)
                    assert(#whoCalls==1)
                    Advance(1)
                    Click(function() assert(NS.Scanner:Continue()) end)
                    assert(#whoCalls==2 and #errors==0)
                ''')
                saved_interval = self.client.execute(
                    "Emit('PLAYER_LOGOUT'); return Batata_Scanner_DB.settings.queryInterval")
                self.assertEqual(saved_interval, interval)
                restored = Harness(setup=UI_SUPPORT +
                    f'Batata_Scanner_DB={{schemaVersion=1,settings={{queryInterval={saved_interval}}}}}',
                    modules=MODULES)
                restored.execute('''
                    NS.UI:Show()
                    NS.UI:SelectPage("Scanner")
                    ClickWidget(NS.ScannerPanel.scanSettingsButton)
                ''')
                self.assertEqual(restored.execute("return NS.ScannerPanel.speedDropdown:GetValue()"), interval)

    def test_legacy_scan_intervals_map_to_presets_only_when_saved(self):
        """Verifies that legacy scan intervals map to presets only when saved."""
        self.check('''
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            local panel=NS.ScannerPanel
            Advance(0)
            for caseIndex,case in ipairs({{5,6},{6,6},{7,15},{15,15},{20,30},{30,30},{60,30}}) do
                NS.db.settings.queryInterval=case[1]
                ClickWidget(panel.scanSettingsButton)
                assert(panel.speedDropdown:GetValue()==case[2])
                Batata_Scanner_Dismiss:Hide()
                assert(NS.db.settings.queryInterval==case[1])
                ClickWidget(panel.scanSettingsButton)
                ClickWidget(panel.scanSettings.doneButton)
                assert(NS.db.settings.queryInterval==case[2])
            end
            assert(#whoCalls==0 and #errors==0)
        ''')

    def test_scan_behavior_dropdown_restarts_the_sweep_on_save(self):
        """Verifies that scan behavior dropdown restarts the sweep on save."""
        self.check(r'''
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            local panel=NS.ScannerPanel
            ClickWidget(panel.scanSettingsButton)
            local dropdown=panel.behaviorDropdown
            assert(#dropdown.options==3 and dropdown:IsEnabled())
            assert(dropdown.options[1].label=="In Order" and dropdown.options[1].value=="ordered")
            assert(dropdown.options[2].label=="Reversed" and dropdown.options[2].value=="reversed")
            assert(dropdown.options[3].label=="Random" and dropdown.options[3].value=="random")
            assert(dropdown:GetValue()=="random" and NS.db.settings.scanBehavior=="random")
            dropdown:Select(2)
            assert(NS.db.settings.scanBehavior=="random" and #whoCalls==0)
            ClickWidget(panel.scanSettings.doneButton)
            assert(NS.db.settings.scanBehavior=="reversed" and not NS.db.settings.overrideDefaults)
            assert(not panel.scanSettings:IsShown() and #whoCalls==1 and whoCalls[1]=="51-60")
            Deliver({})
            Advance(6)
            ClickWidget(panel.scanSettingsButton)
            assert(dropdown:GetValue()=="reversed")
            ClickWidget(panel.scanSettings.doneButton)
            assert(#whoCalls==1 and Batata_Scanner.GetScanStatus().currentQuery=="41-50")
            ClickWidget(panel.scanSettingsButton)
            dropdown:Select(1)
            ClickWidget(panel.scanSettings.doneButton)
            assert(NS.db.settings.scanBehavior=="ordered" and #whoCalls==2 and whoCalls[2]=="1-10")
            Deliver({})
            Advance(6)
            ClickWidget(panel.scanSettingsButton)
            dropdown:Select(3)
            assert(NS.db.settings.scanBehavior=="ordered")
            math.random=function(choiceCount) return 1 end
            ClickWidget(panel.scanSettings.doneButton)
            assert(NS.db.settings.scanBehavior=="random" and #whoCalls==3 and whoCalls[3]=="51-60")
            assert(#errors==0)
        ''')

    def test_throttled_playback_stays_running_and_recovers_after_stop(self):
        """Verifies that throttled playback stays running and recovers after stop."""
        self.check(r'''
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            local panel=NS.ScannerPanel
            ClickWidget(panel.stopBtn)
            ClickWidget(panel.scanButton)
            Emit("CHAT_MSG_SYSTEM","You must wait a moment longer before using /who again")
            NS.UI:Refresh()
            assert(panel.scanStatus:GetText()=="Scanning" and Batata_Scanner.GetScanStatus().cooldown==12)
            assert(panel.scanButton:IsEnabled() and panel.stopBtn:IsEnabled())
            assert(not panel.scanButton.playIcon:IsShown() and panel.scanButton.pauseIcon[1]:IsShown())
            GameTooltip:ClearLines()
            panel.scanStatusHint:GetScript("OnEnter")(panel.scanStatusHint)
            assert(GameTooltip:IsShown() and GameTooltip:IsOwned(panel.scanStatusHint))
            assert(table.concat(GameTooltip.lines," "):find("throttled",1,true))
            panel.scanStatusHint:GetScript("OnLeave")(panel.scanStatusHint)
            assert(not GameTooltip:IsShown())
            Advance(12.2)
            assert(panel.scanStatus:GetText()=="Scanning" and panel.scanButton:IsEnabled())
            assert(#whoCalls==1)
            Click(function() WorldFrame:GetScript("OnMouseDown")(WorldFrame) end)
            Emit("UI_ERROR_MESSAGE",123,"You must wait a moment longer before using /who again.")
            NS.UI:Refresh()
            ClickWidget(panel.stopBtn)
            NS.UI:Refresh()
            assert(not panel.scanButton:IsEnabled() and not panel.stopBtn:IsEnabled())
            Advance(12.2)
            assert(panel.scanStatus:GetText()=="Stopped" and panel.scanButton:IsEnabled())
            ClickWidget(panel.scanButton)
            assert(#whoCalls==3 and Batata_Scanner.GetScanStatus().awaiting and #errors==0)
        ''')

    def test_native_who_hold_follows_parent_visibility_and_tab_switches(self):
        """Verifies that native who hold follows parent visibility and tab switches."""
        self.check(r'''
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            local panel=NS.ScannerPanel
            LFGParentFrame=CreateFrame("Frame","LFGParentFrame",UIParent)
            LFGParentFrame:Hide()
            LFGWhoListFrame:SetParent(LFGParentFrame)
            LFGWhoListFrame:Show()
            assert(LFGWhoListFrame:IsShown() and not LFGWhoListFrame:IsVisible())
            assert(not Batata_Scanner.GetScanStatus().nativeWhoOpen)
            LFGParentFrame:Show()
            Advance(0.2)
            assert(panel.scanStatus:GetText()=="Paused: Who")
            assert(panel.scanButton:IsEnabled() and panel.stopBtn:IsEnabled())
            assert(not panel.scanButton.playIcon:IsShown() and panel.scanButton.pauseIcon[1]:IsShown())
            Click(function() WorldFrame:GetScript("OnMouseDown")(WorldFrame) end)
            assert(#whoCalls==0)
            LFGParentFrame:Hide()
            Advance(0.2)
            assert(LFGWhoListFrame:IsShown() and not Batata_Scanner.GetScanStatus().nativeWhoOpen)
            assert(panel.scanStatus:GetText()=="Scanning" and #whoCalls==0)
            LFGParentFrame:Show()
            Advance(0.2)
            assert(panel.scanStatus:GetText()=="Paused: Who")
            LFGWhoListFrame:Hide()
            Advance(0.2)
            assert(LFGParentFrame:IsVisible() and panel.scanStatus:GetText()=="Scanning")
            assert(#whoCalls==0)
            Click(function() WorldFrame:GetScript("OnMouseDown")(WorldFrame) end)
            assert(#whoCalls==1)
            Deliver({})
            LFGWhoListFrame:Show()
            Advance(6)
            Click(function() WorldFrame:GetScript("OnMouseDown")(WorldFrame) end)
            assert(#whoCalls==1)
            LFGParentFrame:Hide()
            Advance(0.2)
            assert(#whoCalls==1)
            Click(function() WorldFrame:GetScript("OnMouseDown")(WorldFrame) end)
            assert(#whoCalls==2 and #errors==0)
        ''')

    def test_combat_and_battleground_holds_update_labels_and_preserve_manual_pause(self):
        """Verifies that combat and battleground holds update labels and preserve manual pause."""
        self.check('''
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            Advance(0)
            local panel=NS.ScannerPanel
            playerCombat=true
            Emit("PLAYER_REGEN_DISABLED")
            Advance(0.2)
            assert(panel.scanStatus:GetText()=="Paused: Combat")
            assert(panel.scanButton:IsEnabled() and panel.stopBtn:IsEnabled())
            assert(not panel.scanButton.playIcon:IsShown())
            instanceKind="pvp"
            Emit("ZONE_CHANGED_NEW_AREA")
            Advance(0.2)
            assert(panel.scanStatus:GetText()=="Paused: Combat")
            playerCombat=false
            Emit("PLAYER_REGEN_ENABLED")
            Advance(0.2)
            assert(panel.scanStatus:GetText()=="Paused: Battleground" and #whoCalls==0)
            GameTooltip:ClearLines()
            panel.scanStatusHint:GetScript("OnEnter")(panel.scanStatusHint)
            assert(table.concat(GameTooltip.lines," "):find("battleground",1,true))
            ClickWidget(panel.scanButton)
            assert(Batata_Scanner.GetScanStatus().paused and panel.scanStatus:GetText()=="Paused")
            assert(panel.scanButton.playIcon:IsShown() and not panel.scanButton:IsEnabled())
            instanceKind="none"
            Emit("ZONE_CHANGED_NEW_AREA")
            Advance(0.2)
            assert(panel.scanStatus:GetText()=="Paused" and panel.scanButton:IsEnabled())
            assert(#whoCalls==0)
            ClickWidget(panel.scanButton)
            assert(#whoCalls==1 and Batata_Scanner.GetScanStatus().awaiting and #errors==0)
        ''')

    def test_environment_holds_do_not_clear_the_native_who_hold(self):
        """Verifies that environment holds do not clear the native who hold."""
        self.check('''
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            local panel=NS.ScannerPanel
            combatLockdown=true; instanceKind="pvp"
            LFGWhoListFrame:Show()
            Emit("PLAYER_REGEN_DISABLED")
            Advance(0.2)
            assert(panel.scanStatus:GetText()=="Paused: Combat")
            combatLockdown=false; instanceKind="none"
            Emit("PLAYER_REGEN_ENABLED")
            Advance(0.2)
            assert(panel.scanStatus:GetText()=="Paused: Who")
            Click(function() WorldFrame:GetScript("OnMouseDown")(WorldFrame) end)
            assert(#whoCalls==0)
            LFGWhoListFrame:Hide()
            Advance(0.2)
            assert(panel.scanStatus:GetText()=="Scanning" and #whoCalls==0)
            Click(function() WorldFrame:GetScript("OnMouseDown")(WorldFrame) end)
            assert(#whoCalls==1 and #errors==0)
        ''')

    def test_unavailable_environment_keeps_play_disabled_after_stop(self):
        """Verifies that unavailable environment keeps play disabled after stop."""
        self.check('''
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            local panel=NS.ScannerPanel
            IsInInstance=nil
            Emit("ZONE_CHANGED_NEW_AREA")
            Advance(0.2)
            assert(panel.scanStatus:GetText()=="Paused: Unavailable")
            assert(panel.stopBtn:IsEnabled() and panel.scanButton:IsEnabled())
            ClickWidget(panel.stopBtn)
            NS.UI:Refresh()
            assert(panel.scanStatus:GetText()=="Stopped" and not panel.scanButton:IsEnabled())
            IsInInstance=function() return false,"none" end
            Emit("PLAYER_ENTERING_WORLD",false,false)
            Advance(0.2)
            assert(panel.scanStatus:GetText()=="Stopped" and panel.scanButton:IsEnabled())
            assert(#whoCalls==0 and #errors==0)
        ''')

    def test_native_who_hold_allows_manual_pause_but_not_play(self):
        """Verifies that native who hold allows manual pause but not play."""
        self.check(r'''
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            local panel=NS.ScannerPanel
            LFGWhoListFrame:Show()
            Advance(0.2)
            ClickWidget(panel.scanButton)
            assert(Batata_Scanner.GetScanStatus().paused and panel.scanStatus:GetText()=="Paused")
            assert(panel.scanButton.playIcon:IsShown() and not panel.scanButton:IsEnabled())
            LFGWhoListFrame:Hide()
            Advance(0.2)
            assert(panel.scanStatus:GetText()=="Paused" and panel.scanButton:IsEnabled())
            Click(function() WorldFrame:GetScript("OnMouseDown")(WorldFrame) end)
            assert(#whoCalls==0)
            ClickWidget(panel.scanButton)
            assert(#whoCalls==1 and Batata_Scanner.GetScanStatus().awaiting and #errors==0)
        ''')

    def test_external_who_hold_explains_both_holds_and_preserves_manual_pause(self):
        """Verifies that external who hold explains both holds and preserves manual pause."""
        self.check(r'''
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            local panel=NS.ScannerPanel
            LFGWhoListFrame:Show()
            Click(function() C_FriendList.SendWho("5-5") end)
            Advance(0.2)
            assert(panel.scanStatus:GetText()=="Waiting for Who")
            assert(panel.scanButton:IsEnabled() and panel.stopBtn:IsEnabled())
            GameTooltip:ClearLines()
            panel.scanStatusHint:GetScript("OnEnter")(panel.scanStatusHint)
            local tooltipText=table.concat(GameTooltip.lines," ")
            assert(tooltipText:find("Who list is open",1,true) and tooltipText:find("retry",1,true))
            assert(not tooltipText:lower():find("reload",1,true))
            ClickWidget(panel.scanButton)
            assert(Batata_Scanner.GetScanStatus().paused and not panel.scanButton:IsEnabled())
            Deliver({})
            LFGWhoListFrame:Hide()
            Advance(6)
            assert(panel.scanStatus:GetText()=="Paused" and panel.scanButton:IsEnabled())
            assert(#whoCalls==1 and Batata_Scanner.CountPlayers()==0)
            ClickWidget(panel.scanButton)
            assert(#whoCalls==2 and #errors==0)
        ''')

    def test_settings_restart_and_stop_cannot_bypass_native_who_hold(self):
        """Verifies that settings restart and stop cannot bypass native who hold."""
        self.check(r'''
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            local panel=NS.ScannerPanel
            LFGWhoListFrame:Show()
            ClickWidget(panel.scanSettingsButton)
            panel.behaviorDropdown:Select(1)
            ClickWidget(panel.scanSettings.doneButton)
            NS.UI:Refresh()
            assert(panel.scanStatus:GetText()=="Paused: Who" and #whoCalls==0)
            assert(Batata_Scanner.GetScanStatus().running and not Batata_Scanner.GetScanStatus().awaiting)
            ClickWidget(panel.stopBtn)
            Advance(0.2)
            assert(panel.scanStatus:GetText()=="Stopped" and not panel.scanButton:IsEnabled())
            LFGWhoListFrame:Hide()
            Advance(0.2)
            assert(panel.scanStatus:GetText()=="Stopped" and panel.scanButton:IsEnabled())
            Click(function() WorldFrame:GetScript("OnMouseDown")(WorldFrame) end)
            assert(#whoCalls==0 and #errors==0)
        ''')

    def test_unanswered_query_controls_show_bounded_cooldown_after_stop(self):
        """Verifies that unanswered query controls show bounded cooldown after stop."""
        self.check(r'''
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            local panel=NS.ScannerPanel
            ClickWidget(panel.stopBtn)
            ClickWidget(panel.scanButton)
            Advance(11)
            NS.UI:Refresh()
            assert(panel.scanStatus:GetText()=="Retry in 9s" and panel.scanButton:IsEnabled())
            ClickWidget(panel.stopBtn)
            NS.UI:Refresh()
            assert(panel.scanStatus:GetText()=="Cooldown: 9s")
            assert(not panel.scanButton:IsEnabled() and not panel.stopBtn:IsEnabled())
            GameTooltip:ClearLines()
            panel.scanStatusHint:GetScript("OnEnter")(panel.scanStatusHint)
            assert(not table.concat(GameTooltip.lines," "):lower():find("reload",1,true))
            Advance(9)
            NS.UI:Refresh()
            assert(panel.scanStatus:GetText()=="Stopped" and panel.scanButton:IsEnabled())
            Click(function() WorldFrame:GetScript("OnMouseDown")(WorldFrame) end)
            assert(#whoCalls==1 and #errors==0)
            ClickWidget(panel.scanButton)
            assert(#whoCalls==2)
        ''')

    def test_unanswered_query_countdown_returns_to_playing_without_sending(self):
        """Verifies that unanswered query countdown returns to playing without sending."""
        self.check(r'''
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            local panel=NS.ScannerPanel
            Click(function() WorldFrame:GetScript("OnMouseDown")(WorldFrame) end)
            Advance(11)
            NS.UI:Refresh()
            assert(panel.scanStatus:GetText()=="Retry in 9s" and panel.scanButton:IsEnabled())
            Advance(9)
            NS.UI:Refresh()
            assert(panel.scanStatus:GetText()=="Scanning" and #whoCalls==1)
            Click(function() WorldFrame:GetScript("OnMouseDown")(WorldFrame) end)
            assert(#whoCalls==2 and whoCalls[2]==whoCalls[1] and #errors==0)
        ''')

    def test_external_overlap_countdown_allows_manual_pause_without_reload(self):
        """Verifies that external overlap countdown allows manual pause without reload."""
        self.check(r'''
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            local panel=NS.ScannerPanel
            Click(function() WorldFrame:GetScript("OnMouseDown")(WorldFrame) end)
            Click(function() C_FriendList.SendWho("5-5") end)
            Advance(0.2)
            assert(panel.scanStatus:GetText()=="Retry in 10s" and not Batata_Scanner.GetScanStatus().blockedUntilReload)
            Deliver({{fullName="External",level=5}})
            ClickWidget(panel.scanButton)
            assert(panel.scanStatus:GetText()=="Cooldown: 10s" and Batata_Scanner.GetScanStatus().paused)
            assert(not panel.scanButton:IsEnabled())
            Advance(10)
            assert(panel.scanStatus:GetText()=="Paused" and panel.scanButton:IsEnabled())
            Click(function() WorldFrame:GetScript("OnMouseDown")(WorldFrame) end)
            assert(#whoCalls==2 and Batata_Scanner.CountPlayers()==0)
            ClickWidget(panel.scanButton)
            assert(#whoCalls==3 and whoCalls[3]==whoCalls[1] and #errors==0)
        ''')

    def test_settings_are_staged_until_save(self):
        """Verifies that settings are staged until save."""
        self.check(r'''
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            local panel=NS.ScannerPanel
            local planned=Batata_Scanner.GetScanStatus().plannedQueries
            ClickWidget(panel.scanSettingsButton)
            panel.overrideCheck:SetChecked(true)
            ClickWidget(panel.overrideCheck)
            panel.minLevel:SetText("30")
            panel.minLevel:SetFocus(); panel.minLevel:ClearFocus()
            panel.speedDropdown:Select(2)
            panel.classChecks[1]:SetChecked(false)
            panel.behaviorDropdown:Select(2)
            assert(not NS.db.settings.overrideDefaults and NS.db.settings.minLevel==1)
            assert(NS.db.settings.queryInterval==6 and NS.db.settings.scanClasses==nil)
            assert(NS.db.settings.scanBehavior=="random")
            Batata_Scanner_Dismiss:Hide()
            assert(not panel.scanSettings:IsShown() and not NS.db.settings.overrideDefaults)
            assert(NS.db.settings.minLevel==1 and NS.db.settings.queryInterval==6)
            ClickWidget(panel.scanSettingsButton)
            assert(not panel.overrideCheck:GetChecked() and panel.minLevel:GetText()=="1")
            assert(panel.speedDropdown:GetValue()==6 and panel.classChecks[1]:GetChecked())
            assert(panel.behaviorDropdown:GetValue()=="random")
            panel.overrideCheck:SetChecked(true)
            ClickWidget(panel.overrideCheck)
            for classIndex,classCheck in ipairs(panel.classChecks) do
                assert(classCheck:IsEnabled())
                classCheck:SetChecked(false)
            end
            ClickWidget(panel.scanSettings.doneButton)
            assert(panel.scanSettings:IsShown() and not NS.db.settings.overrideDefaults)
            assert(Batata_Scanner.GetScanStatus().plannedQueries==planned)
            assert(#whoCalls==0 and #errors==0)
        ''')

    def test_retention_is_opt_in_staged_and_refreshes_results_without_scanning(self):
        """Verifies that retention is opt in staged and refreshes results without scanning."""
        self.check('''
            NS.Store:Observe({name="Old",level=10})
            epoch=epoch+31*86400
            NS.Store:Observe({name="Current",level=20})
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            Advance(0)
            local panel=NS.ScannerPanel
            ClickWidget(panel.scanSettingsButton)
            assert(panel.retentionDropdown:GetValue()==0 and NS.db.settings.retentionDays==0)
            local options=panel.retentionDropdown.options
            assert(#options==5 and options[1].label=="Never")
            assert(options[2].value==30 and options[3].value==90 and options[4].value==180 and options[5].value==365)
            panel.retentionDropdown:Select(2)
            assert(NS.db.settings.retentionDays==0 and Batata_Scanner.CountPlayers()==2)
            Batata_Scanner_Dismiss:Hide()
            assert(NS.db.settings.retentionDays==0 and panel.list:ItemCount()==2)
            ClickWidget(panel.scanSettingsButton)
            assert(panel.retentionDropdown:GetValue()==0)
            panel.retentionDropdown:Select(2)
            ClickWidget(panel.scanSettings.doneButton)
            Advance(0)
            assert(NS.db.settings.retentionDays==30 and Batata_Scanner.GetPlayer("Old")==nil)
            assert(panel.list:ItemCount()==1 and panel.list.rows[1].item.name=="Current")
            assert(#whoCalls==0)
            ClickWidget(panel.scanSettingsButton)
            assert(panel.retentionDropdown:GetValue()==30)
            panel.retentionDropdown:Select(1)
            ClickWidget(panel.scanSettings.doneButton)
            assert(NS.db.settings.retentionDays==0 and Batata_Scanner.CountPlayers()==1)
            Emit("PLAYER_LOGOUT")
            assert(Batata_Scanner_DB.settings.retentionDays==0 and #Batata_Scanner_DB.players==1)
            assert(#errors==0)
        ''')

    def test_search_filters_narrow_results_and_persist_without_affecting_scans(self):
        """Verifies that search filters narrow results and persist without affecting scans."""
        self.check(r'''
            local function Choose(dropdown,value)
                for index,option in ipairs(dropdown.options) do
                    if option.value==value then dropdown:Select(index) return end
                end
                error("missing option "..tostring(value))
            end
            NS.Store:Observe({name="Alpha",level=60,class="MAGE",guild="Guild"},"who")
            NS.Store:Observe({name="Delta",level=12,class="WARRIOR",guild=""},"who")
            local original=NS.context
            NS.context={faction="Horde",key="Horde"}
            NS.Store:Observe({name="Beta",level=30,class="WARRIOR"},"who")
            NS.context=original
            epoch=epoch+7200
            NS.Store:Observe({name="Echo",level=40,class="MAGE",guild=""},"who")
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            Advance(1)
            local panel=NS.ScannerPanel
            local planned=Batata_Scanner.GetScanStatus().plannedQueries
            assert(panel.list:ItemCount()==3 and panel.factionCheck==nil)
            assert(NS.db.settings.myFactionOnly==false)
            panel.searchMinLevel:SetText("50")
            panel.searchMaxLevel:SetText("10")
            panel.searchMaxLevel:SetFocus(); panel.searchMaxLevel:ClearFocus()
            Advance(1)
            assert(NS.db.settings.searchMinLevel==10 and NS.db.settings.searchMaxLevel==50)
            assert(panel.searchMinLevel:GetText()=="10" and panel.list:ItemCount()==2)
            assert(#panel.classFilter.options==3 and panel.classFilter.options[2].value=="Mage")
            Choose(panel.classFilter,"Mage")
            Advance(1)
            assert(NS.db.settings.searchClass=="Mage" and panel.list:ItemCount()==1)
            assert(panel.list.rows[1].item.name=="Echo")
            Choose(panel.classFilter,"")
            Choose(panel.guildFilter,"unguilded")
            Advance(1)
            assert(NS.db.settings.searchClass==nil and NS.db.settings.searchGuildStatus=="unguilded")
            assert(#panel.guildFilter.options==3)
            assert(panel.list:ItemCount()==2)
            Choose(panel.seenFilter,3600)
            Advance(1)
            assert(NS.db.settings.searchSeenWithin==3600 and panel.list:ItemCount()==1)
            Choose(panel.seenFilter,0)
            Advance(1)
            assert(NS.db.settings.searchSeenWithin==nil and panel.list:ItemCount()==2)
            assert(#whoCalls==0 and Batata_Scanner.GetScanStatus().plannedQueries==planned)
            Tab("Census")
            assert(NS.CensusPanel.snapshot.total==3)
            assert(Batata_Scanner.GetCensus().total==4)
            assert(#errors==0)
        ''')

    def test_scanner_automatically_filters_by_detected_character_faction(self):
        """Verifies that scanner automatically filters by detected character faction."""
        for faction in ("Alliance", "Horde"):
            with self.subTest(faction=faction):
                client = Harness(setup=UI_SUPPORT + f'''
                    function UnitFactionGroup() return "{faction}" end
                ''', modules=MODULES)
                client.execute(r'''
                    local original=NS.context
                    assert(original.faction==UnitFactionGroup("player"))
                    NS.Store:Observe({name="Friendly",level=30,class="MAGE"},"who")
                    NS.context={faction=original.faction=="Alliance" and "Horde" or "Alliance"}
                    NS.Store:Observe({name="Opponent",level=30,class="MAGE"},"who")
                    NS.context=original
                    NS.UI:Show()
                    NS.UI:SelectPage("Scanner")
                    local panel=NS.ScannerPanel
                    for preferenceIndex,preference in ipairs({false,true}) do
                        NS.db.settings.myFactionOnly=preference
                        panel:Submit()
                        Advance(1)
                        assert(panel.list:ItemCount()==1 and panel.list.rows[1].item.name=="Friendly")
                        assert(panel.list.rows[1].item.faction==original.faction)
                    end
                    panel.input:SetText("Opponent")
                    panel.input.scripts.OnEnterPressed(panel.input)
                    Advance(1)
                    assert(panel.list:ItemCount()==0 and panel.factionCheck==nil)
                    assert(Batata_Scanner.CountPlayers()==2 and #whoCalls==0 and #errors==0)
                ''')

    def test_scanner_search_lists_first_seen_in_a_full_width_table_without_faction(self):
        """Verifies that scanner search lists first seen in a full width table without faction."""
        self.check(r'''
            local original=NS.context
            NS.context={faction="Horde",key="Horde"}
            NS.Store:Observe({name="Gamma",level=10,class="MAGE",race="Human",guild="Second Guild",zone="Stormwind"},"passive")
            NS.context=original
            NS.Store:Observe({name="Delta",level=10,class="MAGE",race="Human",guild="Second Guild",zone="Stormwind"},"who")
            epoch=epoch+60
            NS.Store:Observe({name="Alpha",level=60,class="MAGE",race="Human",guild="First Guild",zone="Stormwind"},"who")
            NS.Store:Observe({name="Beta",level=20,class="WARRIOR",race="Dwarf",guild="",zone="Ironforge"},"passive")
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            local panel=NS.ScannerPanel
            assert(panel.input.template=="SearchBoxTemplate")
            assert(panel.input:GetWidth()==180 and panel.input:GetHeight()==20)
            assert(panel.details==nil and panel.resultsGroup:GetWidth()==panel.root:GetWidth())
            local labels={"Lvl","Class","Name","Guild","First seen","Last seen"}
            assert(#panel.list.headers==#labels)
            for index,label in ipairs(labels) do
                assert(panel.list.headers[index]:GetText()==label)
            end
            panel.input:SetText("mage stormwind")
            panel.input.scripts.OnEnterPressed(panel.input)
            Advance(0)
            assert(panel.list:ItemCount()==2)
            assert(panel.scanSummary:GetText()=="Showing 2 players")
            assert(panel.scanSummary.properties.SetJustifyH[1]=="LEFT")
            local row=panel.list.rows[1]
            assert(row.item.name=="Alpha" and panel.list.rows[2].item.name=="Delta", "newest observations come first")
            assert(row.cells[3]:GetText()=="Alpha" and row.cells[5]:GetText()=="Now")
            local classIcon=row.cells[2].icon
            assert(classIcon:IsShown() and classIcon.texture:find("UI-CharacterCreate-Classes",1,true))
            assert(classIcon.texCoords[1]==0.25 and classIcon.texCoords[2]==0.5)
            ClickWidget(row)
            assert(not row.sel:IsShown() and not Batata_Scanner_Dismiss:IsShown())
            ClickWidget(panel.list.headers[1])
            Advance(0)
            assert(panel.list.rows[1].item.name=="Delta" and panel.list.rows[2].item.name=="Alpha")
            ClickWidget(panel.list.headers[1])
            Advance(0)
            assert(panel.list.rows[1].item.name=="Alpha")
            row.item.zone="Changed only in a result copy"
            assert(Batata_Scanner.GetPlayer(row.item.name).zone=="Stormwind")
            panel.input:SetText("absent-player")
            panel.input.scripts.OnEnterPressed(panel.input)
            Advance(0)
            assert(panel.list:ItemCount()==0)
            assert(row.item==nil and not row:IsShown())
            assert(#errors==0)
        ''')

    def test_census_ignores_legacy_scope_preferences_and_uses_current_faction(self):
        """Verifies that census ignores legacy scope preferences and uses current faction."""
        for saved_preference in (False, True):
            with self.subTest(saved_preference=saved_preference):
                self.client = Harness(setup=UI_SUPPORT +
                    'Batata_Scanner_DB={schemaVersion=1,settings={myFactionOnly=' +
                    str(saved_preference).lower() + '}}', modules=MODULES)
                self.check('''
                    NS.Store:Observe({name="Alliance Player",race="Human"},"who")
                    NS.context.faction="Horde"
                    NS.Store:Observe({name="Horde Player",race="Orc"},"who")
                    NS.context.faction="Alliance"
                    NS.UI:Show()
                    NS.UI:SelectPage("Census")
                    local panel=NS.CensusPanel
                    assert(panel.scopeFilter==nil and panel.snapshot.total==1)
                    assert(panel.snapshot.byRace.Human==1 and panel.snapshot.byRace.Orc==nil)
                    NS.context.faction="Horde"
                    NS.UI:Refresh()
                    assert(panel.snapshot.total==1 and panel.snapshot.byRace.Orc==1)
                    assert(panel.snapshot.byRace.Human==nil)
                    assert(Batata_Scanner.GetCensus().total==2)
                    assert(#whoCalls==0 and #errors==0)
                ''')

    def test_invalid_search_submission_cancels_inflight_work_and_preserves_completed_results(self):
        """Verifies that invalid search submission cancels inflight work and preserves completed results."""
        self.check('''
            NS.Store:Observe({name="Alpha",level=30})
            NS.Store:Observe({name="Beta",level=30})
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            Advance(0)
            local panel=NS.ScannerPanel
            assert(panel.list:ItemCount()==2)
            panel.input:SetText("Alpha")
            panel:Submit()
            assert(panel.searching)
            panel.input:SetText("one two three four five six seven eight nine")
            panel:Submit()
            assert(not panel.searching and panel.refreshPaused and panel.inputError)
            Advance(31)
            assert(panel.list:ItemCount()==2 and not panel.searching)
            assert(not Batata_Scanner_Dismiss:IsShown())
            panel.input:SetText("Beta")
            panel:Submit()
            Advance(0)
            assert(panel.list:ItemCount()==1 and panel.list.rows[1].item.name=="Beta")
            assert(not panel.inputError and not panel.refreshPaused and #errors==0)
        ''')

    def test_who_updates_queue_a_refresh_without_cancelling_an_inflight_snapshot(self):
        """Verifies that who updates queue a refresh without cancelling an inflight snapshot."""
        self.check('''
            NS.Store:Observe({name="Snapshot Player",level=30})
            local originalSearch=NS.Store.CreateSearch
            local firstRequest
            local searchCount=0
            NS.Store.CreateSearch=function(...)
                local request=originalSearch(...)
                searchCount=searchCount+1
                if not firstRequest then
                    firstRequest=request
                    local originalStep=request.Step
                    local steps=0
                    request.Step=function(self)
                        steps=steps+1
                        if steps<=3 then
                            NS:Notify("WHO_RESULTS_RECEIVED")
                            return false
                        end
                        return originalStep(self)
                    end
                end
                return request
            end
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            Advance(0)
            assert(firstRequest.complete and searchCount==1)
            assert(NS.ScannerPanel.list:ItemCount()==1 and not NS.ScannerPanel.searching)
            Advance(30)
            assert(searchCount==2 and not NS.ScannerPanel.searching)
            assert(#errors==0)
        ''')

    def test_accepted_who_reply_waits_for_the_thirty_second_scanner_refresh(self):
        """Stores accepted Who rows immediately but defers their browser refresh."""
        self.check(r'''
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            Advance(0)
            local panel=NS.ScannerPanel
            assert(panel.list:ItemCount()==0)
            Click(function() assert(NS.Scanner:Continue()) end)
            local query=NS.Scanner:GetStatus().currentQuery
            local level=tonumber(query:match("(%d+)%-%d+$"))
            Deliver({{fullName="Fresh Who Result",level=level,filename="MAGE",classStr="Mage"}})
            Advance(1)
            assert(panel.list:ItemCount()==0 and Batata_Scanner.CountPlayers()==1)
            Advance(28.9)
            assert(panel.list:ItemCount()==0, "Who replies must respect the browser refresh interval")
            Advance(.1)
            assert(panel.list:ItemCount()==1)
            assert(panel.list.rows[1].item.name=="Fresh Who Result")
            assert(not panel.searching and #errors==0)
        ''')

    def test_who_refresh_keeps_filters_and_defers_hidden_searches(self):
        """Verifies that who refresh keeps filters and defers hidden searches."""
        self.check(r'''
            local original=NS.Store.CreateSearch
            local searchCount=0
            NS.Store.CreateSearch=function(...)
                searchCount=searchCount+1
                return original(...)
            end
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            Advance(0)
            local panel=NS.ScannerPanel
            panel.input:SetText("Match")
            panel:Submit()
            Click(function() assert(NS.Scanner:Continue()) end)
            local level=tonumber(NS.Scanner:GetStatus().currentQuery:match("(%d+)%-%d+$"))
            Deliver({{fullName="Match One",level=level},{fullName="Excluded",level=level}})
            Advance(1)
            assert(panel.list:ItemCount()==0)
            Advance(29)
            assert(panel.list:ItemCount()==1 and panel.list.rows[1].item.name=="Match One")
            assert(panel.input:GetText()=="Match" and not panel.searching)
            NS.UI:Toggle()
            Advance(5)
            local previousSearches=searchCount
            Click(function() assert(NS.Scanner:Continue()) end)
            level=tonumber(NS.Scanner:GetStatus().currentQuery:match("(%d+)%-%d+$"))
            Deliver({{fullName="Match Two",level=level}})
            Advance(1)
            assert(searchCount==previousSearches, "hidden Who updates must not start searches")
            NS.UI:Show()
            Advance(0)
            assert(panel.list:ItemCount()==1 and searchCount==previousSearches)
            Advance(24)
            assert(panel.list:ItemCount()==2 and #errors==0)
        ''')

    def test_scanner_periodic_tick_respects_a_recent_manual_search(self):
        """Keeps filters responsive without letting the periodic ticker bypass the interval."""
        self.check('''
            local originalSearch=NS.Store.CreateSearch
            local searches=0
            NS.Store.CreateSearch=function(...)
                searches=searches+1
                return originalSearch(...)
            end
            NS.Store:Observe({name="Manual Match",level=30,class="MAGE"})
            NS.UI:Show()
            Tab("Scanner")
            Advance(20)
            local panel=NS.ScannerPanel
            panel.input:SetText("Manual")
            panel:Submit()
            Advance(0)
            assert(searches==2 and panel.list:ItemCount()==1)
            Advance(10)
            assert(searches==2, "the periodic tick must not restart a recent search")
            NS.Store:Observe({name="Manual New Match",level=40,class="WARRIOR"})
            NS:Notify("WHO_RESULTS_RECEIVED")
            Advance(19.9)
            assert(searches==2 and panel.list:ItemCount()==1)
            Advance(.1)
            assert(searches==3 and panel.list:ItemCount()==2)
            assert(panel.input:GetText()=="Manual" and #whoCalls==0 and #errors==0)
        ''')

    def test_relative_ages_refresh_and_warm_results_survive_a_short_window_close(self):
        """Verifies periodic searches while open and cached ages after a short reopen."""
        self.check('''
            NS.Store:Observe({name="Age Probe",level=30,class="MAGE"})
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            Advance(31)
            local panel=NS.ScannerPanel
            local row=panel.list.rows[1]
            local originalSearch=NS.Store.CreateSearch
            local searches=0
            NS.Store.CreateSearch=function(...)
                searches=searches+1
                return originalSearch(...)
            end
            epoch=epoch+3600
            Advance(30)
            assert(row.cells[5]:GetText()=="1h ago" and row.cells[6]:GetText()=="1h ago")
            assert(searches==1, "the open window refreshes its search every thirty seconds")
            NS.UI:Toggle()
            epoch=epoch+3600
            Advance(30)
            assert(row.cells[6]:GetText()=="1h ago" and searches==1)
            NS.UI:Show()
            Advance(0)
            assert(row.cells[6]:GetText()=="2h ago" and searches==1)
            assert(#whoCalls==0 and #errors==0)
        ''')

    def test_scanner_results_warm_while_another_tab_is_open_and_release_on_window_hide(self):
        """Verifies background search, immediate tab readiness, and hidden-window result release."""
        self.check('''
            NS.Store:Observe({name="Background Alpha",level=30,class="MAGE"})
            NS.Store:Observe({name="Background Beta",level=40,class="WARRIOR"})
            local original=NS.Store.CreateSearch
            local searches=0
            NS.Store.CreateSearch=function(...)
                searches=searches+1
                return original(...)
            end
            NS.UI:Show()
            assert(NS.UI.pageTitle:GetText()=="Welcome")
            Advance(0)
            local panel=NS.ScannerPanel
            assert(searches==1 and not panel.searching)
            assert(panel.list.providerGet==nil and panel.list:ItemCount()==0)
            NS.Store:Observe({name="Background Gamma",level=50,class="PRIEST"})
            Advance(30)
            assert(searches==2 and not panel.searching)
            assert(panel.list.providerGet==nil and panel.list:ItemCount()==0)
            Tab("Scanner")
            assert(panel.list:ItemCount()==3 and searches==2)
            assert(panel.list.rows[1].item.name=="Background Gamma")
            NS.UI:Toggle()
            assert(panel.list.providerGet~=nil and panel.list:ItemCount()==3)
            assert(panel.list.rows[1].item.name=="Background Gamma")
            local searchesAtHide=searches
            Advance(31)
            assert(searches==searchesAtHide and panel.list:ItemCount()==3 and not panel.searching)
            NS.UI:Show()
            Advance(0)
            assert(searches==searchesAtHide and not panel.searching)
            Tab("Scanner")
            assert(panel.list:ItemCount()==3 and panel.list.rows[1].item.name=="Background Gamma")
            NS.UI:Toggle()
            Advance(300)
            assert(panel.list.providerGet==nil and panel.list:ItemCount()==0)
            for rowIndex,row in ipairs(panel.list.rows) do
                assert(row.item==nil and not row:IsShown())
            end
            NS.UI:Show()
            Advance(0)
            assert(searches==searchesAtHide+1 and not panel.searching)
            Tab("Scanner")
            assert(panel.list:ItemCount()==3 and #errors==0)
        ''')

    def test_census_reuses_aggregates_and_refreshes_changed_data_every_thirty_seconds(self):
        """Keeps Census data and hover stable between periodic snapshot refreshes."""
        self.check('''
            NS.Store:Observe({name="Census Probe",level=30,class="MAGE",race="Human"})
            NS.Store.GetCensus=function() error("UI must not rescan the player collection") end
            NS.UI:Show()
            NS.UI:SelectPage("Census")
            Advance(1)
            local panel=NS.CensusPanel
            local chart=panel.classChart
            local centerX,centerY=chart.ring:GetCenter()
            cursorX=(centerX+chart.radius*0.8)*chart.ring:GetEffectiveScale()
            cursorY=centerY*chart.ring:GetEffectiveScale()
            chart.ring.scripts.OnEnter(chart.ring)
            local hovered=chart.hoveredEntry
            local originalOverview=NS.Store.GetCensusOverview
            local reads=0
            NS.Store.GetCensusOverview=function(...)
                reads=reads+1
                return originalOverview(...)
            end
            for tickIndex=1,5 do
                NS:Notify("SCAN_STATUS_CHANGED")
                Advance(1)
            end
            assert(hovered and chart.hoveredEntry==hovered and GameTooltip:IsShown())
            assert(reads==0)
            NS.Store:Observe({name="New Class",level=40,class="WARRIOR",race="Dwarf"})
            Advance(1)
            assert(reads==0 and panel.snapshot.total==1 and chart.hoveredEntry==hovered)
            assert(Batata_Scanner.CountPlayers()==2, "collection and API must remain current")
            Advance(22.9)
            assert(reads==0 and panel.snapshot.total==1)
            Advance(.1)
            assert(reads==1 and panel.snapshot.total==2 and chart.hoveredEntry==nil)
            NS.UI:SelectPage("Scanner")
            Advance(1)
            assert(#NS.ScannerPanel.classFilter.options==3 and #errors==0)
        ''')

    def test_census_snapshot_warms_and_refreshes_only_while_window_is_open(self):
        """Warms Census on Welcome, skips unchanged data, and stops timers on close."""
        self.check('''
            local originalOverview=NS.Store.GetCensusOverview
            local originalRefresh=NS.CensusPanel.Refresh
            local reads=0
            local periodicRefreshes=0
            NS.Store.GetCensusOverview=function(...)
                reads=reads+1
                return originalOverview(...)
            end
            function NS.CensusPanel:Refresh(deferDataChanges)
                if not deferDataChanges then periodicRefreshes=periodicRefreshes+1 end
                return originalRefresh(self,deferDataChanges)
            end
            NS.Store:Observe({name="Initial Census",level=20,class="MAGE",race="Human"})
            NS.UI:Show()
            Advance(0)
            local panel=NS.CensusPanel
            assert(not panel.root:IsVisible() and panel.snapshot.total==1 and reads==1)
            NS.Store:Observe({name="Background Census",level=40,class="WARRIOR",race="Dwarf"})
            Advance(29.9)
            assert(reads==1 and panel.snapshot.total==1)
            Advance(.1)
            assert(reads==2 and panel.snapshot.total==2 and periodicRefreshes==2)
            Advance(30)
            assert(reads==2 and periodicRefreshes==3, "unchanged revisions must not copy aggregates")
            Tab("Census")
            assert(reads==2 and panel.classChart.total==2)
            NS.UI:Toggle()
            NS.Store:Observe({name="Hidden Census",level=60,class="PRIEST",race="Human"})
            Advance(90)
            assert(reads==2 and periodicRefreshes==3 and panel.snapshot.total==2)
            NS.UI:Show()
            NS.UI:Show()
            Advance(0)
            assert(reads==3 and periodicRefreshes==4 and panel.snapshot.total==3)
            NS.Store:Observe({name="Reopened Census",level=50,class="ROGUE",race="Dwarf"})
            Advance(29.9)
            assert(reads==3 and panel.snapshot.total==3)
            Advance(.1)
            assert(reads==4 and periodicRefreshes==5 and panel.snapshot.total==4)
            assert(#whoCalls==0 and #errors==0)
        ''')

    def test_census_sections_share_periodic_data_without_delaying_guild_search(self):
        """Keeps all sections consistent while navigation and guild filtering remain immediate."""
        self.check('''
            NS.Store:Observe({name="First Census",level=20,class="MAGE",race="Human",guild="Alpha"},"who")
            NS.UI:Show()
            Tab("Census")
            Advance(0)
            local panel=NS.CensusPanel
            local snapshot=panel.snapshot
            NS.Store:Observe({name="Second Census",level=40,class="WARRIOR",race="Dwarf",guild="Beta"},"who")
            NS:Notify("WHO_RESULTS_RECEIVED")
            Advance(1)
            assert(panel.snapshot==snapshot and panel.classChart.total==1)
            ClickWidget(panel.navigation.links[2])
            assert(panel.levelBars[20].count==1 and panel.levelBars[40].count==0)
            ClickWidget(panel.navigation.links[3])
            assert(panel.guildBox.rows[1].label:GetText()=="Alpha")
            panel.guildSearch:SetText("Beta")
            assert(panel.noGuilds:IsShown() and panel.snapshot==snapshot)
            Advance(29)
            snapshot=panel.snapshot
            assert(snapshot.total==2 and not panel.noGuilds:IsShown())
            assert(panel.guildBox.rows[1].label:GetText()=="Beta")
            panel.guildSearch:SetText("Alpha")
            assert(panel.guildBox.rows[1].label:GetText()=="Alpha" and panel.snapshot==snapshot)
            ClickWidget(panel.navigation.links[1])
            assert(panel.classChart.total==2 and panel.snapshot==snapshot)
            ClickWidget(panel.navigation.links[2])
            assert(panel.levelBars[20].count==1 and panel.levelBars[40].count==1)
            assert(panel.levelBars[40].total==2 and panel.snapshot==snapshot)
            assert(#whoCalls==0 and #errors==0)
        ''')

    def test_census_faction_changes_refresh_before_the_next_periodic_tick(self):
        """Never reuses another faction's cached statistics through the UI refresh path."""
        self.check('''
            NS.Store:Observe({name="Alliance Census",level=20,class="MAGE",race="Human"})
            NS.context.faction="Horde"
            NS.Store:Observe({name="Horde Census One",level=40,class="WARRIOR",race="Orc"})
            NS.Store:Observe({name="Horde Census Two",level=60,class="SHAMAN",race="Troll"})
            NS.context.faction="Alliance"
            NS.UI:Show()
            Tab("Census")
            local panel=NS.CensusPanel
            assert(panel.snapshot.total==1)
            NS.context.faction="Horde"
            NS.UI:Refresh()
            assert(panel.snapshotFaction=="Horde" and panel.snapshot.total==2 and panel.classChart.total==2)
            NS.context.faction=nil
            NS.UI:Refresh()
            assert(panel.snapshot.total==0 and panel.classChart.total==0)
            NS.context.faction="Alliance"
            NS.UI:Refresh()
            assert(panel.snapshot.total==1 and panel.classChart.total==1)
            assert(Batata_Scanner.CountPlayers()==3 and #whoCalls==0 and #errors==0)
        ''')

    def test_recency_filters_expire_without_new_observations(self):
        """Verifies that recency filters expire without new observations."""
        self.check(r'''
            NS.Store:Observe({name="Recent",level=60,class="MAGE"})
            NS.db.settings.searchSeenWithin=3600
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            Advance(1)
            local panel=NS.ScannerPanel
            local revision=NS.db.revision
            assert(panel.list:ItemCount()==1)
            epoch=epoch+3601
            Advance(31)
            assert(panel.list:ItemCount()==0, "recency must expire without DATA_UPDATED")
            assert(NS.db.revision==revision and Batata_Scanner.CountPlayers()==1)
            assert(#errors==0)
        ''')

    def test_updates_coalesce_and_search_refresh_pauses_while_hidden(self):
        """Verifies that updates coalesce and search refresh pauses while hidden."""
        self.check(r'''
            local original=NS.Store.CreateSearch
            searchCount=0
            NS.Store.CreateSearch=function(...)
                searchCount=searchCount+1
                return original(...)
            end
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
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
        """Verifies that search sorting reverses and scroll fetches only visible records."""
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
            NS.UI:SelectPage("Scanner")
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
            local lastName=list:GetItem(list:ItemCount()).name
            list.scroll.scripts.OnVerticalScroll(list.scroll,1000*NS.Widgets.ROW_H)
            local foundLast=false
            for _,row in ipairs(list.rows) do
                if row.item and row.item.name==lastName then foundLast=true end
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

    def test_scanner_browser_displays_no_more_than_one_thousand_players(self):
        """Verifies that Scanner limits displayed matches without limiting stored observations."""
        self.check('''
            NS.Store:BeginBatch()
            for playerIndex=1,1200 do
                NS.Store:Observe({name=string.format("Player%04d",playerIndex),level=30})
            end
            NS.Store:EndBatch()
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            Advance(0)
            local panel=NS.ScannerPanel
            assert(panel.list:ItemCount()==1000)
            assert(panel.list:GetItem(1000)~=nil)
            assert(panel.list:GetItem(1001)==nil)
            assert(panel.scanSummary:GetText()=="Showing first 1000 matches; narrow your search for more.")
            assert(Batata_Scanner.CountPlayers()==1200)
            assert(#whoCalls==0 and #errors==0)
        ''')

    def test_hidden_interrupted_refresh_retries_when_reopened_with_existing_results(self):
        """Verifies that hidden interrupted refresh retries when reopened with existing results."""
        self.check(r'''
            NS.Store:Observe({name="Alpha",class="MAGE"},"who")
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
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
            assert(panel.list:ItemCount()==1, "completed results stay cached during the close grace period")
            NS.UI:Show()
            Advance(0)
            assert(panel.list:ItemCount()==2 and not panel.searching)
            assert(panel.list.rows[1].item.name=="Beta")
            assert(#errors==0)
        ''')

    def test_search_ownership_releases_on_replacement_escape_and_hide(self):
        """Verifies that search ownership releases on replacement escape and hide."""
        self.check('''
            for playerIndex=1,100 do
                NS.Store:Observe({name=string.format("Player%04d",playerIndex),level=30})
            end
            local requests={}
            local originalSearch=NS.Store.CreateSearch
            NS.Store.CreateSearch=function(...)
                local request=originalSearch(...)
                if request then requests[#requests+1]=request end
                return request
            end
            NS.UI:Show()
            NS.UI:SelectPage("Scanner")
            Advance(0)
            local panel=NS.ScannerPanel
            local completed=requests[#requests]
            panel:Submit(true)
            local abandoned=requests[#requests]
            panel:Submit(true)
            assert(abandoned.cancelled and not completed.cancelled)
            Advance(0)
            assert(completed.cancelled)
            completed=requests[#requests]
            panel:Submit(true)
            local cancelled=requests[#requests]
            assert(panel:Escape())
            assert(cancelled.cancelled and not completed.cancelled and panel.list:ItemCount()==100)
            panel:Submit(true)
            Advance(0)
            completed=requests[#requests]
            panel.list.scroll.scripts.OnVerticalScroll(panel.list.scroll,20*NS.Widgets.ROW_H)
            local previousOffset=FauxScrollFrame_GetOffset(panel.list.scroll)
            assert(previousOffset>0)
            NS.UI:Toggle()
            assert(not completed.cancelled and panel.list.providerGet~=nil and panel.list:ItemCount()==100)
            for rowIndex,row in ipairs(panel.list.rows) do
                assert(row.item~=nil)
            end
            Advance(300)
            assert(completed.cancelled and panel.list.providerGet==nil and panel.list:ItemCount()==0)
            for rowIndex,row in ipairs(panel.list.rows) do
                assert(row.item==nil)
            end
            NS.UI:Show()
            Advance(0)
            assert(panel.list:ItemCount()==100)
            assert(FauxScrollFrame_GetOffset(panel.list.scroll)==previousOffset)
            assert(#errors==0)
        ''')

if __name__ == "__main__":
    unittest.main()
