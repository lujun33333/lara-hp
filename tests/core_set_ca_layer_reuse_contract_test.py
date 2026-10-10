from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "lara/overlay/CoreSetRenderCommands.mm").read_text(encoding="utf-8")


def body(signature: str) -> str:
    start = SOURCE.index(signature)
    opening = SOURCE.index("{", start)
    depth = 1
    for index in range(opening + 1, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[opening + 1:index]
    raise AssertionError(signature)


def test_cross_application_ca_reuses_command_containers():
    consumer = SOURCE[SOURCE.index("@implementation CoreSetCoreAnimationConsumer"):]
    for token in (
        "NSMutableArray<CALayer *> *_commandLayers",
        "while (_commandLayers.count < frame.commands.count)",
        "CALayer *container = _commandLayers[index++]",
        "CSConfigureCommandContainer(container, command, size, scale)",
        "_root.sublayers = layers",
    ):
        assert token in consumer, token
    assert "NSMutableArray<CALayer *> *layers = [NSMutableArray arrayWithCapacity:frame.commands.count]" in consumer


def test_reuse_is_type_stable_and_clear_discards_old_identity():
    reset = body("static void CSResetCommandContainer(")
    assert "[container.name isEqualToString:signature]" in reset
    assert "container.sublayers = nil" in reset
    assert "container.name = signature" in reset
    configure = body("static BOOL CSConfigureCommandContainer(")
    for token in ("CAGradientLayer", "CATextLayer", "CAShapeLayer",
                  "CSBackGlyphLayer(command)", "container.frame"):
        assert token in configure, token
    clear = body("- (void)clear")
    assert "_root.sublayers = nil" in clear
    assert "[_commandLayers removeAllObjects]" in clear
