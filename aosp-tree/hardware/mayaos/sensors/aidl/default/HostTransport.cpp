#include "HostTransport.h"

#include <errno.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#include <android-base/logging.h>

#include <chrono>
#include <thread>

namespace aidl::android::hardware::sensors::mayaos {

HostTransport::HostTransport() = default;

HostTransport::~HostTransport() {
    stop();
}

bool HostTransport::start(FrameHandler cb, void* opaque) {
    mCallback = cb;
    mOpaque = opaque;
    mRunning.store(true);
    mThread = std::thread(&HostTransport::readerLoop, this);
    return true;
}

void HostTransport::stop() {
    mRunning.store(false);

    {
        std::lock_guard<std::mutex> g(mFdMutex);
        if (mFd >= 0) {
            ::shutdown(mFd, SHUT_RDWR);
            ::close(mFd);
            mFd = -1;
        }
    }
    if (mThread.joinable()) {
        mThread.join();
    }
}

bool HostTransport::connectOnce() {
    int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        PLOG(WARNING) << "mayaos.sensors: socket() failed";
        return false;
    }

    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    // Linux abstract namespace: prepend a NUL byte and write the name.
    // Name is "@mayaos.sensors" -> sun_path is "\0mayaos.sensors".
    const std::string name = kAbstractName;
    if (name.size() + 1 >= sizeof(addr.sun_path)) {
        LOG(ERROR) << "mayaos.sensors: abstract name too long";
        ::close(fd);
        return false;
    }
    ::memcpy(addr.sun_path + 1, name.data(), name.size());
    socklen_t addrlen = offsetof(sockaddr_un, sun_path) + 1 + name.size();

    if (::connect(fd, reinterpret_cast<sockaddr*>(&addr), addrlen) < 0) {
        // Expected during boot; the host injector may not be up yet.
        ::close(fd);
        return false;
    }

    {
        std::lock_guard<std::mutex> g(mFdMutex);
        mFd = fd;
    }
    mConnected.store(true);
    LOG(INFO) << "mayaos.sensors: connected to @" << kAbstractName;
    return true;
}

void HostTransport::readerLoop() {
    int backoff = kMinReconnectMs;

    while (mRunning.load()) {
        if (!mConnected.load() && !connectOnce()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(backoff));
            backoff = std::min(backoff * 2, kMaxReconnectMs);
            continue;
        }
        backoff = kMinReconnectMs;

        SensorEventFrame frame{};
        ssize_t total = 0;
        while (total < (ssize_t)sizeof(frame)) {
            int fd = -1;
            {
                std::lock_guard<std::mutex> g(mFdMutex);
                fd = mFd;
            }
            if (fd < 0) break;

            ssize_t n = ::read(fd, reinterpret_cast<char*>(&frame) + total,
                               sizeof(frame) - total);
            if (n <= 0) {
                if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
                // Host went away; recycle and reconnect.
                {
                    std::lock_guard<std::mutex> g(mFdMutex);
                    if (mFd >= 0) {
                        ::close(mFd);
                        mFd = -1;
                    }
                }
                mConnected.store(false);
                LOG(WARNING) << "mayaos.sensors: host disconnected, reconnecting";
                break;
            }
            total += n;
        }

        if (total == (ssize_t)sizeof(frame) && mCallback) {
            mCallback(frame, mOpaque);
        }
    }
}

}  // namespace aidl::android::hardware::sensors::mayaos
