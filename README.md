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

## Your scooter (stem sticker)

The factory QR labels point at the **Voltix** app (`com.world.voltix`)—the same
protocol this repo implements at the BLE layer. Example serial from a W3 Max
sticker: **`US2603013795W3MAX`**. The bind QR is for Voltix account pairing;
**this app does not use bind** and never sends unbind/reset commands.

Bluetooth name is **not** guaranteed to match the serial. It may contain
`W3MAX`, `Voltix`, or a fragment of the serial (e.g. `13795`). Prefer
**Scooters only (FF60)** in the app over guessing the name.

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
- "Right scooter for Voltix protocol": **confirmed** for W3 Max with Voltix
  stem QR / serial suffix `W3MAX`

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

## Build it on Linux (xtool)

[xtool](https://github.com/xtool-org/xtool) builds the same `Scooter/` sources from `Package.swift`, no Mac needed:

```sh
xtool dev build        # writes xtool/Scooter.app
xtool dev              # build, sign with your Apple ID and install on a USB iPhone
```

`xtool.yml` points at `Scooter/Info.xtool.plist`: `Scooter/Info.plist` without the Xcode `$(...)` build variables, which xtool fills in itself. Add a new Info.plist key to both files. TestFlight still goes through the Xcode project below.

## TestFlight (Mac mini or GitHub Actions)

**Local (same keys as Kate/Cairn):**

```bash
cd ~/src/scooter-ios && git pull origin main
export ASC_KEY_ID="…" ASC_ISSUER_ID="…" ASC_KEY_PATH="$HOME/keys/AuthKey_….p8"
export APPLE_TEAM_ID=6BP7W45U55
./scripts/testflight.sh
```

**CI:** workflow `.github/workflows/testflight.yml` runs on push to `main` when
`Scooter/**` changes, if repo secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`,
`ASC_KEY_P8`, and `APPLE_TEAM_ID` are set.

## Files

- `Scooter/ScooterBLE.swift` — protocol + CoreBluetooth controller
- `Scooter/ContentView.swift` — SwiftUI UI
- `Scooter/ScooterApp.swift` — app entry point

## Note on TestFlight

A direct BLE app needs no backend to function. The Python reference client
(`reference/voltix_client.py`) and the phone app speak the same bytes.
