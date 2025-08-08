//
//  foo_out_avfoundation.cpp
//  foo_out_avfoundation
//
//  Created by pnck on 2025/8/8.
//

#include "predef.h"
#include "common/consts.hpp"

namespace foo_out_avf
{
    class AVFOutput : public output_v6 {
    public:
        static constexpr GUID class_guid = guid_output_avfoundation;
        static GUID g_get_guid() { return class_guid; }

        static const char *g_get_name() { return "AVFOutput"; }

        static bool g_is_high_latency() { return false; }
        static bool g_supports_multiple_streams() { return false; }
        static bool g_advanced_settings_query() { return false; }

        static bool g_needs_bitdepth_config() { return false; }
        static bool g_needs_dither_config() { return false; }
        static bool g_needs_device_list_prefixes() { return false; }

    public:
        AVFOutput(const GUID &p_device, double p_buffer_length, bool p_dither, t_uint32 p_bitdepth) {
            // CTOR
        }
        static void g_enum_devices(output_device_enum_callback &p_callback) {
            p_callback.on_device(guid_output_device, "AVFoundation Output", 19);
        }

    public:
        size_t process_samples_v2(const audio_chunk &) override { return 0; }

        bool is_progressing() override { return false; }

        double get_latency() override { return 0; }

        void process_samples(const audio_chunk &p_chunk) override {}

        void update(bool &p_ready) override {}

        void pause(bool p_state) override {}

        void flush() override {}

        void force_play() override {}

        void volume_set(double p_val) override {}

        int service_release() noexcept override { return 0; }

        int service_add_ref() noexcept override { return 0; }

        bool service_query(service_ptr &p_out, const GUID &p_guid) override { return true; }
    };

} // namespace foo_out_avf

static output_factory_t<foo_out_avf::AVFOutput> g_avf_output;
