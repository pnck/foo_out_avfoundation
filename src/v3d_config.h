//
//  v3d_config.h
//  foo_out_avfoundation
//
//  Persisted + live configuration for the output: which spatialization mode to use, and (for V3D) the
//  VIRTUAL SPEAKER RIG the user arranges. Backed by fb2k's configStore (SQLite k/v) for persistence,
//  with an in-memory cached copy + a generation counter so the running engine can pick up live edits
//  from the preferences UI without an observer/notification dance:
//    UI edit -> set_layout() (persist + bump generation) ; engine feed loop watches layout_generation()
//    and re-applies when it changes. The cache is the read source (configStore is only touched on first
//    load and on writes, both under one mutex), so the audio thread never races the UI on configStore.
//
//  Read from C++ (the engine) directly, and from the Swift UI via the V3DConfig Objective-C bridge.
//

#pragma once

#include "engine.h" // OutputMode

namespace foo_out_avf
{
    namespace v3d_config
    {
        struct Vec3 {
            double x, y, z;
        };

        // A stereo speaker pair, expressed the DAW way: distance from the listener, the angle BETWEEN
        // its two speakers (spacing), and the azimuth/elevation of the pair's centre (degrees).
        // Azimuth 0 = front, + = right; elevation 0 = ear level, + = up.
        struct SpeakerPair {
            double distance;
            double spacingDeg;
            double centerAzDeg;
            double centerElDeg;
        };

        // The whole rig: a front pair + a rear pair, plus a freely-placed mono centre and LFE.
        struct Layout {
            SpeakerPair front;
            SpeakerPair rear;
            Vec3 center;
            Vec3 lfe;
        };

        // The six virtual speaker positions in metres (listener at origin; front = -z, right = +x,
        // up = +y), computed from a Layout. The single source of geometry for both the engine and the
        // UI's 3D preview.
        struct SpeakerPositions {
            Vec3 fl, fr, c, lfe, rl, rr;
        };

        // The factory-default rig (also the engine's fallback): standard 5.1 (ITU-R BS.775) — front
        // L/R at ±30°, surrounds at ±110°, mono centre dead ahead, all on a 2 m arc, LFE front-low.
        // This is what the preferences "Reset to 5.1" button restores.
        Layout default_layout();

        SpeakerPositions compute_speakers(const Layout &layout);

        // Output spatialization mode (default: SystemSpatial). Mode changes take effect on the next
        // playback start (the output rebuilds its engine then), so they are NOT part of the live layout.
        OutputMode mode();
        void set_mode(OutputMode m);

        // The live layout: cached in memory, persisted to configStore. set_layout bumps the generation.
        Layout layout();
        void set_layout(const Layout &l);

        // Monotonic counter, bumped on every set_layout. The engine compares it cheaply each feed and
        // re-applies the layout only when it changes.
        unsigned long long layout_generation();

        // Monotonic counter, bumped on every set_mode. The output (AVFOutput) watches it and rebuilds
        // its engine for the new backend live, so toggling Virtual 3D takes effect without restarting
        // foobar or the output (an output instance is long-lived; it would otherwise never re-read).
        unsigned long long mode_generation();

    } // namespace v3d_config
} // namespace foo_out_avf
