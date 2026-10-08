import Foundation

// Independent battle lane. No recoil delta formula or verified mapped write
// profile is available, so binding never promotes any action field.
final class CoreSetRecoilConsumer: CoreSetFeatureConsumer {
    typealias State = CoreSetRecoilSettings
    let capability = CoreSetCapability.recoilControl
    private let writer = CoreSetTargetWriteSession()
    private let inputProbe = CoreSetActionReadOnlyProbe(lane: "recoil")

    init() {
        NSLog("Core-SET: target-write lane=recoil stage=capability ready=0 reason=audited-writer-or-receipt-unavailable localStateMachine=reference-c571c-valid-input callerMerge=unverified controllerSlots=static-typed axisUnitRoute=unverified lifecycleReceipt=unverified")
        inputProbe.requestIfDue()
    }

    var availability: CoreSetAvailability {
        inputProbe.requestIfDue()
        return .unavailable(reason: writer.pendingCleanup
            ? "压枪写会话清理待确认" : "压枪增量公式及目标写 profile 未验证")
    }
    var supportedFields: Set<CoreSetField> { [] }

    func apply(_ request: CoreSetApplyRequest<State>,
               completion: @escaping (CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void) {
        NSLog("Core-SET: target-write lane=recoil stage=request-denied committed=0 reason=audited-writer-or-receipt-unavailable request=%@", request.token.requestID.uuidString)
        inputProbe.requestIfDue()
        NSLog("Core-SET: target-write lane=recoil stage=planner-boundary pointIDs=v17-131..136 postStateFlag=verticalEnabled-and-storedContinue rawFire=separate directMergeSlots=reference-closed upstreamRouteAuthority=unissued localStateMachine=reference-c571c-valid-input callerMerge=unverified producerLease=unissued stopRestore=unverified committed=0")
        completion(request.token, .notApplied(reason: "压枪公式未闭合，未执行目标写入"))
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
}
