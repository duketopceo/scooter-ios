# HopCycle W3 Max — Scooter Remote for iPhone

A lightweight, no-account Swift/SwiftUI app that talks to a HopCycle W3 Max
electric scooter directly over Bluetooth LE. It is a native port of the
Voltix FF60 protocol recovered from the `com.world.voltix` Android APK.

No backend. No cloud. No account binding. The radio is CoreBluetooth
on the phone, talking straight to the scooter.

## What it does

- Scan for nearby BLE devices (FF60 filter by default), connect to the scooter
- Live dashboard: speed (km/h or mph), battery %, fault code
- Save a favorite scooter and auto-reconnect when it is nearby
- Record rides with a trip map (location permission asked when you start a ride)
- Lock / unlock (with optional 4-digit code; experimental)
- Light on/off, gear, speed limit, cruise control (some still marked experimental in the UI)
- Extra controls: zero-start, e-brake, display brightness
- Hidden Debug panel (tap the title five times) for raw BLE frames

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
- TestFlight: `scripts/ci-testflight.sh` archives, exports, and uploads
  (needs `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`, `MARKETING_VERSION`, `BUILD_NUMBER`;
  `SKIP_UPLOAD=1` stops after the IPA). See RELEASING below. The App Store Connect app record must exist first.

Pairing happens inside this app. Do not pair through iOS Settings → Bluetooth.

## Build it on Linux (xtool)

[xtool](https://github.com/xtool-org/xtool) builds the same `Scooter/` sources from `Package.swift`, no Mac needed:

```sh
xtool dev build        # writes xtool/Scooter.app
xtool dev              # build, sign with your Apple ID and install on a USB iPhone
```

`xtool.yml` points at `Scooter/Info.xtool.plist`: `Scooter/Info.plist` without the Xcode `$(...)` build variables, which xtool fills in itself. Add a new Info.plist key to both files. TestFlight still goes through the Xcode project below.

## RELEASING (TestFlight)

Tag `ios-vX.Y.Z` and push it:

```bash
git tag ios-v1.2.3 && git push origin ios-v1.2.3
```

Merges to `main` that change non-docs paths also upload a TestFlight build automatically. Those uploads reuse the latest `ios-v*` marketing version and set the build number to `github.run_number + 20261104000000`. No GitHub release is created for main-branch uploads.

`.github/workflows/testflight.yml` runs the release job on the self-hosted `promax` macOS runner. Tag pushes also create a GitHub release. A tag that is not `X.Y.Z` fails fast. Actions, Run workflow does the same from a branch with a typed version.
Pull requests only build unsigned on GitHub-hosted runners and never see secrets. Repo secrets: `APPLE_TEAM_ID`,
`ASC_ISSUER_ID`, `ASC_KEY_ID`, `ASC_KEY_P8`.

**Backup runner.** The release job runs on the self-hosted `promax` Mac runner. To use a GitHub-hosted runner instead
(for example when that Mac is offline), set the repo variable, and delete it to go back:

```sh
gh variable set IOS_RUNNER -R duketopceo/scooter-ios --body '"macos-26"'
gh variable delete IOS_RUNNER -R duketopceo/scooter-ios
```

The release job runs on tag pushes, qualifying pushes to `main`, and manual runs, never on pull requests. Pull requests build on GitHub-hosted runners. `KC_PASSWORD` (the login keychain password of the runner Mac) is also a repo secret.

By hand on a Mac:

```bash
export ASC_KEY_ID="…" ASC_ISSUER_ID="…" ASC_KEY_PATH="/path/to/AuthKey_….p8"
export APPLE_TEAM_ID=6BP7W45U55 MARKETING_VERSION=1.2.3 BUILD_NUMBER=20261104000100
./scripts/ci-testflight.sh
```

Pick a hand-run `BUILD_NUMBER` above anything CI will reach soon, or avoid hand uploads.

## Files

- `Scooter/ScooterBLE.swift` — protocol + CoreBluetooth controller
- `Scooter/ContentView.swift` — SwiftUI UI
- `Scooter/ScooterApp.swift` — app entry point

## Note on TestFlight

A direct BLE app needs no backend to function. The Python reference client
(`reference/voltix_client.py`) and the phone app speak the same bytes.
