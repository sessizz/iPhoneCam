#pragma once

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace iphonecam {

class NetworkReceiver {
public:
    using PacketCallback = std::function<void(const std::vector<uint8_t> &data)>;
    using StatusCallback = std::function<void(const std::string &status, uint16_t port)>;

    NetworkReceiver();
    ~NetworkReceiver();

    void setPacketCallback(PacketCallback callback);
    void setStatusCallback(StatusCallback callback);
    void start(const std::string &receiverName);
    void stop();

private:
    struct Impl;
    Impl *impl_ = nullptr;
};

} // namespace iphonecam
