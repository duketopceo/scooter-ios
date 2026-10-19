import SwiftUI
import UIKit

/// Hidden panel (tap the title 5×): live hex log of every write and notification, a raw sender, and
/// "try variants" cyclers that send one candidate frame at a time so you can see which one the scooter obeys.
struct DebugView: View {
    @ObservedObject var controller: ScooterController
    @Environment(\.dismiss) private var dismiss
    @State private var raw = "33 02 01"
    @State private var addFraming = true
    @State private var writeMode = 0
    @State private var speedValue = 20

    var body: some View {
        NavigationView {
            Form {
                Section("Find the working frame") {
                    if let r = controller.runner, let c = r.current {
                        Text("\(r.kind.title) #\(r.index + 1) of \(r.candidates.count)").font(.headline)
                        Text(c.label)
                        Text(Voltix.hex(c.frame)).font(.caption.monospaced())
                        Text(r.kind == .poll ? "Did Speed/Battery start updating?" : "Did the scooter react?").font(.footnote)
                        HStack {
                            Button("✅ It worked") { controller.markWorked() }.buttonStyle(.borderedProminent)
                            Spacer()
                            Button("Resend") { controller.sendCurrentVariant() }
                            Spacer()
                            Button("Next ▶") { controller.nextVariant() }
                        }
                        Button("Stop", role: .cancel) { controller.runner = nil }
                    } else {
                        Button("Try light variants") { controller.startVariants(.light) }
                        HStack {
                            Stepper("Speed \(speedValue) km/h", value: $speedValue, in: 6...40)
                            Button("Try") { controller.startVariants(.speed, value: speedValue) }
                        }
                        Button("Try cruise variants") { controller.startVariants(.cruise, value: 1) }
                        Button("Try telemetry poll variants") { controller.startVariants(.poll) }
                    }
                    ForEach(["light", "speed", "cruise", "poll"], id: \.self) { k in
                        if let hex = controller.winners[k] {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("Saved \(k): \(controller.winners[k + ".label"] ?? "")").font(.footnote)
                                    Text(hex).font(.caption2.monospaced())
                                }
                                Spacer()
                                Button("Clear") { controller.clearWinner(VariantRunner.Kind(rawValue: k)!) }.font(.footnote)
                            }
                        }
                    }
                }

                Section("Raw command") {
                    TextField("hex", text: $raw).font(.body.monospaced()).autocorrectionDisabled().textInputAutocapitalization(.characters)
                    Toggle("Add framing (type CMD PARAM PAYLOAD…)", isOn: $addFraming)
                    Picker("Write", selection: $writeMode) {
                        Text("Auto").tag(0); Text("No response").tag(1); Text("With response").tag(2)
                    }.pickerStyle(.segmented)
                    Button("Send") { controller.sendRaw(raw, addFraming: addFraming, withResponse: writeMode == 0 ? nil : writeMode == 2) }
                    Text("FF62 supports: \(controller.writeTypeNote.isEmpty ? "?" : controller.writeTypeNote). Bind/reset/OTA (3A, 42, 43, 91–93) are blocked.")
                        .font(.footnote).foregroundColor(.secondary)
                }

                Section("Last telemetry payload (0x60)") {
                    let p = controller.telemetry.rawQueryCar
                    Text(p.isEmpty ? "none yet" : p.enumerated().map { "[\($0.offset)]\(String(format: "%02X", $0.element))" }.joined(separator: " "))
                        .font(.caption.monospaced())
                }

                Section {
                    HStack {
                        Button("Copy log") { UIPasteboard.general.string = controller.logText }
                        Spacer()
                        Button("Clear", role: .destructive) { controller.log.removeAll() }
                    }
                    ForEach(controller.log.suffix(300).reversed()) { l in
                        Text(l.line).font(.caption2.monospaced())
                            .foregroundColor(l.dir == .tx ? .blue : l.dir == .rx ? .green : (l.text.contains("WORKED") ? .orange : .secondary))
                    }
                } header: { Text("Log (newest first)") }
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
