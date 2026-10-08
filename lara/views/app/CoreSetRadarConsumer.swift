import UIKit
import QuartzCore

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
    private var expectedCapturedAt: Double?
    private var lastCaptureFailure: String?
    private var expectedReadSemanticDiagnostic: String?
    private var lastSemanticLogAt: Double = 0
    private var lastSemanticLogRevision: UInt64?
    private var pendingInvalidation: (token: CoreSetRequestToken, snapshot: UUID,
        generation: UInt64, revision: UInt64, reason: String)?
    private var invalidationLanes: Set<CoreSetRenderLane> = []
    private var invalidationRejected = false
    private let ownedLanes: Set<CoreSetRenderLane> = [.radar, .warning]
    private var confirmedLanes: Set<CoreSetRenderLane> = []

    init(coordinator: CoreSetRuntimeCoordinator) {
        self.coordinator = coordinator
        session.diagnosticLabel = "radar"
        probe = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.probeTarget() }
        probeTarget()
    }

    var availability: CoreSetAvailability {
        guard session.ready && session.capabilities == 1 else {
            return .unavailable(reason: session.lastConnectDiagnostic)
        }
        return coordinator?.playerCanvas != nil ? .ready :
            .unavailable(reason: "本地绘制宿主未就绪")
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
            let reason: String
            if case .unavailable(let detail) = availability { reason = detail }
            else { reason = "雷达侦测距离、半径、X/Y 或预警距离、字号未完整选择，或会话已停止" }
            completion(request.token, .notApplied(reason: reason)); return
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
            expectedReadSemanticDiagnostic = "radar=disabled warning=disabled commands=0"
            submit([], warning: [], token: token, revision: expectedRevision, canvas: canvas,
                   snapshotID: UUID(), sessionGeneration: session.generation,
                   processID: session.processID, imageBase: session.imageBase,
                   capturedAt: CACurrentMediaTime())
            return
        }
        inFlight = true
        let includeWarningYaw = settings.warningEnabled == true
        worker.async { [weak self] in
            guard let self else { return }
            let failureSequence = self.session.readFailureSequence
            let snapshot = CoreSetPlayerCollector.capture(self.session, canvasSize: canvas.size,
                playerBones: false, botBones: false, boneDistanceLimit: 0,
                includeOffscreen: false, includeRadar: true, includeBattleInputs: false,
                playerWeaponText: includeWarningYaw, botWeaponText: includeWarningYaw, includeGrenadeWarning: false,
                includeCounts: false, playerInformation: includeWarningYaw, botInformation: includeWarningYaw,
                includeWarningYaw: includeWarningYaw)
            let captureFailure = self.session.readFailureSequence != failureSequence
                ? self.session.lastReadDiagnostic
                : "snapshot-validation-or-identity-failed transport-errors=0"
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight = false
                guard !self.stopped else { return }
                guard self.activeToken == token, self.revision == expectedRevision else {
                    if self.pendingApply != nil { self.capture() }
                    return
                }
                let captureAge = snapshot.map { CACurrentMediaTime() - $0.captureCompletedMonotonicSeconds } ?? .nan
                let failureReason = snapshot != nil && !(0...0.5).contains(captureAge)
                    ? String(format: "snapshot-stale stage=capture ageSeconds=%.3f limit=0.5", captureAge)
                    : captureFailure
                guard let snapshot, snapshot.sessionGeneration == self.session.generation,
                      snapshot.processID == self.session.processID,
                      snapshot.imageBase == self.session.imageBase,
                      captureAge >= 0, captureAge <= 0.5 else {
                    if self.lastCaptureFailure != failureReason {
                        self.lastCaptureFailure = failureReason
                        NSLog("Core-SET: target-read lane=radar stage=capture ready=0 reason=%@", failureReason)
                    }
                    self.clearStaleLanes(token: token, reason: failureReason)
                    if let pending = self.pendingApply, pending.0 == token {
                        self.pendingApply = nil
                        pending.1(token, .unavailable(reason: "雷达快照未确认：\(failureReason)"))
                    }
                    self.coordinator?.refreshPlayerAvailability()
                    return
                }
                self.lastCaptureFailure = nil
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
                self.expectedReadSemanticDiagnostic = snapshot.readSemanticDiagnostic +
                    " radarCommands=\(commands.count) warningCommands=\(warning.count) warningText=name-weapon-rounded-m warningLayout=local-subset yawFreshness=capture-stable-only"
                self.submit(commands, warning: warning, token: token,
                    revision: expectedRevision, canvas: canvas,
                    snapshotID: id, sessionGeneration: snapshot.sessionGeneration,
                    processID: snapshot.processID, imageBase: snapshot.imageBase,
                    capturedAt: snapshot.captureCompletedMonotonicSeconds)
            }
        }
    }

    private func submit(_ commands: [CoreSetRenderCommand], warning: [CoreSetRenderCommand],
                        token: CoreSetRequestToken,
                        revision expectedRevision: UInt64, canvas: (generation: UInt64, size: CGSize),
                        snapshotID: UUID, sessionGeneration: UInt64,
                        processID: Int32, imageBase: UInt64, capturedAt: Double) {
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
        confirmedLanes.removeAll() // Each frame requires both exact lane receipts.
        expectedSnapshot = snapshotID
        expectedGeneration = canvas.generation
        expectedSessionGeneration = sessionGeneration
        expectedProcessID = processID
        expectedImageBase = imageBase
        expectedCapturedAt = capturedAt
    }

    private func publish(_ commands: [CoreSetRenderCommand], lane: CoreSetRenderLane,
                         token: CoreSetRequestToken, revision: UInt64,
                         canvas: (generation: UInt64, size: CGSize), snapshotID: UUID) -> Bool {
        // No warning hits (or a disabled radar in a warning-only frame) must
        // not install the explicit stop barrier for this configuration.
        return coordinator?.submitLane(CoreSetLaneSubmission(lane: lane,
            hostGeneration: canvas.generation, configRevision: revision,
            snapshotID: snapshotID, requestToken: token,
            canvasSize: canvas.size, commands: commands)) == true
    }

    private func clearStaleLanes(token: CoreSetRequestToken, reason: String = "radar-frame-invalidated",
                                 recordInvalidation: Bool = true) {
        guard let canvas = coordinator?.playerCanvas, revision < UInt64.max - 1 else { return }
        refresh?.invalidate(); refresh = nil
        revision += 1
        let id = UUID()
        if recordInvalidation && pendingApply == nil && pendingStop == nil && activeToken == token {
            pendingInvalidation = (token, id, canvas.generation, revision, reason)
            invalidationLanes.removeAll(); invalidationRejected = false
        }
        let radarCleared = coordinator?.clearLane(.radar, generation: canvas.generation,
            configRevision: revision, snapshotID: id, requestToken: token,
            canvasSize: canvas.size) == true
        let warningCleared = coordinator?.clearLane(.warning, generation: canvas.generation,
            configRevision: revision, snapshotID: id, requestToken: token,
            canvasSize: canvas.size) == true
        if !radarCleared || !warningCleared {
            pendingInvalidation = nil; invalidationLanes.removeAll()
            NSLog("Core-SET: target-read lane=radar stage=clear-submission confirmed=0 reason=%@", reason)
        }
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
                  let yaw = mark.warningYawDegrees?.doubleValue,
                  mark.distanceUnitsDividedBy100.isFinite,
                  mark.distanceUnitsDividedBy100 >= 0,
                  mark.distanceUnitsDividedBy100 <= Double(range) else { return false }
            return CoreSetWarningAngleMatches(mark.radarCameraDelta, yaw)
        } // Core's warning vector preserves actor traversal order, not nearest-first order.
        var result: [CoreSetRenderCommand] = []
        for mark in hits.prefix(32) {
            let y = CGFloat(12 + result.count * (textSize + 4))
            let height = CGFloat(textSize + 4)
            if y + height > size.height { break }
            guard let text = CoreSetReferenceWarningText(mark.playerName, mark.bot, mark.weaponName,
                                                        mark.weaponID, mark.distanceUnitsDividedBy100) else { return nil }
            result.append(CoreSetRenderCommand(kind: .text,
                rect: CGRect(x: 12, y: y, width: max(0, size.width - 24), height: height),
                endpoint: .zero, color: .systemRed, lineWidth: 0, filled: false,
                text: text,
                fontSize: CGFloat(textSize)))
        }
        return result
    }

    func consumed(_ receipt: CoreSetLocalFrameReceipt) {
        guard ownedLanes.contains(receipt.lane) else { return }
        if let invalidation = pendingInvalidation,
           receipt.requestToken == invalidation.token, receipt.snapshotID == invalidation.snapshot,
           receipt.hostGeneration == invalidation.generation, receipt.configRevision == invalidation.revision {
            invalidationLanes.insert(receipt.lane)
            invalidationRejected = invalidationRejected || !receipt.acceptedByLocalRenderer
            guard invalidationLanes == ownedLanes else { return }
            pendingInvalidation = nil; invalidationLanes.removeAll()
            guard pendingApply == nil, pendingStop == nil, activeToken == invalidation.token else { return }
            activeToken = nil
            coordinator?.invalidateReadFrameObservation(capability,
                reason: invalidationRejected ? "radar-clear-renderer-rejected" : invalidation.reason)
            return
        }
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
            let fresh = expectedCapturedAt.map {
                CACurrentMediaTime() - $0 >= 0 && CACurrentMediaTime() - $0 <= 0.5
            } ?? false
            guard identityMatches && fresh else {
                pendingApply = nil; expectedSnapshot = nil; expectedGeneration = nil
                confirmedLanes.removeAll()
                expectedSessionGeneration = nil; expectedProcessID = nil; expectedImageBase = nil
                expectedCapturedAt = nil
                let reason = identityMatches ? "snapshot-stale stage=receipt" : "radar-receipt-identity-lost"
                NSLog("Core-SET: target-read lane=radar stage=receipt confirmed=0 reason=%@", reason)
                clearStaleLanes(token: pending.0, reason: reason, recordInvalidation: false)
                pending.1(pending.0, .unavailable(reason: reason))
                return
            }
            guard receipt.acceptedByLocalRenderer else {
                pendingApply = nil; expectedSnapshot = nil; expectedGeneration = nil
                confirmedLanes.removeAll()
                expectedSessionGeneration = nil; expectedProcessID = nil; expectedImageBase = nil
                expectedCapturedAt = nil
                clearStaleLanes(token: pending.0, recordInvalidation: false)
                pending.1(pending.0, .failed(reason: "雷达或预警帧未被本地渲染器消费"))
                return
            }
            confirmedLanes.insert(receipt.lane)
            if confirmedLanes == ownedLanes {
                logReadSemanticReceipt(receipt)
                pendingApply = nil; expectedSnapshot = nil; expectedGeneration = nil
                confirmedLanes.removeAll()
                expectedSessionGeneration = nil; expectedProcessID = nil; expectedImageBase = nil
                expectedCapturedAt = nil
                pending.1(pending.0, .applied(observed: settings))
                refresh?.invalidate(); refresh = nil
                if settings.enabled == true || settings.warningEnabled == true {
                    refresh = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.capture() }
                }
            }
            return
        }
        if activeToken == receipt.requestToken,
           receipt.configRevision == revision, receipt.snapshotID == expectedSnapshot,
           receipt.hostGeneration == expectedGeneration {
            let identityMatches = session.ready && session.generation == expectedSessionGeneration &&
                session.processID == expectedProcessID && session.imageBase == expectedImageBase
            let fresh = expectedCapturedAt.map {
                CACurrentMediaTime() - $0 >= 0 && CACurrentMediaTime() - $0 <= 0.5
            } ?? false
            if !receipt.acceptedByLocalRenderer || !identityMatches || !fresh {
                clearStaleLanes(token: receipt.requestToken,
                    reason: !identityMatches ? "radar-receipt-identity-lost" :
                        (!fresh ? "snapshot-stale stage=receipt" : "radar-renderer-rejected"))
            } else {
                confirmedLanes.insert(receipt.lane)
                if confirmedLanes == ownedLanes { logReadSemanticReceipt(receipt) }
            }
        } else if activeToken == receipt.requestToken && availability != .ready {
            clearStaleLanes(token: receipt.requestToken, reason: "radar-receipt-session-unavailable")
        }
    }

    private func logReadSemanticReceipt(_ receipt: CoreSetLocalFrameReceipt) {
        guard let diagnostic = expectedReadSemanticDiagnostic else { return }
        let now = CACurrentMediaTime()
        guard lastSemanticLogRevision != receipt.configRevision || now - lastSemanticLogAt >= 30 else { return }
        lastSemanticLogRevision = receipt.configRevision; lastSemanticLogAt = now
        NSLog("Core-SET: read-semantic lane=radar-warning stage=receipt confirmed=1 evidence=local-renderer-frame parity=partial session=%llu pid=%d host=%llu revision=%llu snapshot=%@ scope=%@",
              session.generation, session.processID, receipt.hostGeneration, receipt.configRevision,
              receipt.snapshotID.uuidString, diagnostic)
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
        expectedReadSemanticDiagnostic = nil
        let cleanup = worker.sync { session.disconnect() }
        return cleanup.complete
    }
}
