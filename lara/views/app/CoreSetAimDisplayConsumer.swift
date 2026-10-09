import UIKit
import QuartzCore

// This is a local HUD projection of AimConsumer's selected candidate, not a
// second selector or a game action receipt.
final class CoreSetAimDisplayConsumer: NSObject, CoreSetFeatureConsumer {
    typealias State = CoreSetAimDisplaySettings
    let capability = CoreSetCapability.localAimDisplay
    private weak var coordinator: CoreSetRuntimeCoordinator?
    private let preview: CoreSetAimPreviewConsumer
    private var refresh: CADisplayLink?
    private var inFlight = false
    private var activeToken: CoreSetRequestToken?
    private var settings = CoreSetAimDisplaySettings()
    private var revision: UInt64 = 0
    private var expectedSnapshot: UUID?
    private var expectedGeneration: UInt64?
    private var expectedSourceIdentity: CoreSetAimDisplaySourceIdentity?
    private var expectedCompletedAt: Double?
    private var expectedCommandCount: Int?
    private var expectedTargetPresent: Bool?
    private var awaitingTargetEvidence = false
    private var dynamicCandidateKey: UInt64?
    private var dynamicReadIdentity: (generation: UInt64, pid: Int32, base: UInt64)?
    private var dynamicStartedAt: CFTimeInterval?
    private var pendingApply: (CoreSetRequestToken, State,
                               (CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void)?
    private var pendingFailure: (CoreSetRequestToken, String,
                                 (CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void)?
    private var pendingClearInvalidation: CoreSetRequestToken?
    private var pendingStop: (CoreSetRequestToken, (CoreSetRequestToken, CoreSetStopOutcome) -> Void)?

    init(coordinator: CoreSetRuntimeCoordinator) {
        self.coordinator = coordinator
        preview = CoreSetAimPreviewConsumer(coordinator: coordinator)
        super.init()
    }

    var availability: CoreSetAvailability {
        coordinator?.playerCanvas != nil ? .ready : .unavailable(reason: "本地 HUD 画布未就绪")
    }
    var configurableFields: Set<CoreSetField> {
        [.localAimCircle, .localAimCircleSize, .localAimPreviewLine,
         .localAimPreviewMarker, .localAimDynamicCircle, .localAimPreviewBots,
         .localAimPreviewDistance]
    }
    var supportedFields: Set<CoreSetField> {
        guard availability == .ready else { return [] }
        var fields: Set<CoreSetField> = [.localAimCircle, .localAimCircleSize]
        if preview.ready {
            fields.formUnion([.localAimPreviewLine, .localAimPreviewMarker,
                              .localAimDynamicCircle, .localAimPreviewBots,
                              .localAimPreviewDistance])
        }
        return fields
    }

    private func needsTarget(_ state: State) -> Bool {
        state.connectionLine == true || state.preaimMarker == true || state.dynamicCircle == true
    }

    private func resetDynamicAnimation() {
        dynamicCandidateKey = nil
        dynamicReadIdentity = nil
        dynamicStartedAt = nil
    }

    private func armRefresh() {
        guard refresh == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(refreshFrame))
        link.add(to: .main, forMode: .common)
        refresh = link
    }

    @objc private func refreshFrame() { capture() }

    private func dynamicElapsed(for target: CoreSetAimPreviewTarget,
                                frame: CoreSetAimPreviewFrame,
                                now: CFTimeInterval) -> Double? {
        guard now.isFinite else { resetDynamicAnimation(); return nil }
        let identityChanged = dynamicReadIdentity.map {
            $0.generation != frame.sessionGeneration ||
                $0.pid != frame.processID || $0.base != frame.imageBase
        } ?? true
        let startChanged = dynamicStartedAt.map {
            $0 != target.candidateStartedMonotonicSeconds
        } ?? true
        if identityChanged || dynamicCandidateKey != target.candidateKey ||
            startChanged {
            dynamicCandidateKey = target.candidateKey
            dynamicReadIdentity = (frame.sessionGeneration, frame.processID, frame.imageBase)
            dynamicStartedAt = target.candidateStartedMonotonicSeconds
        }
        guard let started = dynamicStartedAt else { return nil }
        let elapsed = now - started
        guard elapsed.isFinite, elapsed >= 0 else {
            resetDynamicAnimation()
            return nil
        }
        // Core substitutes 10 only when its saved start scalar is invalid; a valid
        // candidate continues with the full elapsed value.  The shared Aim record
        // already carries a finite selection start, so do not clamp a live phase.
        return elapsed
    }

    private func appendLine(from start: CGPoint, to end: CGPoint,
                            color: UIColor, width: CGFloat,
                            to result: inout [CoreSetRenderCommand]) {
        result.append(CoreSetRenderCommand(kind: .line,
            rect: CGRect(origin: start, size: .zero), endpoint: end,
            color: color, lineWidth: width, filled: false,
            text: nil, fontSize: 12))
    }

    private func appendArc(center: CGPoint, radius: CGFloat,
                           start: CGFloat, end: CGFloat, segments: Int,
                           color: UIColor, width: CGFloat,
                           to result: inout [CoreSetRenderCommand]) {
        guard radius.isFinite, radius > 2, start.isFinite, end.isFinite,
              end > start, segments > 0 else { return }
        var previous = CGPoint(x: center.x + cos(start) * radius,
                               y: center.y + sin(start) * radius)
        for index in 1...segments {
            let fraction = CGFloat(index) / CGFloat(segments)
            let angle = start + (end - start) * fraction
            let next = CGPoint(x: center.x + cos(angle) * radius,
                               y: center.y + sin(angle) * radius)
            appendLine(from: previous, to: next, color: color, width: width, to: &result)
            previous = next
        }
    }

    private func appendCircleOutline(center: CGPoint, radius: CGFloat,
                                     segments: Int, color: UIColor, width: CGFloat,
                                     to result: inout [CoreSetRenderCommand]) {
        appendArc(center: center, radius: radius, start: 0, end: CGFloat.pi * 2,
                  segments: segments, color: color, width: width, to: &result)
    }

    private func appendDynamicRing(center: CGPoint, ring: CGFloat,
                                   target: CoreSetAimPreviewTarget,
                                   elapsed: Double,
                                   to result: inout [CoreSetRenderCommand]) {
        let decay = exp(-1.8 * elapsed)
        let oscillation = exp(-3.6 * elapsed) * cos(12 * elapsed)
        guard decay.isFinite, oscillation.isFinite else { return }

        let primaryAlpha = CGFloat(Int(32 + 38 * decay)) / 255
        let secondaryAlpha = CGFloat(Int(175 + 60 * decay)) / 255
        let primary = UIColor(red: 70.0 / 255, green: 185.0 / 255,
                              blue: 1, alpha: primaryAlpha)
        let secondary = UIColor(red: 125.0 / 255, green: 215.0 / 255,
                                blue: 1, alpha: secondaryAlpha)
        let quarter = CGFloat.pi / 2
        for index in 0..<4 {
            let start = CGFloat(index) * quarter + 0.13
            let end = CGFloat(index + 1) * quarter - 0.13
            appendArc(center: center, radius: ring, start: start, end: end,
                      segments: 16, color: primary, width: 5.2, to: &result)
            appendArc(center: center, radius: ring, start: start, end: end,
                      segments: 16, color: secondary, width: 2.4, to: &result)
        }

        let pulsing = ring * CGFloat(0.54 + 0.24 * oscillation)
        let innerRadius = min(ring * 0.8, max(ring * 0.43, pulsing))
        let pointerLength = min(16, max(8, ring * 0.055))
        let outerRadius = innerRadius + pointerLength
        let pointer = UIColor(red: 165.0 / 255, green: 232.0 / 255,
                              blue: 1, alpha: CGFloat(Int(195 + 60 * decay)) / 255)
        for index in 0..<4 {
            let angle = -CGFloat.pi / 2 + CGFloat(index) * quarter
            let unit = CGPoint(x: cos(angle), y: sin(angle))
            let inner = CGPoint(x: center.x + unit.x * innerRadius,
                                y: center.y + unit.y * innerRadius)
            let outer = CGPoint(x: center.x + unit.x * outerRadius,
                                y: center.y + unit.y * outerRadius)
            appendLine(from: inner, to: outer, color: pointer, width: 3, to: &result)
            result.append(CoreSetRenderCommand(kind: .ellipse,
                rect: CGRect(x: inner.x - 1.7, y: inner.y - 1.7, width: 3.4, height: 3.4),
                endpoint: .zero, color: pointer, lineWidth: 1,
                filled: true, text: nil, fontSize: 12))
        }

        let dx = target.point.x - center.x
        let dy = target.point.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        if distance.isFinite, distance > 1 {
            let direction = atan2(dy, dx)
            let halfSpan = CGFloat(0.16 + 0.04 * decay)
            let directionColor = UIColor(red: 210.0 / 255, green: 245.0 / 255,
                                         blue: 1, alpha: 245.0 / 255)
            appendArc(center: center, radius: ring,
                      start: direction - halfSpan, end: direction + halfSpan,
                      segments: 10, color: directionColor, width: 4.2, to: &result)
        }
    }

    private func radius(_ state: State, canvas: CGSize) -> CGFloat? {
        guard let size = state.circleSize.value, (30...525).contains(size),
              canvas.width.isFinite, canvas.height.isFinite,
              canvas.width > 0, canvas.height > 0 else { return nil }
        let short = min(canvas.width, canvas.height)
        let raw = short * CGFloat(size) / 1170
        let upper = min(short * 0.45, 525)
        let value = raw < 30 ? CGFloat(30) : min(raw, upper)
        return value.isFinite && value > 2 ? value : nil
    }

    func apply(_ request: CoreSetApplyRequest<State>,
               completion: @escaping (CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void) {
        precondition(Thread.isMainThread)
        guard availability == .ready, let canvas = coordinator?.playerCanvas,
              revision < UInt64.max else {
            completion(request.token, .notApplied(reason: "本地 HUD 画布未就绪")); return
        }
        if (request.desired.circleVisible == true || needsTarget(request.desired)) &&
            radius(request.desired, canvas: canvas.size) == nil {
            completion(request.token, .notApplied(reason: "请先选择本地预览圈大小")); return
        }
        if request.desired.dynamicCircle == true && request.desired.circleVisible != true {
            completion(request.token, .notApplied(reason: "动态预览圈需先开启本地圈")); return
        }
        if needsTarget(request.desired) &&
            (!preview.ready || request.desired.maximumDistance.value == nil) {
            let reason = preview.ready ? "请先选择只读预览筛选距离" : preview.unavailableDiagnostic
            completion(request.token, .notApplied(reason: reason)); return
        }
        refresh?.invalidate(); refresh = nil
        inFlight = false
        expectedSnapshot = nil; expectedGeneration = nil
        expectedSourceIdentity = nil; expectedCompletedAt = nil
        awaitingTargetEvidence = false
        expectedCommandCount = nil
        expectedTargetPresent = nil
        revision += 1
        settings = request.desired; activeToken = request.token
        pendingApply = (request.token, request.desired, completion)
        capture()
        if needsTarget(request.desired) { armRefresh() }
    }

    private func capture() {
        guard !inFlight, let token = activeToken,
              let canvas = coordinator?.playerCanvas else { return }
        let ring: CGFloat
        if let selected = radius(settings, canvas: canvas.size) { ring = selected }
        else if !needsTarget(settings) && settings.circleVisible != true { ring = 0 }
        else { return }
        let expectedRevision = revision, current = settings
        if !needsTarget(current) {
            submit(frame: nil, ring: ring, state: current, token: token,
                   revision: expectedRevision, canvas: canvas)
            return
        }
        guard let distance = current.maximumDistance.value else { return }
        let bots = current.includeBots == true // Nil is a local fail-closed "exclude bots" policy.
        preview.capture(canvas: canvas.size, radius: ring, includeBots: bots,
                        maximumDistance: distance) { [weak self] frame in
            guard let self else { return }
            guard self.activeToken == token, self.revision == expectedRevision,
                  self.coordinator?.playerCanvas?.generation == canvas.generation else {
                return
            }
            self.submit(frame: frame, ring: ring, state: current, token: token,
                        revision: expectedRevision, canvas: canvas)
        }
    }

    private func commands(state: State, frame: CoreSetAimPreviewFrame?,
                          canvas: CGSize, ring: CGFloat) -> [CoreSetRenderCommand] {
        let targetRequired = needsTarget(state)
        if targetRequired && frame?.target == nil {
            resetDynamicAnimation()
            // Keep the local circle visible. Target-dependent decoration waits
            // for AimConsumer's selected-candidate publication.
        }
        var result: [CoreSetRenderCommand] = []
        let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        if state.circleVisible == true {
            if state.dynamicCircle == true, let frame, let target = frame.target,
               let elapsed = dynamicElapsed(for: target, frame: frame,
                                            now: CACurrentMediaTime()) {
                appendDynamicRing(center: center, ring: ring, target: target,
                                  elapsed: elapsed, to: &result)
            } else {
                resetDynamicAnimation()
                // Core 0x1000de764..0x1000de780: 64-segment circle,
                // ImU32 0xa0ffd278 (RGBA 120,210,255,160), width 1.5.
                let staticCircle = UIColor(red: 120.0 / 255, green: 210.0 / 255,
                                           blue: 1, alpha: 160.0 / 255)
                appendCircleOutline(center: center, radius: ring, segments: 64,
                                    color: staticCircle, width: 1.5, to: &result)
            }
        } else {
            resetDynamicAnimation()
        }
        if let target = frame?.target {
            if state.connectionLine == true {
                // Core 0x1000debf8..0x1000dec2c: center to selected point,
                // ImU32 0x825050ff (RGBA 255,80,80,130), width 1.
                result.append(CoreSetRenderCommand(kind: .line,
                    rect: CGRect(origin: center, size: .zero), endpoint: target.point,
                    color: UIColor(red: 1, green: 80.0 / 255, blue: 80.0 / 255,
                                   alpha: 130.0 / 255), lineWidth: 1,
                    filled: false, text: nil, fontSize: 12))
            }
            if state.preaimMarker == true {
                // Core 0x1000dec40..0x1000deca0: the selected point first receives
                // a 24-segment r=7 outline (width 1.8) and a filled r=2.5 core,
                // both ImU32 0xdc5050ff (RGBA 255,80,80,220).
                let marker = UIColor(red: 1, green: 80.0 / 255, blue: 80.0 / 255,
                                     alpha: 220.0 / 255)
                appendCircleOutline(center: target.point, radius: 7, segments: 24,
                                    color: marker, width: 1.8, to: &result)
                result.append(CoreSetRenderCommand(kind: .ellipse,
                    rect: CGRect(x: target.point.x - 2.5, y: target.point.y - 2.5,
                                 width: 5, height: 5), endpoint: .zero,
                    color: marker, lineWidth: 1,
                    filled: true, text: nil, fontSize: 12))
                if let predicted = target.predictedPoint {
                    // Core 0x1000ded2c..0x1000ded88: only the same-actor,
                    // in-bounds c4af8 predicted point reaches this second layer.
                    let predictedLine = UIColor(red: 1, green: 210.0 / 255,
                                                blue: 60.0 / 255, alpha: 200.0 / 255)
                    appendLine(from: target.point, to: predicted,
                               color: predictedLine, width: 1.5, to: &result)
                    let predictedCircle = UIColor(red: 1, green: 210.0 / 255,
                                                  blue: 60.0 / 255, alpha: 230.0 / 255)
                    appendCircleOutline(center: predicted, radius: 5, segments: 16,
                                        color: predictedCircle, width: 1.5, to: &result)
                }
            }
        }
        return result
    }

    private func submit(frame: CoreSetAimPreviewFrame?, ring: CGFloat, state: State,
                        token: CoreSetRequestToken, revision: UInt64,
                        canvas: (generation: UInt64, size: CGSize)) {
        guard self.revision == revision, activeToken == token else { return }
        let id = frame?.snapshotID ?? UUID()
        expectedSnapshot = id; expectedGeneration = canvas.generation
        expectedSourceIdentity = frame?.sourceIdentity
        expectedCompletedAt = frame?.captureCompletedMonotonicSeconds
        let renderedCommands = commands(state: state, frame: frame,
                                        canvas: canvas.size, ring: ring)
        expectedCommandCount = renderedCommands.count
        expectedTargetPresent = frame?.target != nil
        awaitingTargetEvidence = needsTarget(state) && frame?.target == nil
        let input = CoreSetLaneSubmission(lane: .aimDisplay, hostGeneration: canvas.generation,
            configRevision: revision, snapshotID: id, requestToken: token,
            canvasSize: canvas.size, commands: renderedCommands,
            aimSourceIdentity: frame?.sourceIdentity)
        inFlight = true
        if coordinator?.submitLane(input) != true {
            inFlight = false
            expectedSnapshot = nil; expectedGeneration = nil
            expectedSourceIdentity = nil; expectedCompletedAt = nil
            expectedCommandCount = nil; expectedTargetPresent = nil
            awaitingTargetEvidence = false
            if let pending = pendingApply, pending.0 == token {
                pendingApply = nil
                pending.2(token, .failed(reason: "本地预览帧未进入合成器"))
            } else { clearStale(token: token, canvas: canvas, reason: "本地预览帧提交失败") }
        }
    }

    private func clearStale(token: CoreSetRequestToken,
                            canvas: (generation: UInt64, size: CGSize), reason: String) {
        NSLog("Core-SET: target-read lane=aim-preview stage=preview-invalidated confirmed=0 reason=%@", reason)
        refresh?.invalidate(); refresh = nil
        awaitingTargetEvidence = false
        expectedCommandCount = nil; expectedTargetPresent = nil
        resetDynamicAnimation()
        guard revision < UInt64.max else { return }
        revision += 1
        let id = UUID()
        expectedSnapshot = id; expectedGeneration = canvas.generation
        let cleared = coordinator?.clearLane(.aimDisplay, generation: canvas.generation,
            configRevision: revision, snapshotID: id, requestToken: token,
            canvasSize: canvas.size) == true
        inFlight = cleared
        if let pending = pendingApply, pending.0 == token {
            pendingApply = nil
            if cleared { pendingFailure = (token, reason, pending.2) }
            else { pending.2(token, .failed(reason: "本地预览失效且清帧未确认")) }
        } else if cleared { pendingClearInvalidation = token }
        else { coordinator?.invalidateAimDisplayObservation() }
    }

    func consumed(_ receipt: CoreSetLocalFrameReceipt) {
        guard receipt.lane == .aimDisplay,
              receipt.configRevision == revision,
              receipt.snapshotID == expectedSnapshot,
              receipt.hostGeneration == expectedGeneration else { return }
        inFlight = false
        if let stop = pendingStop, stop.0 == receipt.requestToken {
            pendingStop = nil; expectedSnapshot = nil; expectedGeneration = nil
            stop.1(stop.0, receipt.acceptedByLocalRenderer ? .restored :
                .failed(reason: "本地预览圈清空未获精确回执"))
            return
        }
        if let failure = pendingFailure, failure.0 == receipt.requestToken {
            pendingFailure = nil; expectedSnapshot = nil; expectedGeneration = nil
            expectedSourceIdentity = nil; expectedCompletedAt = nil
            expectedCommandCount = nil; expectedTargetPresent = nil
            failure.2(failure.0, receipt.acceptedByLocalRenderer ?
                .unavailable(reason: failure.1) : .failed(reason: "本地预览失效清帧被拒绝"))
            return
        }
        if pendingClearInvalidation == receipt.requestToken {
            pendingClearInvalidation = nil
            coordinator?.invalidateAimDisplayObservation()
            return
        }
        if let pending = pendingApply, pending.0 == receipt.requestToken {
            let identityValid: Bool
            if let source = expectedSourceIdentity,
               let snapshotID = expectedSnapshot, let generation = expectedGeneration {
                identityValid = source.snapshotID == snapshotID &&
                    source.hostGeneration == generation &&
                    receipt.aimSourceIdentity == source
            } else {
                identityValid = expectedSourceIdentity == nil && receipt.aimSourceIdentity == nil
            }
            let freshnessValid = expectedCompletedAt.map {
                CACurrentMediaTime() - $0 >= 0 &&
                    CACurrentMediaTime() - $0 <= CoreSetAimDisplayRecordStore.maximumRecordAge
            } ?? true
            guard receipt.acceptedByLocalRenderer, availability == .ready,
                  identityValid, freshnessValid else {
                if let canvas = coordinator?.playerCanvas {
                    clearStale(token: pending.0, canvas: canvas,
                        reason: "只读预览回执时身份或新鲜度已失效")
                } else {
                    pendingApply = nil
                    pending.2(pending.0, .unavailable(reason: "本地预览宿主已失效"))
                }
                return
            }
            if needsTarget(pending.1), expectedTargetPresent != true {
                let count = expectedCommandCount ?? 0
                expectedSnapshot = nil; expectedGeneration = nil
                expectedSourceIdentity = nil; expectedCompletedAt = nil
                expectedCommandCount = nil; expectedTargetPresent = nil
                awaitingTargetEvidence = true
                NSLog("Core-SET: target-read lane=aim-preview stage=receipt confirmed=0 reason=no-target-evidence commands=\(count)")
                armRefresh()
                return
            }
            pendingApply = nil; expectedSnapshot = nil; expectedGeneration = nil
            expectedSourceIdentity = nil; expectedCompletedAt = nil
            expectedCommandCount = nil; expectedTargetPresent = nil
            awaitingTargetEvidence = false
            pending.2(pending.0, .applied(observed: pending.1))
            if needsTarget(pending.1) { armRefresh() }
            return
        }
        if !receipt.acceptedByLocalRenderer, activeToken == receipt.requestToken {
            if let canvas = coordinator?.playerCanvas {
                clearStale(token: receipt.requestToken, canvas: canvas,
                    reason: "本地预览帧被拒绝，显示状态已撤销")
            } else {
                coordinator?.invalidateAimDisplayObservation()
            }
            return
        }
    }

    func stop(_ token: CoreSetRequestToken,
              completion: @escaping (CoreSetRequestToken, CoreSetStopOutcome) -> Void) {
        precondition(Thread.isMainThread)
        refresh?.invalidate(); refresh = nil
        inFlight = false
        resetDynamicAnimation()
        activeToken = nil
        pendingApply = nil
        pendingFailure = nil
        pendingClearInvalidation = nil
        expectedSourceIdentity = nil; expectedCompletedAt = nil
        expectedCommandCount = nil; expectedTargetPresent = nil
        awaitingTargetEvidence = false
        guard revision < UInt64.max else {
            completion(token, .failed(reason: "本地预览圈序号耗尽")); return
        }
        revision += 1
        if let canvas = coordinator?.playerCanvas {
            let id = UUID()
            expectedSnapshot = id; expectedGeneration = canvas.generation
            pendingStop = (token, completion)
            if coordinator?.clearLane(.aimDisplay, generation: canvas.generation,
                configRevision: revision, snapshotID: id, requestToken: token,
                canvasSize: canvas.size) == true { return }
            pendingStop = nil
        }
        completion(token, coordinator?.lastStopResult?.complete.boolValue == true ? .restored :
            .failed(reason: "本地预览圈清空未获确认"))
    }

    @discardableResult
    func shutdownPreview() -> Bool {
        refresh?.invalidate(); refresh = nil
        inFlight = false
        resetDynamicAnimation()
        activeToken = nil
        expectedCommandCount = nil; expectedTargetPresent = nil
        awaitingTargetEvidence = false
        return preview.shutdown()
    }

    func invalidateFrame() {
        precondition(Thread.isMainThread)
        refresh?.invalidate(); refresh = nil
        inFlight = false
        resetDynamicAnimation()
        activeToken = nil
        pendingApply = nil; pendingFailure = nil
        pendingClearInvalidation = nil
        expectedSnapshot = nil; expectedGeneration = nil; expectedSourceIdentity = nil
        expectedCompletedAt = nil
        expectedCommandCount = nil; expectedTargetPresent = nil
        awaitingTargetEvidence = false
        if revision < UInt64.max { revision += 1 }
    }
}
