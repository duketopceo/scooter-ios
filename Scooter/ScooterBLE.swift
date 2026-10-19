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
    var likelyW3Max: Bool
}

enum ScanFilter: String, CaseIterable {
    case voltixOnly = "Scooters only (FF60)"
    case allNamed = "All named devices"
}

enum ScooterIdentity {
    static let exampleSerial = "US2603013795W3MAX"

    static func likelyW3Max(advertisedName: String) -> Bool {
        let upper = advertisedName.uppercased()
        if upper.contains("W3MAX") { return true }
        if upper.contains("VOLTIX") { return true }
        if upper.contains("13795") { return true }
        return false
    }
}

struct ScooterTelemetry {
    var batteryPct: Int = 0
    var faultCode: UInt8 = 0
    var speedKmh: Double = 0
}

// MARK: - Voltix FF60 protocol

enum Voltix {
    static let serviceString = "0000FF60-0000-1000-8000-00805F9B34FB"
    static let notifyString  = "0000FF61-0000-1000-8000-00805F9B34FB"
    static let writeString   = "0000FF62-0000-1000-8000-00805F9B34FB"

    static let service = CBUUID(string: serviceString)
    static let notifyChar = CBUUID(string: notifyString)
    static let writeChar = CBUUID(string: writeString)

    /// iOS often exposes 16-bit UUIDs (`FF60`) while we store the full Bluetooth base UUID.
    static func matches(_ uuid: CBUUID, shortHex: String) -> Bool {
        let u = uuid.uuidString.uppercased()
        let short = shortHex.uppercased()
        if u == short { return true }
        if u.contains(short) { return true }
        return false
    }

    static func isService(_ uuid: CBUUID) -> Bool { matches(uuid, shortHex: "FF60") }
    static func isNotify(_ uuid: CBUUID) -> Bool { matches(uuid, shortHex: "FF61") }
    static func isWrite(_ uuid: CBUUID) -> Bool { matches(uuid, shortHex: "FF62") }

    static func advertisesVoltix(in advertisementData: [String: Any]) -> Bool {
        let lists: [[CBUUID]?] = [
            advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
            advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID],
            advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID],
        ]
        for uuids in lists {
            guard let uuids else { continue }
            if uuids.contains(where: isService) { return true }
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
        out.append(UInt8(crc & 0xFF))
        out.append(UInt8(crc >> 8))
        out.append(0x1F)
        out.append(0xF1)
        return Data(out)
    }

    static func connectFrame() -> Data   { frame(cmd: .connect, param: 2, payload: [0x01]) }
    static func heartbeatFrame() -> Data { frame(cmd: .heartbeat, param: 1) }
    static func queryCarFrame() -> Data  { frame(cmd: .queryCar, param: 1) }

    static func lockFrame() -> Data { frame(cmd: .lock, param: 2, payload: [0x00]) }

    static func unlockFrame(password: String?) -> Data {
        var payload: [UInt8] = [0x00]
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
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var notifyEnabled = false
    private var pollTimer: Timer?
    private var setupTimer: Timer?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func setScanFilter(_ filter: ScanFilter) {
        guard filter != scanFilter else { return }
        scanFilter = filter
        if isScanning { startScan() }
    }

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
        if discovered.isEmpty, scanFilter == .voltixOnly, !isConnected {
            status = "No FF60 devices found. Power the scooter on, stand within ~2 m, then Rescan—or switch to All named devices."
        } else if !isConnected {
            status = "Scan stopped"
        }
    }

    func connect(_ peripheral: CBPeripheral) {
        stopScan()
        cancelSetupTimer()
        writeCharacteristic = nil
        notifyCharacteristic = nil
        notifyEnabled = false
        status = "Connecting to \(peripheral.name ?? "device")…"
        central?.connect(peripheral, options: nil)
    }

    func disconnect() {
        cancelSetupTimer()
        pollTimer?.invalidate()
        pollTimer = nil
        if let connected = connected {
            central?.cancelPeripheralConnection(connected)
        }
        resetSessionState()
        status = "Disconnected"
    }

    private func resetSessionState() {
        connected = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        notifyEnabled = false
        isConnected = false
        connectedID = nil
        telemetry = ScooterTelemetry()
    }

    private func cancelSetupTimer() {
        setupTimer?.invalidate()
        setupTimer = nil
    }

    private func beginSetupTimeout(for peripheral: CBPeripheral) {
        cancelSetupTimer()
        setupTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self, weak peripheral] _ in
            guard let self, let peripheral, peripheral === self.connected else { return }
            self.status = "Setup timed out (no FF60 GATT). Wrong device or scooter asleep—Disconnect and try another row."
            self.bluetoothError = self.status
        }
    }

    private func send(_ data: Data) {
        guard let connected, let writeCharacteristic else { return }
        let type: CBCharacteristicWriteType = writeCharacteristic.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse
        connected.writeValue(data, for: writeCharacteristic, type: type)
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

        if scanFilter == .allNamed {
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
            advertisesVoltix: advertisesVoltix,
            likelyW3Max: ScooterIdentity.likelyW3Max(advertisedName: displayName)
        )

        if let idx = discovered.firstIndex(where: { $0.id == peripheral.identifier }) {
            discovered[idx] = entry
        } else {
            discovered.append(entry)
        }
        discovered.sort { a, b in
            if a.likelyW3Max != b.likelyW3Max { return a.likelyW3Max && !b.likelyW3Max }
            return a.rssi > b.rssi
        }
    }

    private func voltixService(on peripheral: CBPeripheral) -> CBService? {
        peripheral.services?.first(where: { Voltix.isService($0.uuid) })
    }

    private func tryFinishGATTSetup() {
        guard notifyEnabled, writeCharacteristic != nil else { return }
        cancelSetupTimer()
        bluetoothError = nil
        isConnected = true
        status = "Connected to scooter"
        // Voltix app sends connect twice ~1 s apart.
        send(Voltix.connectFrame())
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.send(Voltix.connectFrame())
            self?.send(Voltix.heartbeatFrame())
        }
        startPolling()
    }

    private func failSetup(_ message: String, disconnect: Bool = true) {
        cancelSetupTimer()
        bluetoothError = message
        status = message
        isConnected = false
        if disconnect, let connected {
            central?.cancelPeripheralConnection(connected)
        }
    }
}

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
        bluetoothError = nil
        status = "Connected. Discovering services…"
        beginSetupTimeout(for: peripheral)
        // Discover all services — filtered discovery + strict UUID compare caused silent hangs.
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        status = "Connect failed: \(error?.localizedDescription ?? "unknown error")"
        resetSessionState()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        cancelSetupTimer()
        pollTimer?.invalidate()
        pollTimer = nil
        resetSessionState()
        status = error == nil ? "Disconnected" : "Disconnected: \(error!.localizedDescription)"
    }
}

extension ScooterController: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            failSetup("Service discovery failed: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services, !services.isEmpty else {
            failSetup("No GATT services on this device—not a Voltix scooter.")
            return
        }
        guard let service = voltixService(on: peripheral) else {
            let listed = services.map { $0.uuid.uuidString }.joined(separator: ", ")
            failSetup("No FF60 service (found: \(listed)). Try another device in the list.")
            return
        }
        status = "Found FF60. Discovering characteristics…"
        peripheral.discoverCharacteristics([Voltix.notifyChar, Voltix.writeChar], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            failSetup("Characteristic discovery failed: \(error.localizedDescription)")
            return
        }
        guard Voltix.isService(service.uuid) else { return }
        guard let characteristics = service.characteristics, !characteristics.isEmpty else {
            failSetup("FF60 service has no characteristics.")
            return
        }

        for c in characteristics {
            if Voltix.isNotify(c.uuid) {
                notifyCharacteristic = c
                peripheral.setNotifyValue(true, for: c)
            } else if Voltix.isWrite(c.uuid) {
                writeCharacteristic = c
            }
        }

        if writeCharacteristic == nil {
            failSetup("Missing FF62 write characteristic on FF60 service.")
            return
        }
        if notifyCharacteristic == nil {
            failSetup("Missing FF61 notify characteristic on FF60 service.")
            return
        }
        if notifyEnabled {
            tryFinishGATTSetup()
        } else {
            status = "Enabling notifications…"
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            failSetup("Notify setup failed: \(error.localizedDescription)")
            return
        }
        guard Voltix.isNotify(characteristic.uuid) else { return }
        notifyEnabled = characteristic.isNotifying
        if notifyEnabled {
            tryFinishGATTSetup()
        } else {
            failSetup("Notifications disabled on FF61.")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil,
              Voltix.isNotify(characteristic.uuid),
              let data = characteristic.value else { return }
        let bytes = [UInt8](data)
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
