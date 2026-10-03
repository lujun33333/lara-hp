$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$header = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'lara/kexploit/wzesp.h')
$consumer = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'lara/kexploit/wzesp.mm')
$collector = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'lara/kexploit/wz/YuanbaoCollector.mm')
$types = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'lara/kexploit/wz/KoiTypes.h')
function Require([string]$text, [string]$pattern, [string]$reason) {
    if ($text -notmatch $pattern) { throw $reason }
}
Require $header 'WZESP_SHOW_HERO_VISION\s*=\s*1u\s*<<\s*15' 'AX hero vision needs its own flag'
Require $header 'WZESP_SHOW_SOLDIER_VISION\s*=\s*1u\s*<<\s*16' 'AX soldier vision needs its own flag'
Require $header 'WZESP_PRIMITIVE_EXPOSURE_POINT\s*=\s*4' 'AX exposure point primitive missing'
Require $collector 'offsets\[\]\{[\s\S]{0,80}0x123FBC88, 0x138, 0x2C8, 0x48, 0x170, 0x150' 'AX decoded host chain changed'
Require $collector 'ResolveAXCachedChainAddress\([\s\S]{0,140}std::size\(offsets\)' 'Host position must use the AX two-second terminal-address cache'
Require $collector 'position\[2\]\) / 1000\.0f' 'Host z must come from raw int32 xyz /1000'
Require $collector 'reader\.pointer\(actor, 0x1A0, &state\)' 'AX soldier HP owner changed'
Require $collector 'reader\.field\(state, 0x160, &raw\)' 'AX soldier HP field changed'
Require $collector 'entity->exposureState = raw / 8192' 'AX soldier HP scaling changed'
Require $collector 'heroOffsets\[\]\{0x268, 0x10, 0, 0x60\}' 'AX hero coordinates must use the recovered direct pointer chain'
Require $collector 'rawA / 8192000' 'AX own-state gate scaling changed'
Require $consumer 'wzax_touch_tap_async\([\s\S]{0,120}config\.clickX, config\.clickY,[\s\S]{0,160}FinishAXAutoKillSubmission' 'Auto kill must hold ownership through the recovered asynchronous touch sender'
Require $consumer 'g_autoKillSubmitBusy\.exchange\(' 'Auto kill action-byte claim is missing'
if ($consumer -match 'g_autoKillNextAllowed' -or
    $consumer -match 'now \+ UINT64_C\(1000000000\)') {
    throw 'Reader backoff was incorrectly reused as an autokill success cooldown'
}
Require $consumer 'input\.collectExposure && diagnostics\.hostPositionValid' 'Do not draw a fabricated safe dot when host position cannot be read'
Require $consumer 'hero && dx == 0\.0f && dz == 0\.0f' 'AX excludes coincident hero coordinates'
Require $consumer 'std::fma\(dx, dx, dz \* dz\) <= 144\.0f' 'AX exposure radius squared is exactly 144, with fused multiply-add'
Require $consumer 'item\.minimapExposureValid = 1' 'Minimap visibility must have a live producer'
Require $consumer 'exposed \? 0xFF0000FFu : 0xB40000FFu' 'AX minimap ring bright/dim colors changed'
Require $consumer 'const bool exposed = AXMinimapExposed' 'Do not replace geometric visibility with the legacy visibility byte'
Require $consumer 'config->minimapSize / 30\.0f' 'AX dot radius is mapsize/30'
Require $consumer 'exposed \? 0xFF0000FFu : 0x00FF00FFu' 'AX point must be red/green in the bridge RGBA layout'
Require $collector 'friendlyHeroHeaders' 'Production collector drops AX friendly hero observers'
Require $types 'exposureObserverOnly' 'Friendly hero observers are not isolated from HUD entities'
Require $consumer 'if \(entity\.exposureObserverOnly\)' 'Observer-only heroes can leak into HUD output'
Require $collector 'gAXHostPositionBackoff' 'Host position still shares autokill backoff state'
Require $collector 'gAXAutoKillBackoff' 'Autokill gate lacks independent backoff state'
Require $collector 'monster, i \* kActorStride' 'AX monster exclusion stride is not 0x18'
Require $collector 'UpdateProducerReadiness\(readyCandidate\)' 'Producer miss hysteresis is bypassed'
if ($collector -match 'gProducerReady\s*=\s*readyCandidate' -or
    $collector -match 'reader\.pointer\(monster, i \* 8') {
    throw 'Legacy readiness overwrite or monster i*8 stride remains'
}
Write-Output 'PASS: AX exposure source contracts (static only; no iOS compile or device test)'
