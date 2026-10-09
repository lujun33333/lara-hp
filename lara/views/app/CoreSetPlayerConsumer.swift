import UIKit
import QuartzCore

// Target-specific, read-only minimum lane. Unproven controls remain unsupported.
final class CoreSetPlayerConsumer: CoreSetFeatureConsumer {
    typealias State = CoreSetPlayerSettings
    let capability = CoreSetCapability.playerRendering
    private weak var coordinator: CoreSetRuntimeCoordinator?
    private let session = CoreSetReadSession()
    private let geometrySession = CoreSetReadSession()
    private let presentationSession = CoreSetReadSession()
    private let grenadeMotion = CoreSetGrenadeMotionTracker()
    private let worker = DispatchQueue(label: "coreset.player.read", qos: .userInitiated)
    private let geometryWorker = DispatchQueue(label: "coreset.player.geometry", qos: .userInteractive)
    private let presentationWorker = DispatchQueue(label: "coreset.player.presentation", qos: .userInteractive)
    private var probe: Timer?
    private var refresh: Timer?
    private var presentationTimer: DispatchSourceTimer?
    private let presentationTickLock = NSLock()
    private var presentationTickQueued = false
    private var inFlight = false
    private var geometryInFlight = false
    private var presentationInFlight = false
    private var currentRoster: CoreSetPlayerSnapshot?
    private var currentGeometry: CoreSetPlayerSnapshot?
    private var lastFullCaptureStartedAt: Double = 0
    private var lastGeometrySubmittedAt: Double?
    private var lastGeometryReceiptAt: Double?
    private var geometryExpired = false
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
    private var expectedCompletedAt: Double?
    private var lastCaptureFailure: String?
    private var captureFailureStartedAt: Double?
    private var captureLaneClearedForFailure = false
    private var awaitingReceipt = false
    private var awaitingReceiptSince: Double?
    private var activeSessionGeneration: UInt64?
    private var activeProcessID: Int32?
    private var activeImageBase: UInt64?
    private var expectedReadSemanticDiagnostic: String?
    private var lastSemanticLogAt: Double = 0
    private var lastSemanticLogRevision: UInt64?
    private var presentationReceiptWindowStartedAt: Double?
    private var presentationReceiptCount = 0
    private var pendingInvalidation: (token: CoreSetRequestToken, snapshot: UUID,
        generation: UInt64, revision: UInt64, reason: String)?

    init(coordinator: CoreSetRuntimeCoordinator) {
        self.coordinator = coordinator
        session.diagnosticLabel = "player"
        geometrySession.diagnosticLabel = "player-geometry"
        presentationSession.diagnosticLabel = "player-presentation"
        NSLog("Core-SET: player-loop contract=latest-snapshot-v9 interval=0.15 presentationInterval=0.016 presentationClock=dispatch-source rosterRetry=0.15 rosterRefresh=1.0 firstFrame=full-capture geometry=independent-camera-root-reprojection presentation=current-camera-cached-world-reprojection configurationApply=immediate renderEvidence=separate")
        probe = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.probeTarget() }
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
        guard !stopped, !session.ready || !geometrySession.ready || !presentationSession.ready else { return }
        worker.async { [weak self] in
            guard let self else { return }
            if !self.session.ready { _ = self.session.connect() }
            if !self.geometrySession.ready { _ = self.geometrySession.connect() }
            if !self.presentationSession.ready { _ = self.presentationSession.connect() }
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
        presentationTimer?.cancel(); presentationTimer = nil
        revision += 1
        settings = request.desired
        if settings.grenadeWarning != true { _ = grenadeMotion.clear() }
        activeToken = request.token
        activeSessionGeneration = session.generation
        activeProcessID = session.processID
        activeImageBase = session.imageBase
        captureFailureStartedAt = nil
        captureLaneClearedForFailure = false
        awaitingReceipt = false
        awaitingReceiptSince = nil
        expectedSnapshot = nil
        expectedGeneration = nil
        expectedSessionGeneration = nil
        expectedProcessID = nil
        expectedImageBase = nil
        expectedCompletedAt = nil
        expectedReadSemanticDiagnostic = nil
        // Core v1.7 stores UI choices directly in its shared configuration and
        // lets the frame loop consume the newest value.  Configuration is not
        // held behind the presence of an on-screen actor or a renderer receipt;
        // those receipts remain separate evidence of an actual drawn frame.
        pendingApply = nil
        completion(request.token, .applied(observed: settings))
        armCaptureLoop()
        armPresentationLoop()
        tick()
    }

    private func armCaptureLoop() {
        precondition(Thread.isMainThread)
        guard !stopped, activeToken != nil, refresh == nil else { return }
        refresh = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func armPresentationLoop() {
        precondition(Thread.isMainThread)
        guard !stopped, activeToken != nil, presentationTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: presentationWorker)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16),
                       leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.enqueuePresentationTick() }
        presentationTimer = timer
        timer.resume()
    }

    private func enqueuePresentationTick() {
        presentationTickLock.lock()
        guard !presentationTickQueued else {
            presentationTickLock.unlock()
            return
        }
        presentationTickQueued = true
        presentationTickLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presentationTickLock.lock()
            self.presentationTickQueued = false
            self.presentationTickLock.unlock()
            self.refreshPresentation()
        }
    }

    private func tick() {
        precondition(Thread.isMainThread)
        guard !stopped, activeToken != nil else { return }
        expireGeometryIfNeeded()
        if currentRoster != nil { refreshGeometry() }
        // Root reads can fail transiently on the mapped transport. Until a
        // usable roster exists, retry at the render tick instead of reducing
        // the only producer to one attempt per second. Once a roster exists,
        // the independent geometry lane owns the fast path and enrichment can
        // return to the slower cadence.
        let fullCaptureInterval = currentRoster == nil ? 0.15 : 1.0
        if !inFlight, CACurrentMediaTime() - lastFullCaptureStartedAt >= fullCaptureInterval { capture() }
    }

    private var activeSessionMatches: Bool {
        session.ready && session.generation == activeSessionGeneration &&
            session.processID == activeProcessID && session.imageBase == activeImageBase
    }

    private var expectedReadIdentityMatches: Bool {
        let matches: (CoreSetReadSession) -> Bool = { candidate in
            candidate.ready && candidate.generation == self.expectedSessionGeneration &&
                candidate.processID == self.expectedProcessID &&
                candidate.imageBase == self.expectedImageBase
        }
        // A complete capture is submitted by the primary session; refreshed
        // geometry is submitted by the secondary session. A renderer receipt
        // is valid when either live owner still matches the exact snapshot
        // identity, so the first frame never depends on the secondary owner.
        return matches(session) || matches(geometrySession) || matches(presentationSession)
    }

    private func finishUnavailable(_ reason: String, token: CoreSetRequestToken) {
        precondition(Thread.isMainThread)
        refresh?.invalidate(); refresh = nil
        presentationTimer?.cancel(); presentationTimer = nil
        awaitingReceipt = false
        awaitingReceiptSince = nil
        currentRoster = nil; currentGeometry = nil
        lastGeometrySubmittedAt = nil; lastGeometryReceiptAt = nil
        geometryExpired = false
        let pending = pendingApply
        pendingApply = nil
        clearStaleLane(token: token, reason: reason)
        if let pending, pending.0 == token {
            pending.1(token, .unavailable(reason: reason))
        }
        coordinator?.refreshPlayerAvailability()
    }

    private func retryCapture(_ reason: String, token: CoreSetRequestToken) {
        precondition(Thread.isMainThread)
        guard activeSessionMatches else {
            finishUnavailable("player-active-session-changed: \(reason)", token: token)
            return
        }
        let now = CACurrentMediaTime()
        if lastCaptureFailure != reason {
            lastCaptureFailure = reason
            NSLog("Core-SET: target-read lane=player stage=capture ready=0 retrying=1 reason=%@", reason)
        }
        if captureFailureStartedAt == nil { captureFailureStartedAt = now }
        if currentRoster == nil, !captureLaneClearedForFailure,
           now - (captureFailureStartedAt ?? now) >= 0.5 {
            captureLaneClearedForFailure = true
            clearStaleLane(token: token, reason: reason,
                           recordInvalidation: false, preserveRefresh: true)
        }
        armCaptureLoop()
        armPresentationLoop()
        coordinator?.refreshPlayerAvailability()
    }

    private var requiresRenderableEvidence: Bool {
        settings.player.box == true || settings.player.ray == true ||
        settings.player.distance == true || settings.player.bones == true ||
        settings.player.weapon.enabled == true || settings.player.count.enabled == true ||
        settings.player.information.enabled == true ||
        (settings.hideBots != true && (settings.bot.box == true || settings.bot.ray == true ||
            settings.bot.distance == true || settings.bot.bones == true ||
            settings.bot.weapon.enabled == true || settings.bot.count.enabled == true ||
            settings.bot.information.enabled == true)) ||
        settings.backIndicator?.showIndicator == true || settings.grenadeWarning == true
    }

    private func expireGeometryIfNeeded() {
        guard let token = activeToken, let canvas = coordinator?.playerCanvas else { return }
        let now = CACurrentMediaTime()
        if awaitingReceipt, let since = awaitingReceiptSince, now - since >= 0.5 {
            awaitingReceipt = false; awaitingReceiptSince = nil
            expectedSnapshot = nil; expectedGeneration = nil
            expectedSessionGeneration = nil; expectedProcessID = nil; expectedImageBase = nil
            expectedCompletedAt = nil; expectedReadSemanticDiagnostic = nil
        }
        let freshest = lastGeometryReceiptAt ?? lastGeometrySubmittedAt
        guard requiresRenderableEvidence, !geometryExpired, let freshest,
              now - freshest >= 0.5 else { return }
        let id = UUID()
        let empty = CoreSetLaneSubmission(lane: .player, hostGeneration: canvas.generation,
            configRevision: revision, snapshotID: id, requestToken: token,
            canvasSize: canvas.size, commands: [])
        if coordinator?.submitLane(empty) == true {
            geometryExpired = true
            NSLog("Core-SET: target-read lane=player stage=geometry-expired age=%.3f action=empty-lane",
                  now - freshest)
        }
    }

    private func refreshGeometry() {
        guard !stopped, !geometryInFlight,
              let roster = currentGeometry ?? currentRoster, let token = activeToken,
              let canvas = coordinator?.playerCanvas else { return }
        guard geometrySession.ready,
              geometrySession.processID == roster.processID,
              geometrySession.imageBase == roster.imageBase else {
            probeTarget(); return
        }
        geometryInFlight = true
        let expectedRevision = revision
        let rosterID = roster.snapshotID
        let includeOffscreen = settings.backIndicator?.showIndicator == true
        let maximumDrawDistance = Double(settings.drawingDistance.value ?? 0)
        geometryWorker.async { [weak self] in
            guard let self else { return }
            let snapshot = CoreSetPlayerCollector.refreshGeometry(for: roster,
                session: self.geometrySession, canvasSize: canvas.size,
                includeOffscreen: includeOffscreen,
                maximumDrawDistance: maximumDrawDistance)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.geometryInFlight = false
                guard !self.stopped, self.activeToken == token,
                      self.revision == expectedRevision,
                      (self.currentGeometry ?? self.currentRoster)?.snapshotID == rosterID,
                      let currentCanvas = self.coordinator?.playerCanvas,
                      currentCanvas.generation == canvas.generation,
                      currentCanvas.size == canvas.size,
                      let snapshot else { return }
                self.currentGeometry = snapshot
                if !self.awaitingReceipt {
                    self.submitGeometry(snapshot, token: token, revision: expectedRevision,
                                        canvas: currentCanvas)
                }
            }
        }
    }

    private func refreshPresentation() {
        precondition(Thread.isMainThread)
        guard !stopped, !presentationInFlight, !awaitingReceipt,
              let geometry = currentGeometry ?? currentRoster, let token = activeToken,
              let canvas = coordinator?.playerCanvas else { return }
        guard presentationSession.ready,
              presentationSession.processID == geometry.processID,
              presentationSession.imageBase == geometry.imageBase else {
            probeTarget(); return
        }
        presentationInFlight = true
        let expectedRevision = revision
        let geometryID = geometry.snapshotID
        let includeOffscreen = settings.backIndicator?.showIndicator == true
        let maximumDrawDistance = Double(settings.drawingDistance.value ?? 0)
        presentationWorker.async { [weak self] in
            guard let self else { return }
            let snapshot = CoreSetPlayerCollector.reprojectPresentation(for: geometry,
                session: self.presentationSession, canvasSize: canvas.size,
                includeOffscreen: includeOffscreen,
                maximumDrawDistance: maximumDrawDistance)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.presentationInFlight = false
                guard !self.stopped, !self.awaitingReceipt,
                      self.activeToken == token, self.revision == expectedRevision,
                      (self.currentGeometry ?? self.currentRoster)?.snapshotID == geometryID,
                      let currentCanvas = self.coordinator?.playerCanvas,
                      currentCanvas.generation == canvas.generation,
                      currentCanvas.size == canvas.size,
                      let snapshot else { return }
                self.submitGeometry(snapshot, token: token, revision: expectedRevision,
                                    canvas: currentCanvas)
            }
        }
    }

    private func submitGeometry(_ snapshot: CoreSetPlayerSnapshot, token: CoreSetRequestToken,
                                revision expectedRevision: UInt64,
                                canvas: (generation: UInt64, size: CGSize)) {
        precondition(Thread.isMainThread)
        guard !awaitingReceipt else { return }
        if settings.grenadeWarning == true {
            grenadeMotion.decorate(snapshot, canvasSize: canvas.size,
                                    nativeScale: Double(UIScreen.main.nativeScale))
        } else { _ = grenadeMotion.clear() }
        let id = UUID(uuidString: snapshot.snapshotID.uuidString) ?? UUID()
        guard let commands = render(snapshot, on: canvas.size) else { return }
        guard !requiresRenderableEvidence || !commands.isEmpty else { return }
        let input = CoreSetLaneSubmission(lane: .player, hostGeneration: canvas.generation,
            configRevision: expectedRevision, snapshotID: id, requestToken: token,
            canvasSize: canvas.size, commands: commands)
        guard coordinator?.submitLane(input) == true else { return }
        expectedSnapshot = id; expectedGeneration = canvas.generation
        expectedSessionGeneration = snapshot.sessionGeneration
        expectedProcessID = snapshot.processID; expectedImageBase = snapshot.imageBase
        expectedCompletedAt = snapshot.captureCompletedMonotonicSeconds
        expectedReadSemanticDiagnostic = snapshot.readSemanticDiagnostic +
            " commands=\(commands.count) playerDistance=truncate-space-mi weaponImage=local-catalog rayGeometry=reference-top-native-scale headAnchor=current-bone-world-or-root-plus90 informationLayout=core17-simple-modern-name-health informationAnchor=core17-record-first-projection informationScale=core17-frame-literal-1 informationBotOrdinal=core17-frame-local-counter gradient=core17-horizontal-four-vertex informationIcoMoon=not-consumed"
        awaitingReceipt = true; awaitingReceiptSince = CACurrentMediaTime()
        lastGeometrySubmittedAt = CACurrentMediaTime()
        geometryExpired = false
    }

    private func capture() {
        guard !stopped, !inFlight, let token = activeToken,
              let canvas = coordinator?.playerCanvas else { return }
        guard activeSessionMatches else {
            finishUnavailable("player-active-session-changed-before-capture", token: token)
            return
        }
        inFlight = true
        lastFullCaptureStartedAt = CACurrentMediaTime()
        let expectedRevision = revision
        let playerBones = settings.player.bones == true
        let botBones = settings.bot.bones == true && settings.hideBots != true
        let boneDistanceLimit = Double(settings.boneDistance.value ?? 0)
        let maximumDrawDistance = Double(settings.drawingDistance.value ?? 0)
        // The slow roster must retain enemies that are currently outside the
        // viewport so the fast camera pass can bring them on-screen instantly.
        let includeOffscreen = true
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
                : "\(CoreSetPlayerCollector.lastCaptureDiagnostic()) transport-errors=0"
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight = false
                guard !self.stopped, self.activeToken == token,
                      self.revision == expectedRevision,
                      let currentCanvas = self.coordinator?.playerCanvas,
                      currentCanvas.generation == canvas.generation,
                      currentCanvas.size == canvas.size else { return }
                let captureAge = snapshot.map { CACurrentMediaTime() - $0.captureCompletedMonotonicSeconds } ?? .nan
                let failureReason = snapshot != nil && !(0...0.5).contains(captureAge)
                    ? String(format: "snapshot-stale stage=capture ageSeconds=%.3f limit=0.5", captureAge)
                    : captureFailure
                guard let snapshot,
                      snapshot.sessionGeneration == self.session.generation,
                      snapshot.processID == self.session.processID,
                      snapshot.imageBase == self.session.imageBase,
                      captureAge >= 0, captureAge <= 0.5 else {
                    if self.activeToken == token, self.revision == expectedRevision {
                        self.retryCapture(failureReason, token: token)
                    }
                    return
                }
                self.lastCaptureFailure = nil
                self.captureFailureStartedAt = nil
                self.captureLaneClearedForFailure = false
                self.currentRoster = snapshot
                self.currentGeometry = snapshot
                self.geometryExpired = false
                // Publish the complete capture immediately. The renderer must
                // never depend on a second read session succeeding before the
                // first valid frame becomes visible. Subsequent ticks replace
                // this with current camera/root geometry when available.
                self.submitGeometry(snapshot, token: token, revision: expectedRevision,
                                    canvas: currentCanvas)
            }
        }
    }

    private func clearStaleLane(token: CoreSetRequestToken, reason: String = "player-frame-invalidated",
                                recordInvalidation: Bool = true, preserveRefresh: Bool = false) {
        _ = grenadeMotion.clear()
        guard let canvas = coordinator?.playerCanvas, revision < UInt64.max - 1 else { return }
        if !preserveRefresh {
            refresh?.invalidate(); refresh = nil
            presentationTimer?.cancel(); presentationTimer = nil
        }
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
            grenadeLoop: for mark in snapshot.grenadeMarks {
                let point = mark.point, distance = mark.distanceUnitsDividedBy100
                guard point.x.isFinite, point.y.isFinite, distance.isFinite,
                      distance >= 0, point.x >= 0, point.x <= size.width,
                      point.y >= 0, point.y <= size.height else { continue }
                let text: String
                if let timer = mark.countdownSeconds?.doubleValue {
                    guard timer.isFinite, timer > 0, timer <= 10 else { continue }
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
                          segment.lineWidth > 0, segment.shadowLineWidth > 0 else { continue }
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
                    if end.x.isFinite, end.y.isFinite, scale.isFinite, scale > 0 {
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
                }
                if result.count > 8000 { break grenadeLoop }
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
        // Core resets the accepted player/bot counters at 0x1000db190 and
        // 0x1000db198 for every draw pass, then increments the matching counter
        // before consuming the information branch (0x1000dbb54..dbb64).  Keep
        // the bot ordinal frame-local instead of persisting it in the roster.
        var botInformationFrameOrdinal = 0
        for mark in snapshot.marks {
            if mark.bot && settings.hideBots == true { continue }
            if mark.bot { botInformationFrameOrdinal += 1 }
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
                                                                 angle: edge.angle, color: color) else { continue }
                result.append(glyph)
                if indicator.showDistance {
                    result.append(CoreSetRenderCommand(kind: .text,
                        rect: CGRect(x: edge.point.x - 35, y: edge.point.y + height / 2 + 2,
                                     width: 70, height: 18), endpoint: .zero, color: color,
                        lineWidth: 0, filled: false,
                        text: String(format: "%.0fm", mark.distanceUnitsDividedBy100), fontSize: 12)
                        .styled(role: distanceRole))
                }
                if result.count > 8000 { break }
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
                if CoreSetReferencePlayerRay(size, Double(UIScreen.main.nativeScale), head,
                                             &origin, &endpoint) {
                    result.append(CoreSetRenderCommand(kind: .line,
                        rect: CGRect(origin: origin, size: .zero),
                        endpoint: endpoint, color: color, lineWidth: 1, filled: false,
                        text: nil, fontSize: 12)
                        .styled(role: mark.bot ? .botRay : .playerRay))
                }
            }
            if display.distance == true {
                if let text = CoreSetReferencePlayerDistanceText(mark.distanceUnitsDividedBy100) {
                    result.append(CoreSetRenderCommand(kind: .text,
                        rect: CGRect(x: feet.x - 40, y: feet.y + 2, width: 80, height: 20),
                        endpoint: .zero, color: color, lineWidth: 0, filled: false,
                        text: text, fontSize: 12)
                        .styled(role: distanceRole))
                }
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
               mark.informationAnchorPresent {
                _ = appendCoreInformation(for: mark, mode: mode,
                                          anchor: mark.informationAnchor,
                                          botFrameOrdinal: botInformationFrameOrdinal,
                                          commands: &result)
            }
            let withinBoneDistance = settings.boneDistance.value.map {
                mark.distanceUnitsDividedBy100 <= Double($0)
            } ?? true
            if display.bones == true && withinBoneDistance {
                for segment in mark.boneSegments {
                    let start = segment.start, end = segment.end
                    guard [start.x, start.y, end.x, end.y].allSatisfy({ $0.isFinite }) else { continue }
                    result.append(CoreSetRenderCommand(kind: .line,
                        rect: CGRect(origin: start, size: .zero), endpoint: end,
                        color: color, lineWidth: 1, filled: false, text: nil, fontSize: 12)
                        .styled(role: mark.bot ? .botBone : .playerBone))
                }
            }
            if result.count > 8000 { break }
        }
        return result
    }

    // Core v1.7 0x1000dbca8..0x1000dc750 has two distinct information
    // layouts.  It does not concatenate HP, distance or weapon into the name
    // line: both branches render the name and a separate health bar.  The
    // frame owner stores the exact 0x3f800000 literal into the shared draw
    // context at 0x100021bb0..0x100021bb8.  The branch reads that producer at
    // draw-context +0x0, while its anchor is the first projected draw-record
    // point at record +0x30/+0x34 (0x1000dbca0..0x1000dbca4).  It is not the
    // midpoint of the first and second projected points.
    private func appendCoreInformation(for mark: CoreSetPlayerMark,
                                       mode: CoreSetInformationMode,
                                       anchor: CGPoint,
                                       botFrameOrdinal: Int,
                                       commands: inout [CoreSetRenderCommand]) -> Bool {
        let scale = coreInformationFrameScale()
        let anchorX = anchor.x
        let topY = anchor.y
        guard anchorX.isFinite, topY.isFinite else { return false }

        let rawName = mark.playerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name: String
        if mode == .minimal {
            name = rawName.isEmpty ? (mark.bot ? "人机" : "未知玩家") : rawName
        } else if mark.bot {
            name = rawName.isEmpty ? "人机\(botFrameOrdinal)【人机】" : "\(rawName)【人机】"
        } else {
            name = rawName.isEmpty ? "未知玩家" : rawName
        }
        let ratio = min(CGFloat(1), max(CGFloat(0), CGFloat(mark.health) / 100))
        let palette = coreInformationTeamColor(mark.teamID)
        let healthColor = coreInformationHealthColor(ratio, modern: mode == .modern)
        let teamRole: CoreSetRenderStyleRole = mark.bot ? .botTeam : .playerTeam
        let nameRole: CoreSetRenderStyleRole = mark.bot ? .botName : .playerName

        if mode == .minimal {
            let fontSize = 11 * scale
            guard let font = UIFont(name: "OPPOSans-H", size: fontSize) else { return false }
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let teamText = "\(mark.teamID)"
            let teamWidth = ceil((teamText as NSString).size(withAttributes: attributes).width)
            let nameSize = (name as NSString).size(withAttributes: attributes)
            let nameWidth = ceil(nameSize.width)
            let textHeight = ceil(max(font.lineHeight, nameSize.height))
            let totalWidth = teamWidth + 4 * scale + nameWidth
            let barWidth = max(54 * scale, totalWidth)
            guard [teamWidth, nameWidth, textHeight, totalWidth, barWidth].allSatisfy({ $0.isFinite }),
                  totalWidth > 0, barWidth > 0 else { return false }
            let textX = anchorX - totalWidth / 2
            let textY = topY - 24 * scale
            commands.append(CoreSetRenderCommand(kind: .text,
                rect: CGRect(x: textX, y: textY, width: teamWidth, height: textHeight),
                endpoint: .zero, color: palette, lineWidth: 0, filled: false,
                text: teamText, fontSize: fontSize).usingFont(.body))
            commands.append(CoreSetRenderCommand(kind: .text,
                rect: CGRect(x: textX + teamWidth + 4 * scale, y: textY,
                             width: nameWidth, height: textHeight),
                endpoint: .zero, color: .white, lineWidth: 0, filled: false,
                text: name, fontSize: fontSize).usingFont(.body).styled(role: nameRole))
            let barY = textY + textHeight + 2 * scale
            let barHeight = 2.5 * scale
            let barX = anchorX - barWidth / 2
            commands.append(CoreSetRenderCommand(kind: .rectangle,
                rect: CGRect(x: barX, y: barY, width: barWidth, height: barHeight),
                endpoint: .zero,
                color: UIColor(red: 35 / 255, green: 35 / 255, blue: 35 / 255, alpha: 190 / 255),
                lineWidth: 0, filled: true, text: nil, fontSize: fontSize)
                .rounded(radius: 1.25 * scale))
            if ratio > 0 {
                commands.append(CoreSetRenderCommand(kind: .rectangle,
                    rect: CGRect(x: barX, y: barY, width: barWidth * ratio, height: barHeight),
                    endpoint: .zero, color: healthColor, lineWidth: 0, filled: true,
                    text: nil, fontSize: fontSize).rounded(radius: 1.25 * scale))
            }
            return true
        }

        let fontSize = 12 * scale
        guard let font = UIFont(name: "OPPOSans-H", size: fontSize) else { return false }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let teamText = "\(mark.teamID)"
        let teamSize = (teamText as NSString).size(withAttributes: attributes)
        let nameSize = (name as NSString).size(withAttributes: attributes)
        let cardWidth = max(90 * scale, ceil(nameSize.width) + 37 * scale)
        guard [teamSize.width, teamSize.height, nameSize.width, nameSize.height, cardWidth]
            .allSatisfy({ $0.isFinite }), cardWidth > 18 * scale else { return false }
        let cardX = anchorX - cardWidth / 2
        let cardY = topY - 28 * scale
        let cardHeight = 18 * scale
        let badgeWidth = 18 * scale
        commands.append(CoreSetRenderCommand(kind: .rectangle,
            rect: CGRect(x: cardX, y: cardY, width: badgeWidth, height: cardHeight),
            endpoint: .zero, color: palette, lineWidth: 0, filled: true,
            text: nil, fontSize: fontSize).rounded(radius: 4 * scale))

        // Core 0x1000dc564..0x1000dc5f0 calls AddRectFilledMultiColor over the
        // 15-point name area. TL/BL use alpha 240; TR/BR use alpha 0. Because
        // each vertical pair is identical, the exact four-vertex payload is a
        // horizontal gradient in both local render backends.
        let gradientX = cardX + badgeWidth
        let gradientWidth = cardWidth - badgeWidth
        let gradientRGB = coreInformationGradientRGB(mark.teamID)
        let gradientLeft = UIColor(red: gradientRGB.0, green: gradientRGB.1,
                                   blue: gradientRGB.2, alpha: 240 / 255)
        let gradientRight = UIColor(red: gradientRGB.0, green: gradientRGB.1,
                                    blue: gradientRGB.2, alpha: 0)
        commands.append(CoreSetRenderCommand(kind: .rectangle,
            rect: CGRect(x: gradientX, y: cardY, width: gradientWidth, height: 15 * scale),
            endpoint: .zero, color: gradientLeft,
            lineWidth: 0, filled: true, text: nil, fontSize: fontSize)
            .horizontalGradient(from: gradientLeft, to: gradientRight))
        commands.append(CoreSetRenderCommand(kind: .text,
            rect: CGRect(x: cardX + (badgeWidth - teamSize.width) / 2,
                         y: cardY + (cardHeight - teamSize.height) / 2,
                         width: teamSize.width, height: max(font.lineHeight, teamSize.height)),
            endpoint: .zero, color: .white, lineWidth: 0, filled: false,
            text: teamText, fontSize: fontSize).usingFont(.body).styled(role: teamRole))
        let nameY = cardY + (15 * scale - nameSize.height) / 2
        commands.append(CoreSetRenderCommand(kind: .text,
            rect: CGRect(x: cardX + badgeWidth + 4 * scale, y: nameY,
                         width: nameSize.width, height: max(font.lineHeight, nameSize.height)),
            endpoint: .zero, color: .white, lineWidth: 0, filled: false,
            text: name, fontSize: fontSize).usingFont(.body).styled(role: nameRole))
        let healthX = gradientX
        let healthY = topY - 13 * scale
        let healthWidth = gradientWidth
        let healthHeight = 3 * scale
        commands.append(CoreSetRenderCommand(kind: .rectangle,
            rect: CGRect(x: healthX, y: healthY, width: healthWidth, height: healthHeight),
            endpoint: .zero,
            color: UIColor(red: 40 / 255, green: 40 / 255, blue: 40 / 255, alpha: 1),
            lineWidth: 0, filled: true, text: nil, fontSize: fontSize)
            .rounded(radius: 4 * scale))
        if ratio > 0 {
            commands.append(CoreSetRenderCommand(kind: .rectangle,
                rect: CGRect(x: healthX, y: healthY, width: healthWidth * ratio,
                             height: healthHeight), endpoint: .zero,
                color: healthColor, lineWidth: 0, filled: true,
                text: nil, fontSize: fontSize).rounded(radius: 4 * scale))
        }
        return true
    }

    private func coreInformationFrameScale() -> CGFloat {
        // ldr s0, [0x100bd8b20] / str s0, [context] is executed immediately
        // before frame_draw.  The identity-bound literal is IEEE-754 1.0.
        CGFloat(Float(bitPattern: 0x3f800000))
    }

    private func coreInformationTeamColor(_ teamID: UInt32) -> UIColor {
        // Exact eight-entry ImGui palette at Core image 0x100ac8678.
        let palette: [(CGFloat, CGFloat, CGFloat)] = [
            (255, 100, 100), (100, 200, 255), (100, 255, 100), (255, 200, 100),
            (255, 100, 255), (255, 255, 100), (100, 255, 200), (200, 100, 255),
        ]
        let value = palette[Int(teamID & 7)]
        return UIColor(red: value.0 / 255, green: value.1 / 255,
                       blue: value.2 / 255, alpha: 1)
    }

    private func coreInformationGradientRGB(_ teamID: UInt32) -> (CGFloat, CGFloat, CGFloat) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard coreInformationTeamColor(teamID).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        else { return (0.8, 0.8, 0.8) }
        return (floor(red * 255 * 0.8) / 255,
                floor(green * 255 * 0.8) / 255,
                floor(blue * 255 * 0.8) / 255)
    }

    private func coreInformationHealthColor(_ ratio: CGFloat, modern: Bool) -> UIColor {
        if modern {
            if ratio < 0.3 { return UIColor(red: 1, green: 50 / 255, blue: 1, alpha: 1) }
            if ratio < 0.7 { return UIColor(red: 1, green: 140 / 255, blue: 0, alpha: 1) }
            return .white
        }
        if ratio < 0.3 { return UIColor(red: 1, green: 58 / 255, blue: 58 / 255, alpha: 245 / 255) }
        if ratio < 0.7 { return UIColor(red: 1, green: 150 / 255, blue: 30 / 255, alpha: 245 / 255) }
        return UIColor(white: 245 / 255, alpha: 245 / 255)
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
            awaitingReceipt = false
            awaitingReceiptSince = nil
            let identityMatches = expectedReadIdentityMatches
            let fresh = expectedCompletedAt.map {
                CACurrentMediaTime() - $0 >= 0 && CACurrentMediaTime() - $0 <= 0.5
            } ?? false
            expectedSnapshot = nil; expectedGeneration = nil
            expectedSessionGeneration = nil; expectedProcessID = nil; expectedImageBase = nil
            expectedCompletedAt = nil
            guard identityMatches && fresh else {
                let reason = identityMatches ? "snapshot-stale stage=receipt" : "player-receipt-identity-lost"
                NSLog("Core-SET: target-read lane=player stage=receipt confirmed=0 reason=%@", reason)
                retryCapture(reason, token: pending.0)
                return
            }
            if receipt.acceptedByLocalRenderer {
                pendingApply = nil
                logReadSemanticReceipt(receipt)
                pending.1(pending.0, .applied(observed: settings))
            } else {
                pendingApply = nil
                refresh?.invalidate(); refresh = nil
                presentationTimer?.cancel(); presentationTimer = nil
                pending.1(pending.0, .failed(reason: "玩家帧未被本地渲染器消费"))
            }
            return
        }
        if activeToken == receipt.requestToken,
           receipt.configRevision == revision, receipt.snapshotID == expectedSnapshot,
           receipt.hostGeneration == expectedGeneration {
            awaitingReceipt = false
            awaitingReceiptSince = nil
            let identityMatches = expectedReadIdentityMatches
            let fresh = expectedCompletedAt.map {
                CACurrentMediaTime() - $0 >= 0 && CACurrentMediaTime() - $0 <= 0.5
            } ?? false
            if !identityMatches || !fresh {
                expectedSnapshot = nil; expectedGeneration = nil
                expectedSessionGeneration = nil; expectedProcessID = nil; expectedImageBase = nil
                expectedCompletedAt = nil
                retryCapture(!identityMatches ? "player-receipt-identity-lost" :
                    "snapshot-stale stage=receipt", token: receipt.requestToken)
            } else if !receipt.acceptedByLocalRenderer {
                clearStaleLane(token: receipt.requestToken,
                    reason: "player-renderer-rejected")
            } else {
                lastGeometryReceiptAt = CACurrentMediaTime()
                geometryExpired = false
                recordPresentationCadenceIfNeeded()
                logReadSemanticReceipt(receipt)
            }
        } else if activeToken == receipt.requestToken && availability != .ready {
            finishUnavailable("player-receipt-session-unavailable", token: receipt.requestToken)
        }
    }

    private func logReadSemanticReceipt(_ receipt: CoreSetLocalFrameReceipt) {
        guard let diagnostic = expectedReadSemanticDiagnostic else { return }
        let now = CACurrentMediaTime()
        guard lastSemanticLogRevision != receipt.configRevision || now - lastSemanticLogAt >= 30 else { return }
        lastSemanticLogRevision = receipt.configRevision; lastSemanticLogAt = now
        NSLog("Core-SET: read-semantic lane=player stage=receipt confirmed=1 evidence=local-renderer-frame parity=partial session=%llu pid=%d host=%llu revision=%llu snapshot=%@ scope=%@",
              geometrySession.generation, geometrySession.processID, receipt.hostGeneration, receipt.configRevision,
              receipt.snapshotID.uuidString, diagnostic)
    }

    private func recordPresentationCadenceIfNeeded() {
        guard expectedReadSemanticDiagnostic?.hasPrefix("presentation-reprojection") == true else { return }
        let now = CACurrentMediaTime()
        guard let startedAt = presentationReceiptWindowStartedAt else {
            presentationReceiptWindowStartedAt = now
            presentationReceiptCount = 1
            return
        }
        presentationReceiptCount += 1
        let elapsed = now - startedAt
        guard elapsed >= 2 else { return }
        let fps = Double(max(0, presentationReceiptCount - 1)) / elapsed
        NSLog("Core-SET: target-read lane=player stage=presentation-cadence confirmed=1 frames=%d window=%.3f effectiveFPS=%.2f clock=dispatch-source receipt=local-renderer",
              presentationReceiptCount, elapsed, fps)
        presentationReceiptWindowStartedAt = now
        presentationReceiptCount = 1
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
        presentationTimer?.cancel(); presentationTimer = nil
        activeToken = nil; pendingApply = nil
        currentRoster = nil; currentGeometry = nil
        geometryInFlight = false; presentationInFlight = false; geometryExpired = false
        lastGeometrySubmittedAt = nil; lastGeometryReceiptAt = nil
        awaitingReceipt = false
        awaitingReceiptSince = nil
        activeSessionGeneration = nil; activeProcessID = nil; activeImageBase = nil
        captureFailureStartedAt = nil; captureLaneClearedForFailure = false
        expectedReadSemanticDiagnostic = nil
        presentationReceiptWindowStartedAt = nil; presentationReceiptCount = 0
        let motionClean = grenadeMotion.clear()
        CoreSetWeaponImageCatalog.stop()
        let cleanup = worker.sync { session.disconnect() } // Drain queued connects/captures first.
        let geometryCleanup = geometryWorker.sync { geometrySession.disconnect() }
        let presentationCleanup = presentationWorker.sync { presentationSession.disconnect() }
        return motionClean && cleanup.complete && geometryCleanup.complete && presentationCleanup.complete
    }
}
