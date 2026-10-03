#!/usr/bin/env python3
"""校验构建产物：Mach-O 魔数 / cpusubtype / 是否存在 LC_CODE_SIGNATURE。

为什么要有这个脚本：CI 直接把 .app 打成 ipa，若签名步骤意外生效会产出
fakesigned 包，安装到越狱设备上会被 amfid 直接拒绝，而失败现象只是
「装不上」，从 ipa 外表完全看不出来。所以每次交付前都要机械地核一遍。
"""
import struct
import sys

LC_CODE_SIGNATURE = 0x1D


def check(path: str) -> int:
    with open(path, "rb") as f:
        data = f.read()

    magic = struct.unpack_from("<I", data, 0)[0]
    # MH_MAGIC_64 = 0xFEEDFACF；字节序反过来（大端）也算合法 Mach-O
    if magic != 0xFEEDFACF:
        print(f"magic      : 0x{magic:08X}  <-- 不是 64 位小端 Mach-O")
        return 1

    cputype, cpusubtype, _ft, ncmds, _szcmds, _flags = struct.unpack_from("<iiIIII", data, 4)
    # CPU_TYPE_ARM64 = 0x0100000C；cpusubtype 2 = arm64e，0 = arm64
    print(f"magic      : 0x{magic:08X} (MH_MAGIC_64)")
    print(f"cputype    : 0x{cputype:08X} (期望 0x0100000C = ARM64)")
    print(f"cpusubtype : {cpusubtype & 0x00FFFFFF} (期望 2 = arm64e)")

    off = 32
    found = False
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmdsize == 0:
            print("命令尺寸为 0，文件结构异常")
            return 1
        if cmd == LC_CODE_SIGNATURE:
            found = True
        off += cmdsize

    print(f"LC_CODE_SIGNATURE : {'存在 <-- 不该有' if found else '无 (未签名，符合预期)'}")

    ok = (
        cputype == 0x0100000C
        and (cpusubtype & 0x00FFFFFF) == 2
        and not found
    )
    print("结论       :", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(check(sys.argv[1]))
