"""Proximity collection stays bounded and preserves unreadable/unknown identity."""

import unittest

from harness import Harness


# Lua unit API overrides for passive-observation tests.
UNIT_SETUP = '''
units={}
unitReads=0
-- Implements mocked UnitExists behavior for addon tests.
-- @param token Argument named token passed by the tested addon code.
function UnitExists(token)
    unitReads=unitReads+1
    return units[token]~=nil
end
-- Implements mocked UnitIsPlayer behavior for addon tests.
-- @param token Argument named token passed by the tested addon code.
function UnitIsPlayer(token) return units[token] and units[token].isPlayer~=false or false end
-- Implements mocked UnitFactionGroup behavior for addon tests.
-- @param token Argument named token passed by the tested addon code.
function UnitFactionGroup(token)
    if token=="player" then return "Alliance" end
    return units[token] and (units[token].faction or "Alliance")
end
-- Implements mocked UnitNameUnmodified behavior for addon tests.
-- @param token Argument named token passed by the tested addon code.
function UnitNameUnmodified(token)
    local unit=units[token]
    if unit then return unit.name,unit.surname end
end
-- Implements mocked UnitClass behavior for addon tests.
-- @param token Argument named token passed by the tested addon code.
function UnitClass(token)
    local unit=units[token]
    if unit then return unit.className or "Mage",unit.class or "MAGE" end
end
-- Implements mocked UnitRace behavior for addon tests.
-- @param token Argument named token passed by the tested addon code.
function UnitRace(token) return units[token] and (units[token].race or "Human") end
-- Implements mocked UnitLevel behavior for addon tests.
-- @param token Argument named token passed by the tested addon code.
function UnitLevel(token) return units[token] and (units[token].level or 5) end
-- Implements mocked UnitGUID behavior for addon tests.
-- @param token Argument named token passed by the tested addon code.
function UnitGUID(token) return units[token] and units[token].guid end
-- Returns the deterministic mock GetGuildInfo result.
-- @param token Argument named token passed by the tested addon code.
function GetGuildInfo(token) return units[token] and units[token].guild end
'''


class PassiveTests(unittest.TestCase):
    """Checks passive observation and its bounded unit queues."""
    def setUp(self):
        """Creates a fresh test fixture before each test."""
        self.harness = Harness(setup=UNIT_SETUP)

    def check(self, expression):
        """Runs a Lua assertion or statement in the current test fixture."""
        self.assertTrue(self.harness.execute("return " + expression), expression)

    def test_passive_name_and_surname_are_preserved(self):
        """Verifies that passive name and surname are preserved."""
        self.harness.execute("units.target={name='First',surname='Last',guid='GUID1',guild='Guild'}")
        self.harness.advance(0.5)
        self.check("Batata_Scanner.GetPlayer('First Last').guild=='Guild'")
        self.check("Batata_Scanner.GetPlayer('First Last').sources==nil")
        self.check("#whoCalls==0")

    def test_old_disabled_setting_no_longer_stops_passive_recording(self):
        """Verifies that old disabled setting no longer stops passive recording."""
        self.harness = Harness(setup=UNIT_SETUP + "Batata_Scanner_DB={schemaVersion=1,settings={passiveEnabled=false}}")
        self.harness.execute("units.target={name='Recorded',guid='GUID1'}")
        self.harness.advance(0.5)
        self.check("Batata_Scanner.GetPlayer('Recorded')~=nil and NS.db.settings.passiveEnabled==nil")

    def test_repeated_nil_guild_stays_unknown(self):
        """Verifies that repeated nil guild stays unknown."""
        self.harness.execute("units.target={name='Unknown',guid='GUID1'}")
        self.harness.advance(0.5)
        self.check("Batata_Scanner.GetPlayer('Unknown').guild==nil")
        self.harness.advance(3)
        self.check("Batata_Scanner.GetPlayer('Unknown').guild==nil and #whoCalls==0")

    def test_deferred_recheck_can_discover_a_guild(self):
        """Verifies that deferred recheck can discover a guild."""
        self.harness.execute("units.target={name='Unknown',guid='GUID1'}")
        self.harness.advance(0.5)
        self.harness.execute("units.target.guild='Loaded Later'")
        self.harness.advance(2)
        self.check("Batata_Scanner.GetPlayer('Unknown').guild=='Loaded Later'")

    def test_reused_unit_token_does_not_change_the_old_player(self):
        """Verifies that reused unit token does not change the old player."""
        self.harness.execute("units.target={name='Old',guid='OLD'}")
        self.harness.advance(0.5)
        self.harness.execute("units.target={name='New',guid='NEW',guild='Different'}")
        self.harness.advance(2)
        self.check("Batata_Scanner.GetPlayer('Old').guild==nil and Batata_Scanner.GetPlayer('New')==nil")
        self.harness.emit("PLAYER_TARGET_CHANGED")
        self.harness.advance(1)
        self.check("Batata_Scanner.GetPlayer('New').guild=='Different'")

    def test_other_faction_nonplayers_and_secret_identity_are_skipped(self):
        """Verifies that other faction nonplayers and secret identity are skipped."""
        self.harness.execute('''
            units.target={name="Enemy",guid="ENEMY",faction="Horde"}
            units.mouseover={name="Creature",guid="NPC",isPlayer=false}
            units.party1={name="SecretSurname",surname={secret=true},guid="SECRET"}
            units.party2={name={secret=true},guid="SECRET2"}
            units.party3={name="Readable",guid="READABLE",guild={secret=true},race={secret=true}}
        ''')
        self.harness.advance(0.5)
        self.check("Batata_Scanner.CountPlayers()==1")
        self.check("Batata_Scanner.GetPlayer('Readable').guild==nil and Batata_Scanner.GetPlayer('Readable').race==nil")

    def test_missing_guild_does_not_erase_prior_who_knowledge(self):
        """Verifies that missing guild does not erase prior who knowledge."""
        self.harness.execute('''
            NS.Store:Observe({name="Known",level=5,guild="Confirmed Guild"},"who")
            units.target={name="Known",guid="GUID1"}
        ''')
        self.harness.advance(3)
        self.check("Batata_Scanner.GetPlayer('Known').guild=='Confirmed Guild'")

    def test_remote_group_member_does_not_inherit_the_observers_zone(self):
        """Verifies that remote group member does not inherit the observers zone."""
        self.harness.execute('''
            NS.Store:Observe({name="Remote",level=5,zone="Remote Zone"},"who")
            units.party1={name="Remote",guid="REMOTE"}
        ''')
        self.harness.advance(0.5)
        self.check("Batata_Scanner.GetPlayer('Remote').zone=='Remote Zone'")

    def test_batches_and_unit_queue_are_bounded(self):
        """Verifies that batches and unit queue are bounded."""
        self.harness.execute('''
            for index=1,1024 do Emit("NAME_PLATE_UNIT_ADDED","nameplate"..index) end
        ''')
        self.harness.advance(0.5)
        self.check("unitReads<=8")
        self.harness.advance(30)
        self.check("unitReads<=256")

    def test_idle_worker_stops_and_events_restart_bounded_work(self):
        """Verifies that idle worker stops and events restart bounded work."""
        self.harness = Harness(setup=UNIT_SETUP + '''
            passiveTickers={}
            local originalTicker=C_Timer.NewTicker
            C_Timer.NewTicker=function(interval,callback)
                local ticker=originalTicker(interval,callback)
                if interval==0.5 then passiveTickers[#passiveTickers+1]=ticker end
                return ticker
            end
        ''')
        self.harness.advance(4)
        self.check("#passiveTickers==1 and passiveTickers[1].cancelled")
        self.harness.advance(10)
        self.check("#passiveTickers==1")
        self.harness.execute("units.target={name='Event Player',guid='EVENT',guild='Known'}")
        self.harness.emit("PLAYER_TARGET_CHANGED")
        self.check("#passiveTickers==2 and not passiveTickers[2].cancelled")
        self.harness.advance(0.5)
        self.check("Batata_Scanner.GetPlayer('Event Player').guild=='Known' and passiveTickers[2].cancelled")
        self.harness.execute("units.mouseover={name='Delayed Player',guid='DELAYED'}")
        self.harness.emit("UPDATE_MOUSEOVER_UNIT")
        self.harness.advance(0.5)
        self.check("#passiveTickers==3 and not passiveTickers[3].cancelled")
        self.harness.execute("units.mouseover.guild='Loaded Later'")
        self.harness.advance(2)
        self.check("Batata_Scanner.GetPlayer('Delayed Player').guild=='Loaded Later' and passiveTickers[3].cancelled")
        self.harness.emit("PLAYER_TARGET_CHANGED")
        self.harness.emit("PLAYER_LEAVING_WORLD")
        self.check("#passiveTickers==4 and passiveTickers[4].cancelled")
        self.harness.emit("PLAYER_ENTERING_WORLD")
        self.harness.advance(4)
        self.check("#passiveTickers==5 and passiveTickers[5].cancelled and #whoCalls==0")

    def test_stop_cancels_queued_and_deferred_work(self):
        """Verifies that stop cancels queued and deferred work."""
        self.harness.execute("units.target={name='Pending',guid='GUID1'}")
        self.harness.advance(0.5)
        self.harness.execute("NS.Passive:Stop(); units.target.guild='Later'")
        self.harness.advance(5)
        self.check("Batata_Scanner.GetPlayer('Pending').guild==nil")
        self.harness.emit("PLAYER_TARGET_CHANGED")
        self.harness.advance(1)
        self.check("Batata_Scanner.GetPlayer('Pending').guild==nil")

    def test_world_transition_discards_queued_tokens_and_reseeds(self):
        """Verifies that world transition discards queued tokens and reseeds."""
        self.harness.execute("units.target={name='Before',guid='GUID1'}")
        self.harness.emit("PLAYER_LEAVING_WORLD")
        self.harness.advance(1)
        self.check("Batata_Scanner.CountPlayers()==0")
        self.harness.execute("units.target={name='After',guid='GUID2'}")
        self.harness.emit("PLAYER_ENTERING_WORLD")
        self.harness.advance(0.5)
        self.check("Batata_Scanner.GetPlayer('After')~=nil and Batata_Scanner.GetPlayer('Before')==nil")

    def test_disabled_passive_tracks_world_entry_before_restart(self):
        """Verifies that disabled passive tracks world entry before restart."""
        self.harness.emit("PLAYER_LEAVING_WORLD")
        self.harness.execute("NS.Passive:Stop()")
        self.harness.emit("PLAYER_ENTERING_WORLD")
        self.harness.execute("units.target={name='After Restart',guid='GUID2'}; assert(NS.Passive:Start())")
        self.harness.advance(0.5)
        self.check("Batata_Scanner.GetPlayer('After Restart')~=nil")


if __name__ == "__main__":
    unittest.main()
