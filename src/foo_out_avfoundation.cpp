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

// Debug configuration - uncomment to enable audio dump
// #define ENABLE_AUDIO_DUMP 1

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
            engine.setQueueSize(3);

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
            if (!is_active || is_paused) {
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

        bool is_progressing() override { return engine.isEnabled() && !engine.isPaused(); }

        double get_latency() override {
            if (is_active && !is_paused) {
                // Return actual calculated latency based on pending buffers
                return engine.getCurrentLatency();
            } else {
                // Return minimal latency when not active
                return 0.01; // 10ms
            }
        }

        void process_samples(const audio_chunk &p_chunk) override { process_samples_v2(p_chunk); }

        void update(bool &p_ready) override { p_ready = engine.isEnabled() && engine.isReadyForMoreMediaData(); }

        void pause(bool p_state) override {
            is_paused = p_state;
            if (p_state) {
                // Pause the engine (clears queue but keeps semaphore)
                engine.pause();
            } else {
                // Resume the engine
                engine.resume();
            }
        }

        void flush() override { engine.flush(); }

        void force_play() override {
            is_paused = false;
            engine.disable();
            engine.enable();
        }

        void volume_set(double p_val) override { engine.setVolume(static_cast<float>(p_val)); }
    };

} // namespace foo_out_avf

static output_factory_t<foo_out_avf::AVFOutput> g_avf_output;
