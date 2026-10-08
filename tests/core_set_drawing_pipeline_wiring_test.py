from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "lara/views/app"
COORDINATOR = (APP / "CoreSetRuntimeCoordinator.swift").read_text(encoding="utf-8")
STATE = (APP / "CoreSetFeatureState.swift").read_text(encoding="utf-8")
HOST = (ROOT / "lara/overlay/CoreSetHUDHost.mm").read_text(encoding="utf-8")
LIFECYCLE = (ROOT / "lara/overlay/CoreSetHUDLifecycle.h").read_text(encoding="utf-8")


def read(name: str) -> str:
    return (APP / name).read_text(encoding="utf-8")


def test_all_reference_drawing_consumers_share_one_composer_and_receipt_path():
    bindings = {
        "CoreSetPlayerConsumer.swift": ("playerConsumer", "\\.player", ".player"),
        "CoreSetMaterialConsumer.swift": ("materialConsumer", "\\.materials", ".materials"),
        "CoreSetAdjustmentConsumer.swift": ("adjustmentConsumer", "\\.adjustments", ".appearance"),
        "CoreSetRadarConsumer.swift": ("radarConsumer", "\\.radar", ".radar"),
        "CoreSetFrameRateConsumer.swift": ("frameRateConsumer", "\\.frameRate", None),
        "CoreSetAimDisplayConsumer.swift": ("aimDisplayConsumer", "\\.aimDisplay", ".aimDisplay"),
    }
    for file, (owner, channel, lane) in bindings.items():
        source = read(file)
        assert f"{owner} = {file.removesuffix('.swift')}(coordinator: self)" in COORDINATOR
        assert f"to: {channel}" in COORDINATOR
        assert "var supportedFields: Set<CoreSetField>" in source
        assert ".applied(observed:" in source
        assert "func stop(" in source
        if lane:
            assert f"lane: {lane}" in source or f"clearLane({lane}" in source
    for owner in ("playerConsumer", "materialConsumer", "radarConsumer",
                  "adjustmentConsumer", "aimDisplayConsumer"):
        assert f"self.{owner}?.consumed(receipt)" in COORDINATOR


def test_draw_surface_uses_retained_ca_when_remotely_hosted():
    assert "return foreground && metalAvailable && !crossApplicationHosted" in LIFECYCLE
    assert "id<CoreSetFrameConsumer> consumer = host->_activeBackend == CoreSetHUDBackendMetal" in HOST
    assert "host.frameDidConsume(frame, YES, nil)" in HOST
    assert "hostedRegistrationReceipt" in HOST


def test_required_drawing_capabilities_remain_field_complete():
    for capability in ("playerRendering", "materialFiltering", "drawingAppearance",
                       "radarRendering", "frameScheduling", "localAimDisplay"):
        assert f"case .{capability}:" in STATE

