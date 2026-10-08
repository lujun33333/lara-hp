import Foundation

// Battle fields stay unavailable until a target-specific writer, selector,
// and stop barrier are all verified. Binding this object never enables aim.
final class CoreSetAimConsumer: CoreSetFeatureConsumer {
    typealias State = CoreSetAimSettings
    let capability = CoreSetCapability.aimControl
    private let writer = CoreSetTargetWriteSession()
    private let inputProbe = CoreSetActionReadOnlyProbe(lane: "aim")
    private var cachedWriteBoundaryReason = "写 profile 尚未观察"
    private var cachedWriteBoundaryAt = -Double.infinity

    init() {
        NSLog("Core-SET: target-write lane=aim stage=capability ready=0 reason=audited-writer-or-receipt-unavailable controllerSlots=static-typed axisUnitRoute=unverified selector=unverified lifecycleReceipt=unverified")
        inputProbe.requestIfDue()
    }

    var availability: CoreSetAvailability {
        inputProbe.requestIfDue()
        return .unavailable(reason: writer.pendingCleanup
            ? "目标写会话清理待确认" : writeBoundaryReason())
    }
    var supportedFields: Set<CoreSetField> { [] }

    func apply(_ request: CoreSetApplyRequest<State>,
               completion: @escaping (CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void) {
        NSLog("Core-SET: target-write lane=aim stage=request-denied committed=0 reason=audited-writer-or-receipt-unavailable request=%@", request.token.requestID.uuidString)
        inputProbe.requestIfDue()
        NSLog("Core-SET: target-write lane=aim stage=planner-boundary pointIDs=v17-106..130 triggerLatch=reference-0.25s sceneTables=reference-typed directMergeSlots=reference-closed upstreamRouteAuthority=unissued selector=reference-raw-point-rank liveBoneOwner=unverified geometryClock=reference-first-reset-50ms localGeometry=reference-c4af8-valid-input angularMotion=reference-c642c-not-ballistic producerLease=unissued gameThreadExclusive=0 stopRestore=unverified committed=0")
        completion(request.token, .notApplied(reason: "自瞄目标写能力未验证，未执行目标写入"))
    }

    func stop(_ token: CoreSetRequestToken,
              completion: @escaping (CoreSetRequestToken, CoreSetStopOutcome) -> Void) {
        inputProbe.stop { [weak self] probeClean in
            guard let self = self else {
                completion(token, .failed(reason: "动作诊断所有者已释放，清理未确认")); return
            }
            let cleanup = self.writer.disconnect()
            completion(token, probeClean && cleanup.complete ? .restored : .failed(reason: "目标写会话或只读诊断清理未确认"))
        }
    }

    func shutdownWriteSession() -> Bool {
        let probeClean = inputProbe.stopIfIdle()
        return writer.disconnect().complete && probeClean
    }

    private func writeBoundaryReason() -> String {
        let now = ProcessInfo.processInfo.systemUptime
        if now - cachedWriteBoundaryAt < 5 { return cachedWriteBoundaryReason }
        let snapshot = CoreSetKernelWriteProfileRegistry.diagnosticSnapshot()
        let reasons = (snapshot["failureReasons"] as? [String]) ?? []
        let profile = (snapshot["profileMatches"] as? Bool) == true
            ? "profile-match" : (reasons.isEmpty ? "profile-unverified" : reasons.joined(separator: ","))
        cachedWriteBoundaryReason = "build15915 动作 owner、恢复回执未验证；写 profile=\(profile)"
        cachedWriteBoundaryAt = now
        return cachedWriteBoundaryReason
    }
}
