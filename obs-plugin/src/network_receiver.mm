#include "network_receiver.hpp"
#include "protocol.hpp"

#import <Foundation/Foundation.h>
#import <Network/Network.h>

namespace iphonecam {
namespace {

std::string endpointDescription(nw_connection_t connection)
{
    nw_endpoint_t endpoint = nw_connection_copy_endpoint(connection);
    if (!endpoint)
        return "unknown";
    std::string description = "unknown";
    if (nw_endpoint_get_type(endpoint) == nw_endpoint_type_host) {
        const char *host = nw_endpoint_get_hostname(endpoint);
        const uint16_t port = nw_endpoint_get_port(endpoint);
        description = std::string(host ? host : "unknown") + ":" + std::to_string(port);
    }
    return description;
}

std::string errorDescription(nw_error_t error)
{
    if (!error)
        return "";
    return std::string("network error ") + std::to_string(nw_error_get_error_code(error));
}

} // namespace

struct NetworkReceiver::Impl {
    dispatch_queue_t queue = dispatch_queue_create("iphonecam.obs.receiver", DISPATCH_QUEUE_SERIAL);
    nw_listener_t listener = nullptr;
    nw_connection_t activeConnection = nullptr;
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

        nw_parameters_t parameters = nw_parameters_create_secure_udp(NW_PARAMETERS_DISABLE_PROTOCOL,
                                                                     NW_PARAMETERS_DEFAULT_CONFIGURATION);
        listener = nw_listener_create_with_port("0", parameters);
        if (!listener) {
            publishStatus("Receiver failed", 0);
            return;
        }

        nw_advertise_descriptor_t advertise =
            nw_advertise_descriptor_create_bonjour_service(receiverName.c_str(), kBonjourServiceType, nullptr);
        nw_listener_set_advertise_descriptor(listener, advertise);
        nw_listener_set_queue(listener, queue);

        nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
          switch (state) {
          case nw_listener_state_ready: {
              const uint16_t port = nw_listener_get_port(listener);
              publishStatus("Waiting for iPhone", port);
              break;
          }
          case nw_listener_state_failed:
              publishStatus("Receiver failed: " + errorDescription(error), 0);
              break;
          case nw_listener_state_waiting:
              publishStatus("Receiver waiting: " + errorDescription(error), 0);
              break;
          case nw_listener_state_cancelled:
              publishStatus("Receiver stopped", 0);
              break;
          default:
              break;
          }
        });

        nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) {
          const std::string endpoint = endpointDescription(connection);
          if (activeConnection && endpoint != activeEndpoint) {
              nw_connection_cancel(connection);
              return;
          }

          activeConnection = connection;
          activeEndpoint = endpoint;
          nw_connection_set_queue(connection, queue);
          nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
            switch (state) {
            case nw_connection_state_ready:
                publishStatus("Connected: " + activeEndpoint, nw_listener_get_port(listener));
                break;
            case nw_connection_state_failed:
                publishStatus("Connection failed: " + errorDescription(error), nw_listener_get_port(listener));
                activeConnection = nullptr;
                activeEndpoint.clear();
                break;
            case nw_connection_state_cancelled:
                activeConnection = nullptr;
                activeEndpoint.clear();
                publishStatus("Waiting for iPhone", listener ? nw_listener_get_port(listener) : 0);
                break;
            default:
                break;
            }
          });
          nw_connection_start(connection);
          receive(connection);
        });

        nw_listener_start(listener);
    }

    void stop()
    {
        if (activeConnection) {
            nw_connection_cancel(activeConnection);
            activeConnection = nullptr;
        }
        activeEndpoint.clear();
        if (listener) {
            nw_listener_cancel(listener);
            listener = nullptr;
        }
    }

    void receive(nw_connection_t connection)
    {
        nw_connection_receive_message(connection, ^(dispatch_data_t content, nw_content_context_t, bool,
                                                   nw_error_t error) {
          if (content) {
              const void *buffer = nullptr;
              size_t size = 0;
              dispatch_data_t mapped = dispatch_data_create_map(content, &buffer, &size);
              if (mapped && buffer && size > 0 && onPacket) {
                  const auto *bytes = static_cast<const uint8_t *>(buffer);
                  onPacket(std::vector<uint8_t>(bytes, bytes + size));
              }
          }
          if (!error)
              receive(connection);
        });
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
