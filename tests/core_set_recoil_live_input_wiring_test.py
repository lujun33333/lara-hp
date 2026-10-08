from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HEADER = (ROOT / "lara/overlay/CoreSetPlayerSnapshot.h").read_text(encoding="utf-8")
SOURCE = (ROOT / "lara/overlay/CoreSetPlayerSnapshot.mm").read_text(encoding="utf-8")


def test_recoil_snapshot_exposes_exact_post_record_contract():
    for token in (
        "recoilInputsPresent", "recoilBinding", "recoilPostSample",
        "recoilFirstWeight", "recoilFirstBindingScale",
        "recoilSecondWeight", "recoilSecondBindingScale",
        "uint64_t key", "uint64_t ownerToken", "uint8_t active",
        "float value0", "float value1", "float value2",
        "float value3", "float value4", "float value5",
    ):
        assert token in HEADER


def test_recoil_owner_and_scale_reads_match_core_v17_chain():
    for expression in (
        "controller + 0x838", "local + 0xbdc",
        "controller + 0x834", "local + 0xbe0",
        "local + 0x37a0", "first + 0x600",
        "owner + 0x2038", "owner + 0x2048", "key + 0x208",
    ):
        assert expression in SOURCE
    assert "std::array<uint8_t, 0x94>" in SOURCE
    assert "{0x00, 0x04, 0x08, 0x0c, 0x10, 0x4c}" in SOURCE


def test_recoil_input_is_final_pass_optional_and_generation_bound():
    stability = SOURCE.index('CSLastCaptureDiagnostic = "stability-battle-inputs"')
    capture = SOURCE.rindex("CSCaptureRecoilInputs(session, generation")
    completion = SOURCE.index("const double captureCompletedAt = CACurrentMediaTime()", capture)
    publish = SOURCE.index("CoreSetPlayerSnapshot *snapshot = [CoreSetPlayerSnapshot new]", capture)
    assert stability < capture < completion < publish
    assert "local > 0x8000000000ULL - 0x37a8" in SOURCE
    assert "controller > 0x8000000000ULL - 0x83c" in SOURCE
    assert "recoilInputs.present && recoilBinding != 0" in SOURCE
    assert "A missing weapon/action chain is a valid unavailable recoil" in SOURCE
    assert "return nil" not in SOURCE[SOURCE.index("static bool CSCaptureRecoilInputs"):SOURCE.index("static bool CSCorePlayerSpeedMatches")]


def test_geometry_exposes_exact_next_frame_recoil_key():
    header = (ROOT / "lara/overlay/CoreSetIsolatedWriteProbe.h").read_text(encoding="utf-8")
    source = (ROOT / "lara/overlay/CoreSetIsolatedWriteProbe.mm").read_text(encoding="utf-8")
    assert "geometrySampleKey" in header
    assert "std::memcpy(&sampleKey, observed.numerical.data(), sizeof(sampleKey))" in source
    assert "result.geometrySampleKey = sampleKey" in source


def test_shared_recoil_dynamics_preserves_core_order_and_constants():
    header = (ROOT / "lara/overlay/CoreSetIsolatedWriteProbe.h").read_text(encoding="utf-8")
    source = (ROOT / "lara/overlay/CoreSetIsolatedWriteProbe.mm").read_text(encoding="utf-8")
    assert "CoreSetV17RecoilDynamics" in header
    for token in (
        "referenceActionPostState(_post", "stepRecoilRawState(&_raw",
        "referenceActionRecoilCallerMerge", "mergeAimRecoilDeltas",
        "referenceActionPriorAimFeedback", "raw.combined",
        "post.values[2]", "post.values[5]",
        "tuning.firstLimit = 1.5f", "tuning.deadzone = 0.0005000000237487257f",
        "tuning.quietFrameLimit = 6", "tuning.secondLimitScale = 1.0f",
    ):
        assert token in source
    assert source.index("referenceActionPostState(_post") < source.index("stepRecoilRawState(&_raw")
    assert source.index("stepRecoilRawState(&_raw") < source.index("referenceActionRecoilCallerMerge")
    assert source.index("referenceActionRecoilCallerMerge") < source.index("return finish(recoilPitch, recoilYaw)")


def test_recoil_and_aim_use_one_serial_worker_and_dynamic_slot_route():
    aim = (ROOT / "lara/views/app/CoreSetAimConsumer.swift").read_text(encoding="utf-8")
    recoil = (ROOT / "lara/views/app/CoreSetRecoilConsumer.swift").read_text(encoding="utf-8")
    coordinator = (ROOT / "lara/views/app/CoreSetRuntimeCoordinator.swift").read_text(encoding="utf-8")
    menu = (ROOT / "lara/views/app/CoreSetMenuViewController.swift").read_text(encoding="utf-8")
    for token in (
        "CoreSetV17RecoilDynamics", "submitMergedAction", "tickRecoilOnly",
        "CoreSetV17ActionRouteDynamics", "routeDynamics.useControlRotation",
        "? .controlRotation : .rotationInput", "routeDynamics.observeCommitted",
        "observeCommittedRoute(w20: !inputPaused)", "lane: lane",
        "pendingRecoilCompletion", "stopRecoil(",
        "merged.recoilPitch", "merged.recoilYaw", "recoilContributed",
        "aimContributed",
        "共享动作旧映射清理待确认", "压枪同步终止",
    ):
        assert token in aim, token
    assert "actionConsumer.applyRecoil" in recoil
    assert "actionConsumer.stopRecoil" in recoil
    assert "supportedFields: Set<CoreSetField> { [] }" not in recoil
    assert "CoreSetRecoilConsumer(actionConsumer: aimConsumer)" in coordinator
    assert "apply(\\.recoil)" in menu
    assert "editGame(\\.recoil)" in menu
    route = (ROOT / "lara/overlay/CoreSetIsolatedWriteProbe.mm").read_text(encoding="utf-8")
    assert "_state.observeResult(1, CoreSet::RouteResultGate::lowBit, w20)" in route
    assert "_state.modeFlag && !_state.alternate" in route
