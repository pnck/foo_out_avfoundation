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
#include <thread>
#include <fstream>
#include <semaphore>
#include <vector>
#include <span>
#include <chrono>
#include <mutex>

// Debug configuration - uncomment to enable audio dump
// #define ENABLE_AUDIO_DUMP 1

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
                FB2K_console_print("[AVF] SLOW callback ", name, ": ", (int)ms, " ms (blocked playback thread)");
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

#ifdef ENABLE_AUDIO_DUMP
        // Debug function to dump audio data to file
        void debugDumpAudioData(const audio_chunk &p_chunk) {
            static std::counting_semaphore read_sem(1), write_sem(0);
            static std::vector<audio_sample> dump_buffer;
            static size_t samples_written = 0;

            const auto sample_rate = p_chunk.get_sample_rate();
            const size_t sample_count = p_chunk.get_sample_count();
            const size_t used_size = p_chunk.get_used_size();
            const auto max_samples_to_save = 10 * sample_rate; // 10 seconds worth of audio
            const double _should_last = static_cast<double>(sample_count) / sample_rate;

            const audio_sample *samples = p_chunk.get_data();
            if (samples_written < max_samples_to_save) {
                read_sem.acquire();
                dump_buffer.clear();
                dump_buffer.resize(used_size);
                fb2k_audio_math::convert(samples, dump_buffer.data(), used_size);
                write_sem.release();
            }

            static std::thread dump_thread([this, max_samples_to_save] {
                std::ofstream output_file("/tmp/au.data", std::ios::binary);
                while (is_active && !is_paused && samples_written < max_samples_to_save) {
                    write_sem.acquire();
                    if (is_active && dump_buffer.size() > 0) {
                        FB2K_console_print("Writing ", dump_buffer.size(), " samples to /tmp/au.data [", samples_written, "]");
                        output_file.write(reinterpret_cast<const char *>(dump_buffer.data()),
                                          dump_buffer.size() * sizeof(decltype(dump_buffer)::value_type));
                        samples_written += dump_buffer.size(); // Use buffer size instead of sample_count
                    }
                    read_sem.release();
                }
                output_file.flush();
                FB2K_console_print("Finished writing audio data to /tmp/au.data\n");
            });

            static bool thread_started = false;
            if (!thread_started) {
                dump_thread.detach();
                thread_started = true;
            }
            std::this_thread::sleep_for(std::chrono::duration<double>(_should_last));
        }
#endif

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

            engine.setLogCallback([](const char *message) { FB2K_console_print(message); });
            // Keep foobar's configured buffer length worth of audio enqueued in the renderer
            // (the steady-state lead). Too small a lead underruns AVF between refills.
            engine.setBufferLength(p_buffer_length);

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
                    FB2K_console_print("[AVF] process_samples_v2 called while paused (", p_chunk.get_sample_count(),
                                       " samples, count=", paused_calls, ") -> returning 0");
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

            // Setup audio format if needed (this is safe to call multiple times)
            engine.setupAudioFormat(sample_rate, channels);

            // Convert from double (audio_sample) to float and keep interleaved format
            const audio_sample *input_data = p_chunk.get_data();
            std::vector<float> float_data(p_chunk.get_used_size());
#if defined(AUDIO_MATH_NEON)
            utils::neon_convert(input_data, float_data.data(), p_chunk.get_used_size());
#else
            fb2k_audio_math::convert(input_data, float_data.data(), p_chunk.get_used_size());
#endif
#ifdef ENABLE_AUDIO_DUMP
            audio_chunk_impl ac;
            ac.set_channels(1);
            // Extract first channel for debugging
            std::vector<float> first_channel(sample_count);
            for (size_t i = 0; i < sample_count; i++) {
                first_channel[i] = float_data[i * channels]; // First channel only
            }
            ac.set_data_32(first_channel.data(), sample_count, 1, sample_rate);

            // Debug: dump audio data to file
            debugDumpAudioData(ac);
#endif

            size_t processed_samples = engine.feedAudioData(std::move(float_data), sample_rate, channels, sample_count);
            return processed_samples;
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
            // We are a shallow sink: ready iff there's room under the target lead.
            p_ready = is_active && engine.canAcceptMore();
        }

        //! Advisory count of samples we can take right now (0 == not ready). Lets foobar
        //! offer a right-sized chunk instead of over-offering and getting a partial take.
        size_t update_v2() override {
            CallTimerHelper _t("update_v2");
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
