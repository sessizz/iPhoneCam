import Foundation
import Network

final class BonjourBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    var onEndpointFound: ((NWEndpoint) -> Void)?
    var onStatusChanged: ((String) -> Void)?

    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var currentEndpoint: NWEndpoint?
    private var isSearching = false

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
        if services.isEmpty {
            currentEndpoint = nil
            onStatusChanged?("Looking for Mac receiver...")
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard sender.port > 0 else {
            onStatusChanged?("Mac receiver resolved without a UDP port")
            return
        }

        let hostName = sender.hostName ?? sender.name
        guard let port = NWEndpoint.Port(rawValue: UInt16(sender.port)) else {
            onStatusChanged?("Mac receiver has an invalid UDP port")
            return
        }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(hostName), port: port)
        if endpoint.debugDescription != currentEndpoint?.debugDescription {
            currentEndpoint = endpoint
            onStatusChanged?("Resolved Mac at \(hostName):\(sender.port)")
            onEndpointFound?(endpoint)
        }
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
