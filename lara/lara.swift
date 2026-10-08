//
//  lara.swift
//  lara
//
//  Created by ruter on 23.03.26.
//

import UIKit
import UniformTypeIdentifiers

let g_isunsupported: Bool = isunsupported()
var weonadebugbuild_pjbweouttahereexclamationmark: Bool = false

@main
final class LaraAppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        CoreSetBackgroundAudio.shared.start()
        bootstrapLaraApplication()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if CoreSetFloatingSceneManager.isFloating(identifier: connectingSceneSession.persistentIdentifier) {
            let configuration = UISceneConfiguration(
                name: "Core Floating Configuration",
                sessionRole: connectingSceneSession.role
            )
            configuration.delegateClass = CoreSetFloatingSceneDelegate.self
            return configuration
        }
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = LaraSceneDelegate.self
        return configuration
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .portrait
    }

    func applicationWillTerminate(_ application: UIApplication) {
        NSLog("Core-SET: shutdown stage=begin")
        var finished = false
        CoreSetRuntimeCoordinator.stopAllForTermination {
            laramgr.shared.terminateRemoteCallSession {
                finished = true
                NSLog("Core-SET: shutdown stage=remote-session-destroyed complete=1")
                CFRunLoopStop(CFRunLoopGetMain())
            }
        }
        // Keep the main run loop alive until the remaining feature session
        // and floating-scene ownership have completed their shutdown callbacks.
        while !finished { CFRunLoopRun() }
        CoreSetBackgroundAudio.shared.stop()
        NSLog("Core-SET: shutdown stage=complete")
    }
}

@objc(QxF1)
final class CoreSetFloatingSceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        CoreSetFloatingSceneManager.shared().connect(
            scene: windowScene,
            identifier: session.persistentIdentifier
        )
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else { return }
        CoreSetFloatingSceneManager.shared().disconnect(scene: windowScene)
    }
}

@objc(ZeqcgKhNvh)
final class LaraSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var coreSetRuntime: CoreSetRuntimeCoordinator?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        CoreSetBackgroundAudio.shared.start()
        let window = UIWindow(windowScene: windowScene)
        self.window = window
        window.backgroundColor = .black
        let launcher = CoreSetLauncherViewController(
            authorizationState: .initialForCurrentBuild
        )
        let runtime = CoreSetRuntimeCoordinator(scene: windowScene, launcher: launcher)
        coreSetRuntime = runtime
        launcher.coreSetRuntime = runtime
        window.rootViewController = launcher
        window.makeKeyAndVisible()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        coreSetRuntime?.activate()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
    }

    func sceneWillResignActive(_ scene: UIScene) {
        coreSetRuntime?.deactivate()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        coreSetRuntime?.deactivate()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Coordinator retains itself until window cleanup AND stop receipts finish.
        _ = coreSetRuntime?.stop()
        coreSetRuntime = nil
    }
}

private func bootstrapLaraApplication() {
    #if DEBUG
    weonadebugbuild_pjbweouttahereexclamationmark = true
    #endif

    // fix file picker
    let fixMethod = class_getInstanceMethod(
        UIDocumentPickerViewController.self,
        #selector(UIDocumentPickerViewController.fix_init(forOpeningContentTypes:asCopy:))
    )!
    let origMethod = class_getInstanceMethod(
        UIDocumentPickerViewController.self,
        #selector(UIDocumentPickerViewController.init(forOpeningContentTypes:asCopy:))
    )!
    method_exchangeImplementations(origMethod, fixMethod)

    globallogger.capture()
}

// file picker fixes
extension UIDocumentPickerViewController {
    @objc func fix_init(forOpeningContentTypes contentTypes: [UTType], asCopy: Bool) -> UIDocumentPickerViewController {
        return fix_init(forOpeningContentTypes: contentTypes, asCopy: true)
    }
}

// make strings compatiable with errors
extension String: @retroactive Error {}
