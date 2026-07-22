// PeonPadEngineHost.mm
//
// Objective-C++ implementation of the engine lifecycle boundary. See the
// header for the threading contract.
#import "PeonPadEngineHost.h"

#include <atomic>
#include <string>
#include <vector>
#include <unistd.h>

#import <Foundation/Foundation.h>

// The engine entry point is a C++ symbol (engine/stratagus/src/stratagus/
// stratagus.cpp). Declared here so this translation unit does not need the
// engine's headers; it is resolved at link time against libstratagus_lib.a.
extern int stratagusMain(int argc, char **argv);

// SDL3 refuses to initialize any subsystem unless it knows the app has taken
// over main(). Because our real entry point is the SwiftUI @main (not SDL's
// SDL_main), we must tell SDL the main function is ready before the engine
// calls SDL_Init; otherwise SDL_InitSubSystem fails with "Application didn't
// initialize properly, did you include SDL_main.h…". Resolved from libSDL3.a.
extern "C" void SDL_SetMainReady(void);

@implementation PeonPadEngineHost {
    std::atomic<PeonPadEngineState> _state;
    NSString *_failureReason;   // guarded by @synchronized(self)
    BOOL _started;              // guarded by @synchronized(self)
}

- (instancetype)init
{
    if ((self = [super init])) {
        _state.store(PeonPadEngineStateIdle);
        _started = NO;
    }
    return self;
}

- (PeonPadEngineState)state
{
    return _state.load();
}

- (nullable NSString *)failureReason
{
    @synchronized(self) {
        return _failureReason;
    }
}

- (void)setFailure:(NSString *)reason
{
    @synchronized(self) {
        _failureReason = [reason copy];
    }
    _state.store(PeonPadEngineStateFailed);
}

- (BOOL)startWithArguments:(NSArray<NSString *> *)arguments
{
    @synchronized(self) {
        if (_started) {
            return NO;
        }
        _started = YES;
    }

    // Initialize the bridge command/snapshot infrastructure on the thread that
    // will run the simulation loop. peonpad_tabletop_init() returns -1 if it
    // was already initialized, which we tolerate (idempotent restart).
    _state.store(PeonPadEngineStateStarting);

    // The engine owns an SDL render loop that must not run on the app main
    // thread. Request an offscreen/dummy video driver so the engine simulates
    // without opening its own window; the RealityKit board is the display.
    // Callers may override via the environment before start.
    if (getenv("SDL_VIDEODRIVER") == nullptr) {
        setenv("SDL_VIDEODRIVER", "offscreen", 1);
    }

    // Copy the Swift argv into a C-owned, NUL-terminated argv that outlives the
    // engine thread. The engine keeps pointers into argv, so it must remain
    // valid for the process lifetime; we intentionally leak it (engine runs
    // until process exit).
    NSArray<NSString *> *argsCopy = [arguments copy];
    __block PeonPadEngineHost *weakGuard = self;

    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        const NSUInteger argc = argsCopy.count;
        std::vector<std::string> storage;
        storage.reserve(argc);
        for (NSString *arg in argsCopy) {
            storage.emplace_back(arg.UTF8String ? arg.UTF8String : "");
        }
        char **argv = new char *[argc + 1];
        for (NSUInteger i = 0; i < argc; ++i) {
            argv[i] = const_cast<char *>(storage[i].c_str());
        }
        argv[argc] = nullptr;

        // Run with the game-data directory (the value passed via -d) as the
        // working directory. Stratagus resolves the CLI scenario and other
        // relative resources against the process CWD, and the conventional
        // runtime environment is CWD == data dir.
        for (NSUInteger i = 0; i + 1 < argc; ++i) {
            if (storage[i] == "-d") {
                chdir(storage[i + 1].c_str());
                break;
            }
        }

        // Set up the bridge before the game loop begins publishing.
        peonpad_tabletop_init();
        // Signal SDL that main() is handled by the app before the engine's
        // SDL_Init runs on this thread.
        SDL_SetMainReady();
        weakGuard->_state.store(PeonPadEngineStateRunning);

        int rc = -1;
        @try {
            rc = stratagusMain(static_cast<int>(argc), argv);
        } @catch (NSException *ex) {
            [weakGuard setFailure:
                [NSString stringWithFormat:@"engine threw: %@", ex.reason]];
        }

        // stratagusMain only returns when the engine exits. Reaching here means
        // the engine is no longer running; distinguish a clean stop from a
        // failure by the current state.
        if (weakGuard->_state.load() != PeonPadEngineStateStopped) {
            if (rc == 0) {
                weakGuard->_state.store(PeonPadEngineStateStopped);
            } else {
                [weakGuard setFailure:
                    [NSString stringWithFormat:@"engine exited with code %d", rc]];
            }
        }
        // storage/argv are intentionally not freed while the engine may still
        // reference them; on the return path the process is tearing down.
    }];
    thread.name = @"org.peonpad.tabletop.engine";
    thread.stackSize = 8 * 1024 * 1024;  // engine uses a deep call stack
    [thread start];
    return YES;
}

- (void)shutdown
{
    // Mark stopped first so the engine-thread return path does not misreport a
    // clean shutdown as a failure, then tear down the bridge.
    _state.store(PeonPadEngineStateStopped);
    peonpad_tabletop_cleanup();
}

@end
