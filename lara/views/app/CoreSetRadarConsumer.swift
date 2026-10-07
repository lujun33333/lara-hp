import UIKit

// Radar dots and the read-only warning subset use separate composer lanes.
// Neither path clears player/material commands or writes to the target.
final class CoreSetRadarConsumer: CoreSetFeatureConsumer {
    typealias State = CoreSetRadarSettings
    let capability = CoreSetCapability.radarRendering
    private weak var coordinator: CoreSetRuntimeCoordinator?
    private let session = CoreSetReadSession()
    private let worker = DispatchQueue(label: "coreset.radar.read", qos: .userInitiated)
    private var probe: Timer?
    private var refresh: Timer?
    private var inFlight = false
    private var stopped = false
    private var revision: UInt64 = 0
    private var settings = CoreSetRadarSettings()
    private var activeToken: CoreSetRequestToken?
    private var pendingApply: (CoreSetRequestToken, (CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void)?
    private var pendingStop: (CoreSetRequestToken, (CoreSetRequestToken, CoreSetStopOutcome) -> Void)?
    private var expectedSnapshot: UUID?
    private var expectedGeneration: UInt64?
    private var expectedSessionGeneration: UInt64?
    private var expectedProcessID: Int32?
    private var expectedImageBase: UInt64?
    private let ownedLanes: Set<CoreSetRenderLane> = [.radar, .warning]
    private var confirmedLanes: Set<CoreSetRenderLane> = []

    init(coordinator: CoreSetRuntimeCoordinator) {
        self.coordinator = coordinator
        probe = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.probeTarget() }
        probeTarget()
    }

    var availability: CoreSetAvailability {
        session.ready && session.capabilities == 1 && coordinator?.playerCanvas != nil
            ? .ready : .unavailable(reason: "目标只读会话或本地绘制宿主未就绪")
    }
    var configurableFields: Set<CoreSetField> {
        return [.radarEnabled, .radarShowDistance, .radarDetectionDistance,
                .radarRadius, .radarX, .radarY, .warningEnabled,
                .warningIgnoreBots, .warningRange, .warningTextSize]
    }
    var supportedFields: Set<CoreSetField> {
        availability == .ready ? configurableFields : []
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

    private func accepts(_ state: State) -> Bool {
        if state.warningEnabled == true &&
            (state.warningRange.value == nil || state.warningTextSize.value == nil) { return false }
        if state.enabled == true {
            return state.detectionDistance.value != nil && state.placement.radius != nil &&
                state.placement.x != nil && state.placement.y != nil
        }
        return true
    }

    func apply(_ request: CoreSetApplyRequest<State>,
               completion: @escaping (CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void) {
        precondition(Thread.isMainThread)
        guard !stopped, availability == .ready, accepts(request.desired), revision < UInt64.max else {
            completion(request.token, .notApplied(reason: "雷达只读会话或字段未获静态支持")); return
        }
        refresh?.invalidate(); refresh = nil
        revision += 1
        settings = request.desired
        activeToken = request.token
        pendingApply = (request.token, completion)
        confirmedLanes.removeAll()
        capture()
    }

    private func capture() {
        guard !stopped, !inFlight, let token = activeToken,
              let canvas = coordinator?.playerCanvas else { return }
        let expectedRevision = revision
        if settings.enabled != true && settings.warningEnabled != true {
            submit([], warning: [], token: token, revision: expectedRevision, canvas: canvas,
                   snapshotID: UUID(), sessionGeneration: session.generation,
                   processID: session.processID, imageBase: session.imageBase)
            return
        }
        inFlight = true
        let includeWarningYaw = settings.warningEnabled == true
        worker.async { [weak self] in
            guard let self else { return }
            let snapshot = CoreSetPlayerCollector.capture(self.session, canvasSize: canvas.size,
                playerBones: false, botBones: false, boneDistanceLimit: 0,
                includeOffscreen: false, includeRadar: true, includeBattleInputs: false,
                playerWeaponText: false, botWeaponText: false, includeGrenadeWarning: false,
                includeCounts: false, playerInformation: false, botInformation: false,
                includeWarningYaw: includeWarningYaw)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight = false
                guard !self.stopped else { return }
                guard self.activeToken == token, self.revision == expectedRevision else {
                    if self.pendingApply != nil { self.capture() }
                    return
                }
                guard let snapshot, snapshot.sessionGeneration == self.session.generation,
                      snapshot.processID == self.session.processID,
                      snapshot.imageBase == self.session.imageBase else {
                    self.clearStaleLanes(token: token)
                    if let pending = self.pendingApply, pending.0 == token {
                        self.pendingApply = nil
                        pending.1(token, .unavailable(reason: "未取得完整且身份稳定的雷达快照"))
                    }
                    self.coordinator?.refreshPlayerAvailability()
                    return
                }
                guard let commands = self.renderRadar(snapshot, on: canvas.size),
                      let warning = self.renderWarning(snapshot, on: canvas.size) else {
                    self.clearStaleLanes(token: token)
                    if let pending = self.pendingApply, pending.0 == token {
                        self.pendingApply = nil
                        pending.1(token, .failed(reason: "雷达绘制命令超出本地宿主上限"))
                    }
                    return
                }
                let id = UUID(uuidString: snapshot.snapshotID.uuidString) ?? UUID()
                self.submit(commands, warning: warning, token: token,
                    revision: expectedRevision, canvas: canvas,
                    snapshotID: id, sessionGeneration: snapshot.sessionGeneration,
                    processID: snapshot.processID, imageBase: snapshot.imageBase)
            }
        }
    }

    private func submit(_ commands: [CoreSetRenderCommand], warning: [CoreSetRenderCommand],
                        token: CoreSetRequestToken,
                        revision expectedRevision: UInt64, canvas: (generation: UInt64, size: CGSize),
                        snapshotID: UUID, sessionGeneration: UInt64,
                        processID: Int32, imageBase: UInt64) {
        let radarAccepted = publish(commands, lane: .radar, token: token,
            revision: expectedRevision, canvas: canvas, snapshotID: snapshotID)
        let warningAccepted = publish(warning, lane: .warning, token: token,
            revision: expectedRevision, canvas: canvas, snapshotID: snapshotID)
        guard radarAccepted && warningAccepted else {
            clearStaleLanes(token: token)
            if let pending = pendingApply, pending.0 == token {
                pendingApply = nil
                pending.1(token, .failed(reason: "雷达或预警帧未进入本地合成器"))
            }
            return
        }
        if pendingApply?.0 == token {
            confirmedLanes.removeAll()
            expectedSnapshot = snapshotID
            expectedGeneration = canvas.generation
            expectedSessionGeneration = sessionGeneration
            expectedProcessID = processID
            expectedImageBase = imageBase
        }
    }

    private func publish(_ commands: [CoreSetRenderCommand], lane: CoreSetRenderLane,
                         token: CoreSetRequestToken, revision: UInt64,
                         canvas: (generation: UInt64, size: CGSize), snapshotID: UUID) -> Bool {
        if commands.isEmpty {
            return coordinator?.clearLane(lane, generation: canvas.generation,
                configRevision: revision, snapshotID: snapshotID,
                requestToken: token, canvasSize: canvas.size) == true
        }
        return coordinator?.submitLane(CoreSetLaneSubmission(lane: lane,
            hostGeneration: canvas.generation, configRevision: revision,
            snapshotID: snapshotID, requestToken: token,
            canvasSize: canvas.size, commands: commands)) == true
    }

    private func clearStaleLanes(token: CoreSetRequestToken) {
        guard let canvas = coordinator?.playerCanvas, revision < UInt64.max - 1 else { return }
        revision += 1
        _ = coordinator?.clearLane(.radar, generation: canvas.generation,
            configRevision: revision, snapshotID: UUID(), requestToken: token,
            canvasSize: canvas.size)
        _ = coordinator?.clearLane(.warning, generation: canvas.generation,
            configRevision: revision, snapshotID: UUID(), requestToken: token,
            canvasSize: canvas.size)
        revision += 1
    }

    private func renderRadar(_ snapshot: CoreSetPlayerSnapshot, on size: CGSize) -> [CoreSetRenderCommand]? {
        guard settings.enabled == true, let radius = settings.placement.radius,
              let x = settings.placement.x, let y = settings.placement.y,
              let detection = settings.detectionDistance.value else { return [] }
        let center = CGPoint(x: CGFloat(x), y: CGFloat(y))
        let r = CGFloat(radius)
        guard center.x - r >= 0, center.y - r >= 0,
              center.x + r <= size.width, center.y + r <= size.height else { return nil }
        var result = [CoreSetRenderCommand(kind: .ellipse,
            rect: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r),
            endpoint: .zero, color: UIColor.white, lineWidth: 1, filled: false,
            text: nil, fontSize: 12)]
        result.append(CoreSetRenderCommand(kind: .ellipse,
            rect: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4),
            endpoint: .zero, color: UIColor.white, lineWidth: 0, filled: true,
            text: nil, fontSize: 12))
        for mark in snapshot.marks {
            guard mark.distanceUnitsDividedBy100.isFinite,
                  mark.distanceUnitsDividedBy100 >= 0,
                  mark.distanceUnitsDividedBy100 <= Double(detection) else { continue }
            var point = CGPoint.zero
            guard CoreSetRadarPoint(mark.radarCameraDelta, snapshot.cameraYawDegrees,
                                    Double(radius), Double(detection), center, &point) else { return nil }
            let color = mark.bot ? UIColor.systemYellow : UIColor.systemRed
            result.append(CoreSetRenderCommand(kind: .ellipse,
                rect: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6),
                endpoint: .zero, color: color, lineWidth: 0, filled: true,
                text: nil, fontSize: 12))
            if settings.showDistance == true {
                let meters = Int(mark.distanceUnitsDividedBy100.rounded(.toNearestOrAwayFromZero))
                result.append(CoreSetRenderCommand(kind: .text,
                    rect: CGRect(x: point.x + 4, y: point.y - 10, width: 46, height: 18),
                    endpoint: .zero, color: color, lineWidth: 0, filled: false,
                    text: "\(meters)m", fontSize: 11))
            }
            if result.count > 8000 { return nil }
        }
        return result
    }

    private func renderWarning(_ snapshot: CoreSetPlayerSnapshot, on size: CGSize) -> [CoreSetRenderCommand]? {
        guard settings.warningEnabled == true else { return [] }
        guard let range = settings.warningRange.value,
              let textSize = settings.warningTextSize.value else { return nil }
        let hits = snapshot.marks.filter { mark in
            guard !(settings.ignoreBots == true && mark.bot),
                  let yaw = mark.warningServerYawDegrees?.doubleValue,
                  mark.distanceUnitsDividedBy100.isFinite,
                  mark.distanceUnitsDividedBy100 >= 0,
                  mark.distanceUnitsDividedBy100 <= Double(range) else { return false }
            return CoreSetWarningAngleMatches(mark.radarCameraDelta, yaw)
        }.sorted { $0.distanceUnitsDividedBy100 < $1.distanceUnitsDividedBy100 }
        var result: [CoreSetRenderCommand] = []
        for mark in hits.prefix(32) {
            let y = CGFloat(12 + result.count * (textSize + 4))
            let height = CGFloat(textSize + 4)
            if y + height > size.height { break }
            let meters = Int(mark.distanceUnitsDividedBy100.rounded(.toNearestOrAwayFromZero))
            result.append(CoreSetRenderCommand(kind: .text,
                rect: CGRect(x: 12, y: y, width: max(0, size.width - 24), height: height),
                endpoint: .zero, color: .systemRed, lineWidth: 0, filled: false,
                text: "被瞄预警 \(meters)m",
                fontSize: CGFloat(textSize)))
        }
        return result
    }

    func consumed(_ receipt: CoreSetLocalFrameReceipt) {
        guard ownedLanes.contains(receipt.lane) else { return }
        if let stop = pendingStop, stop.0 == receipt.requestToken,
           receipt.configRevision == revision, receipt.snapshotID == expectedSnapshot,
           receipt.hostGeneration == expectedGeneration {
            guard receipt.acceptedByLocalRenderer else {
                pendingStop = nil; expectedSnapshot = nil; expectedGeneration = nil
                confirmedLanes.removeAll()
                stop.1(stop.0, .failed(reason: "雷达/预警 lane 清空未获双回执"))
                return
            }
            confirmedLanes.insert(receipt.lane)
            if confirmedLanes == ownedLanes {
                pendingStop = nil; expectedSnapshot = nil; expectedGeneration = nil
                confirmedLanes.removeAll()
                stop.1(stop.0, .restored)
            }
            return
        }
        if let pending = pendingApply, pending.0 == receipt.requestToken,
           receipt.configRevision == revision, receipt.snapshotID == expectedSnapshot,
           receipt.hostGeneration == expectedGeneration {
            let identityMatches = session.ready && session.generation == expectedSessionGeneration &&
                session.processID == expectedProcessID && session.imageBase == expectedImageBase
            guard identityMatches else {
                pendingApply = nil; expectedSnapshot = nil; expectedGeneration = nil
                confirmedLanes.removeAll()
                expectedSessionGeneration = nil; expectedProcessID = nil; expectedImageBase = nil
                clearStaleLanes(token: pending.0)
                pending.1(pending.0, .unavailable(reason: "雷达快照消费时目标身份已变化"))
                return
            }
            guard receipt.acceptedByLocalRenderer else {
                pendingApply = nil; expectedSnapshot = nil; expectedGeneration = nil
                confirmedLanes.removeAll()
                expectedSessionGeneration = nil; expectedProcessID = nil; expectedImageBase = nil
                clearStaleLanes(token: pending.0)
                pending.1(pending.0, .failed(reason: "雷达或预警帧未被本地渲染器消费"))
                return
            }
            confirmedLanes.insert(receipt.lane)
            if confirmedLanes == ownedLanes {
                pendingApply = nil; expectedSnapshot = nil; expectedGeneration = nil
                confirmedLanes.removeAll()
                expectedSessionGeneration = nil; expectedProcessID = nil; expectedImageBase = nil
                pending.1(pending.0, .applied(observed: settings))
                refresh?.invalidate(); refresh = nil
                if settings.enabled == true || settings.warningEnabled == true {
                    refresh = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.capture() }
                }
            }
            return
        }
        if activeToken == receipt.requestToken && availability != .ready { clearStaleLanes(token: receipt.requestToken) }
    }

    func stop(_ token: CoreSetRequestToken,
              completion: @escaping (CoreSetRequestToken, CoreSetStopOutcome) -> Void) {
        precondition(Thread.isMainThread)
        let clean = shutdownReadSession()
        guard clean else { completion(token, .failed(reason: "雷达只读会话清理未确认")); return }
        guard revision < UInt64.max - 1 else { completion(token, .failed(reason: "雷达配置序号耗尽")); return }
        revision += 1
        if let canvas = coordinator?.playerCanvas {
            let id = UUID()
            expectedSnapshot = id; expectedGeneration = canvas.generation
            pendingStop = (token, completion)
            confirmedLanes.removeAll()
            let radarCleared = coordinator?.clearLane(.radar, generation: canvas.generation,
                configRevision: revision, snapshotID: id, requestToken: token,
                canvasSize: canvas.size) == true
            let warningCleared = coordinator?.clearLane(.warning, generation: canvas.generation,
                configRevision: revision, snapshotID: id, requestToken: token,
                canvasSize: canvas.size) == true
            if radarCleared && warningCleared { return }
            pendingStop = nil
            clearStaleLanes(token: token)
        }
        completion(token, .failed(reason: "雷达/预警 lane 清空未获双回执"))
    }

    @discardableResult
    func shutdownReadSession() -> Bool {
        precondition(Thread.isMainThread)
        stopped = true
        probe?.invalidate(); probe = nil
        refresh?.invalidate(); refresh = nil
        activeToken = nil; pendingApply = nil
        let cleanup = worker.sync { session.disconnect() }
        return cleanup.taskPortReleased && cleanup.generationAdvanced
    }
}
