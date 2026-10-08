import Foundation

// Battle fields stay unavailable until a target-specific writer, selector,
// and stop barrier are all verified. Binding this object never enables aim.
final class CoreSetAimConsumer: CoreSetFeatureConsumer {
    typealias State = CoreSetAimSettings
    let capability = CoreSetCapability.aimControl
    private let writer = CoreSetTargetWriteSession()
    private let inputProbe = CoreSetActionReadOnlyProbe(lane: "aim")

    init() {
        NSLog("Core-SET: target-write lane=aim stage=capability ready=0 reason=audited-writer-or-receipt-unavailable controllerSlots=static-typed axisUnitRoute=unverified selector=unverified lifecycleReceipt=unverified")
        inputProbe.requestIfDue()
    }

    var availability: CoreSetAvailability {
        inputProbe.requestIfDue()
        return .unavailable(reason: writer.pendingCleanup
            ? "目标写会话清理待确认" : "build15915 映射写能力与动作停止回执未验证")
    }
    var supportedFields: Set<CoreSetField> { [] }

    func apply(_ request: CoreSetApplyRequest<State>,
               completion: @escaping (CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void) {
        NSLog("Core-SET: target-write lane=aim stage=request-denied committed=0 reason=audited-writer-or-receipt-unavailable request=%@", request.token.requestID.uuidString)
        inputProbe.requestIfDue()
        NSLog("Core-SET: target-write lane=aim stage=planner-boundary pointIDs=v17-106..130 triggerLatch=reference-0.25s sceneTables=reference-typed directMergeSlots=reference-closed upstreamRouteAuthority=unissued selector=reference-raw-point-rank liveBoneOwner=unverified geometryClock=reference-first-reset-50ms producerLease=unissued stopRestore=unverified committed=0")
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
}
