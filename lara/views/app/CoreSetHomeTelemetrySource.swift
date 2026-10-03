import Foundation

// Read-only observations are not feature action receipts. Each supported
// field has an observed producer and can disappear independently.
enum CoreSetHomeObservationField: Hashable {
    case kernel, stage, environment, information, floating, kernelProgress
}

struct CoreSetHomeObservation {
    let snapshot: CoreSetHomeSnapshot
    let supportedFields: Set<CoreSetHomeObservationField>
}

final class CoreSetHomeTelemetrySource {
    func capture(hostReady: Bool, panelVisible: Bool, cleanupPending: Bool,
                 remoteHosted: Bool, targetReadReady: Bool) -> CoreSetHomeObservation {
        precondition(Thread.isMainThread)
        let manager = laramgr.shared
        let nativeReady = manager.dsready && ds_is_ready()
        var supported: Set<CoreSetHomeObservationField> = []
        var kernel: String?
        if manager.dsrunning {
            kernel = "DarkSword 初始化中"
        } else if nativeReady {
            kernel = "DarkSword 已就绪"
        } else if manager.dsfailed {
            kernel = "DarkSword 初始化失败"
        } else if manager.dsattempted {
            kernel = "DarkSword 未就绪"
        }
        if kernel != nil { supported.insert(.kernel) }
        let stage = manager.dsrunning ? "DarkSword 初始化进行中" : nil
        if stage != nil { supported.insert(.stage) }
        let environment = nativeReady ? "本应用内核访问已核对" : nil
        if environment != nil { supported.insert(.environment) }
        let information = targetReadReady ? "目标只读身份已核对" : nil
        if information != nil { supported.insert(.information) }
        let floating: String?
        if cleanupPending {
            floating = "悬浮资源清理待确认"
        } else if remoteHosted && hostReady {
            floating = panelVisible ? "跨应用双面挂接已回读 · 菜单显示" : "跨应用双面挂接已回读"
        } else if hostReady {
            floating = panelVisible ? "本应用悬浮已显示" : "本应用悬浮已就绪"
        } else {
            floating = nil
        }
        if floating != nil { supported.insert(.floating) }
        // dsprogress is set to 1 even on failure; never display it as a
        // completion/success receipt after dsrunning becomes false.
        let progress = manager.dsprogress
        let kernelProgress = manager.dsrunning && progress.isFinite &&
            (0...1).contains(progress) ? progress : nil
        if kernelProgress != nil { supported.insert(.kernelProgress) }
        let snapshot = CoreSetHomeSnapshot(kernel: kernel, stage: stage,
            environment: environment, information: information, floating: floating,
            executing: manager.dsrunning, status: nil,
            completedPages: nil, totalPages: nil, environmentStage: nil,
            downloadedBytes: nil, totalBytes: nil,
            kernelProgressFraction: kernelProgress)
        return CoreSetHomeObservation(snapshot: snapshot, supportedFields: supported)
    }
}
