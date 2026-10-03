"""Bind collector constants to the immutable AX 1.2.8 Mach-O oracle."""

from __future__ import annotations

import hashlib
import os
import struct
from pathlib import Path


EXPECTED_SHA256 = (
    "cc947605b97b90d898e784bf73dcab120c44c9281299fe840285dd67dfec1fb4"
)
IMAGE_BASE = 0x100000000


def find_binary() -> Path:
    candidates = []
    if os.environ.get("AX128_BINARY"):
        candidates.append(Path(os.environ["AX128_BINARY"]))
    candidates.extend(
        [
            Path(__file__).resolve().parents[3] / ".ax128" / "axpro.bin",
            Path(os.environ.get("LOCALAPPDATA", ""))
            / "Temp" / "axpro" / "axpro.bin",
        ]
    )
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise AssertionError("AX 1.2.8 axpro.bin oracle not found")


binary_path = find_binary()
image = binary_path.read_bytes()
assert hashlib.sha256(image).hexdigest() == EXPECTED_SHA256


def instruction(address: int) -> int:
    offset = address - IMAGE_BASE
    assert 0 <= offset <= len(image) - 4
    return int.from_bytes(image[offset : offset + 4], "little")


def branch_target(address: int) -> int:
    word = instruction(address)
    assert word & 0xFC000000 == 0x94000000
    immediate = word & 0x03FFFFFF
    if immediate & 0x02000000:
        immediate -= 0x04000000
    return address + immediate * 4


def qword(address: int) -> int:
    offset = address - IMAGE_BASE
    assert 0 <= offset <= len(image) - 8
    return int.from_bytes(image[offset : offset + 8], "little")


def double(address: int) -> float:
    offset = address - IMAGE_BASE
    return struct.unpack_from("<d", image, offset)[0]


def float32(address: int) -> float:
    offset = address - IMAGE_BASE
    return struct.unpack_from("<f", image, offset)[0]


def decoded_chain(addresses: tuple[int, ...], masks: tuple[int, ...]) -> tuple[int, ...]:
    assert len(addresses) == len(masks)
    return tuple(qword(address) ^ mask for address, mask in zip(addresses, masks))


def chained_code_target(address: int) -> int:
    return IMAGE_BASE + (qword(address) & 0xFFFFFFFF)


# Runtime-decoded field paths.  Each tuple is recovered from the immutable
# qwords at the listed data VAs and the decode instructions at the code VAs in
# the comment.  This keeps the oracle independent from the C++ source offsets.
# Matrix: decoder 0x1008055d4..0x100805650; consumer 0x10080575c..0x100805868.
assert decoded_chain(
    tuple(0x100F3B820 + index * 8 for index in range(4)),
    (
        0x1D5890B29C464182,
        0xA945876E9D56E5CA,
        0x4B4D5B1C712F9F9B,
        0x3773EC96AB7C45A3,
    ),
) == (0xB8, 0, 8, 0x128)

# Hero table and summoner-skill paths: decoders 0x10080a33c..0x10080a480.
assert decoded_chain(
    (0x100F3BA58, 0x100F3BA60),
    (0xE54C56C6F0994F32, 0x3E02F0E97C024600),
) == (0x138, 0x78)
assert decoded_chain(
    (0x100F3B9E0, 0x100F3B9E8, 0x100F3B9F0),
    (0xADD2F2354C141E6A, 0xDDDDC2B04E872510, 0xD9BFE9B266B74536),
) == (0x280, 0x68, 0x34)  # camp == 1
assert decoded_chain(
    (0x100F3BA20, 0x100F3BA28, 0x100F3BA30),
    (0x1B17DBCC5F9C91D3, 0xE8C5BB22E11FE256, 0x41E6EF4D66D77DD9),
) == (0x280, 0x68, 0x14)  # camp != 1

# Hero coordinate, HP and recall: decoders 0x10080b2f0..0x10080b3b8 and
# 0x100807de4..0x100807eb8; consumers 0x10080b3dc..0x10080b48c and
# 0x100808560..0x1008088f4.
assert decoded_chain(
    tuple(0x100F3BAC0 + index * 8 for index in range(5)),
    (
        0x36AFA985B5B57928,
        0x3490DF34431AB81E,
        0x43565418464AF5FD,
        0x66B798A08384B6D1,
        0xA2457AF0833AA323,
    ),
) == (0x268, 0x10, 0, 0x60, 0)
assert decoded_chain(
    (0x100F3B900, 0x100F3B908),
    (0xBD4255FFCEC4DD4F, 0x5F5B51BCBE533044),
) == (0x1A0, 0x168)
assert decoded_chain(
    tuple(0x100F3B920 + index * 8 for index in range(4)),
    (
        0x61B70D393AF40934,
        0x9647E5B891EBFD69,
        0xAF3905612BD369AB,
        0xFD16418C02FFEEF4,
    ),
) == (0x170, 0x168, 0x168, 0x20)

# Soldier table/HP/position: decoder 0x10080b9e4..0x10080bac8; the production
# gate at 0x10080bd6c publishes only current HP > 0.
assert decoded_chain(
    (0x100F3BB58, 0x100F3BB60),
    (0x63EB39A95C3CEC61, 0x76BE43E3205EADE9),
) == (0x138, 0x120)
assert decoded_chain(
    (0x100F3BB78, 0x100F3BB80),
    (0xFC6613D36C571E1E, 0x88373DF345C02340),
) == (0x1A0, 0x168)
assert decoded_chain(
    (0x100F3BB20, 0x100F3BB28, 0x100F3BB30),
    (0x9F21E7A6CF214E75, 0x16BA541DFC20BBE9, 0x838C0E30B26CEBA8),
) == (0x250, 0x60, 0)

# Monster root/table: decoder 0x10080c85c..0x10080c8d8; consumer starts at
# 0x10080c9f4.  Slot/coordinate/timer behavior is asserted below.
assert decoded_chain(
    tuple(0x100F3BBA0 + index * 8 for index in range(4)),
    (
        0xD6B208A3D4CB7FA5,
        0x5933AA1668E6F881,
        0x2979C2CC0C0E29BF,
        0x5B830E53F042791C,
    ),
) == (0x127E3240, 0x3B8, 0x88, 0x140)

# Auxiliary page and host-position paths: decoders 0x100810978..0x100810a38
# and 0x100807ebc..0x100807f74; consumers 0x100810cd0/0x1008124fc.
assert decoded_chain(
    (0x100F3BD20, 0x100F3BD28, 0x100F3BD30,
     0x100F3BD38, 0x100F3BD40, 0x100F3BD48),
    (
        0x48A2A818080624CA,
        0x33F04AEEFFCBADDC,
        0x35DD5A7242E7E96D,
        0x3230993F9EB6301C,
        0x3E8C90A91245B3CE,
        0x433BCB0D89259B99,
    ),
) == (0xB0, 8, 0x1A0, 8, 0x30, 0x750)
assert decoded_chain(
    tuple(0x100F3B8A0 + index * 8 for index in range(6)),
    (
        0x303728EB57DD0D90,
        0x01811E9830374090,
        0x1EC3728C6A115010,
        0x1BB6E3FF66A33AE4,
        0x51F388B8595475C2,
        0x69C9BF8E5499CF14,
    ),
) == (0x123FBC88, 0x138, 0x2C8, 0x48, 0x170, 0x150)

# Root RVAs and matrix payload.  The refresh worker materializes the matrix
# slot at 0x10080db10 and actor slot at 0x10080db9c.  The coordinate-candidate
# root 0x1325a828 is a separate load at 0x100805bf8.
assert instruction(0x10080DB10) == 0x5292B008  # mov w8,#0x9580
assert instruction(0x10080DB14) == 0x72A25948  # movk w8,#0x12ca,lsl#16
assert instruction(0x10080DB18) == 0x8B080354  # unity + 0x12ca9580
assert instruction(0x10080DB9C) == 0x5294D809  # mov w9,#0xa6c0
assert instruction(0x10080DBA0) == 0x72A264A9  # movk w9,#0x1325,lsl#16
assert instruction(0x10080DBB4) == 0x97FBE504  # read actor root
assert instruction(0x100805BF8) == 0x52950508  # mov w8,#0xa828
assert instruction(0x100805BFC) == 0x72A264A8  # movk w8,#0x1325,lsl#16
assert instruction(0x100805C08) == 0x97FC04EF  # read coordinate root
assert instruction(0x10080576C) == 0x52800082  # four matrix offsets
assert instruction(0x100805770) == 0x9400157D  # decoded-chain helper
assert instruction(0x100805864) == 0x52800802  # 0x40-byte matrix
assert instruction(0x100805868) == 0x97FC0877  # matrix read
assert instruction(0x1008057D4) == 0x92D0002A  # range 0x7ffeffffffff
assert instruction(0x1008057D8) == 0xF2E0000A
assert instruction(0x1008057E8) == 0x92C00028  # address - 0x100000001
assert instruction(0x1008057FC) == 0xEB0A011F  # unsigned range compare

# Full projection helper 0x1008041a0: W uses matrix 2/10/14, fabs and a
# strict 0.01 minimum. A sub-threshold/NaN W exits without writing output;
# otherwise X uses 0/8/12 and Y uses 1/9/13 before the width/height half-scale.
assert instruction(0x10080423C) == 0xBD400104  # matrix[2]
assert instruction(0x100804240) == 0xBD402105  # matrix[10]
assert instruction(0x100804248) == 0x1F021484  # m2*x + m10*z
assert instruction(0x100804254) == 0xBD4CED25  # matrix[14]
assert instruction(0x100804258) == 0x1E2428A4  # + m14
assert instruction(0x10080425C) == 0x1E20C084  # fabs W
assert float32(0x100C81EB8) == struct.unpack("<f", struct.pack("<f", 0.01))[0]
assert instruction(0x100804264) == 0xBD4EB925  # 0.01
assert instruction(0x100804268) == 0x1E252080  # compare |W|,0.01
assert chained_code_target(0x100F3F888) == 0x1008042F4  # fail/no store
assert chained_code_target(0x100F3F890) == 0x100804284  # reciprocal path
assert instruction(0x100804284) == 0x1E2E1005  # 1.0
assert instruction(0x100804288) == 0x1E2418A4  # 1/|W|
assert instruction(0x100804294) == 0xBD400105  # matrix[0]
assert instruction(0x100804298) == 0xBD402106  # matrix[8]
assert instruction(0x1008042A0) == 0x1F0218A5  # clip X
assert instruction(0x1008042A4) == 0xBD403106  # matrix[12]
assert instruction(0x1008042B4) == 0xBD400106  # matrix[1]
assert instruction(0x1008042B8) == 0xBD402107  # matrix[9]
assert instruction(0x1008042C0) == 0x1F020CC2  # clip Y
assert instruction(0x1008042C4) == 0xBD403103  # matrix[13]
assert instruction(0x1008042CC) == 0x1E214042  # negate clip Y
assert instruction(0x1008042D4) == 0x0F03F602  # {1,1}
assert instruction(0x1008042D8) == 0x0F8410A2  # +/- clip / |W|
assert instruction(0x1008042E0) == 0x2E22DC00  # width,height multiply
assert instruction(0x1008042E8) == 0x2E21DC00  # *0.5
assert instruction(0x1008042EC) == 0xFD000000  # store both coordinates

# Minimap helper 0x100804318 uses halfSide / 55.4 for X and halfSide / 55.15
# for Y, then selects the sign from matrix[0]. These operands are deliberately
# asymmetric and are not the older symmetric /100 approximation.
assert instruction(0x100804318) == 0x1E2C1004  # side * 0.5
assert instruction(0x10080431C) == 0x1E240821  # origin X + halfSide
assert float32(0x100C824F8) == struct.unpack("<f", struct.pack("<f", 55.4))[0]
assert instruction(0x100804324) == 0xBD44F924  # 55.4
assert instruction(0x100804328) == 0x1E241824  # halfSide / 55.4
assert float32(0x100C824FC) == struct.unpack("<f", struct.pack("<f", 55.15))[0]
assert instruction(0x100804330) == 0xBD44FD25  # 55.15
assert instruction(0x100804340) == 0x1E251825  # halfSide / 55.15
assert instruction(0x100804348) == 0xBD4CB506  # matrix[0]
assert instruction(0x10080434C) == 0x1E2020C8  # sign compare
assert instruction(0x100804358) == 0x1E26CCE6  # select orientation
assert instruction(0x100804364) == 0x1F040040  # X fused multiply-add
assert instruction(0x10080436C) == 0x1F050441  # Y fused multiply-add

# Matrix read success rejects only the all-zero m[0]/m[10] probe. Read failure
# and the zero-probe branch both converge on the frame-abort path; no +1 camp
# is written as a fallback.
assert chained_code_target(0x100F3F8E8) == 0x100805938  # read failed
assert chained_code_target(0x100F3F8F0) == 0x100805880  # read succeeded
assert instruction(0x100805880) == 0xBD4002E0  # m[0]
assert instruction(0x100805888) == 0x1A9F17E8  # m[0] == 0
assert instruction(0x10080588C) == 0xBD402AE0  # m[10]
assert instruction(0x100805894) == 0x1A8813E8  # invalid iff both zero
assert chained_code_target(0x100F3F8F8) == 0x1008058AC  # at least one live
assert chained_code_target(0x100F3F900) == 0x100805938  # both zero
assert instruction(0x100805938) == 0xF905A6DF  # clear cached root
assert instruction(0x10080593C) == 0xF902B35F  # clear refresh deadline
assert instruction(0x100805958) == 0x14000012  # frame abort
assert instruction(0x10080597C) == 0xF905A6DF  # clear failed terminal
assert instruction(0x100805980) == 0xF902B35F  # clear failed deadline
assert instruction(0x100805984) == 0x39554708  # previous matrix-ready
assert branch_target(0x10080599C) == 0x1008071D0
assert instruction(0x1008059A4) == 0x3915471F  # clear matrix-ready

# Hero identity, summoner ID, HP, recall and death hysteresis.
assert instruction(0x10080AA78) == 0x91014320  # actor + 0x50 config ID
assert instruction(0x10080AA7C) == 0x52800081  # int32
assert instruction(0x10080AA80) == 0x97FBF151  # read
assert instruction(0x10080AA84) == 0x510C8408  # ID - 801
assert instruction(0x10080AA88) == 0x310AF51F  # folded 101..800 guard
assert instruction(0x10080AC98) == 0x91017320  # actor + 0x5c camp
assert instruction(0x10080ACA0) == 0x97FBF0C9  # camp read
assert instruction(0x10080ACA4) == 0xB94CB2C8  # matrix-derived host camp
assert instruction(0x10080ACA8) == 0x6B08001F  # actor camp compare
assert instruction(0x10080A648) == 0xB27D07EA  # hero slot stride 0x18
assert instruction(0x10080A64C) == 0x9B092148  # indexed slot address
assert instruction(0x10080B16C) == 0x51000808  # hero count - 2
assert instruction(0x10080B170) == 0x71004D1F  # range length 19
assert instruction(0x10080B174) == 0x1A9F3000  # accept 2..20
assert instruction(0x10080A708) == 0x91017320  # skill branch reads camp
assert instruction(0x10080A734) == 0xF100051F  # camp == 1
assert instruction(0x10080A738) == 0x9A890141  # select +0x34 / +0x14 path
assert instruction(0x10080A740) == 0x52800062  # three offsets
assert instruction(0x10080A744) == 0x94000188  # summoner terminal address
assert instruction(0x10080A688) == 0x52800081  # int32 summoner ID
assert instruction(0x10080A68C) == 0x97FBF24E  # summoner ID read
assert instruction(0x100808570) == 0x52800042  # two HP offsets
assert instruction(0x100808574) == 0x940009FC  # {0x1a0,0x168}
assert instruction(0x1008085E0) == 0xD1002320  # current = terminal - 8
assert instruction(0x1008085E8) == 0x97FBFA77  # current read
assert instruction(0x100808624) == 0x130D7D1B  # signed /8192, trunc toward 0
assert instruction(0x100808634) == 0x91002320  # maximum = terminal + 8
assert instruction(0x10080863C) == 0x97FBFA62  # maximum read (unscaled)
assert instruction(0x10080872C) == 0xB9407708  # old dead sample count
assert instruction(0x100808738) == 0x7100011F  # commit only after old > 0
assert instruction(0x100808790) == 0xB9407308  # old alive sample count
assert instruction(0x10080879C) == 0x7100011F  # commit only after old > 0
assert instruction(0x1008087F8) == 0x52800082  # four recall offsets
assert instruction(0x1008087FC) == 0x9400095A  # recall terminal
assert instruction(0x1008088E4) == 0x97FBF9B8  # recall int32 read
assert instruction(0x1008088F0) == 0x7100041F  # recall == 1

# The retained-enemy vector alone has the ten-row ceiling. The compare occurs
# after duplicate scanning and before the append path; friendly observers use
# their separate 0x10080e464/0x10080eb2c production chains.
assert instruction(0x1008064EC) == 0xB940166A  # retained enemy count
assert instruction(0x1008064F0) == 0x7100295F  # count < 10
assert instruction(0x1008064F4) == 0x1A9FA7EA

# Soldier table, position, HP and live-only publication.
assert instruction(0x10080BB28) == 0x52800042  # {0x138,0x120}
assert instruction(0x10080BB2C) == 0x97FFFC8E
assert instruction(0x10080BB98) == 0x910072C0  # count terminal +0x1c
assert instruction(0x10080BBA0) == 0x97FBED09
assert instruction(0x10080BBB0) == 0x51000409  # unsigned(count - 1)
assert instruction(0x10080BBBC) == 0x7A483122  # <= 0x7f => 1..128
assert instruction(0x10080BBEC) == 0xF94007E9  # slot table
assert instruction(0x10080BC84) == 0x910172E0  # actor + 0x5c camp
assert instruction(0x10080BC8C) == 0x97FBECCE
assert instruction(0x10080BD1C) == 0x97FBECAA  # current HP read
assert instruction(0x10080BD30) == 0x130D7D1A  # signed /8192
assert instruction(0x10080BD48) == 0x52800062  # three position offsets
assert instruction(0x10080BD4C) == 0x940019C2  # xyz read and /1000
assert instruction(0x10080BD6C) == 0x7100035F  # current HP > 0 gate
assert instruction(0x10080BD70) == 0x1A95D3E8  # suppress dead publication

# Monster slots, timer policy, coordinates and publication order.
assert instruction(0x10080CA00) == 0x52800082  # four root offsets
assert instruction(0x10080CA04) == 0x97FFF8D8
assert instruction(0x10080CAFC) == 0xF1004EDF  # exactly 19 slots
assert instruction(0x10080CB30) == 0xF1004EDF
assert instruction(0x10080CB7C) == 0x52822E08  # 70000 low half
assert instruction(0x10080CB80) == 0x72A00028
assert instruction(0x10080CB84) == 0x528BF209  # 90000 low half
assert instruction(0x10080CB88) == 0x72A00029
assert instruction(0x10080CB8C) == 0x1A880136  # slot % 4 duration select
assert instruction(0x10080CBC4) == 0xB87769A8  # aux +0x110 + slot*12
assert instruction(0x10080CBC8) == 0x6B16011F  # reject raw > duration
assert instruction(0x10080CBF4) == 0x7100011F  # raw > 0
assert instruction(0x10080CBF8) == 0x7A561102  # raw < duration
assert instruction(0x10080CC64) == 0xFD42A501  # divide by 1000.0
assert instruction(0x10080CC70) == 0x1E611001  # +3.0 grace
assert instruction(0x10080CCA0) == 0x1E64C000  # ceil remaining seconds
assert instruction(0x10080CCAC) == 0x91000768  # next slot
assert instruction(0x10080CCB0) == 0xF1003F7F  # timed slots 0..15
assert instruction(0x10080CD94) == 0x91090100  # direct timer node +0x240
assert instruction(0x10080CDA8) == 0x97FBEB27  # direct timer read
assert instruction(0x10080CEA8) == 0x52805708  # node +0x2b8 X
assert instruction(0x10080CEBC) == 0x97FBE842
assert instruction(0x10080CEF8) == 0x52805808  # node +0x2c0 Z
assert instruction(0x10080CF0C) == 0x97FBE82E
assert instruction(0x10080D0BC) == 0xF1004EFF  # preserve 19-slot order

# Auxiliary page, cooldown fields and actor-coordinate cache bounds.
assert instruction(0x100810C8C) == 0x5295E809  # 0x126daf40 low
assert instruction(0x100810C90) == 0x72A24DA9  # 0x126daf40 high
assert instruction(0x100810CA4) == 0x97FBD8C8  # aux root read
assert instruction(0x100810CD8) == 0x528000C2  # six decoded offsets
assert instruction(0x100810CDC) == 0x97FFE822
assert instruction(0x100810D10) == 0x52800082  # marker int32
assert instruction(0x100810D14) == 0x97FBDB4C
assert instruction(0x100810D20) == 0x52894CA9  # 0x4a65
assert instruction(0x100810D6C) == 0xD114C334  # marker - 0x530
assert instruction(0x100810D78) == 0x52803902  # 0x1c8 table
assert instruction(0x100810B18) == 0x52803902  # refresh 0x1c8 table
assert instruction(0x100810B50) == 0xB27D090B  # record stride 0x38
assert instruction(0x100810B58) == 0xB8696AA9  # record ID
assert instruction(0x100810B5C) == 0x51019129  # ID - 100
assert instruction(0x100810B60) == 0x710AF53F  # <=800
assert instruction(0x100810B68) == 0x91000508  # next aux record
assert instruction(0x100810B6C) == 0xF100151F  # exactly five records
assert instruction(0x100808994) == 0xB940158D  # cooldown +0x14
assert instruction(0x100808998) == 0xB940218C  # cooldown +0x20
assert instruction(0x10080899C) == 0x6B0A01BF  # overflow guard A
assert instruction(0x1008089A0) == 0x7A4A3182  # overflow guard B
assert instruction(0x10081110C) == 0x72A7530A  # 0x3a980001 limit
assert instruction(0x10081114C) == 0x9BA87D28  # unsigned constant divide
assert instruction(0x100811150) == 0xD373FD08  # /8192000
assert instruction(0x100807164) == 0xF109633F  # exactly 600 candidates
assert instruction(0x100806958) == 0xFD002A80  # 100ms confirmation deadline
assert instruction(0x100806D78) == 0xB9405A88  # old confirmations
assert instruction(0x100806D84) == 0x7100011F  # commit after old > 0
assert instruction(0x10080F514) == 0xF1089E1F  # delta X < 551
assert instruction(0x10080F518) == 0x528044F0  # 551
assert instruction(0x10080F51C) == 0xFA5031E2  # delta Z < 551

# Matrix terminal caching starts with a monotonic-time read, reuses the cached
# terminal before its deadline, publishes terminal + now+0.35 on success, and
# publishes a zero terminal + now+0.05 on chain failure. The 64-byte matrix
# payload is nevertheless read on every frame from the selected terminal.
assert instruction(0x100805720) == 0x9411E03F  # monotonic time helper
assert instruction(0x10080572C) == 0xF945A6D4  # cached terminal
assert instruction(0x100805734) == 0xFD42B340  # cached deadline
assert instruction(0x100805738) == 0x1E602100  # deadline > now
assert instruction(0x10080573C) == 0xFA404A84  # terminal != 0 condition
assert instruction(0x1008057C0) == 0xF905A6D4  # publish terminal
assert instruction(0x1008057C8) == 0xFD428100  # 0.35
assert instruction(0x1008057CC) == 0x1E602900  # now + 0.35
assert instruction(0x1008057D0) == 0xFD02B340  # publish success deadline
assert instruction(0x10080585C) == 0xAA1403E0  # terminal as read address
assert instruction(0x100805860) == 0xAA1703E1  # frame matrix buffer
assert instruction(0x100805864) == 0x52800802  # 0x40-byte matrix
assert instruction(0x100805868) == 0x97FC0877  # matrix read every frame
assert instruction(0x10080595C) == 0xF905A6DF  # clear failed terminal
assert instruction(0x100805964) == 0xFD414500  # 0.05
assert instruction(0x100805968) == 0x1E602900  # now + 0.05
assert instruction(0x10080596C) == 0xFD02B340  # publish failure deadline

# A resolved terminal invokes the global reset only when the previous terminal
# was non-zero and differs from the new non-zero value. The reset invalidates
# both reader generations before clearing publication/root/actor/auxiliary
# state, so an older asynchronous completion cannot republish stale data.
assert instruction(0x100805794) == 0xF945A6C8  # previous terminal
assert instruction(0x100805798) == 0xF100011F  # previous != 0 precondition
assert instruction(0x10080579C) == 0xFA401104  # previous == new comparison
assert instruction(0x1008057A0) == 0x1A9F17E8  # reset branch selector
assert branch_target(0x1008057B8) == 0x1008071D0
assert instruction(0x100807204) == 0xF8E90108  # autokill/world epoch + 1
assert instruction(0x100807210) == 0xF8E90108  # reader-config epoch + 1
assert instruction(0x10080721C) == 0xC89FFD1F  # clear nextAllowed
assert instruction(0x10080723C) == 0xAD008100  # clear cached reader snapshot
assert branch_target(0x10080724C) == 0x10070672C  # clear dynamic actor state
assert instruction(0x100807254) == 0xF905AD1F  # clear coordinate root
assert instruction(0x10080725C) == 0xF905B11F  # clear root deadline
assert instruction(0x100807264) == 0x9115C000  # actor cache @ 0x101079570
assert instruction(0x100807268) == 0x5280A001  # actor cache size 0x500
assert instruction(0x10080726C) == 0x9411DBD8  # memset actor cache
assert instruction(0x100807274) == 0xB9056D1F  # clear actor count
assert instruction(0x10080727C) == 0x3915A11F  # clear producer flag
assert instruction(0x100807284) == 0x3915491F  # clear matrix-ready flag
assert instruction(0x10080728C) == 0xF905E51F  # clear cached root
assert instruction(0x100807294) == 0xB90BD11F  # clear miss streak
assert instruction(0x1008072A4) == 0xAD000100  # clear 64-byte root payload
assert instruction(0x1008072A8) == 0xAD010100
assert instruction(0x1008072B4) == 0xA9007D1F  # clear actor-root pair
assert instruction(0x1008072C0) == 0xAD000100  # clear auxiliary state
assert instruction(0x1008072CC) == 0xAD030100
assert instruction(0x1008072E0) == 0xF943F109  # auxiliary epoch
assert instruction(0x1008072E4) == 0x91000529  # auxiliary epoch + 1
assert instruction(0x1008072F4) == 0xF903F109  # publish auxiliary epoch
assert instruction(0x1008072FC) == 0xF905B51F  # clear aux refresh state
assert instruction(0x100807304) == 0xF905B91F
assert instruction(0x10080731C) == 0x392E0128  # republish aux-present flag
assert instruction(0x100807324) == 0x392E051F  # clear aux exhausted
assert instruction(0x10080732C) == 0x392E091F  # clear aux valid
assert instruction(0x100807334) == 0xB90B851F  # clear aux attempts
assert instruction(0x10080733C) == 0xB90B891F  # clear aux failures
assert instruction(0x100807348) == 0x089FFD1F  # clear direct-timer fallback
assert instruction(0x100807360) == 0xF900011F  # clear published world state

# The cache reset releases every 0x4000 mapped alias and its Mach port without
# invoking the lifecycle disconnect wrapper.
assert instruction(0x1006F4428) == 0x52800608  # mapping stride 0x30
assert instruction(0x1006F4468) == 0x52880002  # deallocate size 0x4000
assert branch_target(0x1006F446C) == 0x100C7E61C  # mach_vm_deallocate stub
assert branch_target(0x1006F44BC) == 0x100C7E5CC  # mach_port_deallocate stub

# readerFlags changes advance only the independent config epoch.
assert instruction(0x100808E10) == 0x911FC14A  # config epoch @ 0x100f3b7f0
assert instruction(0x100808E18) == 0x52800028  # increment by one
assert instruction(0x100808E1C) == 0xF8E80148  # atomic config increment

# Actor/raw-root pair changes clear the matrix terminal/deadline before calling
# the same reset, then clear matrix-ready and publish the replacement roots.
assert instruction(0x10080DC10) == 0xF9465708  # cached raw root
assert instruction(0x10080DC18) == 0xFA541104  # raw root changed
assert instruction(0x10080DC2C) == 0xF100013F  # cached actor root non-zero
assert instruction(0x10080DC30) == 0xFA531124  # actor root changed
assert instruction(0x10080DC90) == 0x90004368  # clear matrix terminal page
assert instruction(0x10080DC98) == 0x90004368  # clear matrix deadline page
assert branch_target(0x10080DCA0) == 0x1008071D0
assert instruction(0x10080DCA8) == 0x3915451F  # clear matrix-ready

# Lifecycle wrapper clears matrix terminal/deadline before the same reset.
assert instruction(0x1008073D8) == 0xF905A51F
assert instruction(0x1008073E0) == 0xF902B29F
assert branch_target(0x1008073E4) == 0x1008071D0

# Root/cache refresh TTLs: 350 ms healthy, 50 ms failed and 500 ms for the
# raw-coordinate root. These values are separate from the mapped-pages 750 ms
# stale-root transport compatibility fallback and 2 s autokill chains.
assert double(0x100C82500) == 0.35
assert double(0x100C81288) == 0.05
assert instruction(0x100805A0C) == 0x1E6C1001  # fmov d1,#0.5
assert instruction(0x100805CC4) == 0x1E6C1000  # fmov d0,#0.5

# Visibility/exposure consumers use two independently published friendly
# vectors. Both branches square X/Z deltas and compare against 144.0f (12 m).
assert instruction(0x1007A5564) == 0xBD404101  # observer coordinate field
assert instruction(0x1007A556C) == 0xF9422D29  # friendly vector @ +0x458
assert instruction(0x1007A5CC0) == 0xF94239E9  # friendly vector @ +0x470
assert instruction(0x1007A5DAC) == 0xF9423588  # sibling vector @ +0x468
assert instruction(0x1007A58A8) == 0x1E230863  # dz * dz
assert instruction(0x1007A58AC) == 0x1F020C42  # dx*dx + dz*dz
assert instruction(0x1007A58B0) == 0x52A8620B  # float32 144.0
assert instruction(0x1007A58B8) == 0x1E232040  # radius compare
assert instruction(0x1007A60A8) == 0x1E230863
assert instruction(0x1007A60AC) == 0x1F020C42
assert instruction(0x1007A60B0) == 0x52A8620B
assert instruction(0x1007A60B8) == 0x1E232040


# Camp is matrix-derived in AX: ldr s0; fcmp 0; mov w8,#2; csinc; str w8.
assert instruction(0x1008058C8) == 0xBD4CB500
assert instruction(0x1008058CC) == 0x1E202008
assert instruction(0x1008058D0) == 0x52800048
assert instruction(0x1008058D4) == 0x1A9FD508
assert instruction(0x1008058DC) == 0xB90CB128

# AX increments a consecutive miss counter, compares the old value with 2,
# and clears it on a healthy sample: reset occurs on miss three.
assert instruction(0x100805A3C) == 0xB94BD109
assert instruction(0x100805A40) == 0x1100052A
assert instruction(0x100805A44) == 0xB90BD10A
assert instruction(0x100805A48) == 0x7100093F
assert branch_target(0x100805A64) == 0x1008071D0  # third miss reset
assert instruction(0x100805A68) == 0x3915433F  # clear producer-ready
assert instruction(0x100805A8C) == 0xB90BD11F

# All three monster-table address calculations load stride 0x18.
assert instruction(0x10080F070) == 0x52800309
assert instruction(0x10080F098) == 0x52800308
assert instruction(0x10080F33C) == 0x52800308

# Independent utility serial queues. Both initializers pass (attr=null,
# qos_class=0x11, relative_priority=0) then load the decoded labels at
# 0x100f3bd00 / 0x100f3bf00 and publish separate queue globals.
assert instruction(0x100810554) == 0xD2800000
assert instruction(0x100810558) == 0x52800221
assert instruction(0x10081055C) == 0x52800002
assert instruction(0x100810570) == 0xF0003940
assert instruction(0x100810574) == 0x91340000
assert instruction(0x10081057C) == 0x9411B754
assert instruction(0x100810588) == 0xF902A520  # queue @ 0x101079548
assert instruction(0x1008123F0) == 0xD2800000
assert instruction(0x1008123F4) == 0x52800221
assert instruction(0x1008123F8) == 0x52800002
assert instruction(0x10081240C) == 0xB0003940
assert instruction(0x100812410) == 0x913C0000
assert instruction(0x100812418) == 0x9411AFAD
assert instruction(0x100812424) == 0xF902A120  # queue @ 0x101079540

# The two schedulers claim distinct in-flight bytes and dispatch to distinct
# queue globals. These are production call sites, not just string presence.
assert instruction(0x100810030) == 0x38E98289  # aux 0x101079da8 swap
assert instruction(0x1008100B8) == 0xF942A500  # aux queue load
assert instruction(0x100810104) == 0x1411B85E  # dispatch_async tail call
assert instruction(0x100808A00) == 0x8E8FD2A  # auto 0x101079dab CAS
assert instruction(0x100808A68) == 0xF942A100  # autokill queue load
assert instruction(0x100808AB8) == 0x9411D5F1  # dispatch_async


# Recovered cadence/backoff constants: auxiliary 24 Hz / 20 s discovery;
# autokill 25 ms latency validity, 100 ms exponential base, 1 s cap.
assert double(0x100C82470) == 1.0 / 24.0
assert instruction(0x100810148) == 0x1E669000  # fmov d0, #20.0
assert double(0x100C82508) == 0.025
assert double(0x100C81378) == 0.1
assert instruction(0x100811D04) == 0x1E6E1001  # fmov d1, #1.0
# The three autokill chains call helper 0x100811dc8. A non-null cached
# terminal is reused while expiry > now, then refreshed and stored for 2 s.
assert instruction(0x1008118CC) == 0x9400013F
assert instruction(0x1008118F0) == 0x94000136
assert instruction(0x100811918) == 0x9400012C
assert instruction(0x100811F8C) == 0xF9400260
assert instruction(0x100811FAC) == 0xFD400660
assert instruction(0x100811FB0) == 0x1E682000
assert instruction(0x1008120F4) == 0xF9000260
assert instruction(0x1008120F8) == 0x1E601000
assert instruction(0x100812100) == 0xFD000660

# Publish happens before clearing each in-flight byte. Reset first increments
# both generations, then clears the autokill deadline/cache.
assert instruction(0x100810EA0) == 0xFD05B900
assert instruction(0x100810EB4) == 0x9411B5EE  # memcpy 0x1c8 cache
assert instruction(0x100810F64) == 0x089FFD1F  # clear aux in-flight

# Discovery increments b84 and tests the old attempt count. First failure
# schedules another 20-second discovery; second failure sets both exhausted
# b81 and the direct-timer fallback byte da9.
assert instruction(0x100810E4C) == 0xB94B8528  # old attempts
assert instruction(0x100810E50) == 0x1100050A  # +1
assert instruction(0x100810E54) == 0xB90B852A  # publish attempts
assert instruction(0x100810F00) == 0x7100011F  # old attempts > 0
assert instruction(0x100810F04) == 0x1A9FD7E8
assert instruction(0x100810F1C) == 0x1E669000  # first retry: 20 s
assert instruction(0x100810F20) == 0x1E602900
assert instruction(0x100810F38) == 0x392E0509  # second fail: exhausted
assert instruction(0x100810F40) == 0xF905B51F  # no later discovery
assert instruction(0x100810F4C) == 0x089FFD09  # direct timer fallback
assert instruction(0x100811CA4) == 0xFD00150B  # publish cache timestamp
assert instruction(0x100811D2C) == 0xC89FFD28  # publish nextAllowed
assert instruction(0x100811D38) == 0x089FFD1F  # clear auto in-flight
assert instruction(0x100807204) == 0xF8E90108  # generation 1 increment
assert instruction(0x100807210) == 0xF8E90108  # generation 2 increment
assert instruction(0x10080721C) == 0xC89FFD1F  # clear nextAllowed
assert instruction(0x10080723C) == 0xAD008100  # clear cached snapshot

# Autokill consumer: current>0, maximum>=current, missing-health*0.15,
# distance squared < 22.159685, and damage>=current. The predicate result is
# followed by the action-byte swap, not by a target score/minimum reduction.
assert instruction(0x10079F4F8) == 0x1E202008
assert instruction(0x10079F63C) == 0xBD403921
assert instruction(0x10079F70C) == 0x1E202020
assert instruction(0x10079F7F8) == 0xBD403D22
assert instruction(0x10079F810) == 0xBD404123
assert instruction(0x10079F93C) == 0x1E2338A2
assert instruction(0x10079F94C) == 0x1E230821
assert instruction(0x10079F954) == 0x1F0608C2
assert instruction(0x10079F960) == 0x1E232040
assert instruction(0x10079F964) == 0x1E204428
assert instruction(0x10079F968) == 0x1A9FB7E9
assert float32(0x100C81F1C) == struct.unpack("<f", struct.pack("<f", 0.15))[0]
assert float32(0x100C824B4) == 22.159685134887695
assert instruction(0x10079F9F4) == 0x38E881E8  # action busy byte swap

# The consumer submits an async block whose invoke is 0x100801ce0. Coordinate
# rejection and both terminal sender paths clear the busy byte. There is no
# one-second success cooldown here; the 1.0 constant above belongs to reader
# failure backoff at 0x100811d04.
assert instruction(0x1007A00B0) == 0x089FFDFF
assert instruction(0x1007A00F0) == 0x089FFDFF
assert instruction(0x1007A1838) == 0x90000308
assert instruction(0x1007A183C) == 0x91338108
assert instruction(0x1007A1844) == 0xDAC10128  # sign async invoke 0x100801ce0
assert instruction(0x1007A1850) == 0xA9012428  # publish invoke + descriptor
assert instruction(0x1007A185C) == 0x94137288  # dispatch_async
assert instruction(0x1008022A8) == 0x911381EF  # async block owns busy @ +0x4e0
assert instruction(0x100802384) == 0x089FFDFF
assert instruction(0x100802420) == 0x089FFDFF

print(f"PASS: AX collector binary oracle {binary_path}")
