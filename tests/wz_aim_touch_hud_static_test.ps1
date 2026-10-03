$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Get-Content -LiteralPath (Join-Path $root 'lara/kexploit/WZHUDBridge.mm') -Raw -Encoding UTF8

function Need([string]$pattern, [string]$message) {
    if ($source -notmatch $pattern) { throw "FAIL: $message" }
}
function Reject([string]$pattern, [string]$message) {
    if ($source -match $pattern) { throw "FAIL: $message" }
}

Need 'aim\.externalTouch=1' 'HUD does not hard-select external touch delivery'
Need '@\[@"1",@"2",@"3",@"4"\][\s\S]{0,80}configuredSlot-1,44301' 'skill selection is not explicitly limited to slots 1..4'
Need 'kWZAimTouchMinimumCalibrationRadius = 20\.0' 'calibration can accept incidental touch jitter'
Need '@"centerX"[\s\S]{0,200}@"radius"[\s\S]{0,200}@"width"[\s\S]{0,120}@"height"[\s\S]{0,120}@"orientation"' 'fixed-space calibration geometry is incomplete'
Need 'calibration\.orientation == g_orientation' 'calibration is reused across an orientation mismatch'
Need 'fabs\(calibration\.fixedSize\.width[\s\S]{0,220}fabs\(calibration\.fixedSize\.height' 'calibration is scaled across a different screen size'
Need 'wzax_touch_is_ready\(\)' 'physical interception does not require the real sender readiness state'
Need 'snapshot\.sessionGeneration == 0[\s\S]{0,120}snapshot\.sourceSnapshotGeneration == 0' 'snapshot identity generations are not required'
Need 'snapshot\.hostScreenValid == 0 \|\| snapshot\.targetScreenValid == 0' 'both projected screen points are not required'
Need 'age <= kWZAimTouchSnapshotMaxAgeSeconds' 'target freshness is not bounded'
Need 'calibration->center\.x \+ calibration->radius \* dx / length' 'synthetic drag endpoint does not use calibrated radius and target direction'

Need 'g_aimSkillHitRegion = \[\[UIControl alloc\]' 'skill interception is not an immediate UIControl lifecycle'
Need 'UIControlEventTouchDown' 'physical skill press does not synthesize Down immediately'
Need 'UIControlEventTouchDragInside[\s\S]{0,100}UIControlEventTouchDragOutside' 'physical skill drag is not retained across the hit-region boundary'
Need 'UIControlEventTouchUpInside[\s\S]{0,100}UIControlEventTouchUpOutside' 'physical skill release does not synthesize Up'
Need 'UIControlEventTouchCancel' 'physical skill cancellation is not handled'
Need 'handle_panel_pointer_main\(calibration\.center,WZHUDPointerPhaseBegan,pointerID\)' 'the calibrated skill TouchDown does not enter the shared begin path'
Need 'renderTick:[\s\S]{0,180}g_aimSyntheticDragActive\) move_aim_touch_drag_main\(\)' '60 Hz target tracking does not drive synthetic Move'
Need 'kWZAimTouchMoveInterval = 1\.0 / 30\.0' 'remote aim drag move cadence is no longer bounded at 30 Hz'
Need 'now - g_aimLastMoveSubmitAt < kWZAimTouchMoveInterval' 'aim drag does not throttle remote HID move submissions'
Need 'wzax_touch_drag_end_async' 'physical End is not forwarded as synthetic Up'
Need 'wzax_touch_drag_cancel_async' 'cancel path does not terminate the synthetic drag'
Need 'aim_touch_begin_completion[\s\S]{0,300}dispatch_async\(dispatch_get_main_queue\(\)' 'failed async Down does not clean state on the main queue'

$pointerFilter = $source.IndexOf('if (containsSyntheticPointer) return;', [StringComparison]::Ordinal)
$chord = $source.IndexOf('handle_hid_three_finger_chord(pointerIDs,phase,timestamp);', [StringComparison]::Ordinal)
if ($pointerFilter -lt 0 -or $chord -lt 0 -or $pointerFilter -gt $chord) {
    throw 'FAIL: synthetic pointer 9 is not filtered before chord/recursion handling'
}
$cancelDispatch = $source.IndexOf('if (phase == WZHUDPointerPhaseCancelled)', $chord, [StringComparison]::Ordinal)
$pendingKind = $source.IndexOf('if (!pending_kind(phase, &kind))', $chord, [StringComparison]::Ordinal)
if ($cancelDispatch -lt 0 -or $pendingKind -lt 0 -or $cancelDispatch -gt $pendingKind) {
    throw 'FAIL: HID Cancel does not end aim/calibration before pending-kind fail-closed handling'
}
$directReturn = $source.IndexOf('if (g_directInteractionEnabled && g_sceneActive.load()) return;', $chord, [StringComparison]::Ordinal)
$aimRoute = $source.IndexOf('if (routeAim)', $chord, [StringComparison]::Ordinal)
if ($aimRoute -lt 0 -or $directReturn -lt 0 -or $aimRoute -gt $directReturn) {
    throw 'FAIL: foreground HID skill events are discarded before entering the aim lifecycle'
}

Need 'handle_scene_activity_main\(BOOL active\)[\s\S]{0,260}cancel_aim_touch_drag_main\(\)' 'background transition does not cancel the drag'
Need 'apply_orientation_main\([\s\S]{0,600}cancel_aim_touch_drag_main\(\)' 'rotation/geometry change does not invalidate calibration use'
Need 'destroy_hud_main\(void\)[\s\S]{0,160}cancel_aim_touch_drag_main\(\)' 'HUD teardown does not cancel the drag'
Need 'if \(!connected\)[\s\S]{0,120}cancel_aim_touch_drag_main\(\)' 'transport disconnect does not cancel the drag'
Need 'if \(!enabled\) cancel_aim_touch_drag_main\(\)' 'disabling aim does not cancel the drag'

Reject 'aim\.official"|44001|aimSkillPanned|游戏原始释放|AIM 悬浮按钮' 'legacy release/button route remains in the HUD'
Reject 'WZAimObserver|wzaim_runtime_is_ready\(' 'HUD still depends on the old observer/write-ready path'

'PASS: calibrated external aim HUD lifecycle and fail-open gates'
