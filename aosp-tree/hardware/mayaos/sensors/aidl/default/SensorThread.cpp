#include "SensorThread.h"

#include <android-base/logging.h>
#include <utils/SystemClock.h>

#include <chrono>

namespace aidl::android::hardware::sensors::mayaos {

namespace {

constexpr int32_t kHandleAccel       = 1;
constexpr int32_t kHandleGyro        = 4;
constexpr int32_t kHandleLight       = 5;
constexpr int32_t kHandlePressure    = 6;
constexpr int32_t kHandleProximity   = 8;
constexpr int32_t kHandleRotVec      = 11;
constexpr int32_t kHandleAmbientTemp = 13;
constexpr int32_t kHandleStepCounter = 19;
constexpr int32_t kHandleStepDetect  = 20;

int32_t typeToHandle(uint8_t type) {
    switch (type) {
        case 1:  return kHandleAccel;
        case 4:  return kHandleGyro;
        case 5:  return kHandleLight;
        case 6:  return kHandlePressure;
        case 8:  return kHandleProximity;
        case 11: return kHandleRotVec;
        case 13: return kHandleAmbientTemp;
        case 19: return kHandleStepCounter;
        case 20: return kHandleStepDetect;
        default: return -1;
    }
}

// Translate one wire frame into an AIDL Event.
bool frameToEvent(const SensorEventFrame& f, Event* out) {
    int32_t handle = typeToHandle(f.sensor_type);
    if (handle < 0) return false;

    out->sensorHandle = handle;
    out->sensorType   = static_cast<::aidl::android::hardware::sensors::SensorType>(f.sensor_type);
    out->timestamp    = (f.timestamp_ns != 0) ? f.timestamp_ns : ::android::elapsedRealtimeNano();

    using ::aidl::android::hardware::sensors::Event;
    using ::aidl::android::hardware::sensors::EventPayload;

    switch (f.sensor_type) {
        case 1:  // ACCELEROMETER
        case 4:  // GYROSCOPE
        {
            EventPayload::Vec3 v;
            v.x = f.v[0];
            v.y = f.v[1];
            v.z = f.v[2];
            v.status = ::aidl::android::hardware::sensors::SensorStatus::ACCURACY_HIGH;
            out->payload.set<EventPayload::Tag::vec3>(v);
            break;
        }
        case 11:  // ROTATION_VECTOR
        {
            EventPayload::Data data;
            data.values = {f.v[0], f.v[1], f.v[2], f.v[3], 0.f};
            out->payload.set<EventPayload::Tag::data>(data);
            break;
        }
        case 5:   // LIGHT
        case 6:   // PRESSURE
        case 8:   // PROXIMITY
        case 13:  // AMBIENT_TEMPERATURE
        case 19:  // STEP_COUNTER
        case 20:  // STEP_DETECTOR (event-only)
        {
            EventPayload::Single s;
            s.value = f.v[0];
            out->payload.set<EventPayload::Tag::scalar>(s.value);
            break;
        }
    }
    return true;
}

}  // namespace

SensorThread::SensorThread() {
    for (auto& a : mActive) a.store(false);
    for (auto& s : mSamplingNs) s.store(0);
}

SensorThread::~SensorThread() {
    stop();
}

void SensorThread::initialize(std::shared_ptr<EventMessageQueue> eventQueue,
                              std::shared_ptr<ISensorsCallback> callback) {
    mEventQueue = std::move(eventQueue);
    mCallback   = std::move(callback);
}

void SensorThread::start() {
    if (mRunning.exchange(true)) return;
    mTransport.start(&SensorThread::onHostFrame, this);
    mKeepaliveThread = std::thread(&SensorThread::keepaliveLoop, this);
}

void SensorThread::stop() {
    if (!mRunning.exchange(false)) return;
    mTransport.stop();
    if (mKeepaliveThread.joinable()) mKeepaliveThread.join();
}

void SensorThread::setActivation(int32_t handle, bool active) {
    if (handle < 0 || handle >= (int32_t)mActive.size()) return;
    mActive[handle].store(active);
}

void SensorThread::setSamplingPeriod(int32_t handle, int64_t samplingPeriodNs,
                                     int64_t /*maxReportLatencyNs*/) {
    if (handle < 0 || handle >= (int32_t)mSamplingNs.size()) return;
    mSamplingNs[handle].store(samplingPeriodNs);
}

void SensorThread::disableAll() {
    for (auto& a : mActive) a.store(false);
}

void SensorThread::onHostFrame(const SensorEventFrame& frame, void* opaque) {
    auto* self = reinterpret_cast<SensorThread*>(opaque);
    Event ev;
    if (!frameToEvent(frame, &ev)) return;

    // Stash for keepalive replay.
    if (ev.sensorHandle >= 0 && ev.sensorHandle < (int32_t)self->mLastSample.size()) {
        self->mLastSample[ev.sensorHandle] = ev;
    }

    if (self->mActive[ev.sensorHandle].load()) {
        self->enqueue(ev);
    }
}

void SensorThread::enqueue(const Event& event) {
    if (!mEventQueue) return;
    if (!mEventQueue->write(&event, 1)) {
        // FMQ full -- framework hasn't drained. Best-effort drop. The
        // framework's flush mechanism is the recovery path.
    }
}

void SensorThread::keepaliveLoop() {
    using clock = std::chrono::steady_clock;
    auto next_tick = clock::now() + std::chrono::milliseconds(200);

    while (mRunning.load()) {
        std::this_thread::sleep_until(next_tick);
        next_tick += std::chrono::milliseconds(200);

        for (int32_t h = 0; h < (int32_t)mActive.size(); ++h) {
            if (!mActive[h].load()) continue;
            int64_t periodNs = mSamplingNs[h].load();
            if (periodNs <= 0) continue;
            // If the host has been silent for >2x the configured period,
            // re-emit the last known sample so the framework's "stuck
            // sensor" detector doesn't fire.
            int64_t now = ::android::elapsedRealtimeNano();
            if (mLastSample[h].timestamp == 0) continue;
            if (now - mLastSample[h].timestamp > 2 * periodNs) {
                Event ev = mLastSample[h];
                ev.timestamp = now;
                enqueue(ev);
            }
        }
    }
}

}  // namespace aidl::android::hardware::sensors::mayaos
