$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Get-Content -LiteralPath (Join-Path $root 'lara/kexploit/wz/WZAXTouch.mm') -Raw -Encoding UTF8
$header = Get-Content -LiteralPath (Join-Path $root 'lara/kexploit/wz/WZAXTouch.h') -Raw -Encoding UTF8
$bridge = Get-Content -LiteralPath (Join-Path $root 'lara/kexploit/WZHUDBridge.mm') -Raw -Encoding UTF8
$pending = Get-Content -LiteralPath (Join-Path $root 'lara/kexploit/wz/WZHUDPendingTouchQueue.h') -Raw -Encoding UTF8
$entitlements = Get-Content -LiteralPath (Join-Path $root 'Config/lara.entitlements') -Raw -Encoding UTF8
$buildScript = Get-Content -LiteralPath (Join-Path $root 'scripts/build_ipa_wz.sh') -Raw -Encoding UTF8
function Require([string]$pattern, [string]$message) {
    if ($source -notmatch $pattern) { throw "FAIL: $message" }
}
function Require-Header([string]$pattern, [string]$message) {
    if ($header -notmatch $pattern) { throw "FAIL: $message" }
}
function Require-Bridge([string]$pattern, [string]$message) {
    if ($bridge -notmatch $pattern) { throw "FAIL: $message" }
}
function Require-Pending([string]$pattern, [string]$message) {
    if ($pending -notmatch $pattern) { throw "FAIL: $message" }
}
function Require-Entitlement([string]$pattern, [string]$message) {
    if ($entitlements -notmatch $pattern) { throw "FAIL: $message" }
}
function Require-Build([string]$pattern, [string]$message) {
    if ($buildScript -notmatch $pattern) { throw "FAIL: $message" }
}
# Binary-derived ABI contract: AX128 0x100833308..0x10083331c sets x0..x4.
Require 'Ref \(\*createVirtual\)\(Ref, CFDictionaryRef, const VirtualCallbacksV2 \*, void \*, void \*\)' 'VirtualService create ABI must have five arguments'
Require 'serviceProperties\(\), &callbacks, token, token\)' 'VirtualService properties/generation arguments missing'
Require 'SecTaskCopyValueForEntitlement' 'Runtime effective-entitlement probe is missing'
Require 'CFSTR\("platform-application"\)' 'Platform entitlement is not checked at runtime'
Require 'CFSTR\("com\.apple\.private\.hid\.client\.event-dispatch"\)' 'HID dispatch entitlement is not checked at runtime'
Require 'CFSTR\("com\.apple\.private\.hid\.client\.service-protected"\)' 'Protected HID service entitlement is not checked at runtime'
Require 'CFSTR\("com\.apple\.private\.hid\.manager\.client"\)' 'HID manager entitlement is not checked at runtime'
Require 'create-service probe mode=local[\s\S]{0,500}callbacks=v%llu/%zu[\s\S]{0,300}order=set-queue>activate>create-virtual' 'CreateVirtual ABI/order diagnostic is missing'
Require-Entitlement '<key>platform-application</key>\s*<true/>' 'Requested platform entitlement is missing'
Require-Entitlement '<key>com\.apple\.private\.hid\.client\.event-dispatch</key>\s*<true/>' 'Requested HID dispatch entitlement is missing'
Require-Entitlement '<key>com\.apple\.private\.hid\.client\.service-protected</key>\s*<true/>' 'Requested protected HID service entitlement is missing'
Require-Entitlement '<key>com\.apple\.private\.hid\.manager\.client</key>\s*<true/>' 'Requested HID manager entitlement is missing'
Require-Build 'codesign -d --entitlements :- "\$BIN" >"\$SIGNED_ENTITLEMENTS"' 'Build does not read back final executable entitlements'
Require-Build 'missing signed entitlement keys' 'Build does not reject missing signed entitlement keys'
Require-Build 'mismatched signed entitlement values' 'Build does not reject changed signed entitlement values'
Require 'token != generation \|\| service != virtualService' 'Late service notification may activate a replacement host'
Require 'CFNumberGetValue\(\(CFNumberRef\)value, kCFNumberSInt64Type, &result\)' 'Registry ID must be converted from CFNumber'
# AX Pro v1.2.8 dispatches in-process regardless of HUD layer hosting.
Require 'AX_HID\(dispatchEvent, "IOHIDEventSystemClientDispatchEvent"\)' 'Local IOHID dispatch symbol is not resolved'
Require 'bool dispatchLocal\(Ref event\)[\s\S]{0,220}api\.dispatchEvent\(localClient, event\)' 'Local dispatch does not use our own system client'
Require 'const bool result = dispatchLocal\(parent\)' 'Parent event is not dispatched locally'
if ($source -match 'RemoteCall|remoteCreateEvent|remoteCreateClient|remoteDispatch|\btransmit\(') {
    throw 'FAIL: touch sender carries a cross-process HID transport'
}
if ($header -match '@class RemoteCall|RemoteCall \*|wzax_touch_set_host') {
    throw 'FAIL: touch API still exposes a SpringBoard host'
}
Require-Bridge 'BOOL senderReady = wzax_touch_start\(\)' 'HUD startup can still short-circuit local HID initialization'
Require-Bridge 'if \(success\) \{[\s\S]{0,220}invalidate_pending_touch_actions\(\)[\s\S]{0,320}\(void\)wzax_touch_start\(\)' 'SpringBoard hosting does not preserve the local HID sender'
if ($bridge -match 'wzax_touch_set_host|!g_localHostingReady\.load\(\) \|\| wzax_touch_start') {
    throw 'FAIL: hosting mode can replace or skip the local HID sender'
}
Require 'attribute\(parent, 0xb0007, values.parentMask\)' 'Parent phase mask is absent'
Require 'attribute\(parent, 0xb0016, 1\)' 'Parent integrated-display attribute is absent'
Require 'api\.append\(parent, finger, 1\)' 'AX parent append options changed'
Require 'oldVirtual\) \{ api\.removeVirtual\(oldVirtual\); CFRelease\(oldVirtual\); \}' 'Virtual service cleanup order changed'
Require 'oldClient\) \{ api\.cancel\(oldClient\); CFRelease\(oldClient\); \}' 'System client cleanup order changed'
Require-Header 'wzax_touch_drag_begin_async' 'Drag begin API missing'
Require-Header 'wzax_touch_drag_move_async' 'Drag move API missing'
Require-Header 'wzax_touch_drag_end_async' 'Drag end API missing'
Require-Header 'wzax_touch_drag_cancel_async' 'Drag cancel API missing'
Require-Header 'bool wzax_touch_is_ready\(void\)' 'Read-only sender readiness API missing'
Require 'bool wzax_touch_is_ready\(void\) \{[\s\S]{0,100}return ready\.load\(std::memory_order_acquire\);[\s\S]{0,20}\}' 'Sender readiness API is not the real notification-backed atomic state'
Require-Header 'ownsSession\(uint64_t senderGeneration,[\s\S]{0,120}uint64_t session, uint64_t reservation' 'Touch session generation policy missing'
Require 'std::atomic<uint64_t> touchReservation' 'Tap and drag do not share one exclusive reservation'
Require 'std::atomic<uint64_t> nextTouchSession' 'Each tap/drag does not receive a unique session token'
Require 'touchReservation\.compare_exchange_strong' 'Touch submission must remain nonblocking'
if ($source -match '\btapPending\b') { throw 'FAIL: separate tap reservation permits tap/drag interleaving' }
Require 'dragAcceptingSession\.compare_exchange_strong' 'Drag begin does not open one lifecycle session'
Require 'dragAcceptingSession\.exchange\(0' 'Drag terminal does not close submissions atomically'
Require 'ownsCurrentSession\(senderGeneration, session\)' 'Queued actions do not reject stale sender/session pairs'
Require 'send\(fixed\.x, fixed\.y, wzax_touch_policy::Down\)[\s\S]{0,260}dragActive = true[\s\S]{0,180}dragSenderGeneration = senderGeneration[\s\S]{0,100}dragSession = session' 'Drag begin does not establish the active contact'
Require 'send\(fixed\.x, fixed\.y, wzax_touch_policy::Move\)' 'Drag move HID phase missing'
Require 'send\(releaseX, releaseY, wzax_touch_policy::Up\)[\s\S]{0,220}dragActive = false' 'Drag terminal does not release its contact'
Require 'wzax_touch_drag_cancel_async[\s\S]{0,180}enqueueDragTerminal\(CGPointZero, true' 'Drag cancel does not release at the last submitted point'
Require 'void clear\(\) \{[\s\S]{0,420}releaseActiveDrag\(\);[\s\S]{0,120}\+\+generation' 'Shutdown does not release the active contact before invalidating its generation'
Require 'void releaseActiveDrag\(\)[\s\S]{0,180}send\(dragLastX, dragLastY, wzax_touch_policy::Up\)' 'Shutdown release does not use the active drag coordinates'
Require 'if \(NSThread\.isMainThread\) readSurface\(\);[\s\S]{0,120}dispatch_sync\(dispatch_get_main_queue\(\), readSurface\)' 'UIScreen surface metrics are read off the main thread'
Require 'bool convertToFixedPoint[\s\S]{0,700}if \(NSThread\.isMainThread\) convert\(\);[\s\S]{0,120}dispatch_sync\(dispatch_get_main_queue\(\), convert\)' 'Shared UIKit fixed-space conversion is performed off the main thread'
$fixedConversions = [regex]::Matches($source, 'convertToFixedPoint\(x, y, fixedSpace, &fixed\)').Count
if ($fixedConversions -ne 4) { throw "FAIL: tap/begin/move/end must share fixed-space conversion, got $fixedConversions call sites" }
Require 'start failed stage=create-client mode=local' 'Touch start does not report client creation stage'
Require 'start failed stage=create-service mode=local[\s\S]{0,120}effective-entitlements=%s' 'Touch start does not classify virtual-service entitlement evidence'
Require 'if \(!virtualService\) \{[\s\S]{0,320}start failed stage=create-service mode=local[\s\S]{0,180}clear\(\);[\s\S]{0,80}return;' 'CreateVirtual failure must remain fail-closed'
Require-Pending 'struct PendingTouchAction[\s\S]{0,280}pointerID[\s\S]{0,160}kind[\s\S]{0,160}expirationTime[\s\S]{0,220}actionBlock' 'Pending touch action does not preserve AX fields'
Require-Pending 'AtomicGesture = 3' 'AX kind 3 must remain the point-only/timed gesture kind, not physical Cancel'
Require-Pending 'kExpirationInterval = 0\.75' 'AX 0x10087b06c expiration interval changed'
Require-Pending 'void reset\(std::uint64_t generation\)[\s\S]{0,180}actions_\.clear\(\)' 'Pending queue reset does not clear work'
Require-Pending 'action\.kind == Kind::Moved[\s\S]{0,260}actions_\.back\(\)[\s\S]{0,260}tail\.kind == Kind::Moved[\s\S]{0,220}tail\.pointerID == action\.pointerID[\s\S]{0,220}tail = std::move\(action\)' 'AX tail-only same-pointer Move replacement changed'
Require-Pending 'it->kind == Kind::AtomicGesture[\s\S]{0,180}actions_\.erase\(it\)[\s\S]{0,360}result\.lifecycleDropped = true[\s\S]{0,180}actions_\.clear\(\)' 'AX kind-3 prune / lifecycle batch-clear order changed'
if ($pending -match 'maxDepth|Kind::Cancelled|activePointers_') { throw 'FAIL: guessed depth/cancel/pointer-state policy returned' }
Require-Bridge 'dispatch_queue_create\("com\.coldcheat\.simtouch", DISPATCH_QUEUE_SERIAL\)' 'AX pending actions are not confined to the recovered serial queue'
$pathLoop = $bridge.IndexOf('for (WZHUDAXEventPath *path in paths)', [StringComparison]::Ordinal)
$pathIdentity = $bridge.IndexOf('path.pathIdentity', $pathLoop, [StringComparison]::Ordinal)
$multiPath = $bridge.IndexOf('if (paths.count != 1)', $pathIdentity, [StringComparison]::Ordinal)
$singlePath = $bridge.IndexOf('pointerIDs.firstObject.longLongValue', $multiPath, [StringComparison]::Ordinal)
if ($pathLoop -lt 0 -or $pathIdentity -lt 0 -or $multiPath -lt 0 -or
    $singlePath -lt 0 -or $singlePath - $pathLoop -gt 1800) {
    throw 'FAIL: AX pathIdentity is not preserved for multi-pointer chords and single-pointer dispatch'
}
Require-Bridge 'pending_kind\(phase, &kind\)[\s\S]{0,260}fail-closed reset pointer' 'Physical Cancel must fail closed instead of being guessed as AX kind 3'
Require-Bridge 'PendingTouchAction pending\{[\s\S]{0,180}pointerID[\s\S]{0,180}kind[\s\S]{0,180}expirationTime[\s\S]{0,180}generation' 'HID callback does not create a structured pending action'
Require-Bridge 'timestamp=CFAbsoluteTimeGetCurrent\(\)[\s\S]{0,2200}timestamp \+ wzhud_pending_touch::kExpirationInterval' 'AX CFAbsoluteTime + 0.75 expiration source changed'
Require-Pending 'canExecute\(const PendingTouchAction &action,[\s\S]{0,520}now < action\.expirationTime[\s\S]{0,240}action\.generation == currentGeneration' 'Execution policy does not recheck expiration and generation'
Require-Bridge 'popNext\(CFAbsoluteTimeGetCurrent\(\), generation,[\s\S]{0,120}&action, &expiredPointerID\)[\s\S]{0,1200}canExecute\(' 'Expiration is not rechecked before main-thread execution'
Require-Bridge 'expiredLifecycle[\s\S]{0,700}finish_expired_lifecycle_pointer_main\(pending->pointerID\)[\s\S]{0,300}g_pendingTouchActions\.discardAll\(\)' 'Expired AX lifecycle does not clear the queued batch and retained HUD pointer'
Require-Bridge 'invalidate_pending_touch_actions_main\(void\)[\s\S]{0,180}g_pendingTouchGeneration\.fetch_add\(1\)[\s\S]{0,500}g_pendingTouchActions\.reset\(generation\)' 'Pending queue invalidation does not advance generation and clear state'
Require-Bridge 'handle_scene_activity_main\(BOOL active\)[\s\S]{0,500}invalidate_pending_touch_actions_main\(\)' 'Scene inactivity does not invalidate pending touch work'
Require-Bridge 'destroy_hud_main\(void\)[\s\S]{0,500}invalidate_pending_touch_actions_main\(\)' 'HUD teardown does not invalidate pending touch work'
Require-Bridge 'g_localHostingReady\.store\(ready\)[\s\S]{0,220}if \(ready\) \{[\s\S]{0,120}invalidate_pending_touch_actions_main\(\)' 'Local hosting replacement does not invalidate pending touch work'
Require-Bridge 'g_springBoardHostingInFlight\.store\(false\)[\s\S]{0,180}if \(success\) \{[\s\S]{0,120}invalidate_pending_touch_actions\(\)' 'SpringBoard hosting replacement does not invalidate pending touch work'
Require-Bridge 'static BOOL unregister_local_hosting_main\(void\) \{[\s\S]{0,360}invalidate_pending_touch_actions_main\(\)' 'Local hosting teardown does not invalidate pending touch work'
Require-Bridge 'g_springBoardHostingReady\.store\(false\)[\s\S]{0,260}invalidate_pending_touch_actions\(\)[\s\S]{0,160}if \(!hadHosts\)' 'SpringBoard no-host teardown can retain pending touch work'
'PASS: AX128 SimTouch ABI, binary-derived pending queue, lifecycle and nonblocking submission contracts'
