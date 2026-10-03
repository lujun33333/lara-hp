"""Source gate for caller-owned XPF cleanup and AX stop ordering."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
XPF = (ROOT / "vendor/XPF/src/xpf.c").read_text(encoding="utf-8")
VENDOR_HEADER = (ROOT / "vendor/XPF/src/xpf.h").read_text(encoding="utf-8")
LARA_HEADER = (ROOT / "lara/headers/xpf.h").read_text(encoding="utf-8")
OFFSETS = (ROOT / "lara/kexploit/offsets.m").read_text(encoding="utf-8")
ITEMS = (ROOT / "lara/kexploit/xpfitems.m").read_text(encoding="utf-8")
CLI = (ROOT / "vendor/XPF/src/cli/main.c").read_text(encoding="utf-8")
COMMON = (ROOT / "vendor/XPF/src/common.c").read_text(encoding="utf-8")


helper = "xpf_start_with_kernel_path_cleanup_on_failure"
for header in (VENDOR_HEADER, LARA_HEADER):
    assert f"static inline int {helper}" in header
    helper_body = header.split(f"static inline int {helper}", 1)[1].split("typedef struct s_XPF", 1)[0]
    assert "xpf_start_with_kernel_path(kernelPath)" in helper_body
    assert "if (result != 0)" in helper_body
    assert "xpf_stop();" in helper_body

assert OFFSETS.count(f"{helper}(") == 3
assert CLI.count(f"{helper}(") == 1
assert "if (xpf_start_with_kernel_path(" not in OFFSETS
assert "if (xpf_start_with_kernel_path(" not in CLI

start_body = XPF.split("int xpf_start_with_kernel_path", 1)[1].split(
    "void xpf_item_register", 1
)[0]
assert "xpf_stop();" not in start_body
assert "fstat(gXPF.kernelFd, &s);" in start_body
assert "if (fstat" not in start_body
assert start_body.index("Fat *candidate") < start_body.index("gXPF.kernelContainer = candidate")
assert start_body.index("if (!machoCandidate)") < start_body.index("gXPF.kernelContainer = candidate")

register_body = XPF.split("void xpf_item_register", 1)[1].split(
    "uint64_t xpf_item_resolve", 1
)[0]
assert "malloc(sizeof(XPFItem))" in register_body
assert "if (!newItem)" not in register_body

dictionary_body = XPF.split("xpc_object_t xpf_construct_offset_dictionary", 1)[1].split(
    "static char *gXPFError", 1
)[0]
base_failure = dictionary_body.split("for (int i = 0; sets[i]; i++)", 1)[0]
assert "xpf_offset_dictionary_add_set(offsetDictionary, &gBaseSet) != 0) return NULL" in base_failure
assert "xpc_release" not in base_failure
assert dictionary_body.count("xpc_release(offsetDictionary);") == 3

stop_body = XPF.split("void xpf_stop(void)", 1)[1]
cleanup_order = (
    "gXPF.mappedKernel",
    "gXPF.decompressedKernel",
    "gXPF.kernelFd",
    "gXPF.kernelTextSection",
    "gXPF.kernelPPLTextSection",
    "gXPF.kernelStringSection",
    "gXPF.kernelConstSection",
    "gXPF.kernelDataConstSection",
    "gXPF.kernelDataSection",
    "gXPF.kernelOSLogSection",
    "gXPF.kernelAMFITextSection",
    "gXPF.kernelAMFIStringSection",
    "gXPF.kernelSandboxTextSection",
    "gXPF.kernelSandboxStringSection",
    "gXPF.kernelPrelinkTextSection",
    "gXPF.kernelBootdataInit",
    "gXPF.kernelPLKTextSection",
    "gXPF.kernelInfoPlistSection",
    "gXPF.kernelContainer",
    "gXPF.kernelVersionString",
    "gXPF.darwinVersion",
    "gXPF.xnuBuild",
    "gXPF.xnuPlatform",
    "gXPF.osVersion",
    "gXPF.kernelInfoPlist",
    "gXPF.firstItem",
    "gXPF = (struct s_XPF){ 0 };",
)
cursor = -1
for token in cleanup_order:
    cursor = stop_body.find(token, cursor + 1)
    assert cursor >= 0, token
for intentionally_unreleased in (
    "gXPF.kernelPinstSection",
    "gXPF.kernelKmodInfoSection",
    "gXPF.kernelPrelinkInfoSection",
    "gXPFError",
):
    assert intentionally_unreleased not in stop_body

# The compatibility finder owns and frees only its local metric.  It must not
# mutate global lifecycle state or grow SPTM/TXM cleanup paths.
arm_fallback = COMMON.split("static uint64_t xpf_find_pmap_bootstrap", 1)[1].split(
    "static uint64_t xpf_find_pointer_mask_symbol", 1
)[0]
assert 'pfmetric_string_init("arm_maxoffset")' in arm_fallback
assert "pfmetric_free(armMaxoffsetMetric);" in arm_fallback
assert "xpf_stop" not in arm_fallback and "gXPF =" not in arm_fallback
assert "sptm" not in stop_body.lower() and "txm" not in stop_body.lower()

print("XPF lifecycle source gate: PASS")
