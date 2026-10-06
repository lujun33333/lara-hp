import UIKit
import QuartzCore

// Fixed-hash Core v1.7 closed subset: actor-origin selection, scene/custom
// tuning, same-target preference, c4af8 response and independent axis bounds.
// Bone labels, LOS, downed composite, prediction producer and silent tracking
// remain unavailable.
final class CoreSetAimConsumer: CoreSetFeatureConsumer {
    typealias State = CoreSetAimSettings
    let capability = CoreSetCapability.aimControl
    private weak var coordinator: CoreSetRuntimeCoordinator?
    private let worker = DispatchQueue(label: "coreset.basic.aim", qos: .userInitiated)
    private var session = CoreSetReadSession()
    private let triggerState = CoreSetBasicAimTriggerState()
    private let dynamics = CoreSetV17AimDynamics()
    private var selectedActor: UInt64 = 0
    private var selectedGeneration: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private var readinessTimer: Timer?
    private var active: CoreSetApplyRequest<State>?
    private var pendingCompletion: ((CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void)?
    private var pendingProbes: [CoreSetIsolatedWriteProbe] = []
    private var attemptedWrite = false
    private var readReady = false
    private var cleanupPending = false
    private var executionFailure: String?
    private var closed = false
    private let cancellation = NSLock()
    private var liveToken: CoreSetRequestToken?
    private var liveHostGeneration: UInt64 = 0
    private var liveRevision: UInt64 = 0
    private(set) var status = "目标只读会话未就绪"

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
            return .unavailable(reason: cleanupPending ? "基础自瞄清理或恢复待确认" : "基础自瞄目标只读会话或画布未就绪")
        }
        let info = CoreSetKernelWriteProfileRegistry.diagnosticSnapshot()
        guard (info["profileMatches"] as? Bool) == true else {
            let reasons = (info["failureReasons"] as? [String])?.joined(separator: "; ") ?? "已审内核配置不可用"
            return .unavailable(reason: "基础写入未启用：\(reasons)")
        }
        return .ready
    }
    var supportedFields: Set<CoreSetField> {
        [.basicAimEnabled, .basicAimTrigger, .basicAimDistance, .basicAimRadius, .basicAimBots,
         .basicAimScene, .basicAimStrength, .basicAimSmoothing, .basicAimHorizontalSpeed,
         .basicAimVerticalSpeed, .basicAimLockSameTarget, .basicAimPoint,
         .basicAimLockThreshold, .basicAimConfirmationFrames, .basicAimTakeoverPause]
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
                case .stopped: completion(token, .applied(observed: request.desired))
                case .failed(let reason): completion(token, .failed(reason: reason))
                }
            }
            return
        }
        guard availability == .ready, let canvas = coordinator?.playerCanvas,
              request.desired.enabled == true, request.desired.trigger != nil,
              request.desired.includeBots != nil, request.desired.circleSize.value != nil,
              tuning(request.desired) != nil,
              request.desired.point != nil, request.desired.point != .chest,
              request.desired.excludeKnocked != true else {
            completion(request.token, .unavailable(reason: "倒地组合、LOS、预测速度源和静默追踪尚未闭合")); return
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
            self.attemptedWrite = false
            self.triggerState.reset()
            self.resetAimRuntime()
            let timer = DispatchSource.makeTimerSource(queue: self.worker)
            timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.tick(request, canvas: canvas.size, hostGeneration: canvas.generation, revision: revision) }
            self.timer = timer; timer.resume()
        }
    }
    private struct Tuning {
        let distance: Int, strength: Float, smoothing: Float, pitchSpeed: Float, yawSpeed: Float
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
                pitchSpeed: 220, yawSpeed: 300, lockThreshold: lockValues.0,
                confirmationFrames: lockValues.1, pauseSeconds: lockValues.2)
            case .general: return Tuning(distance: 180, strength: 0.80, smoothing: 0.060,
                pitchSpeed: 300, yawSpeed: 420, lockThreshold: lockValues.0,
                confirmationFrames: lockValues.1, pauseSeconds: lockValues.2)
            case .close: return Tuning(distance: 70, strength: 0.88, smoothing: 0.048,
                pitchSpeed: 420, yawSpeed: 600, lockThreshold: lockValues.0,
                confirmationFrames: lockValues.1, pauseSeconds: lockValues.2)
            case .custom: return nil
            }
        case .custom:
            guard let distance = settings.custom.maximumDistance.value,
                  let strength = settings.custom.strength.value,
                  let smoothing = settings.custom.smoothing.value,
                  let horizontal = settings.custom.horizontalSpeed.value,
                  let vertical = settings.custom.verticalSpeed.value,
                  let threshold = settings.custom.lockThreshold.value,
                  let frames = settings.custom.confirmationFrames.value,
                  let pause = settings.custom.takeoverPauseMilliseconds.value else { return nil }
            return Tuning(distance: distance, strength: Float(strength) / 100,
                          smoothing: 0.024 + 0.012 * Float(smoothing),
                          pitchSpeed: Float(vertical), yawSpeed: Float(horizontal),
                          lockThreshold: Float(threshold) / 100,
                          confirmationFrames: frames, pauseSeconds: Double(pause) / 1000)
        }
    }
    private func capture(_ size: CGSize, distance: Int) -> CoreSetPlayerSnapshot? {
        CoreSetPlayerCollector.capture(session, canvasSize: size,
            playerBones: false, botBones: false, boneDistanceLimit: Double(distance),
            includeOffscreen: false, includeRadar: false, includeBattleInputs: true,
            playerWeaponText: false, botWeaponText: false, includeGrenadeWarning: false,
            includeCounts: false, playerInformation: false, botInformation: false,
            includeWarningYaw: false, maximumDrawDistance: Double(distance))
    }
    private func resetAimRuntime() {
        dynamics.reset(); selectedActor = 0; selectedGeneration = 0
    }
    private func tick(_ request: CoreSetApplyRequest<State>, canvas: CGSize, hostGeneration: UInt64, revision: UInt64) {
        guard pendingProbes.isEmpty else { fail(request, "旧事务清理待确认，禁止后续写入"); return }
        guard isLive(request.token, host: hostGeneration),
              let tuning = tuning(request.desired),
              let size = request.desired.circleSize.value,
              let snapshot = capture(canvas, distance: tuning.distance), snapshot.battleInputsPresent,
              let camera = snapshot.cameraWorldPosition else {
            fail(request, "战斗采样失效或请求撤销"); return
        }
        if selectedGeneration != 0 && selectedGeneration != snapshot.sessionGeneration { resetAimRuntime() }
        let trigger = triggerState.update(mode: request.desired.trigger?.rawValue ?? -1,
            ads: snapshot.localADS, firing: snapshot.localFiring, now: CACurrentMediaTime())
        guard trigger else { publish("等待触发，未写入"); return }
        guard dynamics.permitsTakeover(pitch: snapshot.rotationInputPitch, yaw: snapshot.rotationInputYaw,
            threshold: tuning.lockThreshold, confirmationFrames: tuning.confirmationFrames,
            pauseSeconds: tuning.pauseSeconds, now: snapshot.captureCompletedMonotonicSeconds) else {
            publish("检测到接管输入，暂停写入"); return
        }
        let short = min(canvas.width, canvas.height)
        let radius = max(30, min(short * CGFloat(size) / 1170, min(short * 0.45, 525)))
        guard let point = request.desired.point else { fail(request, "fallback点未配置"); return }
        let previousActor = selectedActor
        let selected = CoreSetBasicAimDelta.select(snapshot: snapshot, point: point.rawValue, radius: Double(radius),
            maximumDistance: Double(tuning.distance), includeBots: request.desired.includeBots == true,
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
                resetAimRuntime(); publish("目标缓存发布失败，未写入"); return
            }
        } else if selectedActor != 0,
                  let cached = dynamics.cachedTarget(generation: snapshot.sessionGeneration,
                    now: snapshot.captureCompletedMonotonicSeconds, stateClear: true) {
            actor = selectedActor; target = cached
        } else {
            resetAimRuntime(); publish("范围内无目标，缓存已失效"); return
        }
        guard snapshot.marks.contains(where: { $0.actorAddress == actor && $0.actorWorldPosition != nil }) else {
            publish("75ms目标缓存保持；fresh actor门禁拒绝写入"); return
        }
        guard let step = dynamics.plan(camera: camera, target: target, actor: actor,
            generation: snapshot.sessionGeneration, now: snapshot.captureCompletedMonotonicSeconds,
            currentPitch: snapshot.controlPitchDegrees, currentYaw: snapshot.controlYawDegrees,
            strength: tuning.strength, smoothingSeconds: tuning.smoothing,
            pitchSpeed: tuning.pitchSpeed, yawSpeed: tuning.yawSpeed) else {
            publish("目标状态预热或采样间隔超限，未写入"); return
        }
        let pitchDelta = step.pitch, yawDelta = step.yaw
        guard pitchDelta != 0 || yawDelta != 0 else { publish("已对准actor原点，未写入"); return }
        guard let verified = capture(canvas, distance: tuning.distance),
              CoreSetBasicAimDelta.validate(captured: snapshot, live: verified, actor: actor,
                point: point.rawValue, radius: Double(radius), maximumDistance: Double(tuning.distance),
                includeBots: request.desired.includeBots == true,
                lockSameTarget: request.desired.lockSameTarget == true,
                previousActor: previousActor, expectedTarget: target) else {
            publish("提交前目标或输入已变化，本帧未写入"); return
        }
        let probe = CoreSetIsolatedWriteProbe(liveValidator: { [weak self] _, token, liveHost, liveRevision in
            guard let self, self.isLive(request.token, host: hostGeneration),
                  self.triggerState.permits(now: CACurrentMediaTime()),
                  token == request.token.requestID, liveHost == hostGeneration,
                  liveRevision == revision else { return false }
            return self.isLive(request.token, host: hostGeneration)
        })
        let result = probe.submit(snapshot: verified, requestToken: request.token.requestID,
            hostGeneration: hostGeneration, configRevision: revision, axis: .both,
            pitchDelta: pitchDelta, yawDelta: yawDelta)
        let cleanup = probe.stop()
        attemptedWrite = attemptedWrite || cleanup.targetWriteAttempted
        if !cleanup.complete { pendingProbes.append(probe) }
        guard result.committed, cleanup.complete, isLive(request.token, host: hostGeneration) else {
            fail(request, result.reason); return
        }
        publish("v1.7闭合角度子链已独立回读；预测/LOS/倒地未启用")
        if let completion = pendingCompletion {
            pendingCompletion = nil
            DispatchQueue.main.async { completion(request.token, .applied(observed: request.desired)) }
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
    func stop(_ token: CoreSetRequestToken, completion: @escaping (CoreSetRequestToken, CoreSetStopOutcome) -> Void) {
        invalidateHost()
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
            let readClean = self.session.disconnect()
            let clean = self.pendingProbes.isEmpty && readClean.taskPortReleased && readClean.generationAdvanced
            if clean { self.session = CoreSetReadSession() }
            let restored = clean && !self.attemptedWrite
            DispatchQueue.main.async {
                self.readReady = false; self.cleanupPending = !clean
                if clean { self.executionFailure = nil }
                self.status = clean ? "已停止；动态视角未回写旧值" : "目标会话清理待确认"
                completion(token, !clean ? .failed(reason: "目标会话清理待确认") :
                    (restored ? .restored : .stopped(reason: "后续写已停止并清理；动态视角未回写旧值")))
                self.coordinator?.refreshPlayerAvailability()
            }
        }
    }
    func shutdownWriteSession() -> Bool {
        invalidateHost(); closed = true; readinessTimer?.invalidate(); readinessTimer = nil
        return worker.sync {
            timer?.cancel(); timer = nil
            triggerState.reset()
            resetAimRuntime()
            pendingProbes = pendingProbes.filter { !$0.stop().complete }
            let result = session.disconnect()
            return pendingProbes.isEmpty && result.taskPortReleased && result.generationAdvanced
        }
    }
}
