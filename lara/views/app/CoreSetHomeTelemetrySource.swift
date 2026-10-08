import Foundation

// Read-only observations are not feature action receipts. Each supported
// field has an observed producer and can disappear independently.
enum CoreSetHomeObservationField: Hashable {
    case kernel, stage, environment, information, floating, kernelProgress, pageProgress, firmwareProgress
}

struct CoreSetHomeObservationIdentity: Equatable {
    let observerEpoch: UUID // Observation owner only, never a native exploit request ID.
    let sequence: UInt64
    let hostGeneration: UInt64
    let observedAt: Date
}
struct CoreSetHomeObservation {
    let snapshot: CoreSetHomeSnapshot
    let supportedFields: Set<CoreSetHomeObservationField>
    let identity: CoreSetHomeObservationIdentity?
    let unavailableReasons: [CoreSetHomeObservationField: String]
    let fieldIdentities: [CoreSetHomeObservationField: CoreSetHomeObservationIdentity]
}

// Original OTA/environment/info/stage/page providers have a fixed read-only
// insertion boundary. Current live local owners can populate it, but their
// receipts remain explicitly distinct from the original Core runtime owners.
struct CoreSetHomeReferenceFieldObservation {
    let field: CoreSetHomeObservationField
    let identity: CoreSetHomeObservationIdentity
    let nativeRequestID: UUID
    let currentGeneration: UInt64?
    let publishGenerationRaw: UInt64?
    let nativeSequence: UInt64
    let snapshot: CoreSetHomeSnapshot
    // Local equivalents remain useful live producers, but are never promoted
    // to an original Core runtime receipt.
    let originalRuntimeReceipt: Bool
}
struct CoreSetHomeReferenceObservation {
    let fields: [CoreSetHomeObservationField: CoreSetHomeReferenceFieldObservation]
    let actionProbeEvents: [CoreSetHomeProducerProbeEvent]
}
private struct CoreSetHomeProducerLogSignature: Equatable {
    let requestID: UUID
    let currentGeneration: UInt64?
    let publishGenerationRaw: UInt64?
    let nativeSequence: UInt64
    let originalRuntimeReceipt: Bool
}
protocol CoreSetHomeReferenceObservationProvider: AnyObject {
    var observerEpoch: UUID { get }
    func readObservation(hostGeneration: UInt64) -> CoreSetHomeReferenceObservation?
    func stopObservation() -> Bool
}

struct CoreSetExistingHomeRuntimeObservation {
    let identity: CoreSetHomeObservationIdentity
    let kernel: String?
    let executing: Bool
    let kernelProgress: Double?
}
protocol CoreSetExistingHomeRuntimeObservationProvider: AnyObject {
    func readObservation(hostGeneration: UInt64) -> CoreSetExistingHomeRuntimeObservation?
    func stopObservation() -> Bool
}
final class CoreSetLaraHomeRuntimeObservationProvider: CoreSetExistingHomeRuntimeObservationProvider {
    private let observerEpoch = UUID()
    private var sequence: UInt64 = 0
    private var stopped = false
    func readObservation(hostGeneration: UInt64) -> CoreSetExistingHomeRuntimeObservation? {
        precondition(Thread.isMainThread)
        guard !stopped else { return nil }
        let nativeBefore = ds_is_ready()
        let manager = laramgr.shared
        let running = manager.dsrunning, ready = manager.dsready && nativeBefore
        let failed = manager.dsfailed, attempted = manager.dsattempted, progress = manager.dsprogress
        guard nativeBefore == ds_is_ready(), !(running && failed) else { return nil }
        let kernel: String?
        if running { kernel = "本应用初始化中" }
        else if ready { kernel = "本应用初始化成功 · 内核访问已核对" }
        else if failed { kernel = "本应用初始化失败" }
        else if !attempted { kernel = "本应用未初始化" }
        else { kernel = nil }
        sequence &+= 1
        if sequence == 0 { sequence = 1 }
        let identity = CoreSetHomeObservationIdentity(observerEpoch: observerEpoch, sequence: sequence,
            hostGeneration: hostGeneration, observedAt: Date())
        return CoreSetExistingHomeRuntimeObservation(identity: identity, kernel: kernel, executing: running,
            kernelProgress: running && progress.isFinite && (0...1).contains(progress) ? progress : nil)
    }
    func stopObservation() -> Bool { stopped = true; return stopped }
}

enum CoreSetHomeProbePoint: Int, CaseIterable, Hashable {
    case runMode = 0, coverMode = 1, kernelAction = 2, informationAction = 3
    case pageProgress = 9, firmwareProgress = 10
    var stableID: String { String(format: "v17-%03d", rawValue) }
    var requiredEvidence: String {
        switch self {
        case .runMode: return "C+12c int32 0/1; non-menu consumer; request/generation; switch and restore result"
        case .coverMode: return "C+2f bool,C+130 int32; global/in-game/off; prior mode preserved on off; occlusion reset/stop result"
        case .kernelAction: return "4f00 gates; submitted task versus completed result; task generation; error/cancel/cleanup result"
        case .informationAction: return "538c host gate; info status 1/2/3; target identity; completed/failed result and cleanup"
        case .pageProgress: return "2fd1c acquire snapshot; executing/cancel/phase; UInt64 completed/total pages; request/generation/sequence"
        case .firmwareProgress: return "QXA107 qm571 call ff24 -> bfc0; progress callbacks cac0/cbd4/d6dc; qm543 -> qx307 stage/inFlight/ready/errorCode; downloaded/total UInt64 bytes; native generation raw bits including sentinel; cancel generation+1 and stopped/error result; URL/path/client presence or digest only"
        }
    }
}

enum CoreSetHomeProbePhase: String {
    case requested, running, completed, failed, cancelled, stopping, stopFailed, stopped, refused
    func canFollow(_ previous: CoreSetHomeProbePhase) -> Bool {
        switch previous {
        case .requested: return [.running, .completed, .failed, .cancelled, .stopping].contains(self)
        case .running: return [.running, .completed, .failed, .cancelled, .stopping].contains(self)
        case .completed, .failed, .cancelled: return [.stopping, .stopped].contains(self)
        case .stopping: return [.stopped, .stopFailed].contains(self)
        case .stopFailed: return self == .stopping
        case .stopped, .refused: return false
        }
    }
}

// Read-only diagnostic insertion boundary for a future audited producer. Events
// never modify desired/actual, supportedFields, or the displayed progress. In
// particular a submitted native task must not report completed merely from its
// entry function's return value. No URL, payload, or memory address is logged.
struct CoreSetHomeProducerProbeEvent {
    let point: CoreSetHomeProbePoint
    let producerEpoch: UUID
    let requestID: UUID
    let sequence: UInt64
    let observedAt: Date
    let phase: CoreSetHomeProbePhase
    let requestedOption: Int?
    let observedStatus: Int?
    let nativeGeneration: UInt64?
    let inFlight: Bool?
    let ready: Bool?
    let completedCount: UInt64?
    let totalCount: UInt64?
    let errorCode: Int?
}

final class CoreSetHomeTelemetrySource {
    private let runtimeProvider: CoreSetExistingHomeRuntimeObservationProvider
    private weak var referenceProvider: CoreSetHomeReferenceObservationProvider?
    private var referenceIdentities: [CoreSetHomeObservationField: CoreSetHomeObservationIdentity] = [:]
    private var referenceRequests: [CoreSetHomeObservationField: UUID] = [:]
    private var referenceGenerations: [CoreSetHomeObservationField: UInt64] = [:]
    private var referenceNativeSequences: [CoreSetHomeObservationField: UInt64] = [:]
    private var referenceSnapshots: [CoreSetHomeObservationField: CoreSetHomeSnapshot] = [:]
    private var producerLogSignatures: [CoreSetHomeObservationField: CoreSetHomeProducerLogSignature] = [:]
    private var observationsStopped = false
    init(runtimeProvider: CoreSetExistingHomeRuntimeObservationProvider = CoreSetLaraHomeRuntimeObservationProvider()) {
        self.runtimeProvider = runtimeProvider
    }
    func bindReferenceObservationProvider(_ provider: CoreSetHomeReferenceObservationProvider) {
        precondition(Thread.isMainThread)
        guard !observationsStopped else { return }
        referenceProvider = provider
        referenceIdentities.removeAll(); referenceRequests.removeAll(); referenceGenerations.removeAll()
        referenceNativeSequences.removeAll(); referenceSnapshots.removeAll(); producerLogSignatures.removeAll()
    }
    @discardableResult
    func stopObservations() -> Bool {
        precondition(Thread.isMainThread)
        observationsStopped = true
        let referenceStopped = referenceProvider?.stopObservation() ?? true
        referenceProvider = nil
        referenceIdentities.removeAll(); referenceRequests.removeAll(); referenceGenerations.removeAll()
        referenceNativeSequences.removeAll(); referenceSnapshots.removeAll(); producerLogSignatures.removeAll()
        let stopped = runtimeProvider.stopObservation()
        NSLog("Core-SET: home-observation stage=stop confirmed=%d reference-detached=%d scope=read-only-observation-owner native-action-stop=0", stopped ? 1 : 0, referenceStopped ? 1 : 0)
        return stopped && referenceStopped && referenceProvider == nil
    }
    private let probeEpoch = UUID()
    private var probeEvents: [CoreSetHomeProbePoint: CoreSetHomeProducerProbeEvent] = [:]
    private var requirementsLogged = false
    @discardableResult
    func recordProducerProbeEvent(_ event: CoreSetHomeProducerProbeEvent) -> Bool {
        precondition(Thread.isMainThread)
        func rejected(_ reason: String) -> Bool {
            NSLog("Core-SET: home-probe stage=rejected point=%@ epoch=%@ request=%@ sequence=%llu confirmed=0 reason=%@ scope=diagnostic-only",
                  event.point.stableID, event.producerEpoch.uuidString, event.requestID.uuidString, event.sequence, reason)
            return false
        }
        guard !observationsStopped else { return rejected("observation-owner-stopped") }
        let age = Date().timeIntervalSince(event.observedAt)
        guard age >= 0, age <= 5, event.sequence > 0 else { return rejected("stale-or-future-observation/zero-sequence") }
        if let option = event.requestedOption {
            guard (event.point == .runMode && (0...1).contains(option)) ||
                  (event.point == .coverMode && (0...2).contains(option)) else { return rejected("invalid-option-for-point") }
        }
        if event.completedCount != nil || event.totalCount != nil {
            guard [.pageProgress, .firmwareProgress].contains(event.point),
                  let completed = event.completedCount, let total = event.totalCount,
                  total > 0, completed <= total else { return rejected("invalid-count-pair-or-unit-scope") }
        }
        if (event.phase == .failed || event.phase == .stopFailed) && event.errorCode == nil { return rejected("failure-without-error-code") }
        if [.pageProgress, .firmwareProgress].contains(event.point), event.phase == .completed {
            guard let completed = event.completedCount, completed == event.totalCount else { return rejected("completed-without-exact-total") }
        }
        if let previous = probeEvents[event.point], previous.producerEpoch == event.producerEpoch,
           previous.requestID == event.requestID {
            guard event.sequence > previous.sequence, event.phase.canFollow(previous.phase) else { return rejected("stale-sequence-or-invalid-transition") }
            if let old = previous.nativeGeneration, let new = event.nativeGeneration, old != new {
                // Native QXA107.cancel explicitly increments generation. This
                // diagnostic exception cannot promote action/progress proof.
                let cancelledGenerationStep = event.point == .firmwareProgress &&
                    [.cancelled, .stopping, .stopped].contains(event.phase) &&
                    old < UInt64.max && new == old + 1
                guard cancelledGenerationStep else { return rejected("native-generation-changed-within-request") }
            }
            if let old = previous.requestedOption, let new = event.requestedOption, old != new {
                return rejected("requested-option-changed-within-request")
            }
            if let old = previous.completedCount, let new = event.completedCount, new < old { return rejected("count-regressed") }
            if let old = previous.totalCount, let new = event.totalCount, new != old { return rejected("denominator-changed") }
        } else {
            guard event.phase == .requested || event.phase == .refused else { return rejected("new-request-must-start-requested-or-refused") }
        }
        probeEvents[event.point] = event
        NSLog("Core-SET: home-probe point=%@ epoch=%@ request=%@ sequence=%llu phase=%@ option=%@ status=%@ nativeGeneration=%@ inFlight=%@ ready=%@ completed=%@ total=%@ errorCode=%@ confirmed=0 scope=diagnostic-only v17-effect-verified=0",
              event.point.stableID, event.producerEpoch.uuidString, event.requestID.uuidString,
              event.sequence, event.phase.rawValue, event.requestedOption.map(String.init) ?? "absent",
              event.observedStatus.map(String.init) ?? "absent", event.nativeGeneration.map(String.init) ?? "absent",
              event.inFlight.map { $0 ? "1" : "0" } ?? "absent", event.ready.map { $0 ? "1" : "0" } ?? "absent",
              event.completedCount.map(String.init) ?? "absent",
              event.totalCount.map(String.init) ?? "absent", event.errorCode.map(String.init) ?? "absent")
        return true
    }
    func recordRefusedControl(_ point: CoreSetHomeProbePoint, option: Int?) {
        _ = recordProducerProbeEvent(CoreSetHomeProducerProbeEvent(point: point, producerEpoch: probeEpoch,
            requestID: UUID(), sequence: 1, observedAt: Date(), phase: .refused,
            requestedOption: option, observedStatus: nil, nativeGeneration: nil, inFlight: nil, ready: nil,
            completedCount: nil, totalCount: nil, errorCode: nil))
    }
    func capture(hostReady: Bool, panelVisible: Bool, cleanupPending: Bool,
                 remoteHosted: Bool, hostGeneration: UInt64, floatingReady: Bool) -> CoreSetHomeObservation {
        precondition(Thread.isMainThread)
        if !requirementsLogged {
            requirementsLogged = true
            for point in CoreSetHomeProbePoint.allCases {
                let localAction = point == .kernelAction || point == .informationAction
                let locallyBound = localAction || (referenceProvider != nil &&
                    (point == .pageProgress || point == .firmwareProgress))
                NSLog("Core-SET: home-probe stage=producer-required point=%@ producer=%@ confirmed=0 original-runtime-receipt=0 required=%@ scope=%@",
                      point.stableID, localAction ? "local-action-bound" :
                        (locallyBound ? "local-equivalent-bound" : "original-action-unbound"),
                      point.requiredEvidence, localAction ? "live-local-action-owner" :
                        (locallyBound ? "live-local-owner" : "reference-contract"))
            }
        }
        var reasons: [CoreSetHomeObservationField: String] = [
            .environment: "v17-005: environment owner has not published a live state",
            .information: "v17-006: information lifecycle has not resolved a local target",
            .stage: "v17-008: typed DarkSword stage owner has not published",
            .pageProgress: "v17-009: typed PAGE owner has not started a scan",
            .firmwareProgress: "v17-010: byte-transfer owner has not started a transfer"]
        guard !observationsStopped, let runtime = runtimeProvider.readObservation(hostGeneration: hostGeneration) else {
            reasons[.kernel] = "v17-004: runtime observation owner stopped or native readiness changed during capture"
            reasons[.floating] = "v17-007: observation owner stopped/unavailable"
            return CoreSetHomeObservation(snapshot: CoreSetHomeSnapshot(), supportedFields: [], identity: nil, unavailableReasons: reasons, fieldIdentities: [:])
        }
        let referenceFields: Set<CoreSetHomeObservationField> = [.environment, .information, .stage, .pageProgress, .firmwareProgress]
        var fieldIdentities: [CoreSetHomeObservationField: CoreSetHomeObservationIdentity] = [:]
        var supported: Set<CoreSetHomeObservationField> = []
        let kernel = runtime.kernel
        if kernel != nil { supported.insert(.kernel); fieldIdentities[.kernel] = runtime.identity }
        let floating: String?
        if cleanupPending {
            floating = "悬浮资源清理待确认"
        } else if remoteHosted && hostReady && floatingReady {
            floating = panelVisible ? "跨应用注册回执有效 · 本地菜单显示" : "跨应用注册回执有效"
        } else if hostReady && floatingReady {
            floating = panelVisible ? "本应用悬浮已显示" : "本应用悬浮已就绪"
        } else {
            floating = nil
        }
        if floating != nil { supported.insert(.floating); fieldIdentities[.floating] = runtime.identity }
        // dsprogress is set to 1 even on failure; never display it as a
        // completion/success receipt after dsrunning becomes false.
        let kernelProgress = runtime.kernelProgress
        if kernelProgress != nil { supported.insert(.kernelProgress); fieldIdentities[.kernelProgress] = runtime.identity }
        var snapshot = CoreSetHomeSnapshot(kernel: kernel, stage: nil,
            environment: nil, information: nil, floating: floating,
            executing: runtime.executing, status: nil,
            completedPages: nil, totalPages: nil, environmentStage: nil,
            downloadedBytes: nil, totalBytes: nil,
            kernelProgressFraction: kernelProgress)
        if let provider = referenceProvider, let reference = provider.readObservation(hostGeneration: hostGeneration) {
            for field in referenceFields { reasons[field] = "bound producer returned no validated value for this field" }
            for (field, value) in reference.fields where referenceFields.contains(field) && value.field == field {
                let identity = value.identity
                let age = Date().timeIntervalSince(identity.observedAt)
                let previousIdentity = referenceIdentities[field]
                let sameOwner = previousIdentity?.observerEpoch == identity.observerEpoch
                let sameRequest = sameOwner && referenceRequests[field] == value.nativeRequestID
                let current = identity.observerEpoch == provider.observerEpoch && identity.hostGeneration == hostGeneration &&
                    identity.sequence > 0 && value.nativeSequence > 0 && age >= 0 && age <= 5
                let ordered = previousIdentity.map { $0.observerEpoch != identity.observerEpoch || identity.sequence > $0.sequence } ?? true
                let generationStable = !sameRequest || value.currentGeneration == referenceGenerations[field]
                let publishGenerationValid = value.publishGenerationRaw == nil ||
                    value.publishGenerationRaw == value.currentGeneration || value.publishGenerationRaw == UInt64.max
                let nativeSequenceStable = !sameRequest || value.nativeSequence >= (referenceNativeSequences[field] ?? 0)
                let oldSnapshot = referenceSnapshots[field]
                func countContinues(_ old: UInt64?, _ oldTotal: UInt64?, _ new: UInt64?, _ newTotal: UInt64?) -> Bool {
                    guard sameRequest, let old, let new else { return true }
                    return new >= old && (oldTotal == nil || newTotal == nil || oldTotal == newTotal)
                }
                let countersStable = countContinues(oldSnapshot?.completedPages, oldSnapshot?.totalPages,
                    value.snapshot.completedPages, value.snapshot.totalPages) &&
                    countContinues(oldSnapshot?.downloadedBytes, oldSnapshot?.totalBytes,
                    value.snapshot.downloadedBytes, value.snapshot.totalBytes)
                guard current && ordered && generationStable && publishGenerationValid && nativeSequenceStable && countersStable else {
                    reasons[field] = "producer epoch/host generation/sequence/freshness/request/generation/counter continuity mismatch"
                    continue
                }
                switch field {
                case .environment:
                    guard let text = value.snapshot.environment, !text.isEmpty, text.utf8.count <= 63 else { continue }
                    snapshot.environment = text
                case .information:
                    guard let text = value.snapshot.information, !text.isEmpty, text.utf8.count <= 191 else { continue }
                    snapshot.information = text; snapshot.informationState = value.snapshot.informationState
                case .stage:
                    // The original 0x168 owner has a 0x30-byte stage member;
                    // the later 0x80 home buffer is only a projection.
                    guard let text = value.snapshot.stage, !text.isEmpty, text.utf8.count <= 47 else { continue }
                    snapshot.stage = text; snapshot.stageState = value.snapshot.stageState
                case .pageProgress:
                    guard let state = value.snapshot.pageProgressState, state.totalPages > 0,
                          state.completedPages <= state.totalPages else { continue }
                    snapshot.pageProgressState = state
                    snapshot.completedPages = state.completedPages; snapshot.totalPages = state.totalPages
                    snapshot.executing = state.executing; snapshot.status = Int(state.phase)
                case .firmwareProgress:
                    guard let state = value.snapshot.firmwareState, value.currentGeneration != nil,
                          state.totalBytes > 0, state.downloadedBytes <= state.totalBytes,
                          state.stage == "ota-download" || (state.localEquivalent && state.stage == "local-kernelcache-copy") else { continue }
                    snapshot.firmwareState = state; snapshot.downloadedBytes = state.downloadedBytes
                    snapshot.totalBytes = state.totalBytes; snapshot.environmentStage = state.stage
                default: continue
                }
                referenceIdentities[field] = identity
                referenceRequests[field] = value.nativeRequestID
                if let generation = value.currentGeneration { referenceGenerations[field] = generation }
                else { referenceGenerations.removeValue(forKey: field) }
                referenceNativeSequences[field] = value.nativeSequence
                referenceSnapshots[field] = value.snapshot
                supported.insert(field); reasons[field] = nil; fieldIdentities[field] = identity
                let logSignature = CoreSetHomeProducerLogSignature(requestID: value.nativeRequestID,
                    currentGeneration: value.currentGeneration, publishGenerationRaw: value.publishGenerationRaw,
                    nativeSequence: value.nativeSequence, originalRuntimeReceipt: value.originalRuntimeReceipt)
                if producerLogSignatures[field] != logSignature {
                    producerLogSignatures[field] = logSignature
                    NSLog("Core-SET: home-producer field=%@ request=%@ generation=%@ nativeSequence=%llu original-runtime-receipt=%d scope=%@",
                          String(describing: field), value.nativeRequestID.uuidString,
                          value.currentGeneration.map(String.init) ?? "absent", value.nativeSequence,
                          value.originalRuntimeReceipt ? 1 : 0,
                          value.originalRuntimeReceipt ? "core-v17-owner" : "local-equivalent-live-owner")
                }
            }
            for event in reference.actionProbeEvents {
                let field: CoreSetHomeObservationField? = event.point == .pageProgress ? .pageProgress :
                    (event.point == .firmwareProgress ? .firmwareProgress : nil)
                guard let field, let owner = reference.fields[field],
                      event.producerEpoch == owner.identity.observerEpoch,
                      event.requestID == owner.nativeRequestID,
                      event.nativeGeneration == owner.currentGeneration else { continue }
                _ = recordProducerProbeEvent(event)
            }
        } else if referenceProvider != nil {
            for field in referenceFields {
                reasons[field] = "bound reference provider returned no fresh observation"
            }
        }
        return CoreSetHomeObservation(snapshot: snapshot, supportedFields: supported, identity: runtime.identity,
            unavailableReasons: reasons, fieldIdentities: fieldIdentities)
    }
}
