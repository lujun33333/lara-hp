$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$source = Get-Content -LiteralPath (Join-Path $root 'lara/lara.swift') -Raw -Encoding UTF8

function Require([string]$pattern, [string]$message) {
    if ($source -notmatch $pattern) { throw "FAIL: $message" }
}

function Reject([string]$pattern, [string]$message) {
    if ($source -match $pattern) { throw "FAIL: $message" }
}

# AX 1.2.8 ZeqcgKhNvh lifecycle IMPs:
#   DidDisconnect       0x10004cbb4: ret
#   DidBecomeActive     0x10004cbb8: local opaque state loop, no calls
#   WillResignActive    0x10004ce1c: local opaque state loop, no calls
#   WillEnterForeground 0x10004d104: local opaque state loop, no calls
#   DidEnterBackground  0x10004d3d0: ret
# The three longer functions only read opaque-control globals and update their
# own stack state. They make no direct or indirect calls and have no lifecycle
# side effects, so all five Swift callbacks must remain empty.
$callbacks = @(
    'sceneDidBecomeActive',
    'sceneWillResignActive',
    'sceneDidEnterBackground',
    'sceneWillEnterForeground',
    'sceneDidDisconnect'
)
foreach ($callback in $callbacks) {
    $match = [regex]::Match(
        $source,
        "func $callback\(_ scene: UIScene\)\s*\{(?<body>[\s\S]*?)\n\s*\}",
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if (-not $match.Success) {
        throw "FAIL: missing $callback"
    }
    if ($match.Groups['body'].Value.Trim().Length -ne 0) {
        throw "FAIL: AX lifecycle callback $callback gained observable behavior"
    }
}

Require 'func applicationWillTerminate[\s\S]{0,160}laramgr\.shared\.terminateWZSession\(\)' `
    'process termination no longer uses the permanent teardown'
Reject 'func sceneDidDisconnect[\s\S]{0,160}disconnectWZSceneSession\(\)' `
    'scene disconnect still performs non-AX resource teardown'

Write-Output 'PASS: AX scene lifecycle callbacks are side-effect free; process termination cleanup remains wired'
