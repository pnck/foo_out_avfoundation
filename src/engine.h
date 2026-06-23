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

@interface AVFEngineImpl : NSObject

- (instancetype)init;
- (void)dealloc;

// Audio format setup - must be called before enable
- (bool)setupAudioFormat:(uint32_t)sampleRate channels:(uint32_t)channels;

// Push side (foobar2000's process_samples_v2). Shallow sink: we decide how many of the offered
// frames to take (under the target lead), allocate the destination block, and call
// `convert(dst, frames)` to write that many interleaved float frames straight into it (single
// copy). Returns frames actually taken; foobar keeps the remainder. See README.md.
- (size_t)feedAudioData:(uint32_t)sampleRate
               channels:(uint32_t)channels
             frameCount:(size_t)frameCount
              converter:(const std::function<void(float *, size_t)> &)convert;

- (void)flush;
- (void)pause;
- (void)resume;
- (void)forcePlay;

// Audio interface status management
- (bool)enable;
- (void)disable;

// foobar2000's configured output buffer length (seconds) — the steady-state lead we keep
// enqueued in the renderer. Call before enable.
- (void)setBufferLength:(double)seconds;

// Backpressure for foobar's update()/update_v2(): can we accept more right now, and roughly
// how many frames (advisory) before we hit the target lead.
- (bool)canAcceptMore;
- (size_t)freeSampleCount;

// Volume control
- (void)setVolume:(float)volume;
- (float)getVolume;

// Spatial audio control
- (void)setListenerPosition:(float)x y:(float)y z:(float)z;
- (void)setListenerOrientation:(float)yaw pitch:(float)pitch roll:(float)roll;
- (void)setSourcePosition:(float)x y:(float)y z:(float)z;

// Latency calculation (our queued seconds = lead ahead of the play head)
- (double)getCurrentLatency;

// Logging bridge for foobar2000 console
- (void)setLogCallback:(void (*)(const char *))callback; // Pass nullptr to fallback to NSLog

@property(nonatomic, readonly, getter=isEnabled) bool isEnabled;
@property(nonatomic, readonly, getter=isPaused) bool isPaused;
// True once primed and actually playing (clock running) — maps to output_v4::is_progressing.
@property(nonatomic, readonly, getter=isProgressing) bool isProgressing;

@end
#endif // __OBJC__

// C++ interface
namespace foo_out_avf
{

    class AVFEngine {
    public:
        AVFEngine();
        ~AVFEngine();

        // Prevent copying
        AVFEngine(const AVFEngine &) = delete;
        AVFEngine &operator=(const AVFEngine &) = delete;

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
        // Opaque pointer to hide Objective-C implementation
        void *impl_ = nullptr;
    };

} // namespace foo_out_avf
