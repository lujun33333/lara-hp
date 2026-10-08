import Darwin
import Foundation

// Local, live owners for the work the current host actually performs.  These
// deliberately never claim a Core v1.7 runtime receipt.
struct CoreSetLocalFirmwareObservation {
    let requestID: UUID
    let generation: UInt64
    let sequence: UInt64
    let phase: Int32
    let inFlight: Bool
    let ready: Bool
    let errorCode: Int32
    let stage: String
    let message: String?
    let downloadedBytes: UInt64
    let totalBytes: UInt64
}

final class CoreSetKernelCacheTransferOwner {
    static let shared = CoreSetKernelCacheTransferOwner()
    private let lock = NSLock()
    private var requestID = UUID()
    private var generation: UInt64 = 1
    private var sequence: UInt64 = 1
    private var phase: Int32 = 0
    private var inFlight = false
    private var ready = false
    private var errorCode: Int32 = 0
    private var stage = "local-kernelcache-copy"
    private var message: String?
    private var downloadedBytes: UInt64 = 0
    private var totalBytes: UInt64 = 0

    private func bump(_ value: inout UInt64) { value = value == UInt64.max ? 1 : value + 1 }

    func begin(totalBytes: UInt64) {
        lock.lock(); defer { lock.unlock() }
        bump(&generation); requestID = UUID(); sequence = 1
        phase = 1; inFlight = true; ready = false; errorCode = 0
        stage = "local-kernelcache-copy"; message = nil
        downloadedBytes = 0; self.totalBytes = totalBytes
    }

    func advance(downloadedBytes: UInt64, totalBytes: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard inFlight, totalBytes == self.totalBytes,
              downloadedBytes >= self.downloadedBytes, downloadedBytes <= totalBytes else { return }
        self.downloadedBytes = downloadedBytes; bump(&sequence)
    }

    func complete() {
        lock.lock(); defer { lock.unlock() }
        guard inFlight, totalBytes > 0, downloadedBytes == totalBytes else { return }
        phase = 5; inFlight = false; ready = true; errorCode = 0; bump(&sequence)
    }

    func fail(code: Int32, message: String) {
        lock.lock(); defer { lock.unlock() }
        guard inFlight else { return }
        phase = 6; inFlight = false; ready = false; errorCode = code
        self.message = message; bump(&sequence)
    }

    func snapshot() -> CoreSetLocalFirmwareObservation {
        lock.lock(); defer { lock.unlock() }
        return CoreSetLocalFirmwareObservation(requestID: requestID, generation: generation,
            sequence: sequence, phase: phase, inFlight: inFlight, ready: ready,
            errorCode: errorCode, stage: stage, message: message,
            downloadedBytes: downloadedBytes, totalBytes: totalBytes)
    }
}

struct CoreSetLocalInformationObservation {
    let requestID: UUID
    let generation: UInt64
    let sequence: UInt64
    let status: Int32
    let message: String?
}

final class CoreSetKernelInformationOwner {
    static let shared = CoreSetKernelInformationOwner()
    private let lock = NSLock()
    private var requestID = UUID()
    private var generation: UInt64 = 1
    private var sequence: UInt64 = 1
    private var status: Int32 = 0
    private var message: String?

    private func bump(_ value: inout UInt64) { value = value == UInt64.max ? 1 : value + 1 }

    func beginResolve() {
        lock.lock(); defer { lock.unlock() }
        bump(&generation); requestID = UUID(); sequence = 1
        status = 1; message = "正在解析本机 kernelcache"
    }

    func didResolveArtifact() {
        lock.lock(); defer { lock.unlock() }
        guard status == 1 else { return }
        message = "kernelcache 已读取，正在验证偏移"; bump(&sequence)
    }

    func completeValidation() {
        lock.lock(); defer { lock.unlock() }
        guard status == 1 else { return }
        status = 2; message = "本机内核偏移已验证"; bump(&sequence)
    }

    func failValidation(_ reason: String) {
        lock.lock(); defer { lock.unlock() }
        guard status == 1 else { return }
        status = 3; message = reason; bump(&sequence)
    }

    func publishCachedValidation() {
        lock.lock(); defer { lock.unlock() }
        guard status == 0 else { return }
        bump(&generation); requestID = UUID(); sequence = 1
        status = 2; message = "使用已验证的本机内核偏移"
    }

    func snapshot() -> CoreSetLocalInformationObservation {
        lock.lock(); defer { lock.unlock() }
        return CoreSetLocalInformationObservation(requestID: requestID, generation: generation,
            sequence: sequence, status: status, message: message)
    }
}

private enum CoreSetV17SupportClass: Equatable {
    case supported, systemUnsupported, ios26NeedsA13OrEarlier, processorUnsupported

    var text: String {
        switch self {
        case .supported: return "环境已支持"
        case .systemUnsupported: return "当前系统版本不支持"
        case .ios26NeedsA13OrEarlier: return "iOS 26.0.0-26.0.1 仅支持到 A13 处理器"
        case .processorUnsupported: return "当前处理器为 A19/M5，暂不支持"
        }
    }
}

private func coreSetV17SupportClass() -> CoreSetV17SupportClass {
    var family: UInt32 = 0
    var size = MemoryLayout<UInt32>.size
    if sysctlbyname("hw.cpufamily", &family, &size, nil, 0) != 0 { family = 0 }
    let blocked: Set<UInt32> = [0xab345f09, 0x01d7a72b, 0x1d5a87e8]
    if blocked.contains(family) { return .processorUnsupported }

    let version = ProcessInfo.processInfo.operatingSystemVersion
    if version.majorVersion == 17 { return .supported }
    if version.majorVersion == 18 {
        if version.minorVersion < 7 { return .supported }
        if version.minorVersion == 7 && version.patchVersion <= 1 { return .supported }
        return .systemUnsupported
    }
    if version.majorVersion == 26 {
        guard version.minorVersion == 0, version.patchVersion <= 1 else { return .systemUnsupported }
        let throughA13: Set<UInt32> = [0x92fb37c8, 0xe81e7ef6, 0x07d34b9f,
                                      0x2c91a47e, 0x67ceee93, 0x462504d2]
        return throughA13.contains(family) ? .supported : .ios26NeedsA13OrEarlier
    }
    return .processorUnsupported
}

final class CoreSetHomeRuntimeProducer: CoreSetHomeReferenceObservationProvider {
    let observerEpoch = UUID()
    private let manager: laramgr
    private let supportClass: CoreSetV17SupportClass
    private var stopped = false
    private var observationSequences: [CoreSetHomeObservationField: UInt64] = [:]
    private var darkSwordRequests: [CoreSetHomeObservationField: (key: String, id: UUID)] = [:]

    init(manager: laramgr = .shared) {
        self.manager = manager
        supportClass = coreSetV17SupportClass()
    }

    private func nextSequence(_ field: CoreSetHomeObservationField) -> UInt64 {
        let old = observationSequences[field] ?? 0
        let next = old == UInt64.max ? 1 : old + 1
        observationSequences[field] = next
        return next
    }

    private func requestID(_ field: CoreSetHomeObservationField, request: UInt64, generation: UInt64) -> UUID {
        let key = "\(request)/\(generation)"
        if let current = darkSwordRequests[field], current.key == key { return current.id }
        let id = UUID(); darkSwordRequests[field] = (key, id); return id
    }

    private func identity(_ field: CoreSetHomeObservationField, hostGeneration: UInt64) -> CoreSetHomeObservationIdentity {
        CoreSetHomeObservationIdentity(observerEpoch: observerEpoch, sequence: nextSequence(field),
            hostGeneration: hostGeneration, observedAt: Date())
    }

    private func field(_ field: CoreSetHomeObservationField, hostGeneration: UInt64,
                       requestID: UUID, generation: UInt64?, nativeSequence: UInt64,
                       snapshot: CoreSetHomeSnapshot) -> CoreSetHomeReferenceFieldObservation {
        CoreSetHomeReferenceFieldObservation(field: field, identity: identity(field, hostGeneration: hostGeneration),
            nativeRequestID: requestID, currentGeneration: generation, publishGenerationRaw: generation,
            nativeSequence: nativeSequence, snapshot: snapshot, originalRuntimeReceipt: false)
    }

    func readObservation(hostGeneration: UInt64) -> CoreSetHomeReferenceObservation? {
        precondition(Thread.isMainThread)
        guard !stopped else { return nil }
        var fields: [CoreSetHomeObservationField: CoreSetHomeReferenceFieldObservation] = [:]
        let firmware = CoreSetKernelCacheTransferOwner.shared.snapshot()

        var environmentSnapshot = CoreSetHomeSnapshot()
        let support = supportClass
        if support != .supported {
            environmentSnapshot.environment = support.text
        } else if firmware.inFlight {
            environmentSnapshot.environment = "正在本机适配"
        } else if firmware.ready {
            environmentSnapshot.environment = "环境已就绪"
        } else if firmware.phase == 6 {
            environmentSnapshot.environment = "环境适配失败"
        } else {
            environmentSnapshot.environment = "等待授权后适配"
        }
        fields[.environment] = field(.environment, hostGeneration: hostGeneration,
            requestID: firmware.requestID, generation: firmware.generation,
            nativeSequence: firmware.sequence, snapshot: environmentSnapshot)

        let information = CoreSetKernelInformationOwner.shared.snapshot()
        var informationSnapshot = CoreSetHomeSnapshot()
        let base: String
        switch information.status {
        case 1: base = "正在获取..."
        case 2: base = "获取成功"
        case 3: base = "获取失败"
        case 4: base = "信息已失效"
        default: base = "等待获取"
        }
        informationSnapshot.information = information.message.map { "\(base)（\($0)）" } ?? base
        informationSnapshot.informationState = CoreSetHomeInformationState(status: information.status,
            message: information.message, localEquivalent: true)
        fields[.information] = field(.information, hostGeneration: hostGeneration,
            requestID: information.requestID, generation: information.generation,
            nativeSequence: information.sequence, snapshot: informationSnapshot)

        if let stage = manager.dsStageObservation, !stage.text.isEmpty, stage.text.utf8.count <= 47 {
            var stageSnapshot = CoreSetHomeSnapshot()
            stageSnapshot.stage = stage.text
            stageSnapshot.stageState = CoreSetHomeStageState(text: stage.text, phase: stage.phase,
                nativeSequence: stage.sequence, localEquivalent: true)
            fields[.stage] = field(.stage, hostGeneration: hostGeneration,
                requestID: requestID(.stage, request: stage.requestID, generation: stage.generation),
                generation: stage.generation, nativeSequence: stage.sequence, snapshot: stageSnapshot)
        }

        if let page = manager.dsPageObservation, page.totalPages > 0, page.completedPages <= page.totalPages {
            var pageSnapshot = CoreSetHomeSnapshot()
            let state = CoreSetHomePageProgressState(executing: page.executing, cancelled: page.cancelled,
                phase: page.phase, completedPages: page.completedPages, totalPages: page.totalPages,
                resultCode: page.resultCode, nativeSequence: page.sequence, localEquivalent: true)
            pageSnapshot.executing = page.executing; pageSnapshot.status = Int(page.phase)
            pageSnapshot.completedPages = page.completedPages; pageSnapshot.totalPages = page.totalPages
            pageSnapshot.pageProgressState = state
            fields[.pageProgress] = field(.pageProgress, hostGeneration: hostGeneration,
                requestID: requestID(.pageProgress, request: page.requestID, generation: page.generation),
                generation: page.generation, nativeSequence: page.sequence, snapshot: pageSnapshot)
        }

        if firmware.totalBytes > 0, firmware.downloadedBytes <= firmware.totalBytes {
            var firmwareSnapshot = CoreSetHomeSnapshot()
            let state = CoreSetHomeFirmwareState(phase: firmware.phase, inFlight: firmware.inFlight,
                ready: firmware.ready, errorCode: firmware.errorCode, stage: firmware.stage,
                message: firmware.message, downloadedBytes: firmware.downloadedBytes,
                totalBytes: firmware.totalBytes, currentGeneration: firmware.generation,
                publishGenerationRaw: firmware.generation, localEquivalent: true)
            firmwareSnapshot.environmentStage = firmware.stage
            firmwareSnapshot.downloadedBytes = firmware.downloadedBytes; firmwareSnapshot.totalBytes = firmware.totalBytes
            firmwareSnapshot.firmwareState = state
            fields[.firmwareProgress] = field(.firmwareProgress, hostGeneration: hostGeneration,
                requestID: firmware.requestID, generation: firmware.generation,
                nativeSequence: firmware.sequence, snapshot: firmwareSnapshot)
        }
        return CoreSetHomeReferenceObservation(fields: fields, actionProbeEvents: [])
    }

    func stopObservation() -> Bool {
        precondition(Thread.isMainThread)
        stopped = true; observationSequences.removeAll(); darkSwordRequests.removeAll()
        return stopped
    }
}
