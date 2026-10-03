"""Static consistency checks for the AX 1.2.8 Xcode/package pipeline."""

from __future__ import annotations

import plistlib
import re
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = ROOT / "scripts" / "build_ipa_wz.sh"
PROJECT_PATH = ROOT / "lara.xcodeproj" / "project.pbxproj"
INFO_PATH = ROOT / "lara" / "Info.plist"
MAKEFILE_PATH = ROOT / "vendor" / "XPF" / "Makefile"
WORKFLOW_PATH = ROOT / ".github" / "workflows" / "build.yml"
PARTIAL_HEADER_PATH = ROOT / "lara" / "kexploit" / "Partial.h"
PARTIAL_SOURCE_PATH = ROOT / "lara" / "kexploit" / "Partial.m"

script = SCRIPT_PATH.read_text(encoding="utf-8")
project = PROJECT_PATH.read_text(encoding="utf-8")
makefile = MAKEFILE_PATH.read_text(encoding="utf-8")
workflow = WORKFLOW_PATH.read_text(encoding="utf-8")
partial_header = PARTIAL_HEADER_PATH.read_text(encoding="utf-8")
partial_source = PARTIAL_SOURCE_PATH.read_text(encoding="utf-8")
with INFO_PATH.open("rb") as stream:
    info = plistlib.load(stream)


def embedded_python_blocks(shell_source: str) -> list[tuple[int, str]]:
    lines = shell_source.splitlines()
    blocks: list[tuple[int, str]] = []
    index = 0
    while index < len(lines):
        if not re.search(r"\bpython3\b.*<<'PY'", lines[index]):
            index += 1
            continue
        start_line = index + 1
        index += 1
        # `<<'PY' \\` may continue with a shell `|| die ...` line before the
        # here-document body begins.
        while index < len(lines) and lines[index].lstrip().startswith(("||", "&&")):
            index += 1
        body: list[str] = []
        while index < len(lines) and lines[index] != "PY":
            body.append(lines[index])
            index += 1
        if index == len(lines):
            raise AssertionError(f"unterminated Python heredoc at line {start_line}")
        blocks.append((start_line, "\n".join(body) + "\n"))
        index += 1
    return blocks


python_blocks = embedded_python_blocks(script)
assert len(python_blocks) == 7, len(python_blocks)
for line_number, body in python_blocks:
    compile(body, f"{SCRIPT_PATH}:{line_number}", "exec")


for token in (
    '"git", "-C", str(root), "ls-files", "--cached", "--others"',
    'sorted(relative_paths, key=lambda item: item.as_posix().encode("utf-8"))',
    'SOURCE_COMMIT=$(git -C "$ROOT" rev-parse HEAD)',
    "SOURCE_TREE=$(git -C \"$ROOT\" rev-parse 'HEAD^{tree}')",
    'SOURCE_FINGERPRINT="$SOURCE_MANIFEST_SHA256"',
    'SOURCE_MANIFEST="$ROOT/$PACKAGE_STEM.sources.jsonl"',
    'CHECKSUM_MANIFEST="$ROOT/$PACKAGE_STEM.sha256"',
    '"sourceManifestSha256": "$SOURCE_MANIFEST_SHA256"',
    'shasum -a 256 -c "${CHECKSUM_MANIFEST##*/}"',
    "LDID=/usr/bin/true",
):
    assert token in script, token
assert not re.search(r"(?m)^FINGERPRINT=\$\(shasum -a 256", script)
assert script.index("SOURCE_STATUS=$(git") < script.index('mkdir -p "$ROOT/build"')
assert script.index("SOURCE_MANIFEST_TMP=") < script.index("say \"从源码构建并静态链接")

assert "create_local_hosting_controller" not in script

for token in (
    "command -v codesign",
    "codesign --force --sign - --timestamp=none",
    '--entitlements "$ROOT/Config/lara.entitlements"',
    '--generate-entitlement-der "$SRC_APP"',
    'codesign -d --entitlements :- "$BIN" >"$SIGNED_ENTITLEMENTS"',
    'python3 - "$ROOT/Config/lara.entitlements" "$SIGNED_ENTITLEMENTS"',
    "missing signed entitlement keys",
    "mismatched signed entitlement values",
    'codesign --verify --strict --verbose=2 "$SRC_APP"',
    'SWIFT_RPATH_LOADS="$(xcrun otool -L "$BIN"',
    'xcrun install_name_tool -change "$old_load" "$system_load" "$BIN"',
    'xcrun install_name_tool -delete_rpath /usr/lib/swift "$BIN"',
    "SYSTEM_SWIFT_LOADS=",
    "NON_SYSTEM_SWIFT_LOADS=",
    "最终主 Mach-O 未链接 iOS 系统 Swift runtime",
    "Swift runtime 规范化后主 Mach-O 仍包含 LC_RPATH",
):
    assert token in script, token
assert not re.search(r"(?im)^\s*(?:command\s+-v|brew\s+install)\s+ldid\b|^\s*ldid\s+-S", script)
plist_cleanup = script.index("/usr/libexec/PlistBuddy -c 'Delete :LARABuildSourceCommit'")
plist_validation = script.index('python3 - "$INFO_PLIST"')
swift_normalize = script.index('SWIFT_RPATH_LOADS="$(xcrun otool -L "$BIN"')
bundle_sign = script.index("codesign --force --sign - --timestamp=none")
entitlement_read = script.index('codesign -d --entitlements :- "$BIN"')
entitlement_compare = script.index(
    'python3 - "$ROOT/Config/lara.entitlements" "$SIGNED_ENTITLEMENTS"'
)
bundle_verify = script.index('codesign --verify --strict --verbose=2 "$SRC_APP"')
assert (
    plist_cleanup
    < plist_validation
    < swift_normalize
    < bundle_sign
    < entitlement_read
    < entitlement_compare
    < bundle_verify
)

for token in (
    "workflow_dispatch:",
    "publish:",
    "local_test_auth_bypass:",
    "default: false",
    "type: boolean",
    "contents: read",
    "if: ${{ github.event_name == 'workflow_dispatch' && inputs.publish == true && inputs.local_test_auth_bypass != true }}",
    "if-no-files-found: error",
    "AX-Pro-1.2.8-*.ipa",
    "AX-Pro-1.2.8-*.json",
    "AX-Pro-1.2.8-*.sources.jsonl",
    "AX-Pro-1.2.8-*.sha256",
    "build/xcodebuild-wz.log",
    'shasum -a 256 -c "${CHECKSUMS[0]}"',
    "refusing to publish local-test auth bypass artifact",
    "refusing to publish manifest with local-test authorization bypass",
):
    assert token in workflow, token
assert len(re.findall(r"(?m)^\s{6}contents: write\s*$", workflow)) == 1
assert len(re.findall(r"(?m)^\s{2}contents: read\s*$", workflow)) == 1
assert not re.search(r"lara-wz-\*\.(?:ipa|json)", workflow)
assert "github.event_name != 'pull_request'" not in workflow
assert "GITHUB_ENV" not in workflow

for token in (
    "AX_LOCAL_TEST_AUTH_BYPASS=0",
    "--local-test-auth-bypass) AX_LOCAL_TEST_AUTH_BYPASS=1",
    "GCC_PREPROCESSOR_DEFINITIONS=$(inherited) AX_LOCAL_TEST_AUTH_BYPASS=0",
    "GCC_PREPROCESSOR_DEFINITIONS=$(inherited) AX_LOCAL_TEST_AUTH_BYPASS=1",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) AX_LOCAL_TEST_AUTH_BYPASS",
    "PRODUCT_BUNDLE_IDENTIFIER=com.ax.ax.localtest",
    '"localTestAuthorizationBypass": $AUTH_BYPASS_JSON',
    '"bundleIdentifier": "$EXPECTED_BUNDLE_IDENTIFIER"',
):
    assert token in script, token
assert "ldid" not in workflow.lower()

assert "LDID ?= ldid" in makefile
assert makefile.count("$(LDID) -S $@") == 2
assert not re.search(r"(?m)^\s*@?ldid\s+-S", makefile)


script_xpf_match = re.search(r"(?ms)^xpf_sources=\(\n(.*?)^\)", script)
assert script_xpf_match
script_xpf_sources = re.findall(r'"\$XPF_DIR/(src/[^"\r\n]+\.c)"', script_xpf_match.group(1))
makefile_xpf_match = re.search(r"(?m)^XPF_SOURCES\s*=\s*(.+)$", makefile)
assert makefile_xpf_match
makefile_xpf_sources = makefile_xpf_match.group(1).split()
assert script_xpf_sources == makefile_xpf_sources, (
    script_xpf_sources,
    makefile_xpf_sources,
)
assert 'verify_xpf_binary_layout "$XPF_DIR/output/ios/libxpf.dylib" arm64 arm64e' in script
assert 'LC_ALL=C grep -a -q -- "arm_maxoffset" "$BIN"' in script
assert 'MAIN_SYMBOLS="$(xcrun nm -g "$BIN")"' in script
assert "XPF_EMBEDDED=" not in script
assert not re.search(
    r'verify_xpf_binary_layout\s+"\$(?:BIN|XPF_EMBEDDED)"', script
)

assert 'choma_sources=("$CHOMA_DIR"/src/*.c)' in script
assert 'grab_sources=("$GRABKERNEL_DIR"/src/*.m)' in script
assert 'GRABKERNEL_COMMIT=e015c73aee6c2d3f6b0aad3fa629fe4c0429b7a6' in script
assert 'GRAB_PARTIAL_SHA256=83aea6edd5d538bf72a91ec8feb4847eb2ae99612e56fd9aa61ee9dfccca3241' in script
for token in (
    'GRAB_PARTIAL_FAT_ARCHIVE="$GRABKERNEL_DIR/_external/lib/ios/libpartial.a"',
    'xcrun lipo "$GRAB_PARTIAL_FAT_ARCHIVE" -thin arm64e',
    'GRAB_PARTIAL_SYMBOLS="$(LC_ALL=C xcrun nm -g "$GRAB_PARTIAL_ARCHIVE")"',
    'GRAB_PARTIAL_CLASS_DEFINITIONS=',
    '"${grab_objects[@]}" "$GRAB_PARTIAL_ARCHIVE"',
    'GRAB_ARCHIVE_PARTIAL_DEFINITIONS=',
    'MAIN_PARTIAL_CLASS_DEFINITIONS=',
):
    assert token in script, token
assert script.count('"_OBJC_CLASS_$_Partial"') == 3
grab_block = script[script.index('grab_sources=('):script.index('ok "XPF 与 libgrabkernel2 静态库已就绪')]
assert 'lara/kexploit/Partial.m' not in grab_block
assert '@interface Partial : NSObject' in partial_header
assert '@implementation Partial' not in partial_source
assert 'bool kc_resolve_firmware_url(' in partial_source
assert 'bool kc_fetch_kernelcache_by_range(' in partial_source
assert 'CHOMA_COMMIT=b1a4f2debf2aff70edc2825c5cfbd05926d7fc18' in script


exception_match = re.search(
    r'(?ms)membershipExceptions = \(\n(.*?)\n\s*\);\n\s*target = .*?/\* lara \*/;',
    project,
)
assert exception_match
exceptions = {
    line.strip().removesuffix(",")
    for line in exception_match.group(1).splitlines()
    if line.strip()
}
assert exceptions == {
    "AXReference.bundle",
    "Info.plist",
    "assets",
    "assets/lara.png",
    "lib/libgrabkernel2.dylib",
    "lib/libxpf.dylib",
    "licenses/LICENSE_ChOma.md",
    "licenses/LICENSE_RootHideManagerApp.md",
    "licenses/LICENSE_XPF.md",
    "licenses/LICENSE_libgrabkernel2.md",
    "other/VarCleanRules.json",
    "other/media.xcassets",
    "third_party/imgui/LICENSE.txt",
}

sources_phase = re.search(
    r"(?ms)/\* Begin PBXSourcesBuildPhase section \*/(.*?)/\* End PBXSourcesBuildPhase section \*/",
    project,
)
assert sources_phase
assert re.search(r"files = \(\s*\);", sources_phase.group(1))
resources_phase = re.search(
    r"(?ms)/\* Begin PBXResourcesBuildPhase section \*/(.*?)/\* End PBXResourcesBuildPhase section \*/",
    project,
)
assert resources_phase
resource_entries = re.findall(r"/\* ([^*]+ in Resources) \*/", resources_phase.group(1))
assert resource_entries == ["Assets.car in Resources"]

for token in (
    '"$(SRCROOT)/lara"',
    '"$(SRCROOT)/lara/kexploit"',
    '"$(SRCROOT)/lara/third_party/imgui"',
    '"-Wl,-force_load,$(SRCROOT)/build/static-ios/libxpf.a"',
    '"-Wl,-force_load,$(SRCROOT)/build/static-ios/libgrabkernel2.a"',
    "SUPPORTED_PLATFORMS = iphoneos;",
    'LD_RUNPATH_SEARCH_PATHS = "";',
    '"-Wl,-headerpad_max_install_names"',
    "GENERATE_PKGINFO_FILE = NO;",
):
    assert project.count(token) == 2, token
assert "LIBRARY_SEARCH_PATHS" not in project
assert "iphonesimulator" not in project


expected_info = {
    "CFBundleDisplayName": "AX Pro",
    "CFBundleExecutable": "$(EXECUTABLE_NAME)",
    "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
    "CFBundleName": "AX Pro",
    "CFBundleShortVersionString": "$(MARKETING_VERSION)",
    "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    "MinimumOSVersion": "$(IPHONEOS_DEPLOYMENT_TARGET)",
    "UILaunchStoryboardName": "LaunchScreen",
    "UIRequiredDeviceCapabilities": ["arm64e"],
    "UIAppFonts": ["Rajdhani Bold.otf"],
    "UIBackgroundModes": ["background-processing", "background-fetch", "audio"],
    "UIApplicationSupportsIndirectInputEvents": True,
}
for key, expected in expected_info.items():
    assert info.get(key) == expected, (key, info.get(key), expected)
for forbidden in (
    "UIFileSharingEnabled",
    "LSSupportsOpeningDocumentsInPlace",
    "UIRequiresFullScreen",
    "UIViewControllerBasedStatusBarAppearance",
    "UILaunchScreen",
):
    assert forbidden not in info

assert info["UIApplicationSceneManifest"] == {
    "UIApplicationSupportsMultipleScenes": False,
    "UISceneConfigurations": {
        "UIWindowSceneSessionRoleApplication": [
            {
                "UISceneConfigurationName": "Default Configuration",
                "UISceneDelegateClassName": "ZeqcgKhNvh",
            }
        ]
    },
}

reference_ipa = ROOT.parents[1] / "其他作者" / "AX自签v1.2.8.ipa"
with zipfile.ZipFile(reference_ipa) as archive:
    reference_info = plistlib.loads(archive.read("Payload/AX Pro.app/Info.plist"))
assert info["UIApplicationSceneManifest"] == reference_info["UIApplicationSceneManifest"]

print(
    "PASS: AX build script embedded Python, static source lists, synchronized "
    "project phases and plist contract"
)
