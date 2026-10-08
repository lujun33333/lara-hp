import Foundation

// The live MTKView scheduler property readback is this capability's receipt,
// not a measured drawable presentation rate. CA has no fixed FPS control.
final class CoreSetFrameRateConsumer: CoreSetFeatureConsumer {
    typealias State = CoreSetFrameRateSettings
    let capability = CoreSetCapability.frameScheduling
    private weak var coordinator: CoreSetRuntimeCoordinator?
    private var appliedObservation: CoreSetFrameRateObservation?
    private var activeRequestToken: CoreSetRequestToken?

    init(coordinator: CoreSetRuntimeCoordinator) { self.coordinator = coordinator }
    var availability: CoreSetAvailability {
        guard coordinator?.frameRateReady == true else {
            return .unavailable(reason: "v17-029：当前宿主没有活跃且命令完成已核对的 Metal 固定 FPS 调度器；实际呈现另行测量")
        }
        if let appliedObservation, coordinator?.frameRateObservation != appliedObservation {
            return .unavailable(reason: "v17-029：Metal 调度器代次或读值已变化，旧回执失效")
        }
        return .ready
    }
    var configurableFields: Set<CoreSetField> { [.framesPerSecond] }
    var supportedFields: Set<CoreSetField> {
        availability == .ready ? configurableFields : []
    }
    func apply(_ request: CoreSetApplyRequest<State>,
               completion: @escaping (CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void) {
        precondition(Thread.isMainThread)
        guard availability == .ready,
              let before = coordinator?.frameRateObservation,
              let value = request.desired.framesPerSecond.value,
              (30...144).contains(value) else {
            completion(request.token, .notApplied(reason: "FPS 调度器或所选参数未就绪")); return
        }
        guard coordinator?.applyFrameRate(value) == true,
              let observed = coordinator?.frameRateObservation,
              observed.hostGeneration == before.hostGeneration,
              observed.preferredFramesPerSecond == value else {
            completion(request.token, .unavailable(reason: "FPS 调度器设置或实际读回未确认")); return
        }
        appliedObservation = observed; activeRequestToken = request.token
        NSLog("Core-SET: scheduler stage=apply point=v17-029 generation=%llu token=%@/%@/%@ requested=%d observed=%d confirmed=1 scope=metal-scheduler-property measured-presentation-fps=0",
              observed.hostGeneration, request.token.generation.uuidString, request.token.consumerID.uuidString,
              request.token.requestID.uuidString, value, observed.preferredFramesPerSecond)
        completion(request.token, .applied(observed: request.desired))
    }
    func refreshSchedulerObservation() {
        precondition(Thread.isMainThread)
        guard let coordinator, let expected = appliedObservation, let token = activeRequestToken else { return }
        let channel = coordinator.featureState.frameRate
        guard channel.pendingApply == nil, channel.pendingStop == nil,
              channel.generation == token.generation else { return }
        let current = coordinator.frameRateObservation
        guard current != expected else { return }
        let reason = "v17-029：Metal调度器回读失效，原代次=\(expected.hostGeneration)，原值=\(expected.preferredFramesPerSecond)，当前代次=\(current?.hostGeneration.description ?? "unavailable")，当前值=\(current?.preferredFramesPerSecond.description ?? "unavailable")"
        appliedObservation = nil; activeRequestToken = nil
        coordinator.invalidateFrameRateObservation(reason: reason)
        NSLog("Core-SET: scheduler stage=invalidated point=v17-029 confirmed=0 scope=metal-scheduler-property reason=%@", reason)
    }
    func stop(_ token: CoreSetRequestToken,
              completion: @escaping (CoreSetRequestToken, CoreSetStopOutcome) -> Void) {
        precondition(Thread.isMainThread)
        guard coordinator?.restoreFrameRate() == true else {
            completion(token, .failed(reason: "FPS 调度器基线恢复未获读回")); return
        }
        appliedObservation = nil; activeRequestToken = nil
        NSLog("Core-SET: scheduler stage=stop point=v17-029 token=%@/%@/%@ confirmed=1 scope=metal-scheduler-baseline measured-presentation-fps=0",
              token.generation.uuidString, token.consumerID.uuidString, token.requestID.uuidString)
        completion(token, .restored)
    }
}
