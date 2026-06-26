//
//  engine_virtual_3d.mm
//  foo_out_avfoundation
//
//  V3D positional backend — a VIRTUAL SPEAKER RIG over headphones, the way real headphone-surround
//  products (Apple "Spatialize Stereo", Dolby Atmos for headphones, Waves Nx, …) work. Each content
//  channel is deinterleaved into its own mono AVAudioSourceNode, positioned at a virtual loudspeaker,
//  and all of them feed one AVAudioEnvironmentNode rendering with HRTFHQ. The listener sits at the
//  origin; the user arranges the speakers. This PRESERVES and spatializes the stereo/multichannel
//  image — it is NOT a mono point source (collapsing the mix to one point would make the feature a toy).
//
//  Speaker placement is a DAW-style abstraction, not raw XYZ: a FRONT pair and a REAR pair, each with
//  {distance, spacing (the angle between the two), center azimuth, center elevation}, plus a freely
//  positioned mono CENTER and LFE. The engine converts that (spherical → cartesian) to each bus's
//  `position`; AVAudioEnvironmentNode only knows XYZ point sources, so that abstraction lives here.
//  Channel → speaker mapping is by content channel count (stereo → front pair; 5.1 → front pair +
//  center + LFE + rear pair).
//
//  FEED MODEL — a PULL graph, unlike the default backend's push into AVSampleBufferAudioRenderer.
//  Each AVAudioSourceNode pulls audio from a real-time render thread; foobar2000 pushes from its
//  playback thread. They meet at one single-producer/single-consumer lock-free ring PER channel
//  (V3DChannelRing), all fed in lockstep. We keep the SAME shallow-sink contract as
//  engine_sys_spatialized.mm — take only enough to top a target lead (partial consumption), prime a
//  small lead before draining, batch (kMinFeed) so we never dribble, floor the lead by the output
//  device's transport type — but here the "queue" is our rings and "start the clock" is the shared
//  `primed` flag.
//
//  CONCURRENCY: the GRAPH topology and the rings are reconfigured only with the engine stopped (which
//  quiesces the render thread), so ring buffers are a plain SPSC hand-off (atomics, no locks). The one
//  exception is LIVE parameter updates: applyLayout sets each source's AVAudioMixing position/volume
//  from the feed thread WHILE the engine runs (the preferences "drag to hear it move" path). Those
//  setters are Apple's supported way to adjust a running mixer, so this is safe — but note it is a real
//  feed-thread ⇄ render-thread interaction, not the "nothing concurrent but the rings" the rings alone
//  would suggest. (Positions are not published as one atomic snapshot, so a single render quantum may
//  observe a half-updated rig during a drag; inaudible for smooth edits.)
//

#import "engine_virtual_3d.h"
#import "v3d_config.h"
#import <AVFoundation/AVFoundation.h>
#import <AVFAudio/AVFAudio.h>
#import <CoreAudio/CoreAudio.h>
#include <vector>
#include <atomic>
#include <algorithm>
#include <functional>
#include <chrono>
#include <cmath>
#include <cstring>

#include "common/lead.h" // shared fsec / lead floors / currentOutputFloor — DO NOT copy-paste

// This TU is not inside namespace foo_out_avf (the @implementation is ObjC), so alias the config
// namespace to keep the v3d_config:: call sites short, and bring the shared lead-policy names
// (fsec, kPrime, currentOutputFloor, kDefaultOutputDeviceAddr, …) into scope unqualified.
namespace v3d_config = foo_out_avf::v3d_config;
using namespace foo_out_avf::lead;

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

namespace
{
    // The lead policy (fsec, ms, the floors, kDefaultOutputDeviceAddr, currentOutputFloor) is shared
    // with engine_sys_spatialized.mm via common/lead.h (in scope through the using-directive
    // above) — NOT copy-pasted. Only V3D-specific helpers live here.

    static size_t nextPow2(size_t n) {
        size_t p = 1;
        while (p < n) {
            p <<= 1;
        }
        return p;
    }

    // The virtual speaker geometry (pair distance/spacing/azimuth/elevation → XYZ) lives in v3d_config
    // so the engine and the UI preview share one source of truth. Here we only convert and map content
    // channels onto the six computed positions.
    static AVAudio3DPoint pointFromVec(const v3d_config::Vec3 &v) {
        return AVAudio3DPointMake((float)v.x, (float)v.y, (float)v.z);
    }

    // Which virtual speaker a given content channel index drives, by total channel count. Standard
    // interleave orders: 2.0 = FL FR; 5.0 = FL FR FC BL BR; 5.1 = FL FR FC LFE BL BR. Unusual / >6
    // counts fall back to the 5.1 order with extra channels folded onto the rear pair.
    static AVAudio3DPoint speakerForChannel(const v3d_config::SpeakerPositions &s, uint32_t count, uint32_t idx) {
        switch (count) {
        case 1:
            return pointFromVec(s.c); // mono → centre
        case 2:
            return pointFromVec((idx == 0) ? s.fl : s.fr);
        case 3:
            return pointFromVec((idx == 0) ? s.fl : (idx == 1) ? s.fr : s.c);
        case 4:
            switch (idx) {
            case 0: return pointFromVec(s.fl);
            case 1: return pointFromVec(s.fr);
            case 2: return pointFromVec(s.rl);
            default: return pointFromVec(s.rr);
            }
        case 5:
            switch (idx) {
            case 0: return pointFromVec(s.fl);
            case 1: return pointFromVec(s.fr);
            case 2: return pointFromVec(s.c);
            case 3: return pointFromVec(s.rl);
            default: return pointFromVec(s.rr);
            }
        default: // 6 (5.1) and anything larger
            switch (idx) {
            case 0: return pointFromVec(s.fl);
            case 1: return pointFromVec(s.fr);
            case 2: return pointFromVec(s.c);
            case 3: return pointFromVec(s.lfe);
            case 4: return pointFromVec(s.rl);
            case 5: return pointFromVec(s.rr);
            default: return pointFromVec((idx % 2) ? s.rr : s.rl);
            }
        }
    }

    // The per-group gain (dB) for a given channel, mirroring speakerForChannel's channel→speaker map.
    static double gainDbForChannel(const v3d_config::Layout &L, uint32_t count, uint32_t idx) {
        switch (count) {
        case 1:
            return L.centerGainDb;
        case 2:
            return L.frontGainDb;
        case 3:
            return (idx < 2) ? L.frontGainDb : L.centerGainDb;
        case 4:
            return (idx < 2) ? L.frontGainDb : L.rearGainDb;
        case 5:
            return (idx < 2) ? L.frontGainDb : (idx == 2 ? L.centerGainDb : L.rearGainDb);
        default: // 6 (5.1) and larger: FL FR C LFE RL RR …
            switch (idx) {
            case 0:
            case 1: return L.frontGainDb;
            case 2: return L.centerGainDb;
            case 3: return L.lfeGainDb;
            default: return L.rearGainDb;
            }
        }
    }

    // --- lock-free hand-off between foobar's feed thread and the render thread ------------------
    // One ring per content channel (mono float32). `write`/`read` are free-running sample counters
    // (never wrap in any realistic runtime), indexed into `buf` via `& mask`. Reconfigured only while
    // the engine is stopped, so buf/capacity/mask are stable whenever the render block runs.
    struct V3DChannelRing {
        std::vector<float> buf;
        size_t capacity = 0; // power of two, in samples (== mono frames)
        size_t mask = 0;
        std::atomic<size_t> write{0};
        std::atomic<size_t> read{0};
        std::atomic<uint64_t> underruns{0};

        size_t buffered() const {
            return write.load(std::memory_order_acquire) - read.load(std::memory_order_relaxed);
        }
    };

    // Shared across all channel render blocks (one instance). primed/paused gate draining identically
    // for every channel so the rig stays phase-aligned.
    struct V3DShared {
        std::atomic<bool> primed{false}; // false until the prime lead is banked → render outputs silence
        std::atomic<bool> paused{false}; // pause freezes the queues: render outputs silence, no drain
        uint32_t sampleRate = 0;
    };
} // namespace

@interface AVFVirtual3DBackend ()
- (void)updateDeviceFloor;
@end

static OSStatus v3d_default_output_changed(AudioObjectID inObjectID, UInt32 inNumberAddresses,
                                           const AudioObjectPropertyAddress *inAddresses, void *clientData) {
    (void)inObjectID;
    (void)inNumberAddresses;
    (void)inAddresses;
    @autoreleasepool {
        [(__bridge AVFVirtual3DBackend *)clientData updateDeviceFloor];
    }
    return noErr;
}

@implementation AVFVirtual3DBackend {
    void (*_logCallback)(const char *);

    AVAudioEngine *_engine;
    AVAudioEnvironmentNode *_env;
    NSMutableArray<AVAudioSourceNode *> *_sources; // one per content channel (strong owner under ARC)
    AVAudioFormat *_monoFormat;                    // mono float32 at the current sample rate (every source)

    std::vector<V3DChannelRing *> _rings; // one per channel; render blocks capture raw pointers
    V3DShared *_shared;                   // heap-owned; render blocks capture a raw pointer (no self)

    unsigned long long _seenLayoutGen; // last v3d_config layout generation we applied (live pick-up gate)
    uint32_t _channelCount;            // number of content channels = number of sources/rings
    bool _engineFailed;                // AVAudioEngine wouldn't start/build — stop feeding, surface it

    fsec _configured;
    std::atomic<fsec> _deviceFloor;
    std::vector<float> _feedStaging; // producer-only scratch for the interleaved input chunk
    std::vector<float> _channelGain; // per-source linear gain, applied in the feed (not via mix.volume,
                                     // which clamps near unity; written by applyLayout, read by the feed —
                                     // both on the playback thread)

    uint64_t _diagFeed;

    // Listener state (the user "places themselves" / head tracking). Source positions come from the
    // speaker layout, not from a single source position.
    AVAudio3DPoint _listenerPosition;
    AVAudio3DAngularOrientation _listenerOrientation;
    // _isEnabled / _isPaused are synthesized from the readonly properties (see engine_virtual_3d.h).
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    _logCallback = nullptr;
    _configured = fsec(0);
    _deviceFloor.store(currentOutputFloor());
    _channelCount = 0;
    _engineFailed = false;
    _seenLayoutGen = 0;
    _diagFeed = 0;
    _isEnabled = false;
    _isPaused = false;

    _shared = new V3DShared();
    _sources = [NSMutableArray array];

    _listenerPosition = AVAudio3DPointMake(0, 0, 0);
    _listenerOrientation = (AVAudio3DAngularOrientation){0, 0, 0};

    _engine = [[AVAudioEngine alloc] init];
    _env = [[AVAudioEnvironmentNode alloc] init];
    [_engine attachNode:_env];
    if (@available(macOS 12.0, *)) {
        _env.outputType = AVAudioEnvironmentOutputTypeHeadphones;
    }
    // Disable the automatic distance attenuation. By default the environment node attenuates by
    // distance (inverse model, ~-6 dB per doubling), so a speaker placed far away goes quiet on its
    // own and fights the user's gain. Pushing referenceDistance past any placement we allow means no
    // distance attenuation: position drives DIRECTION (HRTF), the per-group gain drives LEVEL.
    _env.distanceAttenuationParameters.referenceDistance = 100000.0f;
    _env.listenerPosition = _listenerPosition;
    _env.listenerAngularOrientation = _listenerOrientation;

    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &kDefaultOutputDeviceAddr,
                                   v3d_default_output_changed, (__bridge void *)self);
    return self;
}

- (void)dealloc {
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &kDefaultOutputDeviceAddr,
                                      v3d_default_output_changed, (__bridge void *)self);
    [self disable]; // stops the engine → quiesces the render thread before we free the rings
    [self destroyRings];
    if (_shared) {
        delete _shared;
        _shared = nullptr;
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

- (void)setBufferLength:(double)seconds {
    _configured = (seconds > 0.0) ? fsec(seconds) : fsec(0);
}

// --- lead policy (mirrors engine_sys_spatialized.mm) -----------------------

- (fsec)targetLead {
    return std::max(_configured, _deviceFloor.load());
}

- (fsec)primeLead {
    return std::min([self targetLead] / 2.0, kPrime);
}

// Currently banked lead = buffered mono samples / sample rate. All channel rings are fed in lockstep,
// so ring 0 is representative. Read on the producer thread.
- (fsec)lead {
    const uint32_t sr = _shared->sampleRate;
    if (sr == 0 || _rings.empty()) {
        return fsec(0);
    }
    return fsec((double)_rings[0]->buffered() / (double)sr);
}

- (void)updateDeviceFloor {
    const fsec floor = currentOutputFloor();
    _deviceFloor.store(floor);
    V3D_DIAG(@"[V3D] output device floor -> %.0f ms (target now %.0f ms)", ms(floor), ms([self targetLead]));
}

// --- graph / rings ---------------------------------------------------------

- (void)destroyRings {
    for (V3DChannelRing *r : _rings) {
        delete r;
    }
    _rings.clear();
}

// Apply the current speaker layout to the live source nodes. AVAudioSourceNode adopts AVAudioMixing
// (volume + 3D position) once connected to the environment; guard each setter with respondsToSelector
// so an older macOS that lacks a knob degrades gracefully instead of throwing.
- (void)applyLayout {
    const v3d_config::Layout layout = v3d_config::layout();
    const v3d_config::SpeakerPositions speakers = v3d_config::compute_speakers(layout);
    _channelGain.assign(_channelCount, 1.0f);
    for (uint32_t c = 0; c < _channelCount && c < _sources.count; ++c) {
        id<AVAudioMixing> mix = (id<AVAudioMixing>)_sources[c];
        if ([mix respondsToSelector:@selector(setRenderingAlgorithm:)]) {
            mix.renderingAlgorithm = AVAudio3DMixingRenderingAlgorithmHRTFHQ; // HRTFHQ only (old HRTF dropped)
        }
        if (@available(macOS 12.0, *)) {
            if ([mix respondsToSelector:@selector(setSourceMode:)]) {
                mix.sourceMode = AVAudio3DMixingSourceModePointSource;
            }
        }
        if ([mix respondsToSelector:@selector(setPosition:)]) {
            mix.position = speakerForChannel(speakers, _channelCount, c);
        }
        if ([mix respondsToSelector:@selector(setVolume:)]) {
            mix.volume = 1.0f; // gain is applied to the samples in the feed (mix.volume clamps near unity)
        }
        _channelGain[c] = (float)std::pow(10.0, gainDbForChannel(layout, _channelCount, c) / 20.0);
    }
    _seenLayoutGen = v3d_config::layout_generation();
}

// Size each ring generously: the target lead plus ~1 s of headroom, so it always exceeds any lead the
// policy will ask for (even after a built-in → wireless device switch raises the floor). The engine is
// stopped by the caller, so resizing/resetting here is single-threaded.
- (size_t)ringCapacityForSampleRate:(uint32_t)sampleRate {
    const double seconds = _configured.count() + 1.0;
    const size_t want = (size_t)(seconds * (double)sampleRate);
    return std::max<size_t>(nextPow2(want), (size_t)8192);
}

// Rebuild the whole graph for a new (sample rate, channel count): one mono AVAudioSourceNode + ring per
// content channel, each positioned at its mapped virtual speaker, all feeding the environment node.
// Caller must have stopped the engine first.
- (bool)rebuildGraphForSampleRate:(uint32_t)sampleRate channels:(uint32_t)channels {
    // AVAudioEngine connections want the "standard" (deinterleaved float) format; an interleaved
    // format is a common cause of a silent or refused graph. For mono the sample layout is identical.
    AVAudioFormat *fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate channels:1];
    if (!fmt) {
        V3D_DIAG(@"[V3D] Failed to create mono AVAudioFormat (%u Hz)", sampleRate);
        _monoFormat = nil;
        _channelCount = 0;
        return false;
    }
    _monoFormat = fmt;
    _channelCount = channels;
    _shared->sampleRate = sampleRate;
    _shared->primed.store(false, std::memory_order_relaxed);

    // Detach the previous sources and rebuild the rings.
    for (AVAudioSourceNode *old in _sources) {
        [_engine detachNode:old];
    }
    [_sources removeAllObjects];
    [self destroyRings];

    const size_t capacity = [self ringCapacityForSampleRate:sampleRate];
    V3DShared *shared = _shared; // captured raw (no self) by every render block

    // AVAudioEngine attach/connect can throw NSExceptions; catch them so a graph failure surfaces as a
    // logged error instead of unwinding through foobar's C++ feed (which would wedge playback).
    @try {
    for (uint32_t c = 0; c < channels; ++c) {
        V3DChannelRing *ring = new V3DChannelRing();
        ring->buf.assign(capacity, 0.0f);
        ring->capacity = capacity;
        ring->mask = capacity - 1;
        _rings.push_back(ring);

        AVAudioSourceNode *src = [[AVAudioSourceNode alloc]
            initWithFormat:_monoFormat
               renderBlock:^OSStatus(BOOL *isSilence, const AudioTimeStamp *timestamp,
                                     AVAudioFrameCount frameCount, AudioBufferList *outputData) {
                   (void)timestamp;
                   float *out = (float *)outputData->mBuffers[0].mData;
                   // Honour the output buffer's real capacity, not just frameCount, so an unexpected
                   // oversized request can never overflow it.
                   const size_t cap = outputData->mBuffers[0].mDataByteSize / sizeof(float);
                   const size_t need = std::min((size_t)frameCount, cap); // mono → samples == frames

                   if (ring->capacity == 0 || !shared->primed.load(std::memory_order_acquire) ||
                       shared->paused.load(std::memory_order_acquire)) {
                       memset(out, 0, need * sizeof(float));
                       *isSilence = YES;
                       return noErr;
                   }

                   const size_t w = ring->write.load(std::memory_order_acquire);
                   const size_t rd = ring->read.load(std::memory_order_relaxed);
                   const size_t avail = w - rd;
                   const size_t take = std::min(need, avail);

                   const size_t ri = rd & ring->mask;
                   const size_t first = std::min(take, ring->capacity - ri);
                   memcpy(out, ring->buf.data() + ri, first * sizeof(float));
                   if (take > first) {
                       memcpy(out + first, ring->buf.data(), (take - first) * sizeof(float));
                   }
                   if (take < need) {
                       memset(out + take, 0, (need - take) * sizeof(float)); // underrun → silence the tail
                       ring->underruns.fetch_add(1, std::memory_order_relaxed);
                       *isSilence = (take == 0) ? YES : NO;
                   } else {
                       *isSilence = NO;
                   }
                   ring->read.store(rd + take, std::memory_order_release);
                   return noErr;
               }];
        [_engine attachNode:src];
        // Each source gets its OWN input bus on the environment node (bus `c`); the plain
        // connect:to:format: would target bus 0 every time and overwrite the previous source.
        [_engine connect:src to:_env fromBus:0 toBus:c format:_monoFormat];
        [_sources addObject:src];
    }

    [_engine connect:_env to:_engine.mainMixerNode format:nil];
    } @catch (NSException *ex) {
        V3D_DIAG(@"[V3D] graph build FAILED: %@ — %@", ex.name, ex.reason ?: @"(nil)");
        _monoFormat = nil; // force a retry on the next feed (and keep surfacing the error)
        _channelCount = 0;
        return false;
    }

    [self applyLayout];
    V3D_DIAG(@"[V3D] graph rebuilt: %u ch @ %u Hz, ring=%zu samples/ch, target=%.0f ms", channels,
             sampleRate, capacity, ms([self targetLead]));
    return true;
}

- (bool)setupAudioFormat:(uint32_t)sampleRate channels:(uint32_t)channels {
    if (_monoFormat != nil && sampleRate == (uint32_t)_monoFormat.sampleRate && channels == _channelCount) {
        return true;
    }
    // Sample rate or channel count changed (or first format): rebuild. Stop first so the render thread
    // is quiesced and the ring/node swap is race-free.
    const bool wasRunning = _engine.isRunning;
    if (wasRunning) {
        [_engine stop];
    }
    if (![self rebuildGraphForSampleRate:sampleRate channels:channels]) {
        return false;
    }
    [self startEngineIfReady];
    return true;
}

// --- enable / disable ------------------------------------------------------

// Start the engine only once it's both enabled and has a connected graph (a format). enable() is
// called at construction, before any audio arrives, so the actual start is deferred to the first feed.
- (void)startEngineIfReady {
    if (!_isEnabled || _monoFormat == nil || _channelCount == 0 || _engine.isRunning) {
        return;
    }
    @try {
        NSError *err = nil;
        if (![_engine startAndReturnError:&err]) {
            // Log unconditionally (not the Debug-only macro): a start failure otherwise becomes an
            // indefinite SILENT stall (rings fill, backpressure goes 0, foobar stops feeding, no audio).
            [self logMessage:@"[V3D] engine start FAILED: %@", err ?: @"(nil)"];
            _engineFailed = true;
        } else {
            _engineFailed = false;
            V3D_DIAG(@"[V3D] engine started (%u ch @ %u Hz)", _channelCount, _shared->sampleRate);
        }
    } @catch (NSException *ex) {
        [self logMessage:@"[V3D] engine start EXCEPTION: %@ — %@", ex.name, ex.reason ?: @"(nil)"];
        _engineFailed = true;
    }
}

- (bool)enable {
    if (_isEnabled) {
        return true;
    }
    _isEnabled = true;
    _isPaused = false;
    _shared->paused.store(false, std::memory_order_release);
    [self startEngineIfReady]; // no-op until the first feed establishes the format/graph
    V3D_DIAG(@"[V3D] enabled (HRTFHQ virtual speaker rig)");
    return true;
}

- (void)disable {
    if (!_isEnabled) {
        return;
    }
    _isEnabled = false;
    _isPaused = false;
    if (_engine.isRunning) {
        [_engine stop];
    }
    _shared->primed.store(false, std::memory_order_release);
}

// --- transport -------------------------------------------------------------

- (void)pause {
    if (!_isEnabled) {
        return;
    }
    _isPaused = true;
    _shared->paused.store(true, std::memory_order_release); // render freezes; queues kept for resume
}

- (void)resume {
    if (!_isEnabled || !_isPaused) {
        return;
    }
    _isPaused = false;
    _shared->paused.store(false, std::memory_order_release);
}

- (void)forcePlay {
    // No more data is coming: start draining what we have even if we never reached the prime lead.
    if (!_isEnabled || _isPaused) {
        return;
    }
    _shared->primed.store(true, std::memory_order_release);
}

- (void)flush {
    // Seek: drop everything queued and re-prime from the new position. Stop first so resetting the ring
    // indices can't race the render thread.
    if (!_isEnabled) {
        return;
    }
    const bool wasRunning = _engine.isRunning;
    if (wasRunning) {
        [_engine stop];
    }
    for (V3DChannelRing *r : _rings) {
        r->read.store(0, std::memory_order_relaxed);
        r->write.store(0, std::memory_order_relaxed);
    }
    _shared->primed.store(false, std::memory_order_relaxed);
    if (wasRunning) {
        [self startEngineIfReady];
    }
}

// --- push side: foobar2000's process_samples_v2 ----------------------------

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

    // Live pick-up: if the preferences UI moved a speaker since we last applied, re-position the
    // sources. Cheap atomic compare every feed; the actual re-apply only runs when the user edited.
    if (v3d_config::layout_generation() != _seenLayoutGen) {
        [self applyLayout];
    }

    const size_t freeFrames = [self freeFrames];
    if (freeFrames == 0) {
        return 0;
    }
    const size_t take = std::min(frameCount, freeFrames);

    // Convert foobar's f64 chunk into the interleaved float staging buffer (take frames × channels),
    // then deinterleave into the per-channel rings (one mono speaker each).
    const size_t inSamples = take * channels;
    if (_feedStaging.size() < inSamples) {
        _feedStaging.resize(inSamples);
    }
    convert(_feedStaging.data(), take);

    const float *in = _feedStaging.data();
    const size_t nch = std::min<size_t>(channels, _rings.size());
    for (size_t c = 0; c < nch; ++c) {
        V3DChannelRing *r = _rings[c];
        const float gain = (c < _channelGain.size()) ? _channelGain[c] : 1.0f; // per-group gain, in samples
        const size_t w = r->write.load(std::memory_order_relaxed);
        for (size_t i = 0; i < take; ++i) {
            r->buf[(w + i) & r->mask] = in[i * channels + c] * gain;
        }
        r->write.store(w + take, std::memory_order_release);
    }

    // Priming: once the banked lead reaches the (smaller) prime threshold, let the render blocks drain.
    if (!_shared->primed.load(std::memory_order_relaxed) && [self lead] >= [self primeLead]) {
        _shared->primed.store(true, std::memory_order_release);
        V3D_DIAG(@"[V3D] primed: draining at lead=%.0f ms (target=%.0f ms)", ms([self lead]),
                 ms([self targetLead]));
    }
    if ((_diagFeed++ % 64) == 0) {
        V3D_DIAG(@"[V3D] feed #%llu take=%zu ch=%u lead=%.0f ms underruns=%llu",
                 (unsigned long long)_diagFeed, take, channels, ms([self lead]),
                 (unsigned long long)(_rings.empty() ? 0 : _rings[0]->underruns.load(std::memory_order_relaxed)));
    }
    return take;
}

// Frames we can still take before hitting the target lead, batched by kMinFeed and clamped to the
// physical ring space (which the policy never reaches, but clamp anyway for safety). All rings share
// the same fill, so ring 0 governs.
- (size_t)freeFrames {
    const uint32_t sr = _shared->sampleRate;
    if (sr == 0 || _rings.empty()) {
        return 0;
    }
    const fsec freeRoom = [self targetLead] - [self lead];
    if (freeRoom < kMinFeed) {
        return 0;
    }
    const size_t policy = (size_t)(freeRoom.count() * (double)sr);
    const size_t buffered = _rings[0]->buffered();
    const size_t physical = (_rings[0]->capacity > buffered) ? (_rings[0]->capacity - buffered) : 0;
    return std::min(policy, physical);
}

// --- backpressure for foobar's update() / update_v2() ----------------------

- (bool)canAcceptMore {
    if (!_isEnabled || _isPaused || _engineFailed) {
        return false;
    }
    return [self lead] < [self targetLead];
}

- (size_t)freeSampleCount {
    if (!_isEnabled || _isPaused) {
        return 0;
    }
    if (_engineFailed) {
        return 0; // engine won't run — stop foobar from feeding into a dead graph (no silent stall)
    }
    // Format not established yet: report "can take, amount unknown" (like the default backend) so
    // foobar feeds the first chunk — which is what creates the graph. Returning 0 here would deadlock
    // (no feed → no format → sampleRate stays 0 → still 0 …).
    if (_shared->sampleRate == 0 || _rings.empty()) {
        return SIZE_MAX;
    }
    return [self freeFrames];
}

// --- volume ----------------------------------------------------------------

- (void)setVolume:(float)volume {
    _engine.mainMixerNode.outputVolume = volume;
}

- (float)getVolume {
    return _engine.mainMixerNode.outputVolume;
}

// --- spatial ---------------------------------------------------------------
// Source placement is driven by the speaker layout (applyLayout), not a single source position. The
// listener setters position/orient the listener (the "place yourself" controls / head tracking).

- (void)setListenerPosition:(float)x y:(float)y z:(float)z {
    _listenerPosition = AVAudio3DPointMake(x, y, z);
    _env.listenerPosition = _listenerPosition;
}

- (void)setListenerOrientation:(float)yaw pitch:(float)pitch roll:(float)roll {
    _listenerOrientation = (AVAudio3DAngularOrientation){yaw, pitch, roll};
    _env.listenerAngularOrientation = _listenerOrientation;
}

// Retained from the protocol; the rig has no single "source", so this is intentionally inert. Speaker
// placement comes from the layout (a richer layout-setter path arrives with the config/UI wiring).
- (void)setSourcePosition:(float)x y:(float)y z:(float)z {
    (void)x;
    (void)y;
    (void)z;
}

// --- latency / status ------------------------------------------------------

- (double)getCurrentLatency {
    if (!_isEnabled) {
        return 0.0;
    }
    const double secs = [self lead].count();
    return (secs > 0.0 && secs == secs) ? secs : 0.0;
}

- (bool)isProgressing {
    return _isEnabled && !_isPaused && _shared->primed.load(std::memory_order_relaxed) && _engine.isRunning;
}

@end
