//
//  v3d_config.h
//  foo_out_avfoundation
//
//  Persisted configuration for the output: which spatialization mode to use, and (for V3D) where
//  the user has placed the source in the virtual field. Backed by fb2k's configStore (SQLite k/v,
//  no GUIDs). Read from C++ (the output picks its mode) and from the Swift UI via V3DConfigBridge.
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

        // Output spatialization mode (default: SystemSpatial).
        OutputMode mode();
        void set_mode(OutputMode m);

        // Source position in metres, listener at the origin (default: {0,0,-2} = 2 m front).
        Vec3 source_position();
        void set_source_position(const Vec3 &p);

        // Perceived source size and stereo spread (0..1, DAW-panner style).
        double size();
        void set_size(double v);
        double spread();
        void set_spread(double v);

        // Listener orientation in degrees (yaw, pitch, roll); default {0,0,0}.
        Vec3 listener_orientation();
        void set_listener_orientation(const Vec3 &o);

    } // namespace v3d_config
} // namespace foo_out_avf
