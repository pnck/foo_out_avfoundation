//
//  engine_virtual_3d.h
//  foo_out_avfoundation
//
//  V3D positional backend (declaration). AVAudioEngine + AVAudioPlayerNode + AVAudioEnvironmentNode,
//  rendering in-process with HRTFHQ so the user can place the source at a custom point in a virtual
//  field — the path the system spatializer (engine_sys_spatialized.mm) cannot offer. Selected when the
//  engine's OutputMode is Virtual3D. Implementation + design notes in engine_virtual_3d.mm.
//

#pragma once

#import "engine.h"

#ifdef __OBJC__
@interface AVFVirtual3DBackend : NSObject <AVFOutputBackend>
- (instancetype)init;
// Re-declared from AVFOutputBackend so they auto-synthesize here (see engine.h).
@property(nonatomic, readonly, getter=isEnabled) bool isEnabled;
@property(nonatomic, readonly, getter=isPaused) bool isPaused;
@property(nonatomic, readonly, getter=isProgressing) bool isProgressing;
@end
#endif // __OBJC__
