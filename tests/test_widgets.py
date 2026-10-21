"""Standalone shared table behavior with native-template mocks, never WoW rendering."""

from pathlib import Path
import unittest

from harness import Harness


UI_SUPPORT = Path(__file__).with_name("ui_support.lua").read_text(encoding="utf-8")  # Shared native widget mocks.


class WidgetContracts(unittest.TestCase):
    """Checks shared table and widget behavior."""
    def setUp(self):
        """Creates a fresh test fixture before each test."""
        self.client = Harness(initialize=False, setup=UI_SUPPORT, modules=("Widgets.lua",))

    def test_provider_reaches_last_record_without_building_all_rows(self):
        """Verifies that provider reaches last record without building all rows."""
        self.client.execute(r'''
            local widgets=NS.Widgets
            local fetched={}
            local list=widgets.CreateTable(UIParent, {
                {key="name", label="Name", text=function(item) return item.name end},
            })
            list.frame:SetSize(400,widgets.HEADER_H+45+2)
            list:Layout()
            list:SetProvider(1000,function(index)
                fetched[index]=true
                return {id=tostring(index), name="Player "..index}
            end)
            assert(list:ItemCount()==1000 and #list.items==0)
            assert(list.numRows==2 and list.renderRows==3 and #list.rows==3)
            assert(list.rows[1].item.name=="Player 1" and list.rows[3].item.name=="Player 3")
            local firstRow=list.rows[1]
            local frameCount=#frames
            list.scroll.scripts.OnVerticalScroll(list.scroll,998*widgets.ROW_H)
            assert(list.rows[1]==firstRow and firstRow.item.name=="Player 999")
            assert(list.rows[2].item.name=="Player 1000")
            assert(list.rows[3].item==nil and not list.rows[3]:IsShown())
            assert(#frames==frameCount, "scrolling must reuse bounded rows")
            local count=0
            for index in pairs(fetched) do count=count+1 end
            assert(count<=5, "providers must fetch only visible windows")
            assert(list:GetItem(0)==nil and list:GetItem(1001)==nil)
            list:SetProvider(2,function(index) return {name="Reduced "..index} end,true)
            assert(FauxScrollFrame_GetOffset(list.scroll)==0)
            assert(firstRow.item.name=="Reduced 1" and list.rows[2].item.name=="Reduced 2")
            list:SetItems({{name="Ordinary"}})
            assert(list.providerGet==nil and list:ItemCount()==1 and firstRow.item.name=="Ordinary")
        ''')

    def test_rebound_rows_clear_tooltips_and_selection_and_sort_by_current_column(self):
        """Verifies that rebound rows clear tooltips and selection and sort by current column."""
        self.client.execute(r'''
            local sorted
            local selected="one"
            local list=NS.Widgets.CreateTable(UIParent, {
                {key="name", label="Name", sort=true, text=function(item) return item.id end},
                {key="level", label="Level", sort=true, width=45, text=function(item) return item.level end},
            }, {
                onSort=function(key) sorted=key end,
                onClick=function(item) selected=item.id end,
                isSelected=function(item) return item.id==selected end,
                tooltip=function(item) return item.id, "A player" end,
                emptyText=function() return "No players" end,
            })
            list.frame:SetSize(400,list:HeightForRows(2))
            list:Layout()
            list:SetItems({{id="one",level=1},{id="two",level=2},{id="three",level=3}})
            local firstRow=list.rows[1]
            assert(firstRow.sel:IsShown())
            list.headers[1].scripts.OnClick()
            assert(sorted=="name")
            list.headers[2].scripts.OnClick()
            assert(sorted=="level")
            firstRow.scripts.OnEnter(firstRow)
            assert(GameTooltip:IsOwned(firstRow) and GameTooltip:IsShown())
            list.scroll.scripts.OnVerticalScroll(list.scroll,NS.Widgets.ROW_H)
            assert(firstRow.item.id=="two" and not firstRow.sel:IsShown())
            assert(not GameTooltip:IsShown(), "reused rows must release old tooltips")
            firstRow.scripts.OnClick(firstRow,"LeftButton")
            list:Bind()
            assert(selected=="two" and firstRow.sel:IsShown())
            list:SetItems({})
            assert(firstRow.item==nil and not firstRow:IsShown())
            assert(list.empty:GetText()=="No players")
        ''')

    def test_rows_keep_hover_and_selection_without_unused_stripe_textures(self):
        """Verifies that rows keep hover and selection without unused stripe textures."""
        self.client.execute('''
            local list=NS.Widgets.CreateTable(UIParent, {
                {key="name", label="Name", text=function(item) return item.name end},
            })
            list.frame:SetSize(400,list:HeightForRows(2))
            list:Layout()
            list:SetItems({{name="Visible"}})
            for rowIndex,row in ipairs(list.rows) do
                assert(row.stripe==nil)
                assert(row:GetHighlightTexture()~=nil and row.sel~=nil)
            end
        ''')

    def test_class_colors_and_surface_properties(self):
        """Verifies class colors and the addon surface profile."""
        self.client.execute(r'''
            local red,green,blue=NS.Widgets.ClassColor("MAGE")
            assert(red==RAID_CLASS_COLORS.MAGE.r and green==RAID_CLASS_COLORS.MAGE.g)
            assert(blue==RAID_CLASS_COLORS.MAGE.b)
            red=NS.Widgets.ClassColor("Warrior")
            assert(red==RAID_CLASS_COLORS.WARRIOR.r and NS.Widgets.ClassToken("Druid")=="DRUID")
            red,green,blue=NS.Widgets.ClassColor(nil)
            assert(red==1 and green==1 and blue==1)
            local panel=CreateFrame("Frame",nil,UIParent,"BackdropTemplate")
            NS.Widgets.ProfileSurface(panel)
            assert(panel.batataInset)
        ''')


if __name__ == "__main__":
    unittest.main()
