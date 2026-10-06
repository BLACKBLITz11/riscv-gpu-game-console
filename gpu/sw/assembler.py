#!/usr/bin/env python3
"""Tiny assembler for the 23-op tinyGPU-style ISA used by shader_core.v.

Instruction formats (both 32 bits):
  R-type: opcode(6) rd(4) rs1(4) rs2(4) [14 unused bits]
  I-type: opcode(6) rd(4) rs1(4) imm(18, sign-extended)

STR is special: its "rd" field holds the SOURCE register (the value
being stored), and rs1+imm form the address, matching shader_core.v's
DECODE stage.

Branch immediates are resolved relative to the branch instruction's
OWN address (pc + imm), matching EXECUTE using the branch's own pc.
"""

OPCODES = {
    'ADD':0,'SUB':1,'MUL':2,'DIV':3,'MOD':4,'AND':5,'OR':6,'XOR':7,
    'NAND':8,'NOR':9,'XNOR':10,'NOT':11,'SHL':12,'SHR':13,'CMP':14,
    'BEQ':15,'BNE':16,'BGT':17,'BLT':18,'LDR':19,'STR':20,'MOVI':21,'HALT':22,
}
R_TYPE = {'ADD','SUB','MUL','DIV','MOD','AND','OR','XOR','NAND','NOR','XNOR','NOT','SHL','SHR','CMP'}
I_TYPE_LDR_STR = {'LDR','STR'}
I_TYPE_BRANCH  = {'BEQ','BNE','BGT','BLT'}
I_TYPE_MOVI    = {'MOVI'}

def reg(tok):
    tok = tok.strip().upper()
    assert tok.startswith('R'), f"bad register token {tok!r}"
    n = int(tok[1:])
    assert 0 <= n <= 15
    return n

def assemble(lines):
    # pass 1: strip comments/blank lines, record label addresses
    instrs = []   # list of (mnemonic, args, label_or_None)
    labels = {}
    for raw in lines:
        line = raw.split(';', 1)[0].strip()
        if not line:
            continue
        label = None
        if ':' in line and not line.upper().startswith(('BEQ','BNE','BGT','BLT')):
            # allow "LABEL:" alone or "LABEL: INSTR ..."
            maybe_label, _, rest = line.partition(':')
            if ' ' not in maybe_label.strip():
                label = maybe_label.strip()
                line = rest.strip()
        if label:
            labels[label] = len(instrs)
        if not line:
            continue
        parts = line.replace(',', ' ').split()
        mnem = parts[0].upper()
        args = parts[1:]
        instrs.append((mnem, args))

    # pass 2: encode
    words = []
    for addr, (mnem, args) in enumerate(instrs):
        op = OPCODES[mnem]
        if mnem == 'CMP':
            # CMP Ra, Rb -- two operands, no destination: hardware reads
            # rs1/rs2 and latches flags; rd field is unused (0).
            rs1 = reg(args[0])
            rs2 = reg(args[1])
            word = (op << 26) | (0 << 22) | (rs1 << 18) | (rs2 << 14)
        elif mnem in R_TYPE:
            rd = reg(args[0])
            rs1 = reg(args[1]) if len(args) > 1 else 0
            rs2 = reg(args[2]) if len(args) > 2 else 0
            word = (op << 26) | (rd << 22) | (rs1 << 18) | (rs2 << 14)
        elif mnem in I_TYPE_LDR_STR:
            # LDR Rd, [Rs1+imm]   /   STR Rsrc, [Rs1+imm]
            rd = reg(args[0])
            rest = ' '.join(args[1:]).strip('[]')
            rs1_tok, imm_tok = rest.split('+')
            rs1 = reg(rs1_tok)
            imm = int(imm_tok) & 0x3FFFF
            word = (op << 26) | (rd << 22) | (rs1 << 18) | imm
        elif mnem in I_TYPE_BRANCH:
            target = labels[args[0]]
            imm = (target - addr) & 0x3FFFF
            word = (op << 26) | (0 << 22) | (0 << 18) | imm
        elif mnem in I_TYPE_MOVI:
            rd = reg(args[0])
            imm = int(args[1]) & 0x3FFFF
            word = (op << 26) | (rd << 22) | (0 << 18) | imm
        elif mnem == 'HALT':
            word = (op << 26)
        else:
            raise ValueError(f"unknown mnemonic {mnem}")
        words.append(word)
    return words, labels

if __name__ == '__main__':
    import sys
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    prog_file = args[0]
    with open(prog_file) as f:
        lines = f.readlines()
    words, labels = assemble(lines)
    if '--hex' in sys.argv:
        # one 32-bit word per line, for $readmemh
        for w in words:
            print(f"{w:08x}")
    else:
        print(f"// assembled {len(words)} instructions from {prog_file}")
        for addr, w in enumerate(words):
            print(f"    uut.instr_rom[{addr}] = 32'h{w:08x};")