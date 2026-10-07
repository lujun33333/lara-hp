import UIKit
import QuartzCore

// Name-matched material marks have their own read-only session and render lane.
// Opened-crate semantics remain unproven; filtering currently uses only the
// observed escape-box children heuristic. Armed filtering independently rereads
// local WeaponID within this collector's target identity lease.
final class CoreSetMaterialConsumer: CoreSetFeatureConsumer {
    typealias State = CoreSetMaterialSettings
    let capability = CoreSetCapability.materialFiltering
    private weak var coordinator: CoreSetRuntimeCoordinator?
    private let session = CoreSetReadSession()
    private let worker = DispatchQueue(label: "coreset.materials.read", qos: .userInitiated)
    private var probe: Timer?
    private var refresh: Timer?
    private var inFlight = false
    private var stopped = false
    private var revision: UInt64 = 0
    private var settings = CoreSetMaterialSettings()
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
    private var pendingInvalidation: (token: CoreSetRequestToken, snapshot: UUID,
        generation: UInt64, revision: UInt64, reason: String)?

    init(coordinator: CoreSetRuntimeCoordinator) {
        self.coordinator = coordinator
        session.diagnosticLabel = "materials"
        probe = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.probeTarget() }
        probeTarget()
    }

    var availability: CoreSetAvailability {
        guard session.ready && session.capabilities == 1 else {
            return .unavailable(reason: session.lastConnectDiagnostic)
        }
        return coordinator?.playerCanvas != nil ? .ready :
            .unavailable(reason: "本地绘制画布未就绪")
    }
    var configurableFields: Set<CoreSetField> {
        return [.materialEnabled, .hideWhileArmed, .metroArmor, .hideOpenedCrates,
                .showCrateLevel, .vehicleStatus, .materialDistance,
                .materialColor, .materialGroupSelection]
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
        guard state.categories.count == 13 else { return false }
        guard state.enabled == true else { return true }
        for category in state.categories {
            guard category.groups.count == CoreSetMaterialCatalog.names[category.category.rawValue].count else { return false }
            let selected = category.groups.contains { $0.members.contains(true) }
            if selected {
                guard let min = category.distance.minimum, let max = category.distance.maximum,
                      min <= max, category.color != nil else { return false }
            }
        }
        return true
    }

    func apply(_ request: CoreSetApplyRequest<State>,
               completion: @escaping (CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void) {
        precondition(Thread.isMainThread)
        guard !stopped, availability == .ready, accepts(request.desired), revision < UInt64.max else {
            let reason: String
            if case .unavailable(let detail) = availability { reason = detail }
            else { reason = "所选物资的距离区间或颜色未完整选择，或会话已停止" }
            completion(request.token, .notApplied(reason: reason)); return
        }
        refresh?.invalidate(); refresh = nil
        revision += 1
        settings = request.desired
        activeToken = request.token
        pendingApply = (request.token, completion)
        capture()
    }

    private func capture() {
        guard !stopped, !inFlight, let token = activeToken,
              let canvas = coordinator?.playerCanvas else { return }
        let expectedRevision = revision
        if settings.enabled != true && settings.metroArmor != true {
            submit([], token: token, revision: expectedRevision, canvas: canvas,
                   snapshotID: UUID(), sessionGeneration: session.generation,
                   processID: session.processID, imageBase: session.imageBase,
                   capturedAt: CACurrentMediaTime())
            return
        }
        inFlight = true
        let includeArmedState = settings.hideWhileArmed == true
        let includeCrateLevel = settings.showCrateLevel == true
        let includeVehicleStatus = settings.vehicleStatus == true
        let includeMetroArmor = settings.metroArmor == true
        let includeHideOpenedCrates = settings.hideOpenedCrates == true
        worker.async { [weak self] in
            guard let self else { return }
            let failureSequence = self.session.readFailureSequence
            let snapshot = CoreSetMaterialCollector.capture(self.session, canvasSize: canvas.size,
                patterns: CoreSetMaterialCatalog.matchKeys, includeArmedState: includeArmedState,
                includeCrateLevel: includeCrateLevel, includeVehicleStatus: includeVehicleStatus,
                includeMetroArmor: includeMetroArmor,
                includeHideOpenedCrates: includeHideOpenedCrates)
            let capturedAt = CACurrentMediaTime()
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
                let captureAge = CACurrentMediaTime() - capturedAt
                let failureReason = snapshot != nil && !(0...0.5).contains(captureAge)
                    ? String(format: "snapshot-stale stage=capture ageSeconds=%.3f limit=0.5", captureAge)
                    : captureFailure
                guard let snapshot, snapshot.sessionGeneration == self.session.generation,
                      snapshot.processID == self.session.processID,
                      snapshot.imageBase == self.session.imageBase,
                      captureAge >= 0, captureAge <= 0.5 else {
                    if self.lastCaptureFailure != failureReason {
                        self.lastCaptureFailure = failureReason
                        NSLog("Core-SET: target-read lane=materials stage=capture ready=0 reason=%@", failureReason)
                    }
                    self.clearStaleLane(token: token, reason: failureReason)
                    if let pending = self.pendingApply, pending.0 == token {
                        self.pendingApply = nil
                        pending.1(token, .unavailable(reason: "物资快照未确认：\(failureReason)"))
                    }
                    self.coordinator?.refreshPlayerAvailability()
                    return
                }
                self.lastCaptureFailure = nil
                guard let commands = self.render(snapshot, on: canvas.size) else {
                    self.clearStaleLane(token: token)
                    if let pending = self.pendingApply, pending.0 == token {
                        self.pendingApply = nil
                        pending.1(token, .failed(reason: "物资绘制命令超出本地宿主上限"))
                    }
                    return
                }
                let id = UUID(uuidString: snapshot.snapshotID.uuidString) ?? UUID()
                self.submit(commands, token: token, revision: expectedRevision, canvas: canvas,
                    snapshotID: id, sessionGeneration: snapshot.sessionGeneration,
                    processID: snapshot.processID, imageBase: snapshot.imageBase,
                    capturedAt: capturedAt)
            }
        }
    }

    private func submit(_ commands: [CoreSetRenderCommand], token: CoreSetRequestToken,
                        revision expectedRevision: UInt64, canvas: (generation: UInt64, size: CGSize),
                        snapshotID: UUID, sessionGeneration: UInt64,
                        processID: Int32, imageBase: UInt64, capturedAt: Double) {
        let input = CoreSetLaneSubmission(lane: .materials, hostGeneration: canvas.generation,
            configRevision: expectedRevision, snapshotID: snapshotID, requestToken: token,
            canvasSize: canvas.size, commands: commands)
        // A complete empty snapshot is a normal frame. clearLane installs a
        // stop barrier and would reject later nonempty frames at this revision.
        let accepted = coordinator?.submitLane(input)
        guard accepted == true else {
            clearStaleLane(token: token)
            if let pending = pendingApply, pending.0 == token {
                pendingApply = nil
                pending.1(token, .failed(reason: "物资帧未进入本地合成器"))
            }
            return
        }
        expectedSnapshot = snapshotID
        expectedGeneration = canvas.generation
        expectedSessionGeneration = sessionGeneration
        expectedProcessID = processID
        expectedImageBase = imageBase
        expectedCapturedAt = capturedAt
    }

    private func clearStaleLane(token: CoreSetRequestToken, reason: String = "material-frame-invalidated",
                                recordInvalidation: Bool = true) {
        guard let canvas = coordinator?.playerCanvas, revision < UInt64.max - 1 else { return }
        refresh?.invalidate(); refresh = nil
        revision += 1
        let id = UUID()
        if recordInvalidation && pendingApply == nil && pendingStop == nil && activeToken == token {
            pendingInvalidation = (token, id, canvas.generation, revision, reason)
        }
        let cleared = coordinator?.clearLane(.materials, generation: canvas.generation,
            configRevision: revision, snapshotID: id, requestToken: token,
            canvasSize: canvas.size) == true
        if !cleared {
            pendingInvalidation = nil
            NSLog("Core-SET: target-read lane=materials stage=clear-submission confirmed=0 reason=%@", reason)
        }
        revision += 1
    }

    private func render(_ snapshot: CoreSetMaterialSnapshot, on size: CGSize) -> [CoreSetRenderCommand]? {
        var result: [CoreSetRenderCommand] = []
        let showMaterials = settings.enabled == true &&
            !(settings.hideWhileArmed == true && snapshot.localWeaponID != 0)
        if showMaterials {
            for mark in snapshot.marks {
                let index = mark.recordIndex
                guard CoreSetMaterialCatalog.records.indices.contains(index) else { return nil }
                let record = CoreSetMaterialCatalog.records[index]
                if settings.hideOpenedCrates == true && record.category == .crates &&
                    mark.escapeBoxChildrenCount?.intValue == 1 { continue }
                let category = settings.categories[record.category.rawValue]
                guard category.groups.indices.contains(record.groupIndex),
                      category.groups[record.groupIndex].members.indices.contains(record.memberIndex) else { return nil }
                guard category.groups[record.groupIndex].members[record.memberIndex] == true else { continue }
                guard let minimum = category.distance.minimum, let maximum = category.distance.maximum,
                      let rgba = category.color, mark.distanceUnitsDividedBy100.isFinite,
                      mark.distanceUnitsDividedBy100 >= Double(minimum),
                      mark.distanceUnitsDividedBy100 <= Double(maximum) else { continue }
                let point = mark.point
                guard point.x.isFinite && point.y.isFinite && point.x >= 0 && point.y >= 0 &&
                      point.x <= size.width && point.y <= size.height else { return nil }
                let color = UIColor(red: CGFloat(rgba.red), green: CGFloat(rgba.green),
                                    blue: CGFloat(rgba.blue), alpha: CGFloat(rgba.alpha))
                let title = category.groups[record.groupIndex].displayName
                let level = settings.showCrateLevel == true && record.category == .crates
                    ? mark.crateLevelLabel : nil
                let displayTitle = level.map { "\(title) \($0)" } ?? title
                let distanceText = "\(Int(mark.distanceUnitsDividedBy100))米"
                var displayText = "\(displayTitle)   \(distanceText)"
                if settings.vehicleStatus == true && record.category == .vehicles {
                    if let hp = mark.vehicleHPPercent, let fuel = mark.vehicleFuelPercent {
                        displayText = "\(displayTitle)[血\(hp.intValue)%油\(fuel.intValue)%]\(distanceText)"
                    } else if let hp = mark.vehicleHPPercent {
                        displayText = "\(displayTitle)[血\(hp.intValue)%]\(distanceText)"
                    } else if let fuel = mark.vehicleFuelPercent {
                        displayText = "\(displayTitle)[油\(fuel.intValue)%]\(distanceText)"
                    }
                }
                result.append(CoreSetRenderCommand(kind: .text,
                    rect: CGRect(x: point.x - 70, y: point.y - 11, width: 140, height: 22),
                    endpoint: .zero, color: color, lineWidth: 0, filled: false,
                    text: displayText, fontSize: 12)
                    .styled(role: .materialText).centeredText())
                if result.count > 8000 { return nil }
            }
        }
        if settings.metroArmor == true {
            for mark in snapshot.metroMarks {
                guard mark.point.x.isFinite && mark.point.y.isFinite &&
                      mark.point.x >= 0 && mark.point.y >= 0 &&
                      mark.point.x <= size.width && mark.point.y <= size.height else { return nil }
                let labels = [mark.headLabel.map { "头\($0)" }, mark.armorLabel.map { "甲\($0)" }]
                    .compactMap { $0 }
                guard !labels.isEmpty else { continue }
                result.append(CoreSetRenderCommand(kind: .text,
                    rect: CGRect(x: mark.point.x - 70, y: mark.point.y - 35, width: 140, height: 22),
                    endpoint: .zero, color: .systemOrange, lineWidth: 0, filled: false,
                    text: labels.joined(separator: " "), fontSize: 14).centeredText())
                if result.count > 8000 { return nil }
            }
        }
        return result
    }

    func consumed(_ receipt: CoreSetLocalFrameReceipt) {
        guard receipt.lane == .materials else { return }
        if let invalidation = pendingInvalidation,
           receipt.requestToken == invalidation.token, receipt.snapshotID == invalidation.snapshot,
           receipt.hostGeneration == invalidation.generation, receipt.configRevision == invalidation.revision {
            pendingInvalidation = nil
            guard pendingApply == nil, pendingStop == nil, activeToken == invalidation.token else { return }
            activeToken = nil
            coordinator?.invalidateReadFrameObservation(capability,
                reason: receipt.acceptedByLocalRenderer ? invalidation.reason : "material-clear-renderer-rejected")
            return
        }
        if let stop = pendingStop, stop.0 == receipt.requestToken,
           receipt.configRevision == revision, receipt.snapshotID == expectedSnapshot,
           receipt.hostGeneration == expectedGeneration {
            pendingStop = nil; expectedSnapshot = nil; expectedGeneration = nil
            stop.1(stop.0, receipt.acceptedByLocalRenderer ? .restored : .failed(reason: "物资 lane 清空未获回执"))
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
            pendingApply = nil; expectedSnapshot = nil; expectedGeneration = nil
            expectedSessionGeneration = nil; expectedProcessID = nil; expectedImageBase = nil
            expectedCapturedAt = nil
            guard identityMatches && fresh else {
                let reason = identityMatches ? "snapshot-stale stage=receipt" : "material-receipt-identity-lost"
                NSLog("Core-SET: target-read lane=materials stage=receipt confirmed=0 reason=%@", reason)
                clearStaleLane(token: pending.0, reason: reason, recordInvalidation: false)
                pending.1(pending.0, .unavailable(reason: reason))
                return
            }
            if receipt.acceptedByLocalRenderer {
                pending.1(pending.0, .applied(observed: settings))
                refresh?.invalidate(); refresh = nil
                if settings.enabled == true || settings.metroArmor == true {
                    refresh = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.capture() }
                }
            } else {
                pending.1(pending.0, .failed(reason: "物资帧未被本地渲染器消费"))
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
                clearStaleLane(token: receipt.requestToken,
                    reason: !identityMatches ? "material-receipt-identity-lost" :
                        (!fresh ? "snapshot-stale stage=receipt" : "material-renderer-rejected"))
            }
        } else if activeToken == receipt.requestToken && availability != .ready {
            clearStaleLane(token: receipt.requestToken, reason: "material-receipt-session-unavailable")
        }
    }

    func stop(_ token: CoreSetRequestToken,
              completion: @escaping (CoreSetRequestToken, CoreSetStopOutcome) -> Void) {
        precondition(Thread.isMainThread)
        let clean = shutdownReadSession()
        guard clean else { completion(token, .failed(reason: "物资只读会话清理未确认")); return }
        guard revision < UInt64.max else { completion(token, .failed(reason: "物资配置序号耗尽")); return }
        revision += 1
        if let canvas = coordinator?.playerCanvas {
            let id = UUID()
            expectedSnapshot = id; expectedGeneration = canvas.generation
            pendingStop = (token, completion)
            if coordinator?.clearLane(.materials, generation: canvas.generation,
                configRevision: revision, snapshotID: id, requestToken: token,
                canvasSize: canvas.size) == true { return }
            pendingStop = nil
        }
        completion(token, coordinator?.lastStopResult?.complete.boolValue == true
            ? .restored : .failed(reason: "物资 lane 清空未获确认"))
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
