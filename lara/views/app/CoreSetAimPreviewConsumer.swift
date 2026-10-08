import UIKit
import QuartzCore

// Read-only local preselection for HUD decoration. It never authorizes aim writes.
struct CoreSetAimPreviewTarget {
    let actorAddress: UInt64
    let point: CGPoint
    let bot: Bool
    let distanceMeters: Double
}

struct CoreSetAimPreviewFrame {
    let snapshotID: UUID
    let sessionGeneration: UInt64
    let processID: Int32
    let imageBase: UInt64
    let captureCompletedMonotonicSeconds: Double
    let target: CoreSetAimPreviewTarget?
}

final class CoreSetAimPreviewConsumer {
    private weak var coordinator: CoreSetRuntimeCoordinator?
    private let session = CoreSetReadSession()
    private let worker = DispatchQueue(label: "coreset.aim.preview.read", qos: .userInitiated)
    private var probe: Timer?
    private var stopped = false
    private(set) var lastCaptureDiagnostic = "尚未采集只读候选快照"

    init(coordinator: CoreSetRuntimeCoordinator) {
        self.coordinator = coordinator
        session.diagnosticLabel = "aim-preview"
        probe = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.probeTarget() }
        probeTarget()
    }

    var ready: Bool { !stopped && session.ready && session.capabilities == 1 }
    var unavailableDiagnostic: String { stopped ? "只读候选会话已停止" : session.lastConnectDiagnostic }
    func matchesIdentity(_ expected: (generation: UInt64, pid: Int32, base: UInt64)) -> Bool {
        ready && session.generation == expected.generation &&
            session.processID == expected.pid && session.imageBase == expected.base
    }

    private func probeTarget() {
        guard !stopped, !session.ready else { return }
        worker.async { [weak self] in
            guard let self else { return }
            _ = self.session.connect()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.coordinator?.refreshPlayerAvailability()
            }
        }
    }

    func capture(canvas: CGSize, radius: CGFloat, includeBots: Bool,
                 maximumDistance: Int,
                 completion: @escaping (CoreSetAimPreviewFrame?) -> Void) {
        precondition(Thread.isMainThread)
        guard ready, radius.isFinite, radius > 2,
              canvas.width.isFinite, canvas.height.isFinite,
              canvas.width > 0, canvas.height > 0,
              (10...500).contains(maximumDistance) else {
            lastCaptureDiagnostic = ready ? "preview-canvas-or-filter-invalid" : unavailableDiagnostic
            completion(nil); return
        }
        let generation = session.generation, pid = session.processID, base = session.imageBase
        worker.async { [weak self] in
            guard let self else { return }
            let failureSequence = self.session.readFailureSequence
            let snapshot = CoreSetPlayerCollector.capture(self.session, canvasSize: canvas,
                playerBones: true, botBones: true, boneDistanceLimit: Double(maximumDistance),
                includeOffscreen: false, includeRadar: false, includeBattleInputs: false,
                playerWeaponText: false, botWeaponText: false,
                includeGrenadeWarning: false, includeCounts: false,
                playerInformation: false, botInformation: false,
                includeWarningYaw: false, maximumDrawDistance: Double(maximumDistance))
            let captureFailure = self.session.readFailureSequence != failureSequence
                ? self.session.lastReadDiagnostic
                : "preview-snapshot-validation-or-freshness-failed transport-errors=0"
            var frame: CoreSetAimPreviewFrame?
            if let snapshot,
               snapshot.sessionGeneration == generation,
               snapshot.processID == pid, snapshot.imageBase == base,
               let id = UUID(uuidString: snapshot.snapshotID.uuidString),
               CACurrentMediaTime() - snapshot.captureCompletedMonotonicSeconds >= 0,
               CACurrentMediaTime() - snapshot.captureCompletedMonotonicSeconds <= 0.5 {
                let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                var best: (score: CGFloat, target: CoreSetAimPreviewTarget)?
                for mark in snapshot.marks {
                    guard mark.onScreen, includeBots || !mark.bot,
                          mark.distanceUnitsDividedBy100.isFinite,
                          mark.distanceUnitsDividedBy100 >= 0,
                          mark.distanceUnitsDividedBy100 <= Double(maximumDistance) else { continue }
                    let point: CGPoint
                    if let bone = mark.boneSegments.first?.start,
                       bone.x.isFinite, bone.y.isFinite { point = bone }
                    else { point = mark.center }
                    guard point.x.isFinite, point.y.isFinite,
                          point.x >= 0, point.y >= 0,
                          point.x <= canvas.width, point.y <= canvas.height else { continue }
                    let dx = point.x - center.x, dy = point.y - center.y
                    let score = dx * dx + dy * dy
                    guard score.isFinite, score <= radius * radius else { continue }
                    let target = CoreSetAimPreviewTarget(actorAddress: mark.actorAddress,
                        point: point, bot: mark.bot,
                        distanceMeters: mark.distanceUnitsDividedBy100)
                    if let existing = best {
                        if score < existing.score ||
                            (score == existing.score && target.actorAddress < existing.target.actorAddress) {
                            best = (score, target)
                        }
                    } else { best = (score, target) }
                }
                frame = CoreSetAimPreviewFrame(snapshotID: id,
                    sessionGeneration: generation, processID: pid, imageBase: base,
                    captureCompletedMonotonicSeconds: snapshot.captureCompletedMonotonicSeconds,
                    target: best?.target)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { completion(nil); return }
                guard !self.stopped,
                      self.ready, self.session.generation == generation,
                      self.session.processID == pid, self.session.imageBase == base else {
                    self.lastCaptureDiagnostic = "preview-identity-changed generation=\(generation)"
                    completion(nil); return
                }
                guard let frame,
                      CACurrentMediaTime() - frame.captureCompletedMonotonicSeconds >= 0,
                      CACurrentMediaTime() - frame.captureCompletedMonotonicSeconds <= 0.5 else {
                    self.lastCaptureDiagnostic = captureFailure
                    completion(nil); return
                }
                self.lastCaptureDiagnostic = "preview-snapshot-confirmed"
                completion(frame)
            }
        }
    }

    @discardableResult
    func shutdown() -> Bool {
        precondition(Thread.isMainThread)
        stopped = true
        probe?.invalidate(); probe = nil
        let cleanup = worker.sync { session.disconnect() }
        return cleanup.complete
    }
}
