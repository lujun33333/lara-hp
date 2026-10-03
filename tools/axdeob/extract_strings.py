"""AX Pro 内联字符串解码器提取器

AX 把字符串以「逐字节内联仿射变换」编译进 __text：每字节一条
ldrb / 变换链 / strb 序列。本脚本线性仿真还原明文。
判据：输出必须是可打印 ASCII。读前未写的寄存器用 256 值穷举取最优。
"""
import lief, sys, re, itertools
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
from capstone.arm64 import (ARM64_OP_IMM, ARM64_OP_MEM,
                            ARM64_GRP_JUMP, ARM64_GRP_CALL, ARM64_GRP_RET,
                            ARM64_GRP_BRANCH_RELATIVE)

sys.stdout.reconfigure(encoding='utf-8', errors='replace')
BIN = r"C:\Users\lp\AppData\Local\Temp\axpro\axpro.bin"
b = lief.MachO.parse(BIN).at(0)
raw = open(BIN, "rb").read()
ranges = [(s.virtual_address, s.virtual_address + s.size, s.offset, s.name)
          for s in b.sections if s.size and s.offset]

def foff(va):
    for lo, hi, off, n in ranges:
        if lo <= va < hi: return off + (va - lo)
    return None

def sect_of(va):
    for lo, hi, off, n in ranges:
        if lo <= va < hi: return n
    return None

md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.detail = True
TEXT = [s for s in b.sections if s.name == '__text'][0]
allins = list(md.disasm(raw[TEXT.offset:TEXT.offset + TEXT.size], TEXT.virtual_address))
print(f"__text: {TEXT.size} 字节, {len(allins)} 条指令")

RN = re.compile(r'([wx])(\d+)')
def regnum(ins, cid):
    n = ins.reg_name(cid)
    m = RN.fullmatch(n) if n else None
    return int(m.group(2)) if m else None

CF = {i.address for i in allins
      if i.group(ARM64_GRP_JUMP) or i.group(ARM64_GRP_CALL)
      or i.group(ARM64_GRP_RET) or i.group(ARM64_GRP_BRANCH_RELATIVE)}

def emulate(start, init=None, max_ins=220):
    R = dict(init or {})
    touched = set()
    mem, order, unknown, first_mem = {}, [], set(), None
    for k in range(start, min(start + max_ins, len(allins))):
        ins = allins[k]
        if ins.address in CF and k > start:
            break
        m, ops = ins.mnemonic, ins.operands
        def g(cid):
            n = regnum(ins, cid)
            if n is None: return 0
            if n not in R: unknown.add(n)
            return R.get(n, 0)
        def s(cid, v):
            n = regnum(ins, cid)
            if n is None: return
            wide = ins.reg_name(cid).startswith('x')
            R[n] = (v & 0xFFFFFFFFFFFFFFFF) if wide else (v & 0xFFFFFFFF)
            touched.add(n); unknown.discard(n); 
        try:
            if m == "adrp": s(ops[0].reg, ops[1].imm)
            elif m == "add" and len(ops) == 3 and ops[2].type == ARM64_OP_IMM: s(ops[0].reg, g(ops[1].reg) + ops[2].imm)
            elif m == "add" and len(ops) == 3 and ops[2].shift and ops[2].shift.type != 0: s(ops[0].reg, g(ops[1].reg) + (g(ops[2].reg) << ops[2].shift.value))
            elif m == "add" and len(ops) == 3: s(ops[0].reg, g(ops[1].reg) + g(ops[2].reg))
            elif m == "sub" and len(ops) == 3 and ops[2].shift and ops[2].shift.type != 0: s(ops[0].reg, g(ops[1].reg) - (g(ops[2].reg) << ops[2].shift.value))
            elif m == "sub" and ops[2].type == ARM64_OP_IMM: s(ops[0].reg, g(ops[1].reg) - ops[2].imm)
            elif m == "sub": s(ops[0].reg, g(ops[1].reg) - g(ops[2].reg))
            elif m == "mov" and ops[1].type == ARM64_OP_IMM: s(ops[0].reg, ops[1].imm)
            elif m == "ldrb" and ops[1].type == ARM64_OP_MEM:
                a = g(ops[1].mem.base) + ops[1].mem.disp
                v = mem.get(a)
                if v is None:
                    fo = foff(a); v = raw[fo] if fo is not None else 0
                s(ops[0].reg, v)
            elif m == "strb" and ops[1].type == ARM64_OP_MEM:
                a = g(ops[1].mem.base) + ops[1].mem.disp
                if first_mem is None: first_mem = a
                if a not in mem: order.append(a)
                mem[a] = g(ops[0].reg) & 0xFF
            elif m == "eor" and ops[2].type == ARM64_OP_IMM: s(ops[0].reg, g(ops[1].reg) ^ (ops[2].imm & 0xFFFFFFFF))
            elif m == "eor": s(ops[0].reg, g(ops[1].reg) ^ g(ops[2].reg))
            elif m == "and" and ops[2].type == ARM64_OP_IMM: s(ops[0].reg, g(ops[1].reg) & (ops[2].imm & 0xFFFFFFFF))
            elif m == "and": s(ops[0].reg, g(ops[1].reg) & g(ops[2].reg))
            elif m == "orr" and ops[2].type == ARM64_OP_IMM: s(ops[0].reg, g(ops[1].reg) | (ops[2].imm & 0xFFFFFFFF))
            elif m == "orr": s(ops[0].reg, g(ops[1].reg) | g(ops[2].reg))
            elif m == "orn": s(ops[0].reg, g(ops[1].reg) | (~g(ops[2].reg) & 0xFFFFFFFF))
            elif m == "bic" and ops[2].type == ARM64_OP_IMM: s(ops[0].reg, g(ops[1].reg) & ~(ops[2].imm & 0xFFFFFFFF))
            elif m == "bic": s(ops[0].reg, g(ops[1].reg) & ~g(ops[2].reg))
            elif m == "mvn": s(ops[0].reg, ~g(ops[1].reg))
            elif m == "lsl" and ops[2].type == ARM64_OP_IMM: s(ops[0].reg, g(ops[1].reg) << ops[2].imm)
            elif m == "lsr" and ops[2].type == ARM64_OP_IMM: s(ops[0].reg, g(ops[1].reg) >> ops[2].imm)
        except Exception:
            pass
    return order, mem, unknown

def score(bs):
    n = 0
    for c in bs:
        if c == 0: continue
        n += 1 if 0x20 <= c < 0x7F else -6
    return n

# 找解码块起点：adrp + add 载入 __data 指针，紧跟 ldrb
starts = []
for k in range(len(allins) - 3):
    a0, a1, a2 = allins[k], allins[k + 1], allins[k + 2]
    if a0.mnemonic == "adrp" and a1.mnemonic == "add" and a2.mnemonic == "ldrb" \
       and a1.operands[0].reg == a0.operands[0].reg and a1.operands[2].type == ARM64_OP_IMM:
        ptr = a0.operands[1].imm + a1.operands[2].imm
        if sect_of(ptr): starts.append((k, ptr))
print(f"候选解码起点: {len(starts)}", flush=True)
OUT = open("ax_strings2.txt", "w", encoding="utf-8")

found = {}
for k, ptr in starts:
    order, mem, unknown = emulate(k)
    if len(order) < 4: continue
    if order != list(range(order[0], order[0] + len(order))): continue
    regs = sorted(unknown)
    if len(regs) == 0:
        bs = bytes(mem[a] for a in order)
    elif len(regs) <= 2:
        best, bestsc = None, -10 ** 9
        cand = [0, 0xc2, 0xc6, 0xd2, 0xd6, 0xbd, 0xbf, 0xc0]
        pool = [range(256) if i == 0 else cand for i in range(len(regs))]
        combos = itertools.product(*pool)
        for combo in combos:
            _, mem2, _ = emulate(k, dict(zip(regs, combo)))
            b2 = bytes(mem2.get(a, 0) for a in order)
            sc = score(b2)
            if sc > bestsc: bestsc, best = sc, b2
        bs = best
    else:
        continue
    if bs is None: continue
    tb = bs.split(b'\x00')[0]
    if len(tb) < 4: continue
    try: dec = tb.decode('utf-8')
    except Exception: continue
    pr = sum(1 for ch in dec if 0x20 <= ord(ch) < 0x7f) / max(len(dec), 1)
    if pr < 0.80: continue
    if order[0] in found and found[order[0]][0] == dec: continue
    found[order[0]] = (dec, ptr, len(bs), regs)
    line = f"  {order[0]:#x} <- src {ptr:#x} {len(bs):3d}B unk={regs}  {dec!r}"
    print(line, flush=True)
    OUT.write(line + "\n"); OUT.flush()

print(f"\n共还原 {len(found)} 个字符串")
