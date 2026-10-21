import Foundation
import Network
import UIKit

final class BonjourBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    var onEndpointFound: ((NWEndpoint) -> Void)?
    var onStatusChanged: ((String) -> Void)?

    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var currentEndpoint: NWEndpoint?
    private var isCurrentEndpointTargeted = false
    private var isSearching = false
    var myDeviceName: String = DeviceIdentity.displayName

    override init() {
        super.init()
    }

    func start() {
        stop()
        let browser = NetServiceBrowser()
        browser.delegate = self
        self.browser = browser
        isSearching = true
        onStatusChanged?("Looking for Mac receiver...")
        browser.searchForServices(ofType: CameraProtocol.bonjourServiceType, inDomain: "local.")
    }

    func stop() {
        services.forEach { service in
            service.stop()
            service.delegate = nil
        }
        services.removeAll()
        browser?.stop()
        browser?.delegate = nil
        browser = nil
        currentEndpoint = nil
        isCurrentEndpointTargeted = false
        isSearching = false
    }

    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        onStatusChanged?("Looking for Mac receiver...")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        onStatusChanged?("Bonjour search failed: \(errorDescription(errorDict))")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard isSearching else {
            return
        }
        services.append(service)
        service.delegate = self
        onStatusChanged?("Found Mac receiver, resolving...")
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 === service }
        if services.isEmpty && !moreComing {
            currentEndpoint = nil
            isCurrentEndpointTargeted = false
            onStatusChanged?("Looking for Mac receiver...")
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard sender.port > 0 else {
            onStatusChanged?("Mac receiver resolved without a UDP port")
            return
        }

        guard let port = NWEndpoint.Port(rawValue: UInt16(sender.port)) else {
            onStatusChanged?("Mac receiver has an invalid UDP port")
            return
        }

        var isTargetMatch = false
        var isWildcard = false
        var isBusy = false
        var isConnectedToMe = false

        if let txtData = sender.txtRecordData() {
            let dict = NetService.dictionary(fromTXTRecord: txtData)
            if let busyData = dict["busy"], let busyStr = String(data: busyData, encoding: .utf8), busyStr == "1" {
                isBusy = true
            }
            if let devData = dict["device"], let devStr = String(data: devData, encoding: .utf8) {
                if devStr.caseInsensitiveCompare(myDeviceName) == .orderedSame {
                    isConnectedToMe = true
                }
            }
            if let targetData = dict["target"], let target = String(data: targetData, encoding: .utf8) {
                if target.caseInsensitiveCompare(myDeviceName) == .orderedSame {
                    isTargetMatch = true
                } else if target == "*" || target.isEmpty {
                    isWildcard = true
                } else {
                    // Targeted to a different iPhone; ignore this receiver
                    return
                }
            } else {
                isWildcard = true
            }
        } else {
            isWildcard = true
        }

        let resolvedIPs = extractIPv4Addresses(from: sender)
        let chosenHost: String
        if let usbIP = resolvedIPs.first(where: { $0.hasPrefix("172.20.") }) {
            chosenHost = usbIP
        } else if let linkLocalUSB = resolvedIPs.first(where: { $0.hasPrefix("169.254.") }) {
            chosenHost = linkLocalUSB
        } else if let firstIP = resolvedIPs.first {
            chosenHost = firstIP
        } else if let hostName = sender.hostName, !hostName.isEmpty {
            chosenHost = hostName
        } else {
            chosenHost = sender.name
        }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(chosenHost), port: port)
        let isAlreadyCurrentEndpoint = (currentEndpoint?.debugDescription == endpoint.debugDescription)

        // If this receiver is busy with another phone (and NOT targeted to us, NOT connected to us, and NOT our current endpoint), ignore it!
        if isBusy && !isTargetMatch && !isConnectedToMe && !isAlreadyCurrentEndpoint {
            return
        }

        // If we already connected to an explicitly targeted receiver, do not downgrade to a wildcard
        if isCurrentEndpointTargeted && isWildcard && !isAlreadyCurrentEndpoint {
            return
        }

        if endpoint.debugDescription != currentEndpoint?.debugDescription || (isTargetMatch && !isCurrentEndpointTargeted) {
            currentEndpoint = endpoint
            isCurrentEndpointTargeted = isTargetMatch
            if isTargetMatch {
                onStatusChanged?("Matched receiver for \(myDeviceName) at \(chosenHost):\(sender.port)")
            } else {
                onStatusChanged?("Resolved Mac at \(chosenHost):\(sender.port)")
            }
            onEndpointFound?(endpoint)
        }
    }

    private func extractIPv4Addresses(from service: NetService) -> [String] {
        guard let addresses = service.addresses else { return [] }
        var ips: [String] = []
        for addressData in addresses {
            addressData.withUnsafeBytes { rawBuffer in
                guard let sockaddrPtr = rawBuffer.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return }
                if sockaddrPtr.pointee.sa_family == sa_family_t(AF_INET) {
                    let sockaddrInPtr = rawBuffer.baseAddress!.assumingMemoryBound(to: sockaddr_in.self)
                    var addr = sockaddrInPtr.pointee.sin_addr
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                        ips.append(String(cString: buffer))
                    }
                }
            }
        }
        return ips
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        onStatusChanged?("Bonjour resolve failed: \(errorDescription(errorDict))")
    }

    private func errorDescription(_ errorDict: [String: NSNumber]) -> String {
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        let domain = errorDict[NetService.errorDomain]?.stringValue ?? "unknown"
        return "\(domain) \(code)"
    }
}
