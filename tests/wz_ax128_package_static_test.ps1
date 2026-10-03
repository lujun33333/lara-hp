$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$project = Get-Content -LiteralPath (Join-Path $root 'lara.xcodeproj/project.pbxproj') -Raw -Encoding UTF8
$info = Get-Content -LiteralPath (Join-Path $root 'lara/Info.plist') -Raw -Encoding UTF8
$build = Get-Content -LiteralPath (Join-Path $root 'scripts/build_ipa_wz.sh') -Raw -Encoding UTF8
$workflow = Get-Content -LiteralPath (Join-Path $root '.github/workflows/build.yml') -Raw -Encoding UTF8
$xpfMakefile = Get-Content -LiteralPath (Join-Path $root 'vendor/XPF/Makefile') -Raw -Encoding UTF8

function Require-Literal([string]$content, [string]$token, [string]$message) {
    if ($content -notmatch [regex]::Escape($token)) { throw "FAIL: $message ($token)" }
}

function Reject-Pattern([string]$content, [string]$pattern, [string]$message) {
    if ($content -match $pattern) { throw "FAIL: $message" }
}

function Require-Count([string]$content, [string]$pattern, [int]$count, [string]$message) {
    $actual = [regex]::Matches($content, $pattern).Count
    if ($actual -ne $count) { throw "FAIL: $message expected=$count actual=$actual" }
}

# Reference: AX自签v1.2.8.ipa / Payload/AX Pro.app/Info.plist.
foreach ($token in @(
    '<key>CFBundleDisplayName</key>', '<string>AX Pro</string>',
    '<key>CFBundleExecutable</key>', '<string>$(EXECUTABLE_NAME)</string>',
    '<key>CFBundleIdentifier</key>', '<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>',
    '<key>MinimumOSVersion</key>', '<string>$(IPHONEOS_DEPLOYMENT_TARGET)</string>',
    '<key>UILaunchStoryboardName</key>', '<string>LaunchScreen</string>',
    '<key>UISceneDelegateClassName</key>', '<string>ZeqcgKhNvh</string>',
    '<key>UIRequiredDeviceCapabilities</key>', '<string>arm64e</string>',
    '<key>UISupportedInterfaceOrientations~iphone</key>',
    '<key>CFBundleIconName</key>', '<string>AppIcon</string>'
)) { Require-Literal $info $token 'AX plist contract missing' }
Reject-Pattern $info '<string>LaraSceneDelegate</string>' 'source-class name remains in AX Scene metadata'
Require-Count $info '<key>CFBundleIconName</key>' 2 'phone/iPad icon-name metadata changed'
foreach ($forbidden in @(
    '<key>UIFileSharingEnabled</key>',
    '<key>LSSupportsOpeningDocumentsInPlace</key>',
    '<key>UIRequiresFullScreen</key>',
    '<key>UIViewControllerBasedStatusBarAppearance</key>',
    '<key>UILaunchScreen</key>'
)) { Reject-Pattern $info ([regex]::Escape($forbidden)) "reference-absent plist key remains: $forbidden" }

$phoneOrientation = @(
    'UIInterfaceOrientationPortrait',
    'UIInterfaceOrientationLandscapeLeft',
    'UIInterfaceOrientationLandscapeRight',
    'UIInterfaceOrientationPortraitUpsideDown'
)
$ipadOrientation = @(
    'UIInterfaceOrientationPortrait',
    'UIInterfaceOrientationPortraitUpsideDown',
    'UIInterfaceOrientationLandscapeLeft',
    'UIInterfaceOrientationLandscapeRight'
)
$iphoneOrientation = @(
    'UIInterfaceOrientationPortrait',
    'UIInterfaceOrientationLandscapeLeft',
    'UIInterfaceOrientationLandscapeRight'
)
foreach ($contract in @(
    @{ Key = 'UISupportedInterfaceOrientations'; Values = $phoneOrientation },
    @{ Key = 'UISupportedInterfaceOrientations~ipad'; Values = $ipadOrientation },
    @{ Key = 'UISupportedInterfaceOrientations~iphone'; Values = $iphoneOrientation }
)) {
    $start = $info.IndexOf("<key>$($contract.Key)</key>", [StringComparison]::Ordinal)
    if ($start -lt 0) { throw "FAIL: missing orientation key $($contract.Key)" }
    $end = $info.IndexOf('</array>', $start, [StringComparison]::Ordinal)
    if ($end -lt 0) { throw "FAIL: unterminated orientation array $($contract.Key)" }
    $block = $info.Substring($start, $end - $start)
    $previous = -1
    foreach ($value in $contract.Values) {
        $position = $block.IndexOf("<string>$value</string>", [StringComparison]::Ordinal)
        if ($position -le $previous) { throw "FAIL: orientation order mismatch $($contract.Key): $value" }
        $previous = $position
    }
    $actualCount = [regex]::Matches($block, '<string>UIInterfaceOrientation').Count
    if ($actualCount -ne $contract.Values.Count) {
        throw "FAIL: orientation count mismatch $($contract.Key) expected=$($contract.Values.Count) actual=$actualCount"
    }
}

Require-Count $project 'IPHONEOS_DEPLOYMENT_TARGET = 16\.5\.1;' 4 'all project/target configurations must use iOS 16.5.1'
Require-Count $project 'PRODUCT_BUNDLE_IDENTIFIER = com\.ax\.ax;' 2 'target bundle id is not com.ax.ax in both configurations'
Require-Count $project 'PRODUCT_NAME = "AX Pro";' 2 'product name is not AX Pro in both configurations'
Require-Count $project 'EXECUTABLE_NAME = "AX Pro";' 2 'executable name is not AX Pro in both configurations'
Require-Count $project 'SUPPORTED_PLATFORMS = iphoneos;' 2 'target must only advertise the device platform used by arm64e static archives'
Require-Count $project 'GENERATE_PKGINFO_FILE = NO;' 2 'target must not generate reference-absent PkgInfo'
Require-Count $project 'LD_RUNPATH_SEARCH_PATHS = "";' 2 'target runpath setting must be empty in both configurations'
Require-Count $project '-Wl,-headerpad_max_install_names' 2 'target must reserve load-command space for Swift system-path normalization'
Require-Count $project '-Wl,-force_load,\$\(SRCROOT\)/build/static-ios/libxpf\.a' 2 'libxpf static force-load missing'
Require-Count $project '-Wl,-force_load,\$\(SRCROOT\)/build/static-ios/libgrabkernel2\.a' 2 'libgrabkernel2 static force-load missing'
foreach ($token in @(
    'path = "AX Pro.app"',
    'Assets.car in Resources',
    'path = lara/AXReference.bundle/Assets.car; sourceTree = SOURCE_ROOT',
    'AXReference.bundle,', 'assets,', 'other/VarCleanRules.json,', 'other/media.xcassets,',
    'assets/lara.png,',
    'licenses/LICENSE_ChOma.md,', 'licenses/LICENSE_RootHideManagerApp.md,',
    'licenses/LICENSE_XPF.md,', 'licenses/LICENSE_libgrabkernel2.md,',
    'LD_RUNPATH_SEARCH_PATHS = "";'
)) { Require-Literal $project $token 'AX package project setting missing' }
Reject-Pattern $project 'compiled\.mach-o\.dylib|in Embed Frameworks|Force Sign Embedded Dylibs' 'dynamic XPF/grabkernel embedding remains'
Reject-Pattern $project 'LIBRARY_SEARCH_PATHS|\$\(PROJECT_DIR\)/lara/lib|iphonesimulator' 'stale dynamic-library or simulator search settings remain'
Reject-Pattern $project 'INFOPLIST_KEY_(UIFileSharingEnabled|LSSupportsOpeningDocumentsInPlace|UIRequiresFullScreen|UILaunchScreen_Generation|UISupportedInterfaceOrientations_)' 'generated plist override can drift from reference metadata'

$resourceStart = $project.IndexOf('/* Begin PBXResourcesBuildPhase section */', [StringComparison]::Ordinal)
$resourceEnd = $project.IndexOf('/* End PBXResourcesBuildPhase section */', [StringComparison]::Ordinal)
if ($resourceStart -lt 0 -or $resourceEnd -le $resourceStart) { throw 'FAIL: resources phase missing' }
$resourcePhase = $project.Substring($resourceStart, $resourceEnd - $resourceStart)
Require-Literal $resourcePhase 'Assets.car in Resources' 'reference Assets.car is not copied to the main bundle root'
Reject-Pattern $resourcePhase 'materialrecipe|visualstyleset|HomeBarAssets|media\.xcassets|lara\.png|LICENSE_' 'reference-absent resources remain in build phase'

foreach ($token in @(
    'PRODUCT_NAME="AX Pro"',
    'LDID=/usr/bin/true',
    'GRABKERNEL_COMMIT=e015c73aee6c2d3f6b0aad3fa629fe4c0429b7a6',
    'GRAB_PARTIAL_SHA256=83aea6edd5d538bf72a91ec8feb4847eb2ae99612e56fd9aa61ee9dfccca3241',
    'GRAB_PARTIAL_FAT_ARCHIVE="$GRABKERNEL_DIR/_external/lib/ios/libpartial.a"',
    'xcrun lipo "$GRAB_PARTIAL_FAT_ARCHIVE" -thin arm64e',
    'GRAB_PARTIAL_CLASS_DEFINITIONS=', 'GRAB_ARCHIVE_PARTIAL_DEFINITIONS=',
    'MAIN_PARTIAL_CLASS_DEFINITIONS=',
    'libxpf.a', 'libgrabkernel2.a', '-miphoneos-version-min=16.5.1',
    '-DXPF_LAYOUT_ONLY "$ROOT/tests/xpf_ax128_layout_test.c"',
    'verify_xpf_binary_layout "$XPF_DIR/output/ios/libxpf.dylib" arm64 arm64e',
    'LC_ALL=C grep -a -q -- "arm_maxoffset" "$BIN"',
    'MAIN_SYMBOLS="$(xcrun nm -g "$BIN")"',
    '主 Mach-O 未静态并入 libxpf', '主 Mach-O 未静态并入 libgrabkernel2',
    'NON_SYSTEM_LOADS=', 'cmd LC_RPATH', '[[ ! -e "$SRC_APP/Frameworks" ]]',
    'root = pathlib.Path(sys.argv[1])', 'unexpected root directories',
    'prefix = "Payload/AX Pro.app/"', 'entries outside AX Pro.app', 'forbidden_nested',
    'zipped plist mismatch', 'UIFileSharingEnabled', 'LSSupportsOpeningDocumentsInPlace',
    'reset_build_dir "$STATIC_DIR"', 'reset_build_dir "$DERIVED"', 'reset_build_dir "$STAGE"',
    'rm -rf -- "$target"', 'remove_previous_output "$OUTPUT_IPA"',
    'remove_previous_output "$OUTPUT_MANIFEST"',
    'command -v codesign',
    'codesign --force --sign - --timestamp=none',
    '--entitlements "$ROOT/Config/lara.entitlements"',
    '--generate-entitlement-der "$SRC_APP"',
    'SIGNED_ENTITLEMENTS="$ROOT/build/AX-Pro-main-entitlements.plist"',
    'codesign -d --entitlements :- "$BIN" >"$SIGNED_ENTITLEMENTS"',
    'python3 - "$ROOT/Config/lara.entitlements" "$SIGNED_ENTITLEMENTS"',
    'missing signed entitlement keys', 'mismatched signed entitlement values',
    'codesign --verify --strict --verbose=2 "$SRC_APP"',
    'SWIFT_RPATH_LOADS="$(xcrun otool -L "$BIN"',
    'xcrun install_name_tool -change "$old_load" "$system_load" "$BIN"',
    'xcrun install_name_tool -delete_rpath /usr/lib/swift "$BIN"',
    'SYSTEM_SWIFT_LOADS=', 'NON_SYSTEM_SWIFT_LOADS=',
    '最终主 Mach-O 未链接 iOS 系统 Swift runtime',
    'Swift runtime 规范化后主 Mach-O 仍包含 LC_RPATH',
    'App bundle 签名未生成 _CodeSignature/CodeResources',
    'duplicate ZIP entries', 'missing _CodeSignature/CodeResources',
    'signature entries mismatch',
    'OUTPUT_IPA="$ROOT/$PACKAGE_STEM.ipa"',
    'OUTPUT_MANIFEST="$ROOT/$PACKAGE_STEM.json"',
    'SOURCE_MANIFEST="$ROOT/$PACKAGE_STEM.sources.jsonl"',
    'CHECKSUM_MANIFEST="$ROOT/$PACKAGE_STEM.sha256"',
    'git", "-C", str(root), "ls-files", "--cached", "--others"',
    'sorted(relative_paths, key=lambda item: item.as_posix().encode("utf-8"))',
    'SOURCE_COMMIT=$(git -C "$ROOT" rev-parse HEAD)',
    'SOURCE_TREE=$(git -C "$ROOT" rev-parse ''HEAD^{tree}'')',
    'SOURCE_FINGERPRINT="$SOURCE_MANIFEST_SHA256"',
    '"sourceManifestSha256": "$SOURCE_MANIFEST_SHA256"',
    'shasum -a 256 -c "${CHECKSUM_MANIFEST##*/}"'
)) { Require-Literal $build $token 'AX final-product gate missing' }
Reject-Pattern $build '@executable_path/Frameworks/libxpf|cp\s+"\$XPF_DIR/output/ios/libxpf\.dylib"' 'build script still ships XPF dynamically'
Reject-Pattern $build 'XPF_EMBEDDED=|verify_xpf_binary_layout\s+"\$(BIN|XPF_EMBEDDED)"' 'final main Mach-O still uses the dylib instruction-shape verifier'
Reject-Pattern $build 'create_local_hosting_controller' 'release gate still relies on a static C++ source-function name'
Require-Count $build 'rm -rf -- "\$target"' 1 'recursive cleanup must be centralized in reset_build_dir'
Reject-Pattern $build 'rm -rf(?! -- "\$target")' 'unguarded recursive cleanup remains'
Reject-Pattern $workflow '(?i)\bldid\b' 'workflow still installs or invokes ldid'
Reject-Pattern $build '(?im)^\s*(command\s+-v|brew\s+install)\s+ldid\b|^\s*ldid\s+-S' 'build script still requires or directly invokes ldid'
Reject-Pattern $build '(?m)^FINGERPRINT=\$\(shasum -a 256' 'partial fixed-file source fingerprint remains'
$sourceStatusPosition = $build.IndexOf('SOURCE_STATUS=$(git', [StringComparison]::Ordinal)
$buildOutputPosition = $build.IndexOf('mkdir -p "$ROOT/build"', [StringComparison]::Ordinal)
$sourceManifestPosition = $build.IndexOf('SOURCE_MANIFEST_TMP=', [StringComparison]::Ordinal)
$xpfBuildPosition = $build.IndexOf('say "从源码构建并静态链接', [StringComparison]::Ordinal)
if ($sourceStatusPosition -lt 0 -or $buildOutputPosition -lt 0 -or
    $sourceStatusPosition -ge $buildOutputPosition -or
    $sourceManifestPosition -lt 0 -or $xpfBuildPosition -lt 0 -or
    $sourceManifestPosition -ge $xpfBuildPosition) {
    throw 'FAIL: source identity must be captured before any dependency or compiler output'
}
$plistCleanupPosition = $build.IndexOf("/usr/libexec/PlistBuddy -c 'Delete :LARABuildSourceCommit'", [StringComparison]::Ordinal)
$plistValidationPosition = $build.IndexOf('python3 - "$INFO_PLIST"', [StringComparison]::Ordinal)
$swiftNormalizePosition = $build.IndexOf('SWIFT_RPATH_LOADS="$(xcrun otool -L "$BIN"', [StringComparison]::Ordinal)
$codesignPosition = $build.IndexOf('codesign --force --sign - --timestamp=none', [StringComparison]::Ordinal)
$entitlementReadPosition = $build.IndexOf('codesign -d --entitlements :- "$BIN"', [StringComparison]::Ordinal)
$entitlementComparePosition = $build.IndexOf('python3 - "$ROOT/Config/lara.entitlements" "$SIGNED_ENTITLEMENTS"', [StringComparison]::Ordinal)
$codesignVerifyPosition = $build.IndexOf('codesign --verify --strict --verbose=2 "$SRC_APP"', [StringComparison]::Ordinal)
if ($plistCleanupPosition -lt 0 -or $plistValidationPosition -lt 0 -or
    $swiftNormalizePosition -lt 0 -or $codesignPosition -lt 0 -or
    $entitlementReadPosition -lt 0 -or
    $entitlementComparePosition -lt 0 -or $codesignVerifyPosition -lt 0 -or
    $plistCleanupPosition -ge $plistValidationPosition -or
    $plistValidationPosition -ge $swiftNormalizePosition -or
    $swiftNormalizePosition -ge $codesignPosition -or
    $codesignPosition -ge $entitlementReadPosition -or
    $entitlementReadPosition -ge $entitlementComparePosition -or
    $entitlementComparePosition -ge $codesignVerifyPosition) {
    throw 'FAIL: final plist, bundle signing, entitlement comparison and CodeResources verification order drifted'
}
Require-Literal $xpfMakefile 'LDID ?= ldid' 'XPF signing command is not overridable'
Require-Count $xpfMakefile '\$\(LDID\) -S \$@' 2 'all XPF iOS targets must use the overridable signer'
Reject-Pattern $xpfMakefile '(?m)^\s*@?ldid\s+-S' 'XPF Makefile still hard-codes ldid'

foreach ($token in @(
    'workflow_dispatch:', 'publish:', 'default: false', 'type: boolean',
    'contents: read',
    'if: ${{ github.event_name == ''workflow_dispatch'' && inputs.publish == true && inputs.local_test_auth_bypass != true }}',
    'if-no-files-found: error',
    'AX-Pro-1.2.8-*.ipa', 'AX-Pro-1.2.8-*.json',
    'AX-Pro-1.2.8-*.sources.jsonl', 'AX-Pro-1.2.8-*.sha256',
    'build/xcodebuild-wz.log', 'shasum -a 256 -c "${CHECKSUMS[0]}"'
)) { Require-Literal $workflow $token 'CI artifact/source-binding contract missing' }
foreach ($token in @(
    'local_test_auth_bypass:', 'BUILD_ARGS+=(--local-test-auth-bypass)',
    'true:*-local-test-auth-bypass-*',
    'refusing to publish local-test auth bypass artifact',
    'refusing to publish manifest with local-test authorization bypass'
)) { Require-Literal $workflow $token 'local-test artifact publish boundary missing' }
Require-Count $workflow '(?m)^\s{6}contents: write\s*$' 1 'contents:write must be scoped to the release job only'
Require-Count $workflow '(?m)^\s{2}contents: read\s*$' 1 'workflow default permissions must be read-only'
Reject-Pattern $workflow 'lara-wz-\*\.(ipa|json)|github\.event_name\s*!=\s*''pull_request''' 'stale artifact glob or implicit publishing remains'
Reject-Pattern $workflow 'GITHUB_ENV' 'release notes must not expose an environment-file injection surface'

$hashes = @{
    'lara/AXReference.bundle/Assets.car' = '214C984A048ADF3131F39AFD95FC883A4F9EDEF48A08FECCB51BD2BEB63BF4CB'
    'lara/AppIcon60x60@2x.png' = 'B5B43BE770B6514384393DEE2D0CECA9AAC9476FB32283D8D719F18525FDF2D0'
    'lara/AppIcon76x76@2x~ipad.png' = '67D418DE12C8C9521A80C6BAB887AE56E9E00DF757F2C0D4BEFB5B5D23832792'
    'lara/Rajdhani Bold.otf' = '03D4C893F1406CB68CF0C26C1C3112F2758E5E836D7B9CD3825B974F452FF261'
}
foreach ($entry in $hashes.GetEnumerator()) {
    $path = Join-Path $root $entry.Key
    if (-not (Test-Path -LiteralPath $path)) { throw "FAIL: missing AX resource $($entry.Key)" }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($actual -ne $entry.Value) { throw "FAIL: AX resource hash mismatch $($entry.Key): $actual" }
}

$workspace = Split-Path (Split-Path $root -Parent) -Parent
$referenceIpa = Join-Path $workspace '其他作者/AX自签v1.2.8.ipa'
if (-not (Test-Path -LiteralPath $referenceIpa)) { throw "FAIL: reference IPA missing: $referenceIpa" }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($referenceIpa)
try {
    $expectedEntries = @(
        'Payload/',
        'Payload/AX Pro.app/',
        'Payload/AX Pro.app/_CodeSignature/',
        'Payload/AX Pro.app/_CodeSignature/CodeResources',
        'Payload/AX Pro.app/Rajdhani Bold.otf',
        'Payload/AX Pro.app/AppIcon60x60@2x.png',
        'Payload/AX Pro.app/Assets.car',
        'Payload/AX Pro.app/AppIcon76x76@2x~ipad.png',
        'Payload/AX Pro.app/AX Pro',
        'Payload/AX Pro.app/Info.plist'
    )
    $actualEntries = @($archive.Entries | ForEach-Object FullName)
    if ($actualEntries.Count -ne $expectedEntries.Count -or
        (Compare-Object -ReferenceObject $expectedEntries -DifferenceObject $actualEntries)) {
        throw 'FAIL: local AX reference IPA entries changed'
    }
    if ($actualEntries -match '^Payload/AX Pro\.app/Frameworks/') {
        throw 'FAIL: AX reference unexpectedly contains Frameworks'
    }
} finally {
    $archive.Dispose()
}

Write-Output 'PASS: AX 1.2.8 package identity, plist, root resources, static-link plan, and final artifact gates'
