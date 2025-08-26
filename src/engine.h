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

@interface EngineManager : NSObject

- (instancetype)init;
- (void)dealloc;
// Audio data processing interface - expects f64le (double, little-endian, packed/interleaved) format
// Audio data processing methods
- (void)feedAudioData:(const float **)channelData sampleRate:(double)sampleRate channels:(int)channels frameCount:(size_t)frameCount;
- (void)flush;
// Audio interface status management
- (bool)enable;
- (void)disable;
- (bool)isEnabled;
// Volume control
- (void)setVolume:(float)volume;
- (float)getVolume;
// Spatial audio control interface
- (void)enableSpatialAudio:(bool)enable;
- (bool)isSpatialAudioEnabled;
- (void)setListenerPosition:(float)x y:(float)y z:(float)z;
- (void)setSourcePosition:(float)x y:(float)y z:(float)z;
// AirPods detection and auto-configuration
- (bool)isAirPodsConnected;
- (void)configureForAirPods;
// System audio configuration
- (double)getSystemSampleRate;
// Logging bridge for foobar2000 console
- (void)setLogCallback:(void (*)(const char *))callback; // Pass nullptr to fallback to NSLog

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

        void feedAudioData(std::vector<const t_float32 *> channelData, double sampleRate, int channels, size_t frameCount);
        void flush();

        // Audio interface status management
        bool enable();
        void disable();
        bool isEnabled() const;

        // Volume control
        void setVolume(float volume);
        float getVolume() const;

        // Spatial audio control methods
        void enableSpatialAudio(bool enable);
        bool isSpatialAudioEnabled() const;
        void setListenerPosition(float x, float y, float z);
        void setSourcePosition(float x, float y, float z);

        // AirPods detection and auto-configuration
        bool isAirPodsConnected() const;
        void configureForAirPods();

        // System audio configuration
        double getSystemSampleRate() const;

        // Logging bridge for foobar2000 console
        void setLogCallback(void (*callback)(const char *message)); // Pass nullptr to fallback to NSLog

    private:
        // Opaque pointer to hide Objective-C implementation
        void *impl;
    };

} // namespace foo_out_avf
