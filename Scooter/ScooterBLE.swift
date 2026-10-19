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
    @Published var log: [LogLine] = []
    @Published var runner: VariantRunner?
    @Published var winners: [String: String] = UserDefaults.standard.dictionary(forKey: "voltix.winners") as? [String: String] ?? [:]
    @Published var writeTypeNote = ""
    private var rx: [UInt8] = []
    private var pollsWithoutReply = 0
    private var pollFrame: Data = Voltix.queryCarFrame(sub: nil)

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
        rx.removeAll()
        runner = nil
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

    /// Writes one frame to FF62 and logs it. `withResponse` nil = what the characteristic offers (no-response first).
    @discardableResult
    func send(_ data: Data, note: String = "", withResponse: Bool? = nil) -> Bool {
        let bytes = [UInt8](data)
        if bytes.count > 2, Voltix.forbidden.contains(bytes[2]) {
            addLog(.info, "REFUSED \(Voltix.hex(bytes)): bind/reset/OTA commands are blocked")
            return false
        }
        guard let connected, let writeCharacteristic else {
            addLog(.info, "Not connected: \(note)")
            return false
        }
        let props = writeCharacteristic.properties
        let type: CBCharacteristicWriteType
        if let withResponse {
            type = withResponse ? .withResponse : .withoutResponse
        } else {
            type = props.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        }
        connected.writeValue(data, for: writeCharacteristic, type: type)
        addLog(.tx, "\(Voltix.hex(bytes))\(note.isEmpty ? "" : "  \(note)")\(type == .withResponse ? "  [w/resp]" : "")")
        return true
    }

    func sendRaw(_ hex: String, addFraming: Bool, withResponse: Bool?) {
        guard let bytes = Voltix.parseHex(hex) else { addLog(.info, "Bad hex: \(hex)"); return }
        if addFraming {
            // "CMD PARAM PAYLOAD…" -> full frame with length, CRC and footer.
            guard bytes.count >= 2 else { addLog(.info, "Need at least CMD and PARAM"); return }
            send(Voltix.frame(bytes[0], param: bytes[1], payload: Array(bytes.dropFirst(2))), note: "raw", withResponse: withResponse)
        } else {
            send(Data(bytes), note: "raw", withResponse: withResponse)
        }
    }

    func addLog(_ dir: LogLine.Dir, _ text: String) {
        log.append(LogLine(time: Date(), dir: dir, text: text))
        if log.count > 800 { log.removeFirst(log.count - 800) }
    }

    var logText: String { log.map(\.line).joined(separator: "\n") }

    // MARK: Commands (confirmed: gear. Everything else experimental until a winner is saved.)

    func lock()                    { send(Voltix.lockFrame(), note: "lock") }
    func unlock(pwd: String?)      { send(Voltix.unlockFrame(password: pwd), note: "unlock") }
    func setGear(_ g: Int)         { send(Voltix.gearFrame(g), note: "gear \(g)") }

    func setLight(_ on: Bool) {
        if let saved = winnerFrame("light") {
            send(on ? saved : Self.zeroed(saved), note: "light \(on ? "on" : "off") (saved winner)")
        } else {
            // Untested on this scooter: try the two most likely shapes.
            send(Voltix.frame(0x33, param: 2, payload: [on ? 1 : 0]), note: "light \(on ? "on" : "off") [v1]")
            send(Voltix.frame(0x33, param: 2, payload: [on ? 1 : 0, on ? 1 : 0]), note: "light \(on ? "on" : "off") [v2]")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.send(Voltix.query(.queryLight), note: "query lights") }
    }

    func setSpeedLimit(_ kmh: Int) {
        if let saved = winnerFrame("speed") {
            // Rebuild the winning shape with the new value in its first payload byte.
            var p = Voltix.payload([UInt8](saved)); if !p.isEmpty { p[0] = UInt8(clamping: kmh) }
            let b = [UInt8](saved)
            send(Voltix.frame(b[2], param: b[3], payload: p), note: "speed limit \(kmh) (saved shape)")
        } else {
            send(Voltix.frame(0x36, param: 2, payload: [UInt8(clamping: kmh)]), note: "speed limit \(kmh) km/h")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.send(Voltix.query(.querySpeedLimit), note: "query speed limit") }
    }

    func setCruise(_ on: Bool) {
        if let saved = winnerFrame("cruise") {
            send(on ? saved : Self.zeroed(saved), note: "cruise \(on ? "on" : "off") (saved winner)")
        } else {
            send(Voltix.frame(0x38, param: 2, payload: [on ? 1 : 0]), note: "cruise \(on ? "on" : "off")")
        }
    }

    /// Experimental settings from the app's command table.
    func setStartMode(zeroStart: Bool) { send(Voltix.frame(0x39, param: 2, payload: [zeroStart ? 1 : 0, 0]), note: "start mode \(zeroStart ? "zero-start" : "kick")") }
    func setUnits(miles: Bool) { send(Voltix.frame(0x3C, param: 2, payload: [miles ? 1 : 0]), note: "units \(miles ? "mi" : "km")") }
    func setEBrake(_ level: Int) { send(Voltix.frame(0x37, param: 2, payload: [UInt8(clamping: level)]), note: "e-brake \(level)") }
    func setGaugeBrightness(_ level: Int) { send(Voltix.frame(0x34, param: 2, payload: [UInt8(clamping: level)]), note: "brightness \(level)") }
    func setDriveMode(_ mode: Int) { send(Voltix.frame(0x3B, param: 2, payload: [UInt8(clamping: mode)]), note: "drive mode \(mode)") }
    func setSmartLock(_ on: Bool) { send(Voltix.frame(0x47, param: 2, payload: [on ? 1 : 0]), note: "smart lock \(on)") }

    func queryAll() {
        let qs: [(Voltix.Cmd, UInt8?, String)] = [(.querySN, nil, "serial"), (.querySpeedLimit, nil, "speed limit"), (.queryLight, nil, "lights"),
                                                  (.queryBMSVoltage, 0, "BMS voltage"), (.queryBMSInfo, 0, "BMS info"), (.queryFirmware, 0, "firmware")]
        for (i, q) in qs.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.3) { [weak self] in self?.send(Voltix.query(q.0, sub: q.1), note: "query \(q.2)") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.send(Voltix.frame(0x3E, param: 1), note: "query trip (0x3E)") }
    }

    // MARK: Variant runner

    func startVariants(_ kind: VariantRunner.Kind, value: Int = 0) {
        let list: [Candidate]
        switch kind {
        case .light: list = Candidate.lightOn()
        case .speed: list = Candidate.speedLimit(value)
        case .cruise: list = Candidate.cruiseOn(gear: value)
        case .poll: list = Candidate.queryCar()
        }
        runner = VariantRunner(kind: kind, candidates: list, index: 0)
        addLog(.info, "--- \(kind.title) variants: \(list.count) to try ---")
        sendCurrentVariant()
    }

    func sendCurrentVariant() {
        guard let r = runner, r.index < r.candidates.count else { return }
        let c = r.candidates[r.index]
        if r.kind == .poll { pollFrame = c.frame; pollsWithoutReply = 0 }
        send(c.frame, note: "\(r.kind.title) #\(r.index + 1): \(c.label)", withResponse: c.withResponse)
    }

    func nextVariant() {
        guard var r = runner else { return }
        if r.kind == .light, r.index < r.candidates.count {
            // Put the light back before the next shape so each try starts from off.
            send(Self.zeroed(r.candidates[r.index].frame), note: "undo #\(r.index + 1)", withResponse: r.candidates[r.index].withResponse)
        }
        r.index += 1
        runner = r
        if r.index >= r.candidates.count {
            addLog(.info, "--- \(r.kind.title): no more variants. Copy the log and send it over. ---")
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.sendCurrentVariant() }
        }
    }

    func markWorked() {
        guard let r = runner, r.index < r.candidates.count else { return }
        let c = r.candidates[r.index]
        winners[r.kind.rawValue] = Voltix.hex(c.frame)
        winners[r.kind.rawValue + ".label"] = c.label
        UserDefaults.standard.set(winners, forKey: "voltix.winners")
        addLog(.info, "*** WORKED: \(r.kind.title) #\(r.index + 1) \(c.label) = \(Voltix.hex(c.frame)) (saved) ***")
        runner = nil
    }

    func clearWinner(_ kind: VariantRunner.Kind) {
        winners[kind.rawValue] = nil; winners[kind.rawValue + ".label"] = nil
        UserDefaults.standard.set(winners, forKey: "voltix.winners")
        if kind == .poll { pollFrame = Voltix.queryCarFrame(sub: nil) }
    }

    private func winnerFrame(_ key: String) -> Data? { winners[key].flatMap(Voltix.parseHex).map { Data($0) } }

    /// Same frame with every payload byte set to 0 (the "off" of an "on" shape), CRC rebuilt.
    static func zeroed(_ frame: Data) -> Data {
        let b = [UInt8](frame)
        guard b.count >= 9 else { return frame }
        let p = Voltix.payload(b).map { _ in UInt8(0) }
        let crc = Voltix.crc16Modbus(Array(b[2..<(b.count - 4)]))
        let bigEndian = b[b.count - 4] == UInt8(crc >> 8) && b[b.count - 3] == UInt8(crc & 0xFF) && (crc >> 8) != (crc & 0xFF)
        return Voltix.frame(b[2], param: b[3], payload: p, crcBigEndian: bigEndian)
    }

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
        if let c = writeCharacteristic {
            var props: [String] = []
            if c.properties.contains(.write) { props.append("write") }
            if c.properties.contains(.writeWithoutResponse) { props.append("writeWithoutResponse") }
            writeTypeNote = props.joined(separator: ", ")
            addLog(.info, "Connected. FF62 supports: \(writeTypeNote). MTU (no response): \(connected?.maximumWriteValueLength(for: .withoutResponse) ?? 0)")
        }
        if let w = winnerFrame("poll") { pollFrame = w }
        // Voltix app sends connect twice ~1 s apart, then a heartbeat.
        send(Voltix.connectFrame(), note: "connect")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.send(Voltix.connectFrame(), note: "connect")
            self?.send(Voltix.heartbeatFrame(), note: "heartbeat")
            self?.queryAll()
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

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { addLog(.info, "Write error: \(error.localizedDescription)") }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, Voltix.isNotify(characteristic.uuid), let data = characteristic.value else { return }
        rx += [UInt8](data)
        let frames = Voltix.extractFrames(&rx)
        if frames.isEmpty { addLog(.rx, "\(Voltix.hex(data))  (partial)") }
        for f in frames { handle(f) }
    }

    private func handle(_ f: [UInt8]) {
        let p = Voltix.payload(f)
        let cmd = f[2]
        let name = Voltix.Cmd(rawValue: cmd).map { "\($0)" } ?? String(format: "0x%02X", cmd)
        let crc = Voltix.crcOK(f) ? "" : "  CRC?"
        // The 1 s telemetry poll would flood the log: keep a 0x60 line only when it changed.
        if cmd != Voltix.Cmd.queryCar.rawValue || p != telemetry.rawQueryCar {
            addLog(.rx, "\(Voltix.hex(f))  \(name)\(crc)")
        }
        switch cmd {
        case Voltix.Cmd.queryCar.rawValue:
            pollsWithoutReply = 0
            if f[3] == 2 || p.count >= 14 { var t = telemetry; Voltix.applyMeter2(p, to: &t); telemetry = t }
            if p.count >= 5 { var t = telemetry; Voltix.applyQueryCar(p, to: &t); telemetry = t }
        case Voltix.Cmd.querySpeedLimit.rawValue:
            if let v = p.first, v > 0, v < 80 { telemetry.speedLimitKmh = Int(v) }
        case Voltix.Cmd.queryLight.rawValue, Voltix.Cmd.light.rawValue:
            if let v = p.first { telemetry.lightFlags = v }
        case Voltix.Cmd.querySN.rawValue:
            telemetry.serial = String(bytes: p.filter { $0 >= 0x20 && $0 < 0x7F }, encoding: .ascii)
        case Voltix.Cmd.queryFirmware.rawValue:
            telemetry.firmware = Voltix.hex(p)
        case Voltix.Cmd.queryBMSVoltage.rawValue, Voltix.Cmd.queryBMSInfo.rawValue:
            var t = telemetry; Voltix.applyMeter2(p, to: &t); telemetry = t
        case Voltix.Cmd.singleMile.rawValue:
            telemetry.tripRaw = p
        default:
            break
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.send(self.pollFrame, note: "")
            self.pollsWithoutReply += 1
            // No telemetry after 4 polls with the old empty frame: the doc says 0x60 takes a [sub] byte.
            if self.pollsWithoutReply == 4, self.winners["poll"] == nil, self.runner?.kind != .poll {
                self.pollFrame = self.pollFrame.count == 9 ? Voltix.queryCarFrame(sub: 0x01) : Voltix.queryCarFrame(sub: nil)
                self.addLog(.info, "No telemetry yet: switching poll to \(Voltix.hex(self.pollFrame))")
                self.pollsWithoutReply = 0
            }
        }
    }
}

struct LogLine: Identifiable {
    enum Dir: String { case tx = "→", rx = "←", info = "•" }
    let id = UUID()
    let time: Date
    let dir: Dir
    let text: String
    var line: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        return "\(f.string(from: time)) \(dir.rawValue) \(text)"
    }
}

struct VariantRunner {
    enum Kind: String { case light, speed, cruise, poll
        var title: String {
            switch self {
            case .light: "Light"
            case .speed: "Speed limit"
            case .cruise: "Cruise"
            case .poll: "Telemetry poll"
            }
        }
    }
    let kind: Kind
    let candidates: [Candidate]
    var index: Int
    var current: Candidate? { index < candidates.count ? candidates[index] : nil }
}
