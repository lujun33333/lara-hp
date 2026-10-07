import UIKit
import QuartzCore

// This is a local HUD preview, not an AimConsumer or a game action receipt.
final class CoreSetAimDisplayConsumer: CoreSetFeatureConsumer {
    typealias State = CoreSetAimDisplaySettings
    let capability = CoreSetCapability.localAimDisplay
    private weak var coordinator: CoreSetRuntimeCoordinator?
    private let preview: CoreSetAimPreviewConsumer
    private var refresh: Timer?
    private var inFlight = false
    private var activeToken: CoreSetRequestToken?
    private var settings = CoreSetAimDisplaySettings()
    private var revision: UInt64 = 0
    private var expectedSnapshot: UUID?
    private var expectedGeneration: UInt64?
    private var expectedReadIdentity: (generation: UInt64, pid: Int32, base: UInt64)?
    private var expectedCapturedAt: Double?
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

    private func dynamicElapsed(for target: CoreSetAimPreviewTarget,
                                frame: CoreSetAimPreviewFrame,
                                now: CFTimeInterval) -> Double? {
        guard now.isFinite else { resetDynamicAnimation(); return nil }
        let identityChanged = dynamicReadIdentity.map {
            $0.generation != frame.sessionGeneration ||
                $0.pid != frame.processID || $0.base != frame.imageBase
        } ?? true
        if identityChanged || dynamicCandidateKey != target.actorAddress || dynamicStartedAt == nil {
            dynamicCandidateKey = target.actorAddress
            dynamicReadIdentity = (frame.sessionGeneration, frame.processID, frame.imageBase)
            dynamicStartedAt = now
            return 0
        }
        guard let started = dynamicStartedAt else { return nil }
        let elapsed = now - started
        guard elapsed.isFinite, elapsed >= 0 else {
            dynamicCandidateKey = target.actorAddress
            dynamicStartedAt = now
            return 0
        }
        // Core falls back to 10 when its saved time scalar is invalid. Capping the
        // local clock at the same value avoids an unbounded phase without claiming
        // that CACurrentMediaTime is the original context clock.
        return min(elapsed, 10)
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
        revision += 1
        settings = request.desired; activeToken = request.token
        pendingApply = (request.token, request.desired, completion)
        capture()
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
        inFlight = true
        preview.capture(canvas: canvas.size, radius: ring, includeBots: bots,
                        maximumDistance: distance) { [weak self] frame in
            guard let self else { return }
            self.inFlight = false
            guard self.activeToken == token, self.revision == expectedRevision,
                  self.coordinator?.playerCanvas?.generation == canvas.generation else {
                if self.pendingApply != nil { self.capture() }
                return
            }
            guard let frame else {
                self.clearStale(token: token, canvas: canvas,
                    reason: "只读候选快照未确认：\(self.preview.lastCaptureDiagnostic)")
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
            return [] // No candidate: clear this lane.
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
                result.append(CoreSetRenderCommand(kind: .ellipse,
                    rect: CGRect(x: center.x - ring, y: center.y - ring,
                                 width: ring * 2, height: ring * 2),
                    endpoint: .zero, color: .systemCyan, lineWidth: 1,
                    filled: false, text: nil, fontSize: 12))
            }
        } else {
            resetDynamicAnimation()
        }
        if let target = frame?.target {
            if state.connectionLine == true {
                result.append(CoreSetRenderCommand(kind: .line,
                    rect: CGRect(origin: center, size: .zero), endpoint: target.point,
                    color: .systemOrange, lineWidth: 1.5,
                    filled: false, text: nil, fontSize: 12))
            }
            if state.preaimMarker == true {
                result.append(CoreSetRenderCommand(kind: .ellipse,
                    rect: CGRect(x: target.point.x - 6, y: target.point.y - 6,
                                 width: 12, height: 12), endpoint: .zero,
                    color: .systemOrange, lineWidth: 1,
                    filled: false, text: nil, fontSize: 12))
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
        expectedReadIdentity = frame.map { ($0.sessionGeneration, $0.processID, $0.imageBase) }
        expectedCapturedAt = frame?.captureCompletedMonotonicSeconds
        let input = CoreSetLaneSubmission(lane: .aimDisplay, hostGeneration: canvas.generation,
            configRevision: revision, snapshotID: id, requestToken: token,
            canvasSize: canvas.size, commands: commands(state: state, frame: frame,
                                                       canvas: canvas.size, ring: ring))
        if coordinator?.submitLane(input) != true {
            expectedSnapshot = nil; expectedGeneration = nil
            expectedReadIdentity = nil; expectedCapturedAt = nil
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
        resetDynamicAnimation()
        guard revision < UInt64.max else { return }
        revision += 1
        let id = UUID()
        expectedSnapshot = id; expectedGeneration = canvas.generation
        let cleared = coordinator?.clearLane(.aimDisplay, generation: canvas.generation,
            configRevision: revision, snapshotID: id, requestToken: token,
            canvasSize: canvas.size) == true
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
        if let stop = pendingStop, stop.0 == receipt.requestToken {
            pendingStop = nil; expectedSnapshot = nil; expectedGeneration = nil
            stop.1(stop.0, receipt.acceptedByLocalRenderer ? .restored :
                .failed(reason: "本地预览圈清空未获精确回执"))
            return
        }
        if let failure = pendingFailure, failure.0 == receipt.requestToken {
            pendingFailure = nil; expectedSnapshot = nil; expectedGeneration = nil
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
            let identityValid = expectedReadIdentity.map { preview.matchesIdentity($0) } ?? true
            let freshnessValid = expectedCapturedAt.map {
                CACurrentMediaTime() - $0 >= 0 && CACurrentMediaTime() - $0 <= 0.5
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
            pendingApply = nil; expectedSnapshot = nil; expectedGeneration = nil
            expectedReadIdentity = nil; expectedCapturedAt = nil
            pending.2(pending.0, .applied(observed: pending.1))
            if needsTarget(pending.1) {
                refresh = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.capture() }
            }
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
        let periodicStale = expectedCapturedAt.map {
            CACurrentMediaTime() - $0 < 0 || CACurrentMediaTime() - $0 > 0.5
        } ?? false
        if let identity = expectedReadIdentity,
           (!preview.matchesIdentity(identity) || periodicStale),
           let canvas = coordinator?.playerCanvas, activeToken == receipt.requestToken {
            clearStale(token: receipt.requestToken, canvas: canvas,
                reason: "只读候选身份变化，预览已撤销")
        }
    }

    func stop(_ token: CoreSetRequestToken,
              completion: @escaping (CoreSetRequestToken, CoreSetStopOutcome) -> Void) {
        precondition(Thread.isMainThread)
        refresh?.invalidate(); refresh = nil
        resetDynamicAnimation()
        activeToken = nil
        pendingApply = nil
        pendingFailure = nil
        pendingClearInvalidation = nil
        expectedReadIdentity = nil; expectedCapturedAt = nil
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
        resetDynamicAnimation()
        activeToken = nil
        return preview.shutdown()
    }

    func invalidateFrame() {
        precondition(Thread.isMainThread)
        refresh?.invalidate(); refresh = nil
        resetDynamicAnimation()
        activeToken = nil
        pendingApply = nil; pendingFailure = nil
        pendingClearInvalidation = nil
        expectedSnapshot = nil; expectedGeneration = nil; expectedReadIdentity = nil
        expectedCapturedAt = nil
        if revision < UInt64.max { revision += 1 }
    }
}
