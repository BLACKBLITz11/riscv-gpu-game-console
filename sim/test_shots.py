#!/usr/bin/env python3
"""Checks the 4-shot entity program on the simulated GPU.

    python test_shots.py

Each test puts enemies that stand still at known spots and shots at known spots,
runs one tick, and checks who died.
"""
import sys
from gpu_host import GpuSim, N_CORES, PARKED

EX = [20 + 28 * i for i in range(8)]     # enemy x positions, enemy y is always 100
EY = 100


def spawn_all():
    cmds = []
    for i in range(N_CORES):
        if i < 8:
            cmds += GpuSim.spawn_cmds(i, EX[i], EY, 0, 0, True)
        else:
            cmds += GpuSim.spawn_cmds(i, 0, 0, 0, 0, False)
    return cmds


def tick(sim, shots):
    """shots = 4 (x, y) pairs for shot slots 0..3 (slot k lives at host words 2+2k, 3+2k)."""
    cmds = []
    for k in range(4):
        cmds += [f'HOST {2 + 2 * k} {shots[k][0]}', f'HOST {3 + 2 * k} {shots[k][1]}']
    r = GpuSim.parse(sim.run(spawn_all() + cmds + ['START', 'DUMP']))
    return [e[1] for e in r['entities'][:8]]          # alive flags of the 8 enemies


def parked(**slots):
    s = [(PARKED, PARKED)] * 4
    for k, v in slots.items():
        s[int(k[1:])] = v
    return s


def main():
    sim = GpuSim()
    errors = 0

    def expect(name, alive, dead_set):
        nonlocal errors
        exp = [0 if i in dead_set else 1 for i in range(8)]
        ok = alive == exp
        errors += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {name}" + ("" if ok else f"   alive {alive}, expected {exp}"))

    expect("all slots parked: nobody dies", tick(sim, parked()), set())
    for k in range(4):
        expect(f"slot {k} on enemy {k}: it dies", tick(sim, parked(**{f's{k}': (EX[k], EY)})), {k})
    expect("slot 2 exactly 8 px away: hit (radius edge)", tick(sim, parked(s2=(EX[2] + 8, EY))), {2})
    expect("slot 2 9 px away: miss", tick(sim, parked(s2=(EX[2] + 9, EY))), set())
    expect("slot 3 9 px above: miss", tick(sim, parked(s3=(EX[3], EY - 9))), set())
    expect("slots 1 and 3 hit enemies 4 and 5", tick(sim, parked(s1=(EX[4], EY), s3=(EX[5], EY))), {4, 5})
    expect("all four slots hit enemies 0, 2, 4, 6",
           tick(sim, [(EX[0], EY), (EX[2], EY), (EX[4], EY), (EX[6], EY)]), {0, 2, 4, 6})
    sim.close()
    print("=== ALL TESTS PASSED ===" if errors == 0 else f"=== {errors} FAILED ===")
    return errors == 0


if __name__ == '__main__':
    sys.exit(0 if main() else 1)