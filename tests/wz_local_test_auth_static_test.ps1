$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$policy = Get-Content -LiteralPath (Join-Path $root 'lara/headers/AXLauncherAuthorizationPolicy.h') -Raw -Encoding UTF8
$bridge = Get-Content -LiteralPath (Join-Path $root 'lara/lara-Bridging-Header.h') -Raw -Encoding UTF8
$launcher = Get-Content -LiteralPath (Join-Path $root 'lara/views/app/ContentView.swift') -Raw -Encoding UTF8
$scene = Get-Content -LiteralPath (Join-Path $root 'lara/lara.swift') -Raw -Encoding UTF8
$manager = Get-Content -LiteralPath (Join-Path $root 'lara/classes/laramgr.swift') -Raw -Encoding UTF8
$build = Get-Content -LiteralPath (Join-Path $root 'scripts/build_ipa_wz.sh') -Raw -Encoding UTF8
$project = Get-Content -LiteralPath (Join-Path $root 'lara.xcodeproj/project.pbxproj') -Raw -Encoding UTF8
$workflow = Get-Content -LiteralPath (Join-Path $root '.github/workflows/build.yml') -Raw -Encoding UTF8

function Require-Literal([string]$content, [string]$token, [string]$message) {
    if ($content.IndexOf($token, [StringComparison]::Ordinal) -lt 0) {
        throw "FAIL: $message ($token)"
    }
}

Require-Literal $policy '#define AX_LOCAL_TEST_AUTH_BYPASS 0' 'production default is not fail-closed'
Require-Literal $policy 'return AX_LOCAL_TEST_AUTH_BYPASS == 1;' 'policy does not require the explicit value 1'
Require-Literal $policy 'ax_launcher_authorization_allows_functional_access' 'shared functional-access policy missing'
Require-Literal $bridge '#import "headers/AXLauncherAuthorizationPolicy.h"' 'Swift bridge does not import the policy'
foreach ($token in @(
    'case localTesting',
    'static var initialForCurrentBuild: Self',
    'ax_launcher_local_test_authorization_bypass_enabled()',
    '#if AX_LOCAL_TEST_AUTH_BYPASS',
    'return "LOCAL TEST AUTH BYPASS · 已跳过卡密验证"',
    'authorizationState = .applyingBuildPolicy(to: state)',
    'guard authorizationState.canLaunch else',
    'presentNotice("当前工程尚未接入 AX 卡密验证服务，无法在这里验证 AX 卡密。")'
)) { Require-Literal $launcher $token 'launcher authorization contract missing' }
Require-Literal $scene 'authorizationState: .initialForCurrentBuild' 'startup does not apply the build policy'
foreach ($token in @(
    'ax_launcher_authorization_allows_functional_access(false)',
    'func updateWZAuthorizationAccess(_ verified: Bool)',
    'private func requireWZAuthorization() -> Bool',
    'func prepareWZEnvironment(connectWhenReady: Bool = true) {',
    'func launchWZGame() {',
    'func wzAttach(process: String = "smoba") {',
    'if enabled, !requireWZAuthorization() { return }'
)) { Require-Literal $manager $token 'manager authorization gate missing' }
foreach ($signature in @(
    'func prepareWZEnvironment(connectWhenReady: Bool = true) {',
    'func launchWZGame() {',
    'func wzAttach(process: String = "smoba") {'
)) {
    $start = $manager.IndexOf($signature, [StringComparison]::Ordinal)
    if ($start -lt 0) { throw "FAIL: protected entry missing ($signature)" }
    $body = $manager.Substring($start, [Math]::Min(240, $manager.Length - $start))
    Require-Literal $body 'guard requireWZAuthorization() else { return }' 'protected entry can bypass authorization'
}
foreach ($token in @(
    'AX_LOCAL_TEST_AUTH_BYPASS=0',
    '--local-test-auth-bypass) AX_LOCAL_TEST_AUTH_BYPASS=1',
    'GCC_PREPROCESSOR_DEFINITIONS=$(inherited) AX_LOCAL_TEST_AUTH_BYPASS=0',
    'GCC_PREPROCESSOR_DEFINITIONS=$(inherited) AX_LOCAL_TEST_AUTH_BYPASS=1',
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) AX_LOCAL_TEST_AUTH_BYPASS',
    'PRODUCT_BUNDLE_IDENTIFIER=com.ax.ax.localtest',
    '"${AUTH_BYPASS_BUILD_SETTINGS[@]}"',
    'AUTH_BYPASS_PACKAGE_SUFFIX=-local-test-auth-bypass',
    '"localTestAuthorizationBypass": $AUTH_BYPASS_JSON'
)) { Require-Literal $build $token 'auditable build switch missing' }
foreach ($token in @(
    'local_test_auth_bypass:',
    'BUILD_ARGS+=(--local-test-auth-bypass)',
    'true:*-local-test-auth-bypass-*',
    "inputs.local_test_auth_bypass != true",
    'refusing to publish local-test auth bypass artifact',
    'refusing to publish manifest with local-test authorization bypass'
)) { Require-Literal $workflow $token 'CI publish boundary missing' }
if ($project -match 'AX_LOCAL_TEST_AUTH_BYPASS\s*=\s*1') {
    throw 'FAIL: project enables the local-test bypass by default'
}
if ($launcher -match '(?i)(print|NSLog|logger)[^\r\n]*(activationField|code|卡密)') {
    throw 'FAIL: launcher logs activation input or card data'
}

Write-Output 'PASS: local-test auth bypass is explicit, fail-closed by default, and preserves the production gate'
