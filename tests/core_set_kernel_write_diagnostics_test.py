"""Static read-only diagnostic boundary check; no Apple/device execution claim."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
registry = (ROOT / "lara/overlay/CoreSetKernelWriteProfile.mm").read_text(encoding="utf-8")
backend = (ROOT / "lara/overlay/CoreSetMappedPageWriteBackend.mm").read_text(encoding="utf-8")


def method(source: str, marker: str) -> str:
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    cursor = opening + 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[start:cursor]


def check(registry_source: str, backend_source: str) -> None:
    observed = method(registry_source, "+ (NSDictionary<NSString *, id> *)diagnosticSnapshot")
    mapped = method(backend_source, "- (NSDictionary<NSString *, id> *)diagnosticSnapshot")
    for token in ("kern.osversion", "hw.machine", "kernel_uuid_unavailable",
                  "audited_profile_not_installed", "kernel_offsets_mismatch",
                  "observedOffsetsAudited\": @NO", "offsetMismatchKeys",
                  "nativeReady ? CSCurrentKernelUUID() : nil"):
        assert token in observed, token
    for token in ("target_read_session_not_ready", "target_binding_not_created",
                  "target_binding_stale", "mapped_cleanup_pending",
                  "mapped_backend_kernel_gate_rejected", "readIdentityMatches", "backendReady"):
        assert token in mapped, token
    for token in ("installAuditedProfile:", "sProfile =", "ds_run(", "ds_kwrite",
                  "vmmapremotepage(", "connectForController:", "[_readSession connect]"):
        assert token not in observed + mapped, token
    # Identity/registration remain separate from diagnostics and mandatory for binding.
    assert "if (!sProfile || !ds_is_ready()" in registry_source
    assert "return [CoreSetKernelWriteProfileRegistry matchesCurrentKernel];" in backend_source
    assert "if (_pendingCleanup || _ready || !CSVerifiedKernelProfile()" in backend_source


check(registry, backend)
for before, after in (
    ('observedOffsetsAudited": @NO', 'observedOffsetsAudited": @YES'),
    ('nativeReady ? CSCurrentKernelUUID() : nil', 'CSCurrentKernelUUID()'),
    ('@"schemaVersion": @1', '@"schemaVersion": @1, @"bad": @(ds_run())'),
):
    assert before in registry
    try:
        check(registry.replace(before, after, 1), backend)
    except AssertionError:
        continue
    raise AssertionError(f"unsafe diagnostic mutation accepted: {before}")
print("PASS: concrete identity/rejection diagnostics, read-only boundary, three negative mutations")
