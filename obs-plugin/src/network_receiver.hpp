#pragma once

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace iphonecam {

struct CameraPacket;
struct ControlCommand;

enum class ConnectionMode {
    // Dial the iPhone through usbmuxd over the cable.
    Usb,
    // Dial the iPhone's IP address or Bonjour name over the network.
    WiFi,
};

struct ReceiverConfig {
    ConnectionMode mode = ConnectionMode::Usb;
    // USB only: the camera name to bind to; empty takes the first free iPhone.
    std::string targetDevice;
    // Wi-Fi only: an IP address ("192.168.1.5", optionally ":port") or a discovered camera name.
    std::string host;
};

// Camera names seen on USB connections.
std::vector<std::string> getDiscoveredDevices();
void registerDiscoveredDevice(const std::string &name);

// Bonjour discovery of iPhones advertising the stream listener, for the Wi-Fi host picker.
void startPhoneDiscovery();
void stopPhoneDiscovery();
std::vector<std::string> getDiscoveredPhoneNames();

class NetworkReceiver {
public:
    using PacketCallback = std::function<void(const std::vector<uint8_t> &data)>;
    // connection describes the live link ("USB: iPhone", "Wi-Fi: 192.168.1.5:8240") or is empty.
    using StatusCallback = std::function<void(const std::string &status, const std::string &connection, bool connected)>;

    NetworkReceiver();
    ~NetworkReceiver();

    void setPacketCallback(PacketCallback callback);
    void setStatusCallback(StatusCallback callback);
    void start(const ReceiverConfig &config);
    void stop();
    void sendControlCommand(const ControlCommand &command);
    void sendPacket(const CameraPacket &packet);

    struct Impl;

private:
    Impl *impl_ = nullptr;
};

} // namespace iphonecam
