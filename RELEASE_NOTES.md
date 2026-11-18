# Scooter 1.0.4 — TestFlight / ASC “What to Test”

Paste into App Store Connect → TestFlight → What to Test (or use as GitHub release notes seed).

## What’s new

- Clearer Bluetooth connection flow: live “looking for scooters” empty state, connecting/setup progress, and Cancel while pairing.
- Open Settings when Bluetooth is off or permission is denied.
- Dashboard speed can show mph (phone preference); scooter stem units remain a separate experimental control.
- Light toggle tracks scooter telemetry when connected.
- Settings → About shows marketing version and build number.
- Trips empty state clarifies Start ride + on-device GPS storage.

## Please verify on a physical iPhone + W3 Max

1. Power scooter on; leave **Scooters only (FF60)**; connect strongest / W3? row.
2. Confirm live speed and battery against the stem display (decode is still provisional).
3. Save as my scooter → kill app → relaunch with auto-connect on.
4. Start ride → short outdoor loop → End ride → Trips tab shows map.
5. Gear change works; treat light / lock / cruise / speed limit as experimental.

## Build / tag

- Marketing version: **1.0.4**
- Tag to upload: `ios-v1.0.4` (CI sets build number from `github.run_number + 20261104000000`)
