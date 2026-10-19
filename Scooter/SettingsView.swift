import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var controller: ScooterController

    var body: some View {
        NavigationView {
            Form {
                Section("My scooter") {
                    if let fav = controller.savedFavorite {
                        LabeledContent("Saved as") { Text(fav.displayName) }
                        LabeledContent("BLE UUID") {
                            Text(fav.id.uuidString)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                        Button("Forget saved scooter", role: .destructive) {
                            controller.clearSavedFavorite()
                        }
                    } else {
                        Text("No favorite saved. Connect and tap “Save as my scooter” on the Scooter tab.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Connection") {
                    Toggle("Auto-connect to saved scooter", isOn: Binding(
                        get: { controller.autoConnectEnabled },
                        set: { controller.setAutoConnect($0) }
                    ))
                    Text("On launch, the app tries to reconnect to your saved scooter before showing the scan list.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("Trips") {
                    Text("Ride history is stored on this device only—not synced to Apple Health.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
