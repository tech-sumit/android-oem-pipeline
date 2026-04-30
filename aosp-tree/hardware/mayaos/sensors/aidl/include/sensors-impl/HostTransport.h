// HostTransport.h -- abstract Unix socket client to the host sensor injector.
//
// Forwarded into the guest by stf-provider-emulator at emulator boot via:
//   adb reverse localabstract:mayaos.sensors localabstract:mayaos.sensors
// The host side of the abstract socket is bound by the Phase 5
// mdf-plugin-recording sensors injector.

#pragma once

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>

namespace aidl::android::hardware::sensors::mayaos {

// Wire-format frame -- 32 bytes, little-endian.
struct SensorEventFrame {
    uint8_t  sensor_type;       // 1=ACCEL, 4=GYRO, 5=LIGHT, 6=PRESSURE,
                                // 8=PROX, 11=ROT_VEC, 13=AMBIENT_TEMP,
                                // 19=STEP_COUNTER, 20=STEP_DETECTOR
    uint8_t  reserved;
    uint16_t flags;             // bit 0: wakeUpEvent
    int32_t  payload_len;       // future-proof; usually 0
    int64_t  timestamp_ns;      // monotonic; 0 -> HAL clamps to now()
    float    v[4];
} __attribute__((packed));

static_assert(sizeof(SensorEventFrame) == 32, "wire format drift");

class HostTransport {
public:
    using FrameHandler = void(*)(const SensorEventFrame&, void* opaque);

    HostTransport();
    ~HostTransport();

    // Non-blocking. Spawns a reader thread that reconnects with backoff if
    // the host socket goes away (operator restarting the injector).
    bool start(FrameHandler cb, void* opaque);
    void stop();

    bool isConnected() const { return mConnected.load(); }

private:
    void readerLoop();
    bool connectOnce();

    int                       mFd = -1;
    std::atomic<bool>         mRunning{false};
    std::atomic<bool>         mConnected{false};
    std::thread               mThread;
    std::mutex                mFdMutex;
    FrameHandler              mCallback = nullptr;
    void*                     mOpaque = nullptr;

    static constexpr const char* kAbstractName = "mayaos.sensors";
    // Backoff schedule when the host socket isn't available yet:
    static constexpr int      kMinReconnectMs = 100;
    static constexpr int      kMaxReconnectMs = 5000;
};

}  // namespace aidl::android::hardware::sensors::mayaos
