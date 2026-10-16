#!/usr/bin/env python3
"""
HopCycle W3 Max — BLE protocol capture (step 1 of reverse-engineering).

This script does NOT reverse-engineer anything on its own and does NOT
control the scooter. It enumerates the scooter's GATT services and
characteristics, then subscribes to any that emit notifications so we can
capture the raw bytes the scooter sends. That dump is the raw material for
recovering the actual command protocol.

Why we need this: the scooter's BLE service/characteristic UUIDs and command
frame format are not published anywhere trustworthy. They must be captured
from your real scooter (or decompiled from the Voltix app). This script does
the capture.

Usage:
    pip install bleak
    python3 ble_probe.py scan          # list nearby BLE devices, find the scooter
    python3 ble_probe.py capture <MAC> # dump GATT tree + live notifications
                                       #   (MAC is the device address printed by scan)

Requirements:
    - A machine with Bluetooth (Mac, Linux, or Windows). The Python sandbox has
      no radio, so run this on your own Mac.
    - macOS: grant Terminal Bluetooth permission when prompted.

Output:
    - A full GATT dump (service -> characteristic -> properties -> UUID) printed
      to stdout and written to gatt_dump.txt.
    - Every notification frame printed as hex + ASCII, which is what we base the
      decoded protocol on.
"""

import asyncio
import sys
import time

from bleak import BleakClient, BleakScanner


def fmt_bytes(b):
    """Render bytes as a hex string (and printable ASCII on the right)."""
    hexs = b.hex(" ")
    ascii_ = "".join(chr(x) if 32 <= x < 127 else "." for x in b)
    return f"{hexs:<48} | {ascii_}"


async def scan():
    print("Scanning 12s for BLE devices...")
    devices = await BleakScanner.discover(timeout=12.0, return_adv=True)
    if not devices:
        print("No devices found.")
        return
    print(f"\n{'ADDRESS':<20} {'RSSI':>5}  NAME")
    for d, (adv) in devices.values():
        name = adv.local_name or "(no name)"
        print(f"{d.address:<20} {adv.rssi:>5}  {name}")


def cb_char(uuid):
    """Build a notification callback that decodes the characteristic UUID."""

    def cb(_handle, data):
        if not data:
            return
        print(f"[notify] {uuid}  {fmt_bytes(data)}")

    return cb


async def capture(address: str):
    print(f"Connecting to {address} ...")
    async with BleakClient(address, timeout=30.0) as client:
        print("Connected:", "yes" if client.is_connected else "no")
        dump = []
        for service in client.services:
            line = f"SERVICE  {service.uuid}  ({service.description})"
            print("\n" + line)
            dump.append(line)
            for char in service.characteristics:
                props = ",".join(char.properties)
                line = (
                    f"  CHAR  {char.uuid}  [{props}]  "
                    f"(handle={char.handle})"
                )
                print(line)
                dump.append(line)
                # Subscribe to anything that can notify/indicate.
                if "notify" in char.properties or "indicate" in char.properties:
                    try:
                        await client.start_notify(char, cb_char(str(char.uuid)))
                        print(f"      -> subscribed for notifications")
                        dump.append(f"      -> subscribed: {char.uuid}")
                    except Exception as e:  # noqa: BLE001
                        print(f"      -> subscribe failed: {e}")
                # Read current value if readable.
                if "read" in char.properties:
                    try:
                        val = await client.read_gatt_char(char)
                        print(f"      -> value: {fmt_bytes(val)}")
                        dump.append(f"      -> value {char.uuid}: {val.hex(' ')}")
                    except Exception as e:  # noqa: BLE001
                        pass

        with open("gatt_dump.txt", "w") as f:
            f.write("\n".join(dump))
        print("\nGATT dump written to gatt_dump.txt")
        print("Listening for notifications for 60s. ")
        print("Now toggle things in the Voltix app OR on the scooter handlebar ")
        print("(power on/off, mode D/S/ECO, lights, cruise) so we capture frames.")
        await asyncio.sleep(60.0)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    cmd = sys.argv[1]
    if cmd == "scan":
        asyncio.run(scan())
    elif cmd == "capture":
        if len(sys.argv) < 3:
            print("Usage: python3 ble_probe.py capture <ADDRESS>")
            return
        asyncio.run(capture(sys.argv[2]))
    else:
        print(__doc__)


if __name__ == "__main__":
    main()