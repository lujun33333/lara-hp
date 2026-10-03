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
    private static var retained: [UUID: CoreSetRuntimeCoordinator] = [:]
    private let identity = UUID()
    private weak var scene: UIWindowScene?
    private weak var launcher: CoreSetLauncherViewController?
    private let menu = CoreSetMenuViewController()
    private let host = CoreSetHUDHost(hostingAdapter: nil)
    private let metalAdapter = CoreSetMetalRenderAdapter()
    private var remoteHostingAdapter: CoreSetRemoteHostingAdapter?
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
    private let performanceQueue = DispatchQueue(label: "coreset.local.performance", qos: .utility)
    private var performanceTimer: DispatchSourceTimer?
    private var performanceEpoch = UUID()
    private var stopping = false
    private var stopReceiptsPending = false
    private var submittedGeneration: UInt64?
    private let frameComposer = CoreSetFrameComposer()
    var localFrameDidConsume: ((CoreSetLocalFrameReceipt) -> Void)?
    private(set) var lastStopResult: CoreSetHUDStopResult?
    // Read-only snapshot, not a second mutable configuration store.
    var featureState: CoreSetFeatureState { menu.featureState }
    var playerCanvas: (generation: UInt64, size: CGSize)? {
        guard host.localSurfacesReady, let scene else { return nil }
        let size = scene.coordinateSpace.bounds.size
        return size.width > 0 && size.height > 0 ? (host.generation, size) : nil
    }
    var playerStyleReady: Bool { playerConsumer?.availability == .ready }
    var materialStyleReady: Bool { materialConsumer?.availability == .ready }
    var frameRateReady: Bool {
        host.renderFPSControlReady && host.observedRenderFPS() >= 30
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
    func refreshPlayerAvailability() { menu.refreshConsumerAvailability() }
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
        aimConsumer = CoreSetAimConsumer()
        if let aimConsumer { _ = menu.bindGameConsumer(aimConsumer, to: \.aim) }
        aimDisplayConsumer = CoreSetAimDisplayConsumer(coordinator: self)
        if let aimDisplayConsumer { _ = menu.bindGameConsumer(aimDisplayConsumer, to: \.aimDisplay) }
        recoilConsumer = CoreSetRecoilConsumer()
        if let recoilConsumer { _ = menu.bindGameConsumer(recoilConsumer, to: \.recoil) }
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
        menu.onClose = { [weak self] in self?.publishStatus() }
        Self.retained[identity] = self
        startPerformanceSampling()
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
                self.publishStatus()
            }
        }
        performanceTimer = timer
        timer.resume()
    }

    func activate() {
        guard !stopping, let scene else { return }
        if !host.localSurfacesReady {
            if remoteHostingAdapter == nil, laramgr.shared.rcready,
               let process = laramgr.shared.sbProc {
                let adapter = CoreSetRemoteHostingAdapter(remoteCall: process)
                if adapter.sessionIdentityReady,
                   host.installRemoteHostingAdapter(adapter) {
                    remoteHostingAdapter = adapter
                }
            }
            if !host.startLocal(in: scene, menuController: menu) {
                // A verified remote session may still lack this device's
                // hosting API. Retry local-only only after complete rollback.
                guard remoteHostingAdapter != nil, !host.cleanupPending,
                      host.installRemoteHostingAdapter(nil) else {
                    publishStatus(); return
                }
                remoteHostingAdapter = nil
                guard host.startLocal(in: scene, menuController: menu) else {
                    publishStatus(); return
                }
            }
            // Loads the existing, verified local palette before observing it.
            menu.requestMenuVisibility(false) { [weak self] _ in self?.publishStatus() }
        }
        host.setApplicationActive(true)
        hostChanged()
    }

    func deactivate() {
        guard !stopping else { return }
        host.setApplicationActive(false)
        hostChanged()
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
        if !stopping, host.localSurfacesReady, let scene,
           submittedGeneration != host.generation {
            for expired in frameComposer.reset(to: host.generation) {
                aimDisplayConsumer?.consumed(expired)
                localFrameDidConsume?(expired)
            }
            aimDisplayConsumer?.invalidateFrame()
            menu.invalidateLocalAimDisplayAfterHostReset()
            // No game collector and no fabricated entities: exercise a real empty
            // CA frame. The host rejects stale generation/sequence on delivery.
            submittedGeneration = host.generation
            let bounds = scene.coordinateSpace.bounds
            if bounds.width > 0, bounds.height > 0 {
                host.submitFrame(CoreSetRenderFrame(generation: host.generation, sequence: 1,
                    canvasSize: bounds.size, commands: []))
            }
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

    private func publishStatus() {
        let local = host.localSurfacesReady ? "本应用悬浮可用" : "本应用悬浮未就绪"
        let renderer = host.activeBackend == .metal ? "Metal" : "CA"
        let frame = host.lastConsumedSequence > 0 ? "\(renderer) 本地帧已消费" : "\(renderer) 本地帧未确认"
        let hosting = host.crossApplicationHosted ? "跨应用双面已回读" : "跨应用 unavailable"
        let cleanup = host.cleanupPending ? " · 清理待确认" : ""
        launcher?.updateRuntimePresentation(menuVisible: host.panelVisible,
            status: "\(local) · \(frame) · \(hosting)\(cleanup)")
        menu.updateRuntimeObservations(homeTelemetry.capture(
            hostReady: host.localSurfacesReady, panelVisible: host.panelVisible,
            cleanupPending: host.cleanupPending,
            remoteHosted: host.crossApplicationHosted,
            targetReadReady: playerConsumer?.availability == .ready))
    }

    // Local UIKit cleanup is synchronous and its concrete result is returned.
    // Channel stop receipts may complete later; retain the whole owner until all
    // receipts confirm restoration. Failed cleanup never releases the handles.
    @discardableResult
    func stop() -> CoreSetHUDStopResult {
        precondition(Thread.isMainThread)
        if stopReceiptsPending, let result = lastStopResult { return result }
        stopping = true
        performanceEpoch = UUID()
        performanceTimer?.cancel()
        performanceTimer = nil
        stopReceiptsPending = true
        for expired in frameComposer.reset(to: 0) {
            aimDisplayConsumer?.consumed(expired)
            localFrameDidConsume?(expired)
        }
        host.panelVisibilityRequested = nil
        let result = host.stop()
        lastStopResult = result
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
            self.menu.refreshConsumerAvailability()
            self.publishStatus()
            if result.complete && channelsRestored && !self.host.cleanupPending {
                self.host.stateDidChange = nil
                self.host.frameDidConsume = nil
                Self.retained.removeValue(forKey: self.identity)
            }
        }
        return result
    }

    static func stopAllForTermination() {
        // UIApplication will not promise time for an async continuation here.
        // Await the synchronous window/adapter result, never block the main queue
        // waiting for a callback that itself needs that queue.
        for owner in Array(retained.values) {
            let result = owner.stop()
            if !result.complete { NSLog("Core-SET: overlay cleanup remains unconfirmed") }
        }
    }
}

private final class CoreSetLocalHostConsumer: CoreSetFeatureConsumer {
    typealias State = CoreSetMenuHostSettings
    let capability = CoreSetCapability.hostWindow
    private let host: CoreSetHUDHost
    init(host: CoreSetHUDHost) { self.host = host }
    var availability: CoreSetAvailability {
        host.localSurfacesReady ? .ready : .unavailable(reason: "本应用窗口未就绪；跨应用 unavailable")
    }

    // Same v1.7 palette bytes as the menu, indexed by the typed native enum.
    private func colors(for palette: CoreSetFloatingPalette) -> [UIColor] {
        let rgb: [[CGFloat]] = [[174,139,148], [180,85,94], [68,119,168],
                               [58,133,120], [126,98,171], [181,86,137], [56,139,155]]
        func color(_ index: Int) -> UIColor {
            UIColor(red: rgb[index][0] / 255, green: rgb[index][1] / 255,
                    blue: rgb[index][2] / 255, alpha: 1)
        }
        if palette == .gradient { return [color(0), color(2)] }
        let index = CoreSetFloatingPalette.allCases.firstIndex(of: palette)!
        return [color(index), color(index)]
    }

    func apply(_ request: CoreSetApplyRequest<State>,
               completion: @escaping (CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void) {
        guard availability == .ready, let palette = request.desired.floatingPalette else {
            completion(request.token, .unavailable(reason: "本地宿主或颜色未就绪")); return
        }
        let colors = colors(for: palette)
        guard host.applyLocalMenu(visible: request.desired.menuVisible, colors: colors) else {
            completion(request.token, .failed(reason: "本地菜单设置失败")); return
        }
        let observed = host.observedFloatingColors
        guard observed.count == colors.count, zip(observed, colors).allSatisfy({ $0.0.isEqual($0.1) }),
              host.panelVisible == request.desired.menuVisible else {
            completion(request.token, .failed(reason: "本地窗口读回不匹配")); return
        }
        completion(request.token, .applied(observed: State(menuVisible: host.panelVisible, floatingPalette: palette)))
    }

    func stop(_ token: CoreSetRequestToken, completion: @escaping (CoreSetRequestToken, CoreSetStopOutcome) -> Void) {
        let result = host.stop()
        completion(token, result.complete ? .restored : .failed(reason: "窗口清理未确认"))
    }
}
