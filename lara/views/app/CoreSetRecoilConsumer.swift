import Foundation

// Reference-only raw/post numerical models exist. Live sample ownership,
// mapped-write authority and independent readback/restore remain unverified.
// Binding this lane never promotes an action field to a target effect.
final class CoreSetRecoilConsumer: CoreSetFeatureConsumer {
    typealias State = CoreSetRecoilSettings
    let capability = CoreSetCapability.recoilControl
    private let writer = CoreSetTargetWriteSession()
    private let inputProbe = CoreSetActionReadOnlyProbe(lane: "recoil")
    private var cachedWriteBoundaryReason = "写 profile 尚未观察"
    private var cachedWriteBoundaryAt = -Double.infinity

    init() {
        NSLog("Core-SET: target-write lane=recoil stage=capability ready=0 reason=audited-writer-or-receipt-unavailable localStateMachine=reference-c571c-valid-input localPostState=reference-c416c-valid-input callerMerge=reference-c2d34 postOwnerToken=object-pointer-not-generation controllerSlots=static-typed liveOwnerMapping=unverified lifecycleReceipt=unverified")
        inputProbe.requestIfDue()
    }

    var availability: CoreSetAvailability {
        inputProbe.requestIfDue()
        return .unavailable(reason: writer.pendingCleanup
            ? "压枪写会话清理待确认" : writeBoundaryReason())
    }
    var supportedFields: Set<CoreSetField> { [] }
    // Preserve the six typed reference settings even while the target action
    // owner/formula/restore receipt is unavailable.
    var configurableFields: Set<CoreSetField> {
        [.recoilEnabled, .recoilStopWhenNotFiring, .recoilVerticalEnabled,
         .recoilVerticalStrength, .recoilHorizontalEnabled, .recoilHorizontalStrength]
    }

    func apply(_ request: CoreSetApplyRequest<State>,
               completion: @escaping (CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void) {
        NSLog("Core-SET: target-write lane=recoil stage=request-denied committed=0 reason=audited-writer-or-receipt-unavailable request=%@", request.token.requestID.uuidString)
        inputProbe.requestIfDue()
        NSLog("Core-SET: target-write lane=recoil stage=planner-boundary pointIDs=v17-131..136 postStateFlag=verticalEnabled-and-storedContinue rawFire=separate directMergeSlots=reference-closed upstreamRouteAuthority=unissued localStateMachine=reference-c571c-valid-input localPostState=reference-c416c-valid-input callerMerge=reference-c2d34 postOwnerToken=object-pointer-not-generation producerLease=unissued gameThreadExclusive=0 stopRestore=unverified committed=0")
        completion(request.token, .notApplied(reason: "压枪目标采样 owner 与动作回执未闭合，未执行目标写入"))
    }

    func stop(_ token: CoreSetRequestToken,
              completion: @escaping (CoreSetRequestToken, CoreSetStopOutcome) -> Void) {
        inputProbe.stop { [weak self] probeClean in
            guard let self = self else {
                completion(token, .failed(reason: "动作诊断所有者已释放，清理未确认")); return
            }
            let cleanup = self.writer.disconnect()
            completion(token, probeClean && cleanup.complete ? .restored : .failed(reason: "压枪写会话或只读诊断清理未确认"))
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
        cachedWriteBoundaryReason = "压枪采样 owner、回读恢复未验证；写 profile=\(profile)"
        cachedWriteBoundaryAt = now
        return cachedWriteBoundaryReason
    }
}
