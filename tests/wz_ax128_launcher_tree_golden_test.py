"""Static UIView/CALayer tree golden for the AX 1.2.8 launcher replica."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "lara" / "views" / "app" / "ContentView.swift"
source = SOURCE.read_text(encoding="utf-8")


TREE = {
    "UIViewController.view": {
        "runtimeClass": "BYG6trFgTr5X",
        "layers": [
            "baseGradientLayer",
            "auroraTopLayer[compositingFilter=screen]",
            "auroraBottomLayer[compositingFilter=screen]",
            "starLayer[34 CAShapeLayer children]",
        ],
        "subviews": ["cardView"],
    },
    "cardView": {
        "subviews": ["cardHighlightView", "stackView"],
        "layout": "leading=22,trailing=-22,centerY=-12,safeTop>=18,safeBottom<=-18",
    },
    "cardHighlightView": {
        "runtimeClass": "AXGradientTintView",
        "layers": ["CAGradientLayer backing layer"],
        "frame": "x=0,y=0,width=card.width,height=44",
    },
    "stackView": {
        "arrangedSubviews": [
            "titleLabel",
            "versionLabel",
            "separatorView",
            "supportCard",
            "activationField",
            "activationButton",
            "statusCard",
            "spacerView",
            "launchButton",
            "progressContainer",
        ],
        "layout": "top=22,leading=20,trailing=-20,bottom=-22,axis=vertical,spacing=12",
    },
    "separatorView": {"subviews": ["ruleView[AXGradientTintView/CAGradientLayer]"]},
    "activationButton": {"runtimeClass": "AXGradientButton"},
    "launchButton": {"runtimeClass": "AXGradientButton"},
    "supportCard": {
        "subviews": ["supportStack[supportTitleLabel,supportStatusLabel]"],
        "insets": "12,14,12,14",
    },
    "statusCard": {
        "subviews": ["statusStack[statusTitleLabel,statusLabel,expiryLabel]"],
        "insets": "13,14,13,14",
    },
    "progressContainer": {
        "subviews": ["progressLabel", "progressView"],
        "layout": "label.top=0,progress.top=label.bottom+8,progress.height=4",
    },
}


canonical = json.dumps(TREE, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
actual_hash = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
EXPECTED_HASH = "f21e1c8e9e9ece247a8a645f22d32c2e426e334de08a73de22e148dbd423ba75"
assert actual_hash == EXPECTED_HASH, actual_hash


TOKENS = [
    'view.layer.insertSublayer(baseGradientLayer, at: 0)',
    'view.layer.insertSublayer(auroraTopLayer, above: baseGradientLayer)',
    'view.layer.insertSublayer(auroraBottomLayer, above: auroraTopLayer)',
    'view.layer.insertSublayer(starLayer, above: auroraBottomLayer)',
    'auroraTopLayer.compositingFilter = "screen"',
    'auroraBottomLayer.compositingFilter = "screen"',
    'view.addSubview(cardView)',
    'cardView.addSubview(cardHighlightView)',
    '@objc(BYG6trFgTr5X)',
    '@objc(AXGradientButton)',
    '@objc(AXGradientTintView)',
    'override class var layerClass: AnyClass { CAGradientLayer.self }',
    'private let cardHighlightView = AXLauncherGradientTintView()',
    'private let ruleView = AXLauncherGradientTintView()',
    'private let activationButton = AXLauncherGradientButton(type: .system)',
    'private let launchButton = AXLauncherGradientButton(type: .system)',
    'cardView.addSubview(stackView)',
    'supportCard.addSubview(supportStack)',
    'statusCard.addSubview(statusStack)',
    'progressContainer.addSubview(progressLabel)',
    'progressContainer.addSubview(progressView)',
    'cardView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22)',
    'cardView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22)',
    'cardView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -12)',
    'stackView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 22)',
    'stackView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20)',
    'stackView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20)',
    'stackView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -22)',
    'activationField.heightAnchor.constraint(equalToConstant: 48)',
    'activationButton.heightAnchor.constraint(equalToConstant: 52)',
    'launchButton.heightAnchor.constraint(equalToConstant: 52)',
    'progressContainer.heightAnchor.constraint(equalToConstant: 34)',
    'progressView.heightAnchor.constraint(equalToConstant: 4)',
    'for index in 0..<34',
    'CABasicAnimation(keyPath: "opacity")',
    'star.add(twinkle, forKey: "twinkle")',
]
for token in TOKENS:
    assert token in source, token


arranged = source.split("let arrangedSubviews: [UIView] = [", 1)[1].split("]", 1)[0]
previous = -1
for name in TREE["stackView"]["arrangedSubviews"]:
    position = arranged.find(name)
    assert position > previous, name
    previous = position

assert "screenBlendMode" not in source
assert "UITextFieldDelegate" not in source
assert "activationField.delegate" not in source
assert "textFieldShouldReturn" not in source
assert "override func viewDidAppear" not in source
view_did_load = source.split("override func viewDidLoad() {", 1)[1].split(
    "override func viewDidLayoutSubviews", 1
)[0]
assert view_did_load.count("bootstrapEnvironmentIfNeeded()") == 1
assert view_did_load.index("updatePresentation()") < view_did_load.index(
    "bootstrapEnvironmentIfNeeded()"
)

print(f"PASS: AX launcher UIView/CALayer tree golden {actual_hash}")
