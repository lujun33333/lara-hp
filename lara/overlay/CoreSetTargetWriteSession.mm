#import "CoreSetTargetWriteSession.h"
#import "CoreSetReadSession.h"
#import "CoreSetPlayerSnapshot.h"
#import <QuartzCore/QuartzCore.h>
#import "CoreSetMappedPageWriteBackend.h"
#include "CoreSetTargetWriteContract.h"
#include "CoreSetActionEffectLedger.h"
#include "CoreSetActionInputReadContract.h"
#include <array>
#include <cmath>
#include <cstring>

@implementation CoreSetActionInputObservation
- (instancetype)init {
    if ((self = [super init])) _reason = @"controller-input-not-captured";
    return self;
}
+ (instancetype)capture:(CoreSetReadSession *)session snapshot:(CoreSetPlayerSnapshot *)snapshot {
    CoreSetActionInputObservation *observation = [CoreSetActionInputObservation new];
    observation->_reason = @"snapshot-battle-input-lease-unavailable";
    if (!snapshot || !snapshot.battleInputsPresent) return observation;
    CoreSet::ActionInputReadLease lease;
    lease.pid = snapshot.processID; lease.imageBase = snapshot.imageBase;
    lease.generation = snapshot.sessionGeneration; lease.controller = snapshot.controllerAddress;
    // connect/ready on CoreSetReadSession already validates this exact profile;
    // this constant is not independently capable of establishing a live lease.
    lease.uuid = CoreSet::ControlRotationWriteGate::kUUID;
    uuid_t snapshotBytes = {0}; [snapshot.snapshotID getUUIDBytes:snapshotBytes];
    memcpy(lease.snapshotID.data(), snapshotBytes, sizeof(snapshotBytes));
    lease.snapshotCompletedSeconds = snapshot.captureCompletedMonotonicSeconds;
    lease.capturedControl = {snapshot.controlPitchDegrees, snapshot.controlYawDegrees};
    auto identity = [&](const CoreSet::ActionInputReadLease &current) {
        return session.ready && session.processID == current.pid &&
            session.imageBase == current.imageBase && session.generation == current.generation &&
            snapshot.processID == current.pid && snapshot.imageBase == current.imageBase &&
            snapshot.sessionGeneration == current.generation && snapshot.controllerAddress == current.controller;
    };
    auto readOnly = [&](uint64_t address, void *output, size_t length) -> size_t {
        if (length != 8 || (address != lease.controller + 0x620 &&
                            address != lease.controller + 0x828)) return 0;
        size_t completed = 0;
        return [session readAt:address to:output length:length generation:lease.generation
            completedBytes:&completed error:nullptr] ? completed : 0;
    };
    const auto result = CoreSet::observeActionControllerInput(lease, identity, readOnly,
                                                            [] { return CACurrentMediaTime(); });
    observation->_complete = result.complete();
    observation->_inputFingerprint = result.inputFingerprint;
    observation->_controlBeforeFingerprint = result.controlBeforeFingerprint;
    observation->_controlAfterFingerprint = result.controlAfterFingerprint;
    observation->_completedMonotonicSeconds = result.completedSeconds;
    switch (result.status) {
        case CoreSet::ActionInputReadStatus::invalidLease: observation->_reason = @"controller-input-lease-or-profile-invalid"; break;
        case CoreSet::ActionInputReadStatus::invalidClock: observation->_reason = @"local-monotonic-clock-invalid-or-regressed"; break;
        case CoreSet::ActionInputReadStatus::staleSnapshot: observation->_reason = @"snapshot-stale"; break;
        case CoreSet::ActionInputReadStatus::identityChanged: observation->_reason = @"snapshot-generation-or-identity-changed"; break;
        case CoreSet::ActionInputReadStatus::partialInput: observation->_reason = @"RotationInput-f32-pair-read-not-complete"; break;
        case CoreSet::ActionInputReadStatus::partialControl: observation->_reason = @"ControlRotation-f32-pair-read-not-complete"; break;
        case CoreSet::ActionInputReadStatus::nonfiniteValue: observation->_reason = @"controller-input-or-control-nonfinite-or-out-of-range"; break;
        case CoreSet::ActionInputReadStatus::controlChanged: observation->_reason = @"ControlRotation-changed-after-snapshot"; break;
        case CoreSet::ActionInputReadStatus::observed: observation->_reason = @"typed-controller-input-observed-not-atomic-not-authority"; break;
    }
    return observation;
}
@end

@implementation CoreSetTargetWriteCleanupResult
- (instancetype)initWithReadTaskPortReleased:(BOOL)readTaskPortReleased
                         mappedAliasReleased:(BOOL)mappedAliasReleased
                          generationAdvanced:(BOOL)generationAdvanced
                                  noInFlight:(BOOL)noInFlight {
    // Legacy callers provide no target restoration/no-effects proof.
    return [self initWithReadTaskPortReleased:readTaskPortReleased
        mappedAliasReleased:mappedAliasReleased generationAdvanced:generationAdvanced
        noInFlight:noInFlight targetEffectsResolved:NO];
}
- (instancetype)initWithReadTaskPortReleased:(BOOL)readTaskPortReleased
                         mappedAliasReleased:(BOOL)mappedAliasReleased
                          generationAdvanced:(BOOL)generationAdvanced
                                  noInFlight:(BOOL)noInFlight
                       targetEffectsResolved:(BOOL)targetEffectsResolved {
    if ((self = [super init])) {
        _readTaskPortReleased = readTaskPortReleased;
        _mappedAliasReleased = mappedAliasReleased;
        _generationAdvanced = generationAdvanced;
        _noInFlight = noInFlight;
        _targetEffectsResolved = targetEffectsResolved;
        _complete = readTaskPortReleased && mappedAliasReleased && generationAdvanced &&
            noInFlight && targetEffectsResolved;
    }
    return self;
}
@end

@implementation CoreSetTargetWriteResult
- (instancetype)initWithCommitted:(BOOL)committed pending:(BOOL)pending
                  completedBytes:(size_t)completedBytes reason:(NSString *)reason {
    if ((self = [super init])) {
        _committed = committed; _pending = pending;
        _completedBytes = completedBytes; _reason = [reason copy];
    }
    return self;
}
@end

@interface CoreSetTargetWriteSession () {
    CoreSetReadSession *_readSession;
    CoreSetMappedPageWriteBackend *_backend;
    id<CoreSetTargetWriteAuthority> _authority;
    CoreSet::ControlRotationWriteGate _gate;
    CoreSet::ActionEffectLedger _effects;
    uint64_t _generation;
    BOOL _pendingCleanup;
    BOOL _backendBound;
    BOOL _stopped;
}
@end

@implementation CoreSetTargetWriteSession
- (instancetype)init {
    return [self initWithRequestAuthority:nil];
}
- (instancetype)initWithRequestAuthority:(id<CoreSetTargetWriteAuthority> _Nullable)authority {
    if ((self = [super init])) {
        _readSession = [[CoreSetReadSession alloc] init];
        _readSession.diagnosticLabel = @"target-write";
        _backend = [[CoreSetMappedPageWriteBackend alloc] initWithReadSession:_readSession];
        _authority = authority;
        _generation = 1;
        if (!_authority) {
            NSLog(@"Core-SET: target-write stage=capability ready=0 committed=0 reason=active-request-snapshot-authority-unavailable");
        }
    }
    return self;
}
- (void)dealloc { [self disconnect]; }
- (BOOL)ready { @synchronized (self) { return _authority && !_stopped && !_pendingCleanup && _backend.ready; } }
- (uint64_t)capabilities { return self.ready ? UINT64_C(2) : 0; }
- (uint64_t)generation { @synchronized (self) { return _generation; } }
- (BOOL)pendingCleanup { @synchronized (self) { return _pendingCleanup; } }

- (CoreSetTargetWriteResult *)writeControllerActionForPID:(int32_t)pid
    imageBase:(uint64_t)imageBase controller:(uint64_t)controller
    lane:(CoreSetTargetWriteLane)lane slot:(CoreSetTargetWriteSlot)slot
    axis:(CoreSetTargetWriteAxis)axis
    generation:(uint64_t)generation requestToken:(NSUUID *)requestToken
    snapshotID:(NSUUID *)snapshotID expectedOld:(NSData *)expectedOld
    newValue:(NSData *)newValue {
    @synchronized (self) {
        if (_stopped)
            return [[CoreSetTargetWriteResult alloc] initWithCommitted:NO pending:_pendingCleanup
                completedBytes:0 reason:@"target write session stopped"];
        if (_pendingCleanup || _gate.pending() || _backend.pendingCleanup)
            return [[CoreSetTargetWriteResult alloc] initWithCommitted:NO pending:YES
                completedBytes:0 reason:@"target write cleanup pending"];
        uint64_t offset = 0;
        size_t length = 0;
        if (!CoreSet::ControlRotationWriteGate::shape(
                static_cast<CoreSet::TargetActionSlot>(slot),
                static_cast<CoreSet::TargetActionAxis>(axis), &offset, &length) ||
            (lane != CoreSetTargetWriteLaneAim && lane != CoreSetTargetWriteLaneRecoil) ||
            !requestToken || !snapshotID || expectedOld.length != length ||
            newValue.length != length || controller > UINT64_MAX - offset - length)
            return [[CoreSetTargetWriteResult alloc] initWithCommitted:NO pending:NO
                completedBytes:0 reason:@"target write request invalid"];
        if (!_authority || ![_authority authorizesPID:pid imageBase:imageBase
            generation:generation controller:controller lane:lane slot:slot axis:axis
            requestToken:requestToken snapshotID:snapshotID]) {
            _pendingCleanup = _backendBound;
            return [[CoreSetTargetWriteResult alloc] initWithCommitted:NO pending:_pendingCleanup
                completedBytes:0 reason:@"active request/snapshot authority unavailable"];
        }
        if (![_readSession connect] || _readSession.processID != pid ||
            _readSession.imageBase != imageBase || _readSession.generation != generation) {
            _pendingCleanup = _backendBound;
            return [[CoreSetTargetWriteResult alloc] initWithCommitted:NO pending:_pendingCleanup
                completedBytes:0 reason:@"target read identity changed"];
        }
        float rotation[2] = {0};
        memcpy(rotation, newValue.bytes, length);
        if (!std::isfinite(rotation[0]) || (length == 8 && !std::isfinite(rotation[1])))
            return [[CoreSetTargetWriteResult alloc] initWithCommitted:NO pending:NO
                completedBytes:0 reason:@"nonfinite controller action float"];
        if (!_backend.ready && ![_backend connectForController:controller]) {
            _pendingCleanup = _backendBound || _backend.pendingCleanup;
            return [[CoreSetTargetWriteResult alloc] initWithCommitted:NO pending:_pendingCleanup
                completedBytes:0 reason:@"verified mapped-page kernel profile unavailable or binding stale"];
        }
        _backendBound = YES;
        if (![_backend matchesPID:pid imageBase:imageBase generation:generation controller:controller]) {
            _pendingCleanup = YES;
            return [[CoreSetTargetWriteResult alloc] initWithCommitted:NO pending:YES
                completedBytes:0 reason:@"mapped-page binding changed"];
        }

        CoreSet::ControlRotationLease lease;
        lease.pid = pid; lease.imageBase = imageBase; lease.generation = generation;
        lease.controller = controller; lease.uuid = CoreSet::ControlRotationWriteGate::kUUID;
        lease.lane = static_cast<CoreSet::TargetActionLane>(lane);
        lease.slot = static_cast<CoreSet::TargetActionSlot>(slot);
        lease.axis = static_cast<CoreSet::TargetActionAxis>(axis);
        uuid_t tokenBytes = {0}, snapshotBytes = {0};
        [requestToken getUUIDBytes:tokenBytes]; [snapshotID getUUIDBytes:snapshotBytes];
        memcpy(lease.requestToken.data(), tokenBytes, lease.requestToken.size());
        memcpy(lease.snapshotID.data(), snapshotBytes, lease.snapshotID.size());
        std::array<uint8_t, 8> oldBytes{}, newBytes{};
        memcpy(oldBytes.data(), expectedOld.bytes, length);
        memcpy(newBytes.data(), newValue.bytes, length);
        const uint64_t writeGeneration = _generation;
        auto identity = [&](const CoreSet::ControlRotationLease &current) {
            return current.pid == pid && current.imageBase == imageBase &&
                current.generation == generation && current.controller == controller &&
                current.lane == lease.lane && current.slot == lease.slot &&
                current.axis == lease.axis &&
                current.requestToken == lease.requestToken &&
                current.snapshotID == lease.snapshotID && _generation == writeGeneration &&
                [_authority authorizesPID:pid imageBase:imageBase generation:generation
                    controller:controller lane:lane slot:slot axis:axis
                    requestToken:requestToken snapshotID:snapshotID] &&
                [_backend matchesPID:pid imageBase:imageBase generation:generation controller:controller];
        };
        auto read = [&](uint64_t address, void *buffer, size_t length) -> size_t {
            size_t completed = 0;
            NSString *error = nil;
            return [_readSession readAt:address to:buffer length:length generation:generation
                completedBytes:&completed error:&error] ? completed : 0;
        };
        auto write = [&](uint64_t address, const void *buffer, size_t length) -> size_t {
            if (address != controller + offset || length != expectedOld.length) return 0;
            // Mark BEFORE calling the backend: partial/zero returns cannot
            // independently prove that no effect occurred on the target.
            _effects.markWriteAttempt();
            NSLog(@"Core-SET: target-write stage=write-attempt lane=%u slot=%u axis=%u unresolvedEffects=1 effectEpoch=%llu request=%@ snapshot=%@",
                (unsigned)lane, (unsigned)slot, (unsigned)axis,
                (unsigned long long)_effects.attemptEpoch(), requestToken.UUIDString, snapshotID.UUIDString);
            return [_backend writeControllerSlot:slot axis:axis controller:controller
                                           bytes:buffer length:length];
        };
        auto result = _gate.transact(lease, oldBytes, newBytes, identity, read, write);
        _pendingCleanup = result.pending || _backend.pendingCleanup;
        BOOL committed = result.status == CoreSet::ControlRotationWriteStatus::committed;
        return [[CoreSetTargetWriteResult alloc] initWithCommitted:committed
            pending:_pendingCleanup completedBytes:result.completedBytes
            reason:committed ? @"read-compare-mapped-write-independent-readback committed" :
                [NSString stringWithFormat:@"write gate status %d", (int)result.status]];
    }
}

- (CoreSetTargetWriteCleanupResult *)disconnect {
    @synchronized (self) {
        _stopped = YES; // Reject late requests before any new read/backend connection.
        BOOL drained = _gate.stopAfterDrain();
        BOOL backendClean = [_backend disconnect];
        BOOL mappedReleased = _backend.aliasesReleased;
        CoreSetReadCleanupResult *readCleanup = [_readSession disconnect];
        BOOL advanced = _generation != UINT64_MAX;
        if (advanced) ++_generation;
        const BOOL effectsResolved = _effects.targetEffectsResolved();
        _pendingCleanup = _pendingCleanup || !backendClean || !drained || !readCleanup.complete ||
            !advanced || !mappedReleased || !effectsResolved;
        if (!effectsResolved) {
            NSLog(@"Core-SET: target-write stage=stop ready=0 targetEffectsResolved=0 effectEpoch=%llu reason=explicit-independent-restoration-receipt-unavailable noAutomaticWriteback=1 noRotationInputClear=1",
                  (unsigned long long)_effects.attemptEpoch());
        }
        return [[CoreSetTargetWriteCleanupResult alloc]
            initWithReadTaskPortReleased:readCleanup.taskPortReleased && readCleanup.transportReleased
            mappedAliasReleased:mappedReleased
            generationAdvanced:advanced && readCleanup.generationAdvanced
            noInFlight:drained && backendClean targetEffectsResolved:effectsResolved];
    }
}
@end
