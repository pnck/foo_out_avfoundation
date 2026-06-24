//
//  v3d_config_bridge.mm
//  foo_out_avfoundation
//
//  Bridges V3DConfig (ObjC, for Swift) onto foo_out_avf::v3d_config (C++/configStore). Each layout
//  setter is a read-modify-write of the whole Layout (it's tiny) so a single edited field still goes
//  through set_layout — which persists and bumps the generation the engine watches.
//

#import "v3d_config_bridge.h"
#import "v3d_config.h"

using namespace foo_out_avf;
using v3d_config::Layout;

namespace
{
    Layout cur() { return v3d_config::layout(); }
    void put(const Layout &l) { v3d_config::set_layout(l); }
} // namespace

@implementation V3DConfig

+ (BOOL)virtual3DEnabled { return v3d_config::mode() == OutputMode::Virtual3D; }
+ (void)setVirtual3DEnabled:(BOOL)v {
    v3d_config::set_mode(v ? OutputMode::Virtual3D : OutputMode::SystemSpatial);
}

+ (double)frontDistance { return cur().front.distance; }
+ (void)setFrontDistance:(double)v { Layout l = cur(); l.front.distance = v; put(l); }
+ (double)frontSpacing { return cur().front.spacingDeg; }
+ (void)setFrontSpacing:(double)v { Layout l = cur(); l.front.spacingDeg = v; put(l); }
+ (double)frontAzimuth { return cur().front.centerAzDeg; }
+ (void)setFrontAzimuth:(double)v { Layout l = cur(); l.front.centerAzDeg = v; put(l); }
+ (double)frontElevation { return cur().front.centerElDeg; }
+ (void)setFrontElevation:(double)v { Layout l = cur(); l.front.centerElDeg = v; put(l); }

+ (double)rearDistance { return cur().rear.distance; }
+ (void)setRearDistance:(double)v { Layout l = cur(); l.rear.distance = v; put(l); }
+ (double)rearSpacing { return cur().rear.spacingDeg; }
+ (void)setRearSpacing:(double)v { Layout l = cur(); l.rear.spacingDeg = v; put(l); }
+ (double)rearAzimuth { return cur().rear.centerAzDeg; }
+ (void)setRearAzimuth:(double)v { Layout l = cur(); l.rear.centerAzDeg = v; put(l); }
+ (double)rearElevation { return cur().rear.centerElDeg; }
+ (void)setRearElevation:(double)v { Layout l = cur(); l.rear.centerElDeg = v; put(l); }

+ (double)centerX { return cur().center.x; }
+ (void)setCenterX:(double)v { Layout l = cur(); l.center.x = v; put(l); }
+ (double)centerY { return cur().center.y; }
+ (void)setCenterY:(double)v { Layout l = cur(); l.center.y = v; put(l); }
+ (double)centerZ { return cur().center.z; }
+ (void)setCenterZ:(double)v { Layout l = cur(); l.center.z = v; put(l); }

+ (double)lfeX { return cur().lfe.x; }
+ (void)setLfeX:(double)v { Layout l = cur(); l.lfe.x = v; put(l); }
+ (double)lfeY { return cur().lfe.y; }
+ (void)setLfeY:(double)v { Layout l = cur(); l.lfe.y = v; put(l); }
+ (double)lfeZ { return cur().lfe.z; }
+ (void)setLfeZ:(double)v { Layout l = cur(); l.lfe.z = v; put(l); }

+ (NSArray<NSArray<NSNumber *> *> *)speakerPositions {
    const v3d_config::SpeakerPositions s = v3d_config::compute_speakers(cur());
    auto pt = [](const v3d_config::Vec3 &v) {
        return @[ @(v.x), @(v.y), @(v.z) ];
    };
    return @[ pt(s.fl), pt(s.fr), pt(s.c), pt(s.lfe), pt(s.rl), pt(s.rr) ];
}

+ (NSArray<NSNumber *> *)standard51Values {
    const Layout d = v3d_config::default_layout();
    return @[
        @(d.front.distance), @(d.front.spacingDeg), @(d.front.centerAzDeg), @(d.front.centerElDeg),
        @(d.rear.distance), @(d.rear.spacingDeg), @(d.rear.centerAzDeg), @(d.rear.centerElDeg),
        @(d.center.x), @(d.center.y), @(d.center.z),
        @(d.lfe.x), @(d.lfe.y), @(d.lfe.z)
    ];
}

+ (void)applyLayoutValues:(NSArray<NSNumber *> *)v mode:(BOOL)v3dEnabled {
    if (v.count >= 14) {
        Layout l;
        l.front = {v[0].doubleValue, v[1].doubleValue, v[2].doubleValue, v[3].doubleValue};
        l.rear = {v[4].doubleValue, v[5].doubleValue, v[6].doubleValue, v[7].doubleValue};
        l.center = {v[8].doubleValue, v[9].doubleValue, v[10].doubleValue};
        l.lfe = {v[11].doubleValue, v[12].doubleValue, v[13].doubleValue};
        v3d_config::set_layout(l); // single persist + one generation bump
    }
    v3d_config::set_mode(v3dEnabled ? OutputMode::Virtual3D : OutputMode::SystemSpatial);
}

@end
