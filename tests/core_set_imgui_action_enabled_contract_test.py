"""Changed-path cost/disabled source contract; actual widgets run in the C++ test."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "lara/views/app/CoreSetMenuViewController.swift").read_text(encoding="utf-8")


def body(signature: str) -> str:
    opening = source.index("{", source.index(signature))
    depth = 1
    for index in range(opening + 1, len(source)):
        if source[index] == "{": depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0: return source[opening + 1:index]
    raise AssertionError(signature)


enabled = body("private func imguiActionEnabled(")
enabled = "\n".join(line.split("//", 1)[0] for line in enabled.splitlines())
for forbidden in ("imguiMenuSnapshot", "updateConsumerAvailability", "pages", "sections", "items", "for "):
    assert forbidden not in enabled, forbidden
assert "switch selectedPage" in enabled and "default: return false" in enabled
for prefix in ("home.", "player.", "material.", "adjust.", "radar.", "aim.", "recoil."):
    assert f'hasPrefix("{prefix}")' in enabled, prefix
for live in ("imguiChannelReady(featureState.frameRate)",
             "!homeActionsInFlight.contains(.kernelAction)",
             "!homeActionsInFlight.contains(.informationAction)",
             "featureState.aim.restoration != .pending", "guard imguiAimEditable else",
             "featureState.aim.desired.scene == .custom",
             "featureState.aim.desired.scene != .custom"):
    assert live in enabled, live
assert "let aimEditable = imguiAimEditable" in body("func imguiMenuSnapshot()")
dispatcher = body("func performImGuiMenuAction(")
assert dispatcher.index("guard imguiActionEnabled(action)") < dispatcher.index("switch action")
assert "imguiMenuSnapshot" not in dispatcher
print("PASS: current-page live enabled guard has no menu reconstruction/consumer refresh or table walk")
