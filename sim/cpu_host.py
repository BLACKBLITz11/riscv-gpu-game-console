#!/usr/bin/env python3
"""Python host for the whole console in simulation: RV32I CPU + bridge + GPU.

The CPU runs game.asm by itself. Python only (1) presses the controller buttons and
(2) looks at the result after every frame to draw it.  Runs sim_cpu_server.v.

    python cpu_host.py        # quick self-test

Needs `iverilog` and `vvp` on PATH, and these files in the same folder:
  GPU : gpu_alu.v gpu_reg_file.v gpu_prog_counter.v shader_core.v mem_ctrl.v framebuffer.v gpu_top.v
        assembler.py entity_update.asm
  CPU : alu.v reg_file.v prog_counter.v decoder.v control_unit.v cpu_core.v memories.v
        cpu_system.v gpu_bridge.v gpu_regs.vh rvasm.py game.asm
  sim : sim_cpu_server.v gpu_host.py
"""
import os, sys, shutil, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import repo
import assembler
import rvasm
from gpu_host import GpuSim, N_CORES

GPU_RTL = ['gpu_alu.v', 'gpu_reg_file.v', 'gpu_prog_counter.v', 'shader_core.v',
           'mem_ctrl.v', 'framebuffer.v', 'gpu_top.v']
CPU_RTL = ['alu.v', 'reg_file.v', 'prog_counter.v', 'decoder.v', 'control_unit.v',
           'cpu_core.v', 'memories.v', 'cpu_system.v', 'gpu_bridge.v']
RTL = GPU_RTL + CPU_RTL + ['sim_cpu_server.v']

# controller bits read by game.asm
BTN_LEFT, BTN_RIGHT, BTN_FIRE, BTN_RESPAWN = 4, 8, 16, 32
LEVEL_SHIFT = 6               # bits 7:6 of the button register carry (weapon level - 1)


class CpuSim(GpuSim):
    """Same file protocol as GpuSim, but the commands drive the CPU system."""

    def __init__(self, cpu_program='game.asm', gpu_program='entity_update.asm', work='cpusimwork'):
        self.work = os.path.join(HERE, work)
        shutil.rmtree(self.work, ignore_errors=True)
        os.makedirs(self.work)
        for tool in ('iverilog', 'vvp'):
            if shutil.which(tool) is None:
                raise SystemExit(f"'{tool}' not found on PATH - install Icarus Verilog first.")
        files = [repo.find(f) for f in RTL]
        missing = [f for f in files if not os.path.exists(f)]
        if missing:
            raise SystemExit("missing files: " + ", ".join(os.path.basename(m) for m in missing))

        # assemble the CPU program; vvp runs inside the work folder, so game.hex goes there
        with open(repo.find(cpu_program)) as f:
            words = rvasm.Asm().assemble(f.read())
        with open(os.path.join(self.work, 'game.hex'), 'w') as f:
            f.write('\n'.join(f'{w:08x}' for w in words) + '\n')

        vvp_file = os.path.join(self.work, 'sim.vvp')
        r = subprocess.run(['iverilog', '-g2012', '-I', os.path.dirname(repo.find('gpu_regs.vh')), '-s', 'sim_cpu_server',
                            '-o', vvp_file] + files, capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit("iverilog failed:\n" + r.stdout + r.stderr)
        self.log = open(os.path.join(self.work, 'sim.log'), 'w')
        self.proc = subprocess.Popen(['vvp', 'sim.vvp'], cwd=self.work,
                                     stdout=self.log, stderr=subprocess.STDOUT)
        self.seq = 1

        # GPU instruction ROM, then release the CPU
        with open(repo.find(gpu_program)) as f:
            self.program, _ = assembler.assemble(f.readlines())
        self.run([f'PROG {a} {w}' for a, w in enumerate(self.program)] + ['GO'])
        self.cpu_words = len(words)

    def frame(self, buttons):
        """Set the buttons, let the CPU run until the GPU finishes one tick, read the result.
        Returns (tick_cycles, entities, hosts) where entities = 32 x (core, alive, x, y, vx, vy)
        and hosts = the 10 words the CPU wrote to the GPU: player_x, player_y, then four shot
        slots as (x, y) pairs.  A slot with y > 255 is empty."""
        lines = self.run([f'BUTTONS {buttons}', 'FRAME', 'DUMP'])
        r = self.parse(lines)
        hosts = next(tuple(int(x) for x in l.split()[1:11]) for l in lines if l.startswith('HOSTS'))
        k = next((l.split() for l in lines if l.startswith('KILLS')), None)
        self.kills = int(k[1]) if k else None          # the CPU's own kill total (register s4)
        self.prev_alive = int(k[2]) if k else None     # register s3
        return r['tick'], r['entities'], hosts


def selftest(frames=40):
    sim = CpuSim()
    ok = True
    tick, ents, hosts = sim.frame(0)
    alive = sum(e[1] for e in ents)
    print(f"frame 1: tick {tick} cycles, alive {alive}, player {hosts[:2]}, shot slots {hosts[2:]}")
    ok &= (alive == 32 and hosts[0] == 128 and hosts[1] == 240)
    x = hosts[0]
    for _ in range(frames):
        tick, ents, hosts = sim.frame(BTN_RIGHT)
    ok &= (hosts[0] == min(247, x + 5 * frames))
    print(f"after {frames} frames holding RIGHT: player_x = {hosts[0]}")
    # hold FIRE at weapon level 2: two shots must be in flight, one after the other
    most = 0
    for _ in range(40):
        tick, ents, hosts = sim.frame(BTN_FIRE | (1 << LEVEL_SHIFT))
        most = max(most, sum(1 for k in range(4) if hosts[3 + 2 * k] <= 255))
    print(f"weapon level 2, fire held: up to {most} shots in flight")
    ok &= (most == 2)
    sim.close()
    print("=== OK ===" if ok else "=== FAILED ===")
    return ok

def kill_test(frames=150):
    """The CPU's own kill total (s4) must match the enemies that really died."""
    sim = CpuSim()
    ok = True
    alive_prev = N_CORES                      # entities alive in the previous frame
    for i in range(frames):
        sweep = BTN_LEFT if (i // 25) % 2 else BTN_RIGHT
        tick, ents, hosts = sim.frame(BTN_FIRE | sweep | (3 << LEVEL_SHIFT))
        # s4 lags one frame: at this point the CPU has counted the renders up to the previous frame
        if sim.kills != N_CORES - alive_prev:
            print(f"frame {i + 1}: CPU kills {sim.kills}, expected {N_CORES - alive_prev}")
            ok = False
            break
        alive_prev = sum(e[1] for e in ents)
    print(f"after the run: enemies dead {N_CORES - alive_prev}, CPU kill counter {sim.kills}")
    if N_CORES - alive_prev == 0:
        print("WARNING: no enemy died, so this test proves nothing")
        ok = False
    sim.close()
    print("=== KILL COUNTER OK ===" if ok else "=== KILL COUNTER FAILED ===")
    return ok

if __name__ == '__main__':
    ok = selftest()
    if '--kills' in sys.argv:
        ok = kill_test() and ok
    sys.exit(0 if ok else 1)