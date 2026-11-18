"""Pocket 4 Pro BLE pairing and station Wi-Fi transport for the Mac watcher."""

import asyncio
import uuid

from core.camera_sta_bridge import build_duml_packet, crc8_dji, crc16_dji

SERVICE, NOTIFY, WRITE = (
    f"0000{short}-0000-1000-8000-00805f9b34fb" for short in ("fff0", "fff4", "fff5")
)
DEFAULT_NAME = "OsmoPocket4P-4FB5"


class BLERecoveryError(Exception):
    """An operator-facing state without credentials or raw Bluetooth traffic."""


def _pack_string(value: str, limit: int) -> bytes:
    encoded = value.encode("utf-8")
    if b"\0" in encoded or len(encoded) > limit:
        raise ValueError("Invalid DUML string")
    return bytes([len(encoded)]) + encoded


def _wifi_packet(command: int, payload: bytes, seq: int) -> bytes:
    return build_duml_packet(2, 0, 7, 0, 7, command, payload=payload, seq=seq)


def build_ble_pairing_packet(identifier: str, pin: str, seq: int) -> bytes:
    return _wifi_packet(0x45, _pack_string(identifier, 32) + _pack_string(pin, 32), seq)


def build_ble_sta_mode_packet(seq: int) -> bytes:
    return _wifi_packet(0x48, b"\x01", seq)


def build_ble_sta_join_packet(ssid: str, password: str, seq: int) -> bytes:
    # BLE uses two independently packed strings, not the legacy USB layout.
    return _wifi_packet(0x47, _pack_string(ssid, 32) + _pack_string(password, 64), seq)


class _DumlNotifications:
    def __init__(self):
        self.buffer = bytearray()
        self.frames = asyncio.Queue(maxsize=64)

    def receive(self, _characteristic, data):
        self.buffer.extend(data)
        while len(self.buffer) >= 4:
            length = (self.buffer[1] | self.buffer[2] << 8) & 0x3ff
            if (self.buffer[0] != 0x55 or self.buffer[2] >> 2 != 1 or length < 13
                    or crc8_dji(self.buffer[:3]) != self.buffer[3]):
                del self.buffer[0]
                continue
            if len(self.buffer) < length:
                return
            frame = bytes(self.buffer[:length])
            if int.from_bytes(frame[-2:], "little") != crc16_dji(frame[:-2]):
                del self.buffer[0]
                continue
            del self.buffer[:length]
            if frame[9] != 7 or frame[10] not in (0x45, 0x46, 0x47, 0x48):
                continue
            if self.frames.full():
                self.frames.get_nowait()
            self.frames.put_nowait(frame)

    async def expect(self, command, *, seq=None, timeout=5, failure):
        async def find_frame():
            while True:
                frame = await self.frames.get()
                if frame[10] != command:
                    continue
                if seq is None and frame[8] & 0xc0 == 0x40:
                    return frame
                if (seq is not None and frame[8] & 0x80
                        and int.from_bytes(frame[6:8], "little") == seq):
                    return frame

        try:
            return await asyncio.wait_for(find_frame(), timeout)
        except asyncio.TimeoutError:
            raise BLERecoveryError(failure) from None


async def _provision(name, ssid, password, identifier, pin):
    try:
        from bleak import BleakClient, BleakScanner
    except ImportError:
        raise BLERecoveryError("bleak_unavailable") from None

    # Name is an explicit device selector; never send credentials to a device
    # solely because it advertises the generic FFF0 UUID.
    def matches(device, advertisement):
        return name in (advertisement.local_name, device.name)

    device = await BleakScanner.find_device_by_filter(matches, timeout=6,
                                                       service_uuids=[SERVICE])
    if device is None:
        raise BLERecoveryError("ble_camera_not_found")

    async with BleakClient(device, timeout=8, services=[SERVICE]) as client:
        service = client.services.get_service(SERVICE)
        notify = service.get_characteristic(NOTIFY) if service else None
        writer = service.get_characteristic(WRITE) if service else None
        if notify is None or writer is None or "write-without-response" not in writer.properties:
            raise BLERecoveryError("ble_characteristics_unavailable")

        incoming = _DumlNotifications()
        await client.start_notify(notify, incoming.receive)
        if "notify" in writer.properties:
            await client.start_notify(writer, incoming.receive)
        if "write" not in notify.properties and "write-without-response" not in notify.properties:
            raise BLERecoveryError("ble_arm_unavailable")
        await client.write_gatt_char(notify, b"\x01\x00", response="write" in notify.properties)

        async def send(frame):
            await asyncio.sleep(0.2)
            limit = writer.max_write_without_response_size
            for start in range(0, len(frame), limit):
                await client.write_gatt_char(writer, frame[start:start + limit], response=False)

        await send(build_ble_pairing_packet(identifier, pin, 1))
        pair = (await incoming.expect(0x45, seq=1, failure="ble_pairing_timeout"))[11:-2]
        if pair == b"\x00\x02":
            approval = await incoming.expect(0x46, timeout=25, failure="ble_pairing_needs_approval")
            await send(build_duml_packet(
                approval[5] & 0x1f, approval[5] >> 5, approval[4] & 0x1f, approval[4] >> 5,
                7, 0x46, payload=approval[11:-2], seq=int.from_bytes(approval[6:8], "little"),
                cmd_type=0xc0,
            ))
            if approval[11:-2] != b"\x01":
                raise BLERecoveryError("ble_pairing_not_approved")
        elif pair == b"\x00\x06":
            raise BLERecoveryError("ble_pairing_deferred")
        elif pair != b"\x00\x01":
            raise BLERecoveryError("ble_pairing_rejected")

        await send(build_ble_sta_mode_packet(2))
        mode = (await incoming.expect(0x48, seq=2, failure="ble_sta_mode_timeout"))[11:-2]
        if mode not in (b"\x00", b"\x00\x00"):
            raise BLERecoveryError("ble_sta_mode_rejected")

        await asyncio.sleep(10)
        await send(build_ble_sta_join_packet(ssid, password, 3))
        joined = (await incoming.expect(0x47, seq=3, timeout=12,
                                        failure="ble_sta_join_timeout"))[11:-2]
        if joined not in (b"\x00\x00", b"\x00\x00\x00"):
            raise BLERecoveryError("ble_sta_join_rejected")
        return "sta_join_acknowledged"


def provision_over_ble(settings, network):
    """Run a bounded BLE session; only an agent heartbeat can confirm recovery."""
    ssid, password = network.get("ssid"), network.get("password")
    if not isinstance(ssid, str) or not ssid or not isinstance(password, str) or password == "********":
        raise BLERecoveryError("ble_credentials_unavailable")
    name = settings.get("ble_name", DEFAULT_NAME)
    if not isinstance(name, str) or not name:
        raise BLERecoveryError("ble_camera_name_unavailable")
    identifier = settings.get("ble_identifier", uuid.uuid5(uuid.NAMESPACE_DNS,
                              f"pocket-coffee:{uuid.getnode()}").hex)

    async def run():
        return await asyncio.wait_for(_provision(name, ssid, password, identifier,
                                                settings.get("ble_pin", "osmo")), 75)
    try:
        return asyncio.run(run())
    except BLERecoveryError:
        raise
    except asyncio.TimeoutError:
        raise BLERecoveryError("ble_session_timeout") from None
    except Exception as error:
        # Recognize the macOS permission/power errors without exposing raw traffic.
        if type(error).__name__ == "BleakError":
            if str(error).startswith("BLE is not authorized"):
                raise BLERecoveryError("ble_permission_denied") from None
            if str(error) == "Bluetooth device is turned off":
                raise BLERecoveryError("ble_adapter_unavailable") from None
        raise BLERecoveryError(f"ble_error_{type(error).__name__}") from None
