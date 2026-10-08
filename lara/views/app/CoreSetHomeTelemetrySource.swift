import Foundation

// Read-only observations are not feature action receipts. Each supported
// field has an observed producer and can disappear independently.
enum CoreSetHomeObservationField: Hashable {
    case kernel, stage, environment, information, floating, kernelProgress
}

struct CoreSetHomeObservation {
    let snapshot: CoreSetHomeSnapshot
    let supportedFields: Set<CoreSetHomeObservationField>
}

enum CoreSetHomeProbePoint: Int, CaseIterable {
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
                 remoteHosted: Bool, targetReadReady: Bool) -> CoreSetHomeObservation {
        precondition(Thread.isMainThread)
        if !requirementsLogged {
            requirementsLogged = true
            for point in CoreSetHomeProbePoint.allCases {
                NSLog("Core-SET: home-probe stage=producer-required point=%@ producer=unbound confirmed=0 required=%@ scope=reference-contract",
                      point.stableID, point.requiredEvidence)
            }
        }
        let manager = laramgr.shared
        let nativeReady = manager.dsready && ds_is_ready()
        var supported: Set<CoreSetHomeObservationField> = []
        var kernel: String?
        if manager.dsrunning {
            kernel = "DarkSword 初始化中"
        } else if nativeReady {
            kernel = "DarkSword 已就绪"
        } else if manager.dsfailed {
            kernel = "DarkSword 初始化失败"
        } else if manager.dsattempted {
            kernel = "DarkSword 未就绪"
        }
        if kernel != nil { supported.insert(.kernel) }
        let stage = manager.dsrunning ? "DarkSword 初始化进行中" : nil
        if stage != nil { supported.insert(.stage) }
        let environment = nativeReady ? "本应用内核访问已核对" : nil
        if environment != nil { supported.insert(.environment) }
        let information = targetReadReady ? "目标只读身份已核对" : nil
        if information != nil { supported.insert(.information) }
        let floating: String?
        if cleanupPending {
            floating = "悬浮资源清理待确认"
        } else if remoteHosted && hostReady {
            floating = panelVisible ? "跨应用双面挂接已回读 · 菜单显示" : "跨应用双面挂接已回读"
        } else if hostReady {
            floating = panelVisible ? "本应用悬浮已显示" : "本应用悬浮已就绪"
        } else {
            floating = nil
        }
        if floating != nil { supported.insert(.floating) }
        // dsprogress is set to 1 even on failure; never display it as a
        // completion/success receipt after dsrunning becomes false.
        let progress = manager.dsprogress
        let kernelProgress = manager.dsrunning && progress.isFinite &&
            (0...1).contains(progress) ? progress : nil
        if kernelProgress != nil { supported.insert(.kernelProgress) }
        let snapshot = CoreSetHomeSnapshot(kernel: kernel, stage: stage,
            environment: environment, information: information, floating: floating,
            executing: manager.dsrunning, status: nil,
            completedPages: nil, totalPages: nil, environmentStage: nil,
            downloadedBytes: nil, totalBytes: nil,
            kernelProgressFraction: kernelProgress)
        return CoreSetHomeObservation(snapshot: snapshot, supportedFields: supported)
    }
}
