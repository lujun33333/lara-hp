$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bridge = Get-Content -LiteralPath (Join-Path $root 'lara/kexploit/WZHUDBridge.mm') -Raw -Encoding UTF8
$header = Get-Content -LiteralPath (Join-Path $root 'lara/kexploit/WZHUDBridge.h') -Raw -Encoding UTF8
$manager = Get-Content -LiteralPath (Join-Path $root 'lara/classes/laramgr.swift') -Raw -Encoding UTF8
$app = Get-Content -LiteralPath (Join-Path $root 'lara/lara.swift') -Raw -Encoding UTF8

function Require([string]$text, [string]$pattern, [string]$message) {
    if ($text -notmatch $pattern) { throw "FAIL: $message" }
}

Require $bridge 'commit_menu_window_geometry_main\(void\)[\s\S]{0,260}layoutIfNeeded[\s\S]{0,140}setNeedsDisplay[\s\S]{0,140}displayIfNeeded[\s\S]{0,140}CATransaction flush' `
    'commitMenuWindowGeometry@0x10000596c order changed'
Require $bridge 'flush_menu_window_for_display_main\(void\)[\s\S]{0,500}hidden = NO[\s\S]{0,100}alpha = 1\.0[\s\S]{0,180}rootView\.hidden = NO[\s\S]{0,100}rootView\.alpha = 1\.0[\s\S]{0,140}makeKeyAndVisible[\s\S]{0,140}commit_menu_window_geometry_main' `
    'flushMenuWindowForDisplay@0x100005c04 order changed'
Require $bridge 'BOOL menuPublished = present_menu_window_main\(\);[\s\S]{0,180}register_local_hosting_side_main\(1\)[\s\S]{0,260}g_window = hudScene[\s\S]{0,700}register_local_hosting_side_main\(0\)' `
    'AX didFinish menu publish/register must precede draw window creation/register'
Require $bridge 'wzhud_hosting_outcome\(menuReady, drawReady\)' `
    'TT/TF/FT/FF hosting outcome policy is not wired'
Require $bridge 'BOOL drawRemoved =[\s\S]{0,300}BOOL menuRemoved =[\s\S]{0,600}g_drawHostingController = nil;[\s\S]{0,180}g_menuHostingController = nil;' `
    'local unregister must run draw then menu and clear both fields unconditionally'
Require $bridge 'com\.axpro\.hud\.request-termination' `
    'exact AX Darwin termination notification is absent'
Require $bridge 'wzhud_try_begin_termination\(&g_hudTerminationRequested\)' `
    'requestHUDTermination@0x100007aac one-shot gate is absent'
Require $header 'void wzhud_request_termination_sync\(void\);' `
    'waitable local teardown entry is not exported'
Require $bridge 'void wzhud_request_termination_sync\(void\)[\s\S]{0,300}NSThread\.isMainThread[\s\S]{0,140}dispatch_sync\(dispatch_get_main_queue\(\)' `
    'off-main local teardown does not wait for main completion'
Require $manager 'DispatchQueue\.getSpecific\(key: wzWorkerKey\) == 1[\s\S]{0,160}wzWorker\.sync\(execute: body\)' `
    'cleanup helper is not direct-on-same/sync-on-other queue'
Require $manager 'wzPendingRemoteCleanup\[key\] = remoteProcess[\s\S]{0,1800}pendingSnapshot = Array\(wzPendingRemoteCleanup\.values\)[\s\S]{0,260}destroyRemoteCallOnWorker\(pendingProcess\)' `
    'failed RemoteCall destruction is not deduplicated and retried'
Require $manager 'wzhud_remote_cleanup_succeeded\(remoteProcess\.destroy\(\)\)' `
    'RemoteCall destroy status is not consumed by the tested retry policy'
Require $manager 'func terminateWZSession\(\)[\s\S]{0,700}guard !wzTerminating[\s\S]{0,700}drainWZRemoteTeardown\(\)[\s\S]{0,120}wzhud_request_termination_sync\(\)[\s\S]{0,120}drainWZReaderTeardown\(\)[\s\S]{0,120}stopBackgroundAudio\(\)' `
    'application termination order is not remote -> local HUD -> reader -> audio'
Require $app 'applicationWillTerminate[\s\S]{0,180}terminateWZSession\(\)' `
    'AppDelegate termination does not enter the ordered manager teardown'
Require $app 'bootstrapLaraApplication\(\)[\s\S]{0,300}wzhud_install_termination_notification\(\)' `
    'Darwin termination notification is not installed during bootstrap'

'PASS: AX 1.2.8 HUD geometry, hosting, notification and teardown contracts'
