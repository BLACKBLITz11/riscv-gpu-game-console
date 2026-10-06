#!/usr/bin/env python3
"""Python host for the simulated GPU (drives sim_server.v through command files).

    python gpu_host.py            # self-test: GPU vs. a Python reference model

Needs `iverilog` and `vvp` on PATH, and these files in the same folder:
alu.v reg_file.v prog_counter.v shader_core.v mem_ctrl.v framebuffer.v gpu_top.v
sim_server.v assembler.py entity_update.asm
"""
import os, sys, time, glob, random, shutil, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import repo            # finds files anywhere in the repository
import assembler

RTL = ['gpu_alu.v', 'gpu_reg_file.v', 'gpu_prog_counter.v', 'shader_core.v', 'mem_ctrl.v',
       'framebuffer.v', 'gpu_top.v', 'sim_server.v']
N_CORES = 32
PARKED = 1000            # shot coordinate that can never hit (entities are 0..255)

# host_addr words in global memory (see host_contract.md)
PLAYER_X, PLAYER_Y, SHOT_X, SHOT_Y = 0, 1, 2, 3
# local-memory words per entity
L_X, L_Y, L_VX, L_VY, L_ALIVE = 0, 1, 2, 3, 4


class GpuSim:
    def __init__(self, program='entity_update.asm', work='simwork'):
        self.work = os.path.join(HERE, work)
        shutil.rmtree(self.work, ignore_errors=True)
        os.makedirs(self.work, exist_ok=True)
        for tool in ('iverilog', 'vvp'):
            if shutil.which(tool) is None:
                raise SystemExit(f"'{tool}' not found on PATH - install Icarus Verilog first.")
            files = [repo.find(f) for f in RTL]
        missing = [f for f in files if not os.path.exists(f)]
        if missing:
            raise SystemExit("missing files: " + ", ".join(os.path.basename(m) for m in missing))
        vvp_file = os.path.join(self.work, 'sim.vvp')
        r = subprocess.run(['iverilog', '-g2012', '-s', 'sim_server', '-o', vvp_file] + files,
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit("iverilog failed:\n" + r.stdout + r.stderr)
        self.log = open(os.path.join(self.work, 'sim.log'), 'w')
        self.proc = subprocess.Popen(['vvp', 'sim.vvp'], cwd=self.work,
                                     stdout=self.log, stderr=subprocess.STDOUT)
        self.seq = 1
        with open(repo.find(program)) as f:
            self.program, _ = assembler.assemble(f.readlines())
        self.run([f'PROG {a} {w}' for a, w in enumerate(self.program)])

    # ---- low level -------------------------------------------------------
    def run(self, cmds, timeout=120):
        """Send a list of command lines, wait for the response, return its lines."""
        n = self.seq
        tmp = os.path.join(self.work, f'cmd_{n:06d}.tmp')
        final = os.path.join(self.work, f'cmd_{n:06d}.txt')
        with open(tmp, 'w') as f:
            f.write('\n'.join(cmds) + '\n')
        for _ in range(200):                  # rename into place (retry: Windows file locks)
            try:
                os.replace(tmp, final)
                break
            except PermissionError:
                time.sleep(0.005)
        done = os.path.join(self.work, f'rsp_{n:06d}.done')
        rsp = os.path.join(self.work, f'rsp_{n:06d}.txt')
        t0 = time.time()
        while not os.path.exists(done):
            if self.proc.poll() is not None:
                raise RuntimeError("simulator exited unexpectedly; see simwork/sim.log")
            if time.time() - t0 > timeout:
                raise TimeoutError("simulator did not answer")
            time.sleep(0.0005)
        with open(rsp) as f:
            lines = f.read().split('\n')
        for p in (final, rsp, done):
            for _ in range(50):
                try:
                    os.remove(p)
                    break
                except PermissionError:
                    time.sleep(0.005)
        self.seq += 1
        lines = [l for l in lines if l]
        errs = [l for l in lines if l.startswith('ERR')]
        if errs:
            raise RuntimeError("simulator error: " + errs[0])
        return lines

    @staticmethod
    def parse(lines):
        out = {'tick': None, 'render': None, 'entities': [], 'pixels': {}}
        for l in lines:
            p = l.split()
            if p[0] == 'TICK':
                out['tick'] = int(p[1])
            elif p[0] == 'RENDER':
                out['render'] = int(p[1])
            elif p[0] == 'E':
                out['entities'].append(tuple(int(x) for x in p[1:]))   # core alive x y vx vy
            elif p[0] == 'PIXEL':
                out['pixels'][(int(p[1]), int(p[2]))] = int(p[3])
        return out

    # ---- convenience -----------------------------------------------------
    @staticmethod
    def spawn_cmds(core, x, y, vx, vy, alive):
        return [f'SPAWN {core} {L_X} {x}', f'SPAWN {core} {L_Y} {y}',
                f'SPAWN {core} {L_VX} {vx}', f'SPAWN {core} {L_VY} {vy}',
                f'SPAWN {core} {L_ALIVE} {1 if alive else 0}']

    def frame(self, player, shot, extra=()):
        """One game frame in ONE round trip: optional extra commands (spawns...),
        write player+shot, run a tick, read every entity back."""
        cmds = list(extra)
        cmds += [f'HOST {PLAYER_X} {player[0]}', f'HOST {PLAYER_Y} {player[1]}',
                 f'HOST {SHOT_X} {shot[0]}', f'HOST {SHOT_Y} {shot[1]}']
        cmds += [f'HOST {a} {PARKED}' for a in range(4, 10)]       # shot slots 1..3 stay parked
        cmds += ['START', 'DUMP']
        r = self.parse(self.run(cmds))
        return r['tick'], r['entities']

    def close(self):
        try:
            self.run(['QUIT'], timeout=10)
        except Exception:
            pass
        try:
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()
        self.log.close()


class RefModel:
    """Pure-Python copy of what entity_update.asm does (see host_contract.md, section 6)."""
    def __init__(self):
        self.e = [dict(x=0, y=0, vx=0, vy=0, alive=0) for _ in range(N_CORES)]

    def set(self, i, x, y, vx, vy, alive):
        self.e[i] = dict(x=x, y=y, vx=vx, vy=vy, alive=1 if alive else 0)

    def tick(self, shot):
        for en in self.e:
            if en['alive']:
                en['x'] = (en['x'] + en['vx']) & 255
                en['y'] = (en['y'] + en['vy']) & 255
                if abs(en['x'] - shot[0]) <= 8 and abs(en['y'] - shot[1]) <= 8:
                    en['alive'] = 0

    def as_tuples(self):
        return [(i, en['alive'], en['x'], en['y'], en['vx'], en['vy']) for i, en in enumerate(self.e)]


def selftest(ticks=60, seed=7):
    rng = random.Random(seed)
    sim = GpuSim()
    ref = RefModel()
    errors = 0
    cmds = []
    for i in range(N_CORES):
        x, y = rng.randrange(256), rng.randrange(256)
        vx, vy = rng.randint(-15, 15), rng.randint(-15, 15)
        alive = (i % 8 != 0)
        ref.set(i, x, y, vx, vy, alive)
        cmds += GpuSim.spawn_cmds(i, x, y, vx, vy, alive)
    sim.run(cmds)
    parked_hits = 0
    t0 = time.time()
    tick_cycles = []
    for t in range(ticks):
        alive_idx = [i for i, en in enumerate(ref.e) if en['alive']]
        if t % 5 == 4 or not alive_idx:
            shot = (PARKED, PARKED)                     # parked shot must never hit anything
        else:
            en = ref.e[rng.choice(alive_idx)]           # aim near where an entity will be
            shot = ((en['x'] + en['vx'] + rng.randint(-10, 10)) & 255,
                    (en['y'] + en['vy'] + rng.randint(-10, 10)) & 255)
        before = sum(en['alive'] for en in ref.e)
        ref.tick(shot)
        if shot[0] == PARKED:
            parked_hits += before - sum(en['alive'] for en in ref.e)
        cyc, ents = sim.frame((128, 240), shot)
        tick_cycles.append(cyc)
        if ents != ref.as_tuples():
            errors += 1
            print(f"MISMATCH at tick {t}")
    dt = time.time() - t0
    # hardware framebuffer: every alive entity must be lit, via RENDER + PIXEL
    alive_now = [en for en in ref.e if en['alive']]
    r = GpuSim.parse(sim.run(['RENDER'] + [f"PIXEL {en['x']} {en['y']}" for en in alive_now]))
    fb_ok = all(v == 1 for v in r['pixels'].values()) and len(r['pixels']) == len(
        {(en['x'], en['y']) for en in alive_now})
    if not fb_ok:
        errors += 1
        print("framebuffer: an alive entity is not lit")
    sim.close()
    print(f"{ticks} ticks compared against the Python model, "
          f"tick latency {min(tick_cycles)}..{max(tick_cycles)} cycles, "
          f"{ticks / dt:.1f} frames/s, parked-shot hits = {parked_hits}, "
          f"framebuffer check {'ok' if fb_ok else 'FAILED'}")
    print("=== ALL TESTS PASSED ===" if errors == 0 and parked_hits == 0 else f"=== {errors} FAILED ===")
    return errors == 0 and parked_hits == 0


if __name__ == '__main__':
    sys.exit(0 if selftest() else 1)