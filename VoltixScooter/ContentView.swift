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
                if !controller.discovered.isEmpty {
                    discoveredSection
                }
                if controller.isConnected {
                    dashboardSection
                    controlsSection
                    noteSection
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

    private var discoveredSection: some View {
        Section("Found devices") {
            ForEach(controller.discovered, id: \.identifier) { peripheral in
                Button {
                    controller.connect(peripheral)
                } label: {
                    HStack {
                        Text(peripheral.name ?? "Unnamed device")
                        Spacer()
                        if controller.isConnected {
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
}