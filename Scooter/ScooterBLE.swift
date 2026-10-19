import Foundation
import CoreBluetooth
import Combine

// MARK: - Discovery

struct DiscoveredPeripheral: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    var displayName: String
    var rssi: Int
    var advertisesVoltix: Bool
}

enum ScanFilter: String, CaseIterable {
    case voltixOnly = "Scooters only (FF60)"
    case allNamed = "All named devices"
}

// MARK: - Telemetry (provisional decode)

struct ScooterTelemetry {
    var batteryPct: Int = 0
    var faultCode: UInt8 = 0
    var speedKmh: Double = 0
}

// MARK: - Voltix FF60 protocol (recovered from com.world.voltix)

enum Voltix {
    static let serviceString = "0000FF60-0000-1000-8000-00805F9B34FB"
    static let notifyString  = "0000FF61-0000-1000-8000-00805F9B34FB"
    static let writeString   = "0000FF62-0000-1000-8000-00805F9B34FB"

    static let service = CBUUID(string: serviceString)

    static func advertisesVoltix(in advertisementData: [String: Any]) -> Bool {
        let lists: [[CBUUID]?] = [
            advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
            advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID],
            advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID],
        ]
        for uuids in lists {
            guard let uuids else { continue }
            if uuids.contains(where: { $0.uuidString.uppercased().contains("FF60") }) {
                return true
            }
        }
        return false
    }

    enum Cmd: UInt8 {
        case heartbeat  = 0x10
        case connect    = 0x30
        case lock       = 0x32
        case light      = 0x33
        case gear       = 0x35
        case speedLimit = 0x36
        case cruise     = 0x38
        case queryCar   = 0x60
    }

    /// CRC-16/MODBUS, poly 0xA001, init 0xFFFF. Verified crc([0x01]) == 0x807E.
    static func crc16Modbus(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in bytes {
            crc ^= UInt16(b)
            for _ in 0..<8 {
                if crc & 0x0001 == 1 {
                    crc = (crc >> 1) ^ 0xA001
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }

    static func frame(cmd: Cmd, param: UInt8, payload: [UInt8] = []) -> Data {
        var body: [UInt8] = [cmd.rawValue, param, UInt8(payload.count)]
        body.append(contentsOf: payload)
        let crc = crc16Modbus(body)
        var out: [UInt8] = [0x1A, 0xA1]
        out.append(contentsOf: body)
        out.append(UInt8(crc & 0xFF))   // CRC low byte first
        out.append(UInt8(crc >> 8))     // CRC high byte second
        out.append(0x1F)
        out.append(0xF1)
        return Data(out)
    }

    static func connectFrame() -> Data   { frame(cmd: .connect, param: 2, payload: [0x01]) }
    static func heartbeatFrame() -> Data { frame(cmd: .heartbeat, param: 1) }
    static func queryCarFrame() -> Data  { frame(cmd: .queryCar, param: 1) }

    static func lockFrame() -> Data {
        frame(cmd: .lock, param: 2, payload: [0x00])   // type 0 = toggle/unlock
    }

    static func unlockFrame(password: String?) -> Data {
        var payload: [UInt8] = [0x00]                  // type 0 = unlock
        if let pw = password, pw.count == 4, pw.allSatisfy({ $0.isNumber }) {
            for ch in pw {
                payload.append(UInt8(clamping: ch.wholeNumberValue ?? 0))
            }
        }
        return frame(cmd: .lock, param: 2, payload: payload)
    }

    static func lightFrame(on: Bool) -> Data { frame(cmd: .light, param: 2, payload: [on ? 1 : 0]) }
    static func gearFrame(_ g: Int) -> Data { frame(cmd: .gear, param: 2, payload: [UInt8(clamping: g)]) }
    static func speedLimitFrame(_ kmh: Int) -> Data { frame(cmd: .speedLimit, param: 2, payload: [UInt8(kmh & 0xFF)]) }
    static func cruiseFrame(_ v: Int) -> Data { frame(cmd: .cruise, param: 2, payload: [UInt8(v & 0xFF)]) }

    /// Payload = notify frame with the 5-byte prefix (1A A1 CMD PARAM LEN) removed.
    static func parseQueryCar(_ payload: [UInt8]) -> ScooterTelemetry {
        var t = ScooterTelemetry()
        guard payload.count >= 5 else { return t }
        t.faultCode = payload[2]
        t.batteryPct = payload[3] <= 100 ? Int(payload[3]) : 0
        let low = Int(payload[4])
        let high = payload.count > 8 ? Int(payload[8] & 0x03) : 0
        t.speedKmh = Double(low | (high << 8)) * 0.1
        return t
    }
}

// MARK: - BLE controller

final class ScooterController: NSObject, ObservableObject {
    @Published var bluetoothReady = false
    @Published var bluetoothError: String?
    @Published var isScanning = false
    @Published var discovered: [DiscoveredPeripheral] = []
    @Published var scanFilter: ScanFilter = .voltixOnly
    @Published var status = "Scanning off"
    @Published var isConnected = false
    @Published var telemetry = ScooterTelemetry()
    @Published var connectedID: UUID?

    private var central: CBCentralManager?
    private var connected: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var pollTimer: Timer?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func setScanFilter(_ filter: ScanFilter) {
        guard filter != scanFilter else { return }
        scanFilter = filter
        if isScanning {
            startScan()
        }
    }

    // MARK: Scan / connect

    func startScan() {
        guard let central, central.state == .poweredOn else {
            status = "Waiting for Bluetooth…"
            return
        }
        discovered.removeAll()
        isScanning = true
        let mode = scanFilter == .voltixOnly ? "FF60 scooters" : "all named BLE"
        status = "Scanning for \(mode)…"
        let services: [CBUUID]? = scanFilter == .voltixOnly ? [Voltix.service] : nil
        central.scanForPeripherals(
            withServices: services,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func stopScan() {
        central?.stopScan()
        isScanning = false
        if discovered.isEmpty, scanFilter == .voltixOnly {
            status = "No FF60 devices found. Power the scooter on, stand within ~2 m, then Rescan—or switch to All named devices."
        } else if !isConnected {
            status = "Scan stopped"
        }
    }

    func connect(_ peripheral: CBPeripheral) {
        stopScan()
        status = "Connecting to \(peripheral.name ?? "scooter")…"
        central?.connect(peripheral, options: nil)
    }

    func disconnect() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let connected = connected {
            central?.cancelPeripheralConnection(connected)
        }
        connected = nil
        writeChar = nil
        isConnected = false
        connectedID = nil
        status = "Disconnected"
    }

    // MARK: Controls

    private func send(_ data: Data) {
        guard let connected, let writeChar else { return }
        let type: CBCharacteristicWriteType = writeChar.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse
        connected.writeValue(data, for: writeChar, type: type)
    }

    func lock()                    { send(Voltix.lockFrame()) }
    func unlock(pwd: String?)      { send(Voltix.unlockFrame(password: pwd)) }
    func setLight(_ on: Bool)      { send(Voltix.lightFrame(on: on)) }
    func setGear(_ g: Int)         { send(Voltix.gearFrame(g)) }
    func setSpeedLimit(_ kmh: Int) { send(Voltix.speedLimitFrame(kmh)) }
    func setCruise(_ v: Int)       { send(Voltix.cruiseFrame(v)) }

    private func upsertDiscovery(
        peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: Int
    ) {
        let advertisesVoltix = Voltix.advertisesVoltix(in: advertisementData)
        let advName = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)

        switch scanFilter {
        case .voltixOnly:
            break // iOS already filters by FF60 service in scan
        case .allNamed:
            guard let advName, !advName.isEmpty else { return }
        }

        let displayName: String
        if let advName, !advName.isEmpty {
            displayName = advName
        } else if advertisesVoltix {
            displayName = "Scooter (no name, FF60)"
        } else {
            displayName = "Unnamed device"
        }

        let entry = DiscoveredPeripheral(
            id: peripheral.identifier,
            peripheral: peripheral,
            displayName: displayName,
            rssi: rssi,
            advertisesVoltix: advertisesVoltix
        )

        if let idx = discovered.firstIndex(where: { $0.id == peripheral.identifier }) {
            discovered[idx] = entry
        } else {
            discovered.append(entry)
        }
        discovered.sort { $0.rssi > $1.rssi }
    }
}

// MARK: - CBCentralManagerDelegate

extension ScooterController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothReady = true
            bluetoothError = nil
            startScan()
        case .poweredOff:
            bluetoothReady = false
            bluetoothError = "Bluetooth is off. Turn it on in Settings."
        case .unauthorized:
            bluetoothReady = false
            bluetoothError = "Bluetooth permission denied. Allow it in Settings."
        case .unsupported:
            bluetoothReady = false
            bluetoothError = "This device does not support Bluetooth LE."
        default:
            bluetoothReady = false
            bluetoothError = "Bluetooth unavailable."
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        upsertDiscovery(peripheral: peripheral, advertisementData: advertisementData, rssi: RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connected = peripheral
        connectedID = peripheral.identifier
        peripheral.delegate = self
        status = "Connected. Discovering services…"
        peripheral.discoverServices([Voltix.service])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        status = "Connect failed: \(error?.localizedDescription ?? "unknown error")"
        connected = nil
        isConnected = false
        connectedID = nil
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        pollTimer?.invalidate()
        pollTimer = nil
        connected = nil
        writeChar = nil
        isConnected = false
        connectedID = nil
        telemetry = ScooterTelemetry()
        status = error == nil ? "Disconnected" : "Disconnected: \(error!.localizedDescription)"
    }
}

// MARK: - CBPeripheralDelegate

extension ScooterController: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            status = "Service discovery failed: \(error.localizedDescription)"
            return
        }
        guard let services = peripheral.services else { return }
        for service in services where service.uuid.uuidString.uppercased() == Voltix.serviceString {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil, let characteristics = service.characteristics else { return }
        for c in characteristics {
            let uuid = c.uuid.uuidString.uppercased()
            if uuid == Voltix.notifyString {
                peripheral.setNotifyValue(true, for: c)
            } else if uuid == Voltix.writeString {
                writeChar = c
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, characteristic.isNotifying else { return }
        isConnected = true
        status = "Connected to scooter"
        send(Voltix.connectFrame())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.send(Voltix.heartbeatFrame())
        }
        startPolling()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil,
              characteristic.uuid.uuidString.uppercased() == Voltix.notifyString,
              let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        // Frame: 1A A1 CMD PARAM LEN [payload] CRC_lo CRC_hi 1F F1
        guard bytes.count >= 7, bytes[0] == 0x1A, bytes[1] == 0xA1 else { return }
        if bytes[2] == Voltix.Cmd.queryCar.rawValue {
            telemetry = Voltix.parseQueryCar(Array(bytes.dropFirst(5)))
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.send(Voltix.queryCarFrame())
        }
    }
}
