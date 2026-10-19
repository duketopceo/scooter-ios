import SwiftUI

struct ContentView: View {
    @StateObject private var controller = ScooterController()
    @State private var gear = 1
    @State private var speedLimitKmh = 25
    @State private var cruiseOn = false
    @State private var lightOn = false
    @State private var unlockCode = ""

    var body: some View {
        NavigationView {
            Form {
                statusSection
                scanFilterSection
                if !controller.discovered.isEmpty {
                    discoveredSection
                }
                if controller.isConnected {
                    dashboardSection
                    controlsSection
                    noteSection
                } else {
                    identifyHelpSection
                }
            }
            .navigationTitle("W3 Max")
        }
    }

    private var statusSection: some View {
        Section("Bluetooth") {
            Text(controller.status)
            if let message = controller.bluetoothError {
                Text(message).foregroundColor(.red)
            }
            HStack {
                Button(controller.isScanning ? "Stop scan" : "Rescan",
                       action: controller.isScanning ? controller.stopScan : controller.startScan)
                if controller.isConnected {
                    Spacer()
                    Button("Disconnect", role: .destructive, action: controller.disconnect)
                }
            }
        }
    }

    private var scanFilterSection: some View {
        Section("Scan filter") {
            Picker("Show", selection: Binding(
                get: { controller.scanFilter },
                set: { controller.setScanFilter($0) }
            )) {
                ForEach(ScanFilter.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text("HopCycle/W3 Max uses the Voltix FF60 protocol (same as the official Voltix app QR on the stem). Filter by FF60, not by app name “Scooter”.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private var discoveredSection: some View {
        Section("Found devices (strongest signal first)") {
            ForEach(controller.discovered) { item in
                Button {
                    controller.connect(item.peripheral)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.displayName)
                            Text("\(item.rssi) dBm")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if item.likelyW3Max {
                            Text("W3?")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.2))
                                .cornerRadius(4)
                        }
                        if item.advertisesVoltix {
                            Text("FF60")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.15))
                                .cornerRadius(4)
                        }
                        if controller.isConnected && controller.connectedID == item.id {
                            Text("Connected").foregroundColor(.green)
                        }
                    }
                }
            }
        }
    }

    private var dashboardSection: some View {
        Section("Dashboard") {
            LabeledContent("Speed") {
                Text("\(controller.telemetry.speedKmh, specifier: "%.1f") km/h")
            }
            LabeledContent("Battery") {
                Text("\(controller.telemetry.batteryPct)%")
            }
            LabeledContent("Fault code") {
                Text("\(controller.telemetry.faultCode)")
            }
        }
    }

    private var controlsSection: some View {
        Section("Controls") {
            Button("Lock") { controller.lock() }

            HStack {
                TextField("4-digit code (optional)", text: $unlockCode)
                    .keyboardType(.numberPad)
                Button("Unlock") { controller.unlock(pwd: unlockCode.isEmpty ? nil : unlockCode) }
            }

            Toggle("Light", isOn: $lightOn)
                .onChange(of: lightOn) { value in controller.setLight(value) }

            Stepper(value: $gear, in: 0...2) {
                Text("Gear: \(gear)")
            }
            .onChange(of: gear) { value in controller.setGear(value) }

            HStack {
                Stepper(value: $speedLimitKmh, in: 10...40) {
                    Text("Speed limit: \(speedLimitKmh) km/h")
                }
                Button("Set") { controller.setSpeedLimit(speedLimitKmh) }
            }

            Toggle("Cruise control", isOn: $cruiseOn)
                .onChange(of: cruiseOn) { value in controller.setCruise(value ? 1 : 0) }
        }
    }

    private var noteSection: some View {
        Section {
            Text("Battery and speed decoding is provisional. Verify against the scooter's own display before trusting it.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private var identifyHelpSection: some View {
        Section("Find your scooter") {
            Text("Stem sticker: serial \(ScooterIdentity.exampleSerial) (Voltix bind QR). BLE name may include W3MAX or part of that serial—not “HopCycle”.")
            Text("1. Power the scooter on (display awake). BLE is often off when fully asleep.")
            Text("2. Leave Scooters only (FF60) selected and stand within ~2 m.")
            Text("3. Prefer rows tagged W3? or strongest dBm. Wrong device? Disconnect and try the next.")
            Text("You do not need the Voltix app or bind QR for this client—it speaks FF60 directly.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }
}
