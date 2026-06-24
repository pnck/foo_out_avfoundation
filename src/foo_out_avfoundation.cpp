//
//  foo_out_avfoundation.cpp
//  foo_out_avfoundation
//
//  Created by pnck on 2025/8/8.
//

#include "predef.h"
#include "common/consts.hpp"
#include "common/utils.hpp"
#include "engine.h"
#include "v3d_config.h"
#include <vector>
#include <span>
#include <chrono>
#include <mutex>
#include <string>

namespace
{
    // foobar2000 calls output methods on its (single) playback thread and requires
    // them to return immediately (output.h: "SHOULD NOT block"). The diagnostics here
    // capture the timing of those callbacks so an intermittent "source is stalling"
    // can be correlated with either a blocking call or an inter-callback gap.

    // (1) Per-call duration probe: flags a callback whose own body runs too long.
    struct CallTimerHelper {
        const char *name;
        std::chrono::steady_clock::time_point t0;
        constexpr static double ms_too_long = 30.0; // Threshold for "too long" (in milliseconds)
        explicit CallTimerHelper(const char *n) : name(n), t0(std::chrono::steady_clock::now()) {}
        ~CallTimerHelper() {
            const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
            if (ms > ms_too_long) {
                // Don't block this (playback) thread on console I/O — queue it to the main thread.
                std::string msg = std::string("[AVF] SLOW callback ") + name + ": " + std::to_string((int)ms) +
                                  " ms (blocked playback thread)";
                fb2k::inMainThread([msg = std::move(msg)]() { FB2K_console_print(msg.c_str()); });
            }
        }
    };

}

namespace foo_out_avf
{
    class AVFOutput : public output_v6 {
    private:
        AVFEngine engine;
        bool is_active;
        bool is_paused;
        double m_buffer_length = 0.0;           // foobar's configured output buffer length (seconds)
        unsigned long long m_seen_mode_gen = 0; // last v3d_config mode generation we acted on

        // setMode recreates the backend, so the log callback must be (re)installed on the new one or
        // its [AVF]/[V3D] lines fall back to NSLog instead of foobar's console. Configure mode first.
        void configure_engine_for_mode(OutputMode mode) {
            engine.setMode(mode);
            // Engine logs can originate on foobar's realtime feed thread; console::print dispatches to
            // its receivers synchronously (UI marshaling) and could stall it. Hand each line to the
            // main thread via fb2k::inMainThread() — it queues and returns immediately.
            engine.setLogCallback([](const char *message) {
                fb2k::inMainThread([line = std::string(message)]() { FB2K_console_print(line.c_str()); });
            });
            // foobar's configured buffer length is the steady-state lead; too small underruns AVF.
            engine.setBufferLength(m_buffer_length);
        }

        // An output instance is long-lived, so it would never re-read the mode after the user toggles
        // Virtual 3D in preferences. Watch the mode generation and rebuild the engine for the new
        // backend in place (a brief gap — this is a deliberate switch). Called from update().
        void maybe_switch_mode() {
            const unsigned long long gen = v3d_config::mode_generation();
            if (gen == m_seen_mode_gen) {
                return;
            }
            m_seen_mode_gen = gen;
            const OutputMode want = v3d_config::mode();
            if (want == engine.mode()) {
                return;
            }
            engine.disable();
            configure_engine_for_mode(want);
            is_active = engine.enable();
            if (is_active && is_paused) {
                engine.pause(); // preserve the paused state across the rebuild
            }
        }

    public:
        static constexpr GUID class_guid = guid_output_avfoundation;
        static GUID g_get_guid() { return class_guid; }

        static const char *g_get_name() { return "AVFOutput"; }

        static bool g_is_high_latency() { return false; }
        static bool g_supports_multiple_streams() { return false; }
        static bool g_advanced_settings_query() { return true; }

        static bool g_needs_bitdepth_config() { return false; }
        static bool g_needs_dither_config() { return false; }
        static bool g_needs_device_list_prefixes() { return false; }

    public:
        AVFOutput(const GUID &p_device, double p_buffer_length, bool p_dither, t_uint32 p_bitdepth) : is_active(false), is_paused(false) {
            m_buffer_length = p_buffer_length;
            // Pick the spatialization backend (system Spatial Audio vs V3D) from saved config.
            configure_engine_for_mode(v3d_config::mode());
            m_seen_mode_gen = v3d_config::mode_generation();

            if (engine.enable()) {
                is_active = true;
            }
        }

        ~AVFOutput() {
            if (is_active) {
                // engine.setLogCallback(nullptr);
                engine.disable();
            }
        }

        static void g_enum_devices(output_device_enum_callback &p_callback) {

            p_callback.on_device(guid_output_device, "AVFoundation Output", 19);
        }

    public:
        //! NOTE:  format => f64le,packed
        size_t process_samples_v2(const audio_chunk &p_chunk) override {
            CallTimerHelper _t("process_samples");
            if (!is_active) {
                return 0;
            }
            // Diagnostic: does foobar2000 actually push samples while we're paused?
            // If so, returning 0 here drops them (the "hard cut" hypothesis).
            if (is_paused) {
                static size_t paused_calls = 0;
                if ((paused_calls++ % 20) == 0) {
                    std::string msg = std::string("[AVF] process_samples_v2 called while paused (") +
                                      std::to_string(p_chunk.get_sample_count()) +
                                      " samples, count=" + std::to_string(paused_calls) + ") -> returning 0";
                    fb2k::inMainThread([msg = std::move(msg)]() { FB2K_console_print(msg.c_str()); });
                }
                return 0;
            }

            // Get audio data parameters
            const auto sample_rate = p_chunk.get_sample_rate();
            const unsigned channels = p_chunk.get_channels();
            const size_t sample_count = p_chunk.get_sample_count();

            if (sample_count == 0 || channels == 0) {
                return 0;
            }

            // The engine decides how many frames to take, allocates the renderer's block, and
            // calls back here to convert exactly that many — from foobar's f64 chunk straight
            // into the block (single copy; no intermediate buffer). setupAudioFormat is done
            // inside feedAudioData. Returns frames taken; foobar re-offers the remainder.
            const audio_sample *input_data = p_chunk.get_data();
            return engine.feedAudioData(sample_rate, channels, sample_count,
                                        [input_data, channels](float *dst, size_t frames) {
                                            const size_t count = frames * channels;
#if defined(AUDIO_MATH_NEON)
                                            utils::neon_convert(input_data, dst, count);
#else
                                            fb2k_audio_math::convert(input_data, dst, count);
#endif
                                        });
        }

        // Maps to the engine's clock state. False during the priming phase (data queued but
        // not yet playing) is expected per output.h and must not be read as a stall.
        bool is_progressing() override { return engine.isProgressing(); }

        double get_latency() override {
            CallTimerHelper _t("get_latency");
            // Our queued seconds (lead ahead of the play head), decoupled from foobar's decode
            // position. During pause this is the frozen queued amount, which is still correct.
            return is_active ? engine.getCurrentLatency() : 0.0;
        }

        void process_samples(const audio_chunk &p_chunk) override { process_samples_v2(p_chunk); }

        void update(bool &p_ready) override {
            CallTimerHelper _t("update");
            maybe_switch_mode(); // pick up a Virtual 3D on/off toggle made in preferences, live
            // We are a shallow sink: ready iff there's room under the target lead.
            p_ready = is_active && engine.canAcceptMore();
        }

        //! Advisory count of samples we can take right now (0 == not ready). Lets foobar
        //! offer a right-sized chunk instead of over-offering and getting a partial take.
        size_t update_v2() override {
            CallTimerHelper _t("update_v2");
            maybe_switch_mode(); // pick up a Virtual 3D on/off toggle made in preferences, live
            return is_active ? engine.freeSampleCount() : 0;
        }

        void pause(bool p_state) override {
            CallTimerHelper _t("pause");
            is_paused = p_state;
            if (p_state) {
                // Freeze the clock; enqueued audio is kept for resume.
                engine.pause();
            } else {
                engine.resume();
            }
        }

        void flush() override {
            CallTimerHelper _t("flush");
            engine.flush();
        }

        void force_play() override {
            // Called when there's no more data to send: start the clock even if we
            // never reached the pre-roll threshold (e.g. a track shorter than the
            // pre-roll), so the queued tail actually plays out. We must NOT tear the
            // engine down here — the old disable()/enable() pair flushed the queue
            // and truncated the end of every track.
            CallTimerHelper _t("force_play");
            engine.forcePlay();
        }

        void volume_set(double p_val) override {
            // Pass foobar2000's value straight through to the renderer's linear gain —
            // linear to linear, no curve/dB conversion. We don't assume how foobar maps
            // its slider; whatever value it sends is applied verbatim.
            engine.setVolume(static_cast<float>(p_val));
        }
    };

} // namespace foo_out_avf

static output_factory_t<foo_out_avf::AVFOutput> g_avf_output;
