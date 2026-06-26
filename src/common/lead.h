//
//  lead.h
//  foo_out_avfoundation
//
//  Shared output-lead policy for BOTH backends (engine_sys_spatialized.mm, engine_virtual_3d.mm):
//  the fsec currency type, the device-transport lead floors, and the CoreAudio query that picks the
//  floor for the current default output device. This used to be copy-pasted into each backend — DON'T
//  do that again (see AGENTS.md): one definition here, included by both, so the policy can never drift
//  between the two engines.
//
//  Everything is `inline` so this header can be included by multiple translation units without a
//  duplicate-symbol / ODR problem.
//

#pragma once

#include <CoreAudio/CoreAudio.h> // C framework — #include (not #import) so this header is usable from
                                  // plain C++ TUs too, not only ObjC++.
#include <chrono>

namespace foo_out_avf
{
    namespace lead
    {
        // A duration in floating-point seconds — our currency for everything time-valued. Beats a bare
        // double because the unit is in the type (no "is this seconds or ms?" guessing), and it converts
        // to/from the SDK boundaries (foobar's double seconds, CMTime, frame counts) at named casts.
        using fsec = std::chrono::duration<double>;

        // Display helper: a duration's value in milliseconds, for the [AVF]/[V3D] log lines.
        inline double ms(fsec s) { return std::chrono::duration<double, std::milli>(s).count(); }

        // Bank just this much before starting (prime), then keep filling to the full lead while playing.
        inline constexpr fsec kPrime{0.2}; // 200 ms

        // Floor on the lead, chosen by the output device's transport type (CoreAudio HAL, refreshed on
        // the default-device-changed notification). Wireless routes (Bluetooth / AirPlay) have far
        // higher, burstier latency than the built-in DAC, so they need a deeper lead to avoid underruns;
        // built-in can stay tighter for lower latency.
        inline constexpr fsec kBuiltinFloor{0.2};  // built-in / wired — 200 ms
        inline constexpr fsec kWirelessFloor{0.5}; // Bluetooth / AirPlay (also the safe default) — 500 ms

        // Minimum batch we accept in one go, so we never top the lead up one or two SAMPLES at a time
        // (which thrashes the renderer's queue). Waiting for a whole batch keeps the buffers sane.
        inline constexpr fsec kMinFeed{0.02}; // 20 ms

        // The CoreAudio property address we observe for output-device changes (and re-query the floor on).
        inline AudioObjectPropertyAddress kDefaultOutputDeviceAddr = {
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain,
        };

        // Lead floor for the CURRENT system default output device, by transport type (CoreAudio HAL).
        // Wireless (Bluetooth / BluetoothLE / AirPlay) → the deeper floor; everything else (built-in,
        // USB, HDMI, …) → the tighter floor. On any query failure return the wireless (safe) floor.
        inline fsec currentOutputFloor() {
            AudioObjectID dev = kAudioObjectUnknown;
            UInt32 size = sizeof(dev);
            AudioObjectPropertyAddress addr = kDefaultOutputDeviceAddr;
            if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &dev) != noErr ||
                dev == kAudioObjectUnknown) {
                return kWirelessFloor;
            }
            UInt32 transport = 0;
            size = sizeof(transport);
            addr.mSelector = kAudioDevicePropertyTransportType;
            if (AudioObjectGetPropertyData(dev, &addr, 0, NULL, &size, &transport) != noErr) {
                return kWirelessFloor;
            }
            switch (transport) {
            case kAudioDeviceTransportTypeBluetooth:
            case kAudioDeviceTransportTypeBluetoothLE:
            case kAudioDeviceTransportTypeAirPlay:
                return kWirelessFloor;
            default:
                return kBuiltinFloor;
            }
        }
    } // namespace lead
} // namespace foo_out_avf
