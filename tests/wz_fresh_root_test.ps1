$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot

function Read-Source([string]$Path) {
    return Get-Content -LiteralPath (Join-Path $root $Path) -Raw -Encoding UTF8
}

function Require-Text([string]$Path, [string]$Pattern, [string]$Message) {
    if ((Read-Source $Path) -notmatch $Pattern) {
        throw "FAIL: $Message ($Path)"
    }
}

function Reject-Text([string]$Path, [string]$Pattern, [string]$Message) {
    if ((Read-Source $Path) -match $Pattern) {
        throw "FAIL: $Message ($Path)"
    }
}

Require-Text 'lara/kexploit/wzmem.h' `
    'wz_read_fresh_root\s*\(' `
    '缺少一级根 fresh-read API'
Require-Text 'lara/kexploit/wzmem.m' `
    'wz_mcache_evict_page_locked[\s\S]*entry->page != page[\s\S]*wz_release_mapping' `
    'mapped-pages 未精确淘汰目标页'
Require-Text 'lara/kexploit/wzmem.m' `
    'wz_read_fresh_root[\s\S]*pthread_mutex_lock\(&g_wzMemoryLock\)[\s\S]*wz_mcache_evict_page_locked\(g_wzDefaultPages, page\)[\s\S]*wz_mapped_page\(g_wzDefaultPages, page\)' `
    'fresh-read 未在同一锁内淘汰并重建目标页'
Require-Text 'lara/kexploit/wzmem.m' `
    'WZ_TRANSPORT_MACH_TASK[\s\S]*wz_mach_read_locked\(addr, buffer, size\)' `
    'Mach task 路径未保持直接读取'
Require-Text 'lara/kexploit/wzmem.m' `
    'wz_release_mapping[\s\S]*mach_vm_deallocate\(mach_task_self_, sh->localAddress, PAGE_SIZE\)[\s\S]*mach_port_deallocate\(mach_task_self_, \(mach_port_name_t\)sh->port\)' `
    '全缓存失效没有同时释放0x4000 alias和Mach port'
Require-Text 'lara/kexploit/wzmem.m' `
    'void wz_invalidate_read_cache\(void\)[\s\S]*pthread_mutex_lock\(&g_wzMemoryLock\)[\s\S]*for \(struct wzmcache \*c = g_wzCaches; c; c = c->nextCache\)[\s\S]*wz_clear_cache\(c\)[\s\S]*pthread_mutex_unlock\(&g_wzMemoryLock\)' `
    '缺少不掉连接的全read/mapped alias缓存失效'
$memory = Read-Source 'lara/kexploit/wzmem.m'
$invalidateStart = $memory.IndexOf('void wz_invalidate_read_cache(void)')
$disconnectStart = $memory.IndexOf('void wz_disconnect(void)', $invalidateStart)
if ($invalidateStart -lt 0 -or $disconnectStart -le $invalidateStart) {
    throw 'FAIL: 无法提取read cache invalidate函数'
}
$invalidate = $memory.Substring($invalidateStart, $disconnectStart - $invalidateStart)
if ($invalidate -match 'g_wzVmMap\s*=' -or
    $invalidate -match 'g_wzProc\s*=' -or
    $invalidate -match 'g_wzMachTask\s*=' -or
    $invalidate -match 'g_wzTransport\s*=' -or
    $invalidate -match 'g_wzCapabilities\s*=' -or
    $invalidate -match 'g_wzPid\s*=' -or
    $invalidate -match 'g_wzGeneration\s*(?:\+\+|=)') {
    throw 'FAIL: read cache invalidate错误修改了连接/能力/session generation'
}
Require-Text 'lara/kexploit/wz/YuanbaoCollector.mm' `
    'YuanbaoCollectorResetForTerminalChange[\s\S]*wz_invalidate_read_cache\(\)' `
    'AX terminal reset没有失效底层read/mapped alias缓存'
Require-Text 'lara/kexploit/wz/KoiProjection.mm' `
    'kFreshRootIntervalNanoseconds\s*=\s*UINT64_C\(750000000\)' `
    '矩阵根 fresh-read 未按 750ms 限频'
Require-Text 'lara/kexploit/wz/KoiProjection.mm' `
    'root == 0 \|\| !IsReadablePointer\(root\)[\s\S]*RefreshInvalidMatrixRoot' `
    '矩阵根并非只在 zero/invalid 时 fresh-read'
Require-Text 'lara/kexploit/wz/YuanbaoCollector.mm' `
    'root == 0 \|\| !IsPointer\(root\)[\s\S]*gActorFreshRootProbe' `
    'Actor 根并非只在 zero/invalid 时 fresh-read'
Require-Text 'lara/kexploit/wz/YuanbaoCollector.mm' `
    'root == 0 \|\| !IsPointer\(root\)[\s\S]*gMonsterFreshRootProbe' `
    'Monster 根并非只在 zero/invalid 时 fresh-read'
Require-Text 'lara/kexploit/wz/KoiProjection.mm' `
    'fresh-root matrix cached=0x%llx[\s\S]*fresh=0x%llx rebuild=%llu' `
    '矩阵 fresh-read 缺少 cached/fresh/rebuild 诊断'
Require-Text 'lara/kexploit/wz/YuanbaoCollector.mm' `
    'fresh-root %s cached=0x%llx[\s\S]*fresh=0x%llx rebuild=%llu' `
    '实体 fresh-read 缺少 cached/fresh/rebuild 诊断'

$readOnlyFiles = @(
    'lara/kexploit/wz/KoiProjection.mm',
    'lara/kexploit/wz/YuanbaoCollector.mm',
    'lara/kexploit/wzesp.mm'
)
foreach ($path in $readOnlyFiles) {
    Reject-Text $path '\bwz_write\s*\(' "一级根修复不得写目标进程: $path"
}

Write-Host 'PASS: WZ root slots use rate-limited, read-only mapped-page refresh.'
