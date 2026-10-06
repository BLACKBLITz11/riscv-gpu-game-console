#!/usr/bin/env python3
"""Swarm shooter: the RV32I CPU runs the game loop, the GPU moves the enemies.

    python game_cpu.py                       play (needs a window: tkinter ships with Python)
    python game_cpu.py --bot                 watch a simple bot play in the window
    python game_cpu.py --headless --frames 300 --bot     no window, prints a summary

Controls: Left/Right (or A/D) move, Space fires, R restarts, Esc quits.

Division of labour:
  CPU (game.asm)   : reads the buttons, moves the player and the shots, fires automatically while
                     Space is held, runs one GPU tick per frame
  GPU              : moves all 32 enemies, wraps them, kills any enemy within 8 px of any of 4 shots
  this file        : sends the buttons, draws the frame, keeps score / lives / waves, and decides
                     the weapon level (more score = more shots in flight, UPGRADE_SCORES)
                     (the CPU cannot read enemy state back yet - see the GPU host contract, section 8)
"""
import sys, time, argparse
from cpu_host import CpuSim, N_CORES, BTN_LEFT, BTN_RIGHT, BTN_FIRE, BTN_RESPAWN, LEVEL_SHIFT

PLAYER_Y, HIT_R, COOLDOWN = 240, 8, 30
UPGRADE_SCORES = (100, 300, 600)   # score needed for 2, 3 and 4 shots in flight


class Game:
    def __init__(self, sim):
        self.sim = sim
        self.reset(first=True)

    def reset(self, first=False):
        self.score, self.lives, self.wave, self.over = 0, 3, 1, False
        self.flash, self.cool = 0, 0
        self.ents, self.alive_prev = [], [1] * N_CORES
        self.px, self.shots = 128, []
        self.want_respawn = not first          # the CPU spawns wave 1 by itself at power-on
        self.parked_kills = 0                  # must stay 0: a parked shot can never hit

    def weapon_level(self):
        return 1 + sum(1 for t in UPGRADE_SCORES if self.score >= t)

    def alive_count(self):
        return sum(1 for e in self.ents if e[1])

    def step(self, left, right, fire):
        if self.over:
            return
        if self.flash:
            self.flash -= 1
        if self.cool:
            self.cool -= 1
        buttons = (BTN_LEFT if left else 0) | (BTN_RIGHT if right else 0) | (BTN_FIRE if fire else 0)
        buttons |= (self.weapon_level() - 1) << LEVEL_SHIFT
        if self.want_respawn:
            buttons |= BTN_RESPAWN
            self.alive_prev = [1] * N_CORES
            self.want_respawn = False
        _, ents, hosts = self.sim.frame(buttons)

        self.px = hosts[0]
        self.shots = [(hosts[2 + 2 * k], hosts[3 + 2 * k]) for k in range(4) if hosts[3 + 2 * k] <= 255]
        kills = sum(1 for i in range(N_CORES) if self.alive_prev[i] and not ents[i][1])
        if kills:
            if not self.shots:
                self.parked_kills += kills
            self.score += 10 * kills
        self.ents = ents
        self.alive_prev = [e[1] for e in ents]

        if not self.cool:                      # enemy touches the player (display-side rule)
            for e in ents:
                if e[1] and abs(e[2] - self.px) <= HIT_R and abs(e[3] - PLAYER_Y) <= HIT_R:
                    self.lives -= 1
                    self.flash, self.cool = 10, COOLDOWN
                    break
        if self.lives <= 0:
            self.over = True
        elif sum(self.alive_prev) == 0:        # wave cleared: ask the CPU for 32 new enemies
            self.wave += 1
            self.want_respawn = True

    def bot_action(self):
        targets = [e for e in self.ents if e[1] and e[3] < PLAYER_Y - 12]
        left = right = 0
        if targets:
            tx = min(targets, key=lambda e: abs(e[2] - self.px))[2]
            left, right = int(tx < self.px - 3), int(tx > self.px + 3)
        return left, right, True


def run_headless(game, frames, bot):
    t0 = time.time()
    for f in range(frames):
        game.step(*(game.bot_action() if bot else (0, 0, False)))
        if game.over:
            break
    dt = time.time() - t0
    print(f"{f + 1} frames, {(f + 1) / dt:.1f} frames/s | score {game.score} | lives {game.lives} "
          f"| wave {game.wave} | weapon x{game.weapon_level()} | alive {game.alive_count()} "
          f"| parked-shot kills {game.parked_kills}")
    return game.parked_kills == 0


def run_window(game, bot, max_frames=None):
    import tkinter as tk
    root = tk.Tk()
    root.title("Swarm Shooter - RV32I CPU + GPU (simulated)")
    s = max(1, min(3, (root.winfo_screenheight() - 160) // 256))
    root.resizable(False, False)
    canvas = tk.Canvas(root, width=256 * s, height=256 * s + 24, bg='black', highlightthickness=0)
    canvas.pack()
    keys, state = set(), {'frames': 0, 'fps': 0.0, 't': time.time()}
    root.bind('<KeyPress>', lambda e: keys.add(e.keysym.lower()))
    root.bind('<KeyRelease>', lambda e: keys.discard(e.keysym.lower()))

    def draw():
        canvas.delete('all')
        W = 256 * s
        canvas.create_line(0, (PLAYER_Y + 12) * s, W, (PLAYER_Y + 12) * s, fill='#202020')
        for e in game.ents:
            if e[1]:
                canvas.create_rectangle((e[2] - 1.5) * s, (e[3] - 1.5) * s, (e[2] + 1.5) * s, (e[3] + 1.5) * s,
                                        fill='#ff5050', outline='')
        px, py = game.px * s, PLAYER_Y * s
        canvas.create_polygon(px, py - 4 * s, px - 3 * s, py + 3 * s, px + 3 * s, py + 3 * s,
                              fill='#50ff90', outline='')
        for sx, sy in game.shots:
            canvas.create_rectangle(sx * s - 1, sy * s - 2 * s, sx * s + 1, sy * s + 2 * s,
                                    fill='white', outline='')
        canvas.create_text(6, 6, anchor='nw', fill='white', font=('Consolas', 11),
                           text=f"score {game.score}   lives {'<3 ' * game.lives}   wave {game.wave}   weapon x{game.weapon_level()}   {state['fps']:.0f} fps")
        canvas.create_text(W // 2, 256 * s + 12, fill='#808080', font=('Consolas', 10),
                           text='LEFT/RIGHT or A/D move   hold SPACE to fire   R restart   ESC quit')
        if game.flash:
            canvas.create_rectangle(1, 1, W - 1, 256 * s - 1, outline='#ff3030', width=4)
            canvas.create_text(W // 2, 60 * s, fill='#ff6060', font=('Consolas', 20, 'bold'), text='HIT!  -1 life')
        if game.over:
            canvas.create_text(W // 2, 110 * s, fill='white', font=('Consolas', 24, 'bold'), text='GAME OVER')
            canvas.create_text(W // 2, 128 * s, fill='#aaaaaa', font=('Consolas', 12), text='press R to restart')

    def loop():
        if 'escape' in keys or (max_frames and state['frames'] >= max_frames):
            return root.destroy()
        if game.over and 'r' in keys:
            game.reset()
        if bot:
            game.step(*game.bot_action())
        else:
            game.step(int('left' in keys or 'a' in keys), int('right' in keys or 'd' in keys), 'space' in keys)
        now = time.time()
        state['fps'] = 0.9 * state['fps'] + 0.1 / max(now - state['t'], 1e-6)
        state['t'] = now
        state['frames'] += 1
        draw()
        root.after(1, loop)

    root.protocol('WM_DELETE_WINDOW', root.destroy)
    root.after(10, loop)
    root.mainloop()


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--bot', action='store_true', help='let a bot play')
    ap.add_argument('--headless', action='store_true', help='no window, print a summary')
    ap.add_argument('--frames', type=int, default=300)
    a = ap.parse_args()
    sim = CpuSim()
    try:
        g = Game(sim)
        if a.headless:
            sys.exit(0 if run_headless(g, a.frames, a.bot) else 1)
        run_window(g, a.bot, a.frames if a.bot and '--frames' in sys.argv else None)
    finally:
        sim.close()