$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'lara/kexploit/wz/YuanbaoCollector.mm')
$cache = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'lara/kexploit/wz/WZAXActorCache.h')
foreach ($pattern in @('0x1325A828', 'UINT64_C\(350000000\)', 'UINT64_C\(500000000\)', 'count >= 2 && count <= 20', 'count >= 1 && count <= 128', 'ValidYuanbaoWorldRaw', 'ReadAXRawPosition\(reader, actorAddress, true, &minimapRaw\)', '/ 1080\.0f', '/ 1000\.0f', 'seenHeroActors\.insert\(actorAddress\)\.second', 'std::array<uint8_t, 16> bytes')) {
    if ($source -notmatch $pattern) { throw "Missing AX actor production contract: $pattern" }
}
if ($source -match 'kSoldierTableCandidates|count <= 499|count <= 199') { throw 'Legacy actor-table fallback remains active' }
foreach ($pattern in @('i < 600', 'entry.confirmations\+\+ > 0', 'UINT64_C\(100000000\)', 'Unambiguous', 'Same\(entry.pendingRaw, raw\)', 'UINT64_C\(41666667\)', 'UINT64_C\(25000000\)', 'UINT64_C\(20000000000\)', 'record \+ 0x14', 'record \+ 0x20')) {
    if ($cache -notmatch $pattern) { throw "Missing AX cache contract: $pattern" }
}
Write-Output 'PASS: AX actor profile and coordinate-cache static contracts'
