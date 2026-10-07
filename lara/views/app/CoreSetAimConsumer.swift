import Foundation

// Battle fields stay unavailable until a target-specific writer, selector,
// and stop barrier are all verified. Binding this object never enables aim.
final class CoreSetAimConsumer: CoreSetFeatureConsumer {
    typealias State = CoreSetAimSettings
    let capability = CoreSetCapability.aimControl
    private let writer = CoreSetTargetWriteSession()

    var availability: CoreSetAvailability {
        .unavailable(reason: writer.pendingCleanup
            ? "目标写会话清理待确认" : "build15915 映射写能力与动作停止回执未验证")
    }
    var supportedFields: Set<CoreSetField> { [] }

    func apply(_ request: CoreSetApplyRequest<State>,
               completion: @escaping (CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void) {
        completion(request.token, .notApplied(reason: "自瞄目标写能力未验证，未执行目标写入"))
    }

    func stop(_ token: CoreSetRequestToken,
              completion: @escaping (CoreSetRequestToken, CoreSetStopOutcome) -> Void) {
        let cleanup = writer.disconnect()
        completion(token, cleanup.complete ? .restored : .failed(reason: "目标写会话清理未确认"))
    }

    func shutdownWriteSession() -> Bool { writer.disconnect().complete }
}
