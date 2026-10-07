import AVFoundation
import UIKit

// The overlay keeps one audio owner for its whole app session. The launcher
// music has its own player, but shares this playback/mixWithOthers session.
@MainActor
final class CoreSetBackgroundAudio {
    static let shared = CoreSetBackgroundAudio()

    private var player: AVAudioPlayer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []
    private var watchdog: DispatchSourceTimer?
    private var recoveryEpoch: UInt64 = 0
    private var enabled = false
    private var lastStage = ""
    private var lastHeartbeatUptime: TimeInterval = 0

    private init() {}

    func start() {
        guard !enabled else { return }
        enabled = true
        stage("start")
        installObservers()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, self.enabled else { return }
            self.backgroundHeartbeatIfDue()
            guard self.player?.isPlaying != true else { return }
            self.recover(reason: "watchdog")
        }
        watchdog = timer
        timer.resume()
        if !play() { recover(reason: "start-failed") }
    }

    func stop() {
        guard enabled else { return }
        enabled = false
        recoveryEpoch &+= 1
        watchdog?.cancel()
        watchdog = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        player?.stop()
        player = nil
        endBackgroundTask()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        stage("stop")
        // This is reached only on app termination or after the last scene's
        // asynchronous HUD cleanup. HUD exit alone must not stop this owner.
    }

    private func stage(_ value: String) {
        guard lastStage != value else { return }
        lastStage = value
        globallogger.log("Core-SET: background-audio stage=\(value) playing=\(isPlaying ? 1 : 0)")
    }

    var isPlaying: Bool { player?.isPlaying == true }

    private func backgroundHeartbeatIfDue(force: Bool = false) {
        guard UIApplication.shared.applicationState == .background else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        guard force || uptime - lastHeartbeatUptime >= 15 else { return }
        lastHeartbeatUptime = uptime
        globallogger.log("Core-SET: background-audio stage=heartbeat playing=\(isPlaying ? 1 : 0) task=\(backgroundTask == .invalid ? 0 : 1) uptime=\(Int(uptime))")
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.recover(reason: "interruption")
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.player?.stop()
            self?.player = nil
            self?.recover(reason: "media-reset")
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: nil, queue: .main) { [weak self] notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.intValue ?? 0
            if reason == 1 || reason == 2 || reason == 4 { self?.recover(reason: "route-change") }
        })
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.recover(reason: "app-state")
                self?.backgroundHeartbeatIfDue(force: true)
            })
        }
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.endBackgroundTask()
        })
    }

    private func recover(reason: String) {
        guard enabled else { return }
        beginBackgroundTask()
        recoveryEpoch &+= 1
        let epoch = recoveryEpoch
        stage("recover-\(reason)")
        for delay in [0.0, 0.2, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.enabled, self.recoveryEpoch == epoch else { return }
                if self.play() {
                    self.recoveryEpoch &+= 1
                    self.endBackgroundTask()
                }
            }
        }
    }

    private func play() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if let player {
                let success = player.isPlaying || player.play()
                if success { stage("playing") }
                return success
            }
            let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
            let url = cache.appendingPathComponent("core-set-keepalive.wav")
            try makeWave().write(to: url, options: .atomic)
            let candidate = try AVAudioPlayer(contentsOf: url)
            candidate.numberOfLoops = -1
            candidate.volume = 0.08
            guard candidate.prepareToPlay(), candidate.isPlaying || candidate.play() else {
                stage("play-failed")
                return false
            }
            player = candidate
            stage("playing")
            return true
        } catch {
            stage("play-failed")
            return false
        }
    }

    private func makeWave() -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            Swift.withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(88236))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(44100)); append(UInt32(88200))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(88200))
        for index in 0..<44100 {
            append(Int16(index.isMultiple(of: 2) ? -8 : 8))
        }
        return data
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "CoreSetHUDKeepAlive") { [weak self] in
            self?.stage("expire")
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
