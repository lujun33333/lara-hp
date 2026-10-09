from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MENU = (ROOT / "lara/views/app/CoreSetMenuViewController.swift").read_text(encoding="utf-8")


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


def test_hosted_reference_panel_recenters_when_source_viewport_changes():
    body = function_body(MENU, "override func viewDidLayoutSubviews()")
    assert "let viewport = hostedExitAvailable ? view.bounds" in body
    assert "let viewportChanged = panelLayoutViewport != viewport" in body
    assert "if !panelPlacementInitialized || viewportChanged" in body
    assert "panel.center = CGPoint(x: viewport.midX, y: viewport.midY)" in body
    assert "panelLayoutViewport = viewport" in body


def test_reference_size_and_drag_clamp_share_the_same_viewport():
    assert "referenceSize = CGSize(width: 838, height: 535)" in MENU
    drag = function_body(MENU, "@objc private func moveReferencePanel(")
    assert "let viewport = hostedExitAvailable ? view.bounds" in drag
    assert "in: viewport, scale: panelScale" in drag
