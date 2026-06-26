//
//  vsurround_config.cpp
//  foo_out_avfoundation
//
//  configStore-backed implementation of the VSurround configuration. Keys are namespaced under "foo_out_avf."
//  so they don't collide with other components' settings. The layout is cached in memory behind a mutex
//  (the read source for both the audio thread and the UI); configStore is touched only on first load
//  and on writes, so the two threads never race on it. See vsurround_config.h for the live-update contract.
//

#include "vsurround_config.h"
#include "foobar2000/SDK/configStore.h"

#include <atomic>
#include <cmath>
#include <mutex>

namespace foo_out_avf
{
    namespace vsurround_config
    {
        namespace
        {
            constexpr const char *K_MODE = "foo_out_avf.mode";

            constexpr const char *K_FRONT_DIST = "foo_out_avf.front.distance";
            constexpr const char *K_FRONT_SPACING = "foo_out_avf.front.spacing";
            constexpr const char *K_FRONT_AZ = "foo_out_avf.front.azimuth";
            constexpr const char *K_FRONT_EL = "foo_out_avf.front.elevation";

            constexpr const char *K_REAR_DIST = "foo_out_avf.rear.distance";
            constexpr const char *K_REAR_SPACING = "foo_out_avf.rear.spacing";
            constexpr const char *K_REAR_AZ = "foo_out_avf.rear.azimuth";
            constexpr const char *K_REAR_EL = "foo_out_avf.rear.elevation";

            constexpr const char *K_CENTER_X = "foo_out_avf.center.x";
            constexpr const char *K_CENTER_Y = "foo_out_avf.center.y";
            constexpr const char *K_CENTER_Z = "foo_out_avf.center.z";

            constexpr const char *K_LFE_X = "foo_out_avf.lfe.x";
            constexpr const char *K_LFE_Y = "foo_out_avf.lfe.y";
            constexpr const char *K_LFE_Z = "foo_out_avf.lfe.z";

            constexpr const char *K_FRONT_GAIN = "foo_out_avf.front.gain_db";
            constexpr const char *K_REAR_GAIN = "foo_out_avf.rear.gain_db";
            constexpr const char *K_CENTER_GAIN = "foo_out_avf.center.gain_db";
            constexpr const char *K_LFE_GAIN = "foo_out_avf.lfe.gain_db";

            constexpr const char *K_BASS_FLOOR = "foo_out_avf.bass.floor_db";
            constexpr const char *K_BASS_CUTOFF = "foo_out_avf.bass.cutoff_hz";
            constexpr const char *K_BASS_Q = "foo_out_avf.bass.q";
            constexpr const char *K_FFT_SIZE = "foo_out_avf.fft.size";

            fb2k::configStore::ptr store() { return fb2k::configStore::get(); }

            std::mutex g_mutex;
            bool g_loaded = false;
            Layout g_layout;
            bool g_hasPreview = false; // a transient preview layout is active (unsaved edits)
            Layout g_previewLayout;
            std::atomic<unsigned long long> g_generation{0};
            std::atomic<unsigned long long> g_modeGeneration{0};

            std::mutex g_dspMutex;
            bool g_dspLoaded = false;
            DspParams g_dsp;
            std::atomic<unsigned long long> g_dspGeneration{0};

            // Pull the layout out of configStore (defaults from default_layout()). Caller holds g_mutex.
            void load_locked() {
                const Layout d = default_layout();
                auto s = store();
                g_layout.front.distance = s->getConfigFloat(K_FRONT_DIST, d.front.distance);
                g_layout.front.spacingDeg = s->getConfigFloat(K_FRONT_SPACING, d.front.spacingDeg);
                g_layout.front.centerAzDeg = s->getConfigFloat(K_FRONT_AZ, d.front.centerAzDeg);
                g_layout.front.centerElDeg = s->getConfigFloat(K_FRONT_EL, d.front.centerElDeg);
                g_layout.rear.distance = s->getConfigFloat(K_REAR_DIST, d.rear.distance);
                g_layout.rear.spacingDeg = s->getConfigFloat(K_REAR_SPACING, d.rear.spacingDeg);
                g_layout.rear.centerAzDeg = s->getConfigFloat(K_REAR_AZ, d.rear.centerAzDeg);
                g_layout.rear.centerElDeg = s->getConfigFloat(K_REAR_EL, d.rear.centerElDeg);
                g_layout.center.x = s->getConfigFloat(K_CENTER_X, d.center.x);
                g_layout.center.y = s->getConfigFloat(K_CENTER_Y, d.center.y);
                g_layout.center.z = s->getConfigFloat(K_CENTER_Z, d.center.z);
                g_layout.lfe.x = s->getConfigFloat(K_LFE_X, d.lfe.x);
                g_layout.lfe.y = s->getConfigFloat(K_LFE_Y, d.lfe.y);
                g_layout.lfe.z = s->getConfigFloat(K_LFE_Z, d.lfe.z);
                g_layout.frontGainDb = s->getConfigFloat(K_FRONT_GAIN, d.frontGainDb);
                g_layout.rearGainDb = s->getConfigFloat(K_REAR_GAIN, d.rearGainDb);
                g_layout.centerGainDb = s->getConfigFloat(K_CENTER_GAIN, d.centerGainDb);
                g_layout.lfeGainDb = s->getConfigFloat(K_LFE_GAIN, d.lfeGainDb);
                g_loaded = true;
            }

            // Write the layout back to configStore. Caller holds g_mutex.
            void persist_locked(const Layout &l) {
                auto s = store();
                s->setConfigFloat(K_FRONT_DIST, l.front.distance);
                s->setConfigFloat(K_FRONT_SPACING, l.front.spacingDeg);
                s->setConfigFloat(K_FRONT_AZ, l.front.centerAzDeg);
                s->setConfigFloat(K_FRONT_EL, l.front.centerElDeg);
                s->setConfigFloat(K_REAR_DIST, l.rear.distance);
                s->setConfigFloat(K_REAR_SPACING, l.rear.spacingDeg);
                s->setConfigFloat(K_REAR_AZ, l.rear.centerAzDeg);
                s->setConfigFloat(K_REAR_EL, l.rear.centerElDeg);
                s->setConfigFloat(K_CENTER_X, l.center.x);
                s->setConfigFloat(K_CENTER_Y, l.center.y);
                s->setConfigFloat(K_CENTER_Z, l.center.z);
                s->setConfigFloat(K_LFE_X, l.lfe.x);
                s->setConfigFloat(K_LFE_Y, l.lfe.y);
                s->setConfigFloat(K_LFE_Z, l.lfe.z);
                s->setConfigFloat(K_FRONT_GAIN, l.frontGainDb);
                s->setConfigFloat(K_REAR_GAIN, l.rearGainDb);
                s->setConfigFloat(K_CENTER_GAIN, l.centerGainDb);
                s->setConfigFloat(K_LFE_GAIN, l.lfeGainDb);
            }

            Vec3 spherical(double azDeg, double elDeg, double dist) {
                const double az = azDeg * (M_PI / 180.0);
                const double el = elDeg * (M_PI / 180.0);
                const double ce = std::cos(el);
                return Vec3{dist * ce * std::sin(az), dist * std::sin(el), -dist * ce * std::cos(az)};
            }
        } // namespace

        Layout default_layout() {
            // Standard 5.1 (ITU-R BS.775): front L/R at ±30°, surrounds at ±110°, mono center dead
            // ahead, all on a 2 m arc; LFE front and low (its position is non-directional anyway).
            Layout d;
            d.front = SpeakerPair{2.0, 60.0, 0.0, 0.0};    // ±30° in front
            d.rear = SpeakerPair{2.0, 140.0, 180.0, 0.0};  // surrounds at ±110° (180° ± 70°)
            d.center = Vec3{0.0, 0.0, -2.0};               // mono center, dead ahead
            d.lfe = Vec3{0.0, -0.3, -1.0};                 // mono LFE, front-low and fairly close in
            d.frontGainDb = 0.0;                           // unity gain for the mains by default
            d.rearGainDb = 0.0;
            d.centerGainDb = 0.0;
            d.lfeGainDb = -3.0;                            // trimmed: the mains keep a −12 dB bass floor
                                                           // now, so the LFE carries less of the low end
                                                           // (−3 dB lands total low-end ≈ original stereo)
            return d;
        }

        SpeakerPositions compute_speakers(const Layout &l) {
            SpeakerPositions s;
            // Front: left is center-spacing/2 (more to the left), right is center+spacing/2.
            s.fl = spherical(l.front.centerAzDeg - l.front.spacingDeg * 0.5, l.front.centerElDeg, l.front.distance);
            s.fr = spherical(l.front.centerAzDeg + l.front.spacingDeg * 0.5, l.front.centerElDeg, l.front.distance);
            // Rear: handedness flips facing backwards (azimuth ~180°), so left surround = center+spacing/2.
            s.rl = spherical(l.rear.centerAzDeg + l.rear.spacingDeg * 0.5, l.rear.centerElDeg, l.rear.distance);
            s.rr = spherical(l.rear.centerAzDeg - l.rear.spacingDeg * 0.5, l.rear.centerElDeg, l.rear.distance);
            s.c = l.center;
            s.lfe = l.lfe;
            return s;
        }

        OutputMode mode() {
            return store()->getConfigInt(K_MODE, 0) == 1 ? OutputMode::VirtualSurround : OutputMode::SystemSpatial;
        }
        void set_mode(OutputMode m) {
            store()->setConfigInt(K_MODE, m == OutputMode::VirtualSurround ? 1 : 0);
            g_modeGeneration.fetch_add(1, std::memory_order_release);
        }

        unsigned long long mode_generation() {
            return g_modeGeneration.load(std::memory_order_acquire);
        }

        DspParams default_dsp_params() {
            // −12 dB mains floor, crossover centered at 113 Hz with Q 1.0 (≈ the original 80–160 Hz band),
            // 2048-pt FFT. These reproduce the previously-hardcoded behavior.
            return DspParams{-12.0, 113.0, 1.0, 2048};
        }

        DspParams dsp_params() {
            std::lock_guard<std::mutex> lock(g_dspMutex);
            if (!g_dspLoaded) {
                const DspParams d = default_dsp_params();
                auto s = store();
                g_dsp.bassFloorDb = s->getConfigFloat(K_BASS_FLOOR, d.bassFloorDb);
                g_dsp.bassCutoffHz = s->getConfigFloat(K_BASS_CUTOFF, d.bassCutoffHz);
                g_dsp.bassQ = s->getConfigFloat(K_BASS_Q, d.bassQ);
                g_dsp.fftSize = (int)s->getConfigInt(K_FFT_SIZE, d.fftSize);
                g_dspLoaded = true;
            }
            return g_dsp;
        }

        void set_dsp_params(const DspParams &p) {
            {
                std::lock_guard<std::mutex> lock(g_dspMutex);
                g_dsp = p;
                g_dspLoaded = true;
                auto s = store();
                s->setConfigFloat(K_BASS_FLOOR, p.bassFloorDb);
                s->setConfigFloat(K_BASS_CUTOFF, p.bassCutoffHz);
                s->setConfigFloat(K_BASS_Q, p.bassQ);
                s->setConfigInt(K_FFT_SIZE, p.fftSize);
            }
            g_dspGeneration.fetch_add(1, std::memory_order_release);
        }

        unsigned long long dsp_generation() {
            return g_dspGeneration.load(std::memory_order_acquire);
        }

        Layout layout() {
            std::lock_guard<std::mutex> lock(g_mutex);
            if (!g_loaded) {
                load_locked();
            }
            return g_hasPreview ? g_previewLayout : g_layout;
        }

        void set_layout(const Layout &l) {
            {
                std::lock_guard<std::mutex> lock(g_mutex);
                g_layout = l;
                g_loaded = true;
                g_hasPreview = false; // committing supersedes any preview
                persist_locked(l);
            }
            g_generation.fetch_add(1, std::memory_order_release);
        }

        void set_preview(const Layout &l) {
            {
                std::lock_guard<std::mutex> lock(g_mutex);
                g_previewLayout = l;
                g_hasPreview = true;
            }
            g_generation.fetch_add(1, std::memory_order_release);
        }

        void clear_preview() {
            {
                std::lock_guard<std::mutex> lock(g_mutex);
                g_hasPreview = false;
            }
            g_generation.fetch_add(1, std::memory_order_release);
        }

        unsigned long long layout_generation() {
            return g_generation.load(std::memory_order_acquire);
        }

    } // namespace vsurround_config
} // namespace foo_out_avf
