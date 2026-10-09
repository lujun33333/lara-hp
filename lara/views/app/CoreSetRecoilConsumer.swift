import Foundation

// Recoil is a typed facade over the same serial Core v1.7 action worker used
// by Aim. This prevents independent timers from racing +0x620/+0x828 and keeps
// c416c/c571c history, same-cycle slot selection and the final write receipt in one owner.
final class CoreSetRecoilConsumer: CoreSetFeatureConsumer {
    typealias State = CoreSetRecoilSettings
    let capability = CoreSetCapability.recoilControl
    private weak var actionConsumer: CoreSetAimConsumer?

    init(actionConsumer: CoreSetAimConsumer) {
        self.actionConsumer = actionConsumer
    }

    var availability: CoreSetAvailability {
        actionConsumer?.recoilAvailability ?? .unavailable(reason: "共享 Aim/Recoil 动作 worker 已释放")
    }
    var supportedFields: Set<CoreSetField> {
        [.recoilEnabled, .recoilStopWhenNotFiring, .recoilVerticalEnabled,
         .recoilVerticalStrength, .recoilHorizontalEnabled, .recoilHorizontalStrength]
    }
    var configurableFields: Set<CoreSetField> { supportedFields }

    func apply(_ request: CoreSetApplyRequest<State>,
               completion: @escaping (CoreSetRequestToken, CoreSetApplyOutcome<State>) -> Void) {
        guard let actionConsumer else {
            completion(request.token, .unavailable(reason: "共享 Aim/Recoil 动作 worker 已释放")); return
        }
        actionConsumer.applyRecoil(request, completion: completion)
    }

    func stop(_ token: CoreSetRequestToken,
              completion: @escaping (CoreSetRequestToken, CoreSetStopOutcome) -> Void) {
        guard let actionConsumer else {
            completion(token, .failed(reason: "共享 Aim/Recoil 动作 worker 已释放")); return
        }
        actionConsumer.stopRecoil(token, completion: completion)
    }

    // CoreSetRuntimeCoordinator shuts the shared owner down through
    // CoreSetAimConsumer before asking this facade for its local receipt.
    func shutdownWriteSession() -> Bool { true }
}
