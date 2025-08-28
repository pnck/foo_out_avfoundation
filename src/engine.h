//
//  engine.h
//  foo_out_avfoundation
//
//  Created by pnck on 2025/8/8.
//

#pragma once

#include <span>
#include <vector>

#ifdef __OBJC__
#import <AVFoundation/AVFoundation.h>
#import <AVFAudio/AVFAudio.h>
#import <CoreAudio/CoreAudioTypes.h>

@interface AVFEngineImpl : NSObject

- (instancetype)init;
- (void)dealloc;

// Audio format setup - must be called before enable
- (bool)setupAudioFormat:(uint32_t)sampleRate channels:(uint32_t)channels;

// Audio data processing interface - expects interleaved float32 format
- (size_t)feedAudioData:(std::vector<float>)audioData
             sampleRate:(uint32_t)sampleRate
               channels:(uint32_t)channels
             frameCount:(size_t)frameCount;

- (void)flush;
- (void)pause;
- (void)resume;

// Audio interface status management
- (bool)enable;
- (void)disable;

// Sample queue configuration
- (void)setQueueSize:(uint32_t)size;

// Volume control
- (void)setVolume:(float)volume;
- (float)getVolume;

// Spatial audio control
- (void)setListenerPosition:(float)x y:(float)y z:(float)z;
- (void)setListenerOrientation:(float)yaw pitch:(float)pitch roll:(float)roll;
- (void)setSourcePosition:(float)x y:(float)y z:(float)z;

// Latency calculation
- (double)getCurrentLatency;

// Logging bridge for foobar2000 console
- (void)setLogCallback:(void (*)(const char *))callback; // Pass nullptr to fallback to NSLog

@property(nonatomic, readonly, getter=isEnabled) bool isEnabled;
@property(nonatomic, readonly, getter=isPaused) bool isPaused;
@property(nonatomic, readonly) uint32_t pendingBufferCount;
@property(nonatomic, readonly, getter=isReadyForMoreMediaData) bool readyForMoreMediaData;

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

        size_t feedAudioData(std::vector<float>, uint32_t sampleRate, uint32_t channels, size_t sample_count);
        void flush();
        void pause();
        void resume();

        // Buffer configuration
        void setQueueSize(uint32_t size);
        
        // Audio interface status management
        bool enable();
        void disable();
        bool isEnabled() const;
        bool isPaused() const;

        // Volume control
        void setVolume(float volume);
        float getVolume() const;

        void setListenerPosition(float x, float y, float z);
        void setListenerOrientation(float yaw, float pitch, float roll);
        void setSourcePosition(float x, float y, float z);

        // Latency calculation
        double getCurrentLatency() const;

        // Buffer status query
        uint32_t pendingBufferCount() const;
        bool isReadyForMoreMediaData() const;

        // Logging bridge for foobar2000 console
        void setLogCallback(void (*callback)(const char *message)); // Pass nullptr to fallback to NSLog

    private:
        // Opaque pointer to hide Objective-C implementation
        void *impl_ = nullptr;
    };

} // namespace foo_out_avf
