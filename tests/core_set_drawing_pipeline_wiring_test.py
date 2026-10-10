from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "lara/views/app"
COORDINATOR = (APP / "CoreSetRuntimeCoordinator.swift").read_text(encoding="utf-8")
STATE = (APP / "CoreSetFeatureState.swift").read_text(encoding="utf-8")
HOST = (ROOT / "lara/overlay/CoreSetHUDHost.mm").read_text(encoding="utf-8")
LIFECYCLE = (ROOT / "lara/overlay/CoreSetHUDLifecycle.h").read_text(encoding="utf-8")
RENDER = (ROOT / "lara/overlay/CoreSetRenderCommands.mm").read_text(encoding="utf-8")


def read(name: str) -> str:
    return (APP / name).read_text(encoding="utf-8")


def test_all_reference_drawing_consumers_share_one_composer_and_receipt_path():
    bindings = {
        "CoreSetPlayerConsumer.swift": ("playerConsumer", "\\.player", ".player",
                                        "CoreSetPlayerConsumer(coordinator: self, battleProducer: battleProducer)"),
        "CoreSetMaterialConsumer.swift": ("materialConsumer", "\\.materials", ".materials", None),
        "CoreSetAdjustmentConsumer.swift": ("adjustmentConsumer", "\\.adjustments", ".appearance", None),
        "CoreSetRadarConsumer.swift": ("radarConsumer", "\\.radar", ".radar", None),
        "CoreSetFrameRateConsumer.swift": ("frameRateConsumer", "\\.frameRate", None, None),
        "CoreSetAimDisplayConsumer.swift": ("aimDisplayConsumer", "\\.aimDisplay", ".aimDisplay", None),
    }
    for file, (owner, channel, lane, initializer) in bindings.items():
        source = read(file)
        expected = initializer or f"{file.removesuffix('.swift')}(coordinator: self)"
        assert f"{owner} = {expected}" in COORDINATOR
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
    assert "CoreSetCoreAnimationConsumer *_layers" in HOST
    assert "[_layers attachToView:_drawCanvas]" in HOST
    assert "[_layers setVisible:_activeBackend == CoreSetHUDBackendCoreAnimation]" in HOST
    assert "id<CoreSetFrameConsumer> consumer = host->_activeBackend == CoreSetHUDBackendMetal" in HOST
    assert "? host->_metal : host->_layers" in HOST
    assert "host.frameDidConsume(frame, YES, nil)" in HOST
    assert "hostedRegistrationReceipt" in HOST
    assert "hosted draw stage=consumer accepted=1" in HOST
    assert "CSEnableHostedLayerUpdates(_root)" in RENDER
    assert "[CATransaction flush]" in RENDER


def test_required_drawing_capabilities_remain_field_complete():
    for capability in ("playerRendering", "materialFiltering", "drawingAppearance",
                       "radarRendering", "frameScheduling", "localAimDisplay"):
        assert f"case .{capability}:" in STATE

