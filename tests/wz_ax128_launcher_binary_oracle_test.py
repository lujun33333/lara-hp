"""AX Pro 1.2.8 launcher UIKit oracle, pinned to the reference Mach-O."""

from __future__ import annotations

import hashlib
import re
import struct
from pathlib import Path

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
from capstone.arm64 import (
    ARM64_GRP_BRANCH_RELATIVE,
    ARM64_GRP_CALL,
    ARM64_GRP_JUMP,
    ARM64_GRP_RET,
    ARM64_OP_IMM,
    ARM64_OP_MEM,
    ARM64_OP_REG,
)


EXPECTED_SHA256 = "cc947605b97b90d898e784bf73dcab120c44c9281299fe840285dd67dfec1fb4"
IMAGE_BASE = 0x100000000
BINARY = Path(__file__).resolve().parents[3] / ".ax128" / "axpro.bin"
METHOD_LIST = 0x100C7FA70
SELREF_LO = 0x100CAFB80
SELREF_HI = 0x100CB1DC0


def offset(va: int) -> int:
    return va - IMAGE_BASE


def u32(va: int) -> int:
    return struct.unpack_from("<I", image, offset(va))[0]


def i32(va: int) -> int:
    return struct.unpack_from("<i", image, offset(va))[0]


def u64(va: int) -> int:
    return struct.unpack_from("<Q", image, offset(va))[0]


def chained_pointer(va: int) -> int:
    return IMAGE_BASE + (u64(va) & 0x7FFFFFFFFFF)


def cstring(va: int) -> str:
    start = offset(va)
    end = image.index(b"\0", start)
    return image[start:end].decode("utf-8")


if not BINARY.is_file():
    raise AssertionError(f"AX 1.2.8 oracle binary is missing: {BINARY}")
image = BINARY.read_bytes()
assert hashlib.sha256(image).hexdigest() == EXPECTED_SHA256

CLASS_NAME_ORACLE = {
    0x100C9C46B: "ZeqcgKhNvh",
    0x100C9C49C: "AXGradientButton",
    0x100C9C4AD: "AXGradientTintView",
    0x100C9C4C0: "BYG6trFgTr5X",
}
for address, expected in CLASS_NAME_ORACLE.items():
    assert cstring(address) == expected, (hex(address), cstring(address), expected)


# All 96 BYG6trFgTr5X relative-method entries. This inventories visual,
# boilerplate and excluded authorization/network methods without executing any
# of the latter.
EXPECTED_METHODS = {
    0x10004EB84: "dealloc",
    0x10004ED30: "supportedInterfaceOrientations",
    0x10004ED38: "shouldAutorotate",
    0x10004ED40: "preferredInterfaceOrientationForPresentation",
    0x10004ED48: "viewDidLoad",
    0x10004F020: "viewDidLayoutSubviews",
    0x10004F964: "jZtCjHXgjK",
    0x100051600: "Wu5ojXWpGE",
    0x1000556B8: "F8At8nNO57",
    0x1000561F0: "dj4kqwFF13:font:color:alignment:",
    0x10005641C: "STsFYTRP1C:",
    0x1000565C8: "JxL6SFWVmy:symbol:style:",
    0x100058038: "qN92rVfL6x",
    0x10005974C: "KOijh8hGA",
    0x10005A19C: "aJ3wS7dK5c",
    0x10005B3EC: "pC9jR4xT7k",
    0x10005D260: "uM5bL8zQ1h",
    0x10005E5A4: "LZtLGMPy5H:expiryLabel:",
    0x10005F3F0: "FRZTFEU4aX:",
    0x10005F718: "imageNamed:inBundle:bundlePath:",
    0x100060374: "HMqZgDf4Ch:",
    0x100060C7C: "FGOcKyS4ul:bundlePath:",
    0x100062C34: "CS8G9nJ9Hw:toAlertAction:",
    0x100062EDC: "MJgmYPNzLc:color:",
    0x100063258: "Jm4sx7LqVa:",
    0x100063410: "bRY49asTQe",
    0x1000636F4: "QCW8npt31S:",
    0x100063AFC: "KIJ6ygFThyT",
    0x100063C54: "OJI8yuahgtY",
    0x100063DAC: "NJhuah6BGhy",
    0x100063F04: "mz1gIslazw",
    0x100064670: "T00A0dxzX8",
    0x100065198: "mRKujWw173",
    0x100065AA8: "FCnImVpBtc:",
    0x1000666F0: "bLIFk2dD80:",
    0x100066FF0: "npv1pDIMNt:",
    0x10006E3BC: "qkn9X7uTCw",
    0x10006EED4: "kOix6taQGE",
    0x10006EFAC: "eJP1CmdS4H",
    0x10006F258: "CLHalR7uaw",
    0x10006FC6C: "s2UwWYlg7c:",
    0x100071770: "lkIayu7hYq",
    0x100071804: "LkVUo5TdVd:",
    0x100072438: "l2kI1ayu7h1Yq:",
    0x10007267C: "Xkji7gyGRa:",
    0x1000727AC: "Jxe33jUAqz:",
    0x100073000: "nxL47otG1i:downloadURL:force:",
    0x100073EE4: "bqXWtaNRXw:",
    0x100074298: "MJABZ38Lmk:completion:",
    0x10007528C: "t3LeCi162e:downloadURL:message:force:",
    0x100077024: "e8ieWkBx3t:",
    0x1000771CC: "cQWq1oAAw4:",
    0x10007739C: "bI1lgDf3mA:completion:",
    0x100077F04: "KLDlfqpygR:",
    0x1000783D8: "eP4YvMzQ8k:",
    0x1000790F4: "hVk72PLs4Q:fallbackCode:",
    0x100079828: "vUM9abQ3Px:error:fallbackCode:",
    0x100079C0C: "VgWeakqNBZ:",
    0x10007CE34: "mxzChJJFGC:",
    0x10007FA60: "oz0qjCkH5I",
    0x10007FA98: "setOz0qjCkH5I:",
    0x10007FB14: "auroraTopLayer",
    0x10007FB4C: "setAuroraTopLayer:",
    0x10007FBC8: "auroraBottomLayer",
    0x10007FC00: "setAuroraBottomLayer:",
    0x10007FC7C: "uUzHdyh2mm",
    0x10007FCB4: "setUUzHdyh2mm:",
    0x10007FD04: "AqXXIHrBtT",
    0x10007FD3C: "setAqXXIHrBtT:",
    0x10007FD74: "NoAAdmo4AF",
    0x10007FDAC: "setNoAAdmo4AF:",
    0x10007FDE4: "titleLabel",
    0x10007FE1C: "setTitleLabel:",
    0x10007FE6C: "WaJZixEd9P",
    0x10007FEA4: "setWaJZixEd9P:",
    0x10007FF20: "p1Ms3IK5oo",
    0x10007FF58: "setP1Ms3IK5oo:",
    0x10007FFA8: "iuJUhQofuQ",
    0x10007FFE0: "setIuJUhQofuQ:",
    0x10008005C: "nP4xK8mQ2v",
    0x100080094: "setNP4xK8mQ2v:",
    0x100080110: "rH7cD3wL9s",
    0x100080148: "setRH7cD3wL9s:",
    0x100080198: "yF6tV2qN8m",
    0x1000801D0: "setYF6tV2qN8m:",
    0x100080208: "aMT63KyNts",
    0x100080240: "setAMT63KyNts:",
    0x1000802BC: "qG0bVNf4Wu",
    0x1000802F4: "setQG0bVNf4Wu:",
    0x100080370: "wgxB9UKd3e",
    0x1000803A8: "setWgxB9UKd3e:",
    0x100080424: "oswm6SlLzO",
    0x10008045C: "setOswm6SlLzO:",
    0x1000804D8: "KTT4uPa9Sv",
    0x100080510: "setKTT4uPa9Sv:",
    0x100080548: ".cxx_destruct",
}

entries_and_flags = u32(METHOD_LIST)
count = u32(METHOD_LIST + 4)
assert entries_and_flags == 0x8000000C
assert count == 96 == len(EXPECTED_METHODS)
actual_methods: dict[int, str] = {}
for index in range(count):
    entry = METHOD_LIST + 8 + index * 12
    name_slot = entry + i32(entry)
    name_address = chained_pointer(name_slot) if SELREF_LO <= name_slot < SELREF_HI else name_slot
    imp = entry + 8 + i32(entry + 8)
    actual_methods[imp] = cstring(name_address)
assert actual_methods == EXPECTED_METHODS
assert "viewDidAppear:" not in actual_methods.values()


md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
md.detail = True


def instructions(start: int, end: int):
    return list(md.disasm(image[offset(start) : offset(end)], start))


def assert_instruction(address: int, mnemonic: str, operand_text: str) -> None:
    decoded = instructions(address, address + 4)
    assert len(decoded) == 1
    assert (decoded[0].mnemonic, decoded[0].op_str) == (mnemonic, operand_text)


# UIFontWeightBlack/Bold/Semibold are imported through __auth_got slots
# +0xc08/+0xc10/+0xc28. The adjacent instructions pin every launcher's font
# size and weight family without guessing a Swift symbolic weight.
FONT_INSTRUCTION_ORACLE = {
    0x100053894: ("ldr", "x8, [x8, #0xc08]"),  # title: black
    0x1000538A4: ("mov", "x8, #0x4046000000000000"),  # title: 44 pt
    0x100053A98: ("ldr", "x8, [x8, #0xc28]"),  # version: semibold
    0x100053AA0: ("fmov", "d0, #13.00000000"),
    0x100054218: ("fmov", "d0, #15.00000000"),  # status body
    0x100054314: ("fmov", "d0, #13.00000000"),  # expiry
    0x100057C74: ("ldr", "x8, [x8, #0xc10]"),  # buttons: bold
    0x100057C84: ("fmov", "d0, #17.00000000"),
    0x100058C68: ("ldr", "x8, [x8, #0xc10]"),  # progress: bold
    0x100058C78: ("fmov", "d0, #13.00000000"),
    0x100059DC8: ("ldr", "x8, [x8, #0xc28]"),  # field: semibold
    0x100059DD8: ("fmov", "d0, #16.00000000"),
    0x10005AD14: ("ldr", "x8, [x8, #0xc10]"),  # support title: bold
    0x10005AD24: ("fmov", "d0, #12.00000000"),
    0x10005EE98: ("ldr", "x8, [x8, #0xc10]"),  # status title: bold
    0x10005EEA8: ("fmov", "d0, #12.00000000"),
}
for address, expected in FONT_INSTRUCTION_ORACLE.items():
    assert_instruction(address, *expected)


def references_selref(start: int, end: int, selref: int) -> bool:
    pages: dict[int, int] = {}
    for insn in instructions(start, end):
        operands = insn.operands
        if insn.mnemonic == "adrp":
            pages[operands[0].reg] = operands[1].imm
        elif (
            insn.mnemonic == "ldr"
            and len(operands) >= 2
            and operands[1].type == ARM64_OP_MEM
            and operands[1].mem.base in pages
        ):
            if pages[operands[1].mem.base] + operands[1].mem.disp == selref:
                return True
    return False


# AX performs launcher construction and initial support-state publication from
# viewDidLoad. There is no viewDidAppear entry in the 96-method table.
for selref in (0x100CB03C8, 0x100CB03D0, 0x100CB03D8):
    assert references_selref(0x10004ED48, 0x10004F020, selref), hex(selref)


# KOijh8hGA configures the text field with the default non-secure/default
# keyboard state. It never installs the three excluded setters/delegate hooks.
FIELD_START, FIELD_END = 0x10005974C, 0x10005A19C
assert references_selref(FIELD_START, FIELD_END, 0x100CB0738)  # setPlaceholder:
assert references_selref(FIELD_START, FIELD_END, 0x100CB0770)  # setAttributedPlaceholder:
assert not references_selref(FIELD_START, FIELD_END, 0x100CB1C78)  # setSecureTextEntry:


class VisualStringDecoder:
    """Concrete evaluator for AX's straight-line byte/UTF-16 decode blocks."""

    def __init__(self) -> None:
        self.regs: dict[str, int] = {}
        self.memory: dict[int, int] = {}

    @staticmethod
    def _key(insn, register: int) -> str:
        name = insn.reg_name(register)
        match = re.fullmatch(r"[wx](\d+)", name or "")
        return match.group(1) if match else name

    def _get(self, insn, register: int) -> int | None:
        return self.regs.get(self._key(insn, register))

    def _put(self, insn, register: int, value: int) -> None:
        name = insn.reg_name(register)
        mask = 0xFFFFFFFF if name.startswith("w") else 0xFFFFFFFFFFFFFFFF
        self.regs[self._key(insn, register)] = value & mask

    def _load(self, address: int, size: int) -> int:
        if all(address + index in self.memory for index in range(size)):
            return sum(self.memory[address + index] << (index * 8) for index in range(size))
        if not IMAGE_BASE <= address < IMAGE_BASE + len(image):
            raise ValueError("unmapped read")
        return int.from_bytes(image[offset(address) : offset(address) + size], "little")

    def _store(self, address: int, value: int, size: int) -> None:
        for index in range(size):
            self.memory[address + index] = (value >> (index * 8)) & 0xFF

    def run(self, start: int, end: int) -> None:
        for insn in instructions(start, end):
            operands = insn.operands
            mnemonic = insn.mnemonic
            try:
                if mnemonic == "adrp":
                    self._put(insn, operands[0].reg, operands[1].imm)
                elif mnemonic == "mov":
                    value = (
                        operands[1].imm
                        if operands[1].type == ARM64_OP_IMM
                        else self._get(insn, operands[1].reg)
                    )
                    if value is None:
                        raise ValueError("unknown mov source")
                    self._put(insn, operands[0].reg, value)
                elif mnemonic == "movk":
                    old = self._get(insn, operands[0].reg) or 0
                    shift = operands[2].shift.value if len(operands) > 2 else 0
                    self._put(
                        insn,
                        operands[0].reg,
                        (old & ~(0xFFFF << shift)) | ((operands[1].imm & 0xFFFF) << shift),
                    )
                elif mnemonic in ("add", "sub"):
                    left = self._get(insn, operands[1].reg)
                    right = (
                        operands[2].imm
                        if operands[2].type == ARM64_OP_IMM
                        else self._get(insn, operands[2].reg)
                    )
                    if left is None or right is None:
                        raise ValueError("unknown arithmetic source")
                    if operands[2].shift and operands[2].shift.type:
                        right <<= operands[2].shift.value
                    self._put(
                        insn,
                        operands[0].reg,
                        left + right if mnemonic == "add" else left - right,
                    )
                elif mnemonic in ("ldrb", "ldrh", "ldr", "ldurb", "ldurh", "ldur"):
                    memory = operands[1].mem
                    address = self._get(insn, memory.base)
                    if address is None:
                        raise ValueError("unknown load base")
                    if memory.index:
                        index = self._get(insn, memory.index)
                        if index is None:
                            raise ValueError("unknown load index")
                        address += index
                    address += memory.disp
                    name = insn.reg_name(operands[0].reg)
                    size = (
                        1
                        if mnemonic in ("ldrb", "ldurb")
                        else 2
                        if mnemonic in ("ldrh", "ldurh")
                        else 8
                        if name.startswith("x")
                        else 4
                    )
                    self._put(insn, operands[0].reg, self._load(address, size))
                elif mnemonic in ("strb", "strh", "str", "sturb", "sturh", "stur"):
                    address = self._get(insn, operands[1].mem.base)
                    value = self._get(insn, operands[0].reg)
                    if address is None or value is None:
                        raise ValueError("unknown store operand")
                    address += operands[1].mem.disp
                    name = insn.reg_name(operands[0].reg)
                    size = (
                        1
                        if mnemonic in ("strb", "sturb")
                        else 2
                        if mnemonic in ("strh", "sturh")
                        else 8
                        if name.startswith("x")
                        else 4
                    )
                    self._store(address, value, size)
                elif mnemonic in ("eor", "and", "orr", "orn", "bic"):
                    left = self._get(insn, operands[1].reg)
                    right = (
                        operands[2].imm
                        if operands[2].type == ARM64_OP_IMM
                        else self._get(insn, operands[2].reg)
                    )
                    if left is None or right is None:
                        raise ValueError("unknown bitwise source")
                    value = {
                        "eor": left ^ right,
                        "and": left & right,
                        "orr": left | right,
                        "orn": left | ~right,
                        "bic": left & ~right,
                    }[mnemonic]
                    self._put(insn, operands[0].reg, value)
                elif mnemonic == "mvn":
                    value = self._get(insn, operands[1].reg)
                    if value is None:
                        raise ValueError("unknown mvn source")
                    self._put(insn, operands[0].reg, ~value)
                elif mnemonic in ("lsl", "lsr"):
                    value = self._get(insn, operands[1].reg)
                    if value is None:
                        raise ValueError("unknown shift source")
                    shift = operands[2].imm
                    self._put(
                        insn,
                        operands[0].reg,
                        value << shift if mnemonic == "lsl" else value >> shift,
                    )
                elif mnemonic == "bfxil":
                    destination = self._get(insn, operands[0].reg) or 0
                    source = self._get(insn, operands[1].reg)
                    if source is None:
                        raise ValueError("unknown bfxil source")
                    shift, width = operands[2].imm, operands[3].imm
                    mask = (1 << width) - 1
                    self._put(
                        insn,
                        operands[0].reg,
                        (destination & ~(mask << shift)) | ((source & mask) << shift),
                    )
            except (IndexError, TypeError, ValueError):
                if operands and operands[0].type == ARM64_OP_REG:
                    self.regs.pop(self._key(insn, operands[0].reg), None)

            if (
                insn.group(ARM64_GRP_JUMP)
                or insn.group(ARM64_GRP_CALL)
                or insn.group(ARM64_GRP_RET)
                or insn.group(ARM64_GRP_BRANCH_RELATIVE)
            ):
                self.regs.clear()

    def cfstring(self, object_address: int) -> str:
        flags = u64(object_address + 8)
        characters = IMAGE_BASE + (u64(object_address + 16) & 0x7FFFFFFFFFF)
        length = u64(object_address + 24)
        utf16 = bool(flags & 0x10)
        byte_count = length * (2 if utf16 else 1)
        encoded = bytes(
            self.memory.get(characters + index, image[offset(characters + index)])
            for index in range(byte_count)
        )
        return encoded.decode("utf-16le" if utf16 else "utf-8")


decoder = VisualStringDecoder()
decoder.run(0x10004F964, 0x10006EED4)
STRING_ORACLE = {
    0x100CC65D0: "screen",
    0x100CC66A0: "AX Pro",
    0x100CC66C0: "卡密激活",
    0x100CC66E0: "checkmark.seal.fill",
    0x100CC6700: "启动应用",
    0x100CC6720: "play.fill",
    0x100CC6740: "1.2.8",
    0x100CC6760: "VERSION %@",
    0x100CC6790: "0%",
    0x100CC67D0: "请输入卡密",
    0x100CC6850: "设备与系统支持",
    0x100CC6870: "正在检查当前环境…",
    0x100CC6D80: "! 当前环境待测试",
    0x100CC6DA0: "✓ 当前环境支持",
    0x100CC6DC0: "✕ 当前环境不受支持",
    0x100CC6DE0: "%@ · iOS %@",
    0x100CC6E00: "%@\n%@\n当前系统尚未完成实机验证，请谨慎继续",
    0x100CC6E20: "%@\n%@\n验证与启动功能已停用",
    0x100CC6E40: "%@\n%@",
    0x100CC6E80: "当前状态",
    0x100CC9080: "opacity",
    0x100CC90A0: "twinkle",
}
for object_address, expected in STRING_ORACLE.items():
    assert decoder.cfstring(object_address) == expected, hex(object_address)


# Exact float constants loaded by the visual entry points.
DOUBLE_ORACLE = {
    0x100C81268: 0.80,
    0x100C81270: 0.82,
    0x100C81278: 0.86,
    0x100C81280: 0.90,
    0x100C81288: 0.05,
    0x100C81290: 0.016,
    0x100C81298: 0.018,
    0x100C812A0: 0.04,
    0x100C812A8: -0.30,
    0x100C812B0: 0.85,
    0x100C812B8: -0.35,
    0x100C812C0: 0.62,
    0x100C812C8: 1.70,
    0x100C812D0: 0.042,
    0x100C812D8: 0.058,
    0x100C812E0: 0.052,
    0x100C812E8: 0.02,
    0x100C812F0: 0.048,
    0x100C812F8: 0.58,
    0x100C81300: 0.46,
    0x100C81308: 0.34,
    0x100C81310: 0.98,
    0x100C81318: 0.20,
    0x100C81320: 0.30,
    0x100C81328: 0.24,
    0x100C81330: 0.78,
    0x100C81338: 0.06,
    0x100C81340: 0.55,
    0x100C81348: 0.15,
    0x100C81350: 0.22,
    0x100C81358: 0.08,
    0x100C81360: 0.40,
    0x100C81368: 0.95,
    0x100C81370: 0.16,
    0x100C81378: 0.10,
    0x100C81380: 0.97,
    0x100C81388: 0.60,
    0x100C81390: 1.60,
    0x100C81398: 0.36,
    0x100C813A0: 0.89,
    0x100C813A8: 0.66,
    0x100C813B0: 0.61,
    0x100C813B8: 0.44,
    0x100C813C0: 0.53,
    0x100C813C8: 0.74,
    0x100C813D0: 0.76,
    0x100C813D8: 0.055,
    0x100C813E0: 0.115,
    0x100C813E8: 0.88,
    0x100C813F0: 0.14,
    0x100C813F8: 0.105,
    0x100C81400: 0.81,
    0x100C81408: 0.94,
    0x100C81410: 0.42,
    0x100C81418: 0.70,
    0x100C81420: 0.26,
    0x100C81428: 0.075,
    0x100C81430: 0.32,
    0x100C81438: 0.45,
    0x100C81440: 0.37,
    0x100C81448: 0.48,
    0x100C81450: 0.99,
    0x100C81458: 0.72,
    0x100C81460: 0.38,
    0x100C81468: 0.93,
    0x100C81470: 0.088,
    0x100C81478: 0.52,
    0x100C81480: 0.07,
    0x100C81488: 0.56,
    0x100C81490: 0.84,
    0x100C81498: 0.28,
    0x100C814A0: 0.65,
    0x100C814A8: 0.96,
    0x100C814B0: 2.40,
}
for address, expected in DOUBLE_ORACLE.items():
    actual = struct.unpack_from("<d", image, offset(address))[0]
    assert actual == expected, (hex(address), actual, expected)

assert struct.unpack_from("<f", image, offset(0x100C814F4))[0] == struct.unpack("<f", struct.pack("<f", 0.26))[0]

print(
    "PASS: AX 1.2.8 BYG6trFgTr5X 96-method map, visual strings, "
    "text-field defaults and UIKit constants"
)
