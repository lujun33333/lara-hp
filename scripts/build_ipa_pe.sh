#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PROJECT=lara
SCHEME=lara
PRODUCT_NAME="Core-SET"
CONFIG=Release
DERIVED="$ROOT/build/DerivedDataCoreSet"
AX_LOCAL_TEST_AUTH_BYPASS=0

for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG=Debug ;;
        --local-test-auth-bypass) AX_LOCAL_TEST_AUTH_BYPASS=1 ;;
        *) echo "未知参数：$arg（可用：--debug、--local-test-auth-bypass）" >&2; exit 2 ;;
    esac
done

AUTH_BYPASS_BUILD_SETTINGS=(
    'GCC_PREPROCESSOR_DEFINITIONS=$(inherited) AX_LOCAL_TEST_AUTH_BYPASS=0'
)
AUTH_BYPASS_JSON=false
AUTH_BYPASS_PACKAGE_SUFFIX=
EXPECTED_BUNDLE_IDENTIFIER=qingxiugai.qingxiugai.qinxiugai
if [[ "$AX_LOCAL_TEST_AUTH_BYPASS" == 1 ]]; then
    AUTH_BYPASS_BUILD_SETTINGS=(
        'GCC_PREPROCESSOR_DEFINITIONS=$(inherited) AX_LOCAL_TEST_AUTH_BYPASS=1'
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) AX_LOCAL_TEST_AUTH_BYPASS'
        'PRODUCT_BUNDLE_IDENTIFIER=qingxiugai.qingxiugai.qinxiugai.localtest'
    )
    AUTH_BYPASS_JSON=true
    AUTH_BYPASS_PACKAGE_SUFFIX=-local-test-auth-bypass
    EXPECTED_BUNDLE_IDENTIFIER=qingxiugai.qingxiugai.qinxiugai.localtest
fi

say() { printf '[*] %s\n' "$*"; }
ok()  { printf '[+] %s\n' "$*"; }
die() { printf '[!] %s\n' "$*" >&2; exit 1; }

reset_build_dir() {
    local target="$1"
    case "$target" in
        "$ROOT"/build/*) ;;
        *) die "拒绝清理 build 目录外的路径：$target" ;;
    esac
    [[ "$target" != "$ROOT/build" && "$target" != "$ROOT/build/" ]] \
        || die "拒绝清理整个 build 根目录"
    rm -rf -- "$target"
    mkdir -p -- "$target"
}

remove_previous_output() {
    local target="$1"
    case "$target" in
        "$ROOT"/Core-SET-*.ipa|\
        "$ROOT"/Core-SET-*.json|\
        "$ROOT"/Core-SET-*.jsonl|\
        "$ROOT"/Core-SET-*.sha256) ;;
        *) die "拒绝删除非 Core-SET 输出：$target" ;;
    esac
    rm -f -- "$target"
}

command -v xcodebuild >/dev/null 2>&1 || die "缺少 xcodebuild"
command -v zip >/dev/null 2>&1 || die "缺少 zip"
command -v python3 >/dev/null 2>&1 || die "缺少 python3"
command -v git >/dev/null 2>&1 || die "缺少 git"
command -v codesign >/dev/null 2>&1 || die "缺少 codesign"

# 在任何依赖拉取、编译或生成文件之前固定源码身份；否则构建中间产物会把
# 干净的 CI checkout 误判为 dirty。build/ 与最终根目录产物均不进入清单。
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    SOURCE_HAS_GIT=1
    SOURCE_COMMIT=$(git -C "$ROOT" rev-parse HEAD)
    SOURCE_TREE=$(git -C "$ROOT" rev-parse 'HEAD^{tree}')
    SOURCE_STATUS=$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all)
else
    SOURCE_HAS_GIT=0
    SOURCE_COMMIT=nogit
    SOURCE_TREE=nogit
    SOURCE_STATUS=
fi
mkdir -p "$ROOT/build"
SOURCE_MANIFEST_TMP="$ROOT/build/source-files.jsonl"
python3 - "$ROOT" "$SOURCE_MANIFEST_TMP" <<'PY' \
    || die "无法生成完整源码文件清单"
import hashlib
import json
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1]).resolve()
output = pathlib.Path(sys.argv[2])

generated_patterns = (
    "Core-SET-*.ipa",
    "Core-SET-*.json",
    "Core-SET-*.jsonl",
    "Core-SET-*.sha256",
    # Legacy build products remain excluded from source identity, not deleted.
    "AX-Pro-1.2.8-*.ipa",
    "AX-Pro-1.2.8-*.json",
    "AX-Pro-1.2.8-*.jsonl",
    "AX-Pro-1.2.8-*.sha256",
    "lara-wz-*.ipa",
    "lara-wz-*.json",
)

def is_generated(relative):
    return len(relative.parts) == 1 and any(
        relative.match(pattern) for pattern in generated_patterns
    )

try:
    raw_paths = subprocess.check_output(
        [
            "git", "-C", str(root), "ls-files", "--cached", "--others",
            "--exclude-standard", "-z",
        ]
    )
    relative_paths = {
        pathlib.PurePosixPath(os.fsdecode(item))
        for item in raw_paths.split(b"\0")
        if item
    }
except (FileNotFoundError, subprocess.CalledProcessError):
    excluded_parts = {
        ".git", "build", ".codex-tests", ".codex-temp", "__pycache__",
        "xcuserdata", "__MACOSX",
    }
    relative_paths = set()
    for path in root.rglob("*"):
        relative = pathlib.PurePosixPath(path.relative_to(root).as_posix())
        if any(part in excluded_parts for part in relative.parts):
            continue
        if path.is_file() or path.is_symlink():
            relative_paths.add(relative)

records = []
for relative in sorted(relative_paths, key=lambda item: item.as_posix().encode("utf-8")):
    if is_generated(relative):
        continue
    path = root.joinpath(*relative.parts)
    if path.is_symlink():
        payload = os.fsencode(os.readlink(path))
        mode = "120000"
        kind = "symlink"
    elif path.is_file():
        payload = path.read_bytes()
        mode = "100755" if os.access(path, os.X_OK) else "100644"
        kind = "file"
    else:
        # Tracked deletions are represented by their absence from the manifest.
        continue
    records.append(
        {
            "kind": kind,
            "mode": mode,
            "path": relative.as_posix(),
            "sha256": hashlib.sha256(payload).hexdigest(),
            "size": len(payload),
        }
    )

if not records:
    raise SystemExit("source manifest is empty")
output.write_text(
    "".join(
        json.dumps(record, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + "\n"
        for record in records
    ),
    encoding="utf-8",
)
PY
SOURCE_MANIFEST_SHA256=$(shasum -a 256 "$SOURCE_MANIFEST_TMP" | awk '{print $1}')

if [[ "$SOURCE_HAS_GIT" == 1 ]]; then
    if [[ -z "$SOURCE_STATUS" ]]; then
        SOURCE_STATE=clean
        SOURCE_FINGERPRINT=$(printf 'commit=%s\ntree=%s\n' \
            "$SOURCE_COMMIT" "$SOURCE_TREE" | shasum -a 256 | awk '{print $1}')
    else
        SOURCE_STATE=dirty
        SOURCE_FINGERPRINT="$SOURCE_MANIFEST_SHA256"
    fi
else
    SOURCE_STATE=snapshot
    SOURCE_FINGERPRINT="$SOURCE_MANIFEST_SHA256"
fi
SOURCE_COMMIT_SHORT="${SOURCE_COMMIT:0:12}"
SOURCE_FINGERPRINT_SHORT="${SOURCE_FINGERPRINT:0:12}"

# ── 从源码构建 libxpf.dylib ──────────────────────────────────────────────────
# lara/lib/libxpf.dylib 曾经是一个提交进 git 的预编译二进制（2026-09-05），
# 早于 XPF 的 "Fix some metrics not working on higher versions of iOS 26 and on
# iOS 27 betas" 提交。旧版没有 arm_maxoffset 这条 fallback，于是
# xpf_find_pmap_bootstrap 的字符串查找失败、XPF_ASSERT 直接终止，
# pointer_mask 与 T1SZ_BOOT 都拿不到 —— 内核注入层的 call primitive 与
# task port 随之全部失效。这里改为每次构建都从 vendor/XPF 源码编译，
# 保证「修好的源码」真的进入出货二进制。
say "从源码构建并静态链接 XPF / libgrabkernel2 ..."
XPF_DIR="$ROOT/vendor/XPF"
[ -f "$XPF_DIR/src/common.c" ] || die "缺少 vendor/XPF/src"
[ -f "$XPF_DIR/Makefile" ]     || die "缺少 vendor/XPF/Makefile"
# AX 1.2.8 的入口只接收 kernelcache。Lara 侧同样只传一个参数，因此在编译
# 出货 dylib 前强制核对声明、实现和全部调用，禁止再次混入三参数 ABI。
XPF_SINGLE_DECL='int xpf_start_with_kernel_path(const char *kernelPath);'
LC_ALL=C grep -Fqx -- "$XPF_SINGLE_DECL" "$ROOT/lara/headers/xpf.h" \
    || die "Lara 的 XPF 声明不是 AX 1.2.8 单参数 ABI"
LC_ALL=C grep -Fqx -- "$XPF_SINGLE_DECL" "$XPF_DIR/src/xpf.h" \
    || die "vendor/XPF 的公开声明不是 AX 1.2.8 单参数 ABI"
LC_ALL=C grep -Fqx -- 'int xpf_start_with_kernel_path(const char *kernelPath)' "$XPF_DIR/src/xpf.c" \
    || die "vendor/XPF 的实现不是 AX 1.2.8 单参数 ABI"
if LC_ALL=C grep -nE 'xpf_start_with_kernel_path[[:space:]]*\([^)]*,' \
        "$ROOT/lara/headers/xpf.h" \
        "$ROOT/lara/kexploit/offsets.m" \
        "$ROOT/lara/kexploit/utils.m" \
        "$XPF_DIR/src/xpf.h" \
        "$XPF_DIR/src/xpf.c" \
        "$XPF_DIR/src/cli/main.c"; then
    die "检测到多参数 xpf_start_with_kernel_path，拒绝构建 ABI 混用产物"
fi
# Lara 会直接读取导出全局 gXPF 的字段；两份头文件的结构体必须逐字段一致。
# 2026-09-20 曾因 Lara 仍把 firstItem 当成 +0x110、而 dylib 已移到 +0x1a8，
# 将 kernelSandboxAuthStubSection 误作链表头并在 Mach-O 魔数地址上崩溃。
python3 - "$ROOT/lara/headers/xpf.h" "$XPF_DIR/src/xpf.h" <<'PY' \
    || die "Lara 与 vendor/XPF 的 gXPF 结构布局不一致"
import pathlib
import re
import sys

def struct_body(path):
    text = pathlib.Path(path).read_text(encoding="utf-8")
    match = re.search(r"typedef\s+struct\s+s_XPF\s*\{(.*?)\}\s*XPF\s*;", text, re.S)
    if not match:
        raise SystemExit(f"找不到 XPF 结构体: {path}")
    body = re.sub(r"/\*.*?\*/|//[^\r\n]*", "", match.group(1), flags=re.S)
    return re.sub(r"\s+", " ", body).strip()

if struct_body(sys.argv[1]) != struct_body(sys.argv[2]):
    raise SystemExit("gXPF layout mismatch")

for path in sys.argv[1:]:
    text = pathlib.Path(path).read_text(encoding="utf-8")
    for forbidden in (
        "kernelBootcodeSection", "kernelSandboxAuthStubSection",
        "kernelIOSurfaceTextSection", "kernelIOSurfaceStringSection",
        "kernelIOSurfaceOsLogSection", "decompressedSptm", "decompressedTxm",
        "sptmContainer", "txmContainer",
    ):
        if forbidden in text:
            raise SystemExit(f"forbidden AX 1.2.8 XPF field {forbidden}: {path}")
    for required in (
        "offsetof(XPF, firstItem) == 0x110",
        "offsetof(XPF, ignoreBaseSet) == 0x118",
        "sizeof(XPF) == 0x120",
    ):
        if required not in text:
            raise SystemExit(f"missing ABI assertion {required}: {path}")
PY
for removed in "$XPF_DIR/src/sptm_txm.c" "$XPF_DIR/src/sptm_txm.h" \
               "$XPF_DIR/src/im4p_direct.c" "$XPF_DIR/src/im4p_direct.h"; do
    [[ ! -e "$removed" ]] || die "旧 XPF 构建仍混入可选镜像源：$removed"
done
if LC_ALL=C grep -R -nE 'xpf_sptm_txm_init|decompressedSptm|decompressedTxm|kernelBootcodeSection|kernelSandboxAuthStubSection' \
        "$XPF_DIR/src" "$XPF_DIR/Makefile"; then
    die "旧 XPF 生产链仍混入 SPTM/TXM 初始化或新版 section"
fi
LC_ALL=C grep -q -- 'arm_maxoffset' "$XPF_DIR/src/common.c" \
    || die "旧 XPF 源码缺少 arm_maxoffset 兼容 finder"

verify_xpf_binary_layout() {
    local artifact="$1"
    shift
    python3 - "$artifact" "$@" <<'PY' \
        || die "XPF 产物 ABI 偏移验证失败：$artifact"
import pathlib
import re
import subprocess
import sys

artifact = pathlib.Path(sys.argv[1])
required_archs = sys.argv[2:]
if not artifact.is_file():
    raise SystemExit(f"missing artifact: {artifact}")
if not required_archs:
    raise SystemExit("no required architecture supplied")

archs = subprocess.check_output(
    ["xcrun", "lipo", "-archs", str(artifact)], text=True
).split()
for required_arch in required_archs:
    if required_arch not in archs:
        raise SystemExit(f"missing architecture {required_arch}: {artifact}")

required_offsets = {
    "_xpf_item_register": "0x110",
    "_xpf_item_resolve": "0x110",
    "_xpf_set_ignore_base_set": "0x118",
}
for arch in required_archs:
    symbols = subprocess.check_output(
        ["xcrun", "nm", "-arch", arch, "-n", str(artifact)], text=True
    )
    gxpf_match = re.search(
        r"(?mi)^([0-9a-f]+)\s+\S\s+_gXPF\s*$", symbols
    )
    if not gxpf_match:
        raise SystemExit(f"missing _gXPF symbol ({arch}): {artifact}")
    gxpf_address = int(gxpf_match.group(1), 16)
    disassembly = subprocess.check_output(
        ["xcrun", "otool", "-arch", arch, "-tvV", str(artifact)], text=True
    )
    for symbol, offset in required_offsets.items():
        match = re.search(
            rf"(?ms)^(?:[0-9a-f]+\s+)?{re.escape(symbol)}:\s*\n"
            rf"(.*?)(?=^(?:[0-9a-f]+\s+)?_\S*:\s*\n|\Z)",
            disassembly,
        )
        if not match:
            raise SystemExit(f"missing symbol {symbol} ({arch}): {artifact}")
        offset_value = int(offset, 16)
        # Clang may either materialize &gXPF first and keep the member offset in
        # the load/store, or fold gXPF's page offset into that displacement.
        displacements = {offset_value, (gxpf_address & 0xfff) + offset_value}
        operand_patterns = [
            rf"(?<![0-9a-f])#(?:0x{value:x}|{value})(?![0-9a-f])"
            for value in displacements
        ]
        if not any(
            re.search(pattern, match.group(1), re.IGNORECASE)
            for pattern in operand_patterns
        ):
            raise SystemExit(
                f"{symbol} does not access gXPF + {offset} ({arch}): {artifact}"
            )

binary = artifact.read_bytes()
for forbidden in (b"xpf_sptm_txm_init", b"decompressedSptm", b"decompressedTxm"):
    if forbidden in binary:
        raise SystemExit(f"forbidden optional-image marker {forbidden!r}: {artifact}")
PY
}

CHOMA_COMMIT=b1a4f2debf2aff70edc2825c5cfbd05926d7fc18
CHOMA_DIR="$ROOT/build/deps/ChOma"
if [ ! -d "$CHOMA_DIR/.git" ]; then
    [[ ! -e "$CHOMA_DIR" ]] || die "ChOma 依赖目录存在但不是 Git checkout"
    say "拉取固定版本 ChOma ..."
    mkdir -p "$(dirname "$CHOMA_DIR")"
    git clone --no-checkout https://github.com/opa334/ChOma \
        "$CHOMA_DIR" >/dev/null 2>&1 || die "无法拉取 ChOma"
fi
git -C "$CHOMA_DIR" fetch --depth 1 origin "$CHOMA_COMMIT" >/dev/null 2>&1 \
    || die "无法获取固定 ChOma 提交 $CHOMA_COMMIT"
git -C "$CHOMA_DIR" checkout --detach "$CHOMA_COMMIT" >/dev/null 2>&1 \
    || die "无法切换到固定 ChOma 提交 $CHOMA_COMMIT"
[[ "$(git -C "$CHOMA_DIR" rev-parse HEAD)" == "$CHOMA_COMMIT" ]] \
    || die "ChOma 版本不一致"

# 这里会实际编译头文件中的三条 ABI 断言；失败信息分别包含
# "AX 1.2.8 firstItem ABI"、ignoreBaseSet ABI 和 XPF size。
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -fsyntax-only -arch arm64 -isysroot "$IOS_SDK" \
    -DXPF_LAYOUT_ONLY "$ROOT/scripts/build_support/xpf_layout_check.c" \
    || die "XPF AX 1.2.8 布局编译门禁失败"
xcrun --sdk iphoneos clang -fsyntax-only -arch arm64 -isysroot "$IOS_SDK" \
    -DXPF_LAYOUT_ONLY -DXPF_TEST_LARA_HEADER "$ROOT/scripts/build_support/xpf_layout_check.c" \
    || die "Lara XPF AX 1.2.8 布局编译门禁失败"
mkdir -p "$ROOT/build"
# 该 dylib 只用于 lipo/nm/otool ABI 门禁，不进入 App；覆盖 XPF Makefile 的
# 可选签名器，避免为这个一次性检查产物引入 Homebrew ldid 依赖。
if ! make -B -C "$XPF_DIR" output/ios/libxpf.dylib CHOMA_PATH="$CHOMA_DIR" \
        LDID=/usr/bin/true \
        >"$ROOT/build/xpf-build.log" 2>&1; then
    tail -40 "$ROOT/build/xpf-build.log" >&2
    die "libxpf 编译失败，见 build/xpf-build.log"
fi
verify_xpf_binary_layout "$XPF_DIR/output/ios/libxpf.dylib" arm64 arm64e

# 不将上面的 ABI 验证 dylib 复制到 App。生产链重新以 arm64e / 17.0
# 编译同一份 XPF + ChOma 源码，并通过 -force_load 并入主 Mach-O。
STATIC_DIR="$ROOT/build/static-ios"
reset_build_dir "$STATIC_DIR"
mkdir -p "$STATIC_DIR/obj/xpf" "$STATIC_DIR/obj/grabkernel"

xpf_sources=(
    "$XPF_DIR/src/bad_recovery.c"
    "$XPF_DIR/src/common.c"
    "$XPF_DIR/src/decompress.c"
    "$XPF_DIR/src/non_ppl.c"
    "$XPF_DIR/src/ppl.c"
    "$XPF_DIR/src/xpf.c"
)
choma_sources=("$CHOMA_DIR"/src/*.c)
[[ -e "${choma_sources[0]}" ]] || die "ChOma 源码不完整"
xpf_objects=()
xpf_index=0
for source in "${xpf_sources[@]}" "${choma_sources[@]}"; do
    object="$STATIC_DIR/obj/xpf/$xpf_index.o"
    xcrun --sdk iphoneos clang -c -O2 -fblocks -arch arm64e \
        -isysroot "$IOS_SDK" -miphoneos-version-min=17.0 \
        -I"$XPF_DIR/src" -I"$CHOMA_DIR/include" \
        "$source" -o "$object" \
        || die "XPF 静态对象编译失败：$source"
    xpf_objects+=("$object")
    xpf_index=$((xpf_index + 1))
done
xcrun --sdk iphoneos libtool -static -o "$STATIC_DIR/libxpf.a" "${xpf_objects[@]}" \
    || die "libxpf.a 归档失败"
XPF_ARCHIVE_SYMBOLS="$(LC_ALL=C xcrun nm -g "$STATIC_DIR/libxpf.a")"
grep -q ' _xpf_start_with_kernel_path$' <<<"$XPF_ARCHIVE_SYMBOLS" \
    || die "libxpf.a 缺少公开入口"
LC_ALL=C grep -a -q -- "arm_maxoffset" "$STATIC_DIR/libxpf.a" \
    || die "libxpf.a 缺少 arm_maxoffset 兼容 finder"

# libgrabkernel2 的 src/*.m 只包含 grab/appledb/utils；Partial 基类由固定提交
# 中的 _external/lib/ios/libpartial.a 提供。当前 target 的 Partial.m 仅实现
# kc_* 快路径，不能替代也不能重复定义 Objective-C Partial 类。
GRABKERNEL_COMMIT=e015c73aee6c2d3f6b0aad3fa629fe4c0429b7a6
GRAB_PARTIAL_SHA256=83aea6edd5d538bf72a91ec8feb4847eb2ae99612e56fd9aa61ee9dfccca3241
GRABKERNEL_DIR="$ROOT/build/deps/libgrabkernel2"
if [[ ! -d "$GRABKERNEL_DIR/.git" ]]; then
    [[ ! -e "$GRABKERNEL_DIR" ]] || die "libgrabkernel2 依赖目录存在但不是 Git checkout"
    mkdir -p "$(dirname "$GRABKERNEL_DIR")"
    git clone --no-checkout https://github.com/alfiecg24/libgrabkernel2.git \
        "$GRABKERNEL_DIR" >/dev/null 2>&1 || die "无法拉取 libgrabkernel2"
fi
git -C "$GRABKERNEL_DIR" fetch --depth 1 origin "$GRABKERNEL_COMMIT" >/dev/null 2>&1 \
    || die "无法获取 libgrabkernel2 固定提交 $GRABKERNEL_COMMIT"
git -C "$GRABKERNEL_DIR" checkout --detach "$GRABKERNEL_COMMIT" >/dev/null 2>&1 \
    || die "无法切换 libgrabkernel2 固定提交"
[[ "$(git -C "$GRABKERNEL_DIR" rev-parse HEAD)" == "$GRABKERNEL_COMMIT" ]] \
    || die "libgrabkernel2 版本不一致"
grab_sources=("$GRABKERNEL_DIR"/src/*.m)
[[ -e "${grab_sources[0]}" ]] || die "libgrabkernel2 源码不完整"
GRAB_PARTIAL_FAT_ARCHIVE="$GRABKERNEL_DIR/_external/lib/ios/libpartial.a"
[[ -f "$GRAB_PARTIAL_FAT_ARCHIVE" ]] || die "libgrabkernel2 缺少固定 Partial 静态库"
[[ "$(shasum -a 256 "$GRAB_PARTIAL_FAT_ARCHIVE" | awk '{print $1}')" == \
   "$GRAB_PARTIAL_SHA256" ]] || die "libgrabkernel2 Partial 静态库摘要不一致"
GRAB_PARTIAL_ARCHIVE="$STATIC_DIR/libpartial-arm64e.a"
xcrun lipo "$GRAB_PARTIAL_FAT_ARCHIVE" -thin arm64e \
    -output "$GRAB_PARTIAL_ARCHIVE" \
    || die "无法提取 libpartial arm64e slice"
GRAB_PARTIAL_SYMBOLS="$(LC_ALL=C xcrun nm -g "$GRAB_PARTIAL_ARCHIVE")"
GRAB_PARTIAL_CLASS_DEFINITIONS="$(awk \
    '$NF == "_OBJC_CLASS_$_Partial" && $(NF - 1) != "U" { count++ } END { print count + 0 }' \
    <<<"$GRAB_PARTIAL_SYMBOLS")"
[[ "$GRAB_PARTIAL_CLASS_DEFINITIONS" == 1 ]] \
    || die "libpartial arm64e slice 必须且只能定义一次 Partial 类"
grab_objects=()
grab_index=0
for source in "${grab_sources[@]}"; do
    object="$STATIC_DIR/obj/grabkernel/$grab_index.o"
    xcrun --sdk iphoneos clang -c -O3 -fPIC -fobjc-arc -arch arm64e \
        -isysroot "$IOS_SDK" -miphoneos-version-min=17.0 \
        -I"$GRABKERNEL_DIR/include" -I"$GRABKERNEL_DIR/_external/include" \
        "$source" -o "$object" \
        || die "libgrabkernel2 静态对象编译失败：$source"
    grab_objects+=("$object")
    grab_index=$((grab_index + 1))
done
xcrun --sdk iphoneos libtool -static -o "$STATIC_DIR/libgrabkernel2.a" \
    "${grab_objects[@]}" "$GRAB_PARTIAL_ARCHIVE" \
    || die "libgrabkernel2.a 归档失败"
GRAB_ARCHIVE_SYMBOLS="$(LC_ALL=C xcrun nm -g "$STATIC_DIR/libgrabkernel2.a")"
grep -q ' _grab_kernelcache$' <<<"$GRAB_ARCHIVE_SYMBOLS" \
    || die "libgrabkernel2.a 缺少 grab_kernelcache"
GRAB_ARCHIVE_PARTIAL_DEFINITIONS="$(awk \
    '$NF == "_OBJC_CLASS_$_Partial" && $(NF - 1) != "U" { count++ } END { print count + 0 }' \
    <<<"$GRAB_ARCHIVE_SYMBOLS")"
[[ "$GRAB_ARCHIVE_PARTIAL_DEFINITIONS" == 1 ]] \
    || die "libgrabkernel2.a 中 Partial 类定义数量不唯一"
ok "XPF 与 libgrabkernel2 静态库已就绪（arm64e / iOS 17.0）"

need_files=(
    "lara/headers/AXLauncherAuthorizationPolicy.h"
    "lara/lara-Bridging-Header.h"
    "lara/lara.swift"
    "lara/views/app/ContentView.swift"
    "lara/views/app/CoreSetGameTarget.swift"
    "lara/views/app/CoreSetMenuViewController.swift"
    "lara/kexploit/Partial.h"
    "lara/kexploit/Partial.m"
    "lara/CoreSetAssets/hf.png"
    "lara/CoreSetAssets/OPPOSans-H.ttf"
    "lara/CoreSetAssets/IcoMoon.ttf"
    "lara/CoreSetAssets/bj.mp3"
    "lara/CoreSetLoading.png"
    "lara/AppIcon60x60@2x.png"
    "lara/AppIcon76x76@2x~ipad.png"
    "lara/classes/laramgr.swift"
)
for file in "${need_files[@]}"; do
    [[ -f "$ROOT/$file" ]] || die "缺文件：$file"
done

# The current product presents a local Core-SET menu without a game consumer.
# Check only active source files; historical reports and sample IPAs are excluded.
if LC_ALL=C grep -R -n -E 'wzhud_|wzesp_|wzaim_|wz_find_image_base|wz_connect\(|com\.tencent\.smoba|UnityFramework' \
        --include='*.swift' --include='*.h' --include='*.m' --include='*.mm' \
        "$ROOT/lara"; then
    die "生产源码仍引用已删除的王者功能链"
fi

reset_build_dir "$DERIVED"
mkdir -p "$ROOT/build"
say "构建 Core-SET ($CONFIG, source=$SOURCE_STATE/$SOURCE_COMMIT_SHORT, local-test-auth-bypass=$AUTH_BYPASS_JSON)..."
set +e
xcodebuild \
    -project "$ROOT/$PROJECT.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    -destination 'generic/platform=iOS' \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_ENTITLEMENTS="" \
    CODE_SIGNING_ALLOWED=NO \
    "${AUTH_BYPASS_BUILD_SETTINGS[@]}" \
    clean build 2>&1 | tee "$ROOT/build/xcodebuild-CoreSet.log" | tail -40
status=${PIPESTATUS[0]}
set -e
if [[ $status -ne 0 ]]; then
    grep -nE '(^|[[:space:]])(fatal )?error:' \
        "$ROOT/build/xcodebuild-CoreSet.log" | tail -120 || true
    die "xcodebuild 失败，见 build/xcodebuild-CoreSet.log"
fi

SRC_APP="$DERIVED/Build/Products/$CONFIG-iphoneos/$PRODUCT_NAME.app"
BIN="$SRC_APP/$PRODUCT_NAME"
[[ -f "$BIN" ]] || die "构建后未找到 $BIN"
INFO_PLIST="$SRC_APP/Info.plist"
[[ -f "$INFO_PLIST" ]] || die "构建后未找到 Info.plist"

# Xcode may rewrite standalone PNG resources even when PNG compression is off.
# Restore the exact audited source bytes before the bundle is signed.
for resource in hf.png CoreSetLoading.png; do
    case "$resource" in
        hf.png)
            source_png="$ROOT/lara/CoreSetAssets/hf.png"
            expected_png_sha="a4e166b3ba37ce01a1407f40634be05b1a17fa19927a600e7c9d8b0c17175790"
            ;;
        CoreSetLoading.png)
            source_png="$ROOT/lara/CoreSetLoading.png"
            expected_png_sha="7f521ef9a446a740941ce436d2cc0a30f388e423ee6013e9fb16e6f10ccd3bec"
            ;;
    esac
    [[ -f "$source_png" && "$(shasum -a 256 "$source_png" | awk '{print $1}')" == "$expected_png_sha" ]] \
        || die "Core-SET 源 PNG 摘要不一致：$resource"
    cp "$source_png" "$SRC_APP/$resource" \
        || die "无法恢复 Core-SET 原始 PNG：$resource"
done

# AX 1.2.8 参考 plist 没有工程自定义的构建指纹；提交信息只写入
# IPA 旁边的 JSON 清单。PlistBuddy 仅用于清理旧 DerivedData 可能残留的键。
/usr/libexec/PlistBuddy -c 'Delete :LARABuildSourceCommit' "$INFO_PLIST" \
    >/dev/null 2>&1 || true

python3 - "$INFO_PLIST" "$EXPECTED_BUNDLE_IDENTIFIER" <<'PY' || die "最终 Info.plist 与 Core-SET 包体契约不一致"
import pathlib
import plistlib
import sys

path = pathlib.Path(sys.argv[1])
expected_bundle_identifier = sys.argv[2]
with path.open("rb") as stream:
    info = plistlib.load(stream)

expected = {
    "CFBundleDisplayName": "Core-SET",
    "CFBundleName": "Core-SET",
    "CFBundleExecutable": "Core-SET",
    "CFBundleIdentifier": expected_bundle_identifier,
    "CFBundleShortVersionString": "1.7",
    "LSApplicationQueriesSchemes": ["tencentlaunch1106467070"],
    "CFBundleVersion": "3",
    "MinimumOSVersion": "17.0",
    "UILaunchStoryboardName": "LaunchScreen",
    "UIApplicationSupportsIndirectInputEvents": True,
    "UISupportedInterfaceOrientations": [
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
        "UIInterfaceOrientationPortraitUpsideDown",
    ],
    "UISupportedInterfaceOrientations~ipad": [
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationPortraitUpsideDown",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ],
    "UISupportedInterfaceOrientations~iphone": [
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ],
    "UIRequiredDeviceCapabilities": ["arm64e"],
    "UIAppFonts": ["OPPOSans-H.ttf", "IcoMoon.ttf"],
}
for key, value in expected.items():
    if info.get(key) != value:
        raise SystemExit(f"{key}: expected {value!r}, got {info.get(key)!r}")

expected_icons = {
    "CFBundlePrimaryIcon": {
        "CFBundleIconFiles": ["AppIcon60x60"],
    }
}
expected_ipad_icons = {
    "CFBundlePrimaryIcon": {
        "CFBundleIconFiles": ["AppIcon60x60", "AppIcon76x76"],
    }
}
if info.get("CFBundleIcons") != expected_icons:
    raise SystemExit("CFBundleIcons mismatch")
if info.get("CFBundleIcons~ipad") != expected_ipad_icons:
    raise SystemExit("CFBundleIcons~ipad mismatch")

for forbidden in (
    "UIFileSharingEnabled",
    "LSSupportsOpeningDocumentsInPlace",
    "UIRequiresFullScreen",
    "UIViewControllerBasedStatusBarAppearance",
    "UILaunchScreen",
    "LARABuildSourceCommit",
):
    if forbidden in info:
        raise SystemExit(f"forbidden extra plist key: {forbidden}")
PY

# Xcode 26 的 Swift 链接动作会在 LD_RUNPATH_SEARCH_PATHS 已为空时仍自动加入
# /usr/lib/swift LC_RPATH。先把可能的 @rpath/libswift*.dylib load command
# 改为 iOS 17.0 已提供的系统绝对路径，再删除这个冗余 rpath。修改发生在
# 最终 codesign 之前；OTHER_LDFLAGS 的 headerpad 为 install_name_tool 预留空间。
SWIFT_RPATH_LOADS="$(xcrun otool -L "$BIN" | tail -n +2 | awk '{print $1}' \
    | grep -E '^@rpath/libswift[^/]*\.dylib$' || true)"
if [[ -n "$SWIFT_RPATH_LOADS" ]]; then
    while IFS= read -r old_load; do
        [[ -n "$old_load" ]] || continue
        system_load="/usr/lib/swift/${old_load#@rpath/}"
        xcrun install_name_tool -change "$old_load" "$system_load" "$BIN" \
            || die "无法把 Swift runtime load command 改为系统路径：$old_load"
    done <<<"$SWIFT_RPATH_LOADS"
fi
MAIN_RPATHS_BEFORE="$(xcrun otool -l "$BIN" | awk '
    $1 == "cmd" { in_rpath = ($2 == "LC_RPATH"); next }
    in_rpath && $1 == "path" { print $2; in_rpath = 0 }
')"
if grep -Fxq -- /usr/lib/swift <<<"$MAIN_RPATHS_BEFORE"; then
    xcrun install_name_tool -delete_rpath /usr/lib/swift "$BIN" \
        || die "无法删除 Xcode 自动注入的 /usr/lib/swift LC_RPATH"
fi
MAIN_DYLIB_LOADS="$(xcrun otool -L "$BIN" | tail -n +2 | awk '{print $1}')"
for required_private_framework in \
    /System/Library/PrivateFrameworks/FrontBoard.framework/FrontBoard \
    /System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices; do
    grep -Fxq -- "$required_private_framework" <<<"$MAIN_DYLIB_LOADS" \
        || die "最终主 Mach-O 缺少 Core 1.7 固定依赖：$required_private_framework"
done
SYSTEM_SWIFT_LOADS="$(grep -E '^/usr/lib/swift/libswift[^/]*\.dylib$' \
    <<<"$MAIN_DYLIB_LOADS" || true)"
NON_SYSTEM_SWIFT_LOADS="$(grep -E '(^|/)libswift[^/]*\.dylib$' \
    <<<"$MAIN_DYLIB_LOADS" | grep -Ev '^/usr/lib/swift/' || true)"
if [[ -z "$SYSTEM_SWIFT_LOADS" ]]; then
    printf '[!] 主 Mach-O 动态依赖：\n%s\n' "$MAIN_DYLIB_LOADS" >&2
    die "最终主 Mach-O 未链接 iOS 系统 Swift runtime"
fi
[[ -z "$NON_SYSTEM_SWIFT_LOADS" ]] \
    || die "最终主 Mach-O 仍有非系统 Swift runtime load command：$NON_SYSTEM_SWIFT_LOADS"
NORMALIZED_LOAD_COMMANDS="$(xcrun otool -l "$BIN")"
if grep -q 'cmd LC_RPATH' <<<"$NORMALIZED_LOAD_COMMANDS"; then
    die "Swift runtime 规范化后主 Mach-O 仍包含 LC_RPATH"
fi

say "使用 Core 1.7 浮窗场景与 SpringBoard SBS context 所需权限对 App bundle 做 ad-hoc codesign..."
# Info.plist 和全部 bundle 资源必须先固定，再由 codesign 同时签主 Mach-O、写入
# 当前完整 entitlement 集并生成与最终资源匹配的 _CodeSignature/CodeResources。
codesign --force --sign - --timestamp=none \
    --entitlements "$ROOT/Config/lara.entitlements" \
    --generate-entitlement-der "$SRC_APP"
SIGNED_ENTITLEMENTS="$ROOT/build/Core-SET-main-entitlements.plist"
if ! codesign -d --entitlements :- "$BIN" >"$SIGNED_ENTITLEMENTS"; then
    die "无法读取最终主 executable entitlements"
fi
python3 - "$ROOT/Config/lara.entitlements" "$SIGNED_ENTITLEMENTS" <<'PY' \
    || die "最终主 executable 未逐键保留 Config/lara.entitlements"
import pathlib
import plistlib
import sys

expected_path = pathlib.Path(sys.argv[1])
actual_path = pathlib.Path(sys.argv[2])
with expected_path.open("rb") as stream:
    expected = plistlib.load(stream)
with actual_path.open("rb") as stream:
    actual = plistlib.load(stream)

if not isinstance(expected, dict) or not isinstance(actual, dict):
    raise SystemExit("entitlements root must be a dictionary")
missing = sorted(key for key in expected if key not in actual)
mismatched = sorted(
    key for key, expected_value in expected.items()
    if key in actual and actual[key] != expected_value
)
if missing:
    raise SystemExit(f"missing signed entitlement keys: {missing}")
if mismatched:
    raise SystemExit(f"mismatched signed entitlement values: {mismatched}")
PY
[[ -f "$SRC_APP/_CodeSignature/CodeResources" ]] \
    || die "App bundle 签名未生成 _CodeSignature/CodeResources"
codesign --verify --strict --verbose=2 "$SRC_APP" \
    || die "最终 App bundle codesign/CodeResources 校验失败"

# Swift whole-module compilation need not emit one object per source file.
LC_ALL=C grep -a -q 'CoreSetMenuViewController' "$BIN" \
    || die "最终二进制没有当前 Core-SET 本地菜单"

for object in wzmem.o wzesp.o KoiProjection.o YuanbaoCollector.o WZAXTouch.o WZAimRuntime.o WZAimObserver.o WZHUDBridge.o; do
    if find "$DERIVED" -name "$object" -print -quit | grep -q .; then
        die "已删除的王者对象仍参与编译：$object"
    fi
done
for forbidden in wzesp_tick wz_find_image_base wzaim_runtime_attach \
    wzaim_observer_start wzhud_set_enabled WZHUDDrawWindow WZHUDMenuWindow \
    WZHUDFloatWindow WZAXImageCache lara.wz.local-hud com.tencent.smoba UnityFramework; do
    if LC_ALL=C grep -a -q -- "$forbidden" "$BIN"; then
        die "最终二进制仍包含已删除的王者标记：$forbidden"
    fi
done
if [[ "$AX_LOCAL_TEST_AUTH_BYPASS" == 1 ]]; then
    LC_ALL=C grep -a -q -- "LOCAL TEST AUTH BYPASS" "$BIN" \
        || die "本地测试包缺少授权绕过可见标记"
else
    LC_ALL=C grep -a -q -- "LOCAL TEST AUTH BYPASS" "$BIN" \
        && die "正式包混入本地测试授权绕过标记"
fi

# 字段偏移已经由两份头文件的编译期断言和上面的独立 arm64/arm64e dylib
# 指令级门禁覆盖。静态库进入主程序后可能被 LTO/内联/linker relaxation 改写为
# 不再含直接 #0x110/#0x118 immediate 的等价寻址，不能重复套用 dylib 反汇编形态。
LC_ALL=C grep -a -q -- "arm_maxoffset" "$BIN" \
    || die "主 Mach-O 缺少 arm_maxoffset 兼容 finder"
MAIN_SYMBOLS="$(xcrun nm -g "$BIN")"
grep -q ' _xpf_start_with_kernel_path$' <<<"$MAIN_SYMBOLS" \
    || die "主 Mach-O 未静态并入 libxpf"
grep -q ' _grab_kernelcache$' <<<"$MAIN_SYMBOLS" \
    || die "主 Mach-O 未静态并入 libgrabkernel2"
MAIN_PARTIAL_CLASS_DEFINITIONS="$(awk \
    '$NF == "_OBJC_CLASS_$_Partial" && $(NF - 1) != "U" { count++ } END { print count + 0 }' \
    <<<"$MAIN_SYMBOLS")"
[[ "$MAIN_PARTIAL_CLASS_DEFINITIONS" == 1 ]] \
    || die "主 Mach-O 中 Partial 类定义数量不唯一"

# AX 1.2.8 没有 Frameworks 目录，且所有 load command 都指向系统库。
[[ ! -e "$SRC_APP/Frameworks" ]] || die "最终 App 仍包含 Frameworks 目录"
NON_SYSTEM_LOADS="$(xcrun otool -L "$BIN" | tail -n +2 | awk '{print $1}' \
    | grep -Ev '^(/System/Library/|/usr/lib/)' || true)"
[[ -z "$NON_SYSTEM_LOADS" ]] \
    || die "主 Mach-O 仍有非系统动态依赖：$NON_SYSTEM_LOADS"
MAIN_LOAD_COMMANDS="$(xcrun otool -l "$BIN")"
if grep -q 'cmd LC_RPATH' <<<"$MAIN_LOAD_COMMANDS"; then
    die "主 Mach-O 仍包含 AX 1.2.8 参考不存在的 LC_RPATH"
fi
for retired_resource in "Rajdhani Bold.otf" Assets.car AXReference.bundle; do
    [[ ! -e "$SRC_APP/$retired_resource" ]] \
        || die "最终 App 仍包含已退役的 AX 资源：$retired_resource"
done
[[ "$(shasum -a 256 "$SRC_APP/AppIcon60x60@2x.png" | awk '{print $1}')" == \
   "06903bb8dc06cf4522c21f2a0549cf66ae16b30504571bac88680a1ab82a3d92" ]] \
    || die "Core-SET v1.7 iPhone 图标摘要不一致"
[[ "$(shasum -a 256 "$SRC_APP/AppIcon76x76@2x~ipad.png" | awk '{print $1}')" == \
   "3232f3ed80a07cd9d710d6a88bf9572f17bb0ae5a6fbf37992d34f96ca311420" ]] \
    || die "Core-SET v1.7 iPad 图标摘要不一致"

WEAPON_MANIFEST_SHA256="426c223f6a1859edc11930c20200a7ce7cd5e001946d0bf9cc8bdaa93ce96a10"
python3 - "$SRC_APP" "$PRODUCT_NAME" "$WEAPON_MANIFEST_SHA256" <<'PY' \
    || die "App bundle 根条目与 Core-SET 资源契约不一致"
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
executable = sys.argv[2]
weapon_manifest_sha = sys.argv[3]
required_files = {
    executable,
    "Info.plist",
    "AppIcon60x60@2x.png",
    "AppIcon76x76@2x~ipad.png",
    "hf.png",
    "OPPOSans-H.ttf",
    "IcoMoon.ttf",
    "CoreSetLoading.png",
    "bj.mp3",
}
core_set_hashes = {
    "bj.mp3": "05e3e950da25039931ed3d2c1a9fc24481d16d6fac672b3f6e13a8d37701e92f",
    "hf.png": "a4e166b3ba37ce01a1407f40634be05b1a17fa19927a600e7c9d8b0c17175790",
    "OPPOSans-H.ttf": "cdfdaf7dbadaccdef6186cf806f50681016398065f97cd0dcadcb3a5398a502a",
    "IcoMoon.ttf": "40422bc0623058e64df49907026fc4913ad871bb0231559f41c1a1bd137545a4",
    "CoreSetLoading.png": "7f521ef9a446a740941ce436d2cc0a30f388e423ee6013e9fb16e6f10ccd3bec",
}
actual_files = {entry.name for entry in root.iterdir() if entry.is_file()}
missing = required_files - actual_files
extra = actual_files - required_files
if missing:
    raise SystemExit(f"missing root files: {sorted(missing)}")
if extra:
    raise SystemExit(f"unexpected root files: {sorted(extra)}")
for name, expected in core_set_hashes.items():
    actual = hashlib.sha256((root / name).read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit(f"Core-SET root resource hash mismatch for {name}: {actual}")
directories = {entry.name for entry in root.iterdir() if entry.is_dir()}
unexpected_directories = directories - {"_CodeSignature", "CoreSetWeaponIcons"}
if unexpected_directories:
    raise SystemExit(f"unexpected root directories: {sorted(unexpected_directories)}")
weapon_folder = root / "CoreSetWeaponIcons"
if not weapon_folder.is_dir():
    raise SystemExit("missing CoreSetWeaponIcons directory")
manifest_bytes = (weapon_folder / "manifest.json").read_bytes()
if hashlib.sha256(manifest_bytes).hexdigest() != weapon_manifest_sha:
    raise SystemExit("CoreSetWeaponIcons manifest hash mismatch")
icons = json.loads(manifest_bytes)["icons"]
if len(icons) != 89:
    raise SystemExit("CoreSetWeaponIcons icon count mismatch")
expected_icons = {"manifest.json"}
for icon in icons:
    name = icon["file"]
    if name != f'{icon["id"]}.png' or name in expected_icons:
        raise SystemExit(f"invalid CoreSetWeaponIcons entry: {name}")
    expected_icons.add(name)
    data = (weapon_folder / name).read_bytes()
    if len(data) != icon["bytes"] or hashlib.sha256(data).hexdigest() != icon["sha256"]:
        raise SystemExit(f"CoreSetWeaponIcons hash mismatch: {name}")
if {entry.name for entry in weapon_folder.iterdir()} != expected_icons:
    raise SystemExit("CoreSetWeaponIcons directory entries mismatch")
signature = root / "_CodeSignature"
if not signature.is_dir():
    raise SystemExit("missing _CodeSignature directory")
signature_entries = {
    entry.relative_to(signature).as_posix()
    for entry in signature.rglob("*")
    if entry.is_file()
}
if signature_entries != {"CodeResources"}:
    raise SystemExit(f"signature entries mismatch: {sorted(signature_entries)}")
PY

PACKAGE_STEM="Core-SET-${SOURCE_COMMIT_SHORT}-${SOURCE_FINGERPRINT_SHORT}${AUTH_BYPASS_PACKAGE_SUFFIX}"
STAGE="$ROOT/build/package-CoreSet"
OUTPUT_IPA="$ROOT/$PACKAGE_STEM.ipa"
OUTPUT_MANIFEST="$ROOT/$PACKAGE_STEM.json"
SOURCE_MANIFEST="$ROOT/$PACKAGE_STEM.sources.jsonl"
CHECKSUM_MANIFEST="$ROOT/$PACKAGE_STEM.sha256"
reset_build_dir "$STAGE"
remove_previous_output "$OUTPUT_IPA"
remove_previous_output "$OUTPUT_MANIFEST"
remove_previous_output "$SOURCE_MANIFEST"
remove_previous_output "$CHECKSUM_MANIFEST"
cp "$SOURCE_MANIFEST_TMP" "$SOURCE_MANIFEST"
mkdir -p "$STAGE/Payload"
cp -R "$SRC_APP" "$STAGE/Payload/$PRODUCT_NAME.app"
(cd "$STAGE" && zip -qry "$OUTPUT_IPA" Payload)

python3 - "$OUTPUT_IPA" "$EXPECTED_BUNDLE_IDENTIFIER" "$WEAPON_MANIFEST_SHA256" <<'PY' \
    || die "最终 IPA 的 ZIP 条目、plist 或资源与 Core-SET 契约不一致"
import hashlib
import json
import plistlib
import sys
import zipfile
from collections import Counter

archive = sys.argv[1]
expected_bundle_identifier = sys.argv[2]
weapon_manifest_sha = sys.argv[3]
prefix = "Payload/Core-SET.app/"
required = {
    "Core-SET",
    "Info.plist",
    "AppIcon60x60@2x.png",
    "AppIcon76x76@2x~ipad.png",
    "hf.png",
    "OPPOSans-H.ttf",
    "IcoMoon.ttf",
    "CoreSetLoading.png",
    "bj.mp3",
}
expected_hashes = {
    "bj.mp3": "05e3e950da25039931ed3d2c1a9fc24481d16d6fac672b3f6e13a8d37701e92f",
    "hf.png": "a4e166b3ba37ce01a1407f40634be05b1a17fa19927a600e7c9d8b0c17175790",
    "OPPOSans-H.ttf": "cdfdaf7dbadaccdef6186cf806f50681016398065f97cd0dcadcb3a5398a502a",
    "IcoMoon.ttf": "40422bc0623058e64df49907026fc4913ad871bb0231559f41c1a1bd137545a4",
    "CoreSetLoading.png": "7f521ef9a446a740941ce436d2cc0a30f388e423ee6013e9fb16e6f10ccd3bec",
    "AppIcon60x60@2x.png": "06903bb8dc06cf4522c21f2a0549cf66ae16b30504571bac88680a1ab82a3d92",
    "AppIcon76x76@2x~ipad.png": "3232f3ed80a07cd9d710d6a88bf9572f17bb0ae5a6fbf37992d34f96ca311420",
}
with zipfile.ZipFile(archive) as ipa:
    name_list = ipa.namelist()
    names = set(name_list)
    duplicates = sorted(name for name, count in Counter(name_list).items() if count > 1)
    if duplicates:
        raise SystemExit(f"duplicate ZIP entries: {duplicates}")
    if not any(name == prefix or name.startswith(prefix) for name in names):
        raise SystemExit("missing Payload/Core-SET.app")
    outside = {
        name for name in names
        if name not in {"Payload/", prefix} and not name.startswith(prefix)
    }
    if outside:
        raise SystemExit(f"entries outside Core-SET.app: {sorted(outside)}")
    relative = {
        name[len(prefix):]
        for name in names
        if name.startswith(prefix) and name != prefix
    }
    direct_files = {name for name in relative if "/" not in name.rstrip("/") and not name.endswith("/")}
    if direct_files != required:
        raise SystemExit(
            f"root files mismatch: missing={sorted(required-direct_files)}, "
            f"extra={sorted(direct_files-required)}"
        )
    weapon_prefix = "CoreSetWeaponIcons/"
    manifest_bytes = ipa.read(prefix + weapon_prefix + "manifest.json")
    if hashlib.sha256(manifest_bytes).hexdigest() != weapon_manifest_sha:
        raise SystemExit("zipped CoreSetWeaponIcons manifest hash mismatch")
    icons = json.loads(manifest_bytes)["icons"]
    if len(icons) != 89:
        raise SystemExit("zipped CoreSetWeaponIcons icon count mismatch")
    expected_icons = {weapon_prefix + "manifest.json"}
    for icon in icons:
        name = icon["file"]
        if name != f'{icon["id"]}.png' or weapon_prefix + name in expected_icons:
            raise SystemExit(f"invalid zipped CoreSetWeaponIcons entry: {name}")
        expected_icons.add(weapon_prefix + name)
        data = ipa.read(prefix + weapon_prefix + name)
        if len(data) != icon["bytes"] or hashlib.sha256(data).hexdigest() != icon["sha256"]:
            raise SystemExit(f"zipped CoreSetWeaponIcons hash mismatch: {name}")
    actual_icons = {name for name in relative if name.startswith(weapon_prefix) and not name.endswith("/")}
    if actual_icons != expected_icons:
        raise SystemExit("zipped CoreSetWeaponIcons entries mismatch")
    forbidden_nested = {
        name for name in relative
        if "/" in name.rstrip("/") and not name.startswith("_CodeSignature/")
        and name not in expected_icons
    }
    if forbidden_nested:
        raise SystemExit(f"unexpected nested entries: {sorted(forbidden_nested)}")
    if prefix + "_CodeSignature/CodeResources" not in names:
        raise SystemExit("missing _CodeSignature/CodeResources")
    signature_files = {
        name for name in relative
        if name.startswith("_CodeSignature/") and not name.endswith("/")
    }
    if signature_files != {"_CodeSignature/CodeResources"}:
        raise SystemExit(f"signature entries mismatch: {sorted(signature_files)}")
    for name, expected in expected_hashes.items():
        actual = hashlib.sha256(ipa.read(prefix + name)).hexdigest()
        if actual != expected:
            raise SystemExit(f"hash mismatch for {name}: {actual}")
    info = plistlib.loads(ipa.read(prefix + "Info.plist"))
    for key, expected in {
        "CFBundleExecutable": "Core-SET",
        "CFBundleDisplayName": "Core-SET",
        "CFBundleName": "Core-SET",
        "CFBundleShortVersionString": "1.7",
        "LSApplicationQueriesSchemes": ["tencentlaunch1106467070"],
        "UIAppFonts": ["OPPOSans-H.ttf", "IcoMoon.ttf"],
        "CFBundleIcons": {
            "CFBundlePrimaryIcon": {"CFBundleIconFiles": ["AppIcon60x60"]},
        },
        "CFBundleIcons~ipad": {
            "CFBundlePrimaryIcon": {"CFBundleIconFiles": ["AppIcon60x60", "AppIcon76x76"]},
        },
        "CFBundleIdentifier": expected_bundle_identifier,
        "MinimumOSVersion": "17.0",
        "UILaunchStoryboardName": "LaunchScreen",
    }.items():
        if info.get(key) != expected:
            raise SystemExit(f"zipped plist mismatch for {key}: {info.get(key)!r}")
    for forbidden in ("UIFileSharingEnabled", "LSSupportsOpeningDocumentsInPlace", "UIRequiresFullScreen"):
        if forbidden in info:
            raise SystemExit(f"zipped plist contains forbidden key: {forbidden}")
PY

IPA_SHA256=$(shasum -a 256 "$OUTPUT_IPA" | awk '{print $1}')
BUILD_LOG_SHA256=$(shasum -a 256 "$ROOT/build/xcodebuild-CoreSet.log" | awk '{print $1}')
cat > "$OUTPUT_MANIFEST" <<JSON
{
  "productMode": "core-set-pe-ui",
  "gameConsumer": "CoreSetReadSession HUD lanes + Core v1.7 bone/prediction Aim+Recoil shared checked write",
  "targetProcess": "ShadowTrackerExtra",
  "targetBundle": "com.tencent.tmgp.pubgmhd",
  "targetVersion": "1.38.12/build15915/UUID34b785b2-0dab-3992-985d-359e6bf45585",
  "referenceUIVersion": "1.7",
  "launchMethod": "registered-url-scheme",
  "bundleIdentifier": "$EXPECTED_BUNDLE_IDENTIFIER",
  "sourceState": "$SOURCE_STATE",
  "sourceCommit": "$SOURCE_COMMIT",
  "sourceTree": "$SOURCE_TREE",
  "sourceFingerprint": "$SOURCE_FINGERPRINT",
  "sourceManifest": "${SOURCE_MANIFEST##*/}",
  "sourceManifestSha256": "$SOURCE_MANIFEST_SHA256",
  "ipaSha256": "$IPA_SHA256",
  "buildLogSha256": "$BUILD_LOG_SHA256",
  "localTestAuthorizationBypass": $AUTH_BYPASS_JSON,
  "transportPolicy": "checked-control-and-input-rotation-write",
  "writeFeaturesEnabled": true
}
JSON

(
    cd "$ROOT"
    shasum -a 256 \
        "${OUTPUT_IPA##*/}" \
        "${OUTPUT_MANIFEST##*/}" \
        "${SOURCE_MANIFEST##*/}" \
        "build/xcodebuild-CoreSet.log"
) > "$CHECKSUM_MANIFEST"
(
    cd "$ROOT"
    shasum -a 256 -c "${CHECKSUM_MANIFEST##*/}"
) || die "产物校验清单自检失败"

ok "输出：$OUTPUT_IPA"
ok "清单：$OUTPUT_MANIFEST"
ok "源码清单：$SOURCE_MANIFEST"
ok "校验清单：$CHECKSUM_MANIFEST"
