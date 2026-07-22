// PeonPadEngineHost.h
//
// Objective-C++ lifecycle boundary that boots the Stratagus/Wargus engine on a
// dedicated thread and drives the visionOS tabletop bridge C ABI. The Swift
// EngineTabletopTransport owns an instance of this host: it validates data and
// user paths (EngineStartupPlanner), starts the host, then polls the bridge's
// published snapshots and posts commands through the C ABI directly.
//
// The engine's own SDL render loop must not run on the app's main thread
// (SwiftUI/RealityKit own it), so the engine runs on a dedicated background
// thread with an offscreen SDL video driver; the RealityKit board is the real
// display. The bridge publishes coherent snapshots after every game tick.
//
// This header is safe to include from a Swift bridging header: it exposes only
// Foundation and the C ABI.
#import <Foundation/Foundation.h>
#include "PeonPadTabletopBridge.h"

/// Coarse engine lifecycle state, observed by the transport to surface a
/// visible readiness/failure state on the board (never a silent fallback).
typedef NS_ENUM(NSInteger, PeonPadEngineState) {
    PeonPadEngineStateIdle = 0,     ///< Not started.
    PeonPadEngineStateStarting = 1, ///< Thread launched; awaiting first tick.
    PeonPadEngineStateRunning = 2,  ///< Engine thread is running.
    PeonPadEngineStateFailed = 3,   ///< Engine thread exited abnormally / never ran.
    PeonPadEngineStateStopped = 4,  ///< Shut down cleanly.
};

NS_ASSUME_NONNULL_BEGIN

@interface PeonPadEngineHost : NSObject

/// Current lifecycle state (thread-safe).
@property (atomic, readonly) PeonPadEngineState state;

/// Human-readable failure reason when `state == PeonPadEngineStateFailed`.
@property (atomic, readonly, nullable, copy) NSString *failureReason;

/// Initializes the bridge and boots the engine on a dedicated thread with the
/// given argv (as built by EngineStartupPlanner). Returns NO if the engine is
/// already started. The engine runs until `shutdown` or process exit.
- (BOOL)startWithArguments:(NSArray<NSString *> *)arguments;

/// Requests shutdown: tears down the bridge (stops publishing / flushes the
/// command queue) and marks the host stopped. Safe to call more than once.
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
