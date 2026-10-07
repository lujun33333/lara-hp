import Foundation

// Independent battle lane. No recoil delta formula or verified mapped write
// profile is available, so binding never promotes any action field.
final class CoreSetRecoilConsumer: CoreSetFeatureConsumer {
    typealias State = CoreSetRecoilSettings
    let capability = CoreSetCapability.recoilControl
    private let writer = CoreSetTargetWriteSession()

    var availability: CoreSetAvailability {
        .unavailable(reason: writer.pendingCleanup
            ? "压枪写会话清理待确认" : "压枪增量公式及目标写 profile 未验证")
    }
    var supportedFields: Set<CoreSetField> { [] }

    func apply(_ request: CoreSetApplyRequest<State>,
               completion: @escaping (CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void) {
        completion(request.token, .notApplied(reason: "压枪公式未闭合，未执行目标写入"))
    }

    func stop(_ token: CoreSetRequestToken,
              completion: @escaping (CoreSetRequestToken, CoreSetStopOutcome) -> Void) {
        let cleanup = writer.disconnect()
        completion(token, cleanup.complete ? .restored : .failed(reason: "压枪写会话清理未确认"))
    }

    func shutdownWriteSession() -> Bool { writer.disconnect().complete }
}
