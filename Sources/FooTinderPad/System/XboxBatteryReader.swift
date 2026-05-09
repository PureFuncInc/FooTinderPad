import CoreBluetooth
import Foundation
import os

/// CoreBluetooth battery fallback for Xbox Wireless Controller over BLE.
///
/// Xbox controllers paired as "Bluetooth Low Energy" may expose battery level
/// through the standard BLE Battery Service even when `GCController.battery`
/// reports nothing useful. This reader looks for a connected peripheral named
/// like an Xbox controller, reads characteristic 0x2A19, and translates the
/// byte value (0...100) into the same presentation suffix used by
/// `BatteryMonitor`.
final class XboxBatteryReader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let log = Logger(subsystem: "com.purefuncinc.FooTinderPad", category: "XboxBatteryReader")

    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")
    private static let hidService = CBUUID(string: "1812")
    private static let scanTimeout: TimeInterval = 8

    private(set) var current: BatterySuffix = .none
    var onChange: ((BatterySuffix) -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var scanStopTimer: Timer?
    private var isAttached = false

    static func parseBatteryLevel(_ data: Data?) -> BatterySuffix {
        guard let byte = data?.first else { return .none }
        return .discharging(level: min(Int(byte), 100))
    }

    func attach() {
        guard !isAttached else {
            refresh()
            return
        }
        isAttached = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            refresh()
        }
    }

    func detach() {
        guard isAttached || central != nil else { return }
        isAttached = false
        scanStopTimer?.invalidate()
        scanStopTimer = nil
        central?.stopScan()
        if let p = peripheral, p.state != .disconnected {
            central?.cancelPeripheralConnection(p)
        }
        peripheral = nil
        if current != .none {
            current = .none
            onChange?(.none)
        }
    }

    func refresh() {
        guard isAttached, let central else { return }
        guard central.state == .poweredOn else {
            Self.log.info("bluetooth central unavailable: state=\(central.state.rawValue, privacy: .public)")
            return
        }
        if let p = peripheral, p.state == .connected {
            p.discoverServices([Self.batteryService])
            return
        }

        let connected = Self.unique(
            central.retrieveConnectedPeripherals(withServices: [Self.batteryService]) +
            central.retrieveConnectedPeripherals(withServices: [Self.hidService])
        )
        if let xbox = connected.first(where: Self.isXboxPeripheral) {
            use(xbox)
            return
        }

        central.scanForPeripherals(withServices: [Self.hidService], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
        scanStopTimer?.invalidate()
        scanStopTimer = Timer.scheduledTimer(withTimeInterval: Self.scanTimeout, repeats: false) { [weak self] _ in
            self?.central?.stopScan()
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard isAttached else { return }
        if central.state == .poweredOn {
            refresh()
        } else {
            Self.log.info("bluetooth central state changed: \(central.state.rawValue, privacy: .public)")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard isAttached, Self.isXboxPeripheral(peripheral) else { return }
        central.stopScan()
        scanStopTimer?.invalidate()
        scanStopTimer = nil
        use(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        peripheral.discoverServices([Self.batteryService])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral === self.peripheral else { return }
        Self.log.warning("failed to connect Xbox battery peripheral: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        self.peripheral = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            Self.log.warning("failed to discover Xbox battery service: \(error.localizedDescription, privacy: .public)")
            return
        }
        for service in peripheral.services ?? [] where service.uuid == Self.batteryService {
            peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            Self.log.warning("failed to discover Xbox battery characteristic: \(error.localizedDescription, privacy: .public)")
            return
        }
        for characteristic in service.characteristics ?? [] where characteristic.uuid == Self.batteryLevel {
            peripheral.readValue(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == Self.batteryLevel else { return }
        if let error {
            Self.log.warning("failed to read Xbox battery level: \(error.localizedDescription, privacy: .public)")
            return
        }
        let next = Self.parseBatteryLevel(characteristic.value)
        Self.log.info("Xbox BLE battery level read: \(String(describing: next), privacy: .public)")
        if next != current {
            current = next
            onChange?(next)
        }
    }

    private func use(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        if peripheral.state == .connected {
            peripheral.discoverServices([Self.batteryService])
        } else {
            central?.connect(peripheral, options: nil)
        }
    }

    private static func isXboxPeripheral(_ peripheral: CBPeripheral) -> Bool {
        peripheral.name?.lowercased().contains("xbox") == true
    }

    private static func unique(_ peripherals: [CBPeripheral]) -> [CBPeripheral] {
        var seen: Set<UUID> = []
        var out: [CBPeripheral] = []
        for p in peripherals where !seen.contains(p.identifier) {
            seen.insert(p.identifier)
            out.append(p)
        }
        return out
    }
}
