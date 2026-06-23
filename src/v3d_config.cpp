//
//  v3d_config.cpp
//  foo_out_avfoundation
//
//  configStore-backed implementation of the V3D configuration accessors. Keys are namespaced under
//  "foo_out_avf." so they don't collide with other components' settings.
//

#include "v3d_config.h"
#include "foobar2000/SDK/configStore.h"

namespace foo_out_avf
{
    namespace v3d_config
    {
        namespace
        {
            constexpr const char *K_MODE = "foo_out_avf.mode";
            constexpr const char *K_SRC_X = "foo_out_avf.src.x";
            constexpr const char *K_SRC_Y = "foo_out_avf.src.y";
            constexpr const char *K_SRC_Z = "foo_out_avf.src.z";
            constexpr const char *K_SIZE = "foo_out_avf.size";
            constexpr const char *K_SPREAD = "foo_out_avf.spread";
            constexpr const char *K_YAW = "foo_out_avf.listener.yaw";
            constexpr const char *K_PITCH = "foo_out_avf.listener.pitch";
            constexpr const char *K_ROLL = "foo_out_avf.listener.roll";

            fb2k::configStore::ptr store() { return fb2k::configStore::get(); }
        } // namespace

        OutputMode mode() {
            return store()->getConfigInt(K_MODE, 0) == 1 ? OutputMode::Virtual3D : OutputMode::SystemSpatial;
        }
        void set_mode(OutputMode m) {
            store()->setConfigInt(K_MODE, m == OutputMode::Virtual3D ? 1 : 0);
        }

        Vec3 source_position() {
            auto s = store();
            return Vec3{s->getConfigFloat(K_SRC_X, 0.0), s->getConfigFloat(K_SRC_Y, 0.0),
                        s->getConfigFloat(K_SRC_Z, -2.0)};
        }
        void set_source_position(const Vec3 &p) {
            auto s = store();
            s->setConfigFloat(K_SRC_X, p.x);
            s->setConfigFloat(K_SRC_Y, p.y);
            s->setConfigFloat(K_SRC_Z, p.z);
        }

        double size() { return store()->getConfigFloat(K_SIZE, 0.0); }
        void set_size(double v) { store()->setConfigFloat(K_SIZE, v); }
        double spread() { return store()->getConfigFloat(K_SPREAD, 0.0); }
        void set_spread(double v) { store()->setConfigFloat(K_SPREAD, v); }

        Vec3 listener_orientation() {
            auto s = store();
            return Vec3{s->getConfigFloat(K_YAW, 0.0), s->getConfigFloat(K_PITCH, 0.0),
                        s->getConfigFloat(K_ROLL, 0.0)};
        }
        void set_listener_orientation(const Vec3 &o) {
            auto s = store();
            s->setConfigFloat(K_YAW, o.x);
            s->setConfigFloat(K_PITCH, o.y);
            s->setConfigFloat(K_ROLL, o.z);
        }

    } // namespace v3d_config
} // namespace foo_out_avf
