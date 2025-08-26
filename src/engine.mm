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
#include <vector>

// Compatibility macros for different macOS versions' 3D audio API
#ifndef AVAudio3DPointMake
#define AVAudio3DPointMake(x, y, z) \
    (AVAudio3DPoint) {              \
        x, y, z                     \
    }
#endif

// Objective-C implementation
@implementation EngineManager {
    AVAudioEngine *_audioEngine;
    AVAudioPlayerNode *_playerNode;
    AVAudioEnvironmentNode *_environmentNode; // Available but not connected for testing
    float _volume;
    bool _isEnabled;
    bool _spatialAudioEnabled;
    double _lastSampleRate;
    int _lastChannels;
    AVAudioFormat *_currentFormat; // Current audio format
    void (*_logCallback)(const char *);

    // Synchronization for blocking audio playback
    NSCondition *_playbackCondition;
    NSInteger _pendingBuffers;
    NSInteger _maxPendingBuffers;
    bool _nodesConnected;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _audioEngine = [[AVAudioEngine alloc] init];
        _playerNode = [[AVAudioPlayerNode alloc] init];
        _environmentNode = [[AVAudioEnvironmentNode alloc] init];

        [_audioEngine attachNode:_playerNode];
        [_audioEngine attachNode:_environmentNode];

        // Default values
        _volume = 1.0f;
        _isEnabled = false;
        _spatialAudioEnabled = false;
        _lastSampleRate = 0.0;
        _lastChannels = 0;
        _currentFormat = nil;
        _logCallback = nullptr;

        // Initialize synchronization for blocking playback
        _playbackCondition = [[NSCondition alloc] init];
        _pendingBuffers = 0;
        _maxPendingBuffers = 3;
        _nodesConnected = false;

        // Set initial volume
        _playerNode.volume = _volume;

        // Configure environment node default parameters
        _environmentNode.listenerPosition = AVAudio3DPointMake(0, 0, 0);
        AVAudio3DAngularOrientation orientation = {0, 0, 0};
        _environmentNode.listenerAngularOrientation = orientation;
        _environmentNode.renderingAlgorithm = AVAudio3DMixingRenderingAlgorithmEqualPowerPanning;

        // Configure default source position (1 meter in front of listener)
        AVAudio3DPoint defaultSourcePosition = AVAudio3DPointMake(0, 0, -1);
        if ([_playerNode respondsToSelector:@selector(setPosition:)]) {
            [_playerNode setPosition:defaultSourcePosition];
        }

        // Configure environment node for AirPods spatial audio support
        if (@available(macOS 12.0, *)) {
            _environmentNode.outputType = AVAudioEnvironmentOutputTypeHeadphones;
        }

        [self logMessage:@"[AVF] Engine initialized with f32 non-interleaved format support"];
    }
    return self;
}

- (void)dealloc {
    [self disable];
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

- (bool)enable {
    if (_isEnabled) {
        return true;
    }

    // Use f32 non-interleaved format (CoreAudio compatible)
    _currentFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:48000.0 channels:2 interleaved:NO];

    if (_currentFormat == nil) {
        [self logMessage:@"[AVF] Failed to create f32 non-interleaved format"];
        return false;
    }

    // Connect audio chain: PlayerNode -> EnvironmentNode -> MainMixer
    [_audioEngine connect:_playerNode to:_environmentNode format:_currentFormat];
    [_audioEngine connect:_environmentNode to:_audioEngine.mainMixerNode format:_currentFormat];
    _nodesConnected = true;

    [self logMessage:@"[AVF] Audio chain: PlayerNode -> EnvironmentNode -> MainMixer (f32 non-interleaved)"];

    NSError *error = nil;
    if ([_audioEngine startAndReturnError:&error]) {
        _isEnabled = true;
        [_playerNode play];
        [self logMessage:@"[AVF] Audio engine enabled successfully with spatial audio support"];

        // Auto-configure for AirPods if connected
        [self configureForAirPods];

        return true;
    } else {
        [self logMessage:@"[AVF] Error starting audio engine: %@", error];
        return false;
    }
}

- (void)disable {
    if (!_isEnabled) {
        return;
    }

    [_playerNode stop];

    // Wake up any threads waiting for buffer space
    [_playbackCondition lock];
    _isEnabled = false;
    _pendingBuffers = 0;
    [_playbackCondition broadcast];
    [_playbackCondition unlock];

    // Disconnect nodes before stopping engine
    if (_nodesConnected) {
        [_audioEngine disconnectNodeInput:_environmentNode];
        [_audioEngine disconnectNodeInput:_audioEngine.mainMixerNode];
        _nodesConnected = false;
        [self logMessage:@"[AVF] Audio nodes disconnected"];
    }

    [_audioEngine stop];
    [self logMessage:@"[AVF] Audio engine disabled"];
}

- (bool)isEnabled {
    return _isEnabled;
}

// New method that accepts f32 non-interleaved data (converted in C++ layer)
- (void)feedAudioData:(const float **)channelData sampleRate:(double)sampleRate channels:(int)channels frameCount:(size_t)frameCount {
    if (!_isEnabled) {
        return;
    }

    if (channelData == nullptr || frameCount == 0 || channels == 0) {
        [self logMessage:@"[AVF] Invalid audio data parameters"];
        return;
    }

    // Check if format needs updating (sample rate or channel count changed)
    if (_currentFormat == nil || _lastSampleRate != sampleRate || _lastChannels != channels) {
        // Log format change for debugging
        if (_lastSampleRate != 0.0 && _lastSampleRate != sampleRate) {
            [self logMessage:@"[AVF] Sample rate changed from %.0f Hz to %.0f Hz", _lastSampleRate, sampleRate];
        }
        if (_lastChannels != 0 && _lastChannels != channels) {
            [self logMessage:@"[AVF] Channel count changed from %d to %d", _lastChannels, channels];
        }

        // Disconnect existing connection
        if (_nodesConnected) {
            [_audioEngine disconnectNodeInput:_environmentNode];
            [_audioEngine disconnectNodeInput:_audioEngine.mainMixerNode];
            [self logMessage:@"[AVF] Disconnected for format change"];
        }

        // Create new f32 non-interleaved format
        _currentFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                          sampleRate:sampleRate
                                                            channels:channels
                                                         interleaved:NO];
        if (_currentFormat == nil) {
            [self logMessage:@"[AVF] Failed to create f32 non-interleaved format: %.0f Hz, %d channels", sampleRate, channels];
            return;
        }

        // Reconnect with new format
        [_audioEngine connect:_playerNode to:_environmentNode format:_currentFormat];
        [_audioEngine connect:_environmentNode to:_audioEngine.mainMixerNode format:_currentFormat];
        _nodesConnected = true;
        _lastSampleRate = sampleRate;
        _lastChannels = channels;
        [self logMessage:@"[AVF] Format updated: %.0f Hz, %d channels (f32 non-interleaved)", sampleRate, channels];
    }

    // Create buffer using f32 non-interleaved format and copy data
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_currentFormat frameCapacity:(AVAudioFrameCount)frameCount];
    if (buffer == nil) {
        [self logMessage:@"[AVF] Failed to create audio buffer"];
        return;
    }
    buffer.frameLength = (AVAudioFrameCount)frameCount;

    // Copy data from C++ managed non-interleaved buffers to AVFoundation buffer
    for (int ch = 0; ch < channels; ch++) {
        float *bufferChannelData = buffer.floatChannelData[ch];
        if (bufferChannelData == nil) {
            [self logMessage:@"[AVF] Failed to get buffer channel %d data pointer", ch];
            return;
        }
        memcpy(bufferChannelData, channelData[ch], frameCount * sizeof(float));
    }

    // Wait if we have too many pending buffers (back-pressure mechanism)
    [_playbackCondition lock];
    while (_pendingBuffers >= _maxPendingBuffers && _isEnabled) {
        [self logMessage:@"[AVF] Waiting for buffer space (pending: %ld)", (long)_pendingBuffers];
        [_playbackCondition wait];
    }
    [_playbackCondition unlock];

    if (!_isEnabled) {
        return; // Engine was disabled while waiting
    }

    // Schedule buffer for playback
    if ([_playerNode respondsToSelector:@selector(scheduleBuffer:completionHandler:)]) {
        [_playbackCondition lock];
        _pendingBuffers++;
        [_playbackCondition unlock];

        [_playerNode scheduleBuffer:buffer
                  completionHandler:^{
                    // Buffer finished playing - decrease pending count and signal waiting threads
                    [self->_playbackCondition lock];
                    self->_pendingBuffers--;
                    [self->_playbackCondition signal];
                    [self->_playbackCondition unlock];
                  }];

        // Critical: Ensure the player node is actually playing
        // AVAudioPlayerNode can stop automatically when it runs out of buffers
        if (![_playerNode isPlaying]) {
            [_playerNode play];
            [self logMessage:@"[AVF] Restarted player node playback"];
        }

        // Calculate buffer duration and block to maintain audio synchronization
        double bufferDuration = (double)frameCount / sampleRate;
        
        // This blocking is essential for proper audio timing with foobar2000
        if (bufferDuration > 0.001) {                             // Only for buffers longer than 1ms
            [NSThread sleepForTimeInterval:bufferDuration * 0.8]; // Sleep for 80% of buffer duration
        }

    } else {
        [self logMessage:@"[AVF] Player node does not support scheduling buffers"];
    }
}

- (void)flush {
    if (_isEnabled) {
        [_playerNode stop];

        // Reset pending buffer count and wake up any waiting threads
        [_playbackCondition lock];
        _pendingBuffers = 0;
        [_playbackCondition broadcast]; // Wake up all waiting threads
        [_playbackCondition unlock];

        [_playerNode play];
        [self logMessage:@"[AVF] Audio buffers flushed and player restarted"];
    }
}

- (void)setVolume:(float)volume {
    _volume = volume;
    _playerNode.volume = volume;
}

- (float)getVolume {
    return _volume;
}

// Spatial audio control method implementations
- (void)enableSpatialAudio:(bool)enable {
    _spatialAudioEnabled = enable;

    if (enable) {
        // Enable spatial audio algorithm - use compatible enum value
        _environmentNode.renderingAlgorithm = AVAudio3DMixingRenderingAlgorithmSphericalHead;

        // Configure spatial audio output for AirPods
        if (@available(macOS 12.0, *)) {
            _environmentNode.outputType = AVAudioEnvironmentOutputTypeHeadphones;
        }

        [self logMessage:@"[AVF] Spatial audio enabled - AirPods head tracking will be active when connected"];
    } else {
        // Disable spatial audio, return to normal stereo mode
        _environmentNode.renderingAlgorithm = AVAudio3DMixingRenderingAlgorithmEqualPowerPanning;

        [self logMessage:@"[AVF] Spatial audio disabled"];
    }
}

- (bool)isSpatialAudioEnabled {
    return _spatialAudioEnabled;
}

- (void)setListenerPosition:(float)x y:(float)y z:(float)z {
    AVAudio3DPoint position = AVAudio3DPointMake(x, y, z);
    _environmentNode.listenerPosition = position;
    [self logMessage:@"[AVF] Listener position set to: (%.2f, %.2f, %.2f)", x, y, z];
}

- (void)setSourcePosition:(float)x y:(float)y z:(float)z {
    AVAudio3DPoint position = AVAudio3DPointMake(x, y, z);
    if ([_playerNode respondsToSelector:@selector(setPosition:)]) {
        [_playerNode setPosition:position];
        [self logMessage:@"[AVF] Source position set to: (%.2f, %.2f, %.2f)", x, y, z];
    } else {
        [self logMessage:@"[AVF] Warning: setPosition: method not available on player node"];
    }
}

// AirPods detection and auto-configuration methods
- (bool)isAirPodsConnected {
    // Use Core Audio to detect AirPods on macOS
    AudioDeviceID defaultOutputDevice;
    UInt32 size = sizeof(AudioDeviceID);

    AudioObjectPropertyAddress propertyAddress = {
        kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};

    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &size, &defaultOutputDevice);

    if (status != noErr || defaultOutputDevice == kAudioDeviceUnknown) {
        return false;
    }

    // Get device name
    CFStringRef deviceName = NULL;
    size = sizeof(CFStringRef);
    propertyAddress.mSelector = kAudioDevicePropertyDeviceNameCFString;
    propertyAddress.mScope = kAudioObjectPropertyScopeGlobal;

    status = AudioObjectGetPropertyData(defaultOutputDevice, &propertyAddress, 0, NULL, &size, &deviceName);

    if (status != noErr || deviceName == NULL) {
        return false;
    }

    NSString *deviceNameString = (__bridge NSString *)deviceName;
    bool isAirPods = [deviceNameString containsString:@"AirPods"];

    if (isAirPods) {
        [self logMessage:@"[AVF] AirPods detected: %@", deviceNameString];
    }

    CFRelease(deviceName);
    return isAirPods;
}

- (double)getSystemSampleRate {
    // Get the current output device's preferred sample rate
    AVAudioFormat *outputFormat = [_audioEngine.outputNode outputFormatForBus:0];
    if (outputFormat != nil) {
        double systemSampleRate = outputFormat.sampleRate;
        [self logMessage:@"[AVF] System output sample rate: %.0f Hz", systemSampleRate];
        return systemSampleRate;
    }

    // Fallback to common sample rates based on hardware capabilities
    // Modern Macs typically prefer 48kHz for digital audio
    [self logMessage:@"[AVF] Using fallback sample rate: 48000 Hz"];
    return 48000.0;
}

- (void)configureForAirPods {
    if ([self isAirPodsConnected]) {
        // Automatically enable spatial audio for AirPods
        [self enableSpatialAudio:true];

        // Set optimal configuration for AirPods spatial audio
        if (@available(macOS 12.0, *)) {
            _environmentNode.outputType = AVAudioEnvironmentOutputTypeHeadphones;
        }

        // Use high-quality spatial rendering
        _environmentNode.renderingAlgorithm = AVAudio3DMixingRenderingAlgorithmSphericalHead;

        [self logMessage:@"[AVF] Configured audio engine for AirPods spatial audio"];
    } else {
        [self logMessage:@"[AVF] AirPods not detected, using standard audio configuration"];
    }
}

@end

// C++ implementation
namespace foo_out_avf
{

    AVFEngine::AVFEngine() {
        // Create the Objective-C implementation object
        impl = (__bridge_retained void *)[[EngineManager alloc] init];
    }

    AVFEngine::~AVFEngine() {
        // Release the Objective-C implementation object
        if (impl) {
            (void)(__bridge_transfer EngineManager *)impl;
            impl = nullptr;
        }
    }

    void AVFEngine::flush() {
        EngineManager *manager = (__bridge EngineManager *)impl;
        [manager flush];
    }

    bool AVFEngine::enable() {
        EngineManager *manager = (__bridge EngineManager *)impl;
        return [manager enable];
    }

    void AVFEngine::disable() {
        EngineManager *manager = (__bridge EngineManager *)impl;
        [manager disable];
    }

    bool AVFEngine::isEnabled() const {
        EngineManager *manager = (__bridge EngineManager *)impl;
        return [manager isEnabled];
    }

    void AVFEngine::setVolume(float volume) {
        EngineManager *manager = (__bridge EngineManager *)impl;
        [manager setVolume:volume];
    }

    float AVFEngine::getVolume() const {
        EngineManager *manager = (__bridge EngineManager *)impl;
        return [manager getVolume];
    }

    void AVFEngine::enableSpatialAudio(bool enable) {
        EngineManager *manager = (__bridge EngineManager *)impl;
        [manager enableSpatialAudio:enable];
    }

    bool AVFEngine::isSpatialAudioEnabled() const {
        EngineManager *manager = (__bridge EngineManager *)impl;
        return [manager isSpatialAudioEnabled];
    }

    void AVFEngine::setListenerPosition(float x, float y, float z) {
        EngineManager *manager = (__bridge EngineManager *)impl;
        [manager setListenerPosition:x y:y z:z];
    }

    void AVFEngine::setSourcePosition(float x, float y, float z) {
        EngineManager *manager = (__bridge EngineManager *)impl;
        [manager setSourcePosition:x y:y z:z];
    }

    bool AVFEngine::isAirPodsConnected() const {
        EngineManager *manager = (__bridge EngineManager *)impl;
        return [manager isAirPodsConnected];
    }

    void AVFEngine::configureForAirPods() {
        EngineManager *manager = (__bridge EngineManager *)impl;
        [manager configureForAirPods];
    }

    double AVFEngine::getSystemSampleRate() const {
        EngineManager *manager = (__bridge EngineManager *)impl;
        return [manager getSystemSampleRate];
    }

    void AVFEngine::feedAudioData(std::vector<const t_float32 *> channelData, double sampleRate, int channels, size_t frameCount) {
        EngineManager *manager = (__bridge EngineManager *)impl;
        [manager feedAudioData:channelData.data() sampleRate:sampleRate channels:channels frameCount:frameCount];
    }

    void AVFEngine::setLogCallback(void (*callback)(const char *message)) {
        EngineManager *manager = (__bridge EngineManager *)impl;
        [manager setLogCallback:callback];
    }

} // namespace foo_out_avf
