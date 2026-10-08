import UIKit
import QuartzCore

// Core v1.7 target selection, point interpolation, relative-motion prediction,
// recoil post/raw state, two-axis merge and one serial action-write route.
final class CoreSetAimConsumer: CoreSetFeatureConsumer {
    typealias State = CoreSetAimSettings
    let capability = CoreSetCapability.aimControl
    private weak var coordinator: CoreSetRuntimeCoordinator?
    private let worker = DispatchQueue(label: "coreset.basic.aim", qos: .userInitiated)
    private var session = CoreSetReadSession()
    private let triggerState = CoreSetBasicAimTriggerState()
    private let dynamics = CoreSetV17AimDynamics()
    private let recoilDynamics = CoreSetV17RecoilDynamics()
    private let routeDynamics = CoreSetV17ActionRouteDynamics()
    private var selectedActor: UInt64 = 0
    private var selectedGeneration: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private var recoilTimer: DispatchSourceTimer?
    private var readinessTimer: Timer?
    private var active: CoreSetApplyRequest<State>?
    private var pendingCompletion: ((CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void)?
    private var activeRecoil: CoreSetApplyRequest<CoreSetRecoilSettings>?
    private var pendingRecoilCompletion: ((CoreSetRequestToken, CoreSetApplyOutcome<CoreSetRecoilSettings>) -> Void)?
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
    private(set) var status = "目标只读会话未就绪"

    var recoilAvailability: CoreSetAvailability { availability }
    private var recoilFields: Set<CoreSetField> {
        [.recoilEnabled, .recoilStopWhenNotFiring, .recoilVerticalEnabled,
         .recoilVerticalStrength, .recoilHorizontalEnabled, .recoilHorizontalStrength]
    }

    init(coordinator: CoreSetRuntimeCoordinator) {
        self.coordinator = coordinator
        readinessTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
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
                case .failed(let reason): completion(token, .failed(reason: reason))
                }
            }
            return
        }
        guard availability == .ready, let canvas = coordinator?.playerCanvas,
              request.desired.enabled == true, request.desired.trigger != nil,
              request.desired.includeBots != nil, request.desired.circleSize.value != nil,
              tuning(request.desired) != nil,
              request.desired.point != nil else {
            completion(request.token, .unavailable(reason: "基础自瞄参数未配置完整")); return
        }
        invalidateHost()
        cancellation.lock()
        liveRevision &+= 1
        let revision = liveRevision
        liveToken = request.token; liveHostGeneration = canvas.generation
        cancellation.unlock()
        worker.async { [weak self] in
            guard let self, self.isLive(request.token, host: canvas.generation) else {
                DispatchQueue.main.async { completion(request.token, .failed(reason: "开始前请求已撤销")) }
                return
            }
            self.timer?.cancel(); self.timer = nil
            guard self.pendingProbes.isEmpty else {
                self.invalidateHost()
                DispatchQueue.main.async {
                    self.cleanupPending = true
                    completion(request.token, .failed(reason: "旧事务映射清理待确认，拒绝新请求"))
                    self.coordinator?.refreshPlayerAvailability()
                }
                return
            }
            if let previous = self.active, let previousCompletion = self.pendingCompletion {
                DispatchQueue.main.async { previousCompletion(previous.token, .failed(reason: "请求已替换")) }
            }
            self.active = request; self.pendingCompletion = completion
            self.activeHostGeneration = canvas.generation
            self.activeRevision = revision
            self.activeCanvasSize = canvas.size
            self.triggerState.reset()
            self.resetAimRuntime()
            let timer = DispatchSource.makeTimerSource(queue: self.worker)
            timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.tick(request, canvas: canvas.size, hostGeneration: canvas.generation, revision: revision) }
            self.timer = timer; timer.resume()
        }
    }
    private struct RecoilTuning {
        let verticalEnabled: Bool
        let verticalStrength: Float
        let stopWhenNotFiring: Bool
        let horizontalEnabled: Bool
        let horizontalStrength: Float
    }
    private func recoilTuning(_ settings: CoreSetRecoilSettings) -> RecoilTuning? {
        guard settings.enabled == true,
              let verticalEnabled = settings.verticalEnabled,
              let vertical = settings.verticalStrength.value,
              let stop = settings.stopWhenNotFiring.enabled,
              let horizontalEnabled = settings.horizontalEnabled,
              let horizontal = settings.horizontalStrength.value else { return nil }
        return RecoilTuning(verticalEnabled: verticalEnabled,
            verticalStrength: Float(vertical) / 100, stopWhenNotFiring: stop,
            horizontalEnabled: horizontalEnabled, horizontalStrength: Float(horizontal) / 100)
    }
    func applyRecoil(_ request: CoreSetApplyRequest<CoreSetRecoilSettings>,
        completion: @escaping (CoreSetRequestToken, CoreSetApplyOutcome<CoreSetRecoilSettings>) -> Void) {
        precondition(Thread.isMainThread)
        if request.desired.enabled == false {
            stopRecoil(request.token) { token, outcome in
                switch outcome {
                case .restored: completion(token, .applied(observed: request.desired))
                case .failed(let reason): completion(token, .failed(reason: reason))
                }
            }
            return
        }
        guard recoilAvailability == .ready, recoilTuning(request.desired) != nil,
              let canvas = coordinator?.playerCanvas else {
            completion(request.token, .unavailable(reason: "压枪参数或共享动作会话未就绪")); return
        }
        worker.async { [weak self] in
            guard let self else { return }
            if let previous = self.activeRecoil, let callback = self.pendingRecoilCompletion {
                DispatchQueue.main.async { callback(previous.token, .failed(reason: "压枪请求已替换")) }
            }
            self.activeRecoil = request
            self.pendingRecoilCompletion = completion
            self.activeCanvasSize = canvas.size
            self.recoilDynamics.reset()
            self.resetRouteRuntime()
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
    private func resetRouteRuntime() {
        routeDynamics.reset()
    }
    private func actionSlot(recoilEnabled: Bool, inputPaused: Bool) -> CoreSetTargetWriteSlot {
        routeDynamics.useControlRotation(recoilEnabled: recoilEnabled, inputPaused: inputPaused)
            ? .controlRotation : .rotationInput
    }
    private func observeCommittedRoute(w20: Bool) {
        routeDynamics.observeCommitted(w20: w20)
    }
    private struct Tuning {
        let distance: Int, strength: Float, smoothing: Float, pitchSpeed: Float, yawSpeed: Float
        let predictionMilliseconds: Double
        let curveSelector: Float, residualGain: Float, minimumGain: Float
        let deadzoneRatio: Float, minimumDeadzone: Float
        let lockThreshold: Float, confirmationFrames: Int, pauseSeconds: Double
    }
    private func tuning(_ settings: State) -> Tuning? {
        guard let scene = settings.scene else { return nil }
        switch scene {
        case .far, .general, .close:
            guard let lock = settings.lockStrength else { return nil }
            let lockValues: (Float, Int, Double)
            switch lock {
            case .strong: lockValues = (0.10, 1, 0.420)
            case .medium: lockValues = (0.20, 2, 0.300)
            case .light: lockValues = (0.80, 3, 0.140)
            }
            switch scene {
            case .far: return Tuning(distance: 300, strength: 0.76, smoothing: 0.060,
                pitchSpeed: 220, yawSpeed: 300, predictionMilliseconds: 110,
                curveSelector: lockValues.0, residualGain: 0.90, minimumGain: 0.38,
                deadzoneRatio: 0.12, minimumDeadzone: 0.04, lockThreshold: lockValues.0,
                confirmationFrames: lockValues.1, pauseSeconds: lockValues.2)
            case .general: return Tuning(distance: 180, strength: 0.80, smoothing: 0.060,
                pitchSpeed: 300, yawSpeed: 420, predictionMilliseconds: 90,
                curveSelector: lockValues.0, residualGain: 0.56, minimumGain: 0.06,
                deadzoneRatio: 0.25, minimumDeadzone: 0.10, lockThreshold: lockValues.0,
                confirmationFrames: lockValues.1, pauseSeconds: lockValues.2)
            case .close: return Tuning(distance: 70, strength: 0.88, smoothing: 0.048,
                pitchSpeed: 420, yawSpeed: 600, predictionMilliseconds: 60,
                curveSelector: lockValues.0, residualGain: 0.62, minimumGain: 0.06,
                deadzoneRatio: 0.25, minimumDeadzone: 0.10, lockThreshold: lockValues.0,
                confirmationFrames: lockValues.1, pauseSeconds: lockValues.2)
            case .custom: return nil
            }
        case .custom:
            guard let distance = settings.custom.maximumDistance.value,
                  let strength = settings.custom.strength.value,
                  let smoothing = settings.custom.smoothing.value,
                  let horizontal = settings.custom.horizontalSpeed.value,
                  let vertical = settings.custom.verticalSpeed.value,
                  let prediction = settings.custom.predictionMilliseconds.value,
                  let threshold = settings.custom.lockThreshold.value,
                  let frames = settings.custom.confirmationFrames.value,
                  let pause = settings.custom.takeoverPauseMilliseconds.value else { return nil }
            return Tuning(distance: distance, strength: Float(strength) / 100,
                          smoothing: 0.024 + 0.012 * Float(smoothing),
                          pitchSpeed: Float(vertical), yawSpeed: Float(horizontal),
                          predictionMilliseconds: Double(prediction),
                          curveSelector: Float(threshold) / 100,
                          residualGain: 0.56, minimumGain: 0.06,
                          deadzoneRatio: 0.25, minimumDeadzone: 0.10,
                          lockThreshold: Float(threshold) / 100,
                          confirmationFrames: frames, pauseSeconds: Double(pause) / 1000)
        }
    }
    private func capture(_ size: CGSize, distance: Int) -> CoreSetPlayerSnapshot? {
        CoreSetPlayerCollector.capture(session, canvasSize: size,
            playerBones: true, botBones: true, boneDistanceLimit: Double(distance),
            includeOffscreen: false, includeRadar: false, includeBattleInputs: true,
            playerWeaponText: false, botWeaponText: false, includeGrenadeWarning: false,
            includeCounts: false, playerInformation: false, botInformation: false,
            includeWarningYaw: false, maximumDrawDistance: Double(distance))
    }
    private func resetAimRuntime() {
        dynamics.reset(); selectedActor = 0; selectedGeneration = 0
    }
    private enum ActionSubmitResult { case idle, committed, failed(String) }
    private func submitMergedAction(snapshot: CoreSetPlayerSnapshot, aimStep: CoreSetBasicAimDelta?,
        recoilRequest: CoreSetApplyRequest<CoreSetRecoilSettings>?, inputPaused: Bool,
        primaryToken: CoreSetRequestToken, hostGeneration: UInt64, revision: UInt64,
        requireAimTrigger: Bool) -> ActionSubmitResult {
        let recoil = recoilRequest.flatMap { recoilTuning($0.desired) }
        guard let merged = recoilDynamics.plan(snapshot: snapshot,
            aimPitch: aimStep?.pitch ?? 0, aimYaw: aimStep?.yaw ?? 0,
            geometrySampleKey: aimStep?.geometrySampleKey ?? 0,
            verticalEnabled: recoil?.verticalEnabled ?? false,
            verticalStrength: recoil?.verticalStrength ?? 0,
            stopWhenNotFiring: recoil?.stopWhenNotFiring ?? true,
            horizontalEnabled: recoil?.horizontalEnabled ?? false,
            horizontalStrength: recoil?.horizontalStrength ?? 0) else {
            return .failed("Core v1.7 Aim/Recoil 合并状态无效")
        }
        let pitch = merged.pitch, yaw = merged.yaw
        guard pitch != 0 || yaw != 0 else { return .idle }
        let axis: CoreSetTargetWriteAxis = pitch != 0 && yaw != 0 ? .both : (pitch != 0 ? .first : .second)
        let recoilEnabled = recoilRequest?.desired.enabled == true
        let slot = actionSlot(recoilEnabled: recoilEnabled, inputPaused: inputPaused)
        let lane: CoreSetTargetWriteLane = aimStep == nil && recoilEnabled ? .recoil : .aim
        let probe = CoreSetIsolatedWriteProbe(liveValidator: { [weak self] _, token, liveHost, liveRevision in
            guard let self, self.isLive(primaryToken, host: hostGeneration),
                  token == primaryToken.requestID, liveHost == hostGeneration,
                  liveRevision == revision else { return false }
            if requireAimTrigger && !self.triggerState.permits(now: CACurrentMediaTime()) { return false }
            return self.isLive(primaryToken, host: hostGeneration)
        })
        let result = probe.submit(snapshot: snapshot, requestToken: primaryToken.requestID,
            hostGeneration: hostGeneration, configRevision: revision, lane: lane,
            slot: slot, axis: axis, pitchDelta: pitch, yawDelta: yaw)
        let cleanup = probe.stop()
        if !cleanup.complete { pendingProbes.append(probe) }
        guard result.committed, cleanup.complete,
              isLive(primaryToken, host: hostGeneration) else { return .failed(result.reason) }
        recoilDynamics.observeCommitted(aimPitch: aimStep?.pitch ?? 0,
            inputRoute: slot == .rotationInput, recoilEnabled: recoilEnabled,
            aimActive: aimStep != nil, acceptedFirstAxis: pitch != 0,
            bothZeroDraft: false)
        observeCommittedRoute(w20: !inputPaused)
        let aimContributed = aimStep != nil && (merged.aimPitch != 0 || merged.aimYaw != 0)
        let recoilContributed = recoilEnabled && (merged.recoilPitch != 0 || merged.recoilYaw != 0)
        if aimContributed, let aim = active, let callback = pendingCompletion {
            pendingCompletion = nil
            DispatchQueue.main.async { callback(aim.token, .applied(observed: aim.desired)) }
        }
        if recoilContributed, let recoil = activeRecoil, let callback = pendingRecoilCompletion {
            pendingRecoilCompletion = nil
            DispatchQueue.main.async { callback(recoil.token, .applied(observed: recoil.desired)) }
        }
        publish("Core v1.7 Aim/Recoil 同帧合并已提交并回读")
        return .committed
    }
    private func tickRecoilOnly(canvas: CGSize, hostGeneration: UInt64, revision: UInt64) {
        guard active == nil, let recoilRequest = activeRecoil else { return }
        guard pendingProbes.isEmpty else { failRecoil(recoilRequest, "旧事务清理待确认，禁止压枪写入"); return }
        guard isLive(recoilRequest.token, host: hostGeneration),
              recoilTuning(recoilRequest.desired) != nil,
              let snapshot = capture(canvas, distance: 500), snapshot.battleInputsPresent else {
            failRecoil(recoilRequest, "压枪战斗采样失效或请求已撤销"); return
        }
        switch submitMergedAction(snapshot: snapshot, aimStep: nil, recoilRequest: recoilRequest,
            inputPaused: false, primaryToken: recoilRequest.token,
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
            inputPaused: false, primaryToken: aimRequest.token,
            hostGeneration: hostGeneration, revision: revision, requireAimTrigger: false) {
        case .idle: publish(idleStatus + "；压枪本帧预热或无补偿")
        case .committed: break
        case .failed(let reason): fail(aimRequest, reason)
        }
    }
    private func tick(_ request: CoreSetApplyRequest<State>, canvas: CGSize, hostGeneration: UInt64, revision: UInt64) {
        guard pendingProbes.isEmpty else { fail(request, "旧事务清理待确认，禁止后续写入"); return }
        guard isLive(request.token, host: hostGeneration),
              let tuning = tuning(request.desired),
              let size = request.desired.circleSize.value,
              let snapshot = capture(canvas, distance: tuning.distance), snapshot.battleInputsPresent,
              snapshot.cameraWorldPosition != nil else {
            fail(request, "战斗采样失效或请求撤销"); return
        }
        if selectedGeneration != 0 && selectedGeneration != snapshot.sessionGeneration { resetAimRuntime() }
        let recoilRequest = activeRecoil
        let trigger = triggerState.update(mode: request.desired.trigger?.rawValue ?? -1,
            ads: snapshot.localADS, firing: snapshot.localFiring, now: CACurrentMediaTime())
        if !trigger {
            guard recoilRequest != nil else { publish("等待触发，未写入"); return }
            switch submitMergedAction(snapshot: snapshot, aimStep: nil, recoilRequest: recoilRequest,
                inputPaused: false, primaryToken: request.token, hostGeneration: hostGeneration,
                revision: revision, requireAimTrigger: false) {
            case .idle: publish("等待自瞄触发；压枪本帧预热或无补偿")
            case .committed: break
            case .failed(let reason): fail(request, reason)
            }
            return
        }
        let takeoverAllowed = dynamics.permitsTakeover(pitch: snapshot.rotationInputPitch, yaw: snapshot.rotationInputYaw,
            threshold: tuning.lockThreshold, confirmationFrames: tuning.confirmationFrames,
            pauseSeconds: tuning.pauseSeconds, now: snapshot.captureCompletedMonotonicSeconds)
        if !takeoverAllowed {
            guard recoilRequest != nil else { publish("检测到接管输入，暂停写入"); return }
            switch submitMergedAction(snapshot: snapshot, aimStep: nil, recoilRequest: recoilRequest,
                inputPaused: true, primaryToken: request.token, hostGeneration: hostGeneration,
                revision: revision, requireAimTrigger: false) {
            case .idle: publish("检测到接管输入；压枪本帧预热或无补偿")
            case .committed: break
            case .failed(let reason): fail(request, reason)
            }
            return
        }
        let short = min(canvas.width, canvas.height)
        let radius = max(30, min(short * CGFloat(size) / 1170, min(short * 0.45, 525)))
        guard let point = request.desired.point else { fail(request, "fallback点未配置"); return }
        let previousActor = selectedActor
        let selected = CoreSetBasicAimDelta.select(snapshot: snapshot, point: point.rawValue, radius: Double(radius),
            maximumDistance: Double(tuning.distance), includeBots: request.desired.includeBots == true,
            excludeKnocked: request.desired.excludeKnocked == true,
            lockSameTarget: request.desired.lockSameTarget == true, previousActor: previousActor)
        let actor: UInt64
        let target: CoreSetWorldPoint
        if let selected,
           let fallback = CoreSetBasicAimDelta.fallbackTarget(mark: selected, point: point.rawValue) {
            actor = selected.actorAddress; target = fallback
            if selectedActor != actor || selectedGeneration != snapshot.sessionGeneration {
                dynamics.reset(); selectedActor = actor; selectedGeneration = snapshot.sessionGeneration
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
        guard snapshot.marks.contains(where: { $0.actorAddress == actor && $0.actorWorldPosition != nil }) else {
            runRecoilFallback(snapshot: snapshot, aimRequest: request, recoilRequest: recoilRequest,
                hostGeneration: hostGeneration, revision: revision,
                idleStatus: "75ms目标缓存保持；fresh actor拒绝自瞄")
            return
        }
        guard let camera = snapshot.cameraWorldPosition,
              let step = dynamics.plan(camera: camera, target: target,
                actor: actor, publicationID: snapshot.snapshotID,
                now: snapshot.captureCompletedMonotonicSeconds,
                currentPitch: snapshot.controlPitchDegrees, currentYaw: snapshot.controlYawDegrees,
                strength: tuning.strength, smoothingSeconds: tuning.smoothing,
                curveSelector: tuning.curveSelector, horizontalSpeed: tuning.yawSpeed,
                verticalSpeed: tuning.pitchSpeed, predictionMilliseconds: tuning.predictionMilliseconds,
                residualGain: tuning.residualGain, minimumGain: tuning.minimumGain,
                deadzoneRatio: tuning.deadzoneRatio, minimumDeadzone: tuning.minimumDeadzone) else {
            runRecoilFallback(snapshot: snapshot, aimRequest: request, recoilRequest: recoilRequest,
                hostGeneration: hostGeneration, revision: revision,
                idleStatus: "目标状态预热或采样间隔超限")
            return
        }
        switch submitMergedAction(snapshot: snapshot, aimStep: step, recoilRequest: recoilRequest,
            inputPaused: false, primaryToken: request.token, hostGeneration: hostGeneration,
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
        let completion = pendingCompletion; pendingCompletion = nil
        active = nil
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
        recoilTimer?.cancel(); recoilTimer = nil
        recoilDynamics.reset(); resetRouteRuntime()
        let callback = pendingRecoilCompletion
        pendingRecoilCompletion = nil
        activeRecoil = nil
        if active == nil { invalidateHost() }
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
            self.recoilDynamics.reset(); self.resetRouteRuntime()
            let canceled = self.activeRecoil
            let callback = self.pendingRecoilCompletion
            self.activeRecoil = nil; self.pendingRecoilCompletion = nil
            if let canceled, let callback {
                DispatchQueue.main.async { callback(canceled.token, .failed(reason: "首次压枪提交前已停止")) }
            }
            self.pendingProbes = self.pendingProbes.filter { !$0.stop().complete }
            if self.active != nil {
                let clean = self.pendingProbes.isEmpty
                DispatchQueue.main.async {
                    completion(token, clean ? .restored : .failed(reason: "共享动作旧映射清理待确认"))
                }
                return
            }
            self.invalidateHost()
            let readClean = self.session.disconnect()
            let clean = self.pendingProbes.isEmpty && readClean.taskPortReleased && readClean.generationAdvanced
            if clean { self.session = CoreSetReadSession() }
            self.activeHostGeneration = 0; self.activeRevision = 0
            DispatchQueue.main.async {
                self.readReady = false; self.cleanupPending = !clean
                completion(token, clean ? .restored : .failed(reason: "共享动作会话清理待确认"))
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
            self.pendingProbes = self.pendingProbes.filter { !$0.stop().complete }
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
                DispatchQueue.main.async { completion(token, .restored) }
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
            let readClean = self.session.disconnect()
            let clean = self.pendingProbes.isEmpty && readClean.taskPortReleased && readClean.generationAdvanced
            if clean { self.session = CoreSetReadSession() }
            self.activeHostGeneration = 0; self.activeRevision = 0
            DispatchQueue.main.async {
                self.readReady = false; self.cleanupPending = !clean
                if clean { self.executionFailure = nil }
                self.status = clean ? "已停止后续写入并清理目标会话" : "目标会话清理失败"
                completion(token, clean ? .restored : .failed(reason: "目标会话清理待确认"))
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
            recoilDynamics.reset(); resetRouteRuntime()
            active = nil; activeRecoil = nil
            pendingCompletion = nil; pendingRecoilCompletion = nil
            pendingProbes = pendingProbes.filter { !$0.stop().complete }
            let result = session.disconnect()
            return pendingProbes.isEmpty && result.taskPortReleased && result.generationAdvanced
        }
    }
}
