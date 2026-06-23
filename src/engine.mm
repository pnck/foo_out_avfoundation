//
//  engine.mm
//  foo_out_avfoundation
//
//  Created by pnck on 2025/8/8.
//
//  Output pipeline model (see README.md "How it works — the output pipeline contract"):
//  foobar2000 is the DEEP buffer; this engine is a SHALLOW sink that keeps only a small
//  playback lead (= foobar's configured buffer length) enqueued in AVSampleBufferAudioRenderer. We honour
//  foobar's partial-consumption contract (take what fits, return the count, foobar keeps the
//  rest) and its priming contract (accumulate the lead with the clock stopped, then start).
//
//  Every method here runs on foobar2000's single playback thread and we take no AVF
//  callbacks, so there is no shared state across threads — no locks, no atomics.
//

#import "engine.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#include <vector>
#include <algorithm>

// Compatibility macros for different macOS versions' 3D audio API
#ifndef AVAudio3DPointMake
#define AVAudio3DPointMake(x, y, z) \
    (AVAudio3DPoint) {              \
        x, y, z                     \
    }
#endif

// Diagnostic logging — the [AVF] feed/underrun/gate/primed traces. Compiled out in Release
// (NDEBUG); operational logs (enable/disable, errors) stay in every build. The log callback
// hands these to the main thread (fb2k::inMainThread), so even calls from the realtime feed
// thread don't block on console I/O. Used only inside instance methods (`self` in scope).
#ifdef NDEBUG
#define AVF_DIAG(...) ((void)0)
#else
#define AVF_DIAG(...) [self logMessage:__VA_ARGS__]
#endif

namespace
{
    // Steady-state lead we keep enqueued in the renderer = foobar2000's configured buffer
    // length (passed to the output ctor as p_buffer_length). Using the full configured buffer
    // is the point: too small a lead and the gaps between foobar's refill calls underrun the
    // renderer → crackle. Until foobar tells us, assume the SDK default (1.0 s).
    constexpr double kDefaultBufferSeconds = 1.0;
    // We don't wait for the whole buffer before starting — bank just this much, start the
    // clock, then keep filling up to the full lead while already playing. Keeps startup snappy
    // without sacrificing the deep steady-state buffer.
    constexpr double kPrimeSeconds = 0.2;
    // Floor on the lead. Must exceed high-latency routes' device latency (AirPods/Bluetooth is
    // ~160 ms) so that, with setDelaysRateChangeUntilHasSufficientMediaData = YES, the renderer
    // can buffer enough for the synchronizer to start the clock reliably on those devices.
    constexpr double kMinBufferSeconds = 0.3;
    // Minimum batch we accept in one go. Without this we top the lead up one or two SAMPLES at
    // a time (foobar polls faster than the renderer drains), enqueueing a flood of ~1-sample
    // CMSampleBuffers that thrash AVFoundation's AudioQueue timeline ("Resyncing AQ timeline" +
    // AudioQueueFlush) no matter how big the buffer is — the real cause of the crackle/stall.
    // Waiting for a whole batch makes every enqueued buffer a sane size.
    constexpr double kMinFeedSeconds = 0.02;
} // namespace

@implementation AVFEngineImpl {

    void (*_logCallback)(const char *);

    AVSampleBufferAudioRenderer *renderer;
    AVSampleBufferRenderSynchronizer *synchronizer;
    AVAudioFormat *currentFormat;

    // PTS accumulator: the end timestamp of everything enqueued so far. The next buffer
    // starts here, then this advances by that buffer's duration. Reset to 0 together with the
    // synchronizer clock at enable() and flush(). The current lead (= our latency) is always
    // _presentationTime - synchronizer.currentTime.
    CMTime _presentationTime;

    // Priming gate: false until we've banked _primeSeconds of lead, at which point the clock
    // starts (setRate:1). Until then the renderer fills silently at rate 0.
    bool _primed;

    // Steady-state lead cap (= foobar's buffer length) and the smaller priming threshold.
    double _targetLeadSeconds;
    double _primeSeconds;

    // Diagnostics (see the [AVF] log lines): feed counter, underrun counter, last feed-gate state.
    uint64_t _diagFeed;
    uint64_t _diagUnderrun;
    bool _diagWasReady;
    bool _loggedRenderError; // one-shot: log the renderer's failure reason at most once per enable

    bool _isPaused;

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

    if (@available(macOS 11.0, *)) {
        renderer = [[AVSampleBufferAudioRenderer alloc] init];
        synchronizer = [[AVSampleBufferRenderSynchronizer alloc] init];
        [synchronizer addRenderer:renderer];

        if (@available(tvOS 14.5, iOS 14.5, macOS 11.3, *)) {
            // YES (the default): hold the clock until the renderer has buffered enough to start
            // reliably, in step with the actual device. With NO, setRate:1 starts our clock
            // immediately; on a slow/high-latency route (AirPods: ~315 ms Bluetooth start,
            // ~160 ms device latency) the clock runs ahead during the device's startup, so when
            // audio finally begins there's a gap and the spatializer/AudioQueue underruns after a
            // chunk. (Built-in starts in ~20 ms, so the gap was harmless there.)
            [synchronizer setDelaysRateChangeUntilHasSufficientMediaData:YES];
        }
    } else {
        renderer = nil;
        synchronizer = nil;
    }

    _presentationTime = kCMTimeZero;
    _primed = false;
    _targetLeadSeconds = kDefaultBufferSeconds;
    _primeSeconds = kPrimeSeconds;
    _diagFeed = 0;
    _diagUnderrun = 0;
    _diagWasReady = false;
    _loggedRenderError = false;
    _isEnabled = false;
    _isPaused = false;
    _logCallback = nullptr;

    return self;
}

- (void)dealloc {
    [self disable];
    if (venv) {
        delete venv;
        venv = nullptr;
    }
}

// --- logging ---------------------------------------------------------------

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

// foobar2000's configured output buffer length (seconds), from the output constructor. We
// keep this much enqueued in the renderer in steady state; the priming threshold is the
// smaller of it and kPrimeSeconds.
- (void)setBufferLength:(double)seconds {
    _targetLeadSeconds = (seconds > kMinBufferSeconds) ? seconds : kMinBufferSeconds;
    // Prime to only HALF the target (capped at kPrimeSeconds). The priming threshold MUST be
    // below the target: if we prime all the way to the target, the instant the clock starts we
    // already report "full", foobar stops feeding, and the renderer drains the whole lead
    // before foobar's next poll — starving it right after start (seen in the macOS log as an
    // immediate underrun + endless resync). Priming below target leaves foobar feeding to top
    // the lead up, so the renderer stays continuously fed.
    _primeSeconds = _targetLeadSeconds * 0.5;
    if (_primeSeconds > kPrimeSeconds) {
        _primeSeconds = kPrimeSeconds;
    }
}

// --- format ----------------------------------------------------------------

- (bool)setupAudioFormat:(uint32_t)sampleRate channels:(uint32_t)channels {
    if (@available(macOS 11.0, *)) {
        if (sampleRate == currentFormat.sampleRate && channels == currentFormat.channelCount) {
            return true;
        }

        AVAudioFormat *audioFormat = nil;
        if (channels == 1 || channels == 2) {
            audioFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                           sampleRate:sampleRate
                                                             channels:channels
                                                          interleaved:YES];
        } else {
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

// --- timeline helper -------------------------------------------------------

// Rewind the synchronizer clock to 0 with the rate at 0, and drop back into the priming
// phase. Used by enable() (fresh start) and flush() (post-seek restart).
- (void)resetTimeline {
    if (@available(macOS 11.0, *)) {
        [synchronizer setRate:0.0 time:kCMTimeZero];
    }
    _presentationTime = kCMTimeZero;
    _primed = false;
}

// Current lead ahead of the play head, in seconds (our queued latency). During priming the
// clock sits at 0, so this is simply the amount banked so far.
- (double)leadSeconds {
    if (@available(macOS 11.0, *)) {
        return CMTimeGetSeconds(_presentationTime) - CMTimeGetSeconds([synchronizer currentTime]);
    }
    return 0.0;
}

// --- enable / disable ------------------------------------------------------

- (bool)enable {
    if (_isEnabled) {
        return true;
    }
    if (renderer == nil || synchronizer == nil) {
        [self logMessage:@"[AVF] Error: Missing required components for audio playback"];
        return false;
    }

    if (@available(macOS 11.0, *)) {
        if (@available(macOS 12.0, *)) {
            renderer.allowedAudioSpatializationFormats = AVAudioSpatializationFormatMonoStereoAndMultichannel;
        }
        renderer.muted = NO;
        // Leave audioOutputDeviceUniqueID at nil: per Apple's docs that means "use the default
        // audio device", i.e. follow whatever the system output is. We never pin a device.

        [self resetTimeline]; // clock at 0, rate 0, priming
        _loggedRenderError = false;
        _isPaused = false;
        _isEnabled = true;
        [self logMessage:@"[AVF] Audio engine enabled (lead %.0f ms, prime %.0f ms)",
                         _targetLeadSeconds * 1000.0, _primeSeconds * 1000.0];
        return true;
    }
    [self logMessage:@"[AVF] Error: AVSampleBufferAudioRenderer not available on this system"];
    return false;
}

- (void)disable {
    if (!_isEnabled) {
        return;
    }
    _isEnabled = false;
    _isPaused = false;

    if (@available(macOS 11.0, *)) {
        if (renderer != nil) {
            [renderer flush];
        }
        if (synchronizer != nil) {
            [synchronizer setRate:0.0];
        }
    }
    _presentationTime = kCMTimeZero;
    _primed = false;
    [self logMessage:@"[AVF] Audio engine disabled"];
}

// --- transport -------------------------------------------------------------

- (void)pause {
    if (!_isEnabled) {
        return;
    }
    _isPaused = true;
    if (@available(macOS 11.0, *)) {
        // Freeze the timeline: enqueued audio stops dead and is kept for resume. (foobar's
        // pause = stop but keep the queue; AVF setRate:0 does exactly that.)
        [synchronizer setRate:0.0];
    }
}

- (void)resume {
    if (!_isEnabled || !_isPaused) {
        return;
    }
    _isPaused = false;
    if (@available(macOS 11.0, *)) {
        // Only run the clock if we'd already primed before pausing; if we were still priming,
        // stay at rate 0 and let feedAudioData finish priming.
        if (_primed) {
            [synchronizer setRate:1.0];
        }
    }
}

- (void)forcePlay {
    // foobar calls this when no more data is coming, so we must start even if we never
    // reached the priming threshold (short track / end of stream): play what we have.
    if (!_isEnabled || _isPaused) {
        return;
    }
    if (@available(macOS 11.0, *)) {
        if (!_primed) {
            _primed = true;
            [synchronizer setRate:1.0];
        }
    }
}

- (void)flush {
    // Seek: discard everything queued in the renderer and re-prime from the new position.
    if (@available(macOS 11.0, *)) {
        if (renderer == nil || synchronizer == nil) {
            return;
        }
        [renderer flush];
        [self resetTimeline]; // rewind clock, back to priming (is_progressing -> false briefly)
    }
}

// --- push side: foobar2000's process_samples_v2 ----------------------------

- (size_t)feedAudioData:(std::vector<float>)audioData
             sampleRate:(uint32_t)sampleRate
               channels:(uint32_t)channels
             frameCount:(size_t)frameCount {
    if (!_isEnabled || _isPaused) {
        return 0;
    }
    if (audioData.empty() || frameCount == 0 || channels == 0) {
        return 0;
    }
    if (![self setupAudioFormat:sampleRate channels:channels]) {
        return 0;
    }

    if (@available(macOS 11.0, *)) {
        // Take only enough frames to top the lead back up to the target — the rest stays in
        // foobar, which re-offers it. This is the partial-consumption contract.
        const size_t freeFrames = [self freeFramesAtRate:sampleRate];
        if (freeFrames == 0) {
            return 0;
        }
        const size_t take = std::min(frameCount, freeFrames);

        const size_t bytesPerFrame = sizeof(float) * channels;
        const size_t dataSize = bytesPerFrame * take;

        void *data = CFAllocatorAllocate(kCFAllocatorDefault, dataSize, 0);
        if (!data) {
            return 0;
        }
        memcpy(data, audioData.data(), dataSize); // first `take` interleaved frames

        CMBlockBufferRef blockBuffer = NULL;
        OSStatus status = CMBlockBufferCreateWithMemoryBlock(
            kCFAllocatorDefault, data, dataSize, kCFAllocatorDefault, NULL, 0, dataSize, 0, &blockBuffer);
        if (status != noErr) {
            CFAllocatorDeallocate(kCFAllocatorDefault, data);
            [self logMessage:@"[AVF] Failed to create block buffer: %d", (int)status];
            return 0;
        }

        // Anchor the PTS to the live clock: never enqueue a buffer whose timestamp is already
        // behind synchronizer.currentTime. If a feeding gap let the renderer drain (underrun),
        // currentTime has run past _presentationTime; without this snap the next buffer lands
        // "in the past" and AVFoundation responds with "Resyncing AQ timeline" + AudioQueueFlush
        // (see the macOS log), which dumps the queue and cascades into the tens-of-ms-then-dead
        // failure. Snapping to currentTime turns an underrun into a single small gap instead.
        // (mpv's end_time_av = max(end_time_av, currentTime).) During priming the clock sits at
        // 0, so this is a no-op and PTS stays contiguous from 0.
        CMTime pts = _presentationTime;
        const CMTime cur = [synchronizer currentTime];
        if (CMTIME_IS_NUMERIC(cur) && CMTimeCompare(cur, pts) > 0) {
            // DIAGNOSTIC: the renderer drained — clock is past our last enqueued PTS. If `cur`
            // keeps advancing past `pres` the synchronizer clock is free-running (good, the
            // snap will catch up); if `cur` is stuck near `pres` the clock stalled during the
            // underrun (then the snap can't catch up and AVFoundation will resync/flush).
            if ((_diagUnderrun++ % 16) == 0) {
                AVF_DIAG(@"[AVF] UNDERRUN #%llu pres=%.0fms cur=%.0fms primed=%d (snapping PTS fwd)",
                         (unsigned long long)_diagUnderrun, CMTimeGetSeconds(_presentationTime) * 1000.0,
                         CMTimeGetSeconds(cur) * 1000.0, _primed ? 1 : 0);
            }
            pts = cur;
        }

        CMSampleTimingInfo timing = {
            .duration = CMTimeMake(1, (int32_t)sampleRate),
            .presentationTimeStamp = pts,
            .decodeTimeStamp = kCMTimeInvalid,
        };
        size_t sampleSize = bytesPerFrame;
        CMSampleBufferRef sampleBuffer = NULL;
        status = CMSampleBufferCreateReady(kCFAllocatorDefault, blockBuffer, currentFormat.formatDescription,
                                           (CMItemCount)take, 1, &timing, 1, &sampleSize, &sampleBuffer);
        CFRelease(blockBuffer);
        if (status != noErr || sampleBuffer == NULL) {
            [self logMessage:@"[AVF] Failed to create sample buffer: %d", (int)status];
            return 0;
        }

        [renderer enqueueSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
        [self logRendererErrorIfFailed]; // did this enqueue/route just push the renderer into failure?

        // Advance from the anchored pts (so after a snap, the accumulator follows the clock).
        _presentationTime = CMTimeAdd(pts, CMTimeMake((int64_t)take, (int32_t)sampleRate));

        // Priming: once the banked lead reaches the (smaller) prime threshold, start the
        // clock. We keep accepting afterwards up to the full _targetLeadSeconds.
        if (!_primed && [self leadSeconds] >= _primeSeconds) {
            _primed = true;
            [synchronizer setRate:1.0];
            AVF_DIAG(@"[AVF] primed: clock started at lead=%.0fms (target=%.0fms)",
                     [self leadSeconds] * 1000.0, _targetLeadSeconds * 1000.0);
        }
        // DIAGNOSTIC: periodic feed sample — shows take size, the live lead, and whether the
        // accumulator is keeping ahead of the clock during steady state.
        if ((_diagFeed++ % 64) == 0) {
            AVF_DIAG(@"[AVF] feed #%llu take=%zu lead=%.0fms primed=%d",
                     (unsigned long long)_diagFeed, take, [self leadSeconds] * 1000.0, _primed ? 1 : 0);
        }
        return take;
    }
    return 0;
}

// Frames we can still take before hitting the target lead, at the given sample rate.
- (size_t)freeFramesAtRate:(uint32_t)sampleRate {
    if (sampleRate == 0) {
        return 0;
    }
    const double freeSec = _targetLeadSeconds - [self leadSeconds];
    // Batch: don't accept until at least kMinFeedSeconds of room has opened, so we never feed
    // 1-sample dribbles (see kMinFeedSeconds). The lead then oscillates between
    // (target - batch) and target, and each feed is a sane chunk.
    if (freeSec < kMinFeedSeconds) {
        return 0;
    }
    return (size_t)(freeSec * (double)sampleRate);
}

// --- backpressure for foobar's update() / update_v2() ----------------------

- (bool)canAcceptMore {
    if (!_isEnabled || _isPaused) {
        return false;
    }
    const bool ready = [self leadSeconds] < _targetLeadSeconds;
    // DIAGNOSTIC: log every gate flip. If we go FULL right after priming and foobar then
    // stalls feeding (a long gap before the next READY), that stall is what starves the
    // renderer — independent of buffer size.
    if (ready != _diagWasReady) {
        _diagWasReady = ready;
        AVF_DIAG(@"[AVF] feed-gate -> %s (lead=%.0fms target=%.0fms)", ready ? "READY" : "FULL",
                 [self leadSeconds] * 1000.0, _targetLeadSeconds * 1000.0);
    }
    return ready;
}

// Surface a renderer failure (e.g. AirPods rejecting our format / spatialization path failing).
// Once the renderer enters the failed state it stops consuming, so playback stalls after a chunk
// while the synchronizer clock keeps running. Logged once per enable so the actual NSError shows.
- (void)logRendererErrorIfFailed {
    if (_loggedRenderError) {
        return;
    }
    if (@available(macOS 11.0, *)) {
        if (renderer.status == AVQueuedSampleBufferRenderingStatusFailed) {
            _loggedRenderError = true;
            [self logMessage:@"[AVF] renderer FAILED — error=%@", renderer.error ?: @"(nil)"];
        }
    }
}

- (size_t)freeSampleCount {
    if (!_isEnabled || _isPaused) {
        return 0;
    }
    [self logRendererErrorIfFailed]; // catch failures even when feeding has stalled (foobar polls this)
    if (currentFormat == nil) {
        return SIZE_MAX; // can take, but no hint on how much until we know the format
    }
    return [self freeFramesAtRate:(uint32_t)currentFormat.sampleRate];
}

// --- volume ----------------------------------------------------------------

- (void)setVolume:(float)volume {
    if (renderer != nil) {
        if (@available(macOS 11.0, *)) {
            renderer.volume = volume; // pass-through, no curve conversion
        }
    }
}

- (float)getVolume {
    if (!renderer) {
        return 0.0f;
    }
    return renderer.volume;
}

// --- latency / status ------------------------------------------------------

- (double)getCurrentLatency {
    if (!_isEnabled || !currentFormat) {
        return 0.0;
    }
    const double lead = [self leadSeconds];
    return (lead > 0.0 && lead == lead) ? lead : 0.0;
}

- (bool)isProgressing {
    // Playing iff primed and not paused (the clock is running). Maps to is_progressing();
    // false during priming is expected and must not be read as a stall.
    return _isEnabled && _primed && !_isPaused;
}

// --- spatial (currently informational; not wired to a positional renderer) -

- (void)setListenerPosition:(float)x y:(float)y z:(float)z {
    if (venv) {
        venv->listenerPosition = AVAudio3DPointMake(x, y, z);
    }
}

- (void)setListenerOrientation:(float)yaw pitch:(float)pitch roll:(float)roll {
    if (venv) {
        venv->listenerOrientation = AVAudio3DAngularOrientation{yaw, pitch, roll};
    }
}

- (void)setSourcePosition:(float)x y:(float)y z:(float)z {
    if (venv) {
        venv->sourcePosition = AVAudio3DPointMake(x, y, z);
    }
}

@end

// ===========================================================================
// C++ facade
// ===========================================================================

namespace foo_out_avf
{

    AVFEngine::AVFEngine() {
        impl_ = (__bridge_retained void *)[[AVFEngineImpl alloc] init];
    }

    AVFEngine::~AVFEngine() {
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

    void AVFEngine::forcePlay() {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        [impl forcePlay];
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

    bool AVFEngine::isProgressing() const {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        return [impl isProgressing];
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

    bool AVFEngine::canAcceptMore() const {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        return [impl canAcceptMore];
    }

    size_t AVFEngine::freeSampleCount() const {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        return [impl freeSampleCount];
    }

    size_t AVFEngine::feedAudioData(std::vector<float> audioData, uint32_t sampleRate, uint32_t channels, size_t sample_count) {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        return [impl feedAudioData:std::move(audioData) sampleRate:sampleRate channels:channels frameCount:sample_count];
    }

    void AVFEngine::setLogCallback(void (*callback)(const char *message)) {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        [impl setLogCallback:callback];
    }

    void AVFEngine::setBufferLength(double seconds) {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        [impl setBufferLength:seconds];
    }

    bool AVFEngine::setupAudioFormat(double sampleRate, int channels) {
        AVFEngineImpl *impl = (__bridge AVFEngineImpl *)impl_;
        return [impl setupAudioFormat:sampleRate channels:channels];
    }

} // namespace foo_out_avf
