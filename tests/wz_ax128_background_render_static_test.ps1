$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$bridge = Get-Content -LiteralPath (Join-Path $root 'lara/kexploit/WZHUDBridge.mm') -Raw -Encoding UTF8
$header = Get-Content -LiteralPath (Join-Path $root 'lara/kexploit/WZHUDBridge.h') -Raw -Encoding UTF8
$scene = Get-Content -LiteralPath (Join-Path $root 'lara/lara.swift') -Raw -Encoding UTF8

function Require-Literal([string]$content, [string]$token, [string]$message) {
    if ($content.IndexOf($token, [StringComparison]::Ordinal) -lt 0) {
        throw "FAIL: $message ($token)"
    }
}

foreach ($token in @(
    'UIApplicationDidEnterBackgroundNotification',
    'UIApplicationDidBecomeActiveNotification',
    '@selector(applicationDidEnterBackgroundForOrientation:)',
    '@selector(applicationDidBecomeActiveForRendering:)',
    '- (void)applicationDidEnterBackgroundForOrientation:(NSNotification *)notification',
    '- (void)applicationDidBecomeActiveForRendering:(NSNotification *)notification'
)) { Require-Literal $bridge $token 'UIApplication lifecycle observer chain missing' }

Require-Literal $header 'WZHUDRenderBackendMetal' 'Metal backend policy missing'
Require-Literal $header 'WZHUDRenderBackendCoreAnimation' 'CoreAnimation backend policy missing'
Require-Literal $header 'wzhud_render_backend_for_application_active' 'backend selector missing'
Require-Literal $header 'wzhud_render_transition_for_application_active' 'backend transition policy missing'
$policyStart = $header.IndexOf('wzhud_render_transition_for_application_active(bool active)', [StringComparison]::Ordinal)
$policyEnd = $header.IndexOf('bool wzhud_set_enabled', $policyStart, [StringComparison]::Ordinal)
$policy = $header.Substring($policyStart, $policyEnd - $policyStart)
if ($policy.IndexOf("true,", [StringComparison]::Ordinal) -lt 0 -or
    $policy.IndexOf("active,", [StringComparison]::Ordinal) -lt 0 -or
    $policy.IndexOf("!active,", [StringComparison]::Ordinal) -lt 0) {
    throw 'FAIL: inactive SpringBoard-hosted source tick can still be paused'
}

$renderStart = $bridge.IndexOf('static void render_frame_main(CFTimeInterval now)', [StringComparison]::Ordinal)
$renderEnd = $bridge.IndexOf('static BOOL hud_interaction_ready_main', $renderStart, [StringComparison]::Ordinal)
if ($renderStart -lt 0 -or $renderEnd -le $renderStart) { throw 'FAIL: render_frame_main bounds missing' }
$render = $bridge.Substring($renderStart, $renderEnd - $renderStart)
foreach ($token in @(
    'ax_build_render_commands(latest, latestCount, current_wz_config()',
    'const AXHUDImmutableFrame frame',
    'wzhud_render_backend_for_application_active(g_sceneActive.load())',
    'present_layer_frame_main(frame)',
    'submitCommands:&frame.commands'
)) { Require-Literal $render $token 'shared immutable frame path missing' }
if ($render -match 'apply_wz_snapshot_main|g_canvas\.subviews|CGPathCreateCopyByTransformingPath') {
    throw 'FAIL: render path still depends on UIKit staging or copied CGPath'
}
if ($render -match 'backgroundHosted[\s\S]{0,120}g_displayLink\.paused\s*=\s*YES') {
    throw 'FAIL: a transient background CA failure permanently pauses hosted updates'
}

$caStart = $bridge.IndexOf('static BOOL present_layer_frame_main(const AXHUDImmutableFrame &frame)', [StringComparison]::Ordinal)
$caEnd = $bridge.IndexOf('static void refresh_window_context_ids_main', $caStart, [StringComparison]::Ordinal)
if ($caStart -lt 0 -or $caEnd -le $caStart) { throw 'FAIL: CA consumer bounds missing' }
$ca = $bridge.Substring($caStart, $caEnd - $caStart)
Require-Literal $ca 'for (const AXHUDRenderCommand &command : frame.commands)' 'CA does not consume shared commands'
foreach ($token in @(
    'imgui_abgr_color(command.color)',
    'startAngle:command.startAngle',
    'endAngle:command.endAngle',
    '@"Rajdhani-Bold"',
    'addImage:image frame:command.frame',
    'rounding:command.rounding'
)) { Require-Literal $ca $token 'CA primitive/font/color mapping changed' }
$primitiveCases = @('Line', 'Rect', 'Circle', 'Arc', 'Text', 'OutlinedText', 'Image')
$previousCase = -1
foreach ($kind in $primitiveCases) {
    $position = $ca.IndexOf("case AXHUDRenderCommandKind::$kind", [StringComparison]::Ordinal)
    if ($position -le $previousCase) { throw "FAIL: CA primitive order changed ($kind)" }
    $previousCase = $position
}
foreach ($forbidden in @('g_canvas.subviews', 'convertRect:', 'CGPathCreateCopyByTransformingPath')) {
    if ($ca.IndexOf($forbidden, [StringComparison]::Ordinal) -ge 0) {
        throw "FAIL: CA consumer retains UIKit staging dependency ($forbidden)"
    }
}

$metalStart = $bridge.IndexOf('- (void)buildDirectDrawList:(ImDrawList *)drawList', [StringComparison]::Ordinal)
$metalEnd = $bridge.IndexOf('- (BOOL)submitCommands:', $metalStart, [StringComparison]::Ordinal)
$metal = $bridge.Substring($metalStart, $metalEnd - $metalStart)
Require-Literal $metal 'for (const AXHUDRenderCommand &command : *_commands)' 'Metal does not consume shared commands'

$activityStart = $bridge.IndexOf('static void handle_scene_activity_main(BOOL active) {', [StringComparison]::Ordinal)
$activityEnd = $bridge.IndexOf('@implementation WZHUDDrawWindow', $activityStart, [StringComparison]::Ordinal)
if ($activityStart -lt 0 -or $activityEnd -le $activityStart) { throw 'FAIL: lifecycle transition bounds missing' }
$activity = $bridge.Substring($activityStart, $activityEnd - $activityStart)
foreach ($token in @(
    'wzhud_render_transition_for_application_active(active)',
    'g_metalRenderer.view.hidden=!transition.metalVisible',
    '[g_layerRenderer setVisible:transition.coreAnimationVisible]',
    'g_displayLink.paused = !transition.foregroundTickEnabled'
)) { Require-Literal $activity $token 'lifecycle event does not apply shared backend transition' }
$pausePosition = $activity.IndexOf('g_displayLink.paused = !transition.foregroundTickEnabled', [StringComparison]::Ordinal)
$configurePosition = $activity.IndexOf('(void)configure_layer_renderer_main()', [StringComparison]::Ordinal)
if ($pausePosition -lt 0 -or $configurePosition -lt 0 -or $pausePosition -ge $configurePosition) {
    throw 'FAIL: background transition must apply the live-tick policy before configuring CA'
}

# The five SceneDelegate callbacks stay empty; lifecycle behavior belongs to
# the HUD's UIApplication observers, matching AX gdr2sae1a.
foreach ($name in @('sceneDidBecomeActive', 'sceneWillEnterForeground', 'sceneWillResignActive', 'sceneDidEnterBackground', 'sceneDidDisconnect')) {
    $pattern = "(?s)func\s+$name\s*\([^)]*\)\s*\{\s*\}"
    if ($scene -notmatch $pattern) { throw "FAIL: SceneDelegate callback is no longer empty: $name" }
}

Write-Output 'PASS: UIApplication lifecycle observers, backend switching, and shared immutable render commands'
