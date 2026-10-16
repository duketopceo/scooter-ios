# HopCycle W3 Max — Scooter Remote for iPhone

A lightweight, no-account Swift/SwiftUI app that talks to a HopCycle W3 Max
electric scooter directly over Bluetooth LE. It is a native port of the
Voltix FF60 protocol recovered from the `com.world.voltix` Android APK.

No TestFlight backend. No cloud. No account binding. The radio is CoreBluetooth
on the phone, talking straight to the scooter.

## What it does

- Scan for nearby BLE devices, connect to the scooter
- Live dashboard: speed (km/h), battery %, fault code
- Lock / unlock (with optional 4-digit code)
- Light on/off
- Gear 0/1/2
- Speed limit (km/h)
- Cruise control on/off

## Where the protocol came from

The Voltix byte-level protocol was decompiled from the Android app
`com.world.voltix` (jadx). Full notes: `docs/voltix_ble_protocol.md`.

- Service:  `0000FF60-0000-1000-8000-00805F9B34FB`
- Notify:   `0000FF61-0000-1000-8000-00805F9B34FB` (scooter → phone)
- Write:    `0000FF62-0000-1000-8000-00805F9B34FB` (phone → scooter)
- Frame:    `1A A1 CMD PARAM LEN [PAYLOAD] CRC_lo CRC_hi 1F F1`
- CRC:      CRC-16/MODBUS (poly 0xA001, init 0xFFFF), little-endian

## Confidence

- UUIDs, frame layout, CRC: **high** (read straight out of the decompiled app)
- Telemetry decode (battery byte, speed bit-packing): **provisional** —
  confirm against the scooter's own display before trusting the numbers
- "Right scooter for Voltix protocol": **moderate** — fits the 25 MPH W3 Max
  spec; the physical model label has not been photographed

## What is deliberately refused

The unbind (0x42), disabled-reset (0x43), and OTA (0x91–0x93) commands are
not implemented. This client cannot soft-lock or brick the scooter the way
the Voltix app's account binding can.

## Build it on a Mac

Requires Xcode (macOS). This is a hand-written `.pbxproj`, so it also opens
in Xcode 14+.

1. `open VoltixScooter.xcodeproj`
2. Select your signing team (free personal team works for testing on your
   own iPhone for 7 days at a time)
3. Build and run on a physical iPhone — the iOS **Simulator has no BLE**

Pairing happens inside this app. Do not pair through iOS Settings → Bluetooth.

## Files

- `VoltixScooter/ScooterBLE.swift` — protocol + CoreBluetooth controller
- `VoltixScooter/ContentView.swift` — SwiftUI UI
- `VoltixScooter/VoltixScooterApp.swift` — app entry point

## Note on TestFlight

A direct BLE app needs no backend to function. The Python reference client
(`reference/voltix_client.py`) and the phone app speak the same bytes.