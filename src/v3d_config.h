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
//    load and on writes, both under one mutex), so the audio thread never races the UI on configStore
//    *for the layout*. NOTE: mode() / set_mode() are the exception — they hit configStore directly (no
//    cache); that's safe only because maybe_switch_mode() gates on the atomic mode generation first, so
//    the playback thread reads mode() at most once per actual toggle. configStore is itself thread-safe.
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
        // its two speakers (spacing), and the azimuth/elevation of the pair's center (degrees).
        // Azimuth 0 = front, + = right; elevation 0 = ear level, + = up.
        struct SpeakerPair {
            double distance;
            double spacingDeg;
            double centerAzDeg;
            double centerElDeg;
        };

        // The whole rig: a front pair + a rear pair, plus a freely-placed mono center and LFE, with a
        // per-group gain (dB; 0 = unity) so the user can compensate for the distance attenuation that
        // makes far speakers quiet. The gain is applied to the samples in the feed path (see
        // engine_virtual_3d.mm's _channelGain), NOT to the source node's mixer volume — AVAudioMixing
        // clamps volume near unity, so a mixer-volume boost wouldn't take.
        struct Layout {
            SpeakerPair front;
            SpeakerPair rear;
            Vec3 center;
            Vec3 lfe;
            double frontGainDb;
            double rearGainDb;
            double centerGainDb;
            double lfeGainDb;
        };

        // The six virtual speaker positions in meters (listener at origin; front = -z, right = +x,
        // up = +y), computed from a Layout. The single source of geometry for both the engine and the
        // UI's 3D preview.
        struct SpeakerPositions {
            Vec3 fl, fr, c, lfe, rl, rr;
        };

        // The factory-default rig (also the engine's fallback): standard 5.1 (ITU-R BS.775) — front
        // L/R at ±30°, surrounds at ±110°, mono center dead ahead, all on a 2 m arc, LFE front-low.
        // This is what the preferences "Reset to 5.1" button restores.
        Layout default_layout();

        SpeakerPositions compute_speakers(const Layout &layout);

        // Global DSP parameters for the stereo→5.1 STFT upmix: the bass-management high-pass on the mains
        // and the FFT window size. Persisted separately from the layout, with their own generation, so the
        // engine rebuilds the upmixer (which reallocates for a new FFT size and recomputes the crossover)
        // when they change. These are NOT previewed — there's no transient variant.
        struct DspParams {
            double bassFloorDb;  // mains' low-end floor below the crossover (dB; 0 = keep all, −36 ≈ full cut)
            double bassCutoffHz; // bass-management crossover center frequency (Hz)
            double bassQ;        // crossover steepness (higher Q = narrower transition band)
            int fftSize;         // STFT window size: 1024 | 2048 | 4096
        };
        DspParams default_dsp_params();
        DspParams dsp_params();
        void set_dsp_params(const DspParams &p);
        unsigned long long dsp_generation();

        // Output spatialization mode (default: SystemSpatial). Mode changes take effect on the next
        // playback start (the output rebuilds its engine then), so they are NOT part of the live layout.
        OutputMode mode();
        void set_mode(OutputMode m);

        // The live layout. Returns the PREVIEW layout if one is active (see set_preview), otherwise the
        // saved layout (cached in memory, loaded from configStore on first read).
        Layout layout();

        // Commit a layout: update the cache, persist to configStore, and clear any active preview.
        // Bumps the generation.
        void set_layout(const Layout &l);

        // Live preview (the preferences "drag to hear it move" path): the engine uses this layout
        // immediately WITHOUT persisting it. set_preview installs/updates it; clear_preview drops it so
        // layout() falls back to the saved one (i.e. leaving the page unsaved reverts). Both bump the
        // generation so the running engine repositions. set_layout (Save) clears it as part of committing.
        void set_preview(const Layout &l);
        void clear_preview();

        // Monotonic counter, bumped on every set_layout / set_preview / clear_preview. The engine
        // compares it cheaply each feed and re-applies the layout only when it changes.
        unsigned long long layout_generation();

        // Monotonic counter, bumped on every set_mode. The output (AVFOutput) watches it and rebuilds
        // its engine for the new backend live, so toggling Virtual 3D takes effect without restarting
        // foobar or the output (an output instance is long-lived; it would otherwise never re-read).
        unsigned long long mode_generation();

    } // namespace v3d_config
} // namespace foo_out_avf
