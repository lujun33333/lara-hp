e1 = 0x100ddc7c003
mask14 = 0x0000FFFFFFFFC000   # 我的 g_pr_pte_addr (16KB)
mask12 = 0x0000FFFFFFFFF000   # XNU ARM_TTE_TABLE_MASK
gPhysBase = 0x10004300000
gVirtBase = 0xfffffff01c300000
gPhysSize = 0x1dc544000
log_t2 = 0xfffffff0f5c7c000

for name, m in (("mine C000", mask14), ("xnu  F000", mask12)):
    pa = e1 & m
    kv = gVirtBase + (pa - gPhysBase)
    tag = "== log t2" if kv == log_t2 else "!= log t2 (xor 0x%x)" % (kv ^ log_t2)
    print("%s: pa=0x%x kv=0x%x  %s" % (name, pa, kv, tag))

print()
print("e1 & 0x3      =", hex(e1 & 3), "  (0x3 = ARM_TTE_TYPE_TABLE|VALID)")
print("e1 & 0x3000   =", hex(e1 & 0x3000), "  (两掩码的差异位)")
print("e1 & ~0x3     = 0x%x" % (e1 & ~0x3))
print("PA in RAM     =", gPhysBase <= (e1 & mask14) < gPhysBase + gPhysSize)

# 反推：若 t2 是日志那个值，对应的 pa 和 e1 该是什么
pa_from_t2 = log_t2 - gVirtBase + gPhysBase
print()
print("由日志 t2 反推 pa = 0x%x" % pa_from_t2)
print("该 pa 与 e1&mask 相差 = 0x%x" % (pa_from_t2 ^ (e1 & mask14)))
print("该 pa 是否 16KB 对齐 :", (pa_from_t2 & 0x3FFF) == 0)

# 假设 e1 其实是 12 位十六进制（我可能少数了一位）
for cand in (0x100ddc7c0003, 0x100ddc7c003):
    print()
    print("候选 e1 = 0x%x" % cand)
    print("  &0x3 =", hex(cand & 3))
    pa = cand & mask14
    kv = gVirtBase + (pa - gPhysBase)
    print("  pa=0x%x kv=0x%x %s" % (pa, kv, "== log t2" if kv == log_t2 else "!= log t2"))
