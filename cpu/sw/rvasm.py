#!/usr/bin/env python3
"""rvasm.py - tiny RV32I assembler.  Usage: python3 rvasm.py prog.asm prog.hex"""
import re
import sys

def build_regs():
    r = {f"x{i}": i for i in range(32)}
    r.update(zero=0, ra=1, sp=2, s0=8, s1=9)
    for i in range(8):      r[f"a{i}"] = 10 + i
    for i in range(2, 12):  r[f"s{i}"] = 16 + i
    for i in range(3):      r[f"t{i}"] = 5 + i
    for i in range(3, 7):   r[f"t{i}"] = 25 + i
    return r

R_OPS  = {"add": (0, 0), "sub": (0x20, 0), "sll": (0, 1), "slt": (0, 2), "sltu": (0, 3),
          "xor": (0, 4), "srl": (0, 5), "sra": (0x20, 5), "or": (0, 6), "and": (0, 7)}
I_OPS  = {"addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7}
SH_OPS = {"slli": (0, 1), "srli": (0, 5), "srai": (0x20, 5)}
B_OPS  = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}

def enc_r(f7, rs2, rs1, f3, rd):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x33

def enc_i(imm, rs1, f3, rd, op):
    if not -2048 <= imm < 2048:
        raise ValueError(f"immediate {imm} does not fit in 12 bits")
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

def enc_s(imm, rs2, rs1, f3):
    if not -2048 <= imm < 2048:
        raise ValueError(f"offset {imm} does not fit in 12 bits")
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | 0x23

def enc_b(off, rs2, rs1, f3):
    if not -4096 <= off < 4096 or off % 2:
        raise ValueError(f"branch offset {off} out of range")
    off &= 0x1FFF
    return (((off >> 12) & 1) << 31) | (((off >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (f3 << 12) | (((off >> 1) & 0xF) << 8) | (((off >> 11) & 1) << 7) | 0x63

def enc_u(imm20, rd, op):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op

def enc_j(off, rd):
    if not -(1 << 20) <= off < (1 << 20) or off % 2:
        raise ValueError(f"jump offset {off} out of range")
    off &= 0x1FFFFF
    return (((off >> 20) & 1) << 31) | (((off >> 1) & 0x3FF) << 21) | (((off >> 11) & 1) << 20) | \
           (((off >> 12) & 0xFF) << 12) | (rd << 7) | 0x6F

class Asm:
    def __init__(self):
        self.regs, self.sym, self.labels, self.items = build_regs(), {}, {}, []

    def num(self, tok):
        tok = tok.strip()
        if tok.startswith("-") and tok[1:] in self.sym:
            return -self.sym[tok[1:]]
        if tok in self.sym:
            return self.sym[tok]
        return int(tok, 0)

    def reg(self, tok):
        tok = tok.strip()
        if tok not in self.regs:
            raise ValueError(f"bad register '{tok}'")
        return self.regs[tok]

    def mem(self, tok):
        m = re.match(r"^(.*)\((\w+)\)$", tok.strip())
        if not m:
            raise ValueError(f"bad memory operand '{tok}'")
        return self.num(m.group(1) or "0"), self.reg(m.group(2))

    def target(self, tok):
        if tok.strip() not in self.labels:
            raise ValueError(f"unknown label '{tok}'")
        return self.labels[tok.strip()]

    def expand(self, op, a):
        if op == "li":
            v = self.num(a[1]) & 0xFFFFFFFF
            v = (v ^ 0x80000000) - 0x80000000
            if -2048 <= v < 2048:
                return [("addi", [a[0], "zero", str(v)])]
            lo = ((v & 0xFFF) ^ 0x800) - 0x800
            hi = ((v - lo) >> 12) & 0xFFFFF
            out = [("lui", [a[0], str(hi)])]
            if lo:
                out.append(("addi", [a[0], a[0], str(lo)]))
            return out
        if op == "mv":   return [("addi", [a[0], a[1], "0"])]
        if op == "j":    return [("jal", ["zero", a[0]])]
        if op == "ret":  return [("jalr", ["zero", "ra", "0"])]
        if op == "nop":  return [("addi", ["zero", "zero", "0"])]
        if op == "beqz": return [("beq", [a[0], "zero", a[1]])]
        if op == "bnez": return [("bne", [a[0], "zero", a[1]])]
        return [(op, a)]

    def first_pass(self, text):
        pc = 0
        for n, raw in enumerate(text.splitlines(), 1):
            line = raw.split("#")[0].strip()
            while True:
                m = re.match(r"^(\w+):\s*(.*)$", line)
                if not m:
                    break
                self.labels[m.group(1)] = pc
                line = m.group(2)
            if not line:
                continue
            try:
                if line.startswith(".equ"):
                    name, val = [t.strip() for t in line[4:].split(",", 1)]
                    self.sym[name] = self.num(val)
                    continue
                parts = line.split(None, 1)
                args = [x.strip() for x in parts[1].split(",")] if len(parts) > 1 else []
                for item in self.expand(parts[0].lower(), args):
                    self.items.append((pc, item, n))
                    pc += 4
            except ValueError as e:
                sys.exit(f"line {n}: {e}")

    def encode(self, pc, op, a):
        R = self.reg
        if op in R_OPS:
            f7, f3 = R_OPS[op]
            return enc_r(f7, R(a[2]), R(a[1]), f3, R(a[0]))
        if op in I_OPS:
            return enc_i(self.num(a[2]), R(a[1]), I_OPS[op], R(a[0]), 0x13)
        if op in SH_OPS:
            f7, f3 = SH_OPS[op]
            sh = self.num(a[2])
            if not 0 <= sh < 32:
                raise ValueError("shift amount must be 0..31")
            return enc_i((f7 << 5) | sh, R(a[1]), f3, R(a[0]), 0x13)
        if op == "lw":
            imm, rs1 = self.mem(a[1])
            return enc_i(imm, rs1, 2, R(a[0]), 0x03)
        if op == "sw":
            imm, rs1 = self.mem(a[1])
            return enc_s(imm, R(a[0]), rs1, 2)
        if op in B_OPS:
            return enc_b(self.target(a[2]) - pc, R(a[1]), R(a[0]), B_OPS[op])
        if op == "lui":
            return enc_u(self.num(a[1]), R(a[0]), 0x37)
        if op == "auipc":
            return enc_u(self.num(a[1]), R(a[0]), 0x17)
        if op == "jal":
            return enc_j(self.target(a[1]) - pc, R(a[0]))
        if op == "jalr":
            return enc_i(self.num(a[2]), R(a[1]), 0, R(a[0]), 0x67)
        raise ValueError(f"unknown instruction '{op}'")

    def assemble(self, text):
        self.first_pass(text)
        words = []
        for pc, (op, a), n in self.items:
            try:
                words.append(self.encode(pc, op, a))
            except (ValueError, IndexError) as e:
                sys.exit(f"line {n}: {e}")
        return words

if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: python3 rvasm.py prog.asm prog.hex")
    words = Asm().assemble(open(sys.argv[1]).read())
    with open(sys.argv[2], "w") as f:
        f.write("\n".join(f"{w:08x}" for w in words) + "\n")
    print(f"{len(words)} words written to {sys.argv[2]}")