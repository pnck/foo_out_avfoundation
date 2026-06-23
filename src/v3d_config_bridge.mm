//
//  v3d_config_bridge.mm
//  foo_out_avfoundation
//
//  Bridges V3DConfig (ObjC, for Swift) onto foo_out_avf::v3d_config (C++/configStore).
//

#import "v3d_config_bridge.h"
#import "v3d_config.h"

using namespace foo_out_avf;

@implementation V3DConfig

+ (BOOL)virtual3DEnabled { return v3d_config::mode() == OutputMode::Virtual3D; }
+ (void)setVirtual3DEnabled:(BOOL)v {
    v3d_config::set_mode(v ? OutputMode::Virtual3D : OutputMode::SystemSpatial);
}

+ (double)sourceX { return v3d_config::source_position().x; }
+ (void)setSourceX:(double)v {
    auto p = v3d_config::source_position();
    p.x = v;
    v3d_config::set_source_position(p);
}
+ (double)sourceY { return v3d_config::source_position().y; }
+ (void)setSourceY:(double)v {
    auto p = v3d_config::source_position();
    p.y = v;
    v3d_config::set_source_position(p);
}
+ (double)sourceZ { return v3d_config::source_position().z; }
+ (void)setSourceZ:(double)v {
    auto p = v3d_config::source_position();
    p.z = v;
    v3d_config::set_source_position(p);
}

+ (double)size { return v3d_config::size(); }
+ (void)setSize:(double)v { v3d_config::set_size(v); }
+ (double)spread { return v3d_config::spread(); }
+ (void)setSpread:(double)v { v3d_config::set_spread(v); }

@end
