import UIKit

// Registered public launch scheme from the supplied Peace Elite 1.38.12 Info.plist.
// This target only opens the installed app; it provides no game-data consumer.
enum CoreSetGameTarget {
    static let displayName = "和平精英"
    static let bundleIdentifier = "com.tencent.tmgp.pubgmhd"
    static let processName = "ShadowTrackerExtra"
    static let launchScheme = "tencentlaunch1106467070"

    enum OpenResult { case opened, unavailable, failed }

    static func openApplication(completion: @escaping (OpenResult) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { openApplication(completion: completion) }
            return
        }
        guard let url = URL(string: "\(launchScheme)://"), UIApplication.shared.canOpenURL(url) else {
            completion(.unavailable)
            return
        }
        UIApplication.shared.open(url, options: [:]) { opened in
            DispatchQueue.main.async { completion(opened ? .opened : .failed) }
        }
    }
}
