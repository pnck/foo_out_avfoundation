//
//  preferences_page.mm
//  foo_out_avfoundation
//
//  Registers the component's preferences page with foobar2000 and instantiates the Swift view
//  controller. On macOS the SDK's preferences_page::instantiate() returns a wrapped NSViewController
//  (see vendor/sdk/.../foo_sample/Mac/fooSampleMacPreferences.mm for the canonical pattern).
//
//  The Swift controller is resolved by its @objc runtime name (V3DPreferencesViewController) rather
//  than through the Swift-generated ObjC header. That keeps this ObjC++ TU independent of a Swift
//  build artifact: in one mixed Swift+ObjC++ module Ninja does NOT order the Swift-emitted header
//  ahead of the ObjC++ compiles, so importing it races. We only ever `new` the class and wrap it,
//  so a runtime lookup is enough — no compile-time Swift interface is needed here.
//

#import "predef.h" // foobar2000 SDK (+ Cocoa)
#import "common/consts.hpp"

namespace
{
    // Our preferences-page GUID. Stable; generated once.
    constexpr GUID guid_preferences_v3d = {
        0x2C7A1E94, 0x5B3D, 0x4F02, {0x9A, 0x1C, 0x77, 0xE0, 0x33, 0xAB, 0xCD, 0x12}
    };

    class preferences_page_v3d : public preferences_page
    {
    public:
        service_ptr instantiate() override {
            // Swift class, registered with the ObjC runtime via @objc(V3DPreferencesViewController).
            Class vcClass = NSClassFromString(@"V3DPreferencesViewController");
            NSViewController *vc = [[vcClass alloc] init];
            return fb2k::wrapNSObject(vc);
        }
        const char *get_name() override { return "AVFoundation Output"; }
        GUID get_guid() override { return guid_preferences_v3d; }
        // Sit under Playback > Output (where an output component belongs), not Tools.
        GUID get_parent_guid() override { return guid_output; }
    };

    FB2K_SERVICE_FACTORY(preferences_page_v3d);
} // namespace
