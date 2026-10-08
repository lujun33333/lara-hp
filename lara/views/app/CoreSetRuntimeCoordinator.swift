import UIKit

enum CoreSetRenderLane: Int, CaseIterable { case player, materials, radar, warning, appearance, aimDisplay }

// A producer must supply an observed snapshot and its exact request identity.
// This input has no implicit connection to a target game or memory reader.
struct CoreSetLaneSubmission {
    let lane: CoreSetRenderLane
    let hostGeneration: UInt64
    let configRevision: UInt64
    let snapshotID: UUID
    let requestToken: CoreSetRequestToken
    let canvasSize: CGSize
    let commands: [CoreSetRenderCommand]
    let appearance: CoreSetAdjustmentSettings?
    init(lane: CoreSetRenderLane, hostGeneration: UInt64, configRevision: UInt64,
         snapshotID: UUID, requestToken: CoreSetRequestToken, canvasSize: CGSize,
         commands: [CoreSetRenderCommand], appearance: CoreSetAdjustmentSettings? = nil) {
        self.lane = lane; self.hostGeneration = hostGeneration; self.configRevision = configRevision
        self.snapshotID = snapshotID; self.requestToken = requestToken
        self.canvasSize = canvasSize; self.commands = commands; self.appearance = appearance
    }
}

struct CoreSetLocalFrameReceipt {
    let lane: CoreSetRenderLane
    let hostGeneration: UInt64
    let sequence: UInt64
    let configRevision: UInt64
    let snapshotID: UUID
    let requestToken: CoreSetRequestToken
    let acceptedByLocalRenderer: Bool
}

// Owns all draw lanes and the one sequence space consumed by CoreSetHUDHost.
// A lane clear replaces only that lane's commands; other lanes retain theirs.
private final class CoreSetFrameComposer {
    private struct Pending {
        let frame: CoreSetRenderFrame
        let submission: CoreSetLaneSubmission
    }
    private(set) var generation: UInt64 = 0
    private var nextSequence: UInt64 = 2 // Sequence 1 is the host's local empty probe.
    private var lanes: [CoreSetRenderLane: CoreSetLaneSubmission] = [:]
    private var pending: [UInt64: Pending] = [:]
    private var stoppedAtRevision: [CoreSetRenderLane: UInt64] = [:]

    private func styled(_ command: CoreSetRenderCommand,
                        with settings: CoreSetAdjustmentSettings?) -> CoreSetRenderCommand? {
        guard let settings else { return command }
        let rgba: CoreSetRGBA?
        let thickness: Int?
        let fontSize: Int?
        switch command.styleRole {
        case .none: return command
        case .playerRay: rgba = settings.player.ray; thickness = settings.rayThickness.value; fontSize = nil
        case .botRay: rgba = settings.bot.ray; thickness = settings.rayThickness.value; fontSize = nil
        case .playerDistance: rgba = settings.player.distance; thickness = nil; fontSize = nil
        case .botDistance: rgba = settings.bot.distance; thickness = nil; fontSize = nil
        case .playerBone: rgba = settings.player.bone; thickness = settings.boneThickness.value; fontSize = nil
        case .botBone: rgba = settings.bot.bone; thickness = settings.boneThickness.value; fontSize = nil
        case .materialText: rgba = nil; thickness = nil; fontSize = settings.materialFontSize.value
        case .playerName: rgba = settings.player.name; thickness = nil; fontSize = nil
        case .botName: rgba = settings.bot.name; thickness = nil; fontSize = nil
        case .playerTeam: rgba = settings.player.team; thickness = nil; fontSize = nil
        case .botTeam: rgba = settings.bot.team; thickness = nil; fontSize = nil
        @unknown default: return nil
        }
        guard command.kind == .line || command.kind == .text else { return nil }
        let color = rgba.map { UIColor(red: CGFloat($0.red), green: CGFloat($0.green),
                                       blue: CGFloat($0.blue), alpha: CGFloat($0.alpha)) } ?? command.color
        let styled = CoreSetRenderCommand(kind: command.kind, rect: command.rect,
            endpoint: command.endpoint, color: color,
            lineWidth: thickness.map { CGFloat($0) } ?? command.lineWidth,
            filled: command.isFilled, text: command.text,
            fontSize: fontSize.map { CGFloat($0) } ?? command.fontSize)
        return command.horizontallyCenteredText ? styled.centeredText() : styled
    }

    func reset(to generation: UInt64) -> [CoreSetLocalFrameReceipt] {
        let expired = pending.values.map { receipt($0, accepted: false) }
        self.generation = generation
        nextSequence = 2
        lanes.removeAll()
        pending.removeAll()
        stoppedAtRevision.removeAll()
        return expired
    }

    func invalidateGeometry() -> [CoreSetLocalFrameReceipt] {
        let expired = pending.values.map { receipt($0, accepted: false) }
        // A layout change keeps the host and remote UIWindow generation.
        // Keep nextSequence monotonic so in-flight old frames stay stale.
        lanes.removeAll()
        pending.removeAll()
        stoppedAtRevision.removeAll()
        return expired
    }

    func makeFrame(_ input: CoreSetLaneSubmission) -> CoreSetRenderFrame? {
        guard input.hostGeneration == generation, nextSequence < UInt64.max,
              input.canvasSize.width.isFinite, input.canvasSize.height.isFinite,
              input.canvasSize.width > 0, input.canvasSize.height > 0 else { return nil }
        if let stopped = stoppedAtRevision[input.lane], !input.commands.isEmpty,
           input.configRevision <= stopped { return nil }
        var previous = lanes[input.lane]
        if let previous {
            guard input.configRevision >= previous.configRevision,
                  input.snapshotID != previous.snapshotID || input.configRevision != previous.configRevision else { return nil }
        }
        if let size = lanes.values.first?.canvasSize, size != input.canvasSize {
            // Geometry changed: all prior coordinates are stale; producers must refresh.
            lanes.removeAll()
            stoppedAtRevision.removeAll()
            previous = nil
        }
        lanes[input.lane] = input
        let source = CoreSetRenderLane.allCases.flatMap { lanes[$0]?.commands ?? [] }
        let styledCommands = source.map { styled($0, with: lanes[.appearance]?.appearance) }
        guard source.count <= 8192, styledCommands.allSatisfy({ $0 != nil }) else {
            lanes[input.lane] = previous
            return nil
        }
        let commands = styledCommands.compactMap { $0 }
        let sequence = nextSequence
        nextSequence += 1
        let token = "\(input.requestToken.generation.uuidString)/\(input.requestToken.consumerID.uuidString)/\(input.requestToken.requestID.uuidString)"
        let frame = CoreSetRenderFrame(generation: generation, sequence: sequence,
            canvasSize: input.canvasSize, configRevision: input.configRevision,
            snapshotID: input.snapshotID.uuidString, requestToken: token, commands: commands)
        pending[sequence] = Pending(frame: frame, submission: input)
        if !input.commands.isEmpty { stoppedAtRevision.removeValue(forKey: input.lane) }
        return frame
    }

    func makeClearFrame(_ input: CoreSetLaneSubmission) -> CoreSetRenderFrame? {
        guard input.commands.isEmpty, let frame = makeFrame(input) else { return nil }
        stoppedAtRevision[input.lane] = input.configRevision
        return frame
    }

    func consume(_ frame: CoreSetRenderFrame, accepted: Bool) -> CoreSetLocalFrameReceipt? {
        guard let item = pending[frame.sequence], item.frame === frame,
              frame.generation == generation, frame.generation == item.submission.hostGeneration,
              frame.configRevision == item.submission.configRevision,
              frame.snapshotID == item.submission.snapshotID.uuidString else { return nil }
        let expected = "\(item.submission.requestToken.generation.uuidString)/\(item.submission.requestToken.consumerID.uuidString)/\(item.submission.requestToken.requestID.uuidString)"
        guard frame.requestToken == expected else { return nil }
        pending.removeValue(forKey: frame.sequence)
        if !accepted { lanes.removeAll() } // The renderer cleared the whole canvas.
        return receipt(item, accepted: accepted)
    }

    private func receipt(_ item: Pending, accepted: Bool) -> CoreSetLocalFrameReceipt {
        CoreSetLocalFrameReceipt(lane: item.submission.lane, hostGeneration: item.frame.generation,
            sequence: item.frame.sequence, configRevision: item.frame.configRevision,
            snapshotID: item.submission.snapshotID, requestToken: item.submission.requestToken,
            acceptedByLocalRenderer: accepted)
    }
}

// One scene owns one menu and its authoritative FeatureState. Infrastructure
// readiness never binds or enables any game feature consumer.
final class CoreSetRuntimeCoordinator {
    static let userCancelledLaunchReason = "启动已取消，正在退出 HUD"
    static let sceneEndedLaunchReason = "窗口会话已结束，启动已取消"
    private static var retained: [UUID: CoreSetRuntimeCoordinator] = [:]
    private static var terminationWaiters: [() -> Void] = []
    private static var terminationPollScheduled = false
    private let identity = UUID()
    private weak var scene: UIWindowScene?
    private weak var launcher: CoreSetLauncherViewController?
    private let menu = CoreSetMenuViewController()
    private let host = CoreSetHUDHost(hostingAdapter: nil)
    private let metalAdapter = CoreSetMetalRenderAdapter()
    private var remoteHostingAdapter: CoreSetRemoteHostingAdapter?
    private var localHostingAdapter: CoreSetLocalHostingAdapter?
    private var consumer: CoreSetLocalHostConsumer!
    private var playerConsumer: CoreSetPlayerConsumer?
    private var materialConsumer: CoreSetMaterialConsumer?
    private var radarConsumer: CoreSetRadarConsumer?
    private var adjustmentConsumer: CoreSetAdjustmentConsumer?
    private var frameRateConsumer: CoreSetFrameRateConsumer?
    private var aimConsumer: CoreSetAimConsumer?
    private var aimDisplayConsumer: CoreSetAimDisplayConsumer?
    private var recoilConsumer: CoreSetRecoilConsumer?
    private let performanceSampler = CoreSetPerformanceSampler()
    private let homeTelemetry = CoreSetHomeTelemetrySource()
    private var homeReferenceObservationProvider: CoreSetHomeReferenceObservationProvider?
    private var observationTimer: DispatchSourceTimer?
    private let performanceQueue = DispatchQueue(label: "coreset.local.performance", qos: .utility)
    private var performanceTimer: DispatchSourceTimer?
    private var performanceEpoch = UUID()
    private var stopping = false
    private var stopReceiptsPending = false
    private var stopChannelsConfirmed = false
    private var stopWindowsConfirmed = false
    private var submittedGeneration: UInt64?
    private var submittedCanvasSize: CGSize?
    private var aimSuspendedForHost = false
    private var activateAfterAimStop = false
    private var gameLaunchEpoch: UInt64 = 0
    private var gameLaunchPending = false
    private var pendingLaunchCompletion: ((String?) -> Void)?
    private var returnToLocalPending = false
    private var exitHUDRestorationPending = false
    private var remoteCleanupFailed = false
    private var gameLaunchStatus: String?
    private var kernelOffsetsRunning = false
    private let homeActionProducerEpoch = UUID()
    private var homeActionRequests: [CoreSetHomeProbePoint: UUID] = [:]
    private var homeActionSequences: [CoreSetHomeProbePoint: UInt64] = [:]
    private let frameComposer = CoreSetFrameComposer()
    var localFrameDidConsume: ((CoreSetLocalFrameReceipt) -> Void)?
    private(set) var lastStopResult: CoreSetHUDStopResult?
    // Read-only snapshot, not a second mutable configuration store.
    var featureState: CoreSetFeatureState { menu.featureState }
    @discardableResult
    func recordHomeProducerProbeEvent(_ event: CoreSetHomeProducerProbeEvent) -> Bool {
        precondition(Thread.isMainThread)
        return homeTelemetry.recordProducerProbeEvent(event)
    }
    @discardableResult
    private func recordHomeAction(_ point: CoreSetHomeProbePoint, phase: CoreSetHomeProbePhase,
                                  status: Int?, errorCode: Int? = nil) -> UUID? {
        precondition(Thread.isMainThread)
        let request: UUID
        let sequence: UInt64
        if phase == .requested {
            request = UUID(); sequence = 1
            homeActionRequests[point] = request; homeActionSequences[point] = sequence
        } else {
            guard let active = homeActionRequests[point] else { return nil }
            request = active
            let old = homeActionSequences[point] ?? 0
            sequence = old == UInt64.max ? 1 : old + 1
            homeActionSequences[point] = sequence
        }
        let accepted = homeTelemetry.recordProducerProbeEvent(CoreSetHomeProducerProbeEvent(
            point: point, producerEpoch: homeActionProducerEpoch, requestID: request,
            sequence: sequence, observedAt: Date(), phase: phase, requestedOption: nil,
            observedStatus: status, nativeGeneration: nil,
            inFlight: phase == .requested || phase == .running,
            ready: phase == .completed, completedCount: nil, totalCount: nil,
            errorCode: errorCode))
        if !accepted { return nil }
        if [.completed, .failed, .cancelled, .stopped].contains(phase) {
            homeActionRequests.removeValue(forKey: point)
            homeActionSequences.removeValue(forKey: point)
        }
        return request
    }

    private func performHomeAction(_ point: CoreSetHomeProbePoint,
                                   completion: @escaping (String?) -> Void) {
        precondition(Thread.isMainThread)
        guard !stopping else { completion("HUD 正在停止"); return }
        switch point {
        case .kernelAction: performHomeKernelAction(completion: completion)
        case .informationAction: performHomeInformationAction(completion: completion)
        default: completion("该主页点不是动作入口")
        }
    }

    private func performHomeKernelAction(completion: @escaping (String?) -> Void) {
        let manager = laramgr.shared
        guard !manager.dsrunning else { completion("内核环境正在初始化"); return }
        guard recordHomeAction(.kernelAction, phase: .requested, status: 0) != nil,
              recordHomeAction(.kernelAction, phase: .running, status: 1) != nil else {
            completion("内核利用动作回执初始化失败"); return
        }
        if !manager.dsready && !ds_is_ready() { init_offsets(); offsets_init() }
        manager.run { [weak self] ready in
            guard let self, !self.stopping else { completion("HUD 已停止"); return }
            let phase: CoreSetHomeProbePhase = ready ? .completed : .failed
            _ = self.recordHomeAction(.kernelAction, phase: phase,
                                      status: ready ? 2 : 3, errorCode: ready ? nil : -1)
            self.refreshHomeObservation()
            completion(ready ? nil : "内核环境初始化失败")
        }
    }

    private func performHomeInformationAction(completion: @escaping (String?) -> Void) {
        let manager = laramgr.shared
        guard manager.dsready || ds_is_ready() else {
            completion("请先完成内核利用"); return
        }
        guard !kernelOffsetsRunning else { completion("当前设备信息正在获取"); return }
        guard recordHomeAction(.informationAction, phase: .requested, status: 0) != nil,
              recordHomeAction(.informationAction, phase: .running, status: 1) != nil else {
            completion("获取信息动作回执初始化失败"); return
        }
        if manager.hasOffsets {
            CoreSetKernelInformationOwner.shared.publishCachedValidation()
            _ = recordHomeAction(.informationAction, phase: .completed, status: 2)
            refreshHomeObservation(); completion(nil); return
        }
        kernelOffsetsRunning = true
        CoreSetKernelInformationOwner.shared.beginResolve()
        refreshHomeObservation()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fetched = fetchkcache()
            if fetched { CoreSetKernelInformationOwner.shared.didResolveArtifact() }
            else { CoreSetKernelInformationOwner.shared.failValidation("kernelcache 获取失败") }
            let loaded = fetched && dlkcache()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopping else { completion("HUD 已停止"); return }
                self.kernelOffsetsRunning = false
                manager.hasOffsets = loaded
                if loaded { CoreSetKernelInformationOwner.shared.completeValidation() }
                else if fetched { CoreSetKernelInformationOwner.shared.failValidation("本机内核偏移验证失败") }
                _ = self.recordHomeAction(.informationAction,
                    phase: loaded ? .completed : .failed, status: loaded ? 2 : 3,
                    errorCode: loaded ? nil : -1)
                self.refreshHomeObservation()
                completion(loaded ? nil : (fetched ? "本机内核偏移验证失败" : "kernelcache 获取失败"))
            }
        }
    }
    func bindHomeReferenceObservationProvider(_ provider: CoreSetHomeReferenceObservationProvider) {
        precondition(Thread.isMainThread)
        guard !stopping else { return }
        homeReferenceObservationProvider = provider
        homeTelemetry.bindReferenceObservationProvider(provider)
        publishStatus()
    }
    func invalidateReadFrameObservation(_ capability: CoreSetCapability, reason: String) {
        precondition(Thread.isMainThread)
        menu.invalidateReadFrameObservation(capability: capability, reason: reason)
    }
    var playerCanvas: (generation: UInt64, size: CGSize)? {
        guard host.localSurfacesReady else { return nil }
        let size = host.logicalCanvasSize
        return size.width > 0 && size.height > 0 ? (host.renderGeneration, size) : nil
    }
    var playerStyleReady: Bool { playerConsumer?.availability == .ready }
    var materialStyleReady: Bool { materialConsumer?.availability == .ready }
    var frameRateObservation: CoreSetFrameRateObservation? {
        precondition(Thread.isMainThread)
        guard host.renderFPSControlReady, host.activeBackend == CoreSetHUDBackendMetal else { return nil }
        let generation = host.generation
        let observed = host.observedRenderFPS()
        guard host.generation == generation, host.renderFPSControlReady,
              (30...144).contains(observed) else { return nil }
        return CoreSetFrameRateObservation(hostGeneration: generation, preferredFramesPerSecond: observed)
    }
    var frameRateReady: Bool { frameRateObservation != nil }
    var presentedFrameObservation: CoreSetPresentedFrameObservation? {
        precondition(Thread.isMainThread)
        let generation = host.generation, renderGeneration = host.renderGeneration
        let sample = host.observedPresentationCadence()
        guard sample.valid, host.localSurfacesReady,
              host.generation == generation, host.renderGeneration == renderGeneration else { return nil }
        return CoreSetPresentedFrameObservation(hostGeneration: generation, renderGeneration: renderGeneration,
            adapterEpoch: sample.adapterEpoch, sampleCount: sample.sampleCount, framesPerSecond: sample.framesPerSecond,
            firstPresentedTime: sample.firstPresentedTime, lastPresentedTime: sample.lastPresentedTime,
            observedHostTime: sample.observedHostTime)
    }
    func invalidateFrameRateObservation(reason: String) {
        precondition(Thread.isMainThread)
        menu.invalidateFrameRateObservation(reason: reason)
    }
    func applyFrameRate(_ requested: Int) -> Bool {
        precondition(Thread.isMainThread)
        guard host.renderFPSControlReady else { return false }
        let generation = host.generation
        var observed = 0
        return host.applyRenderFPS(requested, observed: &observed) &&
            host.generation == generation && observed == requested &&
            host.observedRenderFPS() == requested
    }
    func restoreFrameRate() -> Bool {
        precondition(Thread.isMainThread)
        return host.restoreRenderFPS()
    }
    func refreshPlayerAvailability() {
        menu.refreshConsumerAvailability()
        if let availability = aimConsumer?.availability {
            switch availability {
            case .unavailable(let reason): menu.updateBasicAimStatus(reason)
            case .ready: menu.updateBasicAimStatus("基础自瞄消费端已就绪")
            }
        } else {
            menu.updateBasicAimStatus("基础自瞄未绑定")
        }
    }
    func invalidateAimDisplayObservation() {
        precondition(Thread.isMainThread)
        aimDisplayConsumer?.invalidateFrame()
        menu.invalidateLocalAimDisplayAfterHostReset()
        menu.refreshConsumerAvailability()
    }

    init(scene: UIWindowScene, launcher: CoreSetLauncherViewController) {
        self.scene = scene
        self.launcher = launcher
        // The host retains this generic renderer; availability is still
        // decided by an attached drawable and observed Metal scheduler.
        _ = host.installLocalMetalConsumer(metalAdapter)
        host.contentOwnsLayout = true
        host.contentHitRegions = { [weak menu = self.menu] in menu?.localHostHitRegions ?? [] }
        consumer = CoreSetLocalHostConsumer(host: host)
        _ = menu.bindMenuHostConsumer(consumer)
        playerConsumer = CoreSetPlayerConsumer(coordinator: self)
        if let playerConsumer { _ = menu.bindGameConsumer(playerConsumer, to: \.player) }
        materialConsumer = CoreSetMaterialConsumer(coordinator: self)
        if let materialConsumer { _ = menu.bindGameConsumer(materialConsumer, to: \.materials) }
        adjustmentConsumer = CoreSetAdjustmentConsumer(coordinator: self)
        if let adjustmentConsumer { _ = menu.bindGameConsumer(adjustmentConsumer, to: \.adjustments) }
        frameRateConsumer = CoreSetFrameRateConsumer(coordinator: self)
        if let frameRateConsumer { _ = menu.bindGameConsumer(frameRateConsumer, to: \.frameRate) }
        radarConsumer = CoreSetRadarConsumer(coordinator: self)
        if let radarConsumer { _ = menu.bindGameConsumer(radarConsumer, to: \.radar) }
        aimConsumer = CoreSetAimConsumer(coordinator: self)
        if let aimConsumer { _ = menu.bindGameConsumer(aimConsumer, to: \.aim) }
        aimDisplayConsumer = CoreSetAimDisplayConsumer(coordinator: self)
        if let aimDisplayConsumer { _ = menu.bindGameConsumer(aimDisplayConsumer, to: \.aimDisplay) }
        if let aimConsumer { recoilConsumer = CoreSetRecoilConsumer(actionConsumer: aimConsumer) }
        if let recoilConsumer { _ = menu.bindGameConsumer(recoilConsumer, to: \.recoil) }
        let homeProducer = CoreSetHomeRuntimeProducer(manager: .shared)
        homeReferenceObservationProvider = homeProducer
        homeTelemetry.bindReferenceObservationProvider(homeProducer)
        host.stateDidChange = { [weak self] in self?.hostChanged() }
        host.frameDidConsume = { [weak self] frame, accepted, _ in
            guard let self, let receipt = self.frameComposer.consume(frame, accepted: accepted) else { return }
            self.playerConsumer?.consumed(receipt)
            self.materialConsumer?.consumed(receipt)
            self.radarConsumer?.consumed(receipt)
            self.adjustmentConsumer?.consumed(receipt)
            self.aimDisplayConsumer?.consumed(receipt)
            self.localFrameDidConsume?(receipt)
        }
        host.panelVisibilityRequested = { [weak self] visible in self?.requestVisibility(visible) }
        host.hostingInvalidated = { [weak self] in
            guard let self, !self.stopping else { return }
            _ = self.stop()
        }
        menu.onClose = { [weak self] in self?.publishStatus() }
        menu.onExitHUD = { [weak self] in self?.exitHostedHUD() }
        menu.onHomeProbeRefusal = { [weak self] point, option in
            self?.homeTelemetry.recordRefusedControl(point, option: option)
        }
        menu.onHomeAction = { [weak self] point, completion in
            guard let self else { completion("主页动作 owner 已释放"); return }
            self.performHomeAction(point, completion: completion)
        }
        Self.retained[identity] = self
        startPerformanceSampling()
        let observationTimer = DispatchSource.makeTimerSource(queue: .main)
        observationTimer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500), leeway: .milliseconds(100))
        observationTimer.setEventHandler { [weak self] in
            guard let self, !self.stopping else { return }
            self.refreshPeriodicObservations() // Read-only refresh; no host apply/readback or target action is retried.
        }
        self.observationTimer = observationTimer; observationTimer.resume()
    }

    private func startPerformanceSampling() {
        let epoch = performanceEpoch
        let timer = DispatchSource.makeTimerSource(queue: performanceQueue)
        timer.schedule(deadline: .now() + .milliseconds(500),
                       repeating: .milliseconds(1500), leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let sample = self.performanceSampler.sample()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopping, self.performanceEpoch == epoch else { return }
                self.menu.updatePerformanceObservation(sample)
            }
        }
        performanceTimer = timer
        timer.resume()
    }

    func activate() {
        guard !stopping, let scene else { return }
        if returnToLocalPending { return }
        if aimSuspendedForHost {
            guard menu.resumeActionConsumers() else {
                activateAfterAimStop = true
                publishStatus()
                return
            }
            aimSuspendedForHost = false
        }
        activateAfterAimStop = false
        if (remoteHostingAdapter != nil || localHostingAdapter != nil),
           host.localSurfacesReady, !gameLaunchPending {
            // Keep WZ's registered source contexts across app foregrounding.
            host.setApplicationActive(true)
            hostChanged()
            return
        }
        if !host.localSurfacesReady {
            if remoteHostingAdapter != nil || localHostingAdapter != nil {
                guard !host.cleanupPending, host.installRemoteHostingAdapter(nil) else {
                    publishStatus(); return
                }
                remoteHostingAdapter = nil
                localHostingAdapter = nil
            }
            if !host.startLocal(in: scene, menuController: menu) {
                publishStatus(); return
            }
            // Loads the existing, verified local palette before observing it.
            menu.requestMenuVisibility(false) { [weak self] _ in self?.publishStatus() }
        }
        host.setApplicationActive(true)
        hostChanged()
    }

    // WZ's local SBS tier is attempted first; SpringBoard mirrors are the
    // fallback. Both source contexts are checked before opening the game.
    func launchGame(completion: @escaping (String?) -> Void) {
        precondition(Thread.isMainThread)
        guard !stopping, let scene, scene.activationState == .foregroundActive else {
            completion("本应用窗口未处于前台，无法准备游戏内悬浮窗"); return
        }
        guard !gameLaunchPending else { completion("游戏内悬浮窗正在准备中"); return }
        guard !returnToLocalPending else { completion("窗口正在清理，暂不能重新启动"); return }
        guard !exitHUDRestorationPending else {
            completion("HUD 退出后的功能恢复未确认，已停止再次启动"); return
        }
        guard !remoteCleanupFailed else {
            completion("远端清理未确认，请先点“重试清理”"); return
        }
        let support = axDeviceSupportStatus()
        guard support.isSupported else {
            completion("当前设备不支持跨应用悬浮窗：\(support.reason ?? support.identifier)"); return
        }
        gameLaunchPending = true
        gameLaunchEpoch &+= 1
        pendingLaunchCompletion = completion
        let epoch = gameLaunchEpoch
        gameLaunchStatus = "正在准备跨应用悬浮窗"
        publishStatus()

        if (remoteHostingAdapter != nil || localHostingAdapter != nil), host.localSurfacesReady {
            host.confirmHostedReadbackAsync { [weak self] observed in
                guard let self, self.gameLaunchCurrent(epoch) else { return }
                if observed { self.showHostedMenuAndOpenGame(epoch: epoch, completion: completion) }
                else {
                    self.rollbackGameLaunch(epoch: epoch, error: "跨应用双窗口复核失败", completion: completion)
                }
            }
            return
        }
        guard !host.cleanupPending else {
            finishGameLaunch(epoch: epoch, error: "上次窗口清理尚未确认，请重新打开应用", completion: completion)
            return
        }
        let manager = laramgr.shared
        guard !manager.dsrunning else {
            finishGameLaunch(epoch: epoch, error: "内核环境正在初始化，请稍后重试", completion: completion)
            return
        }
        guard !kernelOffsetsRunning else {
            finishGameLaunch(epoch: epoch, error: "当前设备内核偏移仍在解析，请稍后重试", completion: completion)
            return
        }
        if !manager.dsready {
            init_offsets()
            offsets_init()
        }
        manager.run { [weak self] ready in
            guard let self, self.gameLaunchCurrent(epoch) else { return }
            guard ready else {
                self.finishGameLaunch(epoch: epoch, error: "内核环境初始化失败，无法建立跨应用悬浮窗", completion: completion)
                return
            }
            self.prepareKernelOffsets(epoch: epoch, completion: completion)
        }
    }

    private func prepareKernelOffsets(epoch: UInt64, completion: @escaping (String?) -> Void) {
        guard gameLaunchCurrent(epoch) else { return }
        guard let scene, scene.activationState == .foregroundActive else {
            finishGameLaunch(epoch: epoch, error: "场景已失活，已取消当前设备内核偏移解析", completion: completion)
            return
        }
        let manager = laramgr.shared
        if manager.hasOffsets {
            CoreSetKernelInformationOwner.shared.publishCachedValidation()
            prepareLocalHosting(epoch: epoch, completion: completion)
            return
        }
        kernelOffsetsRunning = true
        CoreSetKernelInformationOwner.shared.beginResolve()
        gameLaunchStatus = "正在获取并解析当前设备内核偏移"
        NSLog("Core-SET: game launch epoch=%llu stage=kernel-offsets start", epoch)
        publishStatus()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fetched = fetchkcache()
            if fetched { CoreSetKernelInformationOwner.shared.didResolveArtifact() }
            else { CoreSetKernelInformationOwner.shared.failValidation("kernelcache 获取失败") }
            let loaded = fetched && dlkcache()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.kernelOffsetsRunning = false
                manager.hasOffsets = loaded
                if loaded { CoreSetKernelInformationOwner.shared.completeValidation() }
                else if fetched { CoreSetKernelInformationOwner.shared.failValidation("本机内核偏移验证失败") }
                NSLog("Core-SET: game launch epoch=%llu stage=kernel-offsets fetched=%d resolved=%d",
                      epoch, fetched ? 1 : 0, loaded ? 1 : 0)
                guard self.gameLaunchCurrent(epoch) else { return }
                guard loaded else {
                    self.finishGameLaunch(epoch: epoch,
                        error: fetched ? "当前设备内核偏移解析失败" : "当前设备 kernelcache 获取失败",
                        completion: completion)
                    return
                }
                self.prepareLocalHosting(epoch: epoch, completion: completion)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(180)) { [weak self] in
            guard let self, self.gameLaunchCurrent(epoch), self.kernelOffsetsRunning else { return }
            self.finishGameLaunch(epoch: epoch,
                error: "当前设备内核偏移解析超时；后台任务结束前请勿重试", completion: completion)
        }
    }

    private func gameLaunchCurrent(_ epoch: UInt64) -> Bool {
        !stopping && gameLaunchPending && gameLaunchEpoch == epoch
    }

    // Logs cached state only. Explicit async launch gates own remote readback.
    private func recordHostingDiagnostic(_ stage: String, epoch: UInt64, remoteDecision: Int = -1) {
        NSLog("Core-SET: hosting stage=%@ epoch=%llu remoteDecision=%d sceneState=%ld appState=%ld host={%@} remote={%@}",
              stage, epoch, remoteDecision, scene?.activationState.rawValue ?? -1,
              UIApplication.shared.applicationState.rawValue,
              host.hostingDiagnosticSnapshot(),
              (localHostingAdapter?.hostingDiagnosticSnapshot() ??
               remoteHostingAdapter?.hostingDiagnosticSnapshot()) ?? "adapter-not-installed")
    }

    func recordSceneLifecycle(_ event: String, scene eventScene: UIScene) {
        precondition(Thread.isMainThread)
        NSLog("Core-SET: scene event=%@ state=%ld", event, eventScene.activationState.rawValue)
        recordHostingDiagnostic("scene-\(event)", epoch: gameLaunchEpoch)
    }

    private func finishGameLaunch(epoch: UInt64, error: String?, completion: @escaping (String?) -> Void) {
        guard gameLaunchCurrent(epoch) else { return }
        gameLaunchPending = false
        let finishedCompletion = pendingLaunchCompletion
        pendingLaunchCompletion = nil
        gameLaunchStatus = error ?? "跨应用画面已回读；触控待真机验收"
        NSLog("Core-SET: game launch host epoch=%llu result=%@", epoch, gameLaunchStatus ?? "unknown")
        if let scene, scene.activationState != .foregroundActive {
            host.setApplicationActive(false)
        } else if error != nil, aimSuspendedForHost, host.localSurfacesReady,
                  menu.resumeActionConsumers() {
            aimSuspendedForHost = false
        }
        publishStatus()
        (finishedCompletion ?? completion)(error)
    }

    private func prepareLocalHosting(epoch: UInt64, completion: @escaping (String?) -> Void) {
        guard gameLaunchCurrent(epoch), scene?.activationState == .foregroundActive else { return }
        let adapter = CoreSetLocalHostingAdapter()
        // Even when the SBS class is absent, build the dual system source once.
        // A failed local registration then hands those exact contexts to the
        // SpringBoard adapter without a stop/recreate cycle.
        if !adapter.available {
            NSLog("Core-SET: hosting mode=local-controller class-unavailable; preserve source for fallback")
        }
        installHostedWindows(adapter: adapter, localMode: true, epoch: epoch,
                             completion: completion)
    }

    private func fallbackToSpringBoardAfterLocalFailure(epoch: UInt64,
                                                       completion: @escaping (String?) -> Void) {
        guard gameLaunchCurrent(epoch) else { return }
        NSLog("Core-SET: hosting mode=local-controller failed; trying SpringBoard with existing contexts")
        prepareSpringBoardHosting(epoch: epoch, completion: completion)
    }

    private func prepareSpringBoardHosting(epoch: UInt64, completion: @escaping (String?) -> Void) {
        guard gameLaunchCurrent(epoch), let scene, scene.activationState == .foregroundActive else {
            finishGameLaunch(epoch: epoch, error: "场景已失活，已取消跨应用托管", completion: completion)
            return
        }
        let manager = laramgr.shared
        if manager.rcready, let process = manager.sbProc {
            rebuildHostedWindows(process: process, epoch: epoch, completion: completion)
            return
        }
        guard !manager.rcrunning else {
            finishGameLaunch(epoch: epoch, error: "SpringBoard 远程会话正在初始化，请稍后重试", completion: completion)
            return
        }
        gameLaunchStatus = "正在初始化 SpringBoard 远程会话"
        NSLog("Core-SET: game launch epoch=%llu stage=springboard-rc start", epoch)
        publishStatus()
        manager.rcinit(process: "SpringBoard", migbypass: false) { [weak self] success in
            guard let self, self.gameLaunchCurrent(epoch) else { return }
            NSLog("Core-SET: game launch epoch=%llu stage=springboard-rc ready=%d",
                  epoch, success ? 1 : 0)
            guard success, let process = manager.sbProc else {
                let detail = manager.rcLastError ?? "远程调用初始化失败"
                self.finishGameLaunch(epoch: epoch, error: "SpringBoard 托管不可用：\(detail)", completion: completion)
                return
            }
            self.rebuildHostedWindows(process: process, epoch: epoch, completion: completion)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(180)) { [weak self] in
            guard let self, self.gameLaunchCurrent(epoch), manager.rcrunning else { return }
            self.finishGameLaunch(epoch: epoch,
                error: "SpringBoard 远程会话初始化超时；后台任务结束前请勿重试", completion: completion)
        }
    }

    private func rebuildHostedWindows(process: RemoteCall, epoch: UInt64,
                                      completion: @escaping (String?) -> Void) {
        guard gameLaunchCurrent(epoch), let scene, scene.activationState == .foregroundActive else {
            finishGameLaunch(epoch: epoch, error: "场景已失活，已取消跨应用托管", completion: completion)
            return
        }
        let adapter = CoreSetRemoteHostingAdapter(remoteCall: process)
        if let reason = adapter.sessionIdentityFailureReason {
            let detail = "SpringBoard 会话身份未通过核对：\(reason)"
            globallogger.log("Core-SET: \(detail)")
            finishGameLaunch(epoch: epoch, error: detail, completion: completion)
            return
        }
        if localHostingAdapter != nil && host.localSurfacesReady {
            host.whenHostedReadbackIdle { [weak self] in
                guard let self, self.gameLaunchCurrent(epoch) else { return }
                self.host.transition(toRemoteHostingAdapter: adapter) { [weak self] registered in
                    guard let self, self.gameLaunchCurrent(epoch) else { return }
                    guard registered else {
                        self.rollbackGameLaunch(epoch: epoch,
                            error: "本地双窗口转 SpringBoard 注册未确认", completion: completion)
                        return
                    }
                    self.localHostingAdapter = nil
                    self.remoteHostingAdapter = adapter
                    self.remoteCleanupFailed = false
                    NSLog("Core-SET: hosting mode=springboard stage=same-source-context registered=1")
                    self.verifyHostedWindows(localMode: false, epoch: epoch, completion: completion)
                }
            }
        } else {
            installHostedWindows(adapter: adapter, localMode: false,
                                 epoch: epoch, completion: completion)
        }
    }

    private func hostedInstallFailed(localMode: Bool, epoch: UInt64, error: String,
                                     completion: @escaping (String?) -> Void) {
        if localMode {
            NSLog("Core-SET: hosting mode=local-controller failed reason=%@", error)
            fallbackToSpringBoardAfterLocalFailure(epoch: epoch, completion: completion)
        } else {
            rollbackGameLaunch(epoch: epoch, error: error, completion: completion)
        }
    }

    private func installHostedWindows(adapter: CoreSetHUDHostingAdapter, localMode: Bool,
                                       epoch: UInt64, completion: @escaping (String?) -> Void) {
        aimSuspendedForHost = true
        menu.suspendActionConsumers { [weak self] confirmed in
            guard let self, self.gameLaunchCurrent(epoch) else { return }
            guard confirmed, self.scene?.activationState == .foregroundActive,
                  self.host.localSurfacesReady else {
                self.finishGameLaunch(epoch: epoch,
                    error: "目标动作停止或本地源窗口状态未确认", completion: completion)
                return
            }
            // WZ retains the same menu/draw source windows and MenuVC. Stopping
            // the menu host consumer here would also stop those windows.
            if localMode { self.localHostingAdapter = adapter as? CoreSetLocalHostingAdapter }
            else { self.remoteHostingAdapter = adapter as? CoreSetRemoteHostingAdapter }
            self.host.attach(adapter) { [weak self] registered in
                guard let self, self.gameLaunchCurrent(epoch) else { return }
                guard registered else {
                    self.hostedInstallFailed(localMode: localMode, epoch: epoch,
                        error: "双窗口注册或读回失败", completion: completion)
                    return
                }
                if localMode { self.localHostingAdapter = adapter as? CoreSetLocalHostingAdapter }
                else { self.remoteHostingAdapter = adapter as? CoreSetRemoteHostingAdapter }
                self.remoteCleanupFailed = false
                self.verifyHostedWindows(localMode: localMode, epoch: epoch,
                                         completion: completion)
            }
        }
    }

    private func verifyHostedWindows(localMode: Bool, epoch: UInt64,
                                     completion: @escaping (String?) -> Void) {
        host.setApplicationActive(true)
        hostChanged()
        gameLaunchStatus = localMode
            ? "本地 SBS 双窗口已注册，正在复核" : "SpringBoard 双窗口已注册，正在复核"
        publishStatus()
        host.confirmHostedReadbackAsync { [weak self] firstObserved in
            guard let self, self.gameLaunchCurrent(epoch) else { return }
            guard firstObserved else {
                self.hostedInstallFailed(localMode: localMode, epoch: epoch,
                    error: "双窗口初次读回失败", completion: completion)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1200)) { [weak self] in
                guard let self, self.gameLaunchCurrent(epoch) else { return }
                self.host.confirmHostedReadbackAsync { [weak self] observed in
                    guard let self, self.gameLaunchCurrent(epoch) else { return }
                    NSLog("Core-SET: game launch epoch=%llu stage=dual-host mode=%@ observed=%d",
                          epoch, localMode ? "local-controller" : "springboard", observed ? 1 : 0)
                    guard observed else {
                        self.hostedInstallFailed(localMode: localMode, epoch: epoch,
                            error: "双窗口延迟读回失败", completion: completion)
                        return
                    }
                    self.menu.setHostedExitAvailable(true)
                    self.showHostedMenuAndOpenGame(epoch: epoch, completion: completion)
                }
            }
        }
    }

    private func showHostedMenuAndOpenGame(epoch: UInt64, completion: @escaping (String?) -> Void) {
        guard gameLaunchCurrent(epoch), host.hostedRegistrationReceipt else {
            rollbackGameLaunch(epoch: epoch, error: "跨应用双窗口未通过读回", completion: completion)
            return
        }
        // WZ expands its already hosted menu before opening the target app.
        menu.requestMenuVisibility(true) { [weak self] confirmed in
            guard let self, self.gameLaunchCurrent(epoch) else { return }
            let panelVisible = self.host.panelVisible
            let hosted = self.host.hostedRegistrationReceipt
            NSLog("Core-SET: game launch epoch=%llu stage=menu-visible confirmed=%d panel=%d hosted=%d",
                  epoch, confirmed ? 1 : 0, panelVisible ? 1 : 0, hosted ? 1 : 0)
            guard confirmed, panelVisible, hosted else {
                self.rollbackGameLaunch(epoch: epoch, error: "游戏内菜单显示未确认", completion: completion)
                return
            }
            guard !self.aimSuspendedForHost || self.menu.resumeActionConsumers() else {
                self.rollbackGameLaunch(epoch: epoch, error: "目标动作恢复未确认，已停止游戏启动", completion: completion)
                return
            }
            self.aimSuspendedForHost = false
            guard let scene = self.scene, scene.activationState == .foregroundActive else {
                self.rollbackGameLaunch(epoch: epoch, error: "场景已失活，未发起游戏启动", completion: completion)
                return
            }
            // WZ records the HID monitor result but does not make it a launch
            // prerequisite. A missing monitor remains visible in diagnostics;
            // the dual-window and game-open receipts still decide this chain.
            let inputArmed = self.host.armHostedInput()
            NSLog("Core-SET: game launch epoch=%llu stage=input-monitor armed=%d",
                  epoch, inputArmed ? 1 : 0)
            NSLog("Core-SET: game launch epoch=%llu stage=open-url targetBundle=%@",
                  epoch, CoreSetGameTarget.bundleIdentifier)
            CoreSetGameTarget.openApplication { [weak self] result in
                guard let self, self.gameLaunchCurrent(epoch) else { return }
                switch result {
                case .opened:
                    self.host.confirmHostedReadbackAsync { [weak self] observed in
                        guard let self, self.gameLaunchCurrent(epoch) else { return }
                        self.recordHostingDiagnostic("open-url-callback-opened", epoch: epoch,
                                                     remoteDecision: observed ? 1 : 0)
                        if observed {
                            self.finishGameLaunch(epoch: epoch, error: nil, completion: completion)
                        } else {
                            self.rollbackGameLaunch(epoch: epoch,
                                error: "游戏已打开，但跨应用窗口回读失效", completion: completion)
                        }
                    }
                case .unavailable:
                    self.recordHostingDiagnostic("open-url-callback-unavailable", epoch: epoch)
                    self.rollbackGameLaunch(epoch: epoch, error: "未检测到可打开的和平精英，跨应用窗口已请求清理", completion: completion)
                case .failed:
                    self.recordHostingDiagnostic("open-url-callback-failed", epoch: epoch)
                    self.rollbackGameLaunch(epoch: epoch, error: "系统未能打开和平精英，跨应用窗口已请求清理", completion: completion)
                }
            }
        }
    }

    private func rollbackGameLaunch(epoch: UInt64, error: String,
                                    completion: @escaping (String?) -> Void) {
        host.whenHostedReadbackIdle { [weak self] in
            guard let self, self.gameLaunchCurrent(epoch) else { return }
            self.host.stopHostedAsync { [weak self] result in
                guard let self, self.gameLaunchCurrent(epoch) else { return }
                guard result.complete.boolValue, !self.host.cleanupPending else {
                    self.remoteCleanupFailed = true
                    self.finishGameLaunch(epoch: epoch,
                        error: "\(error)；远端清理回执未确认，已保留句柄", completion: completion)
                    return
                }
                self.remoteHostingAdapter = nil
                self.localHostingAdapter = nil
                self.menu.setHostedExitAvailable(false)
                if self.host.installRemoteHostingAdapter(nil), let scene = self.scene,
                   scene.activationState == .foregroundActive,
                   self.host.startLocal(in: scene, menuController: self.menu) {
                    self.host.setApplicationActive(true)
                    self.hostChanged()
                    self.menu.requestMenuVisibility(false) { [weak self] _ in self?.publishStatus() }
                }
                self.finishGameLaunch(epoch: epoch, error: error, completion: completion)
            }
        }
    }

    // The launcher button explicitly retries a failed remote cleanup once.
    // No background timer or lifecycle notification replays remote writes.
    func retryRemoteCleanup(completion: @escaping (String?) -> Void) {
        precondition(Thread.isMainThread)
        guard remoteCleanupFailed, !returnToLocalPending, !stopping,
              scene?.activationState == .foregroundActive else {
            completion("当前没有可重试的远端清理任务"); return
        }
        remoteCleanupFailed = false
        returnToLocalPending = true
        host.whenHostedReadbackIdle { [weak self] in
            guard let self else { return }
            self.host.stopHostedAsync { [weak self] result in
                guard let self else { return }
                self.returnToLocalPending = false
                guard !self.stopping else { return }
                guard result.complete.boolValue, !self.host.cleanupPending else {
                    self.remoteCleanupFailed = true
                    self.publishStatus()
                    completion("远端清理仍未确认，已保留句柄；不会自动重试")
                    return
                }
                self.remoteHostingAdapter = nil
                guard self.host.installRemoteHostingAdapter(nil), let scene = self.scene,
                      scene.activationState == .foregroundActive,
                      self.host.startLocal(in: scene, menuController: self.menu) else {
                    self.publishStatus()
                    completion("远端已清理，但本应用窗口恢复失败")
                    return
                }
                self.host.setApplicationActive(true)
                self.hostChanged()
                if self.exitHUDRestorationPending {
                    let resumed = self.menu.resumeGameConsumers() &&
                        self.menu.resumeMenuHostConsumer()
                    self.exitHUDRestorationPending = !resumed
                    self.menu.setHostedExitAvailable(false)
                }
                self.menu.requestMenuVisibility(false) { [weak self] _ in self?.publishStatus() }
                self.activate()
                completion(nil)
            }
        }
    }

    // The visible "退出 HUD" control must own actual stop receipts. Hiding the
    // panel alone leaves the source windows and remote mirror installed.
    private func exitHostedHUD() {
        precondition(Thread.isMainThread)
        guard !stopping, !returnToLocalPending,
              remoteHostingAdapter != nil || localHostingAdapter != nil else { return }
        returnToLocalPending = true
        if gameLaunchPending {
            // WZ cancels the current launch generation before HUD teardown.
            // Complete the launcher request exactly once; late open/readback
            // callbacks fail gameLaunchCurrent(epoch) and cannot republish.
            gameLaunchEpoch &+= 1
            gameLaunchPending = false
            let pendingCompletion = pendingLaunchCompletion
            pendingLaunchCompletion = nil
            gameLaunchStatus = Self.userCancelledLaunchReason
            pendingCompletion?(gameLaunchStatus)
        }
        exitHUDRestorationPending = true
        menu.setHostedExitAvailable(false)
        let group = DispatchGroup()
        var gameStopped = false
        var hostStopped = false
        group.enter()
        menu.suspendGameConsumers { confirmed in gameStopped = confirmed; group.leave() }
        group.enter()
        menu.suspendMenuHostConsumer { confirmed in hostStopped = confirmed; group.leave() }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.returnToLocalPending = false
            guard !self.stopping else { return }
            guard gameStopped, hostStopped, !self.host.cleanupPending,
                  self.host.installRemoteHostingAdapter(nil) else {
                self.remoteCleanupFailed = true
                self.gameLaunchStatus = "HUD 退出清理未确认"
                self.publishStatus()
                NSLog("Core-SET: hosted input stage=exit-hud cleanupConfirmed=0")
                return
            }
            self.remoteHostingAdapter = nil
            self.localHostingAdapter = nil
            let channelsResumed = self.menu.resumeGameConsumers() &&
                self.menu.resumeMenuHostConsumer()
            self.exitHUDRestorationPending = !channelsResumed
            self.aimSuspendedForHost = false
            self.activateAfterAimStop = false
            self.gameLaunchStatus = channelsResumed ? "HUD 已退出" : "HUD 功能恢复未确认"
            if self.scene?.activationState == .foregroundActive { self.activate() }
            self.publishStatus()
            NSLog("Core-SET: hosted input stage=exit-hud cleanupConfirmed=1 channelsResumed=%d",
                  channelsResumed ? 1 : 0)
        }
    }

    func deactivate() {
        guard !stopping, !aimSuspendedForHost else { return }
        aimSuspendedForHost = true
        menu.suspendActionConsumers { [weak self] confirmed in
            guard let self, !self.stopping else { return }
            if self.activateAfterAimStop, confirmed {
                self.activateAfterAimStop = false
                guard self.menu.resumeActionConsumers() else { self.publishStatus(); return }
                self.aimSuspendedForHost = false
                self.activate()
                return
            }
            self.host.setApplicationActive(false)
            self.recordHostingDiagnostic("deactivate-applied", epoch: self.gameLaunchEpoch)
            self.hostChanged()
        }
    }

    func toggleMenu() { requestVisibility(!host.panelVisible) }

    private func requestVisibility(_ visible: Bool) {
        guard !stopping else { publishStatus(); return }
        if !host.localSurfacesReady { activate() }
        guard host.localSurfacesReady else { publishStatus(); return }
        menu.refreshConsumerAvailability()
        menu.requestMenuVisibility(visible) { [weak self] _ in self?.publishStatus() }
    }

    private func hostChanged() {
        if let canvas = playerCanvas { menu.syncRadarCanvas(canvas.size) }
        let canvasSize = host.logicalCanvasSize
        if !stopping, host.localSurfacesReady,
           submittedGeneration != host.renderGeneration {
            if submittedGeneration != nil, !aimSuspendedForHost {
                aimSuspendedForHost = true
                menu.suspendActionConsumers { [weak self] confirmed in
                    guard let self, !self.stopping, confirmed else { return }
                    _ = self.menu.resumeActionConsumers()
                    self.aimSuspendedForHost = false
                    if self.activateAfterAimStop {
                        self.activateAfterAimStop = false
                        self.activate()
                        return
                    }
                    self.publishStatus()
                }
            }
            for expired in frameComposer.reset(to: host.renderGeneration) {
                aimDisplayConsumer?.consumed(expired)
                localFrameDidConsume?(expired)
            }
            aimDisplayConsumer?.invalidateFrame()
            menu.invalidateLocalAimDisplayAfterHostReset()
            // No game collector and no fabricated entities: exercise a real empty
            // CA frame. The host rejects stale generation/sequence on delivery.
            submittedGeneration = host.renderGeneration
            submittedCanvasSize = canvasSize
            if canvasSize.width > 0, canvasSize.height > 0 {
                host.submitFrame(CoreSetRenderFrame(generation: host.renderGeneration, sequence: 1,
                    canvasSize: canvasSize, commands: []))
            }
        } else if !stopping, host.localSurfacesReady,
                  submittedCanvasSize != canvasSize {
            for expired in frameComposer.invalidateGeometry() {
                aimDisplayConsumer?.consumed(expired)
                localFrameDidConsume?(expired)
            }
            aimDisplayConsumer?.invalidateFrame()
            menu.invalidateLocalAimDisplayAfterHostReset()
            submittedCanvasSize = canvasSize
        }
        menu.refreshConsumerAvailability()
        publishStatus()
    }

    // Returning true means queued for this local host generation only. The exact
    // consumption result is delivered through localFrameDidConsume.
    @discardableResult
    func submitLane(_ input: CoreSetLaneSubmission) -> Bool {
        precondition(Thread.isMainThread)
        guard !stopping, host.localSurfacesReady,
              let frame = frameComposer.makeFrame(input) else { return false }
        host.submitFrame(frame)
        return true
    }

    @discardableResult
    func clearLane(_ lane: CoreSetRenderLane, generation: UInt64, configRevision: UInt64,
                   snapshotID: UUID, requestToken: CoreSetRequestToken, canvasSize: CGSize) -> Bool {
        precondition(Thread.isMainThread)
        guard !stopping, host.localSurfacesReady,
              let frame = frameComposer.makeClearFrame(CoreSetLaneSubmission(lane: lane, hostGeneration: generation,
            configRevision: configRevision, snapshotID: snapshotID, requestToken: requestToken,
            canvasSize: canvasSize, commands: [])) else { return false }
        host.submitFrame(frame)
        return true
    }

    private func refreshHomeObservation() {
        let remoteHosted = host.hostedRegistrationReceipt
        let homeGeneration = host.generation
        let homeObservation = homeTelemetry.capture(
            hostReady: host.localSurfacesReady, panelVisible: host.panelVisible,
            cleanupPending: host.cleanupPending,
            remoteHosted: remoteHosted,
            hostGeneration: homeGeneration,
            floatingReady: host.floatingControlReady)
        menu.updateRuntimeObservations(homeObservation, expectedHostGeneration: host.generation)
    }

    private func refreshPeriodicObservations() {
        frameRateConsumer?.refreshSchedulerObservation()
        menu.updatePresentedFrameObservation(presentedFrameObservation)
        refreshHomeObservation()
    }

    private func publishStatus() {
        consumer.refreshObservation(isCurrent: menu.menuHostRequestIsCurrent,
                                    canInspect: menu.menuHostObservationMayBeRefreshed,
                                    invalidate: menu.invalidateMenuHostObservation)
        refreshPeriodicObservations()
        let local = host.localSurfacesReady ? "本应用悬浮可用" : "本应用悬浮未就绪"
        let renderer = host.activeBackend == CoreSetHUDBackendMetal ? "Metal" : "CA"
        let frame = host.lastConsumedSequence > 0 ? "\(renderer) 本地帧已消费" : "\(renderer) 本地帧未确认"
        // UI status is a structural registration receipt, never a live pixel
        // or touch claim. Launch and post-open gates call a real async readback.
        let remoteHosted = host.hostedRegistrationReceipt
        let hosting = remoteHosted ? "跨应用注册回执有效" : "跨应用 unavailable"
        let cleanup = host.cleanupPending ? " · 清理待确认" : ""
        let launch = gameLaunchStatus.map { " · \($0)" } ?? ""
        launcher?.updateRuntimePresentation(menuVisible: host.panelVisible,
            status: "\(local) · \(frame) · \(hosting)\(cleanup)\(launch)",
            cleanupRetryRequired: remoteCleanupFailed)
    }

    private func releaseStoppedOwnerIfReady() {
        guard stopping, !stopReceiptsPending, stopChannelsConfirmed,
              stopWindowsConfirmed, !host.cleanupPending else { return }
        host.stateDidChange = nil
        host.frameDidConsume = nil
        Self.retained.removeValue(forKey: identity)
    }

    private func stopAudioAfterSceneTeardownIfReady() {
        // A failed remote cleanup retains its owner for explicit retry. It
        // must not keep audio running once every scene has finished trying to
        // stop; an in-flight cleanup still gets time to return its receipt.
        guard Self.retained.values.allSatisfy({
            $0.stopping && !$0.stopReceiptsPending && !$0.host.hostedCleanupInFlight
        }) else { return }
        CoreSetBackgroundAudio.shared.stop()
    }

    // Local disarm/hide is immediate. Remote mirror cleanup is best-effort on
    // the adapter's serial worker; termination does not wait for its callback.
    @discardableResult
    func stop() -> CoreSetHUDStopResult {
        precondition(Thread.isMainThread)
        if stopping, let result = lastStopResult { return result }
        gameLaunchEpoch &+= 1
        gameLaunchPending = false
        let pendingCompletion = pendingLaunchCompletion
        pendingLaunchCompletion = nil
        stopping = true
        pendingCompletion?(Self.sceneEndedLaunchReason)
        performanceEpoch = UUID()
        performanceTimer?.cancel()
        performanceTimer = nil
        observationTimer?.cancel(); observationTimer = nil
        menu.onHomeAction = nil
        _ = homeTelemetry.stopObservations(); homeReferenceObservationProvider = nil
        menu.updatePresentedFrameObservation(nil)
        stopReceiptsPending = true
        stopChannelsConfirmed = false
        stopWindowsConfirmed = false
        for expired in frameComposer.reset(to: 0) {
            aimDisplayConsumer?.consumed(expired)
            localFrameDidConsume?(expired)
        }
        host.panelVisibilityRequested = nil
        host.hostingInvalidated = nil
        let result = host.stop()
        lastStopResult = result
        stopWindowsConfirmed = result.complete.boolValue
        if host.hostedCleanupInFlight {
            host.stopHostedAsync { [weak self] final in
                guard let self else { return }
                self.lastStopResult = final
                self.stopWindowsConfirmed = final.complete.boolValue
                self.releaseStoppedOwnerIfReady()
                self.stopAudioAfterSceneTeardownIfReady()
            }
        }
        let group = DispatchGroup()
        var channelsRestored = true
        group.enter()
        menu.suspendGameConsumers { restored in channelsRestored = channelsRestored && restored; group.leave() }
        group.enter()
        menu.suspendMenuHostConsumer { restored in channelsRestored = channelsRestored && restored; group.leave() }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.stopReceiptsPending = false
            let playerReadClean = self.playerConsumer?.shutdownReadSession() ?? true
            let materialReadClean = self.materialConsumer?.shutdownReadSession() ?? true
            let radarReadClean = self.radarConsumer?.shutdownReadSession() ?? true
            let previewReadClean = self.aimDisplayConsumer?.shutdownPreview() ?? true
            let aimWriteClean = self.aimConsumer?.shutdownWriteSession() ?? true
            let recoilWriteClean = self.recoilConsumer?.shutdownWriteSession() ?? true
            channelsRestored = channelsRestored && playerReadClean && materialReadClean && radarReadClean && previewReadClean && aimWriteClean && recoilWriteClean
            self.stopChannelsConfirmed = channelsRestored
            self.menu.refreshConsumerAvailability()
            self.publishStatus()
            self.releaseStoppedOwnerIfReady()
            self.stopAudioAfterSceneTeardownIfReady()
        }
        return result
    }

    private static func pollTerminationDrain() {
        precondition(Thread.isMainThread)
        let drained = retained.values.allSatisfy {
            $0.stopping && !$0.stopReceiptsPending && !$0.host.hostedCleanupInFlight
        }
        guard drained else {
            guard !terminationPollScheduled else { return }
            terminationPollScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) {
                terminationPollScheduled = false
                pollTerminationDrain()
            }
            return
        }
        terminationPollScheduled = false
        let waiters = terminationWaiters
        terminationWaiters.removeAll()
        NSLog("Core-SET: shutdown stage=window-channel-drain complete=1 owners=%lu",
              UInt(retained.count))
        waiters.forEach { $0() }
    }

    static func stopAllForTermination(completion: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        terminationWaiters.append(completion)
        for owner in Array(retained.values) {
            let result = owner.stop()
            if !result.complete.boolValue { NSLog("Core-SET: overlay cleanup remains unconfirmed") }
        }
        pollTerminationDrain()
    }
}

private final class CoreSetLocalHostConsumer: CoreSetFeatureConsumer {
    typealias State = CoreSetMenuHostSettings
    let capability = CoreSetCapability.hostWindow
    private let host: CoreSetHUDHost
    private var appliedGeneration: UInt64?
    private var appliedState: State?
    private var appliedToken: CoreSetRequestToken?
    init(host: CoreSetHUDHost) { self.host = host }
    var availability: CoreSetAvailability {
        guard host.localSurfacesReady else { return .unavailable(reason: "本应用窗口未就绪；跨应用 unavailable") }
        if let generation = appliedGeneration, let state = appliedState, !matches(state, generation: generation) {
            return .unavailable(reason: "Host palette generation/property observation no longer matches")
        }
        return .ready
    }

    // Same v1.7 palette bytes as the menu, indexed by the typed native enum.
    private func colors(for palette: CoreSetFloatingPalette) -> [UIColor] {
        palette.referenceColors.map { UIColor(red: CGFloat($0.red), green: CGFloat($0.green), blue: CGFloat($0.blue), alpha: 1) }
    }
    private func matches(_ state: State, generation: UInt64) -> Bool {
        guard host.generation == generation, host.floatingControlReady,
              host.panelVisible == state.menuVisible, let palette = state.floatingPalette else { return false }
        let expected = colors(for: palette), observed = host.observedFloatingColors
        return observed.count == expected.count && zip(observed, expected).allSatisfy { $0.0.isEqual($0.1) }
    }
    func refreshObservation(isCurrent: (CoreSetRequestToken) -> Bool,
                            canInspect: (CoreSetRequestToken) -> Bool, invalidate: (String) -> Void) {
        guard let generation = appliedGeneration, let state = appliedState, let token = appliedToken,
              canInspect(token), !matches(state, generation: generation) else { return }
        appliedGeneration = nil; appliedState = nil; appliedToken = nil
        if isCurrent(token) { invalidate("Host generation/floating geometry/gradient/menu visibility no longer matches its exact apply token") }
    }

    func apply(_ request: CoreSetApplyRequest<State>,
               completion: @escaping (CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void) {
        precondition(Thread.isMainThread)
        guard availability == .ready, let palette = request.desired.floatingPalette else {
            completion(request.token, .notApplied(reason: "本地宿主或颜色未就绪")); return
        }
        let generation = host.generation
        let colors = colors(for: palette)
        guard host.applyLocalMenu(visible: request.desired.menuVisible, colors: colors) else {
            completion(request.token, .failed(reason: "本地菜单设置失败")); return
        }
        guard matches(request.desired, generation: generation) else {
            completion(request.token, .failed(reason: "本地窗口读回不匹配")); return
        }
        appliedGeneration = generation; appliedState = request.desired; appliedToken = request.token
        NSLog("Core-SET: hosted-palette stage=apply point=v17-014 generation=%llu palette=%d token=%@/%@/%@ confirmed=1 scope=actual-host-floating-gradient-property original-runtime-receipt=0 device-effect-verified=0",
              generation, palette.rawValue, request.token.generation.uuidString, request.token.consumerID.uuidString, request.token.requestID.uuidString)
        completion(request.token, .applied(observed: State(menuVisible: host.panelVisible, floatingPalette: palette)))
    }

    func stop(_ token: CoreSetRequestToken, completion: @escaping (CoreSetRequestToken, CoreSetStopOutcome) -> Void) {
        precondition(Thread.isMainThread)
        func finish(_ result: CoreSetHUDStopResult) {
            let stopped = result.complete.boolValue && !host.localSurfacesReady && !host.floatingControlReady && host.observedFloatingColors.isEmpty
            if stopped { appliedGeneration = nil; appliedState = nil; appliedToken = nil }
            NSLog("Core-SET: hosted-palette stage=stop point=v17-014 token=%@/%@/%@ confirmed=%d scope=owned-host-window-and-gradient-removal persisted-palette-retained=1",
                  token.generation.uuidString, token.consumerID.uuidString, token.requestID.uuidString, stopped ? 1 : 0)
            completion(token, stopped ? .restored : .failed(reason: "窗口/浮球清理读回未确认"))
        }
        let result = host.stop()
        if result.complete.boolValue {
            finish(result)
        } else if host.hostedCleanupInFlight {
            host.stopHostedAsync { final in
                finish(final)
            }
        } else {
            completion(token, .failed(reason: "窗口清理未确认"))
        }
    }
}
