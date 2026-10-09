import UIKit
import QuartzCore

struct CoreSetAimDisplayWorldPoint: Equatable {
    let x: Float
    let y: Float
    let z: Float
}

// Immutable hand-off from the serial Aim worker to the main-thread HUD.
// It carries the exact selected candidate; it never grants write authority.
struct CoreSetAimDisplayRecord {
    let identity: CoreSetAimDisplaySourceIdentity
    let actorAddress: UInt64
    let candidateKey: UInt64
    let candidateStartedMonotonicSeconds: Double
    let worldPoint: CoreSetAimDisplayWorldPoint
    let screenPoint: CGPoint
    let predictedWorldPoint: CoreSetAimDisplayWorldPoint?
    let predictedScreenPoint: CGPoint?
    let bot: Bool
    let distanceMeters: Double
    let captureStartedMonotonicSeconds: Double
    let captureCompletedMonotonicSeconds: Double
}

final class CoreSetAimDisplayRecordStore {
    static let shared = CoreSetAimDisplayRecordStore()
    // Local HUD lifecycle bound requested for stage 1; not claimed as a Core constant.
    static let maximumRecordAge: CFTimeInterval = 0.35

    private let lock = NSLock()
    private var record: CoreSetAimDisplayRecord?

    private init() {}

    func publish(_ value: CoreSetAimDisplayRecord) {
        lock.lock(); record = value; lock.unlock()
    }

    func latest(now: CFTimeInterval = CACurrentMediaTime()) -> CoreSetAimDisplayRecord? {
        lock.lock(); defer { lock.unlock() }
        guard let current = record else { return nil }
        let age = now - current.captureCompletedMonotonicSeconds
        guard age.isFinite, age >= 0, age <= Self.maximumRecordAge else {
            record = nil
            return nil
        }
        return current
    }

    func clear() {
        lock.lock(); record = nil; lock.unlock()
    }
}

struct CoreSetAimPreviewTarget {
    let actorAddress: UInt64
    let candidateKey: UInt64
    let candidateStartedMonotonicSeconds: Double
    let worldPoint: CoreSetAimDisplayWorldPoint
    let point: CGPoint
    let predictedWorldPoint: CoreSetAimDisplayWorldPoint?
    let predictedPoint: CGPoint?
    let bot: Bool
    let distanceMeters: Double
}

struct CoreSetAimPreviewFrame {
    let sourceIdentity: CoreSetAimDisplaySourceIdentity
    let captureStartedMonotonicSeconds: Double
    let captureCompletedMonotonicSeconds: Double
    let target: CoreSetAimPreviewTarget?

    var snapshotID: UUID { sourceIdentity.snapshotID }
    var sessionGeneration: UInt64 { sourceIdentity.sessionGeneration }
    var processID: Int32 { sourceIdentity.processID }
    var imageBase: UInt64 { sourceIdentity.imageBase }
    var hostGeneration: UInt64 { sourceIdentity.hostGeneration }
    var actionRevision: UInt64 { sourceIdentity.actionRevision }
    var actionRequestID: UUID { sourceIdentity.actionRequestID }
}

// Read-only adapter over AimConsumer's selected-candidate publication. It does
// not open a second target session, rescan actors, or select another candidate.
final class CoreSetAimPreviewConsumer {
    private weak var coordinator: CoreSetRuntimeCoordinator?
    private let store = CoreSetAimDisplayRecordStore.shared
    private var stopped = false
    private(set) var lastCaptureDiagnostic = "尚未收到自瞄候选记录"

    init(coordinator: CoreSetRuntimeCoordinator) {
        self.coordinator = coordinator
    }

    var ready: Bool { !stopped }
    var unavailableDiagnostic: String { stopped ? "自瞄候选记录订阅已停止" : lastCaptureDiagnostic }

    func capture(canvas: CGSize, radius: CGFloat, includeBots: Bool,
                 maximumDistance: Int,
                 completion: @escaping (CoreSetAimPreviewFrame?) -> Void) {
        precondition(Thread.isMainThread)
        guard ready, radius.isFinite, radius > 2,
              canvas.width.isFinite, canvas.height.isFinite,
              canvas.width > 0, canvas.height > 0,
              (10...500).contains(maximumDistance) else {
            lastCaptureDiagnostic = "aim-record-canvas-or-filter-invalid"
            completion(nil); return
        }
        guard let record = store.latest() else {
            lastCaptureDiagnostic = "aim-record-missing-or-stale"
            completion(nil); return
        }
        guard coordinator?.playerCanvas?.generation == record.identity.hostGeneration else {
            lastCaptureDiagnostic = "aim-record-host-generation-changed"
            completion(nil); return
        }
        let point = record.screenPoint
        guard point.x.isFinite, point.y.isFinite,
              point.x > 0, point.y > 0,
              point.x < canvas.width, point.y < canvas.height,
              includeBots || !record.bot,
              record.distanceMeters.isFinite, record.distanceMeters >= 0,
              record.distanceMeters <= Double(maximumDistance) else {
            lastCaptureDiagnostic = "aim-record-filtered-without-reselection"
            completion(nil); return
        }
        let predictedWorldPoint: CoreSetAimDisplayWorldPoint?
        let predictedPoint: CGPoint?
        if let world = record.predictedWorldPoint,
           let projected = record.predictedScreenPoint,
           world.x.isFinite, world.y.isFinite, world.z.isFinite,
           projected.x.isFinite, projected.y.isFinite,
           projected.x > 0, projected.y > 0,
           projected.x < canvas.width, projected.y < canvas.height {
            predictedWorldPoint = world; predictedPoint = projected
        } else {
            predictedWorldPoint = nil; predictedPoint = nil
        }
        let target = CoreSetAimPreviewTarget(actorAddress: record.actorAddress,
            candidateKey: record.candidateKey,
            candidateStartedMonotonicSeconds: record.candidateStartedMonotonicSeconds,
            worldPoint: record.worldPoint, point: point,
            predictedWorldPoint: predictedWorldPoint,
            predictedPoint: predictedPoint,
            bot: record.bot, distanceMeters: record.distanceMeters)
        let frame = CoreSetAimPreviewFrame(sourceIdentity: record.identity,
            captureStartedMonotonicSeconds: record.captureStartedMonotonicSeconds,
            captureCompletedMonotonicSeconds: record.captureCompletedMonotonicSeconds,
            target: target)
        lastCaptureDiagnostic = "aim-record-confirmed actor=\(record.actorAddress)"
        completion(frame)
    }

    @discardableResult
    func shutdown() -> Bool {
        precondition(Thread.isMainThread)
        stopped = true
        store.clear()
        return true
    }
}
