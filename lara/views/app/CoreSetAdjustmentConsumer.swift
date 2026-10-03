import UIKit

// Recolors only semantic commands already produced by the verified read-only
// player/material lanes. No game memory is written. Name/team text uses the
// verified PlayerName/TeamID fields only when the player information lane runs.
final class CoreSetAdjustmentConsumer: CoreSetFeatureConsumer {
    typealias State = CoreSetAdjustmentSettings
    let capability = CoreSetCapability.drawingAppearance
    private weak var coordinator: CoreSetRuntimeCoordinator?
    private var revision: UInt64 = 0
    private var pendingApply: (CoreSetRequestToken, State,
                               (CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void)?
    private var pendingStop: (CoreSetRequestToken, (CoreSetRequestToken, CoreSetStopOutcome) -> Void)?
    private var expectedSnapshot: UUID?
    private var expectedGeneration: UInt64?

    init(coordinator: CoreSetRuntimeCoordinator) { self.coordinator = coordinator }

    var availability: CoreSetAvailability {
        coordinator?.playerCanvas != nil &&
            (coordinator?.playerStyleReady == true || coordinator?.materialStyleReady == true)
            ? .ready : .unavailable(reason: "目标只读绘制 lane 或本地宿主未就绪")
    }
    var supportedFields: Set<CoreSetField> {
        guard availability == .ready else { return [] }
        var result: Set<CoreSetField> = []
        if coordinator?.playerStyleReady == true {
            for scope in [CoreSetActorScope.player, .bot] {
                result.formUnion([.actorColor(scope, .name), .actorColor(scope, .ray),
                                  .actorColor(scope, .distance), .actorColor(scope, .bone),
                                  .actorColor(scope, .team)])
            }
            result.formUnion([.rayThickness, .boneThickness])
        }
        if coordinator?.materialStyleReady == true { result.insert(.materialFontSize) }
        return result
    }

    private func accepts(_ state: State) -> Bool {
        if coordinator?.playerStyleReady != true &&
            (state.player.name != nil || state.player.team != nil ||
             state.bot.name != nil || state.bot.team != nil ||
             state.player.ray != nil || state.player.distance != nil || state.player.bone != nil ||
             state.bot.ray != nil || state.bot.distance != nil || state.bot.bone != nil ||
             state.rayThickness.value != nil || state.boneThickness.value != nil) { return false }
        if coordinator?.materialStyleReady != true && state.materialFontSize.value != nil { return false }
        return true
    }

    func apply(_ request: CoreSetApplyRequest<State>,
               completion: @escaping (CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void) {
        precondition(Thread.isMainThread)
        guard availability == .ready, accepts(request.desired), revision < UInt64.max,
              let canvas = coordinator?.playerCanvas else {
            completion(request.token, .unavailable(reason: "绘制字段或本地宿主未就绪")); return
        }
        revision += 1
        let id = UUID()
        expectedSnapshot = id; expectedGeneration = canvas.generation
        pendingApply = (request.token, request.desired, completion)
        let submission = CoreSetLaneSubmission(lane: .appearance,
            hostGeneration: canvas.generation, configRevision: revision,
            snapshotID: id, requestToken: request.token, canvasSize: canvas.size,
            commands: [], appearance: request.desired)
        if coordinator?.submitLane(submission) != true {
            pendingApply = nil; expectedSnapshot = nil; expectedGeneration = nil
            completion(request.token, .failed(reason: "样式帧未进入合成器"))
        }
    }

    func consumed(_ receipt: CoreSetLocalFrameReceipt) {
        guard receipt.lane == .appearance,
              receipt.configRevision == revision,
              receipt.snapshotID == expectedSnapshot,
              receipt.hostGeneration == expectedGeneration else { return }
        if let stop = pendingStop, stop.0 == receipt.requestToken {
            pendingStop = nil; expectedSnapshot = nil; expectedGeneration = nil
            stop.1(stop.0, receipt.acceptedByLocalRenderer ? .restored :
                .failed(reason: "样式恢复帧未获精确回执"))
            return
        }
        if let pending = pendingApply, pending.0 == receipt.requestToken {
            pendingApply = nil; expectedSnapshot = nil; expectedGeneration = nil
            guard receipt.acceptedByLocalRenderer, availability == .ready,
                  accepts(pending.1) else {
                pending.2(pending.0, .unavailable(reason: "样式帧或读取 lane 身份已失效")); return
            }
            pending.2(pending.0, .applied(observed: pending.1))
        }
    }

    func stop(_ token: CoreSetRequestToken,
              completion: @escaping (CoreSetRequestToken, CoreSetStopOutcome) -> Void) {
        precondition(Thread.isMainThread)
        pendingApply = nil
        guard revision < UInt64.max else {
            completion(token, .failed(reason: "样式序号耗尽")); return
        }
        revision += 1
        if let canvas = coordinator?.playerCanvas {
            let id = UUID()
            expectedSnapshot = id; expectedGeneration = canvas.generation
            pendingStop = (token, completion)
            if coordinator?.clearLane(.appearance, generation: canvas.generation,
                configRevision: revision, snapshotID: id, requestToken: token,
                canvasSize: canvas.size) == true { return }
            pendingStop = nil
        }
        completion(token, coordinator?.lastStopResult?.complete == true ? .restored :
            .failed(reason: "样式恢复未获确认"))
    }
}
