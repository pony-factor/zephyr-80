import CoreBluetooth
import Foundation

struct Glove80BatteryLevels: Equatable {
    let left: Int?
    let right: Int?

    var isEmpty: Bool {
        left == nil && right == nil
    }
}

final class Glove80BatteryReader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevelCharacteristic = CBUUID(string: "2A19")

    private let queue = DispatchQueue(label: "io.github.JFWooten4.glove80-mac-battery-reader")
    private let completion = DispatchSemaphore(value: 0)

    private var central: CBCentralManager?
    private var keyboard: CBPeripheral?
    private var serviceIndexes: [ObjectIdentifier: Int] = [:]
    private var values: [Int: Int] = [:]
    private var pendingCharacteristicDiscoveries = 0
    private var pendingReads = 0
    private var finished = false

    func read(timeout: TimeInterval = 6) -> Glove80BatteryLevels {
        queue.async { [weak self] in
            guard let self else { return }
            self.central = CBCentralManager(
                delegate: self,
                queue: self.queue,
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
        }

        _ = completion.wait(timeout: .now() + timeout)

        return queue.sync {
            Glove80BatteryLevels(left: values[0], right: values[1])
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            let candidates = central.retrieveConnectedPeripherals(
                withServices: [Self.batteryService]
            )
            guard let peripheral = candidates.first(where: {
                $0.name?.localizedCaseInsensitiveContains("Glove80") == true
            }) else {
                finish()
                return
            }

            keyboard = peripheral
            peripheral.delegate = self

            if peripheral.state == .connected {
                peripheral.discoverServices([Self.batteryService])
            } else {
                central.connect(peripheral, options: nil)
            }

        case .unknown, .resetting:
            break

        default:
            finish()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.batteryService])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        finish()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        finish()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            finish()
            return
        }

        let services = (peripheral.services ?? []).filter {
            $0.uuid == Self.batteryService
        }

        guard !services.isEmpty else {
            finish()
            return
        }

        pendingCharacteristicDiscoveries = services.count

        // ZMK exposes the central half's normal BAS first and the proxied
        // peripheral BAS second. This is also the ordering used by existing
        // split-keyboard battery readers on macOS.
        for (index, service) in services.enumerated() {
            serviceIndexes[ObjectIdentifier(service)] = index
            peripheral.discoverCharacteristics(
                [Self.batteryLevelCharacteristic],
                for: service
            )
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        pendingCharacteristicDiscoveries = max(0, pendingCharacteristicDiscoveries - 1)

        if error == nil {
            for characteristic in service.characteristics ?? []
            where characteristic.uuid == Self.batteryLevelCharacteristic {
                pendingReads += 1
                peripheral.readValue(for: characteristic)
            }
        }

        finishIfComplete()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        defer {
            pendingReads = max(0, pendingReads - 1)
            finishIfComplete()
        }

        guard error == nil,
              characteristic.uuid == Self.batteryLevelCharacteristic,
              let data = characteristic.value,
              let byte = data.first,
              byte <= 100,
              let service = characteristic.service,
              let index = serviceIndexes[ObjectIdentifier(service)] else {
            return
        }

        values[index] = Int(byte)
    }

    private func finishIfComplete() {
        if pendingCharacteristicDiscoveries == 0 && pendingReads == 0 {
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        completion.signal()
    }
}
