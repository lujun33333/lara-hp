import lief
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
from capstone.arm64 import ARM64_OP_IMM, ARM64_OP_MEM, ARM64_OP_REG

BIN = r"C:\Users\lp\AppData\Local\Temp\axpro\axpro.bin"
b = lief.MachO.parse(BIN).at(0)
raw = open(BIN, "rb").read()

ranges = [(s.virtual_address, s.virtual_address+s.size, s.offset, s.name)
          for s in b.sections if s.size and s.offset]
def foff(va):
    for lo,hi,off,n in ranges:
        if lo <= va < hi: return off+(va-lo)
    return None
def rd8(va):
    fo = foff(va)
    return raw[fo] if fo is not None else None

md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.detail = True

LO, HI = 0x100006038, 0x100006260
o = foff(LO)
insns = list(md.disasm(raw[o:o+(HI-LO)], LO))

R = {}                       # 完整 64 位寄存器
def is32(i): return md.reg_name(i).startswith('w')
def g(i): return R.get(i, 0)
def s(i, v):
    R[i] = (v & 0xFFFFFFFF) if is32(i) else (v & 0xFFFFFFFFFFFFFFFF)

mem = {}
missing = set()
trace = []

for ins in insns:
    m, ops = ins.mnemonic, ins.operands
    try:
        if m == "adrp":
            s(ops[0].reg, ops[1].imm)
        elif m == "add" and len(ops) == 3 and ops[2].type == ARM64_OP_IMM:
            s(ops[0].reg, g(ops[1].reg) + ops[2].imm)
        elif m == "add" and len(ops) == 3 and ops[2].shift.type != 0:
            s(ops[0].reg, g(ops[1].reg) + (g(ops[2].reg) << ops[2].shift.value))
        elif m == "sub" and len(ops) == 3 and ops[2].shift.type != 0:
            s(ops[0].reg, g(ops[1].reg) - (g(ops[2].reg) << ops[2].shift.value))
        elif m == "mov" and len(ops) == 2 and ops[1].type == ARM64_OP_IMM:
            s(ops[0].reg, ops[1].imm)
        elif m == "ldrb" and ops[1].type == ARM64_OP_MEM:
            a = g(ops[1].mem.base) + ops[1].mem.disp
            v = rd8(a)
            if v is None: missing.add(a)
            s(ops[0].reg, v if v is not None else 0)
        elif m == "strb" and ops[1].type == ARM64_OP_MEM:
            a = g(ops[1].mem.base) + ops[1].mem.disp
            mem[a] = g(ops[0].reg) & 0xFF
            trace.append((ins.address, a, mem[a]))
        elif m == "eor" and ops[2].type == ARM64_OP_IMM:
            s(ops[0].reg, g(ops[1].reg) ^ ops[2].imm)
        elif m == "eor":
            s(ops[0].reg, g(ops[1].reg) ^ g(ops[2].reg))
        elif m == "and" and ops[2].type == ARM64_OP_IMM:
            s(ops[0].reg, g(ops[1].reg) & ops[2].imm)
        elif m == "and":
            s(ops[0].reg, g(ops[1].reg) & g(ops[2].reg))
        elif m == "orr" and ops[2].type == ARM64_OP_IMM:
            s(ops[0].reg, g(ops[1].reg) | ops[2].imm)
        elif m == "orr":
            s(ops[0].reg, g(ops[1].reg) | g(ops[2].reg))
        elif m == "bic" and ops[2].type == ARM64_OP_IMM:
            s(ops[0].reg, g(ops[1].reg) & ~ops[2].imm)
        elif m == "bic":
            s(ops[0].reg, g(ops[1].reg) & ~g(ops[2].reg))
        elif m == "sub" and ops[2].type == ARM64_OP_IMM:
            s(ops[0].reg, g(ops[1].reg) - ops[2].imm)
        elif m == "sub":
            s(ops[0].reg, g(ops[1].reg) - g(ops[2].reg))
        elif m == "lsl" and ops[2].type == ARM64_OP_IMM:
            s(ops[0].reg, g(ops[1].reg) << ops[2].imm)
        elif m == "lsr" and ops[2].type == ARM64_OP_IMM:
            s(ops[0].reg, g(ops[1].reg) >> ops[2].imm)
        elif m == "mvn":
            s(ops[0].reg, ~g(ops[1].reg))
        elif m == "add" and ops[2].type == ARM64_OP_IMM:
            s(ops[0].reg, g(ops[1].reg) + ops[2].imm)
    except Exception:
        pass

print(f"反汇编 {len(insns)} 条；strb 共 {len(trace)} 次；缺地址 {sorted(hex(x) for x in missing)}")

print("\n=== 解码结果（按目标区）===")
groups = {}
for a in sorted(mem):
    groups.setdefault(a & ~0x3F, []).append(a)
for base, addrs in sorted(groups.items()):
    if addrs != list(range(addrs[0], addrs[-1]+1)):
        continue
    bs = bytes(mem[a] for a in addrs)
    txt = bs.split(b'\x00')[0]
    print(f"  {base:#x} ({len(bs)}B): {bs.hex(' ')}")
    print(f"        ascii: {txt.decode('ascii', 'replace')!r}")
