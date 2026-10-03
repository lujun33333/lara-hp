import Foundation

// A scheduler readback is this capability's receipt. CA's event-driven
// consumer has no fixed frame rate and never reports this field ready.
final class CoreSetFrameRateConsumer: CoreSetFeatureConsumer {
    typealias State = CoreSetFrameRateSettings
    let capability = CoreSetCapability.frameScheduling
    private weak var coordinator: CoreSetRuntimeCoordinator?

    init(coordinator: CoreSetRuntimeCoordinator) { self.coordinator = coordinator }
    var availability: CoreSetAvailability {
        coordinator?.frameRateReady == true ? .ready :
            .unavailable(reason: "当前 CA 事件驱动宿主没有可回读的固定 FPS 调度器")
    }
    var supportedFields: Set<CoreSetField> {
        availability == .ready ? [.framesPerSecond] : []
    }
    func apply(_ request: CoreSetApplyRequest<State>,
               completion: @escaping (CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void) {
        precondition(Thread.isMainThread)
        guard availability == .ready,
              let value = request.desired.framesPerSecond.value,
              (30...144).contains(value),
              coordinator?.applyFrameRate(value) == true else {
            completion(request.token, .unavailable(reason: "FPS 调度器设置或实际读回未确认")); return
        }
        completion(request.token, .applied(observed: request.desired))
    }
    func stop(_ token: CoreSetRequestToken,
              completion: @escaping (CoreSetRequestToken, CoreSetStopOutcome) -> Void) {
        precondition(Thread.isMainThread)
        completion(token, coordinator?.restoreFrameRate() == true ? .restored :
            .failed(reason: "FPS 调度器基线恢复未获读回"))
    }
}
