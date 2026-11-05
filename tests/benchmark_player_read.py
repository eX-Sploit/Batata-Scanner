"""Synthetic Lua 5.1 timings, not WoW runtime evidence. Run from the addon root."""
import argparse
import json
import time

from harness import Harness


def profile(record_count, budget):
    setup = '''
        Batata_Scanner_DB={schemaVersion=1,players={}}
        for playerIndex=1,%d do
            Batata_Scanner_DB.players[playerIndex]={
                name=string.format("Synthetic %%06d",playerIndex),
                faction=playerIndex%%4==0 and "Horde" or "Alliance",
                level=30,class="Mage",race="Human",guild="",zone="Synthetic zone",
                firstSeen=epoch-1000,lastSeen=playerIndex<=209 and epoch or epoch-100
            }
        end
    ''' % record_count
    harness = Harness(setup=setup)
    harness.lua.globals().ProfileMilliseconds = lambda: time.perf_counter() * 1000
    harness.execute('debugprofilestop=function() return ProfileMilliseconds() end')
    open_cursor = harness.lua.eval('''function(recurring)
        return Batata_Scanner.OpenPlayerCursor(
            {faction="Alliance",seenAfter=recurring and epoch or nil},
            {sort="name",limit=100})
    end''')
    advance = harness.lua.globals().Batata_Scanner.AdvancePlayerCursor
    close = harness.lua.globals().Batata_Scanner.ClosePlayerCursor
    current_sequence = harness.lua.eval('function() local sequence=NS.Store:GetReadPosition();return sequence end')
    mutate = harness.lua.eval('''function(stepIndex)
        local isNew,changed=NS.Store:Observe({name=string.format("Synthetic %06d",stepIndex%209+1),level=stepIndex%60+1})
        return changed
    end''')
    results = []
    for recurring in (False, True):
        started = time.perf_counter()
        cursor = open_cursor(recurring)
        creation_ms = (time.perf_counter() - started) * 1000
        maxima = {}
        max_operation_ms = 0
        advancement_count = player_count = change_count = 0
        mutation_count = 0
        max_advance_ms = 0
        drain = False
        started = time.perf_counter()
        while True:
            advancement_count += 1
            if recurring and not drain:
                mutation_count += bool(mutate(advancement_count))
            call_started = time.perf_counter()
            page = advance(cursor, budget)
            elapsed_ms = (time.perf_counter() - call_started) * 1000
            phase = page['state']
            assert phase != 'resetRequired', page['reason']
            maxima[phase] = max(maxima.get(phase, 0), elapsed_ms)
            max_advance_ms = max(max_advance_ms, elapsed_ms)
            max_operation_ms = max(max_operation_ms, page['maxOperationMs'] or 0)
            player_count += len(page['players'])
            change_count += len(page['changes'])
            if page['snapshotComplete']:
                drain = True
            if drain and page['caughtUp'] and page['sequence'] == current_sequence():
                break
            assert advancement_count < 1000000
        assert change_count == mutation_count
        assert player_count == (157 if recurring else record_count - record_count // 4)
        job_ms = (time.perf_counter() - started) * 1000
        started = time.perf_counter()
        close(cursor)
        close_ms = (time.perf_counter() - started) * 1000
        results.append({
            'scenario': 'warm_order_with_updates' if recurring else 'cold_initial',
            'stored_records': record_count,
            'budget_ms': budget,
            'creation_ms': round(creation_ms, 4),
            'close_ms': round(close_ms, 4),
            'max_advancement_ms': round(max_advance_ms, 4),
            'max_operation_ms': round(max_operation_ms, 4),
            'max_by_final_phase_ms': {phase: round(value, 4) for phase, value in maxima.items()},
            'advancements': advancement_count,
            'snapshot_players': player_count,
            'replayed_changes': change_count,
            'job_ms': round(job_ms, 3),
        })
    return results


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sizes', nargs='+', type=int, default=[1000, 10000, 50000])
    parser.add_argument('--budget', type=float, default=2)
    arguments = parser.parse_args()
    for size in arguments.sizes:
        for result in profile(size, arguments.budget):
            print(json.dumps(result), flush=True)
