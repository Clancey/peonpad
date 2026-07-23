// PeonPadTabletop-Bridging-Header.h
//
// Swift/Objective-C++ bridging header for the visionOS tabletop app build.
// Passed to swiftc via -import-objc-header so the Swift transport can call the
// engine bridge C ABI and the Objective-C++ engine host directly.
//
// It exposes only the tabletop bridge C ABI (PeonPadTabletopBridge.h) and the
// engine lifecycle host (PeonPadEngineHost.h). No SDL, RealityKit, or engine
// headers cross this boundary.
#import "PeonPadEngineHost.h"
