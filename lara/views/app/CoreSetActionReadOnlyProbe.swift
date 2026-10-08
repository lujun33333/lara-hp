import Foundation
import CoreGraphics
import QuartzCore

// Bounded diagnostic capture through the existing audited read API only.
// It neither selects a candidate nor supplies request/snapshot write authority.
// The unit canvas is synthetic and no commands or presented-frame claims exist.
final class CoreSetActionReadOnlyProbe {
    private let lane: String
    private let session = CoreSetReadSession()
    private let worker: DispatchQueue
    private let lock = NSLock()
    private var stopped = false
    private var inFlight = false
    private var cleanupConfirmed = true
    private var lastAttempt = -Double.infinity
    private var cycle: UInt64 = 0

    init(lane: String) {
        self.lane = lane
        worker = DispatchQueue(label: "core-set.action-read-probe.\(lane)")
        session.diagnosticLabel = "\(lane)-action-probe"
    }

    func requestIfDue() {
        lock.lock()
        let now = CACurrentMediaTime()
        guard !stopped, !inFlight, now - lastAttempt >= 30, cycle != UInt64.max else {
            lock.unlock(); return
        }
        inFlight = true
        cleanupConfirmed = false
        lastAttempt = now
        cycle += 1
        let captureCycle = cycle
        lock.unlock()
        worker.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let cancelled = self.stopped
            self.lock.unlock()
            if !cancelled {
                if self.session.connect() {
                    let failuresBefore = self.session.readFailureSequence
                    let snapshot = CoreSetPlayerCollector.capture(self.session,
                        canvasSize: CGSize(width: 2, height: 2), playerBones: false,
                        botBones: false, boneDistanceLimit: 0, includeOffscreen: false,
                        includeRadar: false, includeBattleInputs: true)
                    self.lock.lock()
                    let stillCurrent = !self.stopped && self.cycle == captureCycle
                    self.lock.unlock()
                    if stillCurrent, let snapshot = snapshot, snapshot.battleInputsPresent,
                       self.session.ready,
                       snapshot.sessionGeneration == self.session.generation,
                       snapshot.processID == self.session.processID,
                       snapshot.imageBase == self.session.imageBase {
                        let age = CACurrentMediaTime() - snapshot.captureCompletedMonotonicSeconds
                        if age >= 0, age <= 0.5 {
                            NSLog("Core-SET: action-read-probe lane=%@ cycle=%llu stage=inputs-observed complete=1 writeReady=0 originalEffectConfirmed=0 captureGeneration=%llu snapshot=%@ ads=%d fire=%d canvas=synthetic-unit selector=not-run slotRoute=unresolved",
                                  self.lane, captureCycle, snapshot.sessionGeneration,
                                  snapshot.snapshotID.uuidString, snapshot.localADS ? 1 : 0,
                                  snapshot.localFiring ? 1 : 0)
                            let inputFailuresBefore = self.session.readFailureSequence
                            let inputs = CoreSetActionInputObservation.capture(self.session, snapshot: snapshot)
                            let diagnostic = self.session.readFailureSequence != inputFailuresBefore
                                ? self.session.lastReadDiagnostic : "transport-errors=0"
                            self.lock.lock()
                            let inputStillCurrent = !self.stopped && self.cycle == captureCycle
                            self.lock.unlock()
                            if inputStillCurrent {
                                NSLog("Core-SET: action-read-probe lane=%@ cycle=%llu stage=controller-input-observed complete=%d writeReady=0 originalEffectConfirmed=0 captureGeneration=%llu snapshot=%@ inputFingerprint=%016llx controlBeforeFingerprint=%016llx controlAfterFingerprint=%016llx fingerprintScope=diagnostic-fnv1a64-not-authority objectLifetimeAtomic=0 selector=not-run slotRoute=unissued reason=%@ transport=%@",
                                      self.lane, captureCycle, inputs.complete ? 1 : 0,
                                      snapshot.sessionGeneration, snapshot.snapshotID.uuidString,
                                      inputs.inputFingerprint, inputs.controlBeforeFingerprint,
                                      inputs.controlAfterFingerprint, inputs.reason, diagnostic)
                            }
                        } else {
                            NSLog("Core-SET: action-read-probe lane=%@ cycle=%llu stage=capture complete=0 writeReady=0 reason=snapshot-stale captureAge=%.6f",
                                  self.lane, captureCycle, age)
                        }
                    } else if stillCurrent {
                        let reason = self.session.readFailureSequence != failuresBefore
                            ? self.session.lastReadDiagnostic
                            : "snapshot-validation-or-identity-failed transport-errors=0"
                        NSLog("Core-SET: action-read-probe lane=%@ cycle=%llu stage=capture complete=0 writeReady=0 reason=%@",
                              self.lane, captureCycle, reason)
                    }
                } else {
                    NSLog("Core-SET: action-read-probe lane=%@ cycle=%llu stage=connect complete=0 writeReady=0 reason=%@",
                          self.lane, captureCycle, self.session.lastConnectDiagnostic)
                }
            }
            let cleanup = self.session.disconnect()
            self.lock.lock()
            self.cleanupConfirmed = cleanup.taskPortReleased && cleanup.generationAdvanced
            self.inFlight = false
            self.lock.unlock()
        }
    }

    func stop(completion: @escaping (Bool) -> Void) {
        lock.lock(); stopped = true; lock.unlock()
        // Same serial queue: every earlier capture has finished before cleanup
        // is acknowledged. No future requests are accepted after stopped=true.
        worker.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion(false) }; return
            }
            let cleanup = self.session.disconnect()
            self.lock.lock()
            self.cleanupConfirmed = cleanup.taskPortReleased && cleanup.generationAdvanced
            let complete = !self.inFlight && self.cleanupConfirmed
            self.lock.unlock()
            DispatchQueue.main.async { completion(complete) }
        }
    }

    func stopIfIdle() -> Bool {
        lock.lock()
        stopped = true
        let complete = !inFlight && cleanupConfirmed
        lock.unlock()
        // An in-flight worker owns and releases its read lease before clearing
        // inFlight. Returning false keeps the owner's cleanup responsibility.
        return complete
    }
}
