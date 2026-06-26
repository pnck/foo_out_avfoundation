//
//  engine_sys_spatialized.mm
//  foo_out_avfoundation
//
//  Created by pnck on 2025/8/8.
//
//  The DEFAULT output backend: AVSampleBufferAudioRenderer + AVSampleBufferRenderSynchronizer,
//  the path that hands audio to macOS's system Spatial Audio (Control Center, head tracking).
//  The C++ facade (engine.mm) selects this vs the V3D backend through the AVFOutputBackend protocol.
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
#import <CoreAudio/CoreAudio.h>
#include "common/lead.h" // shared fsec / lead floors / currentOutputFloor — DO NOT copy-paste
#include <vector>
#include <algorithm>
#include <functional>
#include <atomic>
#include <chrono>

// THE single logging path for everything [AVF] — traces, enable/disable, errors alike. Expands to
// a -logMessage call in Debug and to nothing in Release (NDEBUG), so the component is completely
// silent in Release and the arguments aren't even evaluated (matters on the realtime feed thread).
// Used inside instance methods (`self` in scope).
#ifdef NDEBUG
#define AVF_DIAG(...) ((void)0)
#else
#define AVF_DIAG(...) [self logMessage:__VA_ARGS__]
#endif

// The output-lead policy (fsec, the floors, currentOutputFloor, the device-change address) is shared
// with engine_virtual_3d.mm via common/lead.h — bring its names into scope so the call sites
// stay unqualified (fsec, kPrime, currentOutputFloor, kDefaultOutputDeviceAddr, …).
using namespace foo_out_avf::lead;

// Forward-declare the private methods used before their definitions (the C listener, and the fsec
// helpers called from feed/gate above their @implementation point).
@interface AVFSysSpatializedBackend ()
- (void)updateDeviceFloor;
- (fsec)lead;
- (fsec)targetLead;
- (fsec)primeLead;
@end

// CoreAudio listener for "default output device changed" — runs on a HAL thread. Re-queries the
// new device's transport type and updates the (atomic) lead floor. clientData is the engine
// (unretained; removed in dealloc before it dies).
static OSStatus avf_default_output_changed(AudioObjectID inObjectID, UInt32 inNumberAddresses,
                                           const AudioObjectPropertyAddress *inAddresses, void *clientData) {
    (void)inObjectID;
    (void)inNumberAddresses;
    (void)inAddresses;
    @autoreleasepool {
        [(__bridge AVFSysSpatializedBackend *)clientData updateDeviceFloor];
    }
    return noErr;
}

@implementation AVFSysSpatializedBackend {

    void (*_logCallback)(const char *);

    AVSampleBufferAudioRenderer *renderer;
    AVSampleBufferRenderSynchronizer *synchronizer;
    AVAudioFormat *currentFormat;

    // PTS accumulator: the end timestamp of everything enqueued so far. The next buffer
    // starts here, then this advances by that buffer's duration. Reset to 0 together with the
    // synchronizer clock at enable() and flush(). The current lead (= our latency) is always
    // _presentationTime - synchronizer.currentTime.
    CMTime _presentationTime;

    // Priming gate: false until we've banked the prime threshold of lead, at which point the
    // clock starts (setRate:1). Until then the renderer fills silently at rate 0.
    bool _primed;

    // Steady-state target lead = max(foobar's configured buffer length, device floor). The floor
    // depends on the current output device's transport type and is updated from a CoreAudio
    // listener (any thread), so it's atomic; _configured is set once on the playback thread.
    // See targetLead / primeLead.
    fsec _configured;
    std::atomic<fsec> _deviceFloor;

    // Diagnostics (see the [AVF] log lines): feed counter, underrun counter, last feed-gate state.
    uint64_t _diagFeed;
    uint64_t _diagUnderrun;
    bool _diagWasReady;
    bool _loggedRenderError; // one-shot: log the renderer's failure reason at most once per enable

    bool _isPaused;
    bool _formatUnsupported; // stream's channel count has no usable AVAudioFormat — stop feeding
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

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
    _configured = fsec(0); // set from fb2k's p_buffer_length in setBufferLength, before enable
    _deviceFloor.store(currentOutputFloor());
    // Track the system default output device so the floor follows speakers ↔ AirPods switches.
    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &kDefaultOutputDeviceAddr,
                                   avf_default_output_changed, (__bridge void *)self);
    _diagFeed = 0;
    _diagUnderrun = 0;
    _diagWasReady = false;
    _loggedRenderError = false;
    _formatUnsupported = false;
    _isEnabled = false;
    _isPaused = false;
    _logCallback = nullptr;

    return self;
}

- (void)dealloc {
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &kDefaultOutputDeviceAddr,
                                      avf_default_output_changed, (__bridge void *)self);
    [self disable];
}

// --- logging ---------------------------------------------------------------

// Debug-only backend for AVF_DIAG (never called in Release — every call site is the macro, which
// compiles to nothing under NDEBUG). Hands the line to the main thread so feed-thread logging
// doesn't block on console I/O.
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

// foobar2000's user-configured output buffer length (a double in seconds from the SDK — converted
// to fsec here, at the boundary). This is the actual configured value, not an assumed default; the
// steady-state target is max(this, device floor), so a non-positive value simply lets the device
// floor decide the minimum. See targetLead.
- (void)setBufferLength:(double)seconds {
    _configured = (seconds > 0.0) ? fsec(seconds) : fsec(0);
}

// Steady-state lead target = the larger of foobar's configured buffer and the current device's
// transport floor (built-in 200 ms / wireless 500 ms).
- (fsec)targetLead {
    return std::max(_configured, _deviceFloor.load());
}

// Priming threshold: half the target, capped at kPrime. MUST be below the target — if we primed
// all the way to it, the instant the clock starts we'd report "full", foobar would stop feeding,
// and the renderer would drain the whole lead before foobar's next poll (immediate underrun +
// endless resync). Priming below target keeps foobar topping the lead up.
- (fsec)primeLead {
    return std::min([self targetLead] / 2.0, kPrime);
}

// Refresh the lead floor from the current default output device's transport type. Called from the
// CoreAudio listener (HAL thread) on device changes. Atomic store only.
- (void)updateDeviceFloor {
    const fsec floor = currentOutputFloor();
    _deviceFloor.store(floor);
    AVF_DIAG(@"[AVF] output device floor -> %.0f ms (target now %.0f ms)", ms(floor), ms([self targetLead]));
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
            // >2 channels REQUIRE a channel layout, or AVAudioFormat returns nil. Left unhandled, setup
            // then failed on every call and foobar busy-looped process_samples (100% CPU — the "5.1
            // drags the whole player down" bug). Build the layout from foobar's OWN channel mask rather
            // than guessing a CoreAudio tag: foobar's channel bits are the WAVEFORMATEXTENSIBLE order,
            // which is exactly CoreAudio's AudioChannelBitmap, so channels can't be mis-mapped for any
            // count (5.1, 6.1, 7.1, …) — and the canonical (ascending-bit) order matches the interleave.
            AudioChannelLayout acl = {0};
            acl.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap;
            acl.mChannelBitmap = (AudioChannelBitmap)audio_chunk::g_guess_channel_config(channels);
            AVAudioChannelLayout *layout = [[AVAudioChannelLayout alloc] initWithLayout:&acl];
            audioFormat = layout ? [[AVAudioFormat alloc] initWithStreamDescription:&asbd channelLayout:layout]
                                 : [[AVAudioFormat alloc] initWithStreamDescription:&asbd];
        }

        if (!audioFormat) {
            // Don't fail-loop: flag the stream unsupported so the backpressure methods tell foobar to
            // stop offering (otherwise it re-calls process_samples forever at 100% CPU).
            AVF_DIAG(@"[AVF] Unsupported format (%u ch @ %u Hz) — no channel layout", channels, sampleRate);
            _formatUnsupported = true;
            return false;
        }
        _formatUnsupported = false;
        currentFormat = audioFormat;
        return true;
    }
    AVF_DIAG(@"[AVF] Error: AVSampleBufferAudioRenderer not available on this system");
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

// Current lead ahead of the play head (our queued latency). During priming the clock sits at 0,
// so this is simply the amount banked so far. CMTime is AVFoundation's native time type; we
// convert it to fsec here, at the boundary.
- (fsec)lead {
    if (@available(macOS 11.0, *)) {
        return fsec(CMTimeGetSeconds(_presentationTime) - CMTimeGetSeconds([synchronizer currentTime]));
    }
    return fsec(0);
}

// --- enable / disable ------------------------------------------------------

- (bool)enable {
    if (_isEnabled) {
        return true;
    }
    if (renderer == nil || synchronizer == nil) {
        AVF_DIAG(@"[AVF] Error: Missing required components for audio playback");
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
        AVF_DIAG(@"[AVF] Audio engine enabled (lead %.0f ms, prime %.0f ms)",
                 ms([self targetLead]), ms([self primeLead]));
        return true;
    }
    AVF_DIAG(@"[AVF] Error: AVSampleBufferAudioRenderer not available on this system");
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
    AVF_DIAG(@"[AVF] Audio engine disabled");
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

- (size_t)feedAudioData:(uint32_t)sampleRate
               channels:(uint32_t)channels
             frameCount:(size_t)frameCount
              converter:(const std::function<void(float *, size_t)> &)convert {
    if (!_isEnabled || _isPaused) {
        return 0;
    }
    if (frameCount == 0 || channels == 0) {
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
        // SINGLE COPY: convert foobar's f64 chunk straight into the CMBlockBuffer block, only the
        // `take` frames we keep — no intermediate std::vector + memcpy.
        convert(reinterpret_cast<float *>(data), take);

        CMBlockBufferRef blockBuffer = NULL;
        OSStatus status = CMBlockBufferCreateWithMemoryBlock(
            kCFAllocatorDefault, data, dataSize, kCFAllocatorDefault, NULL, 0, dataSize, 0, &blockBuffer);
        if (status != noErr) {
            CFAllocatorDeallocate(kCFAllocatorDefault, data);
            AVF_DIAG(@"[AVF] Failed to create block buffer: %d", (int)status);
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
                         (unsigned long long)_diagUnderrun, ms(fsec(CMTimeGetSeconds(_presentationTime))),
                         ms(fsec(CMTimeGetSeconds(cur))), _primed ? 1 : 0);
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
            AVF_DIAG(@"[AVF] Failed to create sample buffer: %d", (int)status);
            return 0;
        }

        [renderer enqueueSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
        [self logRendererErrorIfFailed]; // did this enqueue/route just push the renderer into failure?

        // Advance from the anchored pts (so after a snap, the accumulator follows the clock).
        _presentationTime = CMTimeAdd(pts, CMTimeMake((int64_t)take, (int32_t)sampleRate));

        // Priming: once the banked lead reaches the (smaller) prime threshold, start the
        // clock. We keep accepting afterwards up to the full target lead.
        if (!_primed && [self lead] >= [self primeLead]) {
            _primed = true;
            [synchronizer setRate:1.0];
            AVF_DIAG(@"[AVF] primed: clock started at lead=%.0fms (target=%.0fms)",
                     ms([self lead]), ms([self targetLead]));
        }
        // DIAGNOSTIC: periodic feed sample — shows take size, the live lead, and whether the
        // accumulator is keeping ahead of the clock during steady state.
        if ((_diagFeed++ % 64) == 0) {
            AVF_DIAG(@"[AVF] feed #%llu take=%zu lead=%.0fms primed=%d",
                     (unsigned long long)_diagFeed, take, ms([self lead]), _primed ? 1 : 0);
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
    const fsec freeRoom = [self targetLead] - [self lead];
    // Batch: don't accept until at least kMinFeed of room has opened, so we never feed 1-sample
    // dribbles (see kMinFeed). The lead then oscillates between (target - batch) and target, and
    // each feed is a sane chunk.
    if (freeRoom < kMinFeed) {
        return 0;
    }
    return (size_t)(freeRoom.count() * (double)sampleRate); // fsec → frames, at the boundary
}

// --- backpressure for foobar's update() / update_v2() ----------------------

- (bool)canAcceptMore {
    if (!_isEnabled || _isPaused) {
        return false;
    }
    if (_formatUnsupported) {
        return false; // unsupported stream — don't invite more feeding (no busy loop)
    }
    const bool ready = [self lead] < [self targetLead];
    // DIAGNOSTIC: log every gate flip. If we go FULL right after priming and foobar then
    // stalls feeding (a long gap before the next READY), that stall is what starves the
    // renderer — independent of buffer size.
    if (ready != _diagWasReady) {
        _diagWasReady = ready;
        AVF_DIAG(@"[AVF] feed-gate -> %s (lead=%.0fms target=%.0fms)", ready ? "READY" : "FULL",
                 ms([self lead]), ms([self targetLead]));
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
            AVF_DIAG(@"[AVF] renderer FAILED — error=%@", renderer.error ?: @"(nil)");
        }
    }
}

- (size_t)freeSampleCount {
    if (!_isEnabled || _isPaused) {
        return 0;
    }
    [self logRendererErrorIfFailed]; // catch failures even when feeding has stalled (foobar polls this)
    if (_formatUnsupported) {
        return 0; // unsupported stream — make foobar stop re-offering (otherwise 100% CPU busy loop)
    }
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
    const double secs = [self lead].count(); // fsec → double seconds, foobar's get_latency() unit
    return (secs > 0.0 && secs == secs) ? secs : 0.0;
}

- (bool)isProgressing {
    // Playing iff primed and not paused (the clock is running). Maps to is_progressing();
    // false during priming is expected and must not be read as a stall.
    return _isEnabled && _primed && !_isPaused;
}

// --- spatial ---------------------------------------------------------------
// The system spatializer owns placement, so these positional setters are no-ops here (the V3D
// backend is the one that wires them into HRTFHQ). Kept only to satisfy the AVFOutputBackend protocol.

- (void)setListenerPosition:(float)x y:(float)y z:(float)z {
    (void)x;
    (void)y;
    (void)z;
}

- (void)setListenerOrientation:(float)yaw pitch:(float)pitch roll:(float)roll {
    (void)yaw;
    (void)pitch;
    (void)roll;
}

- (void)setSourcePosition:(float)x y:(float)y z:(float)z {
    (void)x;
    (void)y;
    (void)z;
}

@end
