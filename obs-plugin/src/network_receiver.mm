#include "network_receiver.hpp"
#include "protocol.hpp"

#include <util/base.h>

#include <array>
#include <cerrno>
#include <cstring>
#include <dns_sd.h>
#include <netdb.h>
#include <netinet/in.h>
#include <string>
#include <sys/fcntl.h>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

#import <Foundation/Foundation.h>

namespace iphonecam {
namespace {

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

} // namespace

struct NetworkReceiver::Impl {
    dispatch_queue_t queue = dispatch_queue_create("iphonecam.obs.receiver", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t readSource = nullptr;
    DNSServiceRef bonjourService = nullptr;
    int socketFd = -1;
    uint16_t port = 0;
    std::string activeEndpoint;
    PacketCallback onPacket;
    StatusCallback onStatus;

    ~Impl() { stop(); }

    void publishStatus(const std::string &status, uint16_t port = 0)
    {
        if (onStatus)
            onStatus(status, port);
    }

    void start(const std::string &receiverName)
    {
        stop();

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
        if (!publishBonjour(receiverName, port)) {
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

        blog(LOG_INFO, "[iPhoneCam] OBS UDP receiver listening as '%s' on port %u", receiverName.c_str(), port);
        publishStatus("Waiting for iPhone", port);
    }

    void stop()
    {
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
        port = 0;
        activeEndpoint.clear();
    }

    bool publishBonjour(const std::string &receiverName, uint16_t servicePort)
    {
        const DNSServiceErrorType error = DNSServiceRegister(
            &bonjourService, 0, 0, receiverName.c_str(), "_iphonecam._udp.", nullptr, nullptr, htons(servicePort), 0,
            nullptr,
            [](DNSServiceRef, DNSServiceFlags, DNSServiceErrorType errorCode, const char *name, const char *,
               const char *, void *) {
              if (errorCode == kDNSServiceErr_NoError) {
                  blog(LOG_INFO, "[iPhoneCam] OBS Bonjour service registered as '%s'", name ? name : "iPhoneCam OBS");
              } else {
                  blog(LOG_ERROR, "[iPhoneCam] OBS Bonjour registration callback error: %d", int(errorCode));
              }
            },
            nullptr);
        if (error != kDNSServiceErr_NoError) {
            const std::string message = "Bonjour publish failed: " + std::to_string(int(error));
            fail(message);
            bonjourService = nullptr;
            return false;
        }
        blog(LOG_INFO, "[iPhoneCam] OBS Bonjour service published on _iphonecam._udp.:%u", servicePort);
        return true;
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

            const std::string endpoint = endpointDescription(sender, senderLength);
            if (activeEndpoint.empty()) {
                activeEndpoint = endpoint;
                blog(LOG_INFO, "[iPhoneCam] OBS receiver accepted iPhone endpoint %s", activeEndpoint.c_str());
                publishStatus("Connected: " + activeEndpoint, port);
            } else if (endpoint != activeEndpoint) {
                blog(LOG_INFO, "[iPhoneCam] OBS receiver ignored second endpoint %s", endpoint.c_str());
                continue;
            }

            if (onPacket) {
                onPacket(std::vector<uint8_t>(buffer.begin(), buffer.begin() + bytesRead));
            }
        }
    }

    void fail(const std::string &message)
    {
        blog(LOG_ERROR, "[iPhoneCam] OBS receiver error: %s", message.c_str());
        publishStatus("Receiver failed: " + message, 0);
    }
};

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

void NetworkReceiver::start(const std::string &receiverName)
{
    impl_->start(receiverName);
}

void NetworkReceiver::stop()
{
    impl_->stop();
}

} // namespace iphonecam
