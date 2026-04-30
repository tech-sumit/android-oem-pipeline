// main.cpp -- service entry point for android.hardware.sensors-service.mayaos.

#include <android-base/logging.h>
#include <android/binder_manager.h>
#include <android/binder_process.h>

#include "Sensors.h"

using aidl::android::hardware::sensors::mayaos::Sensors;

int main() {
    android::base::InitLogging(nullptr,
                               android::base::LogdLogger(android::base::SYSTEM));
    LOG(INFO) << "mayaos.sensors HAL service starting";

    ABinderProcess_setThreadPoolMaxThreadCount(2);

    auto sensors = ::ndk::SharedRefBase::make<Sensors>();
    const std::string instance =
        std::string(Sensors::descriptor) + "/default";

    binder_status_t status =
        AServiceManager_addService(sensors->asBinder().get(), instance.c_str());
    if (status != STATUS_OK) {
        LOG(FATAL) << "AServiceManager_addService(" << instance
                   << ") failed: " << status;
        return EXIT_FAILURE;
    }

    LOG(INFO) << "mayaos.sensors HAL service registered as " << instance;
    ABinderProcess_joinThreadPool();

    LOG(WARNING) << "mayaos.sensors HAL service exiting (binder loop returned)";
    return EXIT_FAILURE;
}
