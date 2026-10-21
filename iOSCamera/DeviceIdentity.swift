import Foundation
import UIKit

public enum DeviceIdentity {
    public static let customCameraNameKey = "iphonecam.customCameraName"

    /// The user-configured custom name, if any.
    public static var customName: String? {
        get {
            guard let name = UserDefaults.standard.string(forKey: customCameraNameKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return nil
            }
            return name
        }
        set {
            if let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                UserDefaults.standard.set(value, forKey: customCameraNameKey)
            } else {
                UserDefaults.standard.removeObject(forKey: customCameraNameKey)
            }
        }
    }

    /// Best human-readable display name for this device.
    /// 1. Custom name if set by user.
    /// 2. UIDevice.current.name if it was NOT redacted to "iPhone" / "iPad" by Apple (iOS 16 privacy).
    /// 3. Marketing hardware model name (e.g. "iPhone 11", "iPhone 15 Pro", "iPhone 16 Pro Max").
    public static var displayName: String {
        if let custom = customName {
            return custom
        }

        let systemName = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !systemName.isEmpty && systemName.lowercased() != "iphone" && systemName.lowercased() != "ipad" {
            return systemName
        }

        return hardwareModelName
    }

    /// Hardware model string decoded from utsname (e.g. "iPhone 11", "iPhone 16 Pro").
    public static var hardwareModelName: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }

        return marketingName(for: identifier)
    }

    public static func marketingName(for identifier: String) -> String {
        switch identifier {
        // iPhone 8 / 8 Plus / X
        case "iPhone10,1", "iPhone10,4": return "iPhone 8"
        case "iPhone10,2", "iPhone10,5": return "iPhone 8 Plus"
        case "iPhone10,3", "iPhone10,6": return "iPhone X"
        // iPhone XS / XR
        case "iPhone11,2": return "iPhone XS"
        case "iPhone11,4", "iPhone11,6": return "iPhone XS Max"
        case "iPhone11,8": return "iPhone XR"
        // iPhone 11
        case "iPhone12,1": return "iPhone 11"
        case "iPhone12,3": return "iPhone 11 Pro"
        case "iPhone12,5": return "iPhone 11 Pro Max"
        case "iPhone12,8": return "iPhone SE (2nd gen)"
        // iPhone 12
        case "iPhone13,1": return "iPhone 12 mini"
        case "iPhone13,2": return "iPhone 12"
        case "iPhone13,3": return "iPhone 12 Pro"
        case "iPhone13,4": return "iPhone 12 Pro Max"
        // iPhone 13
        case "iPhone14,4": return "iPhone 13 mini"
        case "iPhone14,5": return "iPhone 13"
        case "iPhone14,2": return "iPhone 13 Pro"
        case "iPhone14,3": return "iPhone 13 Pro Max"
        case "iPhone14,6": return "iPhone SE (3rd gen)"
        // iPhone 14
        case "iPhone14,7": return "iPhone 14"
        case "iPhone14,8": return "iPhone 14 Plus"
        case "iPhone15,2": return "iPhone 14 Pro"
        case "iPhone15,3": return "iPhone 14 Pro Max"
        // iPhone 15
        case "iPhone15,4": return "iPhone 15"
        case "iPhone15,5": return "iPhone 15 Plus"
        case "iPhone16,1": return "iPhone 15 Pro"
        case "iPhone16,2": return "iPhone 15 Pro Max"
        // iPhone 16
        case "iPhone17,1": return "iPhone 16 Pro"
        case "iPhone17,2": return "iPhone 16 Pro Max"
        case "iPhone17,3": return "iPhone 16"
        case "iPhone17,4": return "iPhone 16 Plus"
        case "iPhone17,5": return "iPhone 16e"
        // Simulators
        case "i386", "x86_64", "arm64":
            #if targetEnvironment(simulator)
            if let simModel = ProcessInfo().environment["SIMULATOR_MODEL_IDENTIFIER"] {
                return marketingName(for: simModel) + " (Simulator)"
            }
            return "iPhone Simulator"
            #else
            return "iPhone"
            #endif
        default:
            if identifier.hasPrefix("iPhone") {
                return identifier
            }
            return "iPhone"
        }
    }
}
