//
//  engine.mm
//  foo_out_avfoundation
//
//  Created by pnck on 2025/8/8.
//

#import "engine.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#include <vector>
#include <queue>
#include <mutex>

// Compatibility macros for different macOS versions' 3D audio API
#ifndef AVAudio3DPointMake
#define AVAudio3DPointMake(x, y, z) \
    (AVAudio3DPoint) {              \
        x, y, z                     \
    }
#endif

@implementation AVFEngineImpl {

    void (*_logCallback)(const char *);

    AVSampleBufferAudioRenderer *renderer;
    AVSampleBufferRenderSynchronizer *synchronizer;
    AVAudioFormat *currentFormat;

    // Timestamp tracking for continuous audio stream
    CMTime nextPresentationTime;
    CMTime lastBufferPresentationTime; // For latency calculation
    std::mutex timestampMutex;

    // Sample queue for smooth playback
    std::queue<CMSampleBufferRef> sampleQueue;
    std::mutex sampleQueueMutex;
    uint32_t maxQueueSize;        // Maximum number of buffers in queue
    dispatch_queue_t renderQueue; // Queue for rendering from buffer

    bool _isPaused; // Pause state

    struct VENV {
        AVAudio3DPoint listenerPosition;
        AVAudio3DAngularOrientation listenerOrientation;
        AVAudio3DPoint sourcePosition;
    } *venv;
}
- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    venv = new VENV{
        .listenerPosition = AVAudio3DPointMake(0, 0, 0),
        .listenerOrientation = (AVAudio3DAngularOrientation){0, 0, 0},
        .sourcePosition = AVAudio3DPointMake(0, 0, -1)
    };

    // Initialize spatial renderer and synchronizer for audio playback
    if (@available(macOS 11.0, *)) {
        renderer = [[AVSampleBufferAudioRenderer alloc] init];
        synchronizer = [[AVSampleBufferRenderSynchronizer alloc] init];

        [synchronizer addRenderer:renderer];
        if (@available(tvOS 14.5, iOS 14.5, macOS 11.3, *)) {
            [synchronizer setDelaysRateChangeUntilHasSufficientMediaData:NO];
        }

        nextPresentationTime = kCMTimeZero;
        lastBufferPresentationTime = kCMTimeInvalid;

        // Initialize sample queue with larger buffer to reduce glitches
        maxQueueSize = 8; // Default to 8 buffers for smoother playback
        renderQueue = dispatch_queue_create("avfoundation-render-queue",
                                            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    } else {
        renderer = nil;
        synchronizer = nil;
    }

    _isEnabled = false;
    _isPaused = false;
    _logCallback = nullptr;

    return self;
}

- (void)dealloc {
    [self disable];

    // Clean up render queue
    if (renderQueue) {
        renderQueue = nullptr;
    }

    if (venv) {
        delete venv;
        venv = nullptr;
    }
}

// Sample queue configuration method
- (void)setQueueSize:(uint32_t)size {
    if (size > 0 && size <= 10) { // Reasonable limits: 1-10 buffers
        std::lock_guard<std::mutex> lock(sampleQueueMutex);
        maxQueueSize = size;
        [self logMessage:@"[AVF] Sample queue size set to %u", size];
    } else {
        [self logMessage:@"[AVF] Invalid queue size %u (must be 1-10), keeping current value %u", size, maxQueueSize];
    }
}

// Helper method for logging to foobar2000 console
- (void)logMessage:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    if (_logCallback != nullptr) {
        _logCallback([message UTF8String]);
    } else {
        // Fallback to NSLog if no callback is set
        NSLog(@"%@", message);
    }
}

- (void)setLogCallback:(void (*)(const char *))callback {
    _logCallback = callback;
}

// Setup audio format - must be called before enable
- (bool)setupAudioFormat:(uint32_t)sampleRate channels:(uint32_t)channels {
    if (@available(macOS 11.0, *)) {

        if (sampleRate == currentFormat.sampleRate && channels == currentFormat.channelCount) {
            return true;
        }

        // Use AVAudioFormat to simplify format creation
        AVAudioFormat *audioFormat = nil;

        if (channels == 1 || channels == 2) {

            audioFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                           sampleRate:sampleRate
                                                             channels:channels
                                                          interleaved:YES];
        } else {
            // For multi-channel audio, use standard format with custom channel layout
            AudioStreamBasicDescription asbd = {0};
            asbd.mSampleRate = sampleRate;
            asbd.mFormatID = kAudioFormatLinearPCM;
            asbd.mFormatFlags = kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked;
            asbd.mChannelsPerFrame = channels;
            asbd.mBitsPerChannel = 32;
            asbd.mBytesPerFrame = asbd.mChannelsPerFrame * (asbd.mBitsPerChannel / 8);
            asbd.mFramesPerPacket = 1;
            asbd.mBytesPerPacket = asbd.mBytesPerFrame * asbd.mFramesPerPacket;

            audioFormat = [[AVAudioFormat alloc] initWithStreamDescription:&asbd];
        }

        if (!audioFormat) {
            [self logMessage:@"[AVF] Failed to create AVAudioFormat"];
            return false;
        }

        currentFormat = audioFormat;
        return true;
    }

    [self logMessage:@"[AVF] Error: AVSampleBufferAudioRenderer not available on this system"];
    return false;
}

- (bool)enable {
    if (_isEnabled) {
        return true;
    }

    // Check if we have the required basic components (format description will be created later)
    if (renderer == nil || synchronizer == nil) {
        [self logMessage:@"[AVF] Error: Missing required components for audio playback"];
        return false;
    }

    if (@available(macOS 11.0, *)) {
        if (@available(macOS 12.0, *)) {
            renderer.allowedAudioSpatializationFormats = AVAudioSpatializationFormatMonoStereoAndMultichannel;
        }
        [synchronizer setRate:1.0];
        renderer.volume = 1.0;
        renderer.muted = NO;

        // Reset timestamp tracking for new session
        {
            std::lock_guard<std::mutex> lock(timestampMutex);
            nextPresentationTime = kCMTimeZero;
            lastBufferPresentationTime = kCMTimeInvalid;
        }

        // Clear sample queue
        {
            std::lock_guard<std::mutex> lock(sampleQueueMutex);
            while (!sampleQueue.empty()) {
                CMSampleBufferRef buffer = sampleQueue.front();
                sampleQueue.pop();
                CFRelease(buffer);
            }
        }

        // Start renderer to pull from sample queue
        __weak typeof(self) weakSelf = self;
        [renderer requestMediaDataWhenReadyOnQueue:renderQueue
                                        usingBlock:^{
                                          __strong typeof(weakSelf) strongSelf = weakSelf;
                                          if (strongSelf) {
                                              [strongSelf renderFromQueue];
                                          }
                                        }];

        _isPaused = false;

        _isEnabled = true;
        [self logMessage:@"[AVF] Audio engine enabled successfully using sample buffer renderer"];
        return true;
    }

    [self logMessage:@"[AVF] Error: AVSampleBufferAudioRenderer not available on this system"];
    return false;
}

- (void)disable {
    if (!_isEnabled) {
        return;
    }

    if (@available(macOS 11.0, *)) {
        // Stop requesting data from renderer
        [renderer stopRequestingMediaData];

        // Clear sample queue
        {
            std::lock_guard<std::mutex> lock(sampleQueueMutex);
            while (!sampleQueue.empty()) {
                CMSampleBufferRef buffer = sampleQueue.front();
                sampleQueue.pop();
                CFRelease(buffer);
            }
        }

        if (synchronizer != nil) {
            synchronizer.rate = 0.0;
            [renderer flush];
        }
    }

    _isEnabled = false;
    _isPaused = false;
    [self logMessage:@"[AVF] Audio engine disabled"];
}

// Pause method - stops playback but keeps queue data intact
- (void)pause {
    if (!_isEnabled) {
        return;
    }

    _isPaused = true;

    if (@available(macOS 11.0, *)) {
        // Stop the synchronizer to pause playback, but keep all buffers in queue
        synchronizer.rate = 0.0;
        [self logMessage:@"[AVF] Paused audio playback"];
    }
}

// Resume method - resumes playback from where it was paused
- (void)resume {
    if (!_isEnabled || !_isPaused) {
        return;
    }

    if (@available(macOS 11.0, *)) {
        // Resume the synchronizer to continue playback
        synchronizer.rate = 1.0;
        [self logMessage:@"[AVF] Resumed audio playback"];
    }
    _isPaused = false;
}

// Render method that pulls CMSampleBuffer from queue and sends to AVFoundation
- (void)renderFromQueue {
    if (!_isEnabled || _isPaused) {
        return;
    }

    CMSampleBufferRef sampleBuffer = NULL;

    // Get sample buffer from queue
    {
        std::lock_guard<std::mutex> lock(sampleQueueMutex);
        if (sampleQueue.empty()) {
            // No data available, AVFoundation will call us again when ready
            return;
        }

        sampleBuffer = sampleQueue.front();
        sampleQueue.pop();
    }

    if (@available(macOS 11.0, *)) {
        [renderer enqueueSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
    }
}

// Method that accepts interleaved float32 data and creates CMSampleBuffer
- (size_t)feedAudioData:(std::vector<float>)audioData
             sampleRate:(uint32_t)sampleRate
               channels:(uint32_t)channels
             frameCount:(size_t)frameCount {
    if (!_isEnabled || _isPaused) {
        return 0;
    }

    if (audioData.size() == 0 || frameCount == 0 || channels == 0) {
        [self logMessage:@"[AVF] Invalid audio data parameters"];
        return 0;
    }

    if (![self setupAudioFormat:sampleRate channels:channels]) {
        return 0;
    }

    if (@available(macOS 11.0, *)) {
        // Check if sample queue has space
        {
            std::lock_guard<std::mutex> lock(sampleQueueMutex);
            if (sampleQueue.size() >= maxQueueSize) {
                // Sample queue is full, return 0 to indicate no samples were processed
                return 0;
            }
        }

        // Create CMSampleBuffer
        CMBlockBufferRef blockBuffer = NULL;
        CMSampleBufferRef sampleBuffer = NULL;
        OSStatus status;

        size_t sampleSize = sizeof(decltype(audioData)::value_type) * channels;
        size_t dataSize = sizeof(decltype(audioData)::value_type) * audioData.size();

        // Allocate memory using CFAllocator
        void *data = CFAllocatorAllocate(kCFAllocatorDefault, dataSize, 0);
        if (!data) {
            [self logMessage:@"[AVF] Failed to allocate memory for audio data"];
            return 0;
        }

        // Copy audio data
        memcpy(data, audioData.data(), dataSize);

        // Create CMBlockBuffer
        status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                    data,
                                                    dataSize,
                                                    kCFAllocatorDefault, // CFAllocator will manage the memory
                                                    NULL,
                                                    0,
                                                    dataSize,
                                                    0,
                                                    &blockBuffer);
        if (status != noErr) {
            CFAllocatorDeallocate(kCFAllocatorDefault, data);
            [self logMessage:@"[AVF] Failed to create block buffer: %d", (int)status];
            return 0;
        }

        // Calculate timing info with relative timestamps
        CMTime frameDuration = CMTimeMake(frameCount, sampleRate);
        CMTime currentPresentationTime;

        // Get and update timestamp atomically
        {
            std::lock_guard<std::mutex> lock(timestampMutex);
            currentPresentationTime = nextPresentationTime;
            nextPresentationTime = CMTimeAdd(nextPresentationTime, frameDuration);
            // Update last buffer timestamp for latency calculation
            lastBufferPresentationTime = currentPresentationTime;
        }

        // Use kCMTimeInvalid for timing info to let AVFoundation handle timing automatically
        CMSampleTimingInfo sampleTimingInfo = {
            .duration = frameDuration, .presentationTimeStamp = kCMTimeInvalid, .decodeTimeStamp = kCMTimeInvalid};

        size_t sampleSizeArray[] = {sampleSize};

        // Create sample buffer
        status = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                           blockBuffer,
                                           currentFormat.formatDescription,
                                           frameCount,
                                           1,
                                           &sampleTimingInfo,
                                           1,
                                           sampleSizeArray,
                                           &sampleBuffer);

        CFRelease(blockBuffer);

        if (status == noErr && sampleBuffer != NULL) {
            // Add to sample queue instead of directly enqueueing
            {
                std::lock_guard<std::mutex> lock(sampleQueueMutex);
                sampleQueue.push(sampleBuffer);
                // Don't CFRelease here - queue owns the reference
            }

            // Buffer successfully added to queue
            return frameCount;
        } else {
            [self logMessage:@"[AVF] Failed to create sample buffer: %d", (int)status];
            return 0;
        }
    }

    // For systems without AVSampleBufferAudioRenderer support, log error
    [self logMessage:@"[AVF] Error: AVSampleBufferAudioRenderer not available on this system"];
    return 0;
}

- (void)flush {
    if (!_isEnabled) {
        return;
    }

    if (@available(macOS 11.0, *)) {

        // Reset timestamp for next audio data
        {
            std::lock_guard<std::mutex> lock(timestampMutex);
            nextPresentationTime = kCMTimeZero;
            lastBufferPresentationTime = kCMTimeInvalid;
        }

        // Flush AVFoundation renderer
        if (renderer != nil) {
            [renderer flush];
        }
    }
}

- (void)setVolume:(float)volume {

    // Set volume on spatial renderer if available (macOS 11.0+)
    if (renderer != nil) {
        if (@available(macOS 11.0, *)) {
            renderer.volume = volume;
        }
    }
}

- (float)getVolume {
    if (!renderer) {
        return 0.0f;
    }
    return renderer.volume;
}

- (double)getCurrentLatency {
    if (!_isEnabled || !currentFormat) {
        return 0.01;
    }

    // Calculate latency based on the number of buffers in the queue
    double queueLatency = 0.0;
    {
        std::lock_guard<std::mutex> lock(sampleQueueMutex);
        // Estimate latency based on queue size and typical buffer duration
        // Assume each buffer is about 10-20ms worth of audio
        queueLatency = sampleQueue.size() * 0.015; // 15ms per buffer estimate
    }

    // Add a small constant for AVFoundation's internal buffering
    double totalLatency = queueLatency + 0.01;

    return totalLatency;
}

- (bool)isReadyForMoreMediaData {
    if (!_isEnabled || _isPaused) {
        return false;
    }

    // Check if queue has space
    {
        std::lock_guard<std::mutex> lock(sampleQueueMutex);
        return sampleQueue.size() < maxQueueSize;
    }
}

- (uint32_t)pendingBufferCount {
    std::lock_guard<std::mutex> lock(sampleQueueMutex);
    return static_cast<uint32_t>(sampleQueue.size());
}

- (void)setListenerPosition:(float)x y:(float)y z:(float)z {
    if (venv) {
        venv->listenerPosition = AVAudio3DPointMake(x, y, z);
        [self logMessage:@"[AVF] Listener position set to: (%.2f, %.2f, %.2f)", x, y, z];
    }
}

- (void)setListenerOrientation:(float)yaw pitch:(float)pitch roll:(float)roll {
    if (venv) {
        venv->listenerOrientation = AVAudio3DAngularOrientation{yaw, pitch, roll};
        [self logMessage:@"[AVF] Listener orientation set to: yaw=%.2f, pitch=%.2f, roll=%.2f", yaw, pitch, roll];
    }
}

- (void)setSourcePosition:(float)x y:(float)y z:(float)z {
    if (venv) {
        venv->sourcePosition = AVAudio3DPointMake(x, y, z);
        ;
        [self logMessage:@"[AVF] Source position set to: (%.2f, %.2f, %.2f)", x, y, z];
    }
}

@end

// C++ implementation
namespace foo_out_avf
{

    AVFEngine::AVFEngine() {
        // Create the Objective-C implementation object
        impl_ = (__bridge_retained void *)[[AVFEngineImpl alloc] init];
    }

    AVFEngine::~AVFEngine() {
        // Release the Objective-C implementation object
        if (impl_) {
            (void)(__bridge_transfer AVFEngineImpl *)impl_;
            impl_ = nullptr;
        }
    }

    void AVFEngine::flush() {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        [impl flush];
    }

    void AVFEngine::pause() {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        [impl pause];
    }

    void AVFEngine::resume() {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        [impl resume];
    }

    bool AVFEngine::enable() {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        return [impl enable];
    }

    void AVFEngine::disable() {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        [impl disable];
    }

    bool AVFEngine::isEnabled() const {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        return [impl isEnabled];
    }

    bool AVFEngine::isPaused() const {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        return [impl isPaused];
    }

    void AVFEngine::setVolume(float volume) {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        [impl setVolume:volume];
    }

    float AVFEngine::getVolume() const {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        return [impl getVolume];
    }

    void AVFEngine::setListenerPosition(float x, float y, float z) {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        [impl setListenerPosition:x y:y z:z];
    }

    void AVFEngine::setListenerOrientation(float yaw, float pitch, float roll) {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        [impl setListenerOrientation:yaw pitch:pitch roll:roll];
    }

    void AVFEngine::setSourcePosition(float x, float y, float z) {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        [impl setSourcePosition:x y:y z:z];
    }

    double AVFEngine::getCurrentLatency() const {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        return [impl getCurrentLatency];
    }

    uint32_t AVFEngine::pendingBufferCount() const {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        return [impl pendingBufferCount];
    }

    bool AVFEngine::isReadyForMoreMediaData() const {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        return [impl isReadyForMoreMediaData];
    }

    size_t AVFEngine::feedAudioData(std::vector<float> audioData, uint32_t sampleRate, uint32_t channels, size_t sample_count) {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        return [impl feedAudioData:std::move(audioData) sampleRate:sampleRate channels:channels frameCount:sample_count];
    }

    void AVFEngine::setLogCallback(void (*callback)(const char *message)) {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        [impl setLogCallback:callback];
    }

    bool AVFEngine::setupAudioFormat(double sampleRate, int channels) {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        return [impl setupAudioFormat:sampleRate channels:channels];
    }

} // namespace foo_out_avf
