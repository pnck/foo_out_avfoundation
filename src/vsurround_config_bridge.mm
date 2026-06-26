//
//  vsurround_config_bridge.mm
//  foo_out_avfoundation
//
//  Bridges VSurroundConfig (ObjC, for Swift) onto foo_out_avf::vsurround_config (C++/configStore). Each layout
//  setter is a read-modify-write of the whole Layout (it's tiny) so a single edited field still goes
//  through set_layout — which persists and bumps the generation the engine watches.
//

#import "vsurround_config_bridge.h"
#import "vsurround_config.h"

using namespace foo_out_avf;
using vsurround_config::Layout;

namespace
{
    Layout cur() { return vsurround_config::layout(); }
    void put(const Layout &l) { vsurround_config::set_layout(l); }

    // Build a Layout from the 18-number value array the UI passes (geometry 0..13, gains 14..17).
    // Missing trailing values keep the factory default, so older/short arrays still work.
    Layout layoutFromValues(NSArray<NSNumber *> *v) {
        Layout l = vsurround_config::default_layout();
        if (v.count >= 14) {
            l.front = {v[0].doubleValue, v[1].doubleValue, v[2].doubleValue, v[3].doubleValue};
            l.rear = {v[4].doubleValue, v[5].doubleValue, v[6].doubleValue, v[7].doubleValue};
            l.center = {v[8].doubleValue, v[9].doubleValue, v[10].doubleValue};
            l.lfe = {v[11].doubleValue, v[12].doubleValue, v[13].doubleValue};
        }
        if (v.count >= 18) {
            l.frontGainDb = v[14].doubleValue;
            l.rearGainDb = v[15].doubleValue;
            l.centerGainDb = v[16].doubleValue;
            l.lfeGainDb = v[17].doubleValue;
        }
        return l;
    }
} // namespace

@implementation VSurroundConfig

+ (BOOL)virtualSurroundEnabled { return vsurround_config::mode() == OutputMode::VirtualSurround; }
+ (void)setVirtualSurroundEnabled:(BOOL)v {
    vsurround_config::set_mode(v ? OutputMode::VirtualSurround : OutputMode::SystemSpatial);
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

+ (double)frontGainDb { return cur().frontGainDb; }
+ (void)setFrontGainDb:(double)v { Layout l = cur(); l.frontGainDb = v; put(l); }
+ (double)rearGainDb { return cur().rearGainDb; }
+ (void)setRearGainDb:(double)v { Layout l = cur(); l.rearGainDb = v; put(l); }
+ (double)centerGainDb { return cur().centerGainDb; }
+ (void)setCenterGainDb:(double)v { Layout l = cur(); l.centerGainDb = v; put(l); }
+ (double)lfeGainDb { return cur().lfeGainDb; }
+ (void)setLfeGainDb:(double)v { Layout l = cur(); l.lfeGainDb = v; put(l); }

+ (double)bassFloorDb { return vsurround_config::dsp_params().bassFloorDb; }
+ (void)setBassFloorDb:(double)v { auto d = vsurround_config::dsp_params(); d.bassFloorDb = v; vsurround_config::set_dsp_params(d); }
+ (double)bassCutoffHz { return vsurround_config::dsp_params().bassCutoffHz; }
+ (void)setBassCutoffHz:(double)v { auto d = vsurround_config::dsp_params(); d.bassCutoffHz = v; vsurround_config::set_dsp_params(d); }
+ (double)bassQ { return vsurround_config::dsp_params().bassQ; }
+ (void)setBassQ:(double)v { auto d = vsurround_config::dsp_params(); d.bassQ = v; vsurround_config::set_dsp_params(d); }
+ (NSInteger)fftSize { return vsurround_config::dsp_params().fftSize; }
+ (void)setFftSize:(NSInteger)v { auto d = vsurround_config::dsp_params(); d.fftSize = (int)v; vsurround_config::set_dsp_params(d); }

+ (NSArray<NSArray<NSNumber *> *> *)speakerPositions {
    const vsurround_config::SpeakerPositions s = vsurround_config::compute_speakers(cur());
    auto pt = [](const vsurround_config::Vec3 &v) {
        return @[ @(v.x), @(v.y), @(v.z) ];
    };
    return @[ pt(s.fl), pt(s.fr), pt(s.c), pt(s.lfe), pt(s.rl), pt(s.rr) ];
}

+ (NSArray<NSNumber *> *)standard51Values {
    const Layout d = vsurround_config::default_layout();
    return @[
        @(d.front.distance), @(d.front.spacingDeg), @(d.front.centerAzDeg), @(d.front.centerElDeg),
        @(d.rear.distance), @(d.rear.spacingDeg), @(d.rear.centerAzDeg), @(d.rear.centerElDeg),
        @(d.center.x), @(d.center.y), @(d.center.z),
        @(d.lfe.x), @(d.lfe.y), @(d.lfe.z),
        @(d.frontGainDb), @(d.rearGainDb), @(d.centerGainDb), @(d.lfeGainDb)
    ];
}

+ (void)applyLayoutValues:(NSArray<NSNumber *> *)v mode:(BOOL)vsurroundEnabled {
    vsurround_config::set_layout(layoutFromValues(v)); // persist + clear preview + one generation bump
    vsurround_config::set_mode(vsurroundEnabled ? OutputMode::VirtualSurround : OutputMode::SystemSpatial);
}

+ (void)previewLayoutValues:(NSArray<NSNumber *> *)v {
    vsurround_config::set_preview(layoutFromValues(v)); // transient: engine renders it, not persisted
}

+ (void)clearPreview {
    vsurround_config::clear_preview();
}

@end
