#include "network_receiver.hpp"
#include "protocol.hpp"

#include <util/base.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cerrno>
#include <cstring>
#include <dns_sd.h>
#include <map>
#include <mutex>
#include <netdb.h>
#include <netinet/in.h>
#include <string>
#include <sys/fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <vector>

#import <Foundation/Foundation.h>

namespace iphonecam {
namespace {

constexpr auto kEndpointTimeout = std::chrono::milliseconds(1500);

std::mutex gDevicesMutex;
std::vector<std::string> gDiscoveredDevices;

std::string endpointDescription(const sockaddr_storage &address, socklen_t addressLength)
{
    char host[NI_MAXHOST] = {};
    char service[NI_MAXSERV] = {};
    const int result = getnameinfo(reinterpret_cast<const sockaddr *>(&address), addressLength, host, sizeof(host),
                                   service, sizeof(service), NI_NUMERICHOST | NI_NUMERICSERV);
    if (result != 0)
        return "unknown";
    return std::string(host) + ":" + std::string(service);
}

std::string errnoDescription(const char *operation)
{
    return std::string(operation) + " failed: " + std::strerror(errno);
}

int connectUsbmuxd()
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
        return -1;

    sockaddr_un addr = {};
    addr.sun_family = AF_UNIX;
    const char *path = "/var/run/usbmuxd";
    std::strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    const socklen_t addrLen = static_cast<socklen_t>(sizeof(addr.sun_family) + std::strlen(path) + 1);

    if (connect(fd, reinterpret_cast<sockaddr *>(&addr), addrLen) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

bool sendUsbmuxPlist(int fd, NSDictionary *dict, uint32_t tag = 1)
{
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:dict
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:&error];
    if (!data || error)
        return false;

    const uint32_t totalLen = 16 + static_cast<uint32_t>(data.length);
    uint32_t header[4];
    header[0] = OSSwapHostToLittleInt32(totalLen);
    header[1] = OSSwapHostToLittleInt32(1); // Version
    header[2] = OSSwapHostToLittleInt32(8); // MESSAGE_PLIST
    header[3] = OSSwapHostToLittleInt32(tag);

    NSMutableData *packet = [NSMutableData dataWithBytes:header length:16];
    [packet appendData:data];

    const ssize_t sent = send(fd, packet.bytes, packet.length, 0);
    return sent == static_cast<ssize_t>(packet.length);
}

NSDictionary *readUsbmuxPlist(int fd)
{
    uint8_t hdr[16];
    size_t totalRead = 0;
    while (totalRead < 16) {
        const ssize_t n = recv(fd, hdr + totalRead, 16 - totalRead, 0);
        if (n <= 0)
            return nil;
        totalRead += static_cast<size_t>(n);
    }
    const uint32_t totalLen = static_cast<uint32_t>(hdr[0]) |
                              (static_cast<uint32_t>(hdr[1]) << 8) |
                              (static_cast<uint32_t>(hdr[2]) << 16) |
                              (static_cast<uint32_t>(hdr[3]) << 24);
    if (totalLen < 16)
        return nil;
    const size_t payloadLen = totalLen - 16;
    if (payloadLen == 0)
        return @{};

    std::vector<uint8_t> payloadBuf(payloadLen);
    size_t payloadRead = 0;
    while (payloadRead < payloadLen) {
        const ssize_t n = recv(fd, payloadBuf.data() + payloadRead, payloadLen - payloadRead, 0);
        if (n <= 0)
            return nil;
        payloadRead += static_cast<size_t>(n);
    }
    NSData *data = [NSData dataWithBytes:payloadBuf.data() length:payloadBuf.size()];
    NSError *error = nil;
    NSDictionary *dict = [NSPropertyListSerialization propertyListWithData:data
                                                                   options:0
                                                                    format:nil
                                                                     error:&error];
    return [dict isKindOfClass:[NSDictionary class]] ? dict : nil;
}

} // namespace

std::vector<std::string> getDiscoveredDevices()
{
    std::lock_guard<std::mutex> lock(gDevicesMutex);
    return gDiscoveredDevices;
}

void registerDiscoveredDevice(const std::string &name)
{
    if (name.empty() || name == "Auto" || name == "-")
        return;
    std::lock_guard<std::mutex> lock(gDevicesMutex);
    if (std::find(gDiscoveredDevices.begin(), gDiscoveredDevices.end(), name) == gDiscoveredDevices.end()) {
        gDiscoveredDevices.push_back(name);
    }
}

struct NetworkReceiver::Impl {
    dispatch_queue_t queue = dispatch_queue_create("iphonecam.obs.receiver", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t readSource = nullptr;
    dispatch_source_t timeoutSource = nullptr;
    DNSServiceRef bonjourService = nullptr;
    int socketFd = -1;
    uint16_t port = 0;
    std::string currentReceiverName;
    std::string targetDevice;
    std::string activeEndpoint;
    sockaddr_storage activeAddress = {};
    socklen_t activeAddressLength = 0;
    std::chrono::steady_clock::time_point lastPacketAt;
    PacketCallback onPacket;
    StatusCallback onStatus;

    bool isRunning = false;
    bool isUsbConnected = false;
    int usbDeviceID = -1;
    std::string usbDeviceName;
    std::string connectedDeviceName;

    ~Impl()
    {
        stop();
        dispatch_sync(queue, ^{
            onPacket = nullptr;
            onStatus = nullptr;
        });
    }

    void publishStatus(const std::string &status, uint16_t port = 0)
    {
        if (onStatus)
            onStatus(status, port);
    }

    void setTargetDevice(std::string target);
    void start(const std::string &receiverName);
    void stop();

    void updateBonjourTxt(bool isBusy)
    {
        if (!bonjourService)
            return;

        TXTRecordRef txtRecord;
        TXTRecordCreate(&txtRecord, 0, nullptr);
        const std::string tgt = targetDevice.empty() ? "*" : targetDevice;
        TXTRecordSetValue(&txtRecord, "target", static_cast<uint8_t>(tgt.length()), tgt.c_str());
        const char *busyVal = isBusy ? "1" : "0";
        TXTRecordSetValue(&txtRecord, "busy", 1, busyVal);
        const std::string &dev = isUsbConnected ? usbDeviceName : connectedDeviceName;
        if (!dev.empty()) {
            TXTRecordSetValue(&txtRecord, "device", static_cast<uint8_t>(dev.length()), dev.c_str());
        }

        DNSServiceUpdateRecord(bonjourService, nullptr, 0, TXTRecordGetLength(&txtRecord),
                               TXTRecordGetBytesPtr(&txtRecord), 0);
        TXTRecordDeallocate(&txtRecord);
    }

    void onUsbConnected(int devID, std::string name)
    {
        dispatch_async(queue, ^{
            isUsbConnected = true;
            usbDeviceID = devID;
            usbDeviceName = std::move(name);
            updateBonjourTxt(true);
            publishStatus("Connected to " + usbDeviceName + " via USB Cable", port);
        });
    }

    void onUsbDisconnected()
    {
        dispatch_async(queue, ^{
            isUsbConnected = false;
            usbDeviceID = -1;
            usbDeviceName.clear();
            updateBonjourTxt(!activeEndpoint.empty());
            publishStatus(activeEndpoint.empty() ? "Waiting for iPhone" : ("Connected: " + activeEndpoint), port);
        });
    }

    void dispatchPacket(std::shared_ptr<std::vector<uint8_t>> packet)
    {
        if (!packet)
            return;
        dispatch_async(queue, ^{
            if (onPacket && packet)
                onPacket(*packet);
        });
    }

    void dispatchPacket(const std::vector<uint8_t> &data)
    {
        auto packet = std::make_shared<std::vector<uint8_t>>(data);
        dispatchPacket(packet);
    }

    void sendControlCommand(const ControlCommand &command);

    bool publishBonjour(const std::string &receiverName, uint16_t servicePort, const std::string &target)
    {
        if (bonjourService) {
            DNSServiceRefDeallocate(bonjourService);
            bonjourService = nullptr;
        }

        TXTRecordRef txtRecord;
        TXTRecordCreate(&txtRecord, 0, nullptr);
        const std::string tgt = target.empty() ? "*" : target;
        TXTRecordSetValue(&txtRecord, "target", static_cast<uint8_t>(tgt.length()), tgt.c_str());
        const bool isBusy = isUsbConnected || !activeEndpoint.empty();
        const char *busyVal = isBusy ? "1" : "0";
        TXTRecordSetValue(&txtRecord, "busy", 1, busyVal);
        const std::string &dev = isUsbConnected ? usbDeviceName : connectedDeviceName;
        if (!dev.empty()) {
            TXTRecordSetValue(&txtRecord, "device", static_cast<uint8_t>(dev.length()), dev.c_str());
        }

        const DNSServiceErrorType error = DNSServiceRegister(
            &bonjourService, 0, 0, receiverName.c_str(), "_iphonecam._udp.", nullptr, nullptr, htons(servicePort),
            TXTRecordGetLength(&txtRecord), TXTRecordGetBytesPtr(&txtRecord),
            [](DNSServiceRef, DNSServiceFlags, DNSServiceErrorType errorCode, const char *name, const char *,
               const char *, void *) {
              if (errorCode == kDNSServiceErr_NoError) {
                  blog(LOG_INFO, "[iPhoneCam] OBS Bonjour service registered as '%s'", name ? name : "iPhoneCam OBS");
              } else {
                  blog(LOG_ERROR, "[iPhoneCam] OBS Bonjour registration callback error: %d", int(errorCode));
              }
            },
            nullptr);

        TXTRecordDeallocate(&txtRecord);
        return error == kDNSServiceErr_NoError;
    }

    void receiveAvailable()
    {
        std::array<uint8_t, 4096> buffer = {};
        for (;;) {
            sockaddr_storage sender = {};
            socklen_t senderLength = sizeof(sender);
            const ssize_t bytesRead =
                recvfrom(socketFd, buffer.data(), buffer.size(), 0, reinterpret_cast<sockaddr *>(&sender), &senderLength);
            if (bytesRead < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK)
                    break;
                blog(LOG_WARNING, "[iPhoneCam] OBS UDP recvfrom failed: %s", std::strerror(errno));
                break;
            }
            if (bytesRead == 0)
                continue;

            if (isUsbConnected) {
                continue;
            }

            auto parsed = parsePacket(buffer.data(), static_cast<size_t>(bytesRead));
            if (parsed && parsed->kind == PacketKind::Hello) {
                auto hello = parseHelloPayload(parsed->payload);
                if (hello) {
                    registerDiscoveredDevice(hello->deviceName);
                    if (!targetDevice.empty() && hello->deviceName != targetDevice) {
                        continue;
                    }
                    if (connectedDeviceName != hello->deviceName) {
                        connectedDeviceName = hello->deviceName;
                        updateBonjourTxt(true);
                    }
                }
            }

            const std::string endpoint = endpointDescription(sender, senderLength);
            const auto now = std::chrono::steady_clock::now();
            if (activeEndpoint.empty()) {
                activeEndpoint = endpoint;
                activeAddress = sender;
                activeAddressLength = senderLength;
                lastPacketAt = now;
                updateBonjourTxt(true);
                blog(LOG_INFO, "[iPhoneCam] OBS receiver accepted iPhone endpoint %s", activeEndpoint.c_str());
                publishStatus("Connected: " + activeEndpoint, port);
            } else if (endpoint != activeEndpoint) {
                if (now - lastPacketAt > kEndpointTimeout) {
                    blog(LOG_INFO, "[iPhoneCam] OBS receiver accepted reconnect endpoint %s (previous %s)",
                         endpoint.c_str(), activeEndpoint.c_str());
                    activeEndpoint = endpoint;
                    activeAddress = sender;
                    activeAddressLength = senderLength;
                    lastPacketAt = now;
                    updateBonjourTxt(true);
                    publishStatus("Connected: " + activeEndpoint, port);
                } else {
                    blog(LOG_INFO, "[iPhoneCam] OBS receiver ignored second endpoint %s", endpoint.c_str());
                    continue;
                }
            } else {
                lastPacketAt = now;
            }

            if (onPacket) {
                onPacket(std::vector<uint8_t>(buffer.begin(), buffer.begin() + bytesRead));
            }
        }
    }

    void startTimeoutTimer()
    {
        timeoutSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(timeoutSource, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC * 500),
                                  NSEC_PER_MSEC * 500, NSEC_PER_MSEC * 100);
        dispatch_source_set_event_handler(timeoutSource, ^{
          checkEndpointTimeout();
        });
        dispatch_resume(timeoutSource);
    }

    void checkEndpointTimeout()
    {
        if (isUsbConnected)
            return;

        if (activeEndpoint.empty() || lastPacketAt.time_since_epoch().count() == 0)
            return;

        const auto now = std::chrono::steady_clock::now();
        if (now - lastPacketAt <= kEndpointTimeout)
            return;

        blog(LOG_INFO, "[iPhoneCam] OBS receiver endpoint timed out: %s", activeEndpoint.c_str());
        activeEndpoint.clear();
        connectedDeviceName.clear();
        activeAddress = {};
        activeAddressLength = 0;
        lastPacketAt = {};
        updateBonjourTxt(isUsbConnected);
        publishStatus("Waiting for iPhone", port);
    }

    void fail(const std::string &message)
    {
        blog(LOG_ERROR, "[iPhoneCam] OBS receiver error: %s", message.c_str());
        publishStatus("Receiver failed: " + message, 0);
    }
};

// MARK: - UsbmuxDeviceManager (Shared Multi-Device Manager)

struct UsbmuxDevice {
    int deviceID = -1;
    std::string serialNumber;
    std::string deviceName;
    int streamFd = -1;
    bool isConnecting = false;
    NetworkReceiver::Impl *owner = nullptr;
    std::vector<uint8_t> rxBuffer;
};

struct RegisteredReceiver {
    NetworkReceiver::Impl *impl = nullptr;
    std::string targetDevice;
};

class UsbmuxDeviceManager {
public:
    static UsbmuxDeviceManager &instance()
    {
        static UsbmuxDeviceManager s_instance;
        return s_instance;
    }

    bool isReceiverAssigned(NetworkReceiver::Impl *receiver) const
    {
        for (const auto &pair : devices_) {
            if (pair.second.owner == receiver && pair.second.streamFd >= 0)
                return true;
        }
        return false;
    }

    void registerReceiver(NetworkReceiver::Impl *receiver, std::string targetDevice)
    {
        dispatch_sync(queue_, ^{
            auto it = std::find_if(receivers_.begin(), receivers_.end(),
                                   [receiver](const RegisteredReceiver &r) { return r.impl == receiver; });
            if (it == receivers_.end()) {
                receivers_.push_back({receiver, std::move(targetDevice)});
            } else {
                it->targetDevice = std::move(targetDevice);
            }
            startListeningIfNeeded();
            reevaluateAssignments();
        });
    }

    void unregisterReceiver(NetworkReceiver::Impl *receiver)
    {
        dispatch_sync(queue_, ^{
            for (auto &pair : devices_) {
                if (pair.second.owner == receiver) {
                    pair.second.owner = nullptr;
                }
            }
            receivers_.erase(
                std::remove_if(receivers_.begin(), receivers_.end(),
                               [receiver](const RegisteredReceiver &r) { return r.impl == receiver; }),
                receivers_.end());
            reevaluateAssignments();
        });
    }

    void setReceiverTarget(NetworkReceiver::Impl *receiver, std::string targetDevice)
    {
        dispatch_sync(queue_, ^{
            for (auto &r : receivers_) {
                if (r.impl == receiver) {
                    if (r.targetDevice != targetDevice) {
                        r.targetDevice = std::move(targetDevice);
                        for (auto &pair : devices_) {
                            if (pair.second.owner == receiver) {
                                if (!r.targetDevice.empty() && pair.second.deviceName != r.targetDevice) {
                                    pair.second.owner = nullptr;
                                    receiver->onUsbDisconnected();
                                }
                            }
                        }
                    }
                    break;
                }
            }
            reevaluateAssignments();
        });
    }

    bool sendControlCommand(NetworkReceiver::Impl *receiver, const ControlCommand &command)
    {
        __block bool sent = false;
        dispatch_sync(queue_, ^{
            for (auto &pair : devices_) {
                if (pair.second.owner == receiver && pair.second.streamFd >= 0) {
                    CameraPacket packet;
                    packet.kind = PacketKind::Control;
                    packet.streamId = 1;
                    packet.payload = encodeControlPayload(command);
                    const auto encoded = encodePacket(packet);

                    const uint32_t lengthBE = htonl(static_cast<uint32_t>(encoded.size()));
                    std::vector<uint8_t> framed(4 + encoded.size());
                    std::memcpy(framed.data(), &lengthBE, 4);
                    std::memcpy(framed.data() + 4, encoded.data(), encoded.size());

                    const ssize_t n = send(pair.second.streamFd, framed.data(), framed.size(), 0);
                    if (n > 0) {
                        sent = true;
                    }
                    break;
                }
            }
        });
        return sent;
    }

private:
    UsbmuxDeviceManager() = default;

    void startListeningIfNeeded()
    {
        if (isListening_)
            return;
        isListening_ = true;

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            int lfd = connectUsbmuxd();
            if (lfd < 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2000 * NSEC_PER_MSEC), queue_, ^{
                    isListening_ = false;
                    if (!receivers_.empty())
                        startListeningIfNeeded();
                });
                return;
            }

            NSDictionary *listenMsg = @{
                @"MessageType": @"Listen",
                @"ClientVersionString": @"iPhoneCam",
                @"ProgName": @"iPhoneCam"
            };

            if (!sendUsbmuxPlist(lfd, listenMsg)) {
                close(lfd);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2000 * NSEC_PER_MSEC), queue_, ^{
                    isListening_ = false;
                    if (!receivers_.empty())
                        startListeningIfNeeded();
                });
                return;
            }

            dispatch_async(queue_, ^{
                listenFd_ = lfd;
                blog(LOG_INFO, "[iPhoneCam] OBS UsbmuxDeviceManager listening on /var/run/usbmuxd");

                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    while (listenFd_ == lfd) {
                        NSDictionary *plist = readUsbmuxPlist(lfd);
                        if (!plist)
                            break;
                        dispatch_async(queue_, ^{
                            if (listenFd_ == lfd) {
                                handleListenPlist(plist);
                            }
                        });
                    }
                    dispatch_async(queue_, ^{
                        if (listenFd_ == lfd) {
                            close(lfd);
                            listenFd_ = -1;
                            isListening_ = false;
                            if (!receivers_.empty())
                                startListeningIfNeeded();
                        }
                    });
                });
            });
        });
    }

    void handleListenPlist(NSDictionary *plist)
    {
        NSString *msgType = plist[@"MessageType"];
        if (!msgType)
            return;

        if ([msgType isEqualToString:@"Attached"]) {
            NSNumber *devID = plist[@"DeviceID"];
            NSDictionary *props = plist[@"Properties"];
            NSString *connType = props[@"ConnectionType"];
            if (devID && [connType isEqualToString:@"USB"]) {
                const int idVal = devID.intValue;
                NSString *serial = props[@"SerialNumber"] ?: @"";
                UsbmuxDevice dev;
                dev.deviceID = idVal;
                dev.serialNumber = [serial UTF8String];
                dev.isConnecting = false;
                devices_[idVal] = dev;
                blog(LOG_INFO, "[iPhoneCam] UsbmuxDeviceManager detected USB device %d", idVal);
                tryConnectDevice(idVal);
            }
        } else if ([msgType isEqualToString:@"Detached"]) {
            NSNumber *devID = plist[@"DeviceID"];
            if (devID) {
                const int idVal = devID.intValue;
                auto it = devices_.find(idVal);
                if (it != devices_.end()) {
                    blog(LOG_INFO, "[iPhoneCam] UsbmuxDeviceManager detached USB device %d", idVal);
                    if (it->second.owner) {
                        it->second.owner->onUsbDisconnected();
                        it->second.owner = nullptr;
                    }
                    if (it->second.streamFd >= 0) {
                        close(it->second.streamFd);
                    }
                    devices_.erase(it);
                    reevaluateAssignments();
                }
            }
        }
    }

    void tryConnectDevice(int devID)
    {
        auto it = devices_.find(devID);
        if (it == devices_.end() || it->second.streamFd >= 0 || it->second.isConnecting)
            return;

        it->second.isConnecting = true;

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            int cfd = connectUsbmuxd();
            if (cfd < 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), queue_, ^{
                    auto dit = devices_.find(devID);
                    if (dit != devices_.end()) {
                        dit->second.isConnecting = false;
                        if (dit->second.streamFd < 0) {
                            tryConnectDevice(devID);
                        }
                    }
                });
                return;
            }

            const uint16_t portBE = htons(8240);
            NSDictionary *connectMsg = @{
                @"MessageType": @"Connect",
                @"ClientVersionString": @"iPhoneCam",
                @"ProgName": @"iPhoneCam",
                @"DeviceID": @(devID),
                @"PortNumber": @(portBE)
            };

            if (!sendUsbmuxPlist(cfd, connectMsg)) {
                close(cfd);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), queue_, ^{
                    auto dit = devices_.find(devID);
                    if (dit != devices_.end()) {
                        dit->second.isConnecting = false;
                        if (dit->second.streamFd < 0) {
                            tryConnectDevice(devID);
                        }
                    }
                });
                return;
            }

            NSDictionary *resp = readUsbmuxPlist(cfd);
            NSNumber *num = resp[@"Number"];
            if (!num || num.intValue != 0) {
                close(cfd);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), queue_, ^{
                    auto dit = devices_.find(devID);
                    if (dit != devices_.end()) {
                        dit->second.isConnecting = false;
                        if (dit->second.streamFd < 0) {
                            tryConnectDevice(devID);
                        }
                    }
                });
                return;
            }

            dispatch_async(queue_, ^{
                auto dit = devices_.find(devID);
                if (dit == devices_.end()) {
                    close(cfd);
                    return;
                }
                dit->second.isConnecting = false;
                dit->second.streamFd = cfd;
                dit->second.rxBuffer.clear();
                blog(LOG_INFO, "[iPhoneCam] UsbmuxDeviceManager connected stream for device %d", devID);
                reevaluateAssignments();

                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                    readStreamLoop(cfd, devID);
                });
            });
        });
    }

    void readStreamLoop(int fd, int devID)
    {
        std::vector<uint8_t> readBuf(65536);
        while (true) {
            const ssize_t n = recv(fd, readBuf.data(), readBuf.size(), 0);
            if (n <= 0)
                break;
            std::vector<uint8_t> chunk(readBuf.begin(), readBuf.begin() + n);
            dispatch_async(queue_, ^{
                auto it = devices_.find(devID);
                if (it == devices_.end() || it->second.streamFd != fd)
                    return;
                auto &dev = it->second;
                dev.rxBuffer.insert(dev.rxBuffer.end(), chunk.begin(), chunk.end());

                while (dev.rxBuffer.size() >= 4) {
                    const uint32_t len = (static_cast<uint32_t>(dev.rxBuffer[0]) << 24) |
                                         (static_cast<uint32_t>(dev.rxBuffer[1]) << 16) |
                                         (static_cast<uint32_t>(dev.rxBuffer[2]) << 8) |
                                         static_cast<uint32_t>(dev.rxBuffer[3]);
                    if (len > 10 * 1024 * 1024) {
                        dev.rxBuffer.clear();
                        break;
                    }
                    const size_t totalLength = 4 + static_cast<size_t>(len);
                    if (dev.rxBuffer.size() < totalLength)
                        break;

                    auto packetData = std::make_shared<std::vector<uint8_t>>(
                        dev.rxBuffer.begin() + 4, dev.rxBuffer.begin() + totalLength);
                    dev.rxBuffer.erase(dev.rxBuffer.begin(), dev.rxBuffer.begin() + totalLength);

                    auto parsed = parsePacket(packetData->data(), packetData->size());
                    if (parsed && parsed->kind == PacketKind::Hello) {
                        auto hello = parseHelloPayload(parsed->payload);
                        if (hello) {
                            dev.deviceName = hello->deviceName;
                            registerDiscoveredDevice(hello->deviceName);
                            reevaluateAssignments();
                        }
                    }

                    if (dev.owner) {
                        dev.owner->dispatchPacket(packetData);
                    }
                }
            });
        }

        dispatch_async(queue_, ^{
            auto it = devices_.find(devID);
            if (it != devices_.end() && it->second.streamFd == fd) {
                close(fd);
                it->second.streamFd = -1;
                it->second.isConnecting = false;
                it->second.rxBuffer.clear();
                if (it->second.owner) {
                    it->second.owner->onUsbDisconnected();
                    it->second.owner = nullptr;
                }
                reevaluateAssignments();
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), queue_, ^{
                    auto ret = devices_.find(devID);
                    if (ret != devices_.end() && ret->second.streamFd < 0 && !ret->second.isConnecting) {
                        tryConnectDevice(devID);
                    }
                });
            }
        });
    }

    void reevaluateAssignments()
    {
        // 1. Check existing owners
        for (auto &pair : devices_) {
            auto &dev = pair.second;
            if (dev.owner) {
                auto it = std::find_if(receivers_.begin(), receivers_.end(),
                                       [&dev](const RegisteredReceiver &r) { return r.impl == dev.owner; });
                if (it == receivers_.end()) {
                    dev.owner = nullptr;
                } else if (!it->targetDevice.empty() && dev.deviceName != it->targetDevice) {
                    dev.owner = nullptr;
                    it->impl->onUsbDisconnected();
                }
            }
        }

        // 2. Assign exact target matches
        for (auto &r : receivers_) {
            if (isReceiverAssigned(r.impl) || r.targetDevice.empty())
                continue;
            for (auto &pair : devices_) {
                auto &dev = pair.second;
                if (dev.owner == nullptr && dev.streamFd >= 0 && dev.deviceName == r.targetDevice) {
                    dev.owner = r.impl;
                    r.impl->onUsbConnected(dev.deviceID, dev.deviceName);
                    break;
                }
            }
        }

        // 3. Assign wildcard / Auto receivers
        for (auto &r : receivers_) {
            if (isReceiverAssigned(r.impl) || !r.targetDevice.empty())
                continue;
            for (auto &pair : devices_) {
                auto &dev = pair.second;
                if (dev.owner == nullptr && dev.streamFd >= 0) {
                    dev.owner = r.impl;
                    r.impl->onUsbConnected(dev.deviceID, dev.deviceName.empty() ? "iPhone" : dev.deviceName);
                    break;
                }
            }
        }
    }

    dispatch_queue_t queue_ = dispatch_queue_create("iphonecam.obs.usbmux_manager", DISPATCH_QUEUE_SERIAL);
    bool isListening_ = false;
    int listenFd_ = -1;
    std::map<int, UsbmuxDevice> devices_;
    std::vector<RegisteredReceiver> receivers_;
};

void NetworkReceiver::Impl::setTargetDevice(std::string target)
{
    dispatch_async(queue, ^{
        if (targetDevice == target)
            return;
        targetDevice = std::move(target);
        if (socketFd >= 0 && port > 0) {
            publishBonjour(currentReceiverName, port, targetDevice);
        }
        if (isRunning) {
            UsbmuxDeviceManager::instance().setReceiverTarget(this, targetDevice);
        }
    });
}

void NetworkReceiver::Impl::start(const std::string &receiverName)
{
    stop();
    isRunning = true;
    currentReceiverName = receiverName;

    int fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) {
        fail(errnoDescription("socket"));
        return;
    }

    const int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    const int receiveBufferSize = 4 * 1024 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBufferSize, sizeof(receiveBufferSize));
    const int no = 0;
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof(no));

    sockaddr_in6 address = {};
    address.sin6_family = AF_INET6;
    address.sin6_addr = in6addr_any;
    address.sin6_port = 0;
    if (bind(fd, reinterpret_cast<const sockaddr *>(&address), sizeof(address)) < 0) {
        const std::string message = errnoDescription("bind");
        close(fd);
        fail(message);
        return;
    }

    sockaddr_in6 boundAddress = {};
    socklen_t boundLength = sizeof(boundAddress);
    if (getsockname(fd, reinterpret_cast<sockaddr *>(&boundAddress), &boundLength) < 0) {
        const std::string message = errnoDescription("getsockname");
        close(fd);
        fail(message);
        return;
    }

    if (fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK) < 0) {
        const std::string message = errnoDescription("fcntl");
        close(fd);
        fail(message);
        return;
    }

    socketFd = fd;
    port = ntohs(boundAddress.sin6_port);
    if (!publishBonjour(receiverName, port, targetDevice)) {
        close(socketFd);
        socketFd = -1;
        port = 0;
        return;
    }

    const int sourceFd = socketFd;
    readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, static_cast<uintptr_t>(sourceFd), 0, queue);
    dispatch_source_set_event_handler(readSource, ^{
      receiveAvailable();
    });
    dispatch_source_set_cancel_handler(readSource, ^{
      close(sourceFd);
    });
    dispatch_resume(readSource);
    startTimeoutTimer();

    blog(LOG_INFO, "[iPhoneCam] OBS UDP receiver listening as '%s' on port %u (target: '%s')",
         receiverName.c_str(), port, targetDevice.c_str());
    publishStatus("Waiting for iPhone", port);

    UsbmuxDeviceManager::instance().registerReceiver(this, targetDevice);
}

void NetworkReceiver::Impl::stop()
{
    isRunning = false;
    UsbmuxDeviceManager::instance().unregisterReceiver(this);
    isUsbConnected = false;
    usbDeviceID = -1;
    usbDeviceName.clear();

    if (timeoutSource) {
        dispatch_source_cancel(timeoutSource);
        timeoutSource = nullptr;
    }
    if (readSource) {
        dispatch_source_cancel(readSource);
        readSource = nullptr;
        socketFd = -1;
    } else if (socketFd >= 0) {
        close(socketFd);
        socketFd = -1;
    }
    if (bonjourService) {
        DNSServiceRefDeallocate(bonjourService);
        bonjourService = nullptr;
    }

    // Flush any pending blocks on receiver queue
    dispatch_sync(queue, ^{});

    port = 0;
    activeEndpoint.clear();
    connectedDeviceName.clear();
    activeAddress = {};
    activeAddressLength = 0;
    lastPacketAt = {};
}

void NetworkReceiver::Impl::sendControlCommand(const ControlCommand &command)
{
    if (UsbmuxDeviceManager::instance().sendControlCommand(this, command)) {
        return;
    }

    const ControlCommand commandCopy = command;
    dispatch_async(queue, ^{
        if (socketFd < 0 || activeEndpoint.empty() || activeAddressLength == 0) {
            blog(LOG_WARNING, "[iPhoneCam] Cannot send control command before an iPhone endpoint is connected");
            return;
        }

        CameraPacket packet;
        packet.kind = PacketKind::Control;
        packet.streamId = 1;
        packet.payload = encodeControlPayload(commandCopy);
        const auto encoded = encodePacket(packet);

        const ssize_t sent =
            sendto(socketFd, encoded.data(), encoded.size(), 0, reinterpret_cast<const sockaddr *>(&activeAddress),
                   activeAddressLength);
        if (sent < 0) {
            blog(LOG_WARNING, "[iPhoneCam] Failed to send control command to %s: %s", activeEndpoint.c_str(),
                 std::strerror(errno));
        }
    });
}

NetworkReceiver::NetworkReceiver() : impl_(new Impl()) {}

NetworkReceiver::~NetworkReceiver()
{
    delete impl_;
}

void NetworkReceiver::setPacketCallback(PacketCallback callback)
{
    impl_->onPacket = std::move(callback);
}

void NetworkReceiver::setStatusCallback(StatusCallback callback)
{
    impl_->onStatus = std::move(callback);
}

void NetworkReceiver::setTargetDevice(const std::string &targetDevice)
{
    impl_->setTargetDevice(targetDevice);
}

void NetworkReceiver::start(const std::string &receiverName)
{
    impl_->start(receiverName);
}

void NetworkReceiver::stop()
{
    impl_->stop();
}

void NetworkReceiver::sendControlCommand(const ControlCommand &command)
{
    impl_->sendControlCommand(command);
}

} // namespace iphonecam
