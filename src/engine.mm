//
//  engine.mm
//  foo_out_avfoundation
//
//  C++ facade over the Objective-C output backends. It holds one id<AVFOutputBackend> and forwards
//  every call to it; which concrete backend it is depends on OutputMode:
//    - engine_sys_spatialized.mm (AVFSysSpatializedBackend)         — system Spatial Audio (default)
//    - engine_virtual_3d.mm  (AVFVirtual3DBackend) — in-process HRTFHQ positional path (V3D)
//  This is the single place backend selection happens. See docs/memo.md "File layout".
//

#import "engine.h"
#import "engine_virtual_3d.h"

namespace foo_out_avf
{

    // Construct the backend for a mode. The two backends are interchangeable behind the protocol;
    // the facade never needs to know which one it holds beyond this point.
    static id<AVFOutputBackend> avf_make_backend(OutputMode mode) {
        switch (mode) {
        case OutputMode::Virtual3D:
            return [[AVFVirtual3DBackend alloc] init];
        case OutputMode::SystemSpatial:
        default:
            return [[AVFSysSpatializedBackend alloc] init];
        }
    }

    AVFEngine::AVFEngine(OutputMode mode) : mode_(mode) {
        impl_ = (__bridge_retained void *)avf_make_backend(mode);
    }

    AVFEngine::~AVFEngine() {
        if (impl_) {
            (void)(__bridge_transfer id<AVFOutputBackend>)impl_;
            impl_ = nullptr;
        }
    }

    void AVFEngine::setMode(OutputMode mode) {
        if (mode == mode_ && impl_) {
            return;
        }
        if (impl_) {
            (void)(__bridge_transfer id<AVFOutputBackend>)impl_;
            impl_ = nullptr;
        }
        mode_ = mode;
        impl_ = (__bridge_retained void *)avf_make_backend(mode);
    }

    OutputMode AVFEngine::mode() const { return mode_; }

    void AVFEngine::flush() {
        id<AVFOutputBackend> impl = (__bridge id<AVFOutputBackend>)impl_;
        [impl flush];
    }

    void AVFEngine::pause() {
        id<AVFOutputBackend> impl = (__bridge id<AVFOutputBackend>)impl_;
        [impl pause];
    }

    void AVFEngine::resume() {
        id<AVFOutputBackend> impl = (__bridge id<AVFOutputBackend>)impl_;
        [impl resume];
    }

    void AVFEngine::forcePlay() {
        id<AVFOutputBackend> impl = (__bridge id<AVFOutputBackend>)impl_;
        [impl forcePlay];
    }

    bool AVFEngine::enable() {
        id<AVFOutputBackend> impl = (__bridge id<AVFOutputBackend>)impl_;
        return [impl enable];
    }

    void AVFEngine::disable() {
        id<AVFOutputBackend> impl = (__bridge id<AVFOutputBackend>)impl_;
        [impl disable];
    }

    bool AVFEngine::isEnabled() const {
        id<AVFOutputBackend> impl = (__bridge id<AVFOutputBackend>)impl_;
        return [impl isEnabled];
    }

    bool AVFEngine::isPaused() const {
        id<AVFOutputBackend> impl = (__bridge id<AVFOutputBackend>)impl_;
        return [impl isPaused];
    }

    bool AVFEngine::isProgressing() const {
        id<AVFOutputBackend> impl = (__bridge id<AVFOutputBackend>)impl_;
        return [impl isProgressing];
    }

    void AVFEngine::setVolume(float volume) {
        id<AVFOutputBackend> impl = (__bridge id<AVFOutputBackend>)impl_;
        [impl setVolume:volume];
    }

    float AVFEngine::getVolume() const {
        id<AVFOutputBackend> impl = (__bridge id<AVFOutputBackend>)impl_;
        return [impl getVolume];
    }

    void AVFEngine::setListenerPosition(float x, float y, float z) {
        id<AVFOutputBackend> impl = (__bridge id<AVFOutputBackend>)impl_;
        [impl setListenerPosition:x y:y z:z];
    }

    void AVFEngine::setListenerOrientation(float yaw, float pitch, float roll) {
        id<AVFOutputBackend> impl = (__bridge id<AVFOutputBackend>)impl_;
        [impl setListenerOrientation:yaw pitch:pitch roll:roll];
    }

    void AVFEngine::setSourcePosition(float x, float y, float z) {
        id<AVFOutputBackend> impl = (__bridge id<AVFOutputBackend>)impl_;
        [impl setSourcePosition:x y:y z:z];
    }

    double AVFEngine::getCurrentLatency() const {
        id<AVFOutputBackend> impl = (__bridge id<AVFOutputBackend>)impl_;
        return [impl getCurrentLatency];
    }

    bool AVFEngine::canAcceptMore() const {
        id<AVFOutputBackend> impl = (__bridge id<AVFOutputBackend>)impl_;
        return [impl canAcceptMore];
    }

    size_t AVFEngine::freeSampleCount() const {
        id<AVFOutputBackend> impl = (__bridge id<AVFOutputBackend>)impl_;
        return [impl freeSampleCount];
    }

    size_t AVFEngine::feedAudioData(uint32_t sampleRate, uint32_t channels, size_t frameCount,
                                    const std::function<void(float *, size_t)> &convert) {
        id<AVFOutputBackend> impl = (__bridge id<AVFOutputBackend>)impl_;
        return [impl feedAudioData:sampleRate channels:channels frameCount:frameCount converter:convert];
    }

    void AVFEngine::setLogCallback(void (*callback)(const char *message)) {
        id<AVFOutputBackend> impl = (__bridge id<AVFOutputBackend>)impl_;
        [impl setLogCallback:callback];
    }

    void AVFEngine::setBufferLength(double seconds) {
        id<AVFOutputBackend> impl = (__bridge id<AVFOutputBackend>)impl_;
        [impl setBufferLength:seconds];
    }

    bool AVFEngine::setupAudioFormat(double sampleRate, int channels) {
        id<AVFOutputBackend> impl = (__bridge id<AVFOutputBackend>)impl_;
        return [impl setupAudioFormat:(uint32_t)sampleRate channels:(uint32_t)channels];
    }

} // namespace foo_out_avf
