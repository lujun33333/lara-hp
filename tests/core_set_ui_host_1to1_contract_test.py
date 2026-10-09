from pathlib import Path
import hashlib
import struct
import zipfile

import capstone


ROOT = Path(__file__).resolve().parents[1]
REFERENCE_IPA = ROOT.parent / "源码 - 和平" / "自签Core-SET和平-v1.7.ipa"
MENU = (ROOT / "lara/views/app/CoreSetMenuViewController.swift").read_text(encoding="utf-8")
COORDINATOR = (ROOT / "lara/views/app/CoreSetRuntimeCoordinator.swift").read_text(encoding="utf-8")
STATE = (ROOT / "lara/views/app/CoreSetFeatureState.swift").read_text(encoding="utf-8")


def reference_image() -> bytes:
    with zipfile.ZipFile(REFERENCE_IPA) as archive:
        return archive.read("Payload/Core.app/Core")


def function_body(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    for index in range(opening + 1, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1:index]
    raise AssertionError(signature)


def test_reference_identity_geometry_and_default_font_are_bound():
    image = reference_image()
    assert hashlib.sha256(image).hexdigest() == "c842be92434b88b4d535d0d10a30ace068ce6b9a7b9a97ec5a6ca8fd97fa3dd5"
    assert struct.unpack_from("<2f", image, 0x8A9F80) == (838.0, 535.0)
    assert struct.unpack_from("<2f", image, 0x8A9F50) == (658.0, 160.0)
    assert struct.unpack_from("<2f", image, 0x8A9F58) == (230.0, 145.0)

    decoder = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
    font_init = list(decoder.disasm(image[0xCB32C:0xCB4DC], 0x1000CB32C))
    operands = {(instruction.mnemonic, instruction.op_str) for instruction in font_init}
    for size in ("#16.00000000", "#19.00000000", "#25.00000000"):
        assert ("fmov", f"s0, {size}") in operands
    assert any(instruction.mnemonic == "fmov" and instruction.op_str == "s0, w8"
               for instruction in font_init), "60pt font is materialized through w8=0x42700000"


def test_uikit_uses_reference_panel_card_and_body_metrics():
    for token in (
        "referenceSize = CGSize(width: 838, height: 535)",
        'card("Core稳定自瞄", CGRect(x: 0, y: 0, width: 658, height: 160))',
        "CGRect(x: 0, y: 0, width: 230, height: 145)",
        "CGRect(x: 250, y: 0, width: 400, height: 145)",
        "CGRect(x: 0, y: 188, width: 323, height: lowerHeight)",
        "let lowerHeight: CGFloat = custom ? 315 : 220",
        'card("Core智能压枪【非无后坐力】", CGRect(x: 0, y: 0, width: 658, height: 474))',
        "let caption = label(title, size: 16",
        "button.titleLabel?.font = font(19)",
        "result.addSubview(label(title, size: 17",
        'label("C", size: 36',
        'label("ORE", size: 36',
        'label("SET", size: 11',
    ):
        assert token in MENU, token
    assert 'panel.addSubview(configurationFeedbackLabel)' not in MENU
    assert 'sidebar.addSubview(exitHUDButton)' not in MENU
    assert "let caption = label(title, size: 12" not in MENU
    assert 'note.accessibilityHint = "原版说明文案，当前功能尚未接入"' not in MENU


def test_aim_recoil_controls_and_cross_window_share_live_receipts():
    proof = function_body(MENU, "private func updateControlProof(")
    assert "case .aimControl: evidence = proof(featureState.aim)" in proof
    assert "case .recoilControl: evidence = proof(featureState.recoil)" in proof
    stop = function_body(MENU, "func suspendActionConsumers(")
    assert "stop(\\.aim)" in stop and "stop(\\.recoil)" in stop
    resume = function_body(MENU, "func resumeActionConsumers(")
    assert "featureState.aim.resume()" in resume
    assert "featureState.recoil.resume()" in resume
    for signature in ("private func installHostedWindows(", "func deactivate()", "private func hostChanged()"):
        body = function_body(COORDINATOR, signature)
        assert "suspendActionConsumers" in body
    assert "case .aimControl:" in STATE and "case .recoilControl:" in STATE


def test_reference_controls_have_values_without_uikit_only_unselected_gate():
    aim = function_body(STATE, "struct CoreSetAimSettings:")
    for token in ("point = .head", "trigger = .either", "scene = .far",
                  "lockStrength = .light", "circleSize.set(circleSize.bounds.lowerBound)"):
        assert token in aim, token
    recoil = function_body(STATE, "struct CoreSetRecoilSettings:")
    for token in ("stopWhenNotFiring.enabled = true", "verticalEnabled = false",
                  "horizontalEnabled = false", "verticalStrength.set(", "horizontalStrength.set("):
        assert token in recoil, token
