$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$swift = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'lara/classes/laramgr.swift')
$collector = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'lara/kexploit/wz/YuanbaoCollector.mm')

function Require([string]$Text, [string]$Pattern, [string]$Message) {
    if ($Text -notmatch $Pattern) { throw $Message }
}

Require $swift 'label:\s*"com\.draw\.auxiliary-page-reader",\s*qos:\s*\.utility' `
    'missing AX auxiliary utility queue'
Require $swift 'label:\s*"com\.axpro\.autokill\.reader",\s*qos:\s*\.utility' `
    'missing AX autokill utility queue'
Require $swift 'wzAuxiliaryReader\.async' 'auxiliary reader is not dispatched independently'
Require $swift 'wzAutoKillReader\.async' 'autokill reader is not dispatched independently'
Require $swift 'wzAuxiliaryReaderInFlight' 'auxiliary in-flight coalescing is missing'
Require $swift 'wzAutoKillReaderInFlight' 'autokill in-flight coalescing is missing'

$gatherAt = $collector.IndexOf('size_t YuanbaoCollectorGather(')
if ($gatherAt -lt 0) { throw 'collector gather function missing' }
$gather = $collector.Substring($gatherAt)
if ($gather -match 'UpdateAXAuxiliaryTable\s*\(') {
    throw '16ms gather still performs the auxiliary page read'
}
if ($gather -match 'ReadAXHostPosition\s*\(' -or
    $gather -match 'ReadAXAutoKillState\s*\(') {
    throw '16ms gather still performs autokill/host reader I/O'
}
Require $gather 'gAXAuxiliaryReaderLock' 'gather does not snapshot the auxiliary cache'
Require $gather 'gAXAutoKillReaderLock' 'gather does not snapshot the autokill cache'

$stopAt = $swift.IndexOf('private func stopWZReadersOnWorker()')
$frameAt = $swift.IndexOf('private func wzFrame()', $stopAt)
if ($stopAt -lt 0 -or $frameAt -le $stopAt) { throw 'reader stop helper missing' }
$stop = $swift.Substring($stopAt, $frameAt - $stopAt)
$invalidateAt = $stop.IndexOf('wzesp_readers_stop')
$auxDrainAt = $stop.IndexOf('wzAuxiliaryReader.sync')
$autoDrainAt = $stop.IndexOf('wzAutoKillReader.sync')
if ($invalidateAt -lt 0 -or $auxDrainAt -le $invalidateAt -or
    $autoDrainAt -le $invalidateAt) {
    throw 'teardown does not invalidate before draining both readers'
}

$detachAt = $swift.IndexOf('func wzDetach(')
$setHUDAt = $swift.IndexOf('func setGameHUD(', $detachAt)
$detach = $swift.Substring($detachAt, $setHUDAt - $detachAt)
$stopReadersAt = $detach.IndexOf('stopWZReadersOnWorker')
$resetAt = $detach.IndexOf('wzesp_reset')
$disconnectAt = $detach.IndexOf('wz_disconnect')
if ($stopReadersAt -lt 0 -or $resetAt -le $stopReadersAt -or
    $disconnectAt -le $resetAt) {
    throw 'detach order must be invalidate/drain -> reset -> disconnect'
}

Write-Host 'PASS: AX independent reader scheduler static checks'
