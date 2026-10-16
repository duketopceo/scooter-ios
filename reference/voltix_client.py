#!/usr/bin/env python3
"""
voltix_client.py — standalone BLE client for HopCycle W3 Max (Voltix protocol).

Recovered from the Voltix app (com.world.voltix). No account, no bind, no server.
Talks straight to the scooter over BLE. This cannot soft-lock your scooter, because
it never sends the unbind/reset commands and never touches the app's account binding.

Requirements:
    pip install bleak
    macOS: grant Terminal Bluetooth permission when prompted.

Usage:
    python3 voltix_client.py scan               # find the scooter's MAC + name
    python3 voltix_client.py dashboard -a XX:.. # live dashboard (speed, battery, volts)
    python3 voltix_client.py lock    -a XX:..   # lock the scooter
    python3 voltix_client.py unlock  -a XX:..   # unlock (no password)
    python3 voltix_client.py unlock  -a XX:.. -p 1234   # unlock with 4-digit password
    python3 voltix_client.py light   -a XX:.. -m on|off
    python3 voltix_client.py gear    -a XX:.. -g 0|1|2
    python3 voltix_client.py speedlimit -a XX:.. -s 25
    python3 voltix_client.py cruise  -a XX:.. -v 0|1
    python3 voltix_client.py raw     -a XX:.. -f "1A A1 30 02 01 00 00 1F F1"

Run on a machine with Bluetooth (your Mac). The Python sandbox has no radio.
"""

import argparse
import asyncio
import sys

from bleak import BleakClient, BleakScanner

SERVICE = "0000FF60-0000-1000-8000-00805F9B34FB"
CHAR_NOTIFY = "0000FF61-0000-1000-8000-00805F9B34FB"
CHAR_WRITE = "0000FF62-0000-1000-8000-00805F9B34FB"

HEADER = b"\x1A\xA1"
FOOTER = b"\x1F\xF1"

# Command codes (from BleComCons).
CMD = {
    "heartbeat": 0x10,
    "connect": 0x30,
    "lock": 0x32,
    "light": 0x33,
    "gauge_brightness": 0x34,
    "gear": 0x35,
    "speed_limit": 0x36,
    "ebrake": 0x37,
    "cruise": 0x38,
    "start_sp": 0x39,
    "unit": 0x3C,
    "current_user_car": 0x41,
    "smart_lock": 0x47,
    "query_car": 0x60,
    "query_sn": 0x61,
    "query_speed_limit": 0x62,
    "query_light": 0x63,
    "query_bms_voltage": 0x64,
    "query_bms_info": 0x65,
    "query_pro_vo": 0x66,
    "query_lock_password": 0x67,
}

# Commands we deliberately refuse to send even if asked.
FORBIDDEN = {"unbind_reset": 0x42, "disabled_reset": 0x43,
             "start_ota": 0x91, "data_ota": 0x92, "query_ota": 0x93}


def crc16_modbus(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0xA001
            else:
                crc >>= 1
    return crc


def build_frame(cmd: int, param: int, payload: bytes = b"") -> bytes:
    body = bytes([cmd, param, len(payload)]) + payload
    crc = crc16_modbus(body)
    # CRC is transmitted little-endian (low byte first), matching the app's byte swap.
    return HEADER + body + bytes([crc & 0xFF, crc >> 8]) + FOOTER


def fmt(b: bytes) -> str:
    return b.hex(" ")


# --------------------------------------------------------------------------- #
# Commands
# --------------------------------------------------------------------------- #

def cmd_connect() -> bytes:
    return build_frame(CMD["connect"], 2, b"\x01")


def cmd_heartbeat() -> bytes:
    return build_frame(CMD["heartbeat"], 1)


def _lock_frame(type_byte: int, password: str | None) -> bytes:
    # Decompiled o.o(type, str): payload = [type] when password empty,
    # [type][4 digit bytes] when a 4-digit password is present.
    if password:
        digits = bytes((ord(c) - ord("0")) for c in password[:4])
        return build_frame(CMD["lock"], 2, bytes([type_byte]) + digits)
    return build_frame(CMD["lock"], 2, bytes([type_byte]))


def cmd_lock() -> bytes:
    # Type 0, no password. (App sends o.o(0, "") for lock when no pwd is set.)
    return _lock_frame(0, None)


def cmd_unlock(password: str | None) -> bytes:
    # Type 0 = lock/unlock. The app's unlock path is o.o(0, "") with no password,
    # or o.o(0, "1234") to unlock with a password. Type 1 = SET a password.
    return _lock_frame(0, password)


def cmd_light(on: bool) -> bytes:
    return build_frame(CMD["light"], 2, bytes([1 if on else 0]))


def cmd_gear(g: int) -> bytes:
    return build_frame(CMD["gear"], 2, bytes([g]))


def cmd_speed_limit(kmh: int) -> bytes:
    return build_frame(CMD["speed_limit"], 2, bytes([kmh & 0xFF]))


def cmd_cruise(v: int) -> bytes:
    return build_frame(CMD["cruise"], 2, bytes([v & 0xFF]))


def cmd_query_car() -> bytes:
    return build_frame(CMD["query_car"], 1)


# --------------------------------------------------------------------------- #
# Notify parsing (query-car telemetry, from BleVModel.java)
# --------------------------------------------------------------------------- #

def parse_query_car(payload: bytes) -> dict:
    """Provisional decode of the meter-1 telemetry. Offsets from BleVModel.java.

    `payload` here is the notify frame with the 5-byte prefix (1A A1 CMD PARAM LEN)
    already stripped, so payload[i] == byteArray[i+5].

    HIGH CONFIDENCE (straight from the decompiled parser):
      payload[0] = light status (8 bit flags)
      payload[1] = status flags (brake/lock/cruise/charge/low-power)
      payload[2] = fault code (0 = none)
      payload[3] = battery %
      payload[4] = speed low byte

    PROVISIONAL (bit-packed, verify against hardware):
      payload[8] holds the 2 high bits of speed; speed = (low | (high<<8)) * 0.1
    """
    if len(payload) < 5:
        return {}
    out = {}
    out["battery_pct"] = payload[3] if payload[3] <= 100 else 0
    out["fault_code"] = payload[2]
    low = payload[4] & 0xFF
    high = (payload[8] & 0x03) if len(payload) > 8 else 0
    out["speed_kmh"] = round(((low | (high << 8)) * 0.1), 1)
    return out


def parse_speed_limit(payload: bytes) -> dict:
    if len(payload) >= 6:
        return {"current": payload[5], "max": payload[6]}
    return {}


# --------------------------------------------------------------------------- #
# Runtime helpers
# --------------------------------------------------------------------------- #

async def scan():
    print("Scanning 12 s for BLE devices ...")
    devices = await BleakScanner.discover(timeout=12.0, return_adv=True)
    if not devices:
        print("No devices found.")
        return None
    print(f"{'ADDRESS':<20} {'RSSI':>5}  NAME")
    for d, (adv) in devices.values():
        print(f"{d.address:<20} {adv.rssi:>5}  {adv.local_name or '(no name)'}")
    return devices


async def connect_client(address, on_notify=None):
    client = BleakClient(address, timeout=30.0)
    await client.connect()
    try:
        await client.start_notify(CHAR_NOTIFY, on_notify or (lambda _, d: None))
        await client.write_gatt_char(CHAR_WRITE, cmd_connect())
        await asyncio.sleep(0.5)
        await client.write_gatt_char(CHAR_WRITE, cmd_heartbeat())
    except Exception:
        await client.disconnect()
        raise
    return client


async def dashboard(address):
    def on_notify(_h, data):
        if data[:2] == HEADER and len(data) >= 7:
            cmd = data[2]
            if cmd == CMD["query_car"]:
                info = parse_query_car(data[5:])
                if info:
                    s = info.get("speed_kmh", "?")
                    b = info.get("battery_pct", "?")
                    v = info.get("voltage", "?")
                    f = info.get("fault_code", 0)
                    print(f"\rspeed {s} km/h | battery {b}% | {v} V | fault {f}   ",
                          end="", flush=True)

    client = await connect_client(address, on_notify)
    print("Connected. Streaming telemetry. Ctrl-C to stop.")
    try:
        while True:
            await client.write_gatt_char(CHAR_WRITE, cmd_query_car())
            await asyncio.sleep(1.0)
    except KeyboardInterrupt:
        pass
    finally:
        await client.disconnect()


async def send_once(address, frame: bytes):
    client = await connect_client(address)
    try:
        await client.write_gatt_char(CHAR_WRITE, frame)
        print("sent:", fmt(frame))
        await asyncio.sleep(0.5)
    finally:
        await client.disconnect()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action",
                    choices=["scan", "dashboard", "lock", "unlock", "light",
                             "gear", "speedlimit", "cruise", "raw"])
    ap.add_argument("-a", "--address", help="scooter BLE address, e.g. A1:B2:..")
    ap.add_argument("-p", "--password", help="4-digit lock password (unlock)")
    ap.add_argument("-m", "--mode", help="light on/off")
    ap.add_argument("-g", "--gear", type=int, help="gear 0/1/2")
    ap.add_argument("-s", "--speed", type=int, help="speed limit km/h")
    ap.add_argument("-v", "--value", type=int, help="cruise 0/1")
    ap.add_argument("-f", "--frame", help="raw hex frame (spaces optional)")
    args = ap.parse_args()

    if args.action == "scan":
        asyncio.run(scan())
        return

    if not args.address:
        print("error: -a ADDRESS required for this action")
        sys.exit(2)

    frame = None
    if args.action == "lock":
        frame = cmd_lock()
    elif args.action == "unlock":
        frame = cmd_unlock(args.password)
    elif args.action == "light":
        on = (args.mode or "on").lower() == "on"
        frame = cmd_light(on)
    elif args.action == "gear":
        frame = cmd_gear(args.gear if args.gear is not None else 1)
    elif args.action == "speedlimit":
        frame = cmd_speed_limit(args.speed if args.speed is not None else 25)
    elif args.action == "cruise":
        frame = cmd_cruise(args.value if args.value is not None else 0)
    elif args.action == "raw":
        if not args.frame:
            print("error: -f required for raw")
            sys.exit(2)
        frame = bytes.fromhex(args.frame.replace(" ", ""))

    if frame is not None:
        asyncio.run(send_once(args.address, frame))
    elif args.action == "dashboard":
        asyncio.run(dashboard(args.address))


if __name__ == "__main__":
    main()