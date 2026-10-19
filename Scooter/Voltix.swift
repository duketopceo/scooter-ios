import Foundation
import CoreBluetooth

// Voltix FF60 protocol (docs/voltix_ble_protocol.md). Frame:
// [1A A1] [CMD] [PARAM] [LEN] [PAYLOAD…] [CRC lo] [CRC hi] [1F F1], CRC-16/MODBUS over CMD..PAYLOAD.
// Only connect, heartbeat, query-car and gear are confirmed on Luke's W3 Max (build 20261019171902).
// Everything else is experimental until the Debug panel shows the scooter reacting.

struct ScooterTelemetry {
    var batteryPct: Int = 0
    var faultCode: UInt8 = 0
    var speedKmh: Double = 0
    var lightFlags: UInt8 = 0
    var statusFlags: UInt8 = 0
    var speedLimitKmh: Int?
    var voltage: Double?
    var currentA: Double?
    var tempC: Double?
    var tripRaw: [UInt8]?
    var serial: String?
    var firmware: String?
    /// Last raw 0x60 payload so unknown fields (odometer, trip) can be read off the Debug panel.
    var rawQueryCar: [UInt8] = []
    var lastUpdate: Date?

    var lightOn: Bool { lightFlags & 0x01 != 0 }
    var locked: Bool { statusFlags & 0x02 != 0 }   // experimental bit
    var cruiseOn: Bool { statusFlags & 0x04 != 0 }  // experimental bit
    var charging: Bool { statusFlags & 0x08 != 0 }  // experimental bit
}

enum Voltix {
    static let serviceString = "0000FF60-0000-1000-8000-00805F9B34FB"
    static let notifyString  = "0000FF61-0000-1000-8000-00805F9B34FB"
    static let writeString   = "0000FF62-0000-1000-8000-00805F9B34FB"

    static let service = CBUUID(string: serviceString)
    static let notifyChar = CBUUID(string: notifyString)
    static let writeChar = CBUUID(string: writeString)

    /// iOS reports 16-bit UUIDs (`FF60`) or the full base UUID; match either exactly.
    static func matches(_ uuid: CBUUID, shortHex: String) -> Bool {
        let u = uuid.uuidString.uppercased()
        let short = shortHex.uppercased()
        return u == short || u == "0000\(short)-0000-1000-8000-00805F9B34FB"
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
        return lists.contains { $0?.contains(where: isService) ?? false }
    }

    enum Cmd: UInt8 {
        case heartbeat = 0x10, connect = 0x30, powerOn = 0x31, lock = 0x32, light = 0x33
        case gaugeBrightness = 0x34, gear = 0x35, speedLimit = 0x36, eBrake = 0x37, cruise = 0x38
        case startMode = 0x39, driveMode = 0x3B, unit = 0x3C, singleMile = 0x3E, smartLock = 0x47
        case queryCar = 0x60, querySN = 0x61, querySpeedLimit = 0x62, queryLight = 0x63
        case queryBMSVoltage = 0x64, queryBMSInfo = 0x65, queryFirmware = 0x66
    }

    /// Commands that touch binding, reset or firmware. Never sent, not even from the raw sender.
    static let forbidden: Set<UInt8> = [0x3A, 0x42, 0x43, 0x91, 0x92, 0x93]

    static func crc16Modbus(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in bytes {
            crc ^= UInt16(b)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }

    static func frame(_ cmd: UInt8, param: UInt8, payload: [UInt8] = [], crcBigEndian: Bool = false) -> Data {
        let body: [UInt8] = [cmd, param, UInt8(payload.count)] + payload
        let crc = crc16Modbus(body)
        let lo = UInt8(crc & 0xFF), hi = UInt8(crc >> 8)
        return Data([0x1A, 0xA1] + body + (crcBigEndian ? [hi, lo] : [lo, hi]) + [0x1F, 0xF1])
    }

    static func frame(cmd: Cmd, param: UInt8, payload: [UInt8] = []) -> Data { frame(cmd.rawValue, param: param, payload: payload) }

    static func connectFrame() -> Data { frame(cmd: .connect, param: 2, payload: [0x01]) }
    static func heartbeatFrame() -> Data { frame(cmd: .heartbeat, param: 1) }
    /// The doc lists a `[sub]` payload for 0x60. The old build sent none; `sub` is chosen in the Debug panel.
    static func queryCarFrame(sub: UInt8?) -> Data { frame(cmd: .queryCar, param: 1, payload: sub.map { [$0] } ?? []) }
    static func query(_ cmd: Cmd, sub: UInt8? = nil) -> Data { frame(cmd: cmd, param: 1, payload: sub.map { [$0] } ?? []) }

    static func lockFrame() -> Data { frame(cmd: .lock, param: 2, payload: [0x00]) }
    static func unlockFrame(password: String?) -> Data {
        var payload: [UInt8] = [0x00]
        if let pw = password, pw.count == 4, pw.allSatisfy(\.isNumber) { payload += pw.compactMap { $0.wholeNumberValue.map(UInt8.init) } }
        return frame(cmd: .lock, param: 2, payload: payload)
    }
    static func gearFrame(_ g: Int) -> Data { frame(cmd: .gear, param: 2, payload: [UInt8(clamping: g)]) }

    // MARK: Parsing

    /// Splits a byte stream into whole frames (notifications can arrive split or joined).
    static func extractFrames(_ buffer: inout [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        while true {
            guard let start = (0..<max(0, buffer.count - 1)).first(where: { buffer[$0] == 0x1A && buffer[$0 + 1] == 0xA1 }) else {
                if buffer.count > 1 { buffer = Array(buffer.suffix(1)) }
                return out
            }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 5 else { return out }
            let total = 9 + Int(buffer[4])
            if buffer.count >= total, buffer[total - 2] == 0x1F, buffer[total - 1] == 0xF1 {
                out.append(Array(buffer[0..<total]))
                buffer.removeFirst(total)
                continue
            }
            // Length byte disagrees: fall back to the next footer.
            if let end = (5..<max(5, buffer.count - 1)).first(where: { buffer[$0] == 0x1F && buffer[$0 + 1] == 0xF1 }), buffer.count >= total || end + 2 < total {
                out.append(Array(buffer[0...(end + 1)]))
                buffer.removeFirst(end + 2)
                continue
            }
            if buffer.count > 600 { buffer.removeAll() }
            return out
        }
    }

    /// Payload of a frame (bytes after `1A A1 CMD PARAM LEN`, before CRC and footer).
    static func payload(_ f: [UInt8]) -> [UInt8] {
        guard f.count >= 9 else { return [] }
        return Array(f[5..<(f.count - 4)])
    }

    static func crcOK(_ f: [UInt8]) -> Bool {
        guard f.count >= 9 else { return false }
        let body = Array(f[2..<(f.count - 4)])
        let crc = crc16Modbus(body)
        let lo = f[f.count - 4], hi = f[f.count - 3]
        return (lo == UInt8(crc & 0xFF) && hi == UInt8(crc >> 8)) || (hi == UInt8(crc & 0xFF) && lo == UInt8(crc >> 8))
    }

    /// Meter-1 telemetry (cmd 0x60). Offsets from the app's parser, relative to the payload.
    static func applyQueryCar(_ p: [UInt8], to t: inout ScooterTelemetry) {
        t.rawQueryCar = p
        t.lastUpdate = Date()
        guard p.count >= 5 else { return }
        t.lightFlags = p[0]
        t.statusFlags = p[1]
        t.faultCode = p[2]
        if p[3] <= 100 { t.batteryPct = Int(p[3]) }
        let high = p.count > 8 ? Int(p[8] & 0x03) : 0
        t.speedKmh = Double(Int(p[4]) | (high << 8)) * 0.1
        if p.count > 7, p[7] > 0, p[7] < 80 { t.speedLimitKmh = Int(p[7]) }
    }

    /// Meter-2 block (voltage, current, temperature). Experimental.
    static func applyMeter2(_ p: [UInt8], to t: inout ScooterTelemetry) {
        func u16(_ i: Int) -> Int? { p.count > i + 1 ? Int(p[i]) | Int(p[i + 1]) << 8 : nil }
        if let v = u16(2) { t.voltage = Double(v) * 0.01 }
        if let a = u16(4) { t.currentA = Double(a) * 0.01 }
        if p.count > 11 { t.tempC = Double(p[11]) * 0.1 }
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
    static func hex(_ d: Data) -> String { hex([UInt8](d)) }

    /// "1A A1 33 02 01 01" or "1aa1330201" -> bytes; nil on bad hex.
    static func parseHex(_ s: String) -> [UInt8]? {
        let clean = s.uppercased().filter { "0123456789ABCDEF".contains($0) }
        guard clean.count % 2 == 0, !clean.isEmpty else { return nil }
        var out: [UInt8] = []
        var i = clean.startIndex
        while i < clean.endIndex {
            let j = clean.index(i, offsetBy: 2)
            guard let b = UInt8(clean[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        return out
    }
}

/// One frame to try, for the "try variants" cyclers.
struct Candidate: Identifiable, Hashable {
    let id: String
    let label: String
    let frame: Data
    let withResponse: Bool?

    static func make(_ label: String, _ cmd: UInt8, param: UInt8, _ payload: [UInt8], crcBE: Bool = false, withResponse: Bool? = nil) -> Candidate {
        let f = Voltix.frame(cmd, param: param, payload: payload, crcBigEndian: crcBE)
        let tag = withResponse.map { $0 ? " (write w/ response)" : " (write no response)" } ?? ""
        return Candidate(id: label + tag + Voltix.hex(f), label: label + tag, frame: f, withResponse: withResponse)
    }

    /// Light ON variants. The old build sent 33 02 [01] and the light did not change.
    static func lightOn() -> [Candidate] {
        var c: [Candidate] = [
            make("33 p2 [01]", 0x33, param: 2, [0x01]),
            make("33 p2 [01 01]", 0x33, param: 2, [0x01, 0x01]),
            make("33 p2 [00 01]", 0x33, param: 2, [0x00, 0x01]),
            make("33 p2 [01 00]", 0x33, param: 2, [0x01, 0x00]),
            make("33 p2 [02] (bit 1)", 0x33, param: 2, [0x02]),
            make("33 p2 [03] (head+tail)", 0x33, param: 2, [0x03]),
            make("33 p2 [FF]", 0x33, param: 2, [0xFF]),
            make("33 p2 [01 01 01]", 0x33, param: 2, [0x01, 0x01, 0x01]),
            make("33 p1 [01]", 0x33, param: 1, [0x01]),
            make("33 p0 [01]", 0x33, param: 0, [0x01]),
            make("33 p2 [01] CRC hi-lo", 0x33, param: 2, [0x01], crcBE: true),
            make("33 p2 [] (toggle?)", 0x33, param: 2, []),
        ]
        c.append(make("33 p2 [01]", 0x33, param: 2, [0x01], withResponse: true))
        c.append(make("33 p2 [01]", 0x33, param: 2, [0x01], withResponse: false))
        return c
    }

    /// Speed limit variants for `kmh` (the old build sent 36 02 [kmh]).
    static func speedLimit(_ kmh: Int) -> [Candidate] {
        let k = UInt8(clamping: kmh)
        let mph = UInt8(clamping: Int((Double(kmh) / 1.609).rounded()))
        let tenths = kmh * 10
        return [
            make("36 p2 [\(kmh) km/h]", 0x36, param: 2, [k]),
            make("36 p2 [\(mph) mph]", 0x36, param: 2, [mph]),
            make("36 p2 [\(kmh), 00]", 0x36, param: 2, [k, 0x00]),
            make("36 p2 [00, \(kmh)]", 0x36, param: 2, [0x00, k]),
            make("36 p2 [\(kmh)×10 LE]", 0x36, param: 2, [UInt8(tenths & 0xFF), UInt8(tenths >> 8)]),
            make("36 p1 [\(kmh)]", 0x36, param: 1, [k]),
            make("36 p2 [\(kmh)]", 0x36, param: 2, [k], withResponse: true),
        ]
    }

    /// Cruise ON variants (the old build sent 38 02 [01]; the doc says [gear, mode]).
    static func cruiseOn(gear: Int) -> [Candidate] {
        let g = UInt8(clamping: gear)
        return [
            make("38 p2 [01]", 0x38, param: 2, [0x01]),
            make("38 p2 [01 01]", 0x38, param: 2, [0x01, 0x01]),
            make("38 p2 [gear \(gear), 01]", 0x38, param: 2, [g, 0x01]),
            make("38 p2 [01, 00]", 0x38, param: 2, [0x01, 0x00]),
            make("38 p2 [00 01]", 0x38, param: 2, [0x00, 0x01]),
        ]
    }

    /// Telemetry poll variants (the old build sent 60 01 with no payload).
    static func queryCar() -> [Candidate] {
        [
            make("60 p1 []", 0x60, param: 1, []),
            make("60 p1 [01] (meter 1)", 0x60, param: 1, [0x01]),
            make("60 p1 [00]", 0x60, param: 1, [0x00]),
            make("60 p1 [02] (meter 2)", 0x60, param: 1, [0x02]),
            make("60 p1 [20] (Meter11)", 0x60, param: 1, [0x20]),
            make("60 p1 [21] (Meter22)", 0x60, param: 1, [0x21]),
        ]
    }
}
