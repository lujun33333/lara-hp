import UIKit
import QuartzCore

// Target-specific, read-only minimum lane. Unproven controls remain unsupported.
final class CoreSetPlayerConsumer: CoreSetFeatureConsumer {
    typealias State = CoreSetPlayerSettings
    let capability = CoreSetCapability.playerRendering
    private weak var coordinator: CoreSetRuntimeCoordinator?
    private let session = CoreSetReadSession()
    private let grenadeMotion = CoreSetGrenadeMotionTracker()
    private let worker = DispatchQueue(label: "coreset.player.read", qos: .userInitiated)
    private var probe: Timer?
    private var refresh: Timer?
    private var inFlight = false
    private var stopped = false
    private var revision: UInt64 = 0
    private var settings = CoreSetPlayerSettings()
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

    init(coordinator: CoreSetRuntimeCoordinator) {
        self.coordinator = coordinator
        session.diagnosticLabel = "player"
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
    // These fields can be staged before the target starts; application still
    // requires the live read lease, canvas and matching renderer receipt.
    var configurableFields: Set<CoreSetField> {
        return [.actor(.player, .box), .actor(.player, .ray), .actor(.player, .distance),
                .actor(.player, .bones), .actor(.player, .weapon),
                .actor(.player, .count),
                .actor(.player, .information),
                .actor(.bot, .box), .actor(.bot, .ray),
                .actor(.bot, .distance), .actor(.bot, .bones), .actor(.bot, .weapon),
                .actor(.bot, .count),
                .actor(.bot, .information),
                .hideBots, .drawingDistance, .boneDistance,
                .backIndicator, .backStyle, .backSize, .grenadeWarning]
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
        func display(_ value: CoreSetActorDisplay) -> Bool {
            (value.weapon.enabled != true || value.weapon.mode == .text ||
                (value.weapon.mode == .image && CoreSetWeaponImageCatalog.isReady())) &&
            (value.count.enabled != true || value.count.mode != nil) &&
            (value.information.enabled != true || value.information.mode != nil)
        }
        return display(state.player) && display(state.bot) &&
            (state.backIndicator == nil || state.backIndicator == .off ||
             (state.backStyle != nil && state.backSize.value != nil))
    }

    func apply(_ request: CoreSetApplyRequest<State>,
               completion: @escaping (CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void) {
        precondition(Thread.isMainThread)
        guard !stopped, availability == .ready, accepts(request.desired),
              revision < UInt64.max else {
            let reason: String
            if case .unavailable(let detail) = availability { reason = detail }
            else { reason = "玩家显示模式、图片资源或背敌参数未完整选择，或会话已停止" }
            completion(request.token, .notApplied(reason: reason)); return
        }
        refresh?.invalidate(); refresh = nil
        revision += 1
        settings = request.desired
        if settings.grenadeWarning != true { _ = grenadeMotion.clear() }
        activeToken = request.token
        pendingApply = (request.token, completion)
        capture()
    }

    private func capture() {
        guard !stopped, !inFlight, let token = activeToken,
              let canvas = coordinator?.playerCanvas else { return }
        inFlight = true
        let expectedRevision = revision
        let playerBones = settings.player.bones == true
        let botBones = settings.bot.bones == true && settings.hideBots != true
        let boneDistanceLimit = Double(settings.boneDistance.value ?? 0)
        let maximumDrawDistance = Double(settings.drawingDistance.value ?? 0)
        let includeOffscreen = settings.backIndicator?.showIndicator == true
        // The collector reads a canonical ID for both modes; the name also serves as image fallback.
        let playerWeaponText = settings.player.weapon.enabled == true
        let botWeaponText = settings.bot.weapon.enabled == true &&
            settings.hideBots != true
        let includeGrenadeWarning = settings.grenadeWarning == true
        let includeCounts = settings.player.count.enabled == true || settings.bot.count.enabled == true
        let playerInformation = settings.player.information.enabled == true
        let botInformation = settings.bot.information.enabled == true && settings.hideBots != true
        worker.async { [weak self] in
            guard let self else { return }
            let failureSequence = self.session.readFailureSequence
            let snapshot = CoreSetPlayerCollector.capture(self.session, canvasSize: canvas.size,
                playerBones: playerBones, botBones: botBones, boneDistanceLimit: boneDistanceLimit,
                includeOffscreen: includeOffscreen, includeRadar: false,
                includeBattleInputs: false, playerWeaponText: playerWeaponText,
                botWeaponText: botWeaponText,
                includeGrenadeWarning: includeGrenadeWarning, includeCounts: includeCounts,
                playerInformation: playerInformation, botInformation: botInformation,
                includeWarningYaw: false, maximumDrawDistance: maximumDrawDistance)
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
                guard let snapshot,
                      snapshot.sessionGeneration == self.session.generation,
                      snapshot.processID == self.session.processID,
                      snapshot.imageBase == self.session.imageBase,
                      captureAge >= 0, captureAge <= 0.5 else {
                    if self.lastCaptureFailure != failureReason {
                        self.lastCaptureFailure = failureReason
                        NSLog("Core-SET: target-read lane=player stage=capture ready=0 reason=%@", failureReason)
                    }
                    self.clearStaleLane(token: token, reason: failureReason)
                    if let pending = self.pendingApply, pending.0 == token {
                        self.pendingApply = nil
                        pending.1(token, .unavailable(reason: "玩家快照未确认：\(failureReason)"))
                    }
                    self.coordinator?.refreshPlayerAvailability()
                    return
                }
                self.lastCaptureFailure = nil
                if includeGrenadeWarning {
                    self.grenadeMotion.decorate(snapshot, canvasSize: canvas.size,
                                                 nativeScale: Double(UIScreen.main.nativeScale))
                } else { _ = self.grenadeMotion.clear() }
                let id = UUID(uuidString: snapshot.snapshotID.uuidString) ?? UUID()
                guard let commands = self.render(snapshot, on: canvas.size) else {
                    self.clearStaleLane(token: token)
                    if let pending = self.pendingApply, pending.0 == token {
                        self.pendingApply = nil
                        pending.1(token, .failed(reason: "玩家绘制命令超出本地宿主上限"))
                    }
                    return
                }
                let input = CoreSetLaneSubmission(lane: .player, hostGeneration: canvas.generation,
                    configRevision: expectedRevision, snapshotID: id, requestToken: token,
                    canvasSize: canvas.size, commands: commands)
                guard self.coordinator?.submitLane(input) == true else {
                    self.clearStaleLane(token: token)
                    if let pending = self.pendingApply, pending.0 == token {
                        self.pendingApply = nil
                        pending.1(token, .failed(reason: "玩家帧未进入本地合成器"))
                    }
                    return
                }
                self.expectedSnapshot = id
                self.expectedGeneration = canvas.generation
                self.expectedSessionGeneration = snapshot.sessionGeneration
                self.expectedProcessID = snapshot.processID
                self.expectedImageBase = snapshot.imageBase
                self.expectedCapturedAt = snapshot.captureCompletedMonotonicSeconds
                self.expectedReadSemanticDiagnostic = snapshot.readSemanticDiagnostic +
                    " commands=\(commands.count) playerDistance=truncate-space-mi weaponImage=local-catalog rayGeometry=reference-top-native-scale headAnchor=known-requested-bone-or-root-plus90"
            }
        }
    }

    private func clearStaleLane(token: CoreSetRequestToken, reason: String = "player-frame-invalidated",
                                recordInvalidation: Bool = true) {
        _ = grenadeMotion.clear()
        guard let canvas = coordinator?.playerCanvas, revision < UInt64.max - 1 else { return }
        refresh?.invalidate(); refresh = nil
        revision += 1
        let id = UUID()
        if recordInvalidation && pendingApply == nil && pendingStop == nil && activeToken == token {
            pendingInvalidation = (token, id, canvas.generation, revision, reason)
        }
        let cleared = coordinator?.clearLane(.player, generation: canvas.generation,
            configRevision: revision, snapshotID: id, requestToken: token,
            canvasSize: canvas.size) == true
        if !cleared {
            pendingInvalidation = nil
            NSLog("Core-SET: target-read lane=player stage=clear-submission confirmed=0 reason=%@", reason)
        }
        revision += 1 // A future nonempty frame must exceed the clear revision.
    }

    private func render(_ snapshot: CoreSetPlayerSnapshot, on size: CGSize) -> [CoreSetRenderCommand]? {
        var result: [CoreSetRenderCommand] = []
        if settings.grenadeWarning == true {
            for mark in snapshot.grenadeMarks {
                let point = mark.point, distance = mark.distanceUnitsDividedBy100
                guard point.x.isFinite, point.y.isFinite, distance.isFinite,
                      distance >= 0, point.x >= 0, point.x <= size.width,
                      point.y >= 0, point.y <= size.height else { return nil }
                let text: String
                if let timer = mark.countdownSeconds?.doubleValue {
                    guard timer.isFinite, timer > 0, timer <= 10 else { return nil }
                    text = String(format: "手雷 %.1fs %.0fm", timer, distance)
                } else { text = String(format: "手雷 %.0fm", distance) }
                result.append(CoreSetRenderCommand(kind: .text,
                    rect: CGRect(x: point.x - 55, y: point.y - 10, width: 110, height: 20),
                    endpoint: .zero, color: .systemOrange, lineWidth: 0,
                    filled: false, text: text, fontSize: 14))
                for segment in mark.predictionSegments {
                    let start = segment.start, end = segment.end
                    guard [start.x, start.y, end.x, end.y].allSatisfy({ $0.isFinite }),
                          segment.lineWidth.isFinite, segment.shadowLineWidth.isFinite,
                          segment.lineWidth > 0, segment.shadowLineWidth > 0 else { return nil }
                    result.append(CoreSetRenderCommand(kind: .line,
                        rect: CGRect(origin: start, size: .zero), endpoint: end,
                        color: UIColor(red: 12 / 255, green: 12 / 255, blue: 16 / 255, alpha: 135 / 255),
                        lineWidth: CGFloat(segment.shadowLineWidth), filled: false, text: nil, fontSize: 12))
                    result.append(CoreSetRenderCommand(kind: .line,
                        rect: CGRect(origin: start, size: .zero), endpoint: end,
                        color: segment.color, lineWidth: CGFloat(segment.lineWidth), filled: false,
                        text: nil, fontSize: 12))
                }
                if mark.predictionEndpointPresent {
                    let end = mark.predictionEndpoint, scale = Double(UIScreen.main.nativeScale)
                    guard end.x.isFinite, end.y.isFinite, scale.isFinite, scale > 0 else { return nil }
                    let filledRadius = CGFloat(max(scale * 3.5, 3) / scale)
                    let ringRadius = CGFloat(max(scale * 6, 5) / scale)
                    result.append(CoreSetRenderCommand(kind: .ellipse,
                        rect: CGRect(x: end.x - filledRadius, y: end.y - filledRadius,
                                     width: filledRadius * 2, height: filledRadius * 2), endpoint: .zero,
                        color: UIColor(red: 1, green: 205 / 255, blue: 92 / 255, alpha: 230 / 255),
                        lineWidth: 0, filled: true, text: nil, fontSize: 12))
                    result.append(CoreSetRenderCommand(kind: .ellipse,
                        rect: CGRect(x: end.x - ringRadius, y: end.y - ringRadius,
                                     width: ringRadius * 2, height: ringRadius * 2), endpoint: .zero,
                        color: UIColor(red: 1, green: 120 / 255, blue: 72 / 255, alpha: 180 / 255),
                        lineWidth: CGFloat(max(scale * 1.3, 1) / scale), filled: false, text: nil, fontSize: 12))
                }
                if result.count > 8000 { return nil }
            }
        }
        if settings.player.count.enabled == true, let mode = settings.player.count.mode {
            let count = snapshot.observedPlayerCount
            result.append(CoreSetRenderCommand(kind: .text,
                rect: CGRect(x: size.width / 2 - 130, y: 14, width: 120, height: 22),
                endpoint: .zero, color: .systemRed, lineWidth: 0,
                filled: false, text: mode == .detailed ? "玩家 \(count)" : "\(count)", fontSize: 16))
        }
        if settings.bot.count.enabled == true, settings.hideBots != true,
           let mode = settings.bot.count.mode {
            let count = snapshot.observedBotCount
            result.append(CoreSetRenderCommand(kind: .text,
                rect: CGRect(x: size.width / 2 + 10, y: 14, width: 120, height: 22),
                endpoint: .zero, color: .systemYellow, lineWidth: 0,
                filled: false, text: mode == .detailed ? "人机 \(count)" : "\(count)", fontSize: 16))
        }
        for mark in snapshot.marks {
            if mark.bot && settings.hideBots == true { continue }
            let display = mark.bot ? settings.bot : settings.player
            let color = mark.bot ? UIColor.systemYellow : UIColor.systemRed
            let distanceRole: CoreSetRenderStyleRole = mark.bot ? .botDistance : .playerDistance
            if !mark.onScreen {
                guard let indicator = settings.backIndicator, indicator.showIndicator,
                      let style = settings.backStyle?.rawValue,
                      let glyphSize = settings.backSize.value,
                      let edge = offscreenEdge(mark.indicatorProjection, in: size,
                                               glyphSize: CGFloat(glyphSize)) else { continue }
                let width = CGFloat(glyphSize), height = width * 0.375
                let rect = CGRect(x: edge.point.x - width / 2, y: edge.point.y - height / 2,
                                  width: width, height: height)
                guard let glyph = CoreSetRenderCommand.backGlyph(style: style, rect: rect,
                                                                 angle: edge.angle, color: color) else { return nil }
                result.append(glyph)
                if indicator.showDistance {
                    result.append(CoreSetRenderCommand(kind: .text,
                        rect: CGRect(x: edge.point.x - 35, y: edge.point.y + height / 2 + 2,
                                     width: 70, height: 18), endpoint: .zero, color: color,
                        lineWidth: 0, filled: false,
                        text: String(format: "%.0fm", mark.distanceUnitsDividedBy100), fontSize: 12)
                        .styled(role: distanceRole))
                }
                if result.count > 8000 { return nil }
                continue
            }
            let head = mark.head, feet = mark.feet, center = mark.center
            guard [head.x, head.y, feet.x, feet.y, center.x, center.y].allSatisfy({ $0.isFinite }),
                  head.x >= 0, head.x <= size.width, feet.x >= 0, feet.x <= size.width,
                  head.y >= 0, head.y <= size.height, feet.y >= 0, feet.y <= size.height else { continue }
            let height = abs(feet.y - head.y)
            guard height >= 2, height <= size.height else { continue }
            if display.box == true {
                let width = height / 2 // Local geometry; no claim of original box-style parity.
                let box = CGRect(x: (head.x + feet.x) / 2 - width / 2,
                                 y: min(head.y, feet.y), width: width, height: height)
                result.append(CoreSetRenderCommand(kind: .rectangle, rect: box,
                    endpoint: .zero, color: color, lineWidth: 1, filled: false,
                    text: nil, fontSize: 12))
            }
            if display.ray == true {
                var origin = CGPoint.zero, endpoint = CGPoint.zero
                guard CoreSetReferencePlayerRay(size, Double(UIScreen.main.nativeScale), head,
                                                &origin, &endpoint) else { return nil }
                result.append(CoreSetRenderCommand(kind: .line,
                    rect: CGRect(origin: origin, size: .zero),
                    endpoint: endpoint, color: color, lineWidth: 1, filled: false,
                    text: nil, fontSize: 12)
                    .styled(role: mark.bot ? .botRay : .playerRay))
            }
            if display.distance == true {
                guard let text = CoreSetReferencePlayerDistanceText(mark.distanceUnitsDividedBy100) else { return nil }
                result.append(CoreSetRenderCommand(kind: .text,
                    rect: CGRect(x: feet.x - 40, y: feet.y + 2, width: 80, height: 20),
                    endpoint: .zero, color: color, lineWidth: 0, filled: false,
                    text: text, fontSize: 12)
                    .styled(role: distanceRole))
            }
            if display.weapon.enabled == true && display.weapon.mode == .text,
               let name = mark.weaponName, !name.isEmpty {
                result.append(CoreSetRenderCommand(kind: .text,
                    rect: CGRect(x: head.x - 65, y: min(head.y, feet.y) - 20,
                                 width: 130, height: 18), endpoint: .zero,
                    color: color, lineWidth: 0, filled: false,
                    text: name, fontSize: 12))
            }
            if display.weapon.enabled == true && display.weapon.mode == .image {
                let rect = CGRect(x: head.x - 20, y: min(head.y, feet.y) - 20,
                                  width: 40, height: 20)
                if let image = CoreSetRenderCommand.weaponImage(id: mark.weaponID, rect: rect) {
                    result.append(image)
                } else if let name = mark.weaponName, !name.isEmpty {
                    result.append(CoreSetRenderCommand(kind: .text,
                        rect: CGRect(x: head.x - 65, y: min(head.y, feet.y) - 20,
                                     width: 130, height: 18), endpoint: .zero,
                        color: color, lineWidth: 0, filled: false, text: name, fontSize: 12))
                }
            }
            if display.information.enabled == true, let mode = display.information.mode,
               let name = mark.playerName, !name.isEmpty,
               mark.distanceUnitsDividedBy100.isFinite {
                let detail: String
                if mode == .modern {
                    let weapon = mark.weaponName.map { " · \($0)" } ?? ""
                    detail = String(format: " · %.0f/%.0f HP · %.0fm%@",
                                    Double(mark.health), Double(mark.maximumHealth),
                                    mark.distanceUnitsDividedBy100, weapon)
                } else {
                    detail = String(format: " · %.0fm", mark.distanceUnitsDividedBy100)
                }
                // Three text commands preserve independent name/team color roles.
                // Their local text layout is not claimed as native ImGui parity.
                let teamText = "[\(mark.teamID)] "
                let font = UIFont.systemFont(ofSize: 12)
                let attributes: [NSAttributedString.Key: Any] = [.font: font]
                let teamWidth = min(CGFloat(45), max(CGFloat(24),
                    ceil((teamText as NSString).size(withAttributes: attributes).width) + 4))
                let nameWidth = min(CGFloat(120), max(CGFloat(20),
                    ceil((name as NSString).size(withAttributes: attributes).width) + 4))
                let originX = head.x - 130, originY = min(head.y, feet.y) - 43
                let teamRole: CoreSetRenderStyleRole = mark.bot ? .botTeam : .playerTeam
                let nameRole: CoreSetRenderStyleRole = mark.bot ? .botName : .playerName
                result.append(CoreSetRenderCommand(kind: .text,
                    rect: CGRect(x: originX, y: originY, width: teamWidth, height: 20),
                    endpoint: .zero, color: color, lineWidth: 0, filled: false,
                    text: teamText, fontSize: 12).styled(role: teamRole))
                result.append(CoreSetRenderCommand(kind: .text,
                    rect: CGRect(x: originX + teamWidth, y: originY, width: nameWidth, height: 20),
                    endpoint: .zero, color: color, lineWidth: 0, filled: false,
                    text: name, fontSize: 12).styled(role: nameRole))
                let detailWidth = CGFloat(260) - teamWidth - nameWidth
                if detailWidth > 0 {
                    result.append(CoreSetRenderCommand(kind: .text,
                        rect: CGRect(x: originX + teamWidth + nameWidth, y: originY,
                                     width: detailWidth, height: 20), endpoint: .zero,
                        color: color, lineWidth: 0, filled: false,
                        text: detail, fontSize: 12))
                }
            }
            let withinBoneDistance = settings.boneDistance.value.map {
                mark.distanceUnitsDividedBy100 <= Double($0)
            } ?? true
            if display.bones == true && withinBoneDistance {
                for segment in mark.boneSegments {
                    let start = segment.start, end = segment.end
                    guard [start.x, start.y, end.x, end.y].allSatisfy({ $0.isFinite }) else { return nil }
                    result.append(CoreSetRenderCommand(kind: .line,
                        rect: CGRect(origin: start, size: .zero), endpoint: end,
                        color: color, lineWidth: 1, filled: false, text: nil, fontSize: 12)
                        .styled(role: mark.bot ? .botBone : .playerBone))
                }
            }
            if result.count > 8000 { return nil } // Never submit a partial draw list.
        }
        return result
    }

    private func offscreenEdge(_ projected: CGPoint, in size: CGSize,
                               glyphSize: CGFloat) -> (point: CGPoint, angle: CGFloat)? {
        guard projected.x.isFinite, projected.y.isFinite, glyphSize.isFinite,
              glyphSize >= 40, glyphSize <= 160 else { return nil }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = projected.x - center.x, dy = projected.y - center.y
        guard abs(dx) > 0.000001 || abs(dy) > 0.000001 else { return nil }
        let margin = max(glyphSize * 1.25, 60)
        let limitX = max(1, center.x - min(center.x - 1, margin))
        let limitY = max(1, center.y - min(center.y - 1, margin))
        let factor = min(limitX / max(abs(dx), 0.000001),
                         limitY / max(abs(dy), 0.000001))
        let point = CGPoint(x: center.x + dx * factor, y: center.y + dy * factor)
        let angle = atan2(dy, dx) + .pi
        guard point.x.isFinite, point.y.isFinite, angle.isFinite else { return nil }
        return (point, angle)
    }

    func consumed(_ receipt: CoreSetLocalFrameReceipt) {
        guard receipt.lane == .player else { return }
        if let invalidation = pendingInvalidation,
           receipt.requestToken == invalidation.token, receipt.snapshotID == invalidation.snapshot,
           receipt.hostGeneration == invalidation.generation, receipt.configRevision == invalidation.revision {
            pendingInvalidation = nil
            guard pendingApply == nil, pendingStop == nil, activeToken == invalidation.token else { return }
            activeToken = nil
            coordinator?.invalidateReadFrameObservation(capability,
                reason: receipt.acceptedByLocalRenderer ? invalidation.reason : "player-clear-renderer-rejected")
            return
        }
        if let stop = pendingStop, stop.0 == receipt.requestToken,
           receipt.configRevision == revision, receipt.snapshotID == expectedSnapshot,
           receipt.hostGeneration == expectedGeneration {
            pendingStop = nil; expectedSnapshot = nil; expectedGeneration = nil
            stop.1(stop.0, receipt.acceptedByLocalRenderer ? .restored : .failed(reason: "玩家 lane 清空未获回执"))
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
                let reason = identityMatches ? "snapshot-stale stage=receipt" : "player-receipt-identity-lost"
                NSLog("Core-SET: target-read lane=player stage=receipt confirmed=0 reason=%@", reason)
                clearStaleLane(token: pending.0, reason: reason, recordInvalidation: false)
                pending.1(pending.0, .unavailable(reason: reason))
                return
            }
            if receipt.acceptedByLocalRenderer {
                logReadSemanticReceipt(receipt)
                pending.1(pending.0, .applied(observed: settings))
                refresh?.invalidate()
                refresh = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.capture() }
            } else {
                pending.1(pending.0, .failed(reason: "玩家帧未被本地渲染器消费"))
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
                    reason: !identityMatches ? "player-receipt-identity-lost" :
                        (!fresh ? "snapshot-stale stage=receipt" : "player-renderer-rejected"))
            } else { logReadSemanticReceipt(receipt) }
        } else if activeToken == receipt.requestToken && availability != .ready {
            clearStaleLane(token: receipt.requestToken, reason: "player-receipt-session-unavailable")
        }
    }

    private func logReadSemanticReceipt(_ receipt: CoreSetLocalFrameReceipt) {
        guard let diagnostic = expectedReadSemanticDiagnostic else { return }
        let now = CACurrentMediaTime()
        guard lastSemanticLogRevision != receipt.configRevision || now - lastSemanticLogAt >= 30 else { return }
        lastSemanticLogRevision = receipt.configRevision; lastSemanticLogAt = now
        NSLog("Core-SET: read-semantic lane=player stage=receipt confirmed=1 evidence=local-renderer-frame parity=partial session=%llu pid=%d host=%llu revision=%llu snapshot=%@ scope=%@",
              session.generation, session.processID, receipt.hostGeneration, receipt.configRevision,
              receipt.snapshotID.uuidString, diagnostic)
    }

    func stop(_ token: CoreSetRequestToken,
              completion: @escaping (CoreSetRequestToken, CoreSetStopOutcome) -> Void) {
        precondition(Thread.isMainThread)
        let clean = shutdownReadSession()
        guard clean else {
            completion(token, .failed(reason: "目标只读会话清理未确认")); return
        }
        guard revision < UInt64.max else {
            completion(token, .failed(reason: "玩家配置序号耗尽")); return
        }
        revision += 1
        if let canvas = coordinator?.playerCanvas {
            let id = UUID()
            expectedSnapshot = id; expectedGeneration = canvas.generation
            pendingStop = (token, completion)
            if coordinator?.clearLane(.player, generation: canvas.generation,
                configRevision: revision, snapshotID: id, requestToken: token,
                canvasSize: canvas.size) == true { return }
            pendingStop = nil
        }
        completion(token, coordinator?.lastStopResult?.complete.boolValue == true
            ? .restored : .failed(reason: "玩家 lane 清空未获确认"))
    }

    @discardableResult
    func shutdownReadSession() -> Bool {
        precondition(Thread.isMainThread)
        stopped = true
        probe?.invalidate(); probe = nil
        refresh?.invalidate(); refresh = nil
        activeToken = nil; pendingApply = nil
        expectedReadSemanticDiagnostic = nil
        let motionClean = grenadeMotion.clear()
        CoreSetWeaponImageCatalog.stop()
        let cleanup = worker.sync { session.disconnect() } // Drain queued connects/captures first.
        return motionClean && cleanup.complete
    }
}
