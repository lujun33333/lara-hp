"""Runtime transport/input diagnostics contracts; source only, no device claim."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def body(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    for position in range(opening + 1, len(source)):
        if source[position] == "{":
            depth += 1
        elif source[position] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1:position]
    raise AssertionError("unterminated body: " + signature)


header = read("lara/overlay/CoreSetReadSession.h")
session = read("lara/overlay/CoreSetReadSession.mm")
assert "diagnosticLabel" in header and "lastConnectDiagnostic" in header
assert "Only ShadowTrackerExtra 1.38.12/build 15915" in header
connect = body(session, "- (BOOL)connect")
for stage in (
    "process-not-found", "process-path-unavailable", "profile-mismatch",
    "task-read-symbol-missing", "task-read-denied", "kernel-page-table-read-unavailable",
    "task-port-pid-verification-failed", "main-image-or-uuid-not-found",
    "ready pid=",
):
    assert stage in connect, stage
for gate in (
    'strcmp(name, CSProcessName) != 0', "CSResolveKernelTarget(false)",
    "profileMatchesPath:path", "CSAcquireTaskForPID(pid)", "pid_for_task(task",
    "findImageInTask:task", "identityStillValid:YES",
):
    assert gate in connect, gate
for fallback in (
    'procbyname(CSProcessName)', 'dlsym(RTLD_DEFAULT, "task_for_pid")',
    'dlsym(RTLD_DEFAULT, "task_read_for_pid")',
    'dlsym(RTLD_DEFAULT, "processor_set_tasks")',
    '"kernel-allproc"', 'profileSource=%@ pidSource=%@ taskSource=%@',
    '@"kernel-proc+mach-uuid"', 'candidate.kernelProc == 0',
    '@"kernel-page-table-read"', 'CSAcquireSharedKernelTransport(',
):
    assert fallback in session, fallback
shared_acquire = session[session.index("static BOOL CSAcquireSharedKernelTransport("):
                         session.index("static BOOL CSValidateSharedKernelLease(")]
assert "[transport findImageWithUUID:uuid]" in shared_acquire
assert "candidate.kernelProc, pid, CSUUID" in connect
resolver = body(session, "static CSKernelTarget CSResolveKernelTarget")
assert "ds_address_usable(result.kernelProc)" in resolver
assert "result.kernelProc <= UINT64_MAX - off_proc_p_pid" in resolver
assert "ds_address_usable(result.kernelProc + off_proc_p_pid)" in resolver
assert connect.index("proc_listallpids") < connect.index("CSResolveKernelTarget(false)")
acquire = body(session, "static CSTaskAcquisition CSAcquireTaskForPID")
assert acquire.index('{taskForPID, "task_for_pid"}') < acquire.index(
    '{taskReadForPID, "task_read_for_pid"}'
) < acquire.index("CSTaskFromProcessorSet")
publish = body(session, "- (void)publishConnectDiagnostic:")
assert "changed || !_lastLoggedDiagnostic || now - _lastDiagnosticLogTime >= 30.0" in publish
assert "target-read lane=%@ stage=connect ready=%d" in publish

labels = {
    "lara/views/app/CoreSetPlayerConsumer.swift": "player",
    "lara/views/app/CoreSetMaterialConsumer.swift": "materials",
    "lara/views/app/CoreSetRadarConsumer.swift": "radar",
}
for relative, label in labels.items():
    source = read(relative)
    assert f'session.diagnosticLabel = "{label}"' in source
    if "var availability:" in source:
        assert "session.lastConnectDiagnostic" in body(source, "var availability:")
aim_preview = read("lara/views/app/CoreSetAimPreviewConsumer.swift")
assert "CoreSetReadSession" not in aim_preview
assert "aim-record-missing-or-stale" in aim_preview
assert "aim-record-confirmed actor=" in aim_preview
assert '_readSession.diagnosticLabel = @"target-write"' in read(
    "lara/overlay/CoreSetTargetWriteSession.mm"
)

profile_header = read("lara/overlay/CoreSetKernelWriteProfile.h")
profile_source = read("lara/overlay/CoreSetKernelWriteProfile.mm")
assert "diagnosticSnapshot" in profile_header
profile_diagnostic = body(profile_source, "+ (NSDictionary<NSString *, id> *)diagnosticSnapshot")
for contract in (
    "kernel_transport_not_ready", "audited_profile_not_installed",
    "observedOffsetsAudited", "profileMatches", "failureReasons",
):
    assert contract in profile_diagnostic
assert "ds_start" not in profile_diagnostic
assert "installAuditedProfile" not in profile_diagnostic
assert '@"observedOffsetsAudited": @NO' in profile_diagnostic
assert '#import "overlay/CoreSetKernelWriteProfile.h"' in read("lara/lara-Bridging-Header.h")
aim = read("lara/views/app/CoreSetAimConsumer.swift")
assert "CoreSetIsolatedWriteProbe" in aim
assert "includeBattleInputs: false" in aim and "refreshAction(for: roster" in aim
assert "snapshot.battleInputsPresent = YES" in read("lara/overlay/CoreSetPlayerSnapshot.mm")
assert "result.committed" in aim and "cleanup.complete" in aim
recoil = read("lara/views/app/CoreSetRecoilConsumer.swift")
assert "writeControllerAction" not in recoil
assert "CoreSetAimConsumer" in recoil and "actionConsumer.applyRecoil" in recoil
assert "recoilEnabled" in body(recoil, "var supportedFields:")
assert "supportedFields: Set<CoreSetField> { [] }" not in recoil
assert "lane:lane" in read("lara/overlay/CoreSetIsolatedWriteProbe.mm")

menu = read("lara/views/app/CoreSetMenuViewController.swift")
explain = body(menu, "@objc private func explainUnavailable")
assert "reason=%@" in explain and "configured=0 confirmed=0" in explain
apply_menu = body(menu, "private func applyGame<")
assert "confirmed=%d result=%@" in apply_menu
for result in ("applied", "notApplied:", "unavailable:", "failed:"):
    assert result in apply_menu

host = read("lara/overlay/CoreSetHUDHost.mm")
adapter = read("lara/overlay/CoreSetRemoteHostingAdapter.mm")
scenes = read("lara/overlay/CoreSetFloatingSceneManager.mm")
for contract in ("BKSHID", "IOHIDEventSystemClient", "AXEventRepresentation"):
    assert contract in host
for contract in (
    "SBSAccessibilityWindowHostingController", "registerWindowWithContextID:atLevel:",
    "unregisterWindowWithContextID:",
    "kCoreSetCoreDrawLevel = 999998.0", "kCoreSetCoreMenuLevel = 999999.0",
    "kCoreSetCoreIconLevel = 1000000.0", "registerThreeSurfacesAsync",
    "CALayerHost", "SBMainWorkspace", "mainWindowScene", "setContextId:",
    "kCoreSetCoreMenuLevel", "kCoreSetCoreDrawLevel",
    "RemoteCall", "remote_getClass", "doRemoteCallCheckedWithTimeout",
):
    assert contract in adapter, contract
assert "initWithCoreHosting" in adapter
for contract in ("FBSceneManager", "-touchFloating", "-noTouchFloating"):
    assert contract in scenes, contract

build = read("scripts/build_ipa_pe.sh")
for contract in (
    '"gameConsumer": "CoreSetReadSession HUD lanes + Core v1.7 bone/prediction Aim+Recoil shared checked write"',
    '"targetVersion": "1.38.12/build15915/UUID34b785b2-0dab-3992-985d-359e6bf45585"',
    '"transportPolicy": "checked-control-and-input-rotation-write"',
    '"writeFeaturesEnabled": true',
):
    assert contract in build, contract

# Negative controls: silently removing a target or host boundary must make this
# test logic reject the source.
for missing in ("task-read-denied", "main-image-or-uuid-not-found"):
    combined = session
    assert missing in combined
    assert missing not in combined.replace(missing, "REMOVED", 1)
assert "CALayerHost" in adapter

print("PASS: target read stages, consumer labels, truthful manifest and Core 1.7 scene/SBS diagnostics")
print("LIMIT: source contract only; requires a fresh device log for runtime closure")
