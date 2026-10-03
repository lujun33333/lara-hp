$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot

function Read-Source([string]$Path) {
    return Get-Content -LiteralPath (Join-Path $root $Path) -Raw -Encoding UTF8
}

function Require-Text([string]$Path, [string]$Pattern, [string]$Message) {
    $content = Read-Source $Path
    if ($content -notmatch $Pattern) {
        throw $Message
    }
}

function Reject-Text([string]$Path, [string]$Pattern, [string]$Message) {
    $content = Read-Source $Path
    if ($content -match $Pattern) {
        throw $Message
    }
}

Require-Text 'lara/kexploit/wz/KoiProjection.mm' `
    'kKoiMatrixRootRVA\s*=\s*0x12CA9580' `
    '矩阵 RVA 被诊断改动意外更改'
Require-Text 'lara/kexploit/wz/YuanbaoCollector.mm' `
    'kActorRootRVA\s*=\s*0x1325A6C0' `
    'ActorRoot RVA 被诊断改动意外更改'
Require-Text 'lara/kexploit/wz/KoiProjection.mm' `
    'KoiMatrixChainStageRootSlotZero' `
    '未区分矩阵 root slot 为 0'
Require-Text 'lara/kexploit/wz/KoiProjection.mm' `
    'KoiMatrixChainStageMatrixInvalid' `
    '未区分矩阵内容无效'
Require-Text 'lara/kexploit/wz/YuanbaoCollector.mm' `
    'KoiActorChainStageManager' `
    '未区分 ActorRoot 一级链失败'
Require-Text 'lara/kexploit/wzesp.mm' `
    'kChainDiagnosticIntervalFrames\s*=\s*300' `
    '采集链诊断没有 300 帧限频'
Require-Text 'lara/kexploit/wzesp.mm' `
    'changed[\s\S]*intervalElapsed[\s\S]*profile-chain' `
    '采集链诊断未按状态变化或周期输出'
Require-Text 'lara/kexploit/wzesp.mm' `
    'unity=0x%llx[\s\S]*rva=0x12ca9580[\s\S]*rva=0x1325a6c0' `
    '诊断行缺少 UnityBase 或根 RVA 证据'
Require-Text 'lara/kexploit/wzesp.mm' `
    'owner=0x%llx holder=0x%llx camera=0x%llx address=0x%llx' `
    '诊断行未保留矩阵链的已成功指针'
Require-Text 'lara/kexploit/wzesp.mm' `
    'actor=\{stage=%s[\s\S]*slot=0x%llx root=0x%llx[\s\S]*manager=0x%llx' `
    '诊断行未保留 ActorRoot slot/root/manager'

$readOnlyFiles = @(
    'lara/kexploit/wz/KoiProjection.mm',
    'lara/kexploit/wz/YuanbaoCollector.mm',
    'lara/kexploit/wzesp.mm'
)
foreach ($path in $readOnlyFiles) {
    Reject-Text $path '\bwz_write\s*\(' "诊断代码不得写目标进程: $path"
}

Write-Host 'PASS: WZ collector chain diagnostics are staged, rate-limited, and read-only.'
