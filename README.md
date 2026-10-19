# HopCycle W3 Max — Scooter Remote for iPhone

A lightweight, no-account Swift/SwiftUI app that talks to a HopCycle W3 Max
electric scooter directly over Bluetooth LE. It is a native port of the
Voltix FF60 protocol recovered from the `com.world.voltix` Android APK.

No backend. No cloud. No account binding. The radio is CoreBluetooth
on the phone, talking straight to the scooter.

## What it does

- Scan for nearby BLE devices, connect to the scooter
- Live dashboard: speed (km/h), battery %, fault code
- Lock / unlock (with optional 4-digit code)
- Light on/off
- Gear 0/1/2
- Speed limit (km/h)
- Cruise control on/off

## Finding your scooter in the scan list

The Voltix APK does **not** ship a fixed Bluetooth name for the W3 Max. The
controller usually advertises a generic name (often part of the MAC), not
“HopCycle” or “Scooter”.

**Use the app’s default scan filter: “Scooters only (FF60)”.** That matches
devices advertising BLE service `0000FF60-…`, which is the Voltix protocol
this app speaks—not a marketing name.

Tips:

- Power the scooter on and stand within ~2 m.
- Pick the **strongest RSSI** (top of the list). If connect fails, try the next.
- If FF60 mode finds nothing, toggle **All named devices** (noisier) or use
  [nRF Connect](https://apps.apple.com/app/nrf-connect-for-mobile/id1051070407)
  and look for service **0xFF60**.
- Pair only inside this app—not in Settings → Bluetooth.

On a Mac you can also run `python3 reference/voltix_client.py scan` (needs
`pip install bleak`) to print address, RSSI, and raw name.

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

Requires Xcode (macOS). The Xcode project is generated from `project.yml`
with XcodeGen (`brew install xcodegen`), and the generated
`Scooter.xcodeproj` is committed so it also opens directly.

- Bundle ID `com.duketopceo.scooter`, team `6BP7W45U55`, display name "Scooter".
- Run on a physical iPhone. The iOS Simulator has no BLE.
- TestFlight: `scripts/testflight.sh` archives, exports, and uploads
  (needs `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`; `SKIP_UPLOAD=1` stops
  after the IPA). The App Store Connect app record must exist first.

Pairing happens inside this app. Do not pair through iOS Settings → Bluetooth.

## Files

- `Scooter/ScooterBLE.swift` — protocol + CoreBluetooth controller
- `Scooter/ContentView.swift` — SwiftUI UI
- `Scooter/ScooterApp.swift` — app entry point

## Note on TestFlight

A direct BLE app needs no backend to function. The Python reference client
(`reference/voltix_client.py`) and the phone app speak the same bytes.
