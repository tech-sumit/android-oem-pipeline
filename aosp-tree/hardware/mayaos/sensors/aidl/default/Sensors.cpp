#include "Sensors.h"

#include <android-base/logging.h>

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

SensorInfo makeContinuous(int32_t handle, SensorType type,
                          const std::string& name, int32_t minDelayUs,
                          int32_t maxDelayUs, float maxRange,
                          float resolution, float power) {
    SensorInfo s;
    s.sensorHandle  = handle;
    s.name          = name;
    s.vendor        = "MayaOS";
    s.version       = 1;
    s.type          = type;
    s.typeAsString  = "";
    s.maxRange      = maxRange;
    s.resolution    = resolution;
    s.power         = power;
    s.minDelayUs    = minDelayUs;
    s.fifoReservedEventCount = 0;
    s.fifoMaxEventCount      = 0;
    s.requiredPermission     = "";
    s.maxDelayUs    = maxDelayUs;
    s.flags         = static_cast<uint32_t>(SensorInfo::SENSOR_FLAG_BITS_CONTINUOUS_MODE);
    return s;
}

SensorInfo makeOnChange(int32_t handle, SensorType type,
                        const std::string& name, float maxRange,
                        float resolution, float power) {
    SensorInfo s = makeContinuous(handle, type, name, 200000 /*5Hz*/,
                                  10000000 /*0.1Hz*/, maxRange, resolution,
                                  power);
    s.flags = static_cast<uint32_t>(SensorInfo::SENSOR_FLAG_BITS_ON_CHANGE_MODE);
    return s;
}

SensorInfo makeSpecial(int32_t handle, SensorType type,
                       const std::string& name, float maxRange,
                       float resolution, float power) {
    SensorInfo s = makeContinuous(handle, type, name, 0, 0, maxRange,
                                  resolution, power);
    s.flags = static_cast<uint32_t>(SensorInfo::SENSOR_FLAG_BITS_SPECIAL_REPORTING_MODE);
    return s;
}

}  // namespace

Sensors::Sensors() : mThread(std::make_shared<SensorThread>()) {
    mSensors = buildSensorsList();
    mThread->start();
}

Sensors::~Sensors() {
    if (mThread) mThread->stop();
}

std::vector<SensorInfo> Sensors::buildSensorsList() const {
    std::vector<SensorInfo> out;
    out.reserve(9);

    // ACCEL: 200 Hz, full range +/- 39.2 m/s^2 (4g), 0.0024 m/s^2/LSB.
    out.push_back(makeContinuous(kHandleAccel, SensorType::ACCELEROMETER,
        "MayaOS Accelerometer", 5000, 200000, 39.2f, 0.0024f, 0.230f));

    // GYRO: 200 Hz, full range +/- 8.7 rad/s, 0.00076 rad/s/LSB.
    out.push_back(makeContinuous(kHandleGyro, SensorType::GYROSCOPE,
        "MayaOS Gyroscope", 5000, 200000, 8.7f, 0.00076f, 0.660f));

    // LIGHT: on-change, 0..40000 lux.
    out.push_back(makeOnChange(kHandleLight, SensorType::LIGHT,
        "MayaOS Ambient Light", 40000.f, 1.0f, 0.090f));

    // PRESSURE: 5 Hz, 300..1100 hPa.
    out.push_back(makeContinuous(kHandlePressure, SensorType::PRESSURE,
        "MayaOS Barometer", 200000, 10000000, 1100.f, 0.01f, 0.110f));

    // PROXIMITY: on-change, 0..5 cm.
    out.push_back(makeOnChange(kHandleProximity, SensorType::PROXIMITY,
        "MayaOS Proximity", 5.f, 0.1f, 0.090f));

    // ROTATION_VECTOR: 200 Hz composite (no min delay enforced).
    out.push_back(makeContinuous(kHandleRotVec, SensorType::ROTATION_VECTOR,
        "MayaOS Rotation Vector", 5000, 200000, 1.f, 0.0001f, 0.500f));

    // AMBIENT_TEMP: 1 Hz on-change, -40..85 C.
    out.push_back(makeOnChange(kHandleAmbientTemp, SensorType::AMBIENT_TEMPERATURE,
        "MayaOS Ambient Temperature", 85.f, 0.01f, 0.030f));

    // STEP_COUNTER: 1 Hz on-change.
    out.push_back(makeOnChange(kHandleStepCounter, SensorType::STEP_COUNTER,
        "MayaOS Step Counter", 1e9f, 1.f, 0.060f));

    // STEP_DETECTOR: special reporting (events only).
    out.push_back(makeSpecial(kHandleStepDetect, SensorType::STEP_DETECTOR,
        "MayaOS Step Detector", 1.f, 1.f, 0.060f));

    return out;
}

::ndk::ScopedAStatus Sensors::activate(int32_t handle, bool enabled) {
    LOG(INFO) << "mayaos.sensors: activate handle=" << handle
              << " enabled=" << enabled;
    mThread->setActivation(handle, enabled);
    return ::ndk::ScopedAStatus::ok();
}

::ndk::ScopedAStatus Sensors::batch(int32_t handle, int64_t samplingPeriodNs,
                                    int64_t maxReportLatencyNs) {
    mThread->setSamplingPeriod(handle, samplingPeriodNs, maxReportLatencyNs);
    return ::ndk::ScopedAStatus::ok();
}

::ndk::ScopedAStatus Sensors::configDirectReport(int32_t, int32_t,
                                                 RateLevel, int32_t* out) {
    if (out) *out = 0;
    // Direct report is an SoC-acceleration optimization (sensors push
    // events straight to a shared memory channel skipping the framework).
    // We could implement it later for fps-critical replay tests, but
    // for now the standard FMQ path is enough.
    return ::ndk::ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
}

::ndk::ScopedAStatus Sensors::flush(int32_t /*handle*/) {
    // Flush completion event would be enqueued back to the framework FMQ.
    // The default goldfish HAL no-ops this; we follow suit.
    return ::ndk::ScopedAStatus::ok();
}

::ndk::ScopedAStatus Sensors::getSensorsList(std::vector<SensorInfo>* out) {
    *out = mSensors;
    return ::ndk::ScopedAStatus::ok();
}

::ndk::ScopedAStatus Sensors::initialize(
    const ::aidl::android::hardware::common::fmq::MQDescriptor<
        ::aidl::android::hardware::sensors::Event,
        ::aidl::android::hardware::common::fmq::SynchronizedReadWrite>&
        eventQueueDesc,
    const ::aidl::android::hardware::common::fmq::MQDescriptor<
        int32_t,
        ::aidl::android::hardware::common::fmq::SynchronizedReadWrite>&
        /*wakeLockDesc*/,
    const std::shared_ptr<ISensorsCallback>& sensorsCallback) {
    auto eq = std::make_shared<EventMessageQueue>(eventQueueDesc);
    if (!eq->isValid()) {
        return ::ndk::ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    }
    mThread->initialize(std::move(eq), sensorsCallback);
    return ::ndk::ScopedAStatus::ok();
}

::ndk::ScopedAStatus Sensors::injectSensorData(const Event& /*event*/) {
    // The framework never injects against a real-device HAL and we don't
    // run in OperationMode::DATA_INJECTION. Return UNSUPPORTED.
    return ::ndk::ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
}

::ndk::ScopedAStatus Sensors::registerDirectChannel(
    const ISensors::SharedMemInfo&, int32_t* out) {
    if (out) *out = 0;
    return ::ndk::ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
}

::ndk::ScopedAStatus Sensors::setOperationMode(OperationMode mode) {
    if (mode == OperationMode::NORMAL) {
        return ::ndk::ScopedAStatus::ok();
    }
    return ::ndk::ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
}

::ndk::ScopedAStatus Sensors::unregisterDirectChannel(int32_t /*channel*/) {
    return ::ndk::ScopedAStatus::ok();
}

}  // namespace aidl::android::hardware::sensors::mayaos
