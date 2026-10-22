#include "network_receiver.hpp"
#include "protocol.hpp"
#include "stream_support.hpp"

#include <util/base.h>

#include <arpa/inet.h>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <dns_sd.h>
#include <fcntl.h>
#include <map>
#include <memory>
#include <mutex>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <set>
#include <string>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <thread>
#include <unistd.h>
#include <vector>

#import <Foundation/Foundation.h>

namespace iphonecam {
namespace {

constexpr auto kConnectTimeout = std::chrono::milliseconds(3000);
constexpr auto kRetryDelay = std::chrono::milliseconds(1000);
// The iPhone pings every 2 s, so this much silence means the link is gone even if TCP has not noticed yet.
constexpr auto kIdleTimeout = std::chrono::milliseconds(6000);
constexpr auto kWaitForSettingsChange = std::chrono::hours(24);

std::mutex gDevicesMutex;
std::vector<std::string> gDiscoveredDevices;

std::string localComputerName()
{
    @autoreleasepool {
        NSString *name = [[NSHost currentHost] localizedName];
        return name ? std::string(name.UTF8String) : std::string("Mac");
    }
}

std::vector<uint8_t> framedControl(const ControlCommand &command)
{
    CameraPacket packet;
    packet.kind = PacketKind::Control;
    packet.streamId = 1;
    packet.payload = encodeControlPayload(command);
    return encodeFramedPacket(packet);
}

std::vector<uint8_t> framedIdentify(const char *transport)
{
    ControlCommand command;
    command.action = ControlAction::Identify;
    command.transport = transport;
    command.clientName = "OBS on " + localComputerName();
    return framedControl(command);
}

// Small control packets only; a send timeout keeps a stalled peer from blocking a caller for long.
void setSendTimeout(int fd)
{
    timeval timeout = {};
    timeout.tv_sec = 1;
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
}

void configureStreamSocket(int fd, bool tcp)
{
    const int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    const int receiveBuffer = 4 * 1024 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, sizeof(receiveBuffer));
    setSendTimeout(fd);
    if (!tcp)
        return;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
    // Without keepalive a silently dead link (Wi-Fi drop, no RST) looks connected for minutes.
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &yes, sizeof(yes));
    const int idle = 5;
    const int interval = 5;
    const int count = 2;
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle, sizeof(idle));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &interval, sizeof(interval));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &count, sizeof(count));
}

bool sendAll(int fd, const std::vector<uint8_t> &data)
{
    size_t sent = 0;
    while (sent < data.size()) {
        const ssize_t n = send(fd, data.data() + sent, data.size() - sent, 0);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            return false;
        sent += size_t(n);
    }
    return true;
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
    const uint32_t totalLen = static_cast<uint32_t>(hdr[0]) | (static_cast<uint32_t>(hdr[1]) << 8) |
                              (static_cast<uint32_t>(hdr[2]) << 16) | (static_cast<uint32_t>(hdr[3]) << 24);
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
    NSDictionary *dict = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:&error];
    return [dict isKindOfClass:[NSDictionary class]] ? dict : nil;
}

// MARK: - PhoneDiscovery (Bonjour browse of iPhones running the stream listener)

class PhoneDiscovery {
public:
    static PhoneDiscovery &instance()
    {
        static PhoneDiscovery discovery;
        return discovery;
    }

    void start()
    {
        dispatch_async(queue_, ^{
          if (browseRef_)
              return;
          DNSServiceRef ref = nullptr;
          const DNSServiceErrorType error =
              DNSServiceBrowse(&ref, 0, kDNSServiceInterfaceIndexAny, kPhoneServiceType, nullptr, browseReply, this);
          if (error != kDNSServiceErr_NoError) {
              blog(LOG_WARNING, "[iPhoneCam] Bonjour browse for iPhones failed: %d", int(error));
              return;
          }
          DNSServiceSetDispatchQueue(ref, queue_);
          browseRef_ = ref;
        });
    }

    void stop()
    {
        dispatch_sync(queue_, ^{
          if (browseRef_) {
              DNSServiceRefDeallocate(browseRef_);
              browseRef_ = nullptr;
          }
          std::lock_guard<std::mutex> lock(mutex_);
          for (auto &entry : phones_)
              release(entry.second);
          phones_.clear();
        });
    }

    std::vector<std::string> names() const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        std::vector<std::string> result;
        for (const auto &entry : phones_)
            result.push_back(entry.first);
        return result;
    }

    std::optional<HostPort> lookup(const std::string &name) const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto it = phones_.find(name);
        if (it == phones_.end() || it->second.port == 0)
            return std::nullopt;
        const auto &phone = it->second;
        if (!phone.address.empty())
            return HostPort{phone.address, phone.port};
        if (!phone.hostTarget.empty())
            return HostPort{phone.hostTarget, phone.port};
        return std::nullopt;
    }

private:
    struct Context {
        PhoneDiscovery *owner;
        std::string name;
    };

    struct Phone {
        std::set<uint32_t> interfaces;
        std::string hostTarget;
        std::string address;
        uint16_t port = 0;
        DNSServiceRef resolveRef = nullptr;
        DNSServiceRef addressRef = nullptr;
        Context *context = nullptr;
    };

    PhoneDiscovery() = default;

    // Callers hold mutex_; runs on queue_.
    static void release(Phone &phone)
    {
        if (phone.resolveRef) {
            DNSServiceRefDeallocate(phone.resolveRef);
            phone.resolveRef = nullptr;
        }
        if (phone.addressRef) {
            DNSServiceRefDeallocate(phone.addressRef);
            phone.addressRef = nullptr;
        }
        delete phone.context;
        phone.context = nullptr;
    }

    static void DNSSD_API browseReply(DNSServiceRef, DNSServiceFlags flags, uint32_t interfaceIndex,
                                      DNSServiceErrorType error, const char *serviceName, const char *regtype,
                                      const char *replyDomain, void *context)
    {
        auto *self = static_cast<PhoneDiscovery *>(context);
        if (error != kDNSServiceErr_NoError || !serviceName)
            return;
        const std::string name(serviceName);
        std::lock_guard<std::mutex> lock(self->mutex_);
        if (flags & kDNSServiceFlagsAdd) {
            auto &phone = self->phones_[name];
            const bool first = phone.interfaces.empty();
            phone.interfaces.insert(interfaceIndex);
            if (!first)
                return;
            phone.context = new Context{self, name};
            DNSServiceRef ref = nullptr;
            if (DNSServiceResolve(&ref, 0, interfaceIndex, serviceName, regtype, replyDomain, resolveReply,
                                  phone.context) == kDNSServiceErr_NoError) {
                DNSServiceSetDispatchQueue(ref, self->queue_);
                phone.resolveRef = ref;
            }
            return;
        }

        const auto it = self->phones_.find(name);
        if (it == self->phones_.end())
            return;
        it->second.interfaces.erase(interfaceIndex);
        if (it->second.interfaces.empty()) {
            release(it->second);
            self->phones_.erase(it);
        }
    }

    static void DNSSD_API resolveReply(DNSServiceRef, DNSServiceFlags, uint32_t interfaceIndex,
                                       DNSServiceErrorType error, const char *, const char *hostTarget,
                                       uint16_t portNetworkOrder, uint16_t, const unsigned char *, void *context)
    {
        auto *ctx = static_cast<Context *>(context);
        if (error != kDNSServiceErr_NoError || !hostTarget)
            return;
        PhoneDiscovery *self = ctx->owner;
        std::lock_guard<std::mutex> lock(self->mutex_);
        const auto it = self->phones_.find(ctx->name);
        if (it == self->phones_.end() || it->second.context != ctx)
            return;
        auto &phone = it->second;
        phone.hostTarget = hostTarget;
        phone.port = ntohs(portNetworkOrder);
        if (phone.resolveRef) {
            DNSServiceRefDeallocate(phone.resolveRef);
            phone.resolveRef = nullptr;
        }
        if (phone.addressRef) {
            DNSServiceRefDeallocate(phone.addressRef);
            phone.addressRef = nullptr;
        }
        DNSServiceRef ref = nullptr;
        if (DNSServiceGetAddrInfo(&ref, 0, interfaceIndex, kDNSServiceProtocol_IPv4, hostTarget, addressReply, ctx) ==
            kDNSServiceErr_NoError) {
            DNSServiceSetDispatchQueue(ref, self->queue_);
            phone.addressRef = ref;
        }
    }

    static void DNSSD_API addressReply(DNSServiceRef, DNSServiceFlags flags, uint32_t, DNSServiceErrorType error,
                                       const char *, const sockaddr *address, uint32_t, void *context)
    {
        auto *ctx = static_cast<Context *>(context);
        if (error != kDNSServiceErr_NoError || !address || address->sa_family != AF_INET ||
            !(flags & kDNSServiceFlagsAdd))
            return;
        char text[INET_ADDRSTRLEN] = {};
        const auto *ipv4 = reinterpret_cast<const sockaddr_in *>(address);
        if (!inet_ntop(AF_INET, &ipv4->sin_addr, text, sizeof(text)))
            return;
        PhoneDiscovery *self = ctx->owner;
        std::lock_guard<std::mutex> lock(self->mutex_);
        const auto it = self->phones_.find(ctx->name);
        if (it != self->phones_.end() && it->second.context == ctx)
            it->second.address = text;
    }

    dispatch_queue_t queue_ = dispatch_queue_create("iphonecam.obs.discovery", DISPATCH_QUEUE_SERIAL);
    DNSServiceRef browseRef_ = nullptr;
    mutable std::mutex mutex_;
    std::map<std::string, Phone> phones_;
};

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
    if (std::find(gDiscoveredDevices.begin(), gDiscoveredDevices.end(), name) == gDiscoveredDevices.end())
        gDiscoveredDevices.push_back(name);
}

void startPhoneDiscovery()
{
    PhoneDiscovery::instance().start();
}

void stopPhoneDiscovery()
{
    PhoneDiscovery::instance().stop();
}

std::vector<std::string> getDiscoveredPhoneNames()
{
    return PhoneDiscovery::instance().names();
}

struct NetworkReceiver::Impl {
    dispatch_queue_t queue = dispatch_queue_create("iphonecam.obs.receiver", DISPATCH_QUEUE_SERIAL);
    PacketCallback onPacket;
    StatusCallback onStatus;
    // Set by start() before any connection work begins and left alone until stop() has finished.
    ReceiverConfig config;
    std::atomic<bool> isRunning{false};

    // USB state, confined to `queue`.
    bool isUsbConnected = false;
    std::string usbDeviceName;

    // Wi-Fi dial loop.
    std::thread wifiThread;
    std::atomic<bool> wifiRunning{false};
    std::mutex wifiMutex;
    std::condition_variable wifiWake;
    int wifiFd = -1;

    ~Impl()
    {
        stop();
        dispatch_sync(queue, ^{
          onPacket = nullptr;
          onStatus = nullptr;
        });
    }

    void publishStatus(const std::string &status, const std::string &connection, bool connected)
    {
        if (onStatus)
            onStatus(status, connection, connected);
    }

    void dispatchPacket(std::shared_ptr<std::vector<uint8_t>> packet)
    {
        if (!packet)
            return;
        dispatch_async(queue, ^{
          if (isRunning && onPacket && packet)
              onPacket(*packet);
        });
    }

    void start(const ReceiverConfig &next);
    void stop();
    void onUsbConnected(int deviceID, std::string name);
    void onUsbDisconnected();
    void sendFramed(const std::vector<uint8_t> &bytes);

    void wifiLoop(ReceiverConfig settings);
    int dial(const HostPort &target);
    void readWifi(int fd);
    void stopWifi();

    void waitForRetry(std::chrono::milliseconds delay)
    {
        std::unique_lock<std::mutex> lock(wifiMutex);
        wifiWake.wait_for(lock, delay, [this] { return !wifiRunning.load(); });
    }
};

// MARK: - UsbmuxDeviceManager (one usbmuxd listener shared by every source)

struct UsbmuxDevice {
    int deviceID = -1;
    std::string serialNumber;
    std::string deviceName;
    int streamFd = -1;
    bool isConnecting = false;
    NetworkReceiver::Impl *owner = nullptr;
    PacketStreamFramer framer;
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

    void registerReceiver(NetworkReceiver::Impl *receiver, std::string targetDevice)
    {
        dispatch_sync(queue_, ^{
          auto it = std::find_if(receivers_.begin(), receivers_.end(),
                                 [receiver](const RegisteredReceiver &r) { return r.impl == receiver; });
          if (it == receivers_.end()) {
              receivers_.push_back({receiver, targetDevice});
          } else {
              it->targetDevice = targetDevice;
          }
          startListeningIfNeeded();
          reevaluateAssignments();
        });
    }

    void unregisterReceiver(NetworkReceiver::Impl *receiver)
    {
        dispatch_sync(queue_, ^{
          for (auto &pair : devices_) {
              if (pair.second.owner == receiver)
                  pair.second.owner = nullptr;
          }
          receivers_.erase(std::remove_if(receivers_.begin(), receivers_.end(),
                                          [receiver](const RegisteredReceiver &r) { return r.impl == receiver; }),
                           receivers_.end());
          reevaluateAssignments();
        });
    }

    void sendFramed(NetworkReceiver::Impl *receiver, const std::vector<uint8_t> &bytes)
    {
        dispatch_sync(queue_, ^{
          for (auto &pair : devices_) {
              if (pair.second.owner == receiver && pair.second.streamFd >= 0) {
                  sendAll(pair.second.streamFd, bytes);
                  break;
              }
          }
        });
    }

private:
    UsbmuxDeviceManager() = default;

    bool isReceiverAssigned(NetworkReceiver::Impl *receiver) const
    {
        for (const auto &pair : devices_) {
            if (pair.second.owner == receiver && pair.second.streamFd >= 0)
                return true;
        }
        return false;
    }

    void retryListeningLater()
    {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2000 * NSEC_PER_MSEC), queue_, ^{
          isListening_ = false;
          if (!receivers_.empty())
              startListeningIfNeeded();
        });
    }

    void startListeningIfNeeded()
    {
        if (isListening_)
            return;
        isListening_ = true;

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
          int lfd = connectUsbmuxd();
          if (lfd < 0) {
              retryListeningLater();
              return;
          }

          NSDictionary *listenMsg =
              @{@"MessageType" : @"Listen", @"ClientVersionString" : @"iPhoneCam", @"ProgName" : @"iPhoneCam"};
          if (!sendUsbmuxPlist(lfd, listenMsg)) {
              close(lfd);
              retryListeningLater();
              return;
          }

          dispatch_async(queue_, ^{
            listenFd_ = lfd;
            blog(LOG_INFO, "[iPhoneCam] Listening for USB iPhones via /var/run/usbmuxd");

            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
              while (true) {
                  NSDictionary *plist = readUsbmuxPlist(lfd);
                  if (!plist)
                      break;
                  dispatch_async(queue_, ^{
                    if (listenFd_ == lfd)
                        handleListenPlist(plist);
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
                UsbmuxDevice &dev = devices_[idVal];
                dev.deviceID = idVal;
                dev.serialNumber = [serial UTF8String];
                blog(LOG_INFO, "[iPhoneCam] USB iPhone attached (device %d)", idVal);
                tryConnectDevice(idVal);
            }
        } else if ([msgType isEqualToString:@"Detached"]) {
            NSNumber *devID = plist[@"DeviceID"];
            if (!devID)
                return;
            auto it = devices_.find(devID.intValue);
            if (it == devices_.end())
                return;
            blog(LOG_INFO, "[iPhoneCam] USB iPhone detached (device %d)", devID.intValue);
            if (it->second.owner) {
                it->second.owner->onUsbDisconnected();
                it->second.owner = nullptr;
            }
            if (it->second.streamFd >= 0)
                close(it->second.streamFd);
            devices_.erase(it);
            reevaluateAssignments();
        }
    }

    void retryConnectLater(int devID)
    {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), queue_, ^{
          auto it = devices_.find(devID);
          if (it == devices_.end())
              return;
          it->second.isConnecting = false;
          if (it->second.streamFd < 0)
              tryConnectDevice(devID);
        });
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
              retryConnectLater(devID);
              return;
          }

          NSDictionary *connectMsg = @{
              @"MessageType" : @"Connect",
              @"ClientVersionString" : @"iPhoneCam",
              @"ProgName" : @"iPhoneCam",
              @"DeviceID" : @(devID),
              @"PortNumber" : @(htons(kStreamPort))
          };
          NSDictionary *resp = sendUsbmuxPlist(cfd, connectMsg) ? readUsbmuxPlist(cfd) : nil;
          NSNumber *num = resp[@"Number"];
          if (!num || num.intValue != 0) {
              // The app is not listening yet (not open, or still starting); keep trying.
              close(cfd);
              retryConnectLater(devID);
              return;
          }

          configureStreamSocket(cfd, false);
          dispatch_async(queue_, ^{
            auto dit = devices_.find(devID);
            if (dit == devices_.end()) {
                close(cfd);
                return;
            }
            dit->second.isConnecting = false;
            dit->second.streamFd = cfd;
            dit->second.framer.reset();
            blog(LOG_INFO, "[iPhoneCam] USB stream connected (device %d)", devID);
            reevaluateAssignments();

            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
              readStreamLoop(cfd, devID);
            });
          });
        });
    }

    void readStreamLoop(int fd, int devID)
    {
        std::vector<uint8_t> readBuf(256 * 1024);
        while (true) {
            const ssize_t n = recv(fd, readBuf.data(), readBuf.size(), 0);
            if (n < 0 && errno == EINTR)
                continue;
            if (n <= 0)
                break;
            auto chunk = std::make_shared<std::vector<uint8_t>>(readBuf.begin(), readBuf.begin() + n);
            dispatch_async(queue_, ^{
              auto it = devices_.find(devID);
              if (it == devices_.end() || it->second.streamFd != fd)
                  return;
              auto &dev = it->second;
              dev.framer.append(chunk->data(), chunk->size());
              while (auto bytes = dev.framer.next()) {
                  auto packetData = std::make_shared<std::vector<uint8_t>>(std::move(*bytes));
                  auto parsed = parsePacket(packetData->data(), packetData->size());
                  if (parsed && parsed->kind == PacketKind::Hello) {
                      if (auto hello = parseHelloPayload(parsed->payload)) {
                          dev.deviceName = hello->deviceName;
                          registerDiscoveredDevice(hello->deviceName);
                          reevaluateAssignments();
                      }
                  }
                  if (dev.owner)
                      dev.owner->dispatchPacket(packetData);
              }
              if (dev.framer.desynced()) {
                  blog(LOG_WARNING, "[iPhoneCam] USB stream out of sync, reconnecting");
                  shutdown(fd, SHUT_RDWR);
              }
            });
        }

        dispatch_async(queue_, ^{
          auto it = devices_.find(devID);
          if (it == devices_.end() || it->second.streamFd != fd)
              return;
          close(fd);
          it->second.streamFd = -1;
          it->second.isConnecting = false;
          it->second.framer.reset();
          if (it->second.owner) {
              it->second.owner->onUsbDisconnected();
              it->second.owner = nullptr;
          }
          reevaluateAssignments();
          retryConnectLater(devID);
        });
    }

    void reevaluateAssignments()
    {
        // 1. Release devices whose owner left or now wants a different iPhone.
        for (auto &pair : devices_) {
            auto &dev = pair.second;
            if (!dev.owner)
                continue;
            auto it = std::find_if(receivers_.begin(), receivers_.end(),
                                   [&dev](const RegisteredReceiver &r) { return r.impl == dev.owner; });
            if (it == receivers_.end()) {
                dev.owner = nullptr;
            } else if (!it->targetDevice.empty() && dev.deviceName != it->targetDevice) {
                dev.owner = nullptr;
                it->impl->onUsbDisconnected();
            }
        }

        // 2. Receivers pinned to a camera name.
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

        // 3. Receivers that take the first free iPhone.
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

// MARK: - NetworkReceiver::Impl

void NetworkReceiver::Impl::start(const ReceiverConfig &next)
{
    stop();
    config = next;
    isRunning = true;

    if (config.mode == ConnectionMode::Usb) {
        publishStatus(config.targetDevice.empty() ? "Waiting for an iPhone on USB"
                                                  : "Waiting for " + config.targetDevice + " on USB",
                      "", false);
        UsbmuxDeviceManager::instance().registerReceiver(this, config.targetDevice);
        return;
    }

    wifiRunning = true;
    const ReceiverConfig settings = config;
    wifiThread = std::thread([this, settings] { wifiLoop(settings); });
}

void NetworkReceiver::Impl::stop()
{
    isRunning = false;
    UsbmuxDeviceManager::instance().unregisterReceiver(this);
    stopWifi();
    dispatch_sync(queue, ^{
      isUsbConnected = false;
      usbDeviceName.clear();
    });
}

void NetworkReceiver::Impl::onUsbConnected(int, std::string name)
{
    dispatch_async(queue, ^{
      if (!isRunning)
          return;
      isUsbConnected = true;
      usbDeviceName = name;
      publishStatus("Connected to " + usbDeviceName + " via USB cable", "USB: " + usbDeviceName, true);
      sendFramed(framedIdentify(kTransportUSB));
    });
}

void NetworkReceiver::Impl::onUsbDisconnected()
{
    dispatch_async(queue, ^{
      if (!isRunning)
          return;
      isUsbConnected = false;
      usbDeviceName.clear();
      publishStatus("iPhone disconnected, waiting on USB", "", false);
    });
}

void NetworkReceiver::Impl::sendFramed(const std::vector<uint8_t> &bytes)
{
    if (!isRunning)
        return;
    if (config.mode == ConnectionMode::Usb) {
        UsbmuxDeviceManager::instance().sendFramed(this, bytes);
        return;
    }
    std::lock_guard<std::mutex> lock(wifiMutex);
    if (wifiFd >= 0)
        sendAll(wifiFd, bytes);
}

void NetworkReceiver::Impl::wifiLoop(ReceiverConfig settings)
{
    pthread_setname_np("iphonecam-wifi");
    while (wifiRunning) {
        if (settings.host.empty()) {
            publishStatus("Enter the iPhone's IP address (iPhoneCam shows it on screen)", "", false);
            waitForRetry(kWaitForSettingsChange);
            continue;
        }

        auto target = PhoneDiscovery::instance().lookup(settings.host);
        if (!target)
            target = parseHostPort(settings.host, kStreamPort);
        if (!target) {
            publishStatus("Invalid address: " + settings.host, "", false);
            waitForRetry(kWaitForSettingsChange);
            continue;
        }

        const std::string endpoint = target->host + ":" + std::to_string(target->port);
        publishStatus("Connecting to " + settings.host + "...", "", false);
        const int fd = dial(*target);
        if (fd < 0) {
            if (!wifiRunning)
                break;
            publishStatus("Cannot reach " + endpoint + " (is iPhoneCam open on the same network?)", "", false);
            waitForRetry(kRetryDelay);
            continue;
        }

        {
            std::lock_guard<std::mutex> lock(wifiMutex);
            wifiFd = fd;
        }
        blog(LOG_INFO, "[iPhoneCam] Connected to %s over Wi-Fi", endpoint.c_str());
        publishStatus("Connected via Wi-Fi", "Wi-Fi: " + endpoint, true);
        sendFramed(framedIdentify(kTransportWiFi));

        readWifi(fd);

        {
            std::lock_guard<std::mutex> lock(wifiMutex);
            wifiFd = -1;
        }
        close(fd);
        if (wifiRunning) {
            blog(LOG_INFO, "[iPhoneCam] Lost %s, reconnecting", endpoint.c_str());
            publishStatus("Lost " + endpoint + ", reconnecting...", "", false);
            waitForRetry(kRetryDelay);
        }
    }
}

int NetworkReceiver::Impl::dial(const HostPort &target)
{
    addrinfo hints = {};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    addrinfo *results = nullptr;
    const std::string port = std::to_string(target.port);
    if (getaddrinfo(target.host.c_str(), port.c_str(), &hints, &results) != 0 || !results)
        return -1;

    int connected = -1;
    for (addrinfo *ai = results; ai && wifiRunning && connected < 0; ai = ai->ai_next) {
        const int fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0)
            continue;
        const int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        int result = connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (result < 0 && errno == EINPROGRESS) {
            result = -1;
            // Poll in short slices so stop() never waits for a full connect timeout.
            const auto deadline = std::chrono::steady_clock::now() + kConnectTimeout;
            while (wifiRunning && std::chrono::steady_clock::now() < deadline) {
                pollfd descriptor = {fd, POLLOUT, 0};
                const int ready = poll(&descriptor, 1, 100);
                if (ready > 0) {
                    int error = 0;
                    socklen_t length = sizeof(error);
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length);
                    result = error == 0 ? 0 : -1;
                    break;
                }
                if (ready < 0 && errno != EINTR)
                    break;
            }
        }
        if (result == 0) {
            fcntl(fd, F_SETFL, flags);
            configureStreamSocket(fd, true);
            connected = fd;
        } else {
            close(fd);
        }
    }
    freeaddrinfo(results);
    return connected;
}

void NetworkReceiver::Impl::readWifi(int fd)
{
    PacketStreamFramer framer;
    std::vector<uint8_t> buffer(256 * 1024);
    auto lastData = std::chrono::steady_clock::now();
    while (wifiRunning) {
        pollfd descriptor = {fd, POLLIN, 0};
        const int ready = poll(&descriptor, 1, 250);
        if (ready < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (ready == 0) {
            if (std::chrono::steady_clock::now() - lastData > kIdleTimeout) {
                blog(LOG_WARNING, "[iPhoneCam] No data from the iPhone for 6 s, reconnecting");
                break;
            }
            continue;
        }
        const ssize_t n = recv(fd, buffer.data(), buffer.size(), 0);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            break;
        lastData = std::chrono::steady_clock::now();
        framer.append(buffer.data(), size_t(n));
        while (auto packet = framer.next())
            dispatchPacket(std::make_shared<std::vector<uint8_t>>(std::move(*packet)));
        if (framer.desynced()) {
            blog(LOG_WARNING, "[iPhoneCam] Wi-Fi stream out of sync, reconnecting");
            break;
        }
    }
}

void NetworkReceiver::Impl::stopWifi()
{
    wifiRunning = false;
    {
        std::lock_guard<std::mutex> lock(wifiMutex);
        if (wifiFd >= 0)
            shutdown(wifiFd, SHUT_RDWR);
    }
    wifiWake.notify_all();
    if (wifiThread.joinable())
        wifiThread.join();
}

// MARK: - NetworkReceiver

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

void NetworkReceiver::start(const ReceiverConfig &config)
{
    impl_->start(config);
}

void NetworkReceiver::stop()
{
    impl_->stop();
}

void NetworkReceiver::sendControlCommand(const ControlCommand &command)
{
    const auto bytes = framedControl(command);
    Impl *impl = impl_;
    dispatch_async(impl->queue, ^{
      impl->sendFramed(bytes);
    });
}

void NetworkReceiver::sendPacket(const CameraPacket &packet)
{
    const auto bytes = encodeFramedPacket(packet);
    Impl *impl = impl_;
    dispatch_async(impl->queue, ^{
      impl->sendFramed(bytes);
    });
}

} // namespace iphonecam
