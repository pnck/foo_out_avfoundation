//
//  engine_virtual_3d.mm
//  foo_out_avfoundation
//
//  V3D positional backend (SKELETON). AVAudioEngine + AVAudioPlayerNode + AVAudioEnvironmentNode,
//  rendering in-process with HRTFHQ so the source can be placed at a custom point in a virtual
//  field. This is the path the system spatializer cannot offer (verified: renderingAlgorithm
//  .auto does not route to the system spatializer — see the project memory / tracking notes).
//
//  STATUS: scaffold. The audio graph, spatial setters and lifecycle are wired; the feed path
//  currently schedules AVAudioPCMBuffers on the player node (the proven d5d00ab approach). TODO:
//  switch the feed to an AVAudioSourceNode pull callback honouring foobar's partial-consumption
//  contract (the same shallow-sink model engine_sys_spatialized.mm already implements), so the V3D
//  backend never owns a deep queue or blocks the playback thread.
//

#import "engine_virtual_3d.h"
#import <AVFoundation/AVFoundation.h>
#import <AVFAudio/AVFAudio.h>

#ifndef AVAudio3DPointMake
#define AVAudio3DPointMake(x, y, z) \
    (AVAudio3DPoint) {              \
        x, y, z                     \
    }
#endif

#ifdef NDEBUG
#define V3D_DIAG(...) ((void)0)
#else
#define V3D_DIAG(...) [self logMessage:__VA_ARGS__]
#endif

@implementation AVFVirtual3DBackend {
    void (*_logCallback)(const char *);

    AVAudioEngine *_engine;
    AVAudioPlayerNode *_player;
    AVAudioEnvironmentNode *_env;
    AVAudioFormat *_currentFormat;

    double _bufferLength; // foobar's configured buffer length (seconds); honoured by the feed path

    // Spatial state — stored so it survives format-driven reconnects, and applied to the live nodes.
    AVAudio3DPoint _listenerPosition;
    AVAudio3DAngularOrientation _listenerOrientation;
    AVAudio3DPoint _sourcePosition;
    // _isEnabled / _isPaused are synthesized from the readonly properties (see engine_virtual_3d.h).
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    _logCallback = nullptr;
    _bufferLength = 0.0;
    _isEnabled = false;
    _isPaused = false;

    _listenerPosition = AVAudio3DPointMake(0, 0, 0);
    _listenerOrientation = (AVAudio3DAngularOrientation){0, 0, 0};
    _sourcePosition = AVAudio3DPointMake(0, 0, -2); // 2 m in front by default

    _engine = [[AVAudioEngine alloc] init];
    _player = [[AVAudioPlayerNode alloc] init];
    _env = [[AVAudioEnvironmentNode alloc] init];
    [_engine attachNode:_player];
    [_engine attachNode:_env];

    // In-process HRTFHQ point-source rendering. The old low-grid HRTF is intentionally not used.
    if (@available(macOS 11.0, *)) {
        _player.renderingAlgorithm = AVAudio3DMixingRenderingAlgorithmHRTFHQ;
        _player.position = _sourcePosition;
    }
    if (@available(macOS 12.0, *)) {
        _player.sourceMode = AVAudio3DMixingSourceModePointSource;
        _env.outputType = AVAudioEnvironmentOutputTypeHeadphones;
    }
    _env.listenerPosition = _listenerPosition;
    _env.listenerAngularOrientation = _listenerOrientation;

    return self;
}

- (void)dealloc {
    [self disable];
}

// --- logging (mirrors engine_sys_spatialized.mm: Debug-only backend for V3D_DIAG) ---------------

- (void)logMessage:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (_logCallback != nullptr) {
        _logCallback([message UTF8String]);
    } else {
        NSLog(@"%@", message);
    }
}

- (void)setLogCallback:(void (*)(const char *))callback {
    _logCallback = callback;
}

- (void)setBufferLength:(double)seconds {
    _bufferLength = (seconds > 0.0) ? seconds : 0.0;
}

// --- format ----------------------------------------------------------------

- (bool)setupAudioFormat:(uint32_t)sampleRate channels:(uint32_t)channels {
    if (sampleRate == (uint32_t)_currentFormat.sampleRate && channels == _currentFormat.channelCount) {
        return true;
    }
    // Interleaved float32 — the converter callback writes interleaved frames.
    AVAudioFormat *fmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                         sampleRate:sampleRate
                                                           channels:channels
                                                        interleaved:YES];
    if (!fmt) {
        V3D_DIAG(@"[V3D] Failed to create AVAudioFormat (%u Hz, %u ch)", sampleRate, channels);
        return false;
    }
    _currentFormat = fmt;
    // (Re)wire player -> environment -> mainMixer at the new format.
    [_engine connect:_player to:_env format:fmt];
    [_engine connect:_env to:_engine.mainMixerNode format:nil];
    return true;
}

// --- enable / disable ------------------------------------------------------

- (bool)enable {
    if (_isEnabled) {
        return true;
    }
    NSError *err = nil;
    if (![_engine startAndReturnError:&err]) {
        V3D_DIAG(@"[V3D] engine start failed: %@", err ?: @"(nil)");
        return false;
    }
    [_player play];
    _isEnabled = true;
    _isPaused = false;
    V3D_DIAG(@"[V3D] enabled (HRTFHQ, source=%.1f,%.1f,%.1f)", _sourcePosition.x, _sourcePosition.y,
             _sourcePosition.z);
    return true;
}

- (void)disable {
    if (!_isEnabled) {
        return;
    }
    _isEnabled = false;
    _isPaused = false;
    [_player stop];
    [_engine stop];
}

// --- transport -------------------------------------------------------------

- (void)pause {
    if (!_isEnabled) {
        return;
    }
    _isPaused = true;
    [_player pause];
}

- (void)resume {
    if (!_isEnabled || !_isPaused) {
        return;
    }
    _isPaused = false;
    [_player play];
}

- (void)forcePlay {
    if (!_isEnabled || _isPaused) {
        return;
    }
    if (!_player.isPlaying) {
        [_player play];
    }
}

- (void)flush {
    if (!_isEnabled) {
        return;
    }
    [_player stop];
    [_player play];
}

// --- push side -------------------------------------------------------------

- (size_t)feedAudioData:(uint32_t)sampleRate
               channels:(uint32_t)channels
             frameCount:(size_t)frameCount
              converter:(const std::function<void(float *, size_t)> &)convert {
    if (!_isEnabled || _isPaused || frameCount == 0 || channels == 0) {
        return 0;
    }
    if (![self setupAudioFormat:sampleRate channels:channels]) {
        return 0;
    }
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_currentFormat
                                                            frameCapacity:(AVAudioFrameCount)frameCount];
    if (!buffer) {
        return 0;
    }
    buffer.frameLength = (AVAudioFrameCount)frameCount;
    // Interleaved float32 -> a single packed buffer; write the converted frames straight in.
    float *dst = (float *)buffer.mutableAudioBufferList->mBuffers[0].mData;
    convert(dst, frameCount);

    // TODO(shallow-sink): replace scheduleBuffer with an AVAudioSourceNode pull callback so we
    // honour partial consumption instead of owning the player's deep queue.
    [_player scheduleBuffer:buffer completionHandler:nil];
    return frameCount; // skeleton: accept everything offered
}

- (bool)canAcceptMore {
    // Skeleton: always ready while playing. The pull-based rewrite will gate this on a target lead.
    return _isEnabled && !_isPaused;
}

- (size_t)freeSampleCount {
    return (_isEnabled && !_isPaused) ? SIZE_MAX : 0;
}

// --- volume ----------------------------------------------------------------

- (void)setVolume:(float)volume {
    _engine.mainMixerNode.outputVolume = volume;
}

- (float)getVolume {
    return _engine.mainMixerNode.outputVolume;
}

// --- spatial (wired straight into the HRTFHQ renderer) ---------------------

- (void)setListenerPosition:(float)x y:(float)y z:(float)z {
    _listenerPosition = AVAudio3DPointMake(x, y, z);
    _env.listenerPosition = _listenerPosition;
}

- (void)setListenerOrientation:(float)yaw pitch:(float)pitch roll:(float)roll {
    _listenerOrientation = (AVAudio3DAngularOrientation){yaw, pitch, roll};
    _env.listenerAngularOrientation = _listenerOrientation;
}

- (void)setSourcePosition:(float)x y:(float)y z:(float)z {
    _sourcePosition = AVAudio3DPointMake(x, y, z);
    _player.position = _sourcePosition;
}

// --- latency / status ------------------------------------------------------

- (double)getCurrentLatency {
    // TODO: report the real queued lead once the pull-based feed lands. Skeleton: 0.
    return 0.0;
}

- (bool)isProgressing {
    return _isEnabled && !_isPaused && _player.isPlaying;
}

@end
