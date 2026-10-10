from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
surface_h = (ROOT / "lara/overlay/CoreSetImGuiMenuSurface.h").read_text(encoding="utf-8")
surface = (ROOT / "lara/overlay/CoreSetImGuiMenuSurface.mm").read_text(encoding="utf-8")
menu = (ROOT / "lara/views/app/CoreSetMenuViewController.swift").read_text(encoding="utf-8")
coordinator = (ROOT / "lara/views/app/CoreSetRuntimeCoordinator.swift").read_text(encoding="utf-8")
project = (ROOT / "lara.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
bridge = (ROOT / "lara/lara-Bridging-Header.h").read_text(encoding="utf-8")

for token in ("CoreSetImGuiMenuModel", "CoreSetImGuiMenuViewController",
              "CoreSetHostedMenuTapConsumer"):
    assert token in surface_h, token
for token in ("ImGui::CreateContext", "ImGui_ImplMetal_Init", "ImGui::NewFrame",
              "ImGui::Begin(\"Core-SET\"", "ImGui::Checkbox", "ImGui::SliderFloat",
              "hostedControlIDAtPoint", "handleHostedControlID"):
    assert token in surface, token
for token in ("extension CoreSetMenuViewController: CoreSetImGuiMenuModel",
              "enableImGuiRuntime()", "imguiMenuSnapshot()", "performImGuiMenuAction"):
    assert token in menu, token
assert "host.contentOwnsLayout = false" in coordinator
assert "menuController: menuSurface" in coordinator
assert "menuController: menu)" not in coordinator
assert 'overlay/CoreSetImGuiMenuSurface.mm' in project
assert 'CoreSetImGuiMenuSurface.mm in Sources' in project
assert '#import "overlay/CoreSetImGuiMenuSurface.h"' in bridge
print("PASS: dedicated ImGui/Metal menu context is the runtime three-window menu surface")
