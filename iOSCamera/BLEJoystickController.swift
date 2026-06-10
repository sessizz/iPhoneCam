import CoreBluetooth
import Foundation

final class BLEJoystickController: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var statusText = "BLE joystick: idle"
    @Published private(set) var isConnected = false
    @Published private(set) var signedSpeedPercent = 0

    var onReport: ((BLEZoomJoystickReport) -> Void)?
    var onStopped: (() -> Void)?

    private let serviceUUID = CBUUID(string: BLEZoomProtocol.serviceUUIDString)
    private let joystickCharacteristicUUID = CBUUID(string: BLEZoomProtocol.joystickCharacteristicUUIDString)
    private let displayCharacteristicUUID = CBUUID(string: BLEZoomProtocol.displayCharacteristicUUIDString)
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var joystickCharacteristic: CBCharacteristic?
    private var displayCharacteristic: CBCharacteristic?
    private var reportTimeoutTimer: Timer?
    private var displaySequence: UInt16 = 0
    private var lastDisplayWrite = Date.distantPast
    private var lastDisplayZoomFactor: Double = 1
    private var lastDisplayIntensity: Double = 0
    private var wantsScanning = false

    func start() {
        wantsScanning = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
            statusText = "BLE joystick: starting"
            return
        }
        scanIfReady()
    }

    func stop() {
        wantsScanning = false
        reportTimeoutTimer?.invalidate()
        reportTimeoutTimer = nil
        central?.stopScan()
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        joystickCharacteristic = nil
        displayCharacteristic = nil
        isConnected = false
        signedSpeedPercent = 0
        statusText = "BLE joystick: stopped"
    }

    func updateDisplay(zoomFactor: Double, intensity: Double) {
        guard isConnected, let peripheral, let displayCharacteristic else {
            return
        }

        let now = Date()
        let intensityChanged = abs(intensity - lastDisplayIntensity) >= 0.02
        let zoomChanged = abs(zoomFactor - lastDisplayZoomFactor) >= 0.02
        guard intensityChanged || zoomChanged || now.timeIntervalSince(lastDisplayWrite) >= 0.25 else {
            return
        }

        displaySequence &+= 1
        let state = BLEZoomDisplayState(
            zoomFactor: zoomFactor,
            intensity: intensity,
            connected: true,
            sequence: displaySequence
        )
        let writeType: CBCharacteristicWriteType = displayCharacteristic.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse
        peripheral.writeValue(state.encoded(), for: displayCharacteristic, type: writeType)
        lastDisplayWrite = now
        lastDisplayZoomFactor = zoomFactor
        lastDisplayIntensity = intensity
        signedSpeedPercent = state.signedSpeedPercent
    }

    private func scanIfReady() {
        guard wantsScanning, let central else {
            return
        }
        guard central.state == .poweredOn else {
            statusText = statusText(for: central.state)
            return
        }
        guard peripheral == nil else {
            return
        }
        statusText = "BLE joystick: scanning"
        central.scanForPeripherals(withServices: [serviceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    private func handleDisconnect() {
        reportTimeoutTimer?.invalidate()
        reportTimeoutTimer = nil
        peripheral = nil
        joystickCharacteristic = nil
        displayCharacteristic = nil
        isConnected = false
        signedSpeedPercent = 0
        lastDisplayIntensity = 0
        onStopped?()
        statusText = wantsScanning ? "BLE joystick: reconnecting" : "BLE joystick: idle"
        if wantsScanning {
            scanIfReady()
        }
    }

    private func handleReport(_ report: BLEZoomJoystickReport) {
        reportTimeoutTimer?.invalidate()
        reportTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            guard let self else {
                return
            }
            self.signedSpeedPercent = 0
            self.lastDisplayIntensity = 0
            self.onStopped?()
        }
        onReport?(report)
    }

    private func statusText(for state: CBManagerState) -> String {
        switch state {
        case .poweredOn:
            return "BLE joystick: ready"
        case .poweredOff:
            return "BLE joystick: Bluetooth off"
        case .unauthorized:
            return "BLE joystick: permission needed"
        case .unsupported:
            return "BLE joystick: unsupported"
        case .resetting:
            return "BLE joystick: resetting"
        case .unknown:
            return "BLE joystick: starting"
        @unknown default:
            return "BLE joystick: unavailable"
        }
    }
}

extension BLEJoystickController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        statusText = statusText(for: central.state)
        scanIfReady()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        statusText = "BLE joystick: connecting"
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        statusText = "BLE joystick: discovering"
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        statusText = "BLE joystick: connect failed"
        handleDisconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        handleDisconnect()
    }
}

extension BLEJoystickController: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            statusText = "BLE joystick: service error"
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            statusText = "BLE joystick: service missing"
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([joystickCharacteristicUUID, displayCharacteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            statusText = "BLE joystick: characteristic error"
            central?.cancelPeripheralConnection(peripheral)
            return
        }

        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == joystickCharacteristicUUID {
                joystickCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            } else if characteristic.uuid == displayCharacteristicUUID {
                displayCharacteristic = characteristic
            }
        }

        if joystickCharacteristic != nil {
            statusText = "BLE joystick: connected"
        } else {
            statusText = "BLE joystick: notify missing"
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == joystickCharacteristicUUID, error == nil, let data = characteristic.value else {
            return
        }
        guard let report = BLEZoomJoystickReport(data: data) else {
            statusText = "BLE joystick: bad report"
            return
        }
        handleReport(report)
    }
}
