from hashlib import sha256
from pathlib import Path
import struct
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
REFERENCE_IPA = ROOT.parent / "源码 - 和平" / "自签Core-SET和平-v1.7.ipa"


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class CoreSetFontLayoutContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.header = read("lara/overlay/CoreSetRenderCommands.h")
        cls.render = read("lara/overlay/CoreSetRenderCommands.mm")
        cls.metal = read("lara/overlay/CoreSetMetalRenderAdapter.mm")
        cls.player = read("lara/views/app/CoreSetPlayerConsumer.swift")
        cls.snapshot_header = read("lara/overlay/CoreSetPlayerSnapshot.h")
        cls.snapshot = read("lara/overlay/CoreSetPlayerSnapshot.mm")
        cls.radar = read("lara/views/app/CoreSetRadarConsumer.swift")
        with zipfile.ZipFile(REFERENCE_IPA) as archive:
            cls.reference_image = archive.read("Payload/Core.app/Core")

    def test_extracted_fonts_are_identity_bound_to_core_v17(self) -> None:
        body = (ROOT / "lara/CoreSetAssets/OPPOSans-H.ttf").read_bytes()
        icons = (ROOT / "lara/CoreSetAssets/IcoMoon.ttf").read_bytes()
        self.assertEqual(sha256(body).hexdigest(),
                         "cdfdaf7dbadaccdef6186cf806f50681016398065f97cd0dcadcb3a5398a502a")
        self.assertEqual(sha256(icons).hexdigest(),
                         "40422bc0623058e64df49907026fc4913ad871bb0231559f41c1a1bd137545a4")
        self.assertEqual(self.reference_image.find(body), 0x8A9FF8)
        self.assertEqual(self.reference_image.find(icons), 0xBD9A18)

    def test_warning_layout_constants_and_three_layers_are_exact_core_bytes(self) -> None:
        expected_floats = {
            0xAC8314: 0x3FC28F5C,  # 1.52 row step
            0xAC8318: 0x3E0F5C29,  # 0.14 top anchor
            0xAC8320: 0x3E75C28F,  # 0.24 outer horizontal padding
            0x8A9E6C: 0x3E23D70A,  # 0.16 outer vertical padding
            0x8A9E5C: 0x3E6147AE,  # 0.22 rounded corner scalar
            0xAC8324: 0x3CCCCCCD,  # 0.025 border scalar
            0xAC8328: 0x3D6147AE,  # 0.055 accent width scalar
            0xAC832C: 0x3F947AE1,  # 1.16 lower edge
        }
        for offset, word in expected_floats.items():
            self.assertEqual(struct.unpack_from("<I", self.reference_image, offset)[0], word)
        # mov w3,#0x100c; movk w3,#0x9618,lsl#16 => ImGui RGBA 12,16,24,150.
        self.assertEqual(struct.unpack_from("<II", self.reference_image, 0xDDC4C),
                         (0x52820183, 0x72B2C303))
        # border RGBA=255,120,132,105; accent RGBA=255,92,108,235.
        self.assertEqual(struct.unpack_from("<II", self.reference_image, 0xDDC6C),
                         (0x528F1FE3, 0x72AD3083))
        self.assertEqual(struct.unpack_from("<II", self.reference_image, 0xDDCAC),
                         (0x528B9FE3, 0x72BD6D83))

    def test_information_simple_and_modern_layouts_are_exact_core_bytes(self) -> None:
        instructions = {
            0xDBCA8: 0x34000A99,  # mode 0 -> modern branch
            0xDBF7C: 0x1E24D001,  # simple font scalar 11
            0xDC00C: 0x1E221002,  # simple gap scalar 4
            0xDC01C: 0x52A84B08,  # minimum health width 54
            0xDC03C: 0x1E371000,  # simple y offset -24
            0xDC0E4: 0xBD424660,  # candidate health at draw record +0x244
            0xDC0E8: 0x52A85908,  # health divisor 100
            0xDC110: 0x1E209001,  # simple health height 2.5
            0xDC3E4: 0x1E251000,  # modern font scalar 12
            0xDC41C: 0x1E25D003,  # modern badge inner height 15
            0xDC424: 0x1E211001,  # modern extra width scalar 3
            0xDC42C: 0x1E221002,  # modern gap/radius scalar 4
            0xDC438: 0x52A85688,  # modern minimum width 90
            0xDC498: 0x1E349001,  # modern top y offset -10 after 18-height block
        }
        for offset, word in instructions.items():
            self.assertEqual(struct.unpack_from("<I", self.reference_image, offset)[0], word)
        colors = {
            0xDC158: (0x52846463, 0x72B7C463),  # simple background 35,35,35,190
            0xDC18C: (0x52875FE3, 0x72BEA743),  # simple low HP
            0xDC1A8: (0x5292DFE3, 0x72BEA3C3),  # simple medium HP
            0xDC31C: (0x529EBEA3, 0x72BEBEA3),  # simple high HP
            0xDC688: (0x52850503, 0x72BFE503),  # modern background 40,40,40,255
            0xDC6E0: (0x52865FE3, 0x72BFE643),  # modern low HP
            0xDC6FC: (0x52919FE3, 0x72BFE003),  # modern medium HP
        }
        for offset, words in colors.items():
            self.assertEqual(struct.unpack_from("<II", self.reference_image, offset), words)
        self.assertEqual(struct.unpack_from("<I", self.reference_image, 0xDC708)[0], 0x12800003)
        self.assertEqual(struct.unpack_from("<f", self.reference_image, 0x8A9A88)[0],
                         0.30000001192092896)
        self.assertEqual(struct.unpack_from("<f", self.reference_image, 0xAC8308)[0],
                         0.699999988079071)
        self.assertEqual(struct.unpack_from("<8I", self.reference_image, 0xAC8678), (
            0xFF6464FF, 0xFFFFC864, 0xFF64FF64, 0xFF64C8FF,
            0xFFFF64FF, 0xFF64FFFF, 0xFFC8FF64, 0xFFFF64C8,
        ))
        for offset, literal in ((0x7448B5, "人机"), (0x7448BC, "未知玩家"),
                                (0x7448C9, "【人机】"),
                                (0x7448D6, "人机%d【人机】")):
            self.assertTrue(self.reference_image[offset:].startswith(literal.encode("utf-8") + b"\0"))

    def test_information_anchor_scale_and_frame_ordinal_producers_are_closed(self) -> None:
        instructions = {
            0x21BB0: 0xF0005DA8,  # adrp x8, scale literal page
            0x21BB4: 0xBD4B2100,  # ldr s0,[x8,#0xb20], literal owner
            0x21BB8: 0xBD0002E0,  # str s0,[x23], draw-context scale producer
            0xDB190: 0xB908B2FF,  # player frame ordinal reset
            0xDB198: 0xB908B79F,  # bot frame ordinal reset
            0xDBB54: 0x39490268,  # draw record bot flag
            0xDBB5C: 0xB948B788,  # bot ordinal load
            0xDBB64: 0xB908B788,  # bot ordinal publish
            0xDBCA0: 0x2D462D2E,  # draw record +0x30/+0x34 anchor
        }
        for offset, word in instructions.items():
            self.assertEqual(struct.unpack_from("<I", self.reference_image, offset)[0], word)
        self.assertEqual(struct.unpack_from("<I", self.reference_image, 0xBD8B20)[0],
                         0x3F800000)
        for token in ("informationAnchorPresent", "informationAnchor",
                      "wantsBoneProducer", "wantsInformationProducer",
                      "wantsInformationAnchor && onScreen",
                      "CSPublishAimAnchors(mark, bones, camera, size)",
                      "CSPublishAimAnchors(mark, finalBone, cameraAfter, size)",
                      "CSPublishAimAnchors(mark, bone.state, cameraAfter, size)"):
            self.assertIn(token, self.snapshot_header + self.snapshot)
        self.assertIn("mark.informationAnchorPresent", self.player)
        self.assertIn("anchor: mark.informationAnchor", self.player)
        self.assertNotIn("mode: mode, head: head", self.player)
        self.assertNotIn("guard appendCoreInformation", self.player)
        self.assertIn("_ = appendCoreInformation", self.player)

    def test_back_glyph_style_five_is_separate_from_information_health(self) -> None:
        instructions = {
            0xDBECC: 0x54001820,  # back-indicator geometry joins the glyph tail
            0xDBEE4: 0x5400168D,
            0xDC1D0: 0x0AB47E82,  # sanitize back-glyph style
            0xDC200: 0x97FFDF5C,  # call glyph helper 0x1000d3f70
            0xDC194: 0x14000064,  # low health skips the glyph tail -> 0x1000dc324
            0xDC1B0: 0x1400005D,  # medium health skips it too
            0xDC31C: 0x529EBEA3,  # high-health color falls through at 0x1000dc324
            0xDC320: 0x72BEBEA3,
            0xDC324: 0x1E202188,
            0xD3FC0: 0x7100145F,  # clamp style to <=5
            0xD3FC8: 0x1A883048,
            0xD3FCC: 0x7100005F,  # clamp style to >=0
            0xD3FD0: 0x1A88B3F5,
            0xD4168: 0x710012BF,  # style 5 selects the final procedural branch
            0xD416C: 0x54002BC1,
            0xD4788: 0xF10036BF,  # first 13-point loop
            0xD4834: 0xF10036BF,  # second 13-point loop
            0xD4944: 0x52800062,  # final three-point primitive
        }
        for offset, word in instructions.items():
            self.assertEqual(struct.unpack_from("<I", self.reference_image, offset)[0], word)

    def test_render_command_carries_explicit_body_and_icon_roles(self) -> None:
        for token in ("CoreSetRenderFontRoleBody", "CoreSetRenderFontRoleIcon",
                      "fontRole", "usingFontRole", "backedTextWithColor",
                      "cornerRadius", "roundedWithRadius",
                      "gradientLeftColor", "horizontalGradientFromColor"):
            self.assertIn(token, self.header)
        self.assertIn('CSBodyFontName = @"OPPOSans-H"', self.render)
        self.assertIn('CSIconFontName = @"icomoon"', self.render)
        self.assertIn('@"acersvwxz"', self.render)
        self.assertIn("command.cornerRadius > 256", self.metal)
        self.assertIn("command.kind != CoreSetRenderKindRectangle && command.cornerRadius != 0", self.metal)
        self.assertIn("AddRectFilledMultiColor", self.metal)
        self.assertIn("left, right, right, left", self.metal)
        self.assertNotIn("UIFont *font = [UIFont systemFontOfSize:command.fontSize]", self.render)

    def test_ca_and_metal_use_the_same_selected_font_and_background_order(self) -> None:
        for token in ('pathForResource:@"OPPOSans-H"', 'pathForResource:@"IcoMoon"',
                      "AddFontFromFileTTF(fontPath.UTF8String, 25.0f",
                      "AddFontFromFileTTF(iconPath.UTF8String, 25.0f",
                      "command.fontRole == CoreSetRenderFontRoleIcon ? _iconFont : _font"):
            self.assertIn(token, self.metal)
        self.assertLess(self.metal.index("draw->AddRectFilled(ImVec2(pos.x - horizontal"),
                        self.metal.index("draw->AddText(font, (float)command.fontSize"))
        self.assertLess(self.render.index("[layers addObject:background]"),
                        self.render.index("[layers addObject:text]"))

    def test_information_uses_two_native_layouts_name_and_separate_health(self) -> None:
        for token in ('UIFont(name: "OPPOSans-H", size: fontSize)',
                      "private func appendCoreInformation", "if mode == .minimal",
                      "let fontSize = 11 * scale", "let fontSize = 12 * scale",
                      "let textY = topY - 24 * scale", "let cardY = topY - 28 * scale",
                      "let scale = coreInformationFrameScale()",
                      "anchor: mark.informationAnchor",
                      "let anchorX = anchor.x", "let topY = anchor.y",
                      "CGFloat(Float(bitPattern: 0x3f800000))",
                      "var botInformationFrameOrdinal = 0",
                      "botInformationFrameOrdinal += 1",
                      '"人机\\(botFrameOrdinal)【人机】"',
                      "let textX = anchorX - totalWidth / 2",
                      "let cardX = anchorX - cardWidth / 2",
                      "let barWidth = max(54 * scale, totalWidth)",
                      "let cardWidth = max(90 * scale, ceil(nameSize.width) + 37 * scale)",
                      "CGFloat(mark.health) / 100", "alpha: 240 / 255",
                      ".horizontalGradient(from: gradientLeft, to: gradientRight)",
                      "0x1000dc564..0x1000dc5f0", "coreInformationTeamColor",
                      "coreInformationHealthColor", ".usingFont(.body)",
                      "informationLayout=core17-simple-modern-name-health",
                      "informationAnchor=core17-record-first-projection",
                      "informationScale=core17-frame-literal-1",
                      "informationBotOrdinal=core17-frame-local-counter",
                      "gradient=core17-horizontal-four-vertex",
                      "informationIcoMoon=not-consumed"):
            self.assertIn(token, self.player)
        for removed in ('%.0f/%.0f HP', '%.0fm%@', 'let detail:', '"[\\(mark.teamID)] "'):
            self.assertNotIn(removed, self.player)
        self.assertNotIn("canvasSize.width - totalWidth", self.player)
        self.assertNotIn("let anchorX = (head.x + feet.x) / 2", self.player)
        self.assertNotIn("let topY = min(head.y, feet.y)", self.player)
        self.assertNotIn(".usingFont(.icon)", self.player)

    def test_warning_uses_closed_core_layout_and_three_explicit_layers(self) -> None:
        for token in ("min(200, max(10, configuredTextSize))",
                      "max(size.height * 0.14, fontSize)",
                      "fontSize * 1.52", "fontSize * 0.24",
                      "min(CGFloat(18), max(CGFloat(5)", "fontSize * 0.16",
                      "fontSize * 0.22", "fontSize * 0.025", "fontSize * 0.055",
                      "nativeBackground", "nativeBorder", "nativeAccent",
                      ".rounded(radius: cornerRadius)", ".centeredText()",
                      "core17-centered-top14-row152-rounded-background-border-accent"):
            self.assertIn(token, self.radar)
        self.assertLess(self.radar.index("color: nativeBackground"),
                        self.radar.index("color: nativeBorder"))
        self.assertLess(self.radar.index("color: nativeBorder"),
                        self.radar.index("color: nativeAccent"))
        self.assertNotIn(".usingFont(.icon)", self.radar)

    def test_information_modern_gradient_uses_exact_horizontal_vertex_payload(self) -> None:
        for token in ("height: 15 * scale", "alpha: 240 / 255", "alpha: 0",
                      ".horizontalGradient(from: gradientLeft, to: gradientRight)",
                      "floor(red * 255 * 0.8) / 255",
                      "gradient=core17-horizontal-four-vertex"):
            self.assertIn(token, self.player)
        self.assertNotIn("gradient=four-corner-unresolved", self.player)

    def test_metal_style5_matches_core_arc_dot_triangle_geometry(self) -> None:
        for token in ("case 5:",
                      "arc(.65f, .46f, -2.4215927f, -.18f, 13)",
                      "arc(.65f, .46f, .18f, 2.4215927f, 13)",
                      "dot(.65f, .075f, 1.0f, 1.0f, .65f)",
                      "polygon({{0,0},{.53f,-.18f},{.53f,.18f}}, color, true)",
                      "std::max(.18f * (float)rect.size.height, 2.4f)",
                      "std::max(.095f * (float)rect.size.height, 1.3f)"):
            self.assertIn(token, self.metal)


if __name__ == "__main__":
    unittest.main()
