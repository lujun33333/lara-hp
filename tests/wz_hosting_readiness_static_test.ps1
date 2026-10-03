$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$source = Get-Content -LiteralPath (Join-Path $root 'lara/kexploit/WZHUDBridge.mm') -Raw -Encoding UTF8
$manager = Get-Content -LiteralPath (Join-Path $root 'lara/classes/laramgr.swift') -Raw -Encoding UTF8

function Require([string]$pattern, [string]$message) {
    if ($source -notmatch $pattern) { throw "FAIL: $message" }
}

function Reject([string]$pattern, [string]$message) {
    if ($source -match $pattern) { throw "FAIL: $message" }
}

Require 'bool wzhud_local_hosting_ready\(void\)[\s\S]{0,260}g_localHostingReady\.load\(\)[\s\S]{0,100}g_systemWindowMode\.load\(\)' `
    'local readiness does not require a successful hosting-controller registration'
Require 'g_systemWindowMode\.store\(axHosted\)[\s\S]{0,160}g_contextsStable\.store\(axHosted\)[\s\S]{0,160}g_validatedContextMask\.store\(axHosted \? kWZHUDFullContextMask : 0\)' `
    'failed registration can still publish local-ready validation markers'
Require 'hosting=pending mode=unhosted-source[\s\S]{0,180}awaiting SpringBoard fallback' `
    'unhosted source windows are not left pending for the remote fallback'
Require 'bool wzhud_is_enabled\(void\)[\s\S]{0,220}g_localHostingReady\.load\(\)[\s\S]{0,100}wzhud_springboard_hosting_ready\(\)' `
    'enabled state does not require a real local or remote host'
Require 'BOOL menuReady = register_local_hosting_side_main\(1\);[\s\S]{0,120}BOOL drawReady = register_local_hosting_side_main\(0\);[\s\S]{0,160}wzhud_hosting_outcome\(menuReady, drawReady\)' `
    'local registration does not preserve the AX menu-then-draw independent outcomes'
Require 'if \(index == 0\) g_drawHostingController = registered \? controller : nil;[\s\S]{0,120}else g_menuHostingController = registered \? controller : nil;[\s\S]{0,120}g_hostedContextIDs\[index\]\.store\(registered \? context : 0\)' `
    'a successful local side is not retained independently'
$registerMatch = [regex]::Match(
    $source,
    'static BOOL register_local_hosting_main\(void\)\s*\{(?<body>[\s\S]*?)\n\}\n\nbool wzhud_register_springboard_hosts',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)
if (-not $registerMatch.Success) { throw 'FAIL: cannot isolate local hosting registration' }
if ($registerMatch.Groups['body'].Value -match 'if\s*\(!ready\)[\s\S]*unregister_local_hosting_controller') {
    throw 'FAIL: partial local registration is still rolled back before remote fallback'
}
Require 'BOOL drawRemoved =[\s\S]{0,300}BOOL menuRemoved =[\s\S]{0,700}g_drawHostingController = nil;[\s\S]{0,180}g_menuHostingController = nil;' `
    'local unregister is not draw-then-menu with unconditional field clearing'
Require 'g_validatedContextMask\.store\(0\);[\s\S]{0,120}g_menuWindowReady\.store\(false\);[\s\S]{0,120}g_systemWindowMode\.store\(false\)' `
    'teardown leaves stale local-hosting mode behind'
Reject 'hosting=ready mode=system-window' `
    'bare UIWindowScene source windows are still reported as cross-app ready'
Require 'springboard_hosting_state_valid_locked[\s\S]{0,500}g_springBoardHostWindows\[index\][\s\S]{0,120}g_springBoardHostLayers\[index\][\s\S]{0,220}g_springBoardHostedContextIDs\[index\]\.load\(\)!=g_windowContextIDs\[index\]' `
    'remote readiness does not validate handles and current source contexts'
Require 'bool wzhud_springboard_hosting_ready\(void\)[\s\S]{0,220}springboard_hosting_state_valid_locked\(nil\)[\s\S]{0,120}g_springBoardHostingReady\.store\(false\)' `
    'stale remote readiness is not cleared'
if ($manager -notmatch 'prepareWZSpringBoardHosting[\s\S]{0,1800}if wzhud_springboard_hosting_ready\(\)[\s\S]{0,250}completion\(true\)' -or
    $manager -notmatch 'let registered = wzhud_register_springboard_hosts\(remoteProcess\)[\s\S]{0,250}registered && wzhud_springboard_hosting_ready\(\)[\s\S]{0,1600}let live = verifiedReady && wzhud_springboard_hosting_ready\(\)') {
    throw 'FAIL: Swift launch path can reuse or report an unverified remote host'
}

Write-Output 'PASS: HUD readiness and independent AX hosting outcomes'
