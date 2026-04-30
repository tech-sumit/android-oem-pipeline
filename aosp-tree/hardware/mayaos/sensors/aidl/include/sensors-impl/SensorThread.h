// SensorThread.h -- handles the FMQ -> framework path.
//
// ISensors is a queue-based interface: the framework sends sensor commands
// to us via the EventQueue and reads SensorEvents from a separate FMQ. The
// queue plumbing lives here so Sensors.cpp stays focused on AIDL methods.

#pragma once

#include <aidl/android/hardware/common/fmq/MQDescriptor.h>
#include <aidl/android/hardware/common/fmq/SynchronizedReadWrite.h>
#include <aidl/android/hardware/sensors/Event.h>
#include <aidl/android/hardware/sensors/ISensorsCallback.h>
#include <fmq/AidlMessageQueue.h>

#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include "HostTransport.h"

namespace aidl::android::hardware::sensors::mayaos {

using ::aidl::android::hardware::common::fmq::MQDescriptor;
using ::aidl::android::hardware::common::fmq::SynchronizedReadWrite;
using ::aidl::android::hardware::sensors::Event;
using ::android::AidlMessageQueue;

using EventMessageQueue =
    AidlMessageQueue<Event, SynchronizedReadWrite>;

class SensorThread {
public:
    SensorThread();
    ~SensorThread();

    // Configure (or reconfigure) the FMQ the framework reads events from.
    // Called from Sensors::initialize().
    void initialize(std::shared_ptr<EventMessageQueue> eventQueue,
                    std::shared_ptr<ISensorsCallback> callback);

    // Activate / deactivate a single sensor handle. The framework calls
    // this in response to SensorManager.registerListener / unregister.
    void setActivation(int32_t handle, bool active);
    void setSamplingPeriod(int32_t handle, int64_t samplingPeriodNs,
                           int64_t maxReportLatencyNs);

    // Last-resort fault hook from the framework.
    void disableAll();

    // Running thread state.
    void start();
    void stop();

private:
    // Called from HostTransport reader thread per inbound frame.
    static void onHostFrame(const SensorEventFrame& frame, void* opaque);
    void enqueue(const Event& event);

    HostTransport                              mTransport;
    std::shared_ptr<EventMessageQueue>         mEventQueue;
    std::shared_ptr<ISensorsCallback>          mCallback;

    std::mutex                                 mActiveMutex;
    // bitmap keyed by sensor handle (we ship 9 sensors so handle 1..9).
    std::array<std::atomic<bool>, 32>          mActive{};
    // Most recent sample per sensor for "stuck" prevention.
    std::array<Event, 32>                      mLastSample{};
    // Sampling cadence per sensor (ns); used by the keepalive thread.
    std::array<std::atomic<int64_t>, 32>       mSamplingNs{};

    std::atomic<bool>                          mRunning{false};
    std::thread                                mKeepaliveThread;

    // The keepalive thread emits the last-known sample at the configured
    // rate so the framework's per-sensor "no event in T seconds" stuckness
    // detector never fires even if the host injector is silent.
    void keepaliveLoop();
};

}  // namespace aidl::android::hardware::sensors::mayaos
