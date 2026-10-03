$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bridge = Get-Content -LiteralPath (Join-Path $root 'lara/kexploit/WZHUDBridge.mm') -Raw -Encoding UTF8
$collector = Get-Content -LiteralPath (Join-Path $root 'lara/kexploit/wzesp.mm') -Raw -Encoding UTF8
$manager = Get-Content -LiteralPath (Join-Path $root 'lara/classes/laramgr.swift') -Raw -Encoding UTF8

function Require([string]$content, [string]$pattern, [string]$message) {
    if ($content -notmatch $pattern) { throw "FAIL: $message" }
}

# Yuanbao-native drawing controls: key -> flag -> renderer/collector consumer.
$native = @(
    @('debug', 'WZESP_SHOW_MAP_ADJUSTMENT'),
    @('bigmapimage', 'WZESP_SHOW_AVATAR'),
    @('soldier', 'WZESP_SHOW_SOLDIER'),
    @('draw', 'WZESP_SHOW_MINIMAP'),
    @('monster', 'WZESP_SHOW_MONSTER'),
    @('skill', 'WZESP_SHOW_SKILL'),
    @('box', 'WZESP_SHOW_BOX')
)
foreach ($mapping in $native) {
    $key = [regex]::Escape($mapping[0])
    $flag = $mapping[1]
    Require $bridge "ax_bool\(@`"$key`"\)[\s\S]{0,100}$flag" "UI key $($mapping[0]) is not bound to $flag"
    Require ($bridge + $collector) ([regex]::Escape($flag)) "No consumer exists for $flag"
}
Require $bridge 'g_captureProtected\.store\(ax_bool\(@"stream"\)\)[\s\S]{0,260}ax_apply_capture_policy_main' `
    'screen capture toggle has no capture-policy consumer'

# Compatibility controls retained from the previous working UI.
foreach ($mapping in @(
    @('auto.kill', 'WZESP_AUTO_KILL'),
    @('shiye.soldier', 'WZESP_SHOW_SOLDIER_VISION'),
    @('shiye.hero', 'WZESP_SHOW_HERO_VISION'),
    @('minimap.enemyvision', 'WZESP_SHOW_ENEMY_VISION')
)) {
    $key = [regex]::Escape($mapping[0])
    $flag = $mapping[1]
    Require $bridge "ax_bool\(@`"$key`"\)[^;]*$flag" "Compatibility key $($mapping[0]) is not bound to $flag"
}
Require $collector 'TryAXAutoKill[\s\S]{0,300}WZESP_AUTO_KILL' 'auto-kill flag does not reach the action consumer'
Require $collector 'TryAXAutoKill[\s\S]{0,2200}wzax_touch_tap_async' 'auto-kill action does not submit a touch'
Require $manager 'WZESP_SHOW_HERO_VISION \| WZESP_SHOW_SOLDIER_VISION \|[\s\S]{0,100}WZESP_AUTO_KILL' `
    'advanced flags do not schedule the required reader'
Require $collector 'collectExposure = \(requested &[\s\S]{0,100}WZESP_SHOW_HERO_VISION \| WZESP_SHOW_SOLDIER_VISION' `
    'exposure flags do not reach collector input'
Require $collector 'collectMinimapExposure = \(requested &[\s\S]{0,100}WZESP_SHOW_ENEMY_VISION' `
    'enemy-vision flag does not reach minimap exposure collection'
Require $bridge 'WZESP_SHOW_ENEMY_VISION[\s\S]{0,700}minimapDimmed' `
    'enemy-vision result has no renderer consumer'
Require $bridge 'g_captureKillPoint && phase==WZHUDPointerPhaseBegan[\s\S]{0,900}click_coord_x[\s\S]{0,700}click_coord_space' `
    'kill coordinate setting has no HID capture/persistence consumer'

# A single shared debug command is allowed; no second UIKit staging renderer.
Require $bridge 'WZESP_SHOW_MAP_ADJUSTMENT\)[\s\S]{0,240}ax_push_rect\(commands' `
    'debug guide is not emitted by the shared command producer'
if ($bridge -match 'g_wzMinimapGuide|apply_wz_snapshot_main|g_wzWorldViews|g_wzRayViews') {
    throw 'FAIL: a second UIKit staging renderer remains'
}
Require $bridge 'WZESP_COLLECT_AIM' 'aim does not request the shared collector snapshot'
Require $collector 'wzaim_runtime_consume_snapshot' 'shared collector does not feed aim'
if ($manager -match 'wzaim_runtime_tick\(') {
    throw 'FAIL: Swift still runs a second aim collection tick'
}

Write-Output 'PASS: Yuanbao drawing and compatibility feature UI-to-consumer mappings'
