// Sensors.h -- ISensors AIDL implementation.
//
// Replaces the goldfish stub HAL on emu64a/emu64x. The 9 sensors
// listed in README.md ride a single FMQ; events come from the host
// over the abstract socket via SensorThread + HostTransport.

#pragma once

#include <aidl/android/hardware/sensors/BnSensors.h>
#include <aidl/android/hardware/sensors/SensorInfo.h>

#include <memory>
#include <vector>

#include "SensorThread.h"

namespace aidl::android::hardware::sensors::mayaos {

class Sensors : public BnSensors {
public:
    Sensors();
    ~Sensors() override;

    // ---- ISensors AIDL methods --------------------------------------------
    ::ndk::ScopedAStatus activate(int32_t sensorHandle, bool enabled) override;
    ::ndk::ScopedAStatus batch(int32_t sensorHandle, int64_t samplingPeriodNs,
                               int64_t maxReportLatencyNs) override;
    ::ndk::ScopedAStatus configDirectReport(
        int32_t sensorHandle, int32_t channelHandle, RateLevel rate,
        int32_t* out) override;
    ::ndk::ScopedAStatus flush(int32_t sensorHandle) override;
    ::ndk::ScopedAStatus getSensorsList(std::vector<SensorInfo>* out) override;
    ::ndk::ScopedAStatus initialize(
        const ::aidl::android::hardware::common::fmq::MQDescriptor<
            ::aidl::android::hardware::sensors::Event,
            ::aidl::android::hardware::common::fmq::SynchronizedReadWrite>&
            eventQueueDesc,
        const ::aidl::android::hardware::common::fmq::MQDescriptor<
            int32_t,
            ::aidl::android::hardware::common::fmq::SynchronizedReadWrite>&
            wakeLockDesc,
        const std::shared_ptr<ISensorsCallback>& sensorsCallback) override;
    ::ndk::ScopedAStatus injectSensorData(const Event& event) override;
    ::ndk::ScopedAStatus registerDirectChannel(
        const ISensors::SharedMemInfo& mem, int32_t* out) override;
    ::ndk::ScopedAStatus setOperationMode(OperationMode mode) override;
    ::ndk::ScopedAStatus unregisterDirectChannel(int32_t channelHandle) override;

private:
    std::vector<SensorInfo> buildSensorsList() const;

    std::vector<SensorInfo>      mSensors;
    std::shared_ptr<SensorThread> mThread;
};

}  // namespace aidl::android::hardware::sensors::mayaos
