$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$consumer = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'lara/kexploit/wzesp.mm')
$rules = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'lara/kexploit/WZAXFeatureRules.h')

function Require([string]$text, [string]$pattern, [string]$message) {
    if ($text -notmatch $pattern) { throw $message }
}

Require $consumer 'autoKillSampleValid[\s\S]{0,100}autoKillGateA != 0[\s\S]{0,100}autoKillGateB != 0' `
    'autokill gate validity/fields changed'
Require $consumer 'wzax_auto_kill_first_eligible' `
    'autokill no longer selects the first producer-order candidate'
Require $consumer 'category != KoiEntityCategoryHero[\s\S]{0,100}!entity\.enemy[\s\S]{0,140}!entity\.axPositionValid[\s\S]{0,100}!entity\.axHealthValid[\s\S]{0,100}entity\.axDead' `
    'autokill candidate field gates changed'
Require $consumer 'g_autoKillSubmitBusy\.exchange\(' `
    'AX action-byte claim is missing'
Require $consumer 'wzax_touch_tap_async\([\s\S]{0,220}FinishAXAutoKillSubmission' `
    'autokill does not retain ownership through the asynchronous sender'
Require $consumer 'FinishAXAutoKillSubmission[\s\S]{0,280}g_autoKillSubmitBusy\.store\(0, std::memory_order_release\)' `
    'sender completion does not release the submit owner'
Require $consumer 'g_autoKillSubmitToken\.fetch_add\(1, std::memory_order_acq_rel\)' `
    'sender completion generation guard is missing'
Require $rules 'first predicate pass \(0x10079f968\.\.0x10079f9f4\)' `
    'target-order rule is not tied to AX instruction evidence'

if ($consumer -match 'g_autoKillNextAllowed' -or
    $consumer -match 'now \+ UINT64_C\(1000000000\)') {
    throw 'legacy one-second consumer cooldown remains'
}

Write-Host 'PASS: AX autokill scheduling and field contracts'
