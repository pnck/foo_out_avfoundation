//
//  v3d_config_bridge.h
//  foo_out_avfoundation
//
//  Objective-C face of foo_out_avf::v3d_config, so the Swift UI can read/write the virtual speaker rig
//  without touching C++ directly. Exposed to Swift via the bridging header. Class properties keep the
//  Swift call sites terse (V3DConfig.frontAzimuth = ...). Every write persists immediately AND bumps the
//  layout generation, so a running engine picks the change up live (configStore + in-memory cache).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface V3DConfig : NSObject

// Output mode: YES = Virtual3D, NO = SystemSpatial. (Applies on the next playback start.)
@property(class, nonatomic) BOOL virtual3DEnabled;

// Front / rear speaker pairs (DAW-style): distance in metres, spacing = angle between the two
// speakers, azimuth/elevation of the pair centre in degrees.
@property(class, nonatomic) double frontDistance;
@property(class, nonatomic) double frontSpacing;
@property(class, nonatomic) double frontAzimuth;
@property(class, nonatomic) double frontElevation;
@property(class, nonatomic) double rearDistance;
@property(class, nonatomic) double rearSpacing;
@property(class, nonatomic) double rearAzimuth;
@property(class, nonatomic) double rearElevation;

// Freely-placed mono centre and LFE, in metres (listener at origin, front = -z, right = +x, up = +y).
@property(class, nonatomic) double centerX;
@property(class, nonatomic) double centerY;
@property(class, nonatomic) double centerZ;
@property(class, nonatomic) double lfeX;
@property(class, nonatomic) double lfeY;
@property(class, nonatomic) double lfeZ;

// Per-group gain in dB (0 = unity), to offset distance attenuation on far speakers.
@property(class, nonatomic) double frontGainDb;
@property(class, nonatomic) double rearGainDb;
@property(class, nonatomic) double centerGainDb;
@property(class, nonatomic) double lfeGainDb;

// Computed positions of the six virtual speakers for the 3D preview, in order
// [FL, FR, C, LFE, RL, RR]; each entry is @[x, y, z] in metres. The one source of geometry (shared
// with the engine), so the preview can never drift from what's actually rendered.
@property(class, nonatomic, readonly) NSArray<NSArray<NSNumber *> *> *speakerPositions;

// The factory standard-5.1 layout values, in the same order applyLayoutValues: expects (18 numbers:
// front d/spacing/az/el, rear d/spacing/az/el, centre x/y/z, LFE x/y/z, then the four gains in dB
// front/rear/centre/LFE). For the UI's "Reset".
@property(class, nonatomic, readonly) NSArray<NSNumber *> *standard51Values;

// Commit a whole layout + mode in one shot (one persist, one generation bump, clears any preview).
// `values` is the 18 numbers in the order above; `v3dEnabled` selects the output mode. The "Save".
+ (void)applyLayoutValues:(NSArray<NSNumber *> *)values mode:(BOOL)v3dEnabled;

// Live preview (same 18-value order): install the values as a transient preview the engine renders
// immediately WITHOUT persisting. clearPreview drops it (so leaving the page unsaved reverts).
+ (void)previewLayoutValues:(NSArray<NSNumber *> *)values;
+ (void)clearPreview;

@end

NS_ASSUME_NONNULL_END
