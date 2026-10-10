import UIKit
import QuartzCore

// Core v1.7 target selection, point interpolation, relative-motion prediction,
// recoil post/raw state, two-axis merge and one serial action-write route.
final class CoreSetAimConsumer: CoreSetFeatureConsumer {
    typealias State = CoreSetAimSettings
    let capability = CoreSetCapability.aimControl
    private weak var coordinator: CoreSetRuntimeCoordinator?
    private let battleProducer: CoreSetBattleProducer
    private let worker = DispatchQueue(label: "coreset.basic.aim", qos: .userInitiated)
    private let triggerState = CoreSetBasicAimTriggerState()
    private let dynamics = CoreSetV17AimDynamics()
    private let routeProducer = CoreSetV17ActionRouteProducer()
    private let recoilDynamics = CoreSetV17RecoilDynamics()
    private var selectedActor: UInt64 = 0
    private var selectedGeneration: UInt64 = 0
    private var selectedStartedAt: Double = 0
    private var timer: DispatchSourceTimer?
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
    private var routeProducerIdentity: ActionWorkerIdentity?
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
    private var pendingStatusText: String?
    private var statusPublishScheduled = false
    private var lastStatusPublishedAt: Double = 0
    private(set) var status = "目标只读会话未就绪"

    var recoilAvailability: CoreSetAvailability { availability }
    private var recoilFields: Set<CoreSetField> {
        [.recoilEnabled, .recoilStopWhenNotFiring, .recoilVerticalEnabled,
         .recoilVerticalStrength, .recoilHorizontalEnabled, .recoilHorizontalStrength]
    }

    init(coordinator: CoreSetRuntimeCoordinator, battleProducer: CoreSetBattleProducer) {
        self.coordinator = coordinator
        self.battleProducer = battleProducer
        readinessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }
    private func refresh() {
        guard !closed, !cleanupPending else { return }
        battleProducer.refreshReadiness { [weak self] ready in
            guard let self, !self.closed else { return }
            self.readReady = ready
            self.coordinator?.refreshPlayerAvailability()
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
    private func persistentActionWorker(input: CoreSetActionInputAuthority,
        primaryToken: CoreSetRequestToken, hostGeneration: UInt64,
        revision: UInt64) -> CoreSetIsolatedWriteProbe? {
        let identity = ActionWorkerIdentity(requestID: primaryToken.requestID,
            hostGeneration: hostGeneration, revision: revision,
            processID: input.processID, imageBase: input.imageBase,
            readGeneration: input.sessionGeneration, controller: input.controllerAddress)
        if actionWorkerIdentity == identity, let actionProbe { return actionProbe }
        guard retireActionWorker(), pendingProbes.isEmpty else { return nil }
        let readSession = battleProducer.readSession
        let probe = CoreSetIsolatedWriteProbe(readSession: readSession,
            liveValidator: { [weak self, weak readSession] captured, token, liveHost, liveRevision in
                guard let self, let readSession else { return false }
                return self.actionWorkerLive(token, host: liveHost, revision: liveRevision) &&
                    CoreSetPlayerCollector.validateLiveAuthority(readSession, authority: captured)
            })
        actionWorkerIdentity = identity; actionProbe = probe
        return probe
    }
    private func prepareRouteProducer(input: CoreSetActionInputAuthority,
        primaryToken: CoreSetRequestToken, hostGeneration: UInt64, revision: UInt64) {
        let identity = ActionWorkerIdentity(requestID: primaryToken.requestID,
            hostGeneration: hostGeneration, revision: revision,
            processID: input.processID, imageBase: input.imageBase,
            readGeneration: input.sessionGeneration, controller: input.controllerAddress)
        if routeProducerIdentity != identity {
            routeProducer.reset()
            routeProducerIdentity = identity
        }
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
            self.pendingStatusText = nil
            self.timer?.cancel(); self.timer = nil
            // Move the live-token handoff onto the same serial queue as the
            // action timer. Main-thread invalidation used to leave a window in
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
            self.pendingStatusText = nil
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
                self.replaceActionTimerWithRecoil(canvas: canvas.size,
                    hostGeneration: canvas.generation, revision: revision)
            }
        }
    }
    // Core owns one continuous action worker. Recoil-only operation replaces
    // that worker's timer; when Aim is active its tick already merges recoil.
    private func replaceActionTimerWithRecoil(canvas: CGSize, hostGeneration: UInt64,
                                               revision: UInt64) {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: worker)
        source.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        source.setEventHandler { [weak self] in
            self?.tickRecoilOnly(canvas: canvas, hostGeneration: hostGeneration, revision: revision)
        }
        timer = source
        source.resume()
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
                              candidate: CoreSetActionCandidateRecord) -> CGPoint? {
        let raw = candidate.raw
        let width = Double(candidate.canvasSize.width), height = Double(candidate.canvasSize.height)
        let fov = candidate.cameraFieldOfViewDegrees
        guard width > 0, height > 0, fov.isFinite, fov > 1, fov < 170 else { return nil }
        let degrees = Double.pi / 180
        let pitch = candidate.cameraPitchDegrees * degrees
        let yaw = candidate.cameraYawDegrees * degrees
        let roll = candidate.cameraRollDegrees * degrees
        let sp = sin(pitch), cp = cos(pitch), sy = sin(yaw), cy = cos(yaw)
        let sr = sin(roll), cr = cos(roll)
        let dx = Double(target.x - raw.camera.0)
        let dy = Double(target.y - raw.camera.1)
        let dz = Double(target.z - raw.camera.2)
        let depth = dx * cp * cy + dy * cp * sy + dz * sp
        guard depth.isFinite, depth > 1 else { return nil }
        let right = dx * (sr * sp * cy - cr * sy) +
            dy * (sr * sp * sy + cr * cy) - dz * sr * cp
        let up = dx * (sr * sy - cr * sp * cy) +
            dy * (sr * cy - cr * sp * sy) + dz * cr * cp
        let focal = (width / 2) / tan(fov * degrees / 2)
        let point = CGPoint(x: width / 2 + focal * right / depth,
            y: height / 2 - focal * up / depth)
        return point.x.isFinite && point.y.isFinite ? point : nil
    }
    private func publishDisplayTarget(candidate: CoreSetActionCandidateRecord,
                                      input: CoreSetActionInputAuthority,
                                      step: CoreSetBasicAimDelta,
                                      request: CoreSetApplyRequest<State>,
                                      hostGeneration: UInt64, revision: UInt64) {
        let raw = candidate.raw
        guard raw.valid != 0, raw.candidateKey != 0,
              selectedStartedAt.isFinite, selectedStartedAt >= 0,
              candidate.screenPoint.x.isFinite, candidate.screenPoint.y.isFinite else {
            CoreSetAimDisplayRecordStore.shared.clear()
            return
        }
        let identity = CoreSetAimDisplaySourceIdentity(snapshotID: candidate.snapshotID,
            sessionGeneration: candidate.sessionGeneration, processID: candidate.processID,
            imageBase: candidate.imageBase, hostGeneration: hostGeneration,
            actionRevision: revision, actionRequestID: request.token.requestID)
        let predicted = step.predictedWorldPoint
        let predictedPoint = predicted.flatMap { displayPoint(target: $0, candidate: candidate) }
        let record = CoreSetAimDisplayRecord(identity: identity,
            actorAddress: raw.candidateKey, candidateKey: raw.candidateKey,
            candidateStartedMonotonicSeconds: selectedStartedAt,
            worldPoint: CoreSetAimDisplayWorldPoint(x: raw.target.0,
                y: raw.target.1, z: raw.target.2),
            screenPoint: candidate.screenPoint,
            predictedWorldPoint: predicted.map {
                CoreSetAimDisplayWorldPoint(x: $0.x, y: $0.y, z: $0.z)
            }, predictedScreenPoint: predictedPoint, bot: candidate.bot,
            distanceMeters: candidate.distanceMeters,
            captureStartedMonotonicSeconds: input.captureStartedMonotonicSeconds,
            captureCompletedMonotonicSeconds: input.captureCompletedMonotonicSeconds)
        CoreSetAimDisplayRecordStore.shared.publish(record)
    }
    private func resetAimRuntime() {
        dynamics.reset(); selectedActor = 0; selectedGeneration = 0; selectedStartedAt = 0
        CoreSetAimDisplayRecordStore.shared.clear()
    }
    private enum ActionSubmitResult { case idle, committed, failed(String) }
    private func submitMergedAction(input: CoreSetActionInputAuthority, aimStep: CoreSetBasicAimDelta?,
        recoilRequest: CoreSetApplyRequest<CoreSetRecoilSettings>?,
        route: CoreSetV17ActionRouteDecision,
        primaryToken: CoreSetRequestToken, hostGeneration: UInt64, revision: UInt64,
        requireAimTrigger: Bool) -> ActionSubmitResult {
        let recoil = recoilRequest.flatMap { recoilConfiguration($0.desired) }
        guard let merged = recoilDynamics.plan(input: input,
            aimPitch: aimStep?.pitch ?? 0, aimYaw: aimStep?.yaw ?? 0,
            geometrySampleKey: aimStep?.geometrySampleKey ?? 0,
            configuration: recoil) else {
            return .failed("Core v1.7 Aim/Recoil 合并状态无效")
        }
        let pitch = merged.pitch, yaw = merged.yaw
        let recoilEnabled = recoil != nil
        if pitch == 0 && yaw == 0 {
            recoilDynamics.observeAimFeedback(pitch: aimStep?.pitch ?? 0,
                inputRoute: route.slotRaw == 2, recoilEnabled: recoilEnabled,
                aimActive: aimStep != nil, acceptedFirstAxis: false, bothZeroDraft: true)
            return .idle
        }
        guard route.resolved else { return .failed("Core c2e24 同帧 predecessor authority 未发布") }
        let slot: CoreSetTargetWriteSlot
        switch route.slotRaw {
        case 1: slot = .controlRotation
        case 2: slot = .rotationInput
        default: return .failed("Core c2e24 写槽值无效")
        }
        let axis: CoreSetTargetWriteAxis = pitch != 0 && yaw != 0 ? .both : (pitch != 0 ? .first : .second)
        let lane: CoreSetTargetWriteLane = aimStep == nil && recoilEnabled ? .recoil : .aim
        guard let probe = persistentActionWorker(input: input,
            primaryToken: primaryToken, hostGeneration: hostGeneration,
            revision: revision) else { return .failed("常驻动作 worker 清理或重建失败") }
        if requireAimTrigger && !triggerState.permits(now: CACurrentMediaTime()) { return .idle }
        let result = probe.submit(authority: input, requestToken: primaryToken.requestID,
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
        battleProducer.requestRecoil(recoilRequest, canvas: canvas,
            hostGeneration: hostGeneration, revision: revision)
        let capture = battleProducer.copyAction(requestID: recoilRequest.token.requestID,
            hostGeneration: hostGeneration, revision: revision)
        guard isLive(recoilRequest.token, host: hostGeneration) else { return }
        guard let capture else {
            let failedAt = CACurrentMediaTime()
            deferBattleCapture(now: failedAt)
            noteCaptureFailure("battle-publication-waiting", lane: "recoil", now: failedAt)
            return
        }
        noteCaptureSuccess(lane: "recoil")
        prepareRouteProducer(input: capture.input, primaryToken: recoilRequest.token,
            hostGeneration: hostGeneration, revision: revision)
        switch submitMergedAction(input: capture.input, aimStep: nil, recoilRequest: recoilRequest,
            route: routeProducer.resolveRecoilOnly(),
            primaryToken: recoilRequest.token,
            hostGeneration: hostGeneration, revision: revision, requireAimTrigger: false) {
        case .idle: publish("压枪状态预热或本帧无补偿")
        case .committed: break
        case .failed(let reason): failRecoil(recoilRequest, reason)
        }
    }
    private func runRecoilFallback(input: CoreSetActionInputAuthority,
        aimRequest: CoreSetApplyRequest<State>,
        recoilRequest: CoreSetApplyRequest<CoreSetRecoilSettings>?,
        hostGeneration: UInt64, revision: UInt64, idleStatus: String) {
        guard let recoilRequest else { publish(idleStatus); return }
        switch submitMergedAction(input: input, aimStep: nil, recoilRequest: recoilRequest,
            route: routeProducer.resolveRecoilOnly(),
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
        let radius = CoreSetBasicAimDelta.circleRadius(canvasWidth: Double(canvas.width),
            height: Double(canvas.height), size: size)
        guard radius > 0 else { fail(request, "Core v1.7 自瞄圈参数无效"); return }
        guard let point = request.desired.point else { fail(request, "fallback点未配置"); return }
        battleProducer.requestAim(request, canvas: canvas, radius: radius,
            maximumDistance: configuration.maximumDistance, point: point.rawValue,
            includeBots: request.desired.includeBots == true,
            excludeKnocked: request.desired.excludeKnocked == true,
            lockSameTarget: request.desired.lockSameTarget == true,
            hostGeneration: hostGeneration, revision: revision)
        if let recoilRequest = activeRecoil {
            battleProducer.requestRecoil(recoilRequest, canvas: canvas,
                hostGeneration: hostGeneration, revision: revision)
        }
        let capture = battleProducer.copyAction(requestID: request.token.requestID,
            hostGeneration: hostGeneration, revision: revision)
        guard isLive(request.token, host: hostGeneration) else { return }
        guard let capture else {
            let failedAt = CACurrentMediaTime()
            deferBattleCapture(now: failedAt)
            noteCaptureFailure("battle-publication-waiting", lane: "aim", now: failedAt)
            return
        }
        noteCaptureSuccess(lane: "aim")
        let input = capture.input
        prepareRouteProducer(input: input, primaryToken: request.token,
            hostGeneration: hostGeneration, revision: revision)
        if selectedGeneration != 0 && selectedGeneration != input.sessionGeneration { resetAimRuntime() }
        let recoilRequest = activeRecoil
        let trigger = triggerState.update(mode: request.desired.trigger?.rawValue ?? -1,
            ads: input.localADS, firing: input.localFiring, now: CACurrentMediaTime())
        if !trigger {
            guard recoilRequest != nil else { publish("等待触发，未写入"); return }
            switch submitMergedAction(input: input, aimStep: nil, recoilRequest: recoilRequest,
                route: routeProducer.resolveRecoilOnly(),
                primaryToken: request.token, hostGeneration: hostGeneration,
                revision: revision, requireAimTrigger: false) {
            case .idle: publish("等待自瞄触发；压枪本帧预热或无补偿")
            case .committed: break
            case .failed(let reason): fail(request, reason)
            }
            return
        }
        guard let route = routeProducer.resolveAim(pitch: input.rotationInputPitch,
            yaw: input.rotationInputYaw, configuration: configuration,
            now: input.captureCompletedMonotonicSeconds) else {
            fail(request, "Core c3018/c38c8 路由生产者拒绝当前输入")
            return
        }
        if !route.aimAllowed {
            guard recoilRequest != nil else { publish("检测到接管输入，暂停写入"); return }
            switch submitMergedAction(input: input, aimStep: nil, recoilRequest: recoilRequest,
                route: routeProducer.resolveRecoilOnly(),
                primaryToken: request.token, hostGeneration: hostGeneration,
                revision: revision, requireAimTrigger: false) {
            case .idle: publish("检测到接管输入；压枪本帧预热或无补偿")
            case .committed: break
            case .failed(let reason): fail(request, reason)
            }
            return
        }
        guard let candidate = capture.candidate else {
            resetAimRuntime()
            runRecoilFallback(input: input, aimRequest: request, recoilRequest: recoilRequest,
                hostGeneration: hostGeneration, revision: revision, idleStatus: "范围内无目标，缓存已失效")
            return
        }
        let actor = candidate.raw.candidateKey
        if selectedActor != actor || selectedGeneration != candidate.sessionGeneration {
            dynamics.reset(); selectedActor = actor; selectedGeneration = candidate.sessionGeneration
            selectedStartedAt = candidate.captureCompletedMonotonicSeconds
        }
        if selectedStartedAt == 0 { selectedStartedAt = candidate.captureCompletedMonotonicSeconds }
        guard let step = dynamics.plan(candidate: candidate, input: input,
            configuration: configuration) else {
            CoreSetAimDisplayRecordStore.shared.clear()
            runRecoilFallback(input: input, aimRequest: request, recoilRequest: recoilRequest,
                hostGeneration: hostGeneration, revision: revision,
                idleStatus: "目标状态预热或采样间隔超限")
            return
        }
        publishDisplayTarget(candidate: candidate, input: input, step: step,
            request: request, hostGeneration: hostGeneration, revision: revision)
        switch submitMergedAction(input: input, aimStep: step, recoilRequest: recoilRequest,
            route: route,
            primaryToken: request.token, hostGeneration: hostGeneration,
            revision: revision, requireAimTrigger: true) {
        case .idle: publish("已对准目标，且压枪本帧无补偿")
        case .committed: break
        case .failed(let reason): fail(request, reason)
        }
    }
    private func publish(_ text: String) {
        // The action loop runs at 60 Hz. Status is UI telemetry, not part of the
        // action receipt, so collapse it before crossing onto the main queue.
        // Enqueuing one main-thread block per action tick starves touch delivery.
        pendingStatusText = text
        guard !statusPublishScheduled else { return }
        let now = CACurrentMediaTime()
        let delay = max(0, 0.25 - max(0, now - lastStatusPublishedAt))
        statusPublishScheduled = true
        worker.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.statusPublishScheduled = false
            guard !self.closed, let next = self.pendingStatusText else {
                self.pendingStatusText = nil
                return
            }
            self.pendingStatusText = nil
            self.lastStatusPublishedAt = CACurrentMediaTime()
            self.cancellation.lock()
            let requestID = self.liveToken?.requestID
            let hostGeneration = self.liveHostGeneration
            let revision = self.liveRevision
            self.cancellation.unlock()
            guard let requestID else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.actionWorkerLive(requestID, host: hostGeneration,
                                            revision: revision) else { return }
                self.status = next
                self.coordinator?.refreshPlayerAvailability()
            }
        }
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
        pendingStatusText = nil
        _ = retireActionWorker()
        let completion = pendingCompletion; pendingCompletion = nil
        active = nil
        battleProducer.releaseAim(requestID: request.token.requestID)
        if let recoil = activeRecoil { failRecoil(recoil, reason) }
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
        pendingStatusText = nil
        if active == nil { timer?.cancel(); timer = nil }
        recoilDynamics.reset()
        let callback = pendingRecoilCompletion
        pendingRecoilCompletion = nil
        activeRecoil = nil
        battleProducer.releaseRecoil(requestID: request.token.requestID)
        if active == nil {
            _ = retireActionWorker(); invalidateHost()
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
            self.pendingStatusText = nil
            if self.active == nil { self.timer?.cancel(); self.timer = nil }
            self.recoilDynamics.reset()
            let canceled = self.activeRecoil
            let callback = self.pendingRecoilCompletion
            self.activeRecoil = nil; self.pendingRecoilCompletion = nil
            self.battleProducer.releaseRecoil(requestID: canceled?.token.requestID ?? token.requestID)
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
            let clean = self.pendingProbes.isEmpty
            if clean {
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
            self.pendingStatusText = nil
            self.timer?.cancel(); self.timer = nil
            self.triggerState.reset()
            self.resetAimRuntime()
            let canceled = self.active, callback = self.pendingCompletion
            self.active = nil; self.pendingCompletion = nil
            self.battleProducer.releaseAim(requestID: canceled?.token.requestID ?? token.requestID)
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
                self.replaceActionTimerWithRecoil(canvas: self.activeCanvasSize,
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
                DispatchQueue.main.async {
                    recoilCallback?(recoil.token, .failed(reason: "Aim停止时共享动作旧映射未清理，压枪同步终止"))
                }
            }
            self.invalidateHost()
            let clean = self.pendingProbes.isEmpty
            if clean {
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
            pendingStatusText = nil
            invalidateHost()
            triggerState.reset()
            resetAimRuntime()
            recoilDynamics.reset()
            active = nil; activeRecoil = nil
            pendingCompletion = nil; pendingRecoilCompletion = nil
            battleProducer.releaseAim(requestID: nil)
            battleProducer.releaseRecoil(requestID: nil)
            _ = retireActionWorker()
            drainPendingActionWorkers()
            let clean = pendingProbes.isEmpty
            if clean {
                aimWritesCommitted = false; recoilWritesCommitted = false
                unrestoredActionEffects = false
            }
            return clean
        }
    }
}
