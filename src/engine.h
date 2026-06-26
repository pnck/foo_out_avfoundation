//
//  engine.h
//  foo_out_avfoundation
//
//  Created by pnck on 2025/8/8.
//

#pragma once

#include <span>
#include <vector>
#include <functional>

#ifdef __OBJC__
#import <AVFoundation/AVFoundation.h>
#import <AVFAudio/AVFAudio.h>
#import <CoreAudio/CoreAudioTypes.h>

// The output-backend surface shared by every AVFoundation backend. The C++ facade (engine.mm)
// holds an id<AVFOutputBackend> and picks the concrete backend by OutputMode:
//   - AVFSysSpatializedBackend          (engine_sys_spatialized.mm)  — system Spatial Audio path (default)
//   - AVFVirtualSurroundBackend  (engine_virtual_surround.mm)   — in-process HRTFHQ positional path (VSurround)
@protocol AVFOutputBackend <NSObject>

// Audio format setup — must be called before enable.
- (bool)setupAudioFormat:(uint32_t)sampleRate channels:(uint32_t)channels;

// Push side (foobar2000's process_samples_v2). Shallow sink: the backend decides how many of the
// offered frames to take (under its target lead), allocates the destination, and calls
// `convert(dst, frames)` to write that many interleaved float frames straight in (single copy).
// Returns frames actually taken; foobar keeps the remainder. See docs/memo.md.
- (size_t)feedAudioData:(uint32_t)sampleRate
               channels:(uint32_t)channels
             frameCount:(size_t)frameCount
              converter:(const std::function<void(float *, size_t)> &)convert;

- (void)flush;
- (void)pause;
- (void)resume;
- (void)forcePlay;

- (bool)enable;
- (void)disable;

// foobar2000's configured output buffer length (seconds). Call before enable.
- (void)setBufferLength:(double)seconds;

// Backpressure for foobar's update()/update_v2().
- (bool)canAcceptMore;
- (size_t)freeSampleCount;

- (void)setVolume:(float)volume;
- (float)getVolume;

// Spatial positioning. The default backend keeps these as informational no-ops (the system
// spatializer owns placement); the VSurround backend wires them straight into the HRTFHQ renderer.
- (void)setListenerPosition:(float)x y:(float)y z:(float)z;
- (void)setListenerOrientation:(float)yaw pitch:(float)pitch roll:(float)roll;
- (void)setSourcePosition:(float)x y:(float)y z:(float)z;

- (double)getCurrentLatency;

- (void)setLogCallback:(void (*)(const char *))callback; // Pass nullptr to fall back to NSLog

@property(nonatomic, readonly, getter=isEnabled) bool isEnabled;
@property(nonatomic, readonly, getter=isPaused) bool isPaused;
// True once primed and actually playing (clock running) — maps to output_v4::is_progressing.
@property(nonatomic, readonly, getter=isProgressing) bool isProgressing;

@end

// Default backend: AVSampleBufferAudioRenderer + AVSampleBufferRenderSynchronizer (system Spatial
// Audio). Implementation in engine_sys_spatialized.mm — unchanged from the original single-engine design.
@interface AVFSysSpatializedBackend : NSObject <AVFOutputBackend>
- (instancetype)init;
// Re-declared from AVFOutputBackend so they auto-synthesize their backing ivars/getters here
// (protocol-declared properties are not auto-synthesized in the adopting class).
@property(nonatomic, readonly, getter=isEnabled) bool isEnabled;
@property(nonatomic, readonly, getter=isPaused) bool isPaused;
@property(nonatomic, readonly, getter=isProgressing) bool isProgressing;
@end
#endif // __OBJC__

// C++ interface
namespace foo_out_avf
{

    // Which spatialization path the engine drives. Selected from config before enable().
    enum class OutputMode {
        SystemSpatial = 0, // AVSampleBufferAudioRenderer -> macOS system Spatial Audio (default)
        VirtualSurround = 1,     // AVAudioEngine + AVAudioEnvironmentNode (HRTFHQ) -> custom positioning
    };

    class AVFEngine {
    public:
        explicit AVFEngine(OutputMode mode = OutputMode::SystemSpatial);
        ~AVFEngine();

        // Prevent copying
        AVFEngine(const AVFEngine &) = delete;
        AVFEngine &operator=(const AVFEngine &) = delete;

        // Select the backend. Call BEFORE enable(); recreates the backend if the mode changed.
        // Switching while playing is not supported — the output is rebuilt on a mode change.
        void setMode(OutputMode mode);
        OutputMode mode() const;

        // Audio format setup - must be called before enable
        bool setupAudioFormat(double sampleRate, int channels);

        // Decides how many of `frameCount` offered frames to take, then calls convert(dst, frames)
        // to write that many interleaved float frames into the destination block (single copy).
        // Returns frames actually taken (may be < frameCount: partial).
        size_t feedAudioData(uint32_t sampleRate, uint32_t channels, size_t frameCount,
                             const std::function<void(float *, size_t)> &convert);
        void flush();
        void pause();
        void resume();
        void forcePlay();

        // foobar2000's configured output buffer length (seconds). Call before enable().
        void setBufferLength(double seconds);

        // Audio interface status management
        bool enable();
        void disable();
        bool isEnabled() const;
        bool isPaused() const;
        bool isProgressing() const;

        // Volume control
        void setVolume(float volume);
        float getVolume() const;

        void setListenerPosition(float x, float y, float z);
        void setListenerOrientation(float yaw, float pitch, float roll);
        void setSourcePosition(float x, float y, float z);

        // Latency calculation
        double getCurrentLatency() const;

        // Backpressure for foobar2000's update()/update_v2()
        bool canAcceptMore() const;
        size_t freeSampleCount() const;

        // Logging bridge for foobar2000 console
        void setLogCallback(void (*callback)(const char *message)); // Pass nullptr to fallback to NSLog

    private:
        void *impl_ = nullptr; // id<AVFOutputBackend> (bridged-retained)
        OutputMode mode_ = OutputMode::SystemSpatial;
    };

} // namespace foo_out_avf
