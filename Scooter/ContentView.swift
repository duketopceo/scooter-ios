import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: ScooterController
    @EnvironmentObject private var tripRecorder: TripRecorder
    @AppStorage("preferMiles") private var preferMiles = false
    @State private var gear = 1
    @State private var speedLimitKmh = 25
    @State private var cruiseOn = false
    @State private var lightOn = false
    @State private var unlockCode = ""
    @State private var showDebug = false
    @State private var titleTaps = 0
    @State private var zeroStart = false
    @State private var scooterDisplayMiles = false
    @State private var eBrake = 1
    @State private var brightness = 3

    var body: some View {
        NavigationView {
            Form {
                statusSection
                scanFilterSection
                if controller.isConnecting {
                    connectingSection
                }
                if let fav = controller.savedFavorite, !controller.isConnected, !controller.isConnecting {
                    Section("Saved scooter") {
                        Text("Will auto-connect to \(fav.displayName) when it appears.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                if controller.isScanning && controller.discovered.isEmpty && !controller.isConnecting {
                    scanningEmptySection
                }
                if !controller.discovered.isEmpty {
                    discoveredSection
                }
                if controller.isConnected {
                    myScooterSection
                    rideSection
                    dashboardSection
                    controlsSection
                    noteSection
                } else if !controller.isConnecting {
                    identifyHelpSection
                }
            }
            .navigationTitle("W3 Max")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("W3 Max").font(.headline)
                        .onTapGesture {
                            titleTaps += 1
                            if titleTaps >= 5 { titleTaps = 0; showDebug = true }
                        }
                }
            }
            .sheet(isPresented: $showDebug) { DebugView(controller: controller) }
            .onChange(of: controller.telemetry.lightOn) { value in
                if controller.isConnected { lightOn = value }
            }
            .onChange(of: controller.isConnected) { connected in
                if connected { lightOn = controller.telemetry.lightOn }
            }
        }
    }

    private var connectingSection: some View {
        Section("Connection") {
            HStack(spacing: 10) {
                ProgressView()
                Text(controller.status)
                    .foregroundColor(.secondary)
            }
            Button("Cancel", role: .destructive, action: controller.disconnect)
        }
    }

    private var scanningEmptySection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Looking for scooters…")
                    Text("Power the scooter on and stay within ~2 m. Strongest signal rises to the top.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var myScooterSection: some View {
        Section("My scooter") {
            if controller.isCurrentConnectionFavorite {
                Label("Saved as your scooter", systemImage: "star.fill")
                    .foregroundColor(.yellow)
            } else {
                Button("Save as my scooter") {
                    controller.saveFavoriteFromCurrentConnection()
                }
            }
        }
    }

    private var rideSection: some View {
        Section("Trip log") {
            if tripRecorder.isRecording {
                Label("Recording ride…", systemImage: "record.circle")
                    .foregroundColor(.red)
                Button("End ride", role: .destructive) {
                    tripRecorder.endRide()
                }
            } else {
                Button("Start ride") {
                    tripRecorder.startRide()
                }
            }
            if let err = tripRecorder.locationError {
                Text(err).font(.footnote).foregroundColor(.red)
            }
            Text("GPS route and scooter speed are saved on this device. View past rides on the Trips tab.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private var statusSection: some View {
        Section("Bluetooth") {
            Text(controller.status)
            if let message = controller.bluetoothError {
                Text(message).foregroundColor(.red)
                if needsBluetoothSettingsLink(message) {
                    Button("Open Bluetooth settings") {
                        openBluetoothSettings()
                    }
                }
            }
            HStack {
                Button(controller.isScanning ? "Stop scan" : "Rescan",
                       action: controller.isScanning ? controller.stopScan : controller.startScan)
                    .disabled(controller.isConnecting || !controller.bluetoothReady)
                if controller.isConnected || controller.isConnecting {
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
            .disabled(controller.isConnecting)
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
                        } else if controller.isConnecting && controller.connectedID == item.id {
                            ProgressView()
                        }
                    }
                }
                .disabled(controller.isConnecting)
            }
        }
    }

    private var dashboardSection: some View {
        Section("Dashboard") {
            let t = controller.telemetry
            LabeledContent("Speed") { Text(formattedSpeed(t.speedKmh)) }
            LabeledContent("Battery") { Text("\(t.batteryPct)%") }
            if let l = t.speedLimitKmh {
                LabeledContent("Speed limit (from scooter)") {
                    Text(preferMiles
                          ? String(format: "%.0f mph", Double(l) / 1.609)
                          : "\(l) km/h")
                }
            }
            LabeledContent("Lights (from scooter)") {
                Text(t.lightOn ? "on" : "off")
                    + Text(String(format: "  0x%02X", t.lightFlags)).foregroundColor(.secondary)
            }
            LabeledContent("Fault code") {
                Text(t.faultCode == 0 ? "none" : String(format: "0x%02X", t.faultCode))
            }
            if let v = t.voltage { LabeledContent("Voltage (exp.)") { Text("\(v, specifier: "%.2f") V") } }
            if let a = t.currentA { LabeledContent("Current (exp.)") { Text("\(a, specifier: "%.2f") A") } }
            if let c = t.tempC { LabeledContent("Temp (exp.)") { Text("\(c, specifier: "%.1f") °C") } }
            if let trip = t.tripRaw {
                LabeledContent("Trip raw (exp.)") { Text(Voltix.hex(trip)).font(.caption.monospaced()) }
            }
            if let sn = t.serial, !sn.isEmpty { LabeledContent("Serial") { Text(sn) } }
            if let fw = t.firmware {
                LabeledContent("Firmware (exp.)") { Text(fw).font(.caption.monospaced()) }
            }
            if t.lastUpdate == nil {
                Text("No telemetry yet. The app tries a second poll shape after 4 s.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Toggle("Show speed in mph", isOn: $preferMiles)
            Button("Refresh scooter info") { controller.queryAll() }
        }
    }

    private var controlsSection: some View {
        Group {
            Section("Controls") {
                Stepper(value: $gear, in: 0...3) { Text("Gear: \(gear)  (works)") }
                    .onChange(of: gear) { value in controller.setGear(value) }
                Toggle("Light" + (controller.winners["light"] == nil ? " (experimental)" : ""), isOn: $lightOn)
                    .onChange(of: lightOn) { value in controller.setLight(value) }
                HStack {
                    Stepper(value: $speedLimitKmh, in: 6...40) {
                        Text(preferMiles
                              ? String(format: "Speed limit: %.0f mph (exp.)", Double(speedLimitKmh) / 1.609)
                              : "Speed limit: \(speedLimitKmh) km/h (exp.)")
                    }
                    Button("Set") { controller.setSpeedLimit(speedLimitKmh) }
                }
                Toggle("Cruise control (exp.)", isOn: $cruiseOn)
                    .onChange(of: cruiseOn) { value in controller.setCruise(value) }
                Button("Lock (exp.)") { controller.lock() }
                HStack {
                    TextField("4-digit code (optional)", text: $unlockCode).keyboardType(.numberPad)
                    Button("Unlock (exp.)") { controller.unlock(pwd: unlockCode.isEmpty ? nil : unlockCode) }
                }
            }
            Section("More settings (experimental)") {
                Toggle("Zero-start (off = kick to start)", isOn: $zeroStart)
                    .onChange(of: zeroStart) { v in controller.setStartMode(zeroStart: v) }
                Toggle("Scooter display in miles (exp.)", isOn: $scooterDisplayMiles)
                    .onChange(of: scooterDisplayMiles) { v in controller.setUnits(miles: v) }
                Stepper(value: $eBrake, in: 0...3) { Text("Electronic brake: \(eBrake)") }
                    .onChange(of: eBrake) { v in controller.setEBrake(v) }
                Stepper(value: $brightness, in: 1...5) { Text("Display brightness: \(brightness)") }
                    .onChange(of: brightness) { v in controller.setGaugeBrightness(v) }
                Text("Not in the Voltix protocol: horn. Tap the title 5× for the Debug panel to test light and speed shapes.")
                    .font(.footnote).foregroundColor(.secondary)
            }
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

    private func formattedSpeed(_ kmh: Double) -> String {
        if preferMiles {
            return String(format: "%.1f mph (%.1f km/h)", kmh / 1.609, kmh)
        }
        return String(format: "%.1f km/h (%.1f mph)", kmh, kmh / 1.609)
    }

    private func needsBluetoothSettingsLink(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("permission")
            || message.localizedCaseInsensitiveContains("Bluetooth is off")
    }

    private func openBluetoothSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
