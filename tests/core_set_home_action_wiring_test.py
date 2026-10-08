from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MENU = (ROOT / "lara/views/app/CoreSetMenuViewController.swift").read_text(encoding="utf-8")
COORDINATOR = (ROOT / "lara/views/app/CoreSetRuntimeCoordinator.swift").read_text(encoding="utf-8")
PRODUCER = (ROOT / "lara/views/app/CoreSetHomeRuntimeProducer.swift").read_text(encoding="utf-8")
LIFECYCLE = (ROOT / "lara/overlay/CoreSetHUDLifecycle.h").read_text(encoding="utf-8")


def body(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    for index in range(opening + 1, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[opening + 1:index]
    raise AssertionError(signature)


def test_home_buttons_dispatch_real_local_action_owners():
    for token in (
        "var onHomeAction:", ".homeKernelAction", ".homeInformationAction",
        "startHomeKernelAction", "startHomeInformationAction",
        "action.isEnabled = onHomeAction != nil",
    ):
        assert token in MENU, token
    binding = body(COORDINATOR, "init(scene:")
    assert "menu.onHomeAction =" in binding
    dispatch = body(COORDINATOR, "private func performHomeAction(")
    assert "performHomeKernelAction" in dispatch
    assert "performHomeInformationAction" in dispatch


def test_kernel_and_information_actions_publish_typed_lifecycle_results():
    kernel = body(COORDINATOR, "private func performHomeKernelAction(")
    for token in ("init_offsets()", "offsets_init()", "manager.run",
                  ".kernelAction, phase: .requested", ".kernelAction, phase: .running",
                  "ready ? .completed : .failed"):
        assert token in kernel, token
    information = body(COORDINATOR, "private func performHomeInformationAction(")
    for token in ("beginResolve()", "fetchkcache()", "fetched && dlkcache()",
                  "completeValidation()", "failValidation",
                  ".informationAction, phase: .requested",
                  ".informationAction, phase: .running",
                  "loaded ? .completed : .failed"):
        assert token in information, token
    receipt = body(COORDINATOR, "private func recordHomeAction(")
    for token in ("producerEpoch: homeActionProducerEpoch", "requestID: request",
                  "sequence: sequence", "observedStatus: status", "errorCode: errorCode"):
        assert token in receipt, token


def test_home_status_uses_action_owner_state_and_hosted_metal_stays_live():
    observation = body(PRODUCER, "func readObservation(hostGeneration:")
    assert "let information = CoreSetKernelInformationOwner.shared.snapshot()" in observation
    assert "manager.hasOffsets && information.status == 2" in observation
    assert "firmware.phase == 6 || information.status == 3" in observation
    assert "return metalAvailable && (foreground || crossApplicationHosted)" in LIFECYCLE

