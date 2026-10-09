import UIKit
import QuartzCore

// Core v1.7 target selection, point interpolation, relative-motion prediction,
// recoil post/raw state, two-axis merge and one serial action-write route.
final class CoreSetAimConsumer: CoreSetFeatureConsumer {
    typealias State = CoreSetAimSettings
    let capability = CoreSetCapability.aimControl
    private weak var coordinator: CoreSetRuntimeCoordinator?
    private let worker = DispatchQueue(label: "coreset.basic.aim", qos: .userInitiated)
    private let rosterWorker = DispatchQueue(label: "coreset.basic.aim.roster", qos: .utility)
    private var session = CoreSetReadSession()
    private var rosterSession = CoreSetReadSession()
    private let rosterLock = NSLock()
    private let triggerState = CoreSetBasicAimTriggerState()
    private let dynamics = CoreSetV17AimDynamics()
    private let recoilDynamics = CoreSetV17RecoilDynamics()
    private let routeDynamics = CoreSetV17ActionRouteDynamics()
    private var selectedActor: UInt64 = 0
    private var selectedGeneration: UInt64 = 0
    private var selectedStartedAt: Double = 0
    private var timer: DispatchSourceTimer?
    private var recoilTimer: DispatchSourceTimer?
    private var readinessTimer: Timer?
    private var active: CoreSetApplyRequest<State>?
    private var pendingCompletion: ((CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void)?
    private var activeRecoil: CoreSetApplyRequest<CoreSetRecoilSettings>?
    private var pendingRecoilCompletion: ((CoreSetRequestToken, CoreSetApplyOutcome<CoreSetRecoilSettings>) -> Void)?
    private struct ActionWorkerIdentity: Equatable {
        let requestID: UUID
        let hostGeneration: UInt64
        let revision: UInt64
        let processID: Int32
        let imageBase: UInt64
        let readGeneration: UInt64
        let controller: UInt64
    }
    private var actionProbe: CoreSetIsolatedWriteProbe?
    private var actionWorkerIdentity: ActionWorkerIdentity?
    private var aimWritesCommitted = false
    private var recoilWritesCommitted = false
    private var unrestoredActionEffects = false
    private var pendingProbes: [CoreSetIsolatedWriteProbe] = []
    private var readReady = false
    private var cleanupPending = false
    private var executionFailure: String?
    private var closed = false
    private let cancellation = NSLock()
    private var liveToken: CoreSetRequestToken?
    private var liveHostGeneration: UInt64 = 0
    private var liveRevision: UInt64 = 0
    private var activeHostGeneration: UInt64 = 0
    private var activeRevision: UInt64 = 0
    private var activeCanvasSize: CGSize = .zero
    // A mapped target read can fail transiently while another overlay lane is
    // walking the same process.  A missing sample is not a terminal request
    // failure: keep the action worker alive and retry at a bounded cadence.
    private var nextBattleCaptureAt: Double = 0
    private var lastAimCaptureFailure = ""
    private var lastAimCaptureFailureLogAt: Double = 0
    private var lastRecoilCaptureFailure = ""
    private var lastRecoilCaptureFailureLogAt: Double = 0
    private struct ActionRosterDemand: Equatable {
        let requestID: UUID
        let hostGeneration: UInt64
        let revision: UInt64
        let canvasSize: CGSize
        let maximumDistance: Int
        let playerBones: Bool
        let botBones: Bool
    }
    private struct ActionRosterPublication {
        let demand: ActionRosterDemand
        let snapshot: CoreSetPlayerSnapshot
        let publishedAt: Double
    }
    private var rosterDemand: ActionRosterDemand?
    private var rosterPublication: ActionRosterPublication?
    private var rosterCaptureInFlight = false
    private var rosterDiagnostic = "candidate-publication-empty"
    private(set) var status = "目标只读会话未就绪"

    var recoilAvailability: CoreSetAvailability { availability }
    private var recoilFields: Set<CoreSetField> {
        [.recoilEnabled, .recoilStopWhenNotFiring, .recoilVerticalEnabled,
         .recoilVerticalStrength, .recoilHorizontalEnabled, .recoilHorizontalStrength]
    }

    init(coordinator: CoreSetRuntimeCoordinator) {
        self.coordinator = coordinator
        session.diagnosticLabel = "aim-action"
        rosterSession.diagnosticLabel = "aim-roster-producer"
        readinessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }
    private func refresh() {
        guard !closed, !cleanupPending else { return }
        worker.async { [weak self] in
            guard let self else { return }
            let ready = self.session.connect() && self.session.capabilities == 1
            DispatchQueue.main.async {
                self.readReady = ready
                self.coordinator?.refreshPlayerAvailability()
            }
        }
    }
    var availability: CoreSetAvailability {
        if let executionFailure { return .unavailable(reason: executionFailure) }
        guard !closed, !cleanupPending, readReady, coordinator?.playerCanvas != nil else {
            return .unavailable(reason: cleanupPending ? "基础自瞄清理待确认" : "基础自瞄目标只读会话或画布未就绪")
        }
        return .ready
    }
    var supportedFields: Set<CoreSetField> {
        [.basicAimEnabled, .basicAimPoint, .basicAimTrigger, .basicAimCircleSize,
         .basicAimExcludeKnocked, .basicAimIncludeBots,
         .basicAimLockSameTarget, .basicAimMaximumDistance, .basicAimStrength,
         .basicAimSmoothing, .basicAimConfirmationFrames, .basicAimScene,
         .basicAimLockStrength, .basicAimHorizontalSpeed, .basicAimVerticalSpeed,
         .basicAimPredictionMilliseconds, .basicAimLockThreshold, .basicAimTakeoverPause]
    }
    var configurableFields: Set<CoreSetField> {
        [.basicAimEnabled, .basicAimPoint, .basicAimPreaimCircle, .basicAimTrigger,
         .basicAimDynamicCircle, .basicAimShowCircle, .basicAimConnectionLine,
         .basicAimCircleSize, .basicAimExcludeKnocked, .basicAimIncludeBots,
         .basicAimLockSameTarget, .basicAimMaximumDistance, .basicAimStrength,
         .basicAimSmoothing, .basicAimConfirmationFrames, .basicAimScene,
         .basicAimLockStrength, .basicAimHorizontalSpeed, .basicAimVerticalSpeed,
         .basicAimPredictionMilliseconds, .basicAimLockThreshold, .basicAimTakeoverPause]
    }
    private func isLive(_ token: CoreSetRequestToken, host: UInt64) -> Bool {
        cancellation.lock(); defer { cancellation.unlock() }
        return liveToken == token && liveHostGeneration == host
    }
    private func hasOtherLiveRequest(_ token: CoreSetRequestToken) -> Bool {
        cancellation.lock(); defer { cancellation.unlock() }
        return liveToken != nil && liveToken != token
    }
    private func actionWorkerLive(_ requestToken: UUID, host: UInt64, revision: UInt64) -> Bool {
        cancellation.lock(); defer { cancellation.unlock() }
        return liveToken?.requestID == requestToken &&
            liveHostGeneration == host && liveRevision == revision
    }
    @discardableResult
    private func retireActionWorker() -> Bool {
        guard let probe = actionProbe else { actionWorkerIdentity = nil; return true }
        actionProbe = nil; actionWorkerIdentity = nil
        let cleanup = probe.stop()
        if cleanup.targetEffectsAbandoned { unrestoredActionEffects = true }
        if !cleanup.complete { pendingProbes.append(probe) }
        return cleanup.complete
    }
    private func drainPendingActionWorkers() {
        var retained: [CoreSetIsolatedWriteProbe] = []
        for probe in pendingProbes {
            let cleanup = probe.stop()
            if cleanup.targetEffectsAbandoned { unrestoredActionEffects = true }
            if !cleanup.complete { retained.append(probe) }
        }
        pendingProbes = retained
    }
    private func persistentActionWorker(snapshot: CoreSetPlayerSnapshot,
        primaryToken: CoreSetRequestToken, hostGeneration: UInt64,
        revision: UInt64) -> CoreSetIsolatedWriteProbe? {
        let identity = ActionWorkerIdentity(requestID: primaryToken.requestID,
            hostGeneration: hostGeneration, revision: revision,
            processID: snapshot.processID, imageBase: snapshot.imageBase,
            readGeneration: snapshot.sessionGeneration, controller: snapshot.controllerAddress)
        if actionWorkerIdentity == identity, let actionProbe { return actionProbe }
        guard retireActionWorker(), pendingProbes.isEmpty else { return nil }
        let probe = CoreSetIsolatedWriteProbe(readSession: session,
            liveValidator: { [weak self, weak session] captured, token, liveHost, liveRevision in
                guard let self, let session else { return false }
                return self.actionWorkerLive(token, host: liveHost, revision: liveRevision) &&
                    CoreSetPlayerCollector.validateLiveIdentity(session, snapshot: captured)
            })
        actionWorkerIdentity = identity; actionProbe = probe
        return probe
    }
    func invalidateHost() {
        cancellation.lock(); liveToken = nil; liveHostGeneration = 0; cancellation.unlock()
    }
    func apply(_ request: CoreSetApplyRequest<State>,
               completion: @escaping (CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void) {
        precondition(Thread.isMainThread)
        if request.desired.enabled == false {
            stop(request.token) { token, outcome in
                switch outcome {
                case .restored: completion(token, .applied(observed: request.desired))
                case .stoppedWithoutRestoration:
                    completion(token, .appliedWithoutRestoration(observed: request.desired))
                case .failed(let reason): completion(token, .failed(reason: reason))
                }
            }
            return
        }
        guard availability == .ready, let canvas = coordinator?.playerCanvas,
              request.desired.enabled == true, request.desired.trigger != nil,
              request.desired.includeBots != nil, request.desired.circleSize.value != nil,
              configuration(request.desired) != nil,
              request.desired.point != nil else {
            completion(request.token, .unavailable(reason: "基础自瞄参数未配置完整")); return
        }
        worker.async { [weak self] in
            guard let self, !self.closed else {
                DispatchQueue.main.async { completion(request.token, .failed(reason: "开始前请求已撤销")) }
                return
            }
            self.timer?.cancel(); self.timer = nil
            // Move the live-token handoff onto the same serial queue as the
            // recoil timer. Main-thread invalidation used to leave a window in
            // which an already queued recoil tick observed the new Aim token
            // and incorrectly failed the still-active recoil request.
            self.invalidateHost()
            guard self.retireActionWorker() else {
                DispatchQueue.main.async {
                    self.cleanupPending = true
                    completion(request.token, .failed(reason: "旧动作 worker 清理待确认，拒绝新请求"))
                    self.coordinator?.refreshPlayerAvailability()
                }
                return
            }
            guard self.pendingProbes.isEmpty else {
                self.invalidateHost()
                DispatchQueue.main.async {
                    self.cleanupPending = true
                    completion(request.token, .failed(reason: "旧事务映射清理待确认，拒绝新请求"))
                    self.coordinator?.refreshPlayerAvailability()
                }
                return
            }
            self.cancellation.lock()
            self.liveRevision &+= 1
            let revision = self.liveRevision
            self.liveToken = request.token
            self.liveHostGeneration = canvas.generation
            self.cancellation.unlock()
            if self.active == nil { self.aimWritesCommitted = false }
            if let previous = self.active, let previousCompletion = self.pendingCompletion {
                DispatchQueue.main.async { previousCompletion(previous.token, .failed(reason: "请求已替换")) }
            }
            self.active = request; self.pendingCompletion = completion
            self.activeHostGeneration = canvas.generation
            self.activeRevision = revision
            self.activeCanvasSize = canvas.size
            self.nextBattleCaptureAt = 0
            self.lastAimCaptureFailure = ""
            self.lastAimCaptureFailureLogAt = 0
            self.triggerState.reset()
            self.resetAimRuntime()
            let timer = DispatchSource.makeTimerSource(queue: self.worker)
            timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.tick(request, canvas: canvas.size, hostGeneration: canvas.generation, revision: revision) }
            self.timer = timer; timer.resume()
        }
    }
    private func recoilConfiguration(_ settings: CoreSetRecoilSettings) -> CoreSetV17RecoilConfiguration? {
        guard settings.enabled == true,
              let verticalEnabled = settings.verticalEnabled,
              let vertical = settings.verticalStrength.value,
              let stop = settings.stopWhenNotFiring.enabled,
              let horizontalEnabled = settings.horizontalEnabled,
              let horizontal = settings.horizontalStrength.value else { return nil }
        return CoreSetV17RecoilConfiguration(enabled: true,
            verticalEnabled: verticalEnabled, verticalStrengthPercent: vertical,
            stopWhenNotFiring: stop, horizontalEnabled: horizontalEnabled,
            horizontalStrengthPercent: horizontal)
    }
    func applyRecoil(_ request: CoreSetApplyRequest<CoreSetRecoilSettings>,
        completion: @escaping (CoreSetRequestToken, CoreSetApplyOutcome<CoreSetRecoilSettings>) -> Void) {
        precondition(Thread.isMainThread)
        if request.desired.enabled == false {
            stopRecoil(request.token) { token, outcome in
                switch outcome {
                case .restored: completion(token, .applied(observed: request.desired))
                case .stoppedWithoutRestoration:
                    completion(token, .appliedWithoutRestoration(observed: request.desired))
                case .failed(let reason): completion(token, .failed(reason: reason))
                }
            }
            return
        }
        guard recoilAvailability == .ready, recoilConfiguration(request.desired) != nil,
              let canvas = coordinator?.playerCanvas else {
            completion(request.token, .unavailable(reason: "压枪参数或共享动作会话未就绪")); return
        }
        worker.async { [weak self] in
            guard let self else { return }
            if let previous = self.activeRecoil, let callback = self.pendingRecoilCompletion {
                DispatchQueue.main.async { callback(previous.token, .failed(reason: "压枪请求已替换")) }
            }
            if self.activeRecoil == nil { self.recoilWritesCommitted = false }
            self.activeRecoil = request
            self.pendingRecoilCompletion = completion
            self.activeCanvasSize = canvas.size
            self.recoilDynamics.reset()
            if self.active == nil {
                self.invalidateHost()
                self.cancellation.lock()
                self.liveRevision &+= 1
                let revision = self.liveRevision
                self.liveToken = request.token
                self.liveHostGeneration = canvas.generation
                self.cancellation.unlock()
                self.activeHostGeneration = canvas.generation
                self.activeRevision = revision
                self.nextBattleCaptureAt = 0
                self.lastRecoilCaptureFailure = ""
                self.lastRecoilCaptureFailureLogAt = 0
                self.ensureRecoilTimer(canvas: canvas.size, hostGeneration: canvas.generation, revision: revision)
            } else {
                self.ensureRecoilTimer(canvas: canvas.size, hostGeneration: canvas.generation,
                                       revision: self.activeRevision)
            }
        }
    }
    private func ensureRecoilTimer(canvas: CGSize, hostGeneration: UInt64, revision: UInt64) {
        recoilTimer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: worker)
        source.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        source.setEventHandler { [weak self] in
            self?.tickRecoilOnly(canvas: canvas, hostGeneration: hostGeneration, revision: revision)
        }
        recoilTimer = source
        source.resume()
    }
    private func actionSlot(snapshot: CoreSetPlayerSnapshot) -> CoreSetTargetWriteSlot {
        routeDynamics.slot(firingSample: snapshot.localFiringRaw)
    }
    private func configuration(_ settings: State) -> CoreSetV17AimConfiguration? {
        guard let scene = settings.scene else { return nil }
        let custom = scene == .custom
        if !custom && settings.lockStrength == nil { return nil }
        let maximumDistance = settings.custom.maximumDistance.value
        let strength = settings.custom.strength.value
        let smoothing = settings.custom.smoothing.value
        let confirmationFrames = settings.custom.confirmationFrames.value
        let horizontalSpeed = settings.custom.horizontalSpeed.value
        let verticalSpeed = settings.custom.verticalSpeed.value
        let prediction = settings.custom.predictionMilliseconds.value
        let lockThreshold = settings.custom.lockThreshold.value
        let pause = settings.custom.takeoverPauseMilliseconds.value
        let customPresent = maximumDistance != nil && strength != nil && smoothing != nil &&
            confirmationFrames != nil && horizontalSpeed != nil && verticalSpeed != nil &&
            prediction != nil && lockThreshold != nil && pause != nil
        if custom && !customPresent { return nil }
        return CoreSetV17AimConfiguration(storedScene: scene.rawValue,
            storedLockStrength: settings.lockStrength?.rawValue ?? 0,
            customValuesPresent: customPresent,
            customMaximumDistance: maximumDistance ?? 0,
            customStrength: strength ?? 0, customSmoothing: smoothing ?? 0,
            customConfirmationFrames: confirmationFrames ?? 0,
            customHorizontalSpeed: horizontalSpeed ?? 0,
            customVerticalSpeed: verticalSpeed ?? 0,
            customPredictionMilliseconds: prediction ?? 0,
            customLockThreshold: lockThreshold ?? 0,
            customTakeoverPauseMilliseconds: pause ?? 0)
    }
    private struct BattleCaptureResult {
        let snapshot: CoreSetPlayerSnapshot?
        let failure: String
    }
    private func demand(primaryToken: CoreSetRequestToken, hostGeneration: UInt64,
                        revision: UInt64, canvas: CGSize, distance: Int,
                        includeBones: Bool, includeBots: Bool) -> ActionRosterDemand {
        ActionRosterDemand(requestID: primaryToken.requestID,
            hostGeneration: hostGeneration, revision: revision, canvasSize: canvas,
            maximumDistance: distance, playerBones: includeBones,
            botBones: includeBones && includeBots)
    }
    private func requestRoster(_ demand: ActionRosterDemand, freshCandidates: Bool) {
        rosterLock.lock()
        rosterDemand = demand
        let publicationReady = rosterPublication.map {
            $0.demand == demand && (!freshCandidates ||
                CACurrentMediaTime() - $0.publishedAt <= 1.0)
        } == true
        guard !publicationReady, !rosterCaptureInFlight else {
            rosterLock.unlock(); return
        }
        rosterCaptureInFlight = true
        rosterLock.unlock()
        rosterWorker.async { [weak self] in self?.produceRoster() }
    }
    private func produceRoster() {
        rosterLock.lock()
        guard let demand = rosterDemand else {
            rosterCaptureInFlight = false; rosterLock.unlock(); return
        }
        rosterLock.unlock()
        let connected = rosterSession.connect() && rosterSession.capabilities == 1
        let failureSequence = rosterSession.readFailureSequence
        let snapshot = connected ? CoreSetPlayerCollector.capture(rosterSession,
            canvasSize: demand.canvasSize, playerBones: demand.playerBones,
            botBones: demand.botBones,
            boneDistanceLimit: demand.playerBones || demand.botBones
                ? Double(demand.maximumDistance) : 0,
            includeOffscreen: false, includeRadar: false, includeBattleInputs: false,
            playerWeaponText: false, botWeaponText: false, includeGrenadeWarning: false,
            includeCounts: !demand.playerBones, playerInformation: false, botInformation: false,
            includeWarningYaw: false,
            maximumDrawDistance: Double(demand.maximumDistance)) : nil
        let diagnostic: String
        if !connected { diagnostic = rosterSession.lastConnectDiagnostic }
        else if rosterSession.readFailureSequence != failureSequence {
            diagnostic = rosterSession.lastReadDiagnostic
        } else { diagnostic = CoreSetPlayerCollector.lastCaptureDiagnostic() }
        let publishedAt = CACurrentMediaTime()
        rosterLock.lock()
        let stillCurrent = rosterDemand == demand
        if stillCurrent, let snapshot,
           snapshot.processID == rosterSession.processID,
           snapshot.imageBase == rosterSession.imageBase {
            rosterPublication = ActionRosterPublication(demand: demand,
                snapshot: snapshot, publishedAt: publishedAt)
            rosterDiagnostic = "ready snapshot=\(snapshot.snapshotID.uuidString)"
        } else if stillCurrent {
            rosterPublication = nil
            rosterDiagnostic = diagnostic
        }
        rosterCaptureInFlight = false
        let changed = rosterDemand != nil && rosterDemand != demand
        if changed { rosterCaptureInFlight = true }
        rosterLock.unlock()
        if changed { rosterWorker.async { [weak self] in self?.produceRoster() } }
    }
    private func publishedRoster(for demand: ActionRosterDemand,
                                 freshCandidates: Bool) -> (CoreSetPlayerSnapshot?, String) {
        rosterLock.lock(); defer { rosterLock.unlock() }
        guard let publication = rosterPublication, publication.demand == demand,
              !freshCandidates || CACurrentMediaTime() - publication.publishedAt <= 1.0 else {
            return (nil, rosterDiagnostic)
        }
        return (publication.snapshot, rosterDiagnostic)
    }
    private func invalidatePublishedRoster(_ demand: ActionRosterDemand) {
        rosterLock.lock()
        if rosterPublication?.demand == demand { rosterPublication = nil }
        rosterDiagnostic = "candidate-publication-invalidated"
        rosterLock.unlock()
    }
    private func captureAction(_ size: CGSize, distance: Int, includeBones: Bool,
                               includeBots: Bool, targetActor: UInt64,
                               primaryToken: CoreSetRequestToken, hostGeneration: UInt64,
                               revision: UInt64) -> BattleCaptureResult {
        let expected = demand(primaryToken: primaryToken, hostGeneration: hostGeneration,
            revision: revision, canvas: size, distance: distance,
            includeBones: includeBones, includeBots: includeBots)
        let freshCandidates = targetActor == 0 && includeBones
        requestRoster(expected, freshCandidates: freshCandidates)
        let publication = publishedRoster(for: expected, freshCandidates: freshCandidates)
        guard let roster = publication.0 else {
            return BattleCaptureResult(snapshot: nil,
                failure: "candidate-publication-waiting \(publication.1)")
        }
        let failureSequence = session.readFailureSequence
        let snapshot = CoreSetPlayerCollector.refreshAction(for: roster,
            targetActor: targetActor, session: session, canvasSize: size,
            maximumDrawDistance: Double(distance))
        if snapshot == nil { invalidatePublishedRoster(expected) }
        let failure = session.readFailureSequence != failureSequence
            ? session.lastReadDiagnostic
            : "\(CoreSetPlayerCollector.lastCaptureDiagnostic()) transport-errors=0"
        return BattleCaptureResult(snapshot: snapshot, failure: failure)
    }
    private func shouldAttemptBattleCapture(now: Double) -> Bool {
        now.isFinite && now >= 0 && now >= nextBattleCaptureAt
    }
    private func deferBattleCapture(now: Double) {
        nextBattleCaptureAt = now + 0.15
    }
    private func noteCaptureFailure(_ reason: String, lane: String, now: Double) {
        let first: Bool
        let due: Bool
        if lane == "aim" {
            first = lastAimCaptureFailure.isEmpty
            due = now - lastAimCaptureFailureLogAt >= 3
            lastAimCaptureFailure = reason
            if first || due { lastAimCaptureFailureLogAt = now }
        } else {
            first = lastRecoilCaptureFailure.isEmpty
            due = now - lastRecoilCaptureFailureLogAt >= 3
            lastRecoilCaptureFailure = reason
            if first || due { lastRecoilCaptureFailureLogAt = now }
        }
        guard first || due else { return }
        NSLog("Core-SET: action-sample lane=%@ stage=retry terminal=0 reason=%@", lane, reason)
        publish(lane == "aim" ? "战斗采样暂不可用，保留自瞄请求并重试" :
            "战斗采样暂不可用，保留压枪请求并重试")
    }
    private func noteCaptureSuccess(lane: String) {
        nextBattleCaptureAt = 0
        if lane == "aim" { lastAimCaptureFailure = "" }
        else { lastRecoilCaptureFailure = "" }
    }
    private func displayPoint(target: CoreSetWorldPoint,
                              snapshot: CoreSetPlayerSnapshot) -> CGPoint? {
        guard let camera = snapshot.cameraWorldPosition else { return nil }
        let width = Double(snapshot.canvasSize.width), height = Double(snapshot.canvasSize.height)
        let fov = Double(snapshot.cameraFieldOfViewDegrees)
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              fov.isFinite, fov > 1, fov < 170 else { return nil }
        let degrees = Double.pi / 180
        let pitch = Double(snapshot.cameraPitchDegrees) * degrees
        let yaw = Double(snapshot.cameraYawDegrees) * degrees
        let roll = Double(snapshot.cameraRollDegrees) * degrees
        let sp = sin(pitch), cp = cos(pitch)
        let sy = sin(yaw), cy = cos(yaw)
        let sr = sin(roll), cr = cos(roll)
        let dx = Double(target.x - camera.x)
        let dy = Double(target.y - camera.y)
        let dz = Double(target.z - camera.z)
        let depth = dx * cp * cy + dy * cp * sy + dz * sp
        guard depth.isFinite, depth > 1 else { return nil }
        let right = dx * (sr * sp * cy - cr * sy) +
            dy * (sr * sp * sy + cr * cy) - dz * sr * cp
        let up = dx * (sr * sy - cr * sp * cy) +
            dy * (sr * cy - cr * sp * sy) + dz * cr * cp
        let focal = (width / 2) / tan(fov * degrees / 2)
        let x = width / 2 + focal * right / depth
        let y = height / 2 - focal * up / depth
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }
    private func publishDisplayTarget(mark: CoreSetPlayerMark, target: CoreSetWorldPoint,
                                      step: CoreSetBasicAimDelta,
                                      snapshot: CoreSetPlayerSnapshot,
                                      request: CoreSetApplyRequest<State>,
                                      hostGeneration: UInt64, revision: UInt64) {
        guard selectedActor != 0, selectedStartedAt.isFinite, selectedStartedAt >= 0,
              let point = displayPoint(target: target, snapshot: snapshot) else {
            CoreSetAimDisplayRecordStore.shared.clear()
            return
        }
        let identity = CoreSetAimDisplaySourceIdentity(snapshotID: snapshot.snapshotID,
            sessionGeneration: snapshot.sessionGeneration, processID: snapshot.processID,
            imageBase: snapshot.imageBase, hostGeneration: hostGeneration,
            actionRevision: revision, actionRequestID: request.token.requestID)
        let predictedWorldPoint: CoreSetAimDisplayWorldPoint?
        let predictedScreenPoint: CGPoint?
        if let predicted = step.predictedWorldPoint,
           let projected = displayPoint(target: predicted, snapshot: snapshot),
           projected.x > 0, projected.y > 0,
           projected.x < snapshot.canvasSize.width,
           projected.y < snapshot.canvasSize.height {
            predictedWorldPoint = CoreSetAimDisplayWorldPoint(
                x: predicted.x, y: predicted.y, z: predicted.z)
            predictedScreenPoint = projected
        } else {
            predictedWorldPoint = nil; predictedScreenPoint = nil
        }
        let record = CoreSetAimDisplayRecord(identity: identity,
            actorAddress: selectedActor, candidateKey: selectedActor,
            candidateStartedMonotonicSeconds: selectedStartedAt,
            worldPoint: CoreSetAimDisplayWorldPoint(x: target.x, y: target.y, z: target.z),
            screenPoint: point, predictedWorldPoint: predictedWorldPoint,
            predictedScreenPoint: predictedScreenPoint, bot: mark.bot,
            distanceMeters: mark.distanceUnitsDividedBy100,
            captureStartedMonotonicSeconds: snapshot.captureStartedMonotonicSeconds,
            captureCompletedMonotonicSeconds: snapshot.captureCompletedMonotonicSeconds)
        CoreSetAimDisplayRecordStore.shared.publish(record)
    }
    private func resetAimRuntime() {
        dynamics.reset(); selectedActor = 0; selectedGeneration = 0; selectedStartedAt = 0
        CoreSetAimDisplayRecordStore.shared.clear()
    }
    private func clearRosterPublication() {
        rosterLock.lock()
        rosterDemand = nil; rosterPublication = nil
        rosterDiagnostic = "candidate-publication-empty"
        rosterLock.unlock()
    }
    private func drainRosterProducer() -> Bool {
        clearRosterPublication()
        return rosterWorker.sync {
            let cleanup = rosterSession.disconnect()
            let clean = cleanup.taskPortReleased && cleanup.generationAdvanced
            if clean {
                rosterSession = CoreSetReadSession()
                rosterSession.diagnosticLabel = "aim-roster-producer"
            }
            return clean
        }
    }
    private enum ActionSubmitResult { case idle, committed, failed(String) }
    private func submitMergedAction(snapshot: CoreSetPlayerSnapshot, aimStep: CoreSetBasicAimDelta?,
        recoilRequest: CoreSetApplyRequest<CoreSetRecoilSettings>?,
        primaryToken: CoreSetRequestToken, hostGeneration: UInt64, revision: UInt64,
        requireAimTrigger: Bool) -> ActionSubmitResult {
        let recoil = recoilRequest.flatMap { recoilConfiguration($0.desired) }
        guard let merged = recoilDynamics.plan(snapshot: snapshot,
            aimPitch: aimStep?.pitch ?? 0, aimYaw: aimStep?.yaw ?? 0,
            geometrySampleKey: aimStep?.geometrySampleKey ?? 0,
            configuration: recoil) else {
            return .failed("Core v1.7 Aim/Recoil 合并状态无效")
        }
        let pitch = merged.pitch, yaw = merged.yaw
        let slot = actionSlot(snapshot: snapshot)
        let recoilEnabled = recoil != nil
        if pitch == 0 && yaw == 0 {
            recoilDynamics.observeAimFeedback(pitch: aimStep?.pitch ?? 0,
                inputRoute: slot == .rotationInput, recoilEnabled: recoilEnabled,
                aimActive: aimStep != nil, acceptedFirstAxis: false, bothZeroDraft: true)
            return .idle
        }
        let axis: CoreSetTargetWriteAxis = pitch != 0 && yaw != 0 ? .both : (pitch != 0 ? .first : .second)
        let lane: CoreSetTargetWriteLane = aimStep == nil && recoilEnabled ? .recoil : .aim
        guard let probe = persistentActionWorker(snapshot: snapshot,
            primaryToken: primaryToken, hostGeneration: hostGeneration,
            revision: revision) else { return .failed("常驻动作 worker 清理或重建失败") }
        if requireAimTrigger && !triggerState.permits(now: CACurrentMediaTime()) { return .idle }
        let result = probe.submit(snapshot: snapshot, requestToken: primaryToken.requestID,
            hostGeneration: hostGeneration, configRevision: revision, lane: lane,
            slot: slot, axis: axis, pitchDelta: pitch, yawDelta: yaw)
        if result.pending { _ = retireActionWorker() }
        guard result.committed, isLive(primaryToken, host: hostGeneration) else {
            return .failed(result.reason)
        }
        recoilDynamics.observeAimFeedback(pitch: aimStep?.pitch ?? 0,
            inputRoute: slot == .rotationInput, recoilEnabled: recoilEnabled,
            aimActive: aimStep != nil, acceptedFirstAxis: pitch != 0,
            bothZeroDraft: false)
        let aimContributed = aimStep != nil && (merged.aimPitch != 0 || merged.aimYaw != 0)
        let recoilContributed = recoilEnabled && (merged.recoilPitch != 0 || merged.recoilYaw != 0)
        if aimContributed, let aim = active, let callback = pendingCompletion {
            aimWritesCommitted = true
            pendingCompletion = nil
            DispatchQueue.main.async { callback(aim.token, .applied(observed: aim.desired)) }
        }
        if recoilContributed, let recoil = activeRecoil, let callback = pendingRecoilCompletion {
            recoilWritesCommitted = true
            pendingRecoilCompletion = nil
            DispatchQueue.main.async { callback(recoil.token, .applied(observed: recoil.desired)) }
        }
        publish("Core v1.7 Aim/Recoil 同帧合并已提交并回读")
        return .committed
    }
    private func tickRecoilOnly(canvas: CGSize, hostGeneration: UInt64, revision: UInt64) {
        guard active == nil, let recoilRequest = activeRecoil else { return }
        guard pendingProbes.isEmpty else { failRecoil(recoilRequest, "旧事务清理待确认，禁止压枪写入"); return }
        guard isLive(recoilRequest.token, host: hostGeneration) else { return }
        guard recoilConfiguration(recoilRequest.desired) != nil else {
            failRecoil(recoilRequest, "压枪参数在运行中失效"); return
        }
        let now = CACurrentMediaTime()
        guard shouldAttemptBattleCapture(now: now) else { return }
        let capture = captureAction(canvas, distance: 500, includeBones: false,
            includeBots: false, targetActor: 0, primaryToken: recoilRequest.token,
            hostGeneration: hostGeneration, revision: revision)
        guard isLive(recoilRequest.token, host: hostGeneration) else { return }
        guard let snapshot = capture.snapshot, snapshot.battleInputsPresent else {
            let failedAt = CACurrentMediaTime()
            deferBattleCapture(now: failedAt)
            noteCaptureFailure(capture.failure, lane: "recoil", now: failedAt)
            return
        }
        noteCaptureSuccess(lane: "recoil")
        switch submitMergedAction(snapshot: snapshot, aimStep: nil, recoilRequest: recoilRequest,
            primaryToken: recoilRequest.token,
            hostGeneration: hostGeneration, revision: revision, requireAimTrigger: false) {
        case .idle: publish("压枪状态预热或本帧无补偿")
        case .committed: break
        case .failed(let reason): failRecoil(recoilRequest, reason)
        }
    }
    private func runRecoilFallback(snapshot: CoreSetPlayerSnapshot,
        aimRequest: CoreSetApplyRequest<State>,
        recoilRequest: CoreSetApplyRequest<CoreSetRecoilSettings>?,
        hostGeneration: UInt64, revision: UInt64, idleStatus: String) {
        guard let recoilRequest else { publish(idleStatus); return }
        switch submitMergedAction(snapshot: snapshot, aimStep: nil, recoilRequest: recoilRequest,
            primaryToken: aimRequest.token,
            hostGeneration: hostGeneration, revision: revision, requireAimTrigger: false) {
        case .idle: publish(idleStatus + "；压枪本帧预热或无补偿")
        case .committed: break
        case .failed(let reason): fail(aimRequest, reason)
        }
    }
    private func tick(_ request: CoreSetApplyRequest<State>, canvas: CGSize, hostGeneration: UInt64, revision: UInt64) {
        guard pendingProbes.isEmpty else { fail(request, "旧事务清理待确认，禁止后续写入"); return }
        guard isLive(request.token, host: hostGeneration) else { return }
        guard let configuration = configuration(request.desired),
              let size = request.desired.circleSize.value else {
            fail(request, "自瞄参数在运行中失效"); return
        }
        let now = CACurrentMediaTime()
        guard shouldAttemptBattleCapture(now: now) else { return }
        let refreshTarget = request.desired.lockSameTarget == true ? selectedActor : 0
        let capture = captureAction(canvas, distance: configuration.maximumDistance,
            includeBones: true, includeBots: request.desired.includeBots == true,
            targetActor: refreshTarget, primaryToken: request.token,
            hostGeneration: hostGeneration, revision: revision)
        guard isLive(request.token, host: hostGeneration) else { return }
        guard let snapshot = capture.snapshot, snapshot.battleInputsPresent,
              snapshot.cameraWorldPosition != nil else {
            let failedAt = CACurrentMediaTime()
            deferBattleCapture(now: failedAt)
            noteCaptureFailure(capture.failure, lane: "aim", now: failedAt)
            return
        }
        noteCaptureSuccess(lane: "aim")
        if selectedGeneration != 0 && selectedGeneration != snapshot.sessionGeneration { resetAimRuntime() }
        let recoilRequest = activeRecoil
        let trigger = triggerState.update(mode: request.desired.trigger?.rawValue ?? -1,
            ads: snapshot.localADS, firing: snapshot.localFiring, now: CACurrentMediaTime())
        if !trigger {
            guard recoilRequest != nil else { publish("等待触发，未写入"); return }
            switch submitMergedAction(snapshot: snapshot, aimStep: nil, recoilRequest: recoilRequest,
                primaryToken: request.token, hostGeneration: hostGeneration,
                revision: revision, requireAimTrigger: false) {
            case .idle: publish("等待自瞄触发；压枪本帧预热或无补偿")
            case .committed: break
            case .failed(let reason): fail(request, reason)
            }
            return
        }
        let takeoverAllowed = dynamics.permitsTakeover(pitch: snapshot.rotationInputPitch,
            yaw: snapshot.rotationInputYaw, configuration: configuration,
            now: snapshot.captureCompletedMonotonicSeconds)
        if !takeoverAllowed {
            guard recoilRequest != nil else { publish("检测到接管输入，暂停写入"); return }
            switch submitMergedAction(snapshot: snapshot, aimStep: nil, recoilRequest: recoilRequest,
                primaryToken: request.token, hostGeneration: hostGeneration,
                revision: revision, requireAimTrigger: false) {
            case .idle: publish("检测到接管输入；压枪本帧预热或无补偿")
            case .committed: break
            case .failed(let reason): fail(request, reason)
            }
            return
        }
        let radius = CoreSetBasicAimDelta.circleRadius(canvasWidth: Double(canvas.width),
            height: Double(canvas.height), size: size)
        guard radius > 0 else { fail(request, "Core v1.7 自瞄圈参数无效"); return }
        guard let point = request.desired.point else { fail(request, "fallback点未配置"); return }
        let previousActor = selectedActor
        let selected = CoreSetBasicAimDelta.select(snapshot: snapshot, point: point.rawValue, radius: radius,
            maximumDistance: Double(configuration.maximumDistance), includeBots: request.desired.includeBots == true,
            excludeKnocked: request.desired.excludeKnocked == true,
            lockSameTarget: request.desired.lockSameTarget == true, previousActor: previousActor)
        let actor: UInt64
        let target: CoreSetWorldPoint
        if let selected,
           let fallback = CoreSetBasicAimDelta.fallbackTarget(mark: selected, point: point.rawValue) {
            actor = selected.actorAddress; target = fallback
            if selectedActor != actor || selectedGeneration != snapshot.sessionGeneration {
                dynamics.reset(); selectedActor = actor; selectedGeneration = snapshot.sessionGeneration
                selectedStartedAt = snapshot.captureCompletedMonotonicSeconds
            }
            guard dynamics.rememberTarget(fallback, actor: actor,
                generation: snapshot.sessionGeneration, now: snapshot.captureCompletedMonotonicSeconds) else {
                resetAimRuntime()
                runRecoilFallback(snapshot: snapshot, aimRequest: request, recoilRequest: recoilRequest,
                    hostGeneration: hostGeneration, revision: revision, idleStatus: "目标缓存发布失败")
                return
            }
        } else if selectedActor != 0,
                  let cached = dynamics.cachedTarget(generation: snapshot.sessionGeneration,
                    now: snapshot.captureCompletedMonotonicSeconds, stateClear: true) {
            actor = selectedActor; target = cached
        } else {
            resetAimRuntime()
            runRecoilFallback(snapshot: snapshot, aimRequest: request, recoilRequest: recoilRequest,
                hostGeneration: hostGeneration, revision: revision, idleStatus: "范围内无目标，缓存已失效")
            return
        }
        guard let freshMark = snapshot.marks.first(where: {
            $0.actorAddress == actor && $0.actorWorldPosition != nil
        }) else {
            CoreSetAimDisplayRecordStore.shared.clear()
            runRecoilFallback(snapshot: snapshot, aimRequest: request, recoilRequest: recoilRequest,
                hostGeneration: hostGeneration, revision: revision,
                idleStatus: "75ms目标缓存保持；fresh actor拒绝自瞄")
            return
        }
        if selectedStartedAt == 0 { selectedStartedAt = snapshot.captureCompletedMonotonicSeconds }
        guard let camera = snapshot.cameraWorldPosition,
              let step = dynamics.plan(camera: camera, target: target,
                actor: actor, publicationID: snapshot.snapshotID,
                now: snapshot.captureCompletedMonotonicSeconds,
                currentPitch: snapshot.controlPitchDegrees, currentYaw: snapshot.controlYawDegrees,
                configuration: configuration) else {
            CoreSetAimDisplayRecordStore.shared.clear()
            runRecoilFallback(snapshot: snapshot, aimRequest: request, recoilRequest: recoilRequest,
                hostGeneration: hostGeneration, revision: revision,
                idleStatus: "目标状态预热或采样间隔超限")
            return
        }
        publishDisplayTarget(mark: freshMark, target: target, step: step, snapshot: snapshot,
            request: request, hostGeneration: hostGeneration, revision: revision)
        switch submitMergedAction(snapshot: snapshot, aimStep: step, recoilRequest: recoilRequest,
            primaryToken: request.token, hostGeneration: hostGeneration,
            revision: revision, requireAimTrigger: true) {
        case .idle: publish("已对准目标，且压枪本帧无补偿")
        case .committed: break
        case .failed(let reason): fail(request, reason)
        }
    }
    private func publish(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.status = text; self?.coordinator?.refreshPlayerAvailability() }
    }
    private func fail(_ request: CoreSetApplyRequest<State>, _ reason: String) {
        guard active?.token == request.token else { return }
        cancellation.lock()
        if let current = liveToken, current != request.token { cancellation.unlock(); return }
        liveToken = nil; liveHostGeneration = 0
        cancellation.unlock()
        timer?.cancel(); timer = nil
        triggerState.reset()
        resetAimRuntime()
        _ = retireActionWorker()
        let completion = pendingCompletion; pendingCompletion = nil
        active = nil
        if let recoil = activeRecoil { failRecoil(recoil, reason) }
        else { _ = drainRosterProducer() }
        let pending = !pendingProbes.isEmpty
        DispatchQueue.main.async { [weak self] in
            if let self {
                if pending { self.cleanupPending = true }
                if !self.hasOtherLiveRequest(request.token) {
                    self.status = reason
                    self.executionFailure = reason
                    if !pending { self.cleanupPending = false }
                }
            }
            completion?(request.token, .failed(reason: reason))
            self?.coordinator?.refreshPlayerAvailability()
        }
    }
    private func failRecoil(_ request: CoreSetApplyRequest<CoreSetRecoilSettings>, _ reason: String) {
        guard activeRecoil?.token == request.token else { return }
        recoilTimer?.cancel(); recoilTimer = nil
        recoilDynamics.reset()
        let callback = pendingRecoilCompletion
        pendingRecoilCompletion = nil
        activeRecoil = nil
        if active == nil {
            _ = retireActionWorker(); invalidateHost(); _ = drainRosterProducer()
        }
        DispatchQueue.main.async { [weak self] in
            callback?(request.token, .failed(reason: reason))
            self?.coordinator?.refreshPlayerAvailability()
        }
    }
    func stopRecoil(_ token: CoreSetRequestToken,
        completion: @escaping (CoreSetRequestToken, CoreSetStopOutcome) -> Void) {
        worker.async { [weak self] in
            guard let self else { return }
            self.recoilTimer?.cancel(); self.recoilTimer = nil
            self.recoilDynamics.reset()
            let canceled = self.activeRecoil
            let callback = self.pendingRecoilCompletion
            self.activeRecoil = nil; self.pendingRecoilCompletion = nil
            if let canceled, let callback {
                DispatchQueue.main.async { callback(canceled.token, .failed(reason: "首次压枪提交前已停止")) }
            }
            if self.active == nil { _ = self.retireActionWorker() }
            self.drainPendingActionWorkers()
            let abandoned = self.recoilWritesCommitted || self.unrestoredActionEffects
            if self.active != nil {
                let clean = self.pendingProbes.isEmpty
                if clean { self.recoilWritesCommitted = false }
                DispatchQueue.main.async {
                    completion(token, clean ? (abandoned ? .stoppedWithoutRestoration : .restored) :
                        .failed(reason: "共享动作旧映射清理待确认"))
                }
                return
            }
            self.invalidateHost()
            let rosterClean = self.drainRosterProducer()
            let readClean = self.session.disconnect()
            let clean = rosterClean && self.pendingProbes.isEmpty &&
                readClean.taskPortReleased && readClean.generationAdvanced
            if clean {
                self.session = CoreSetReadSession(); self.session.diagnosticLabel = "aim-action"
                self.recoilWritesCommitted = false
                self.unrestoredActionEffects = false
            }
            self.activeHostGeneration = 0; self.activeRevision = 0
            DispatchQueue.main.async {
                self.readReady = false; self.cleanupPending = !clean
                completion(token, clean ? (abandoned ? .stoppedWithoutRestoration : .restored) :
                    .failed(reason: "共享动作会话清理待确认"))
                self.coordinator?.refreshPlayerAvailability()
            }
        }
    }
    func stop(_ token: CoreSetRequestToken, completion: @escaping (CoreSetRequestToken, CoreSetStopOutcome) -> Void) {
        worker.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel(); self.timer = nil
            self.triggerState.reset()
            self.resetAimRuntime()
            let canceled = self.active, callback = self.pendingCompletion
            self.active = nil; self.pendingCompletion = nil
            if let canceled, let callback {
                DispatchQueue.main.async { callback(canceled.token, .failed(reason: "首次提交前已停止")) }
            }
            _ = self.retireActionWorker()
            self.drainPendingActionWorkers()
            let abandoned = self.aimWritesCommitted || self.unrestoredActionEffects
            if let recoil = self.activeRecoil, self.pendingProbes.isEmpty {
                self.invalidateHost()
                self.cancellation.lock()
                self.liveRevision &+= 1
                let revision = self.liveRevision
                self.liveToken = recoil.token
                self.liveHostGeneration = self.activeHostGeneration
                self.cancellation.unlock()
                self.activeRevision = revision
                self.ensureRecoilTimer(canvas: self.activeCanvasSize,
                    hostGeneration: self.activeHostGeneration, revision: revision)
                self.aimWritesCommitted = false
                DispatchQueue.main.async {
                    completion(token, abandoned ? .stoppedWithoutRestoration : .restored)
                }
                return
            }
            if let recoil = self.activeRecoil {
                let recoilCallback = self.pendingRecoilCompletion
                self.activeRecoil = nil; self.pendingRecoilCompletion = nil
                self.recoilTimer?.cancel(); self.recoilTimer = nil
                DispatchQueue.main.async {
                    recoilCallback?(recoil.token, .failed(reason: "Aim停止时共享动作旧映射未清理，压枪同步终止"))
                }
            }
            self.invalidateHost()
            self.recoilTimer?.cancel(); self.recoilTimer = nil
            let rosterClean = self.drainRosterProducer()
            let readClean = self.session.disconnect()
            let clean = rosterClean && self.pendingProbes.isEmpty &&
                readClean.taskPortReleased && readClean.generationAdvanced
            if clean {
                self.session = CoreSetReadSession(); self.session.diagnosticLabel = "aim-action"
                self.aimWritesCommitted = false
                self.unrestoredActionEffects = false
            }
            self.activeHostGeneration = 0; self.activeRevision = 0
            DispatchQueue.main.async {
                self.readReady = false; self.cleanupPending = !clean
                if clean { self.executionFailure = nil }
                self.status = clean ? "已停止后续写入并清理目标会话" : "目标会话清理失败"
                completion(token, clean ? (abandoned ? .stoppedWithoutRestoration : .restored) :
                    .failed(reason: "目标会话清理待确认"))
                self.coordinator?.refreshPlayerAvailability()
            }
        }
    }
    func shutdownWriteSession() -> Bool {
        closed = true; readinessTimer?.invalidate(); readinessTimer = nil
        return worker.sync {
            timer?.cancel(); timer = nil
            recoilTimer?.cancel(); recoilTimer = nil
            invalidateHost()
            triggerState.reset()
            resetAimRuntime()
            recoilDynamics.reset()
            active = nil; activeRecoil = nil
            pendingCompletion = nil; pendingRecoilCompletion = nil
            _ = retireActionWorker()
            drainPendingActionWorkers()
            let rosterClean = drainRosterProducer()
            let result = session.disconnect()
            let clean = rosterClean && pendingProbes.isEmpty &&
                result.taskPortReleased && result.generationAdvanced
            if clean {
                aimWritesCommitted = false; recoilWritesCommitted = false
                unrestoredActionEffects = false
            }
            return clean
        }
    }
}
