import Darwin
import Foundation

enum NetworkInfo {
    /// IPv4 addresses a receiver can dial, Wi-Fi (en0) first, then other Ethernet-like and bridge interfaces
    /// such as Personal Hotspot over USB.
    static func reachableIPv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else {
            return []
        }
        defer { freeifaddrs(head) }

        var found: [(interface: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else {
                continue
            }
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else {
                continue
            }
            let interface = String(cString: entry.ifa_name)
            guard interface.hasPrefix("en") || interface.hasPrefix("bridge") else {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            let text = String(cString: host)
            // A self-assigned address means the interface never joined a network.
            guard !text.hasPrefix("169.254.") else {
                continue
            }
            found.append((interface, text))
        }
        return found
            .sorted { rank($0.interface) < rank($1.interface) }
            .map(\.address)
    }

    private static func rank(_ interface: String) -> Int {
        if interface == "en0" {
            return 0
        }
        return interface.hasPrefix("en") ? 1 : 2
    }
}
