$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$header = Get-Content -LiteralPath (Join-Path $root 'lara/kexploit/TaskRop/RemoteCall.h') -Raw -Encoding UTF8
$source = Get-Content -LiteralPath (Join-Path $root 'lara/kexploit/TaskRop/RemoteCall.m') -Raw -Encoding UTF8
$policy = Get-Content -LiteralPath (Join-Path $root 'lara/kexploit/TaskRop/RemoteCallCleanupState.h') -Raw -Encoding UTF8

function Require([string]$text, [string]$pattern, [string]$message) {
    if ($text -notmatch $pattern) { throw "FAIL: $message" }
}

Require $header '_creatingExtraThread;[\s\S]{0,80}_extraThreadExitConfirmed;[\s\S]{0,80}_destroying;[\s\S]{0,80}_cleanupPending;[\s\S]{0,80}_firstExceptionPort;' `
    'RemoteCall ivar order no longer matches AX Qv8Kp2ZmR5 +0x10..+0x14'
Require $policy 'RC_CLEANUP_BUSY[\s\S]{0,120}RC_CLEANUP_FINALIZE[\s\S]{0,120}RC_CLEANUP_CONFIRM_EXTRA_THREAD' `
    'portable cleanup policy is incomplete'
Require $source 'rc_cleanup_begin\([\s\S]{0,300}_destroying[\s\S]{0,180}RC_CLEANUP_BUSY[\s\S]{0,120}return -1' `
    'destroyRemoteCall is not guarded against reentry'
Require $source 'cleanupAction == RC_CLEANUP_CONFIRM_EXTRA_THREAD[\s\S]{0,180}\(!_success \|\| !_trojanMem\)[\s\S]{0,350}rc_cleanup_defer' `
    'active worker without an established synchronous call context is not kept pending'
Require $source 'RemoteArbCallWithTimeout\(-1, self, pthread_exit, 0\)[\s\S]{0,300}rc_cleanup_mark_extra_thread_exited[\s\S]{0,1200}mach_port_destruct\(mach_task_self_, _firstExceptionPort' `
    'existing synchronous worker exit is not confirmed before port release'
Require $source 'cleanupAction == RC_CLEANUP_CONFIRM_EXTRA_THREAD[\s\S]{0,180}!_extraThreadExitConfirmed[\s\S]{0,350}rc_cleanup_defer[\s\S]{0,350}mach_port_destruct\(mach_task_self_, _firstExceptionPort' `
    'local ports can be released before the existing worker exit is confirmed'
Require $source 'restoreTrojanThreadWithState:&_originalState\]\)[\s\S]{0,260}RemoteCall cleanup pending: original thread[\s\S]{0,220}rc_cleanup_defer' `
    'failed existing restore path does not remain pending for a retry'
Require $source 'mach_port_destruct\(mach_task_self_, _firstExceptionPort[\s\S]{0,500}mach_port_destruct\(mach_task_self_, _secondExceptionPort[\s\S]{0,1300}pthread_cancel\(_dummyThread\)' `
    'existing port and dummy-thread release order changed'
Require $source 'rc_cleanup_complete\([\s\S]{0,300}_extraThreadExitConfirmed[\s\S]{0,300}_cleanupPending' `
    'completed teardown does not clear lifecycle state'

if ($source -match 'void mig_bypass_(init|start|resume|pause|monitor_threads)[\s\S]{0,120}\{[^\}]*[^\s\}]') {
    # Existing stubs are deliberately out of scope. This guard only rejects a
    # lifecycle patch that silently adds behavior to them.
    $diff = git -C $root diff -U0 -- 'lara/kexploit/TaskRop/RemoteCall.m'
    if ($diff -match '^\+.*mig_bypass_' ) {
        throw 'FAIL: MIG bypass stubs were modified without recovered control flow'
    }
}

'PASS: AX RemoteCall local lifecycle, idempotence and release-order contracts'
