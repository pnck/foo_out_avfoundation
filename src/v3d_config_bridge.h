//
//  v3d_config_bridge.h
//  foo_out_avfoundation
//
//  Objective-C face of foo_out_avf::v3d_config, so the Swift UI can read/write settings without
//  touching C++ directly. Exposed to Swift via the bridging header. Class properties keep the Swift
//  call sites terse (V3DConfig.sourceX = ...). Writes persist immediately (configStore).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface V3DConfig : NSObject

@property(class, nonatomic) BOOL virtual3DEnabled; // output mode: YES = Virtual3D, NO = SystemSpatial
@property(class, nonatomic) double sourceX;
@property(class, nonatomic) double sourceY;
@property(class, nonatomic) double sourceZ;
@property(class, nonatomic) double size;
@property(class, nonatomic) double spread;

@end

NS_ASSUME_NONNULL_END
