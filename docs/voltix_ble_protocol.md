# Voltix BLE protocol — recovered spec

Target: HopCycle W3 Max (1000W, 25 MPH) electric scooter.
Source evidence: decompiled `com.world.voltix` (Voltix app v1.0.12), classes
`BleComCons.java`, `blue/o.java` (frame builder), `BleVModel.java` (response
parser), `BleDataService.java` (GATT wiring).

Provenance: **binary-based** (DEX recovered from the shipped Android APK).

---

## 1. GATT layout

| Role | UUID | Use |
|---|---|---|
| Service | `0000FF60-0000-1000-8000-00805F9B34FB` | single service |
| Notify (scooter → phone) | `0000FF61-0000-1000-8000-00805F9B34FB` | subscribe here, receive all data |
| Write (phone → scooter) | `0000FF62-0000-1000-8000-00805F9B34FB` | send commands here |

- Notification CCCD: standard `00002902-0000-1000-8000-00805F9B34FB` (0x2902).
- The app requests MTU 512 after connect.

Note the naming is counter-intuitive: the app's constant `READ_CHARACTER_UUID_CUS`
(=FF61) is the one you **subscribe** to; `WRITE_CHARACTER_UUID_CUS` (=FF62) is the
one you **write** to.

## 2. Write frame format

Every command is one frame:

```
[1A][A1] [CMD] [PARAM] [LEN] [PAYLOAD...] [CRC lo][CRC hi] [1F][F1]
```

- Byte 0–1: header `0x1A 0xA1`
- Byte 2: command code (see table)
- Byte 3: param byte (fixed per command, listed below)
- Byte 4: payload length in bytes (0 if no payload)
- Byte 5..(4+len): payload
- Next 2 bytes: CRC-16/MODBUS, **little-endian (low byte first)**
- Last 2 bytes: footer `0x1F 0xF1`

CRC-16/MODBUS over exactly bytes `[CMD][PARAM][LEN][PAYLOAD...]` (i.e. byte 2 up to
and including the last payload byte). Polynomial `0xA001`, init `0xFFFF`. The app's
`((65280 & i5) >> 8) | ((i5 & 255) << 8)` in `blue/o.java` emits the CRC low byte
first, then high byte (little-endian).

Total frame length = 9 + payload_len.

### CRC (Python reference)

```python
def crc16_modbus(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0xA001
            else:
                crc >>= 1
    return crc  # append as little-endian: crc & 0xFF, then crc >> 8
```

### Frame builder (Python reference)

```python
HEADER = b"\x1A\xA1"
FOOTER = b"\x1F\xF1"

def build_frame(cmd: int, param: int, payload: bytes = b"") -> bytes:
    body = bytes([cmd, param, len(payload)]) + payload
    crc = crc16_modbus(body)
    # CRC goes out little-endian (low byte first) — matches the app's byte swap.
    return HEADER + body + bytes([crc & 0xFF, crc >> 8]) + FOOTER
```

## 3. Command table

Recovered verbatim from `BleComCons.java`. Params are the `*_PA/*_PARAM` constants.
Decimal and hex both shown.

| Cmd | Hex | Name | Param | Payload | Purpose |
|---|---|---|---|---|---|
| 16 | 0x10 | APP_HEAR | 1 | — | heartbeat (no payload) |
| 32 | 0x20 | Meter11 | — | — | meter selector 1 |
| 33 | 0x21 | Meter22 | — | — | meter selector 2 |
| 48 | 0x30 | APP_CONNECT_AC | 2 | `[0x01]` | connect/accredit car |
| 49 | 0x31 | APP_POWERON | 2 | — | power state |
| 50 | 0x32 | APP_LOCK_AL | 2 | `[type]` or `[type, 4×digit]` | lock / unlock (type 0 = toggle, 1 = set pwd, digits only when a 4-digit password is present) |
| 51 | 0x33 | APP_LIGHT_AL | 2 | light params | lights |
| 52 | 0x34 | APP_GAUGE_BRIGHTNESS_BS | 2 | `[level]` | gauge brightness |
| 53 | 0x35 | APP_ELECTRIC_GEAR_GE | 2 | `[gear, sub]` | speed gear |
| 54 | 0x36 | APP_SPEED_LIMIT_GE | 2 | `[kmh]` | speed limit |
| 55 | 0x37 | APP_ELECTRONIC_BR | 2 | `[level]` | electronic brake level |
| 56 | 0x38 | APP_CRUISE_GE | 2 | `[gear, mode]` | cruise control |
| 57 | 0x39 | APP_START_SP | 2 | `[a, b]` | single-trip mode |
| 58 | 0x3A | APP_SET_SN_SN | 2 | serial bytes | set serial number |
| 59 | 0x3B | APP_DRIVE_DR | 2 | `[mode]` | drive mode |
| 60 | 0x3C | APP_UNIT_UN | 2 | `[unit]` | display unit |
| 62 | 0x3E | APP_SINGLE_MILE | — | — | single mileage |
| 65 | 0x41 | APP_CURRENT_USER_CAR | 2 | `[0/1]` | is-current-user's-car flag |
| 66 | 0x42 | APP_UNBIND_RESET | 2 | — | force unbind/reset *(danger)* |
| 67 | 0x43 | APP_DISABLED_STATE_RESET | 2 | — | disabled-state reset *(danger)* |
| 69 | 0x45 | APP_NAV_SCREEN | 2 | — | nav screen |
| 70 | 0x46 | START_APP_NAV_SCREEN | 2 | `[0/1]` | start/end nav |
| 71 | 0x47 | SET_SMART_LOCK | 2 | `[0/1]` | smart lock on/off |
| 96 | 0x60 | APP_QUERY_CAR_CAR | 1 | `[sub]` | query car status/speed (periodic) |
| 97 | 0x61 | APP_QUERY_SN_SN | 1 | — | query serial |
| 98 | 0x62 | APP_QUERY_SPEED_LI | 1 | — | query speed limit |
| 99 | 0x63 | APP_QUERY_LI | 1 | — | query lights |
| 100 | 0x64 | APP_QUERY_BMS_VOLTAGE | 1 | `[type]` | query BMS voltage |
| 101 | 0x65 | APP_QUERY_BMS_INFO | 1 | `[type]` | query BMS info |
| 102 | 0x66 | APP_QUERY_PRO_VO | 1 | `[type]` | query firmware CRC/version |
| 103 | 0x67 | APP_QUERY_LOCK_PASSWORD | 1 | — | query lock password |
| 0x91 | 0x91 | APP_START_OTA | 1 | — | start OTA *(danger)* |
| 0x92 | 0x92 | APP_DATA_OTA | 1 | data | OTA data *(danger)* |
| 0x93 | 0x93 | APP_QUERY_OTA | 1 | — | query OTA status |

**Do not send** 0x42 (unbind), 0x43 (disabled reset), or the OTA commands (0x91–0x93)
unless you know exactly what you are doing. The "DO NOT BIND" lockout reports come
from the app's bind/unbind lifecycle, and these are the commands that touch it.

## 4. Response / notify frame format

The scooter answers with the same framing, but in the response the **length** byte is
at index 4 and payload starts at index 5:

```
[1A][A1] [CMD_echo] [PARAM] [LEN] [PAYLOAD...] [CRC lo][CRC hi] [1F][F1]
```

`byte[2]` is the command code being answered.

### Query-car response (cmd 0x60) — the periodic telemetry

This is what the dashboard reads. Layout (indexes into the notify payload):

| Offset | Meaning | Decode |
|---|---|---|
| 5 | light status | 8 flags |
| 6 | status byte 1 | brake / lock / cruise / charge / low-power flags |
| 7 | fault code | 0 = none |
| 8 | remaining battery | % (0–100) |
| 9 | speed low byte | part of speed |
| 12 | current speed limit | km/h |
| 13 | speed high bits | 2 high bits of speed (see below) |
| 14–15 | BMS / misc | — |

Ber. byte 9 assembled with 2 bits from byte 13: speed = (byte9 | (2bit << 8)) × 0.1 km/h.

#### Voltage / current block (Meter 2, also in cmd 0x60)
| Offset | Meaning | Decode |
|---|---|---|
| 5–6 | ? | — |
| 7–8 | voltage | `u16_le × 0.01` V |
| 9–10 | current | `u16_le × 0.01` A |
| 11–12 | capacity | `u16_le × 0.1` |
| 13–14 | ? | — |
| 15 | ? | — |
| 16 | temp | × 0.1 °C |

Confidence: the offsets and scale factors above are copied from the decompiled
parser. The exact telemetry header/length for the W3 Max's specific controller may
vary slightly by firmware; treat the query-car layout as **high confidence** for the
Voltix app family, **verify against your scooter** before trusting every field.

## 5. Connection sequence (as the app does it)

1. Scan for BLE device (name advertised by the controller; often contains part of the
   MAC).
2. Connect.
3. Request MTU 512.
4. Subscribe (enable notification) on `FF61`.
5. Send `0x30` connect command with payload `[0x01]`, then repeat once ~1 s later.
6. Send heartbeat `0x10` (no payload).
7. Periodically send `0x60` query-car; the scooter streams telemetry back on FF61.

The bind/unbind + account logic lives **above** this BLE layer (server calls, login
tokens). None of it is needed to connect and read telemetry at the BLE level; our
client skips it entirely, which is exactly why it cannot soft-lock your scooter like
the app's unbind flow does.

## 6. Known unknowns

- The advertised BLE device name for the W3 Max's exact controller is not in the app
  binary (it filters by a name the firmware advertises). Scan and we get it live.
- The precise field layout of the query-car packet may differ by controller firmware
  (the app handles several brands: Dremax, Roma, Nomad, S1, XC devices). The field
  offsets shown are the generic path.