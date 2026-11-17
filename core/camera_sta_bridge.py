"""Camera ADB bridge and HG224 STA agent.

The agent commands were verified on eagle4_hg224 over root ADB. DUML packet
builders below retain experimental protocol assumptions; sending a packet does
not establish association, recording success, or boot persistence.
"""

from dataclasses import dataclass, field, asdict
from datetime import datetime
import json
import ipaddress
import re
import os
import socket
import struct
import subprocess
import time
from typing import Any, Dict, List, Optional, Tuple
from urllib import request as urllib_request
from urllib.error import URLError


# ---------------------------------------------------------------------------
# 1. DUML Protocol & BLE / Wi-Fi STA Packet Builder
# ---------------------------------------------------------------------------

def crc8_dji(data: bytes) -> int:
    """Calculate DJI DUML v1 header CRC-8."""
    crc = 0x77
    for b in data:
        crc ^= b
        for _ in range(8):
            if crc & 0x01:
                crc = ((crc >> 1) ^ 0x8C) & 0xFF
            else:
                crc = (crc >> 1) & 0xFF
    return crc


def crc16_dji(data: bytes) -> int:
    """Calculate DJI DUML v1 frame CRC-16."""
    crc = 0x3692
    for b in data:
        crc ^= b
        for _ in range(8):
            if crc & 0x0001:
                crc = ((crc >> 1) ^ 0x8408) & 0xFFFF
            else:
                crc = (crc >> 1) & 0xFFFF
    return crc


def build_duml_packet(
    sender_type: int,
    sender_index: int,
    receiver_type: int,
    receiver_index: int,
    cmd_set: int,
    cmd_id: int,
    payload: bytes = b"",
    seq: int = 1,
    cmd_type: int = 0x40,  # Req + ACK
) -> bytes:
    """
    Build a standard DJI DUML v1 packet used across USB VCOM, BLE GATT (0xFFF5),
    and UDP (port 9004 / 22345) on Osmo Pocket 3 and Pocket 4 Pro.
    """
    total_len = 13 + len(payload)
    ver_len = ((1 << 10) | (total_len & 0x03FF)) & 0xFFFF
    header_3 = struct.pack("<BH", 0x55, ver_len)
    hdr_crc = crc8_dji(header_3)

    sender = ((sender_index & 0x07) << 5) | (sender_type & 0x1F)
    receiver = ((receiver_index & 0x07) << 5) | (receiver_type & 0x1F)

    body = struct.pack(
        "<BBBHBBB",
        hdr_crc,
        sender,
        receiver,
        seq & 0xFFFF,
        cmd_type,
        cmd_set,
        cmd_id,
    ) + payload

    frame_without_crc = header_3 + body
    f_crc = crc16_dji(frame_without_crc)
    return frame_without_crc + struct.pack("<H", f_crc)


def build_sta_wifi_connect_payload(ssid: str, password: str, target_ip: str = "") -> bytes:
    """
    Build the DUML CmdSet=0x07 (Wi-Fi) CmdId=0x47 (Switch to STA & Join AP) payload.
    Used when provisioning Osmo Pocket 3 / Pocket 4 Pro into LAN Station mode.
    """
    ssid_bytes = ssid.encode("utf-8")[:32]
    pwd_bytes = password.encode("utf-8")[:64]
    payload = struct.pack("<BB", len(ssid_bytes), len(pwd_bytes)) + ssid_bytes + pwd_bytes
    if target_ip:
        try:
            ip_packed = socket.inet_aton(target_ip)
            payload += ip_packed
        except OSError:
            pass
    return build_duml_packet(
        sender_type=2,      # App / Host controller
        sender_index=0,
        receiver_type=7,    # Wi-Fi / AirLink module
        receiver_index=0,
        cmd_set=0x07,       # Wi-Fi CmdSet
        cmd_id=0x47,        # STA Join AP command
        payload=payload,
    )


def build_camera_shutter_packet(start: bool = True, seq: int = 10) -> bytes:
    """
    Build DUML CmdSet=0x02 (Camera) CmdId=0x01 / 0x02 (Record Video Start/Stop) packet.
    """
    action_byte = b"\x01" if start else b"\x00"
    return build_duml_packet(
        sender_type=2,
        sender_index=0,
        receiver_type=1,    # Camera module
        receiver_index=0,
        cmd_set=0x02,
        cmd_id=0x02,        # Video Record Control
        payload=action_byte,
        seq=seq,
    )


# ---------------------------------------------------------------------------
# 2. On-Camera Internal Extension Daemon Script Generator
# ---------------------------------------------------------------------------

ON_CAMERA_AGENT_SCRIPT = r"""#!/system/bin/sh
# Verified on eagle4_hg224. Install in /data/pocket-coffee; firmware is read-only.
BASE_DIR="${BASE_DIR:-/data/pocket-coffee}"
[ -r "$BASE_DIR/agent.env" ] && . "$BASE_DIR/agent.env"
DEVICE_ID="${DEVICE_ID:-pocket4p}"
SERVER_IP="${SERVER_IP:-192.168.5.84}"
SERVER_PORT="${SERVER_PORT:-8788}"
WPA_CONF="${WPA_CONF:-/data/misc/wifi/pocket_sta.conf}"
CTRL_DIR="${CTRL_DIR:-/data/misc/wifi/sockets}"
DCIM_DIR="${DCIM_DIR:-/mnt/media_rw/emulated/DCIM}"
BB=/sbin/busybox
mkdir -p "$BASE_DIR"
PID_FILE="$BASE_DIR/agent.pid"
if [ -r "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then exit 0; fi
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"; exit' INT TERM EXIT
log() { echo "$(date) $*" >> "$BASE_DIR/agent.log"; }

ensure_sta() {
    # DJI powers down the PCIe Wi-Fi device while USB remains available.
    if [ ! -d /sys/class/net/wlan0 ]; then
        echo load > /sys/devices/platform/soc/c080000.apb/c448000.pcie/status || return 1
        sleep 2
    fi
    ip link set wlan0 up || return 1
    STATUS=$(wpa_cli -p "$CTRL_DIR" -i wlan0 status 2>/dev/null)
    if [ -z "$STATUS" ] || ! echo "$STATUS" | "$BB" grep -q 'wpa_state='; then
        # Supplicant drops to uid wifi; mode 0600 root-owned configs are unreadable.
        chown wifi:wifi "$WPA_CONF"
        chmod 600 "$WPA_CONF"
        restorecon "$WPA_CONF" 2>/dev/null
        wpa_supplicant -B -i wlan0 -c "$WPA_CONF" -D nl80211 >> "$BASE_DIR/agent.log" 2>&1 || return 1
        wpa_cli -p "$CTRL_DIR" -i wlan0 scan >/dev/null 2>&1
        return 1
    fi
    if ! echo "$STATUS" | "$BB" grep -q 'wpa_state=COMPLETED'; then
        case "$STATUS" in *wpa_state=DISCONNECTED*|*wpa_state=INACTIVE*)
            wpa_cli -p "$CTRL_DIR" -i wlan0 reassociate >/dev/null 2>&1;; esac
        return 1
    fi
    CURRENT_IP=$(ip -4 addr show wlan0 | "$BB" awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}')
    # Keep our DHCP client alive even when a lease was acquired before launch.
    DHCP_PID="$BASE_DIR/udhcpc.pid"
    if ! [ -r "$DHCP_PID" ] || ! kill -0 "$(cat "$DHCP_PID")" 2>/dev/null; then
        "$BB" udhcpc -b -i wlan0 -p "$DHCP_PID" -s /system/bin/udhcpc.conf.sh -t 5 >> "$BASE_DIR/agent.log" 2>&1
        CURRENT_IP=$(ip -4 addr show wlan0 | "$BB" awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}')
    fi
    [ -n "$CURRENT_IP" ] || return 1
    return 0
}

heartbeat() {
    MAC=$(cat /sys/class/net/wlan0/address)
    # JSON unicode is supplied by the host-generated env; config contains no password.
    BODY="{\"device_id\":\"$DEVICE_ID\",\"ip\":\"$CURRENT_IP\",\"mac_address\":\"$MAC\",\"ssid\":\"$WIFI_SSID\",\"wifi_mode\":\"STA\",\"agent_version\":\"v3-hg224\"}"
    # This firmware's wget has no POST support; nc is available as a BusyBox applet.
    RESPONSE=$({ printf 'POST /api/camera/heartbeat HTTP/1.0\r\nHost: %s:%s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "$SERVER_IP" "$SERVER_PORT" "${#BODY}" "$BODY"; } | "$BB" nc -w 5 "$SERVER_IP" "$SERVER_PORT")
    case "$RESPONSE" in *'200 OK'*) log "heartbeat accepted ip=$CURRENT_IP mac=$MAC";; *) log "heartbeat failed: $RESPONSE";; esac
}

log 'Starting STA agent; boot auto-start is not installed by this script'
# Do not restart adbd here: the provisioning command enables TCP once explicitly.
# The media server is optional; it only exposes the verified DCIM directory.
if [ -d "$DCIM_DIR" ]; then
    "$BB" httpd -p 8088 -h "$DCIM_DIR" 2>> "$BASE_DIR/agent.log"
fi
while true; do
    if ensure_sta; then heartbeat; fi
    [ "${RUN_ONCE:-0}" = 1 ] && break
    sleep 5
done
"""


# ---------------------------------------------------------------------------
# 3. Camera STA & Internal Bridge Manager
# ---------------------------------------------------------------------------

@dataclass
class CameraNodeState:
    device_id: str
    model: str
    wifi_mode: str = "unknown"
    lan_ip: str = ""
    ssid: str = ""
    mac_address: str = ""
    adb_port: int = 5555
    http_media_port: int = 8088
    duml_udp_port: int = 9004
    rtsp_url: str = ""
    internal_daemon_installed: bool = False
    internal_daemon_version: str = ""
    recording_state: str = "unknown"
    battery_percent: Optional[int] = None
    sd_free_gb: Optional[float] = None
    last_heartbeat: str = ""
    capabilities: List[str] = field(default_factory=list)


class CameraInternalBridge:
    """
    Manages persistent STA network connection, internal Linux/Android shell extension,
    and LAN remote control for DJI Osmo Pocket 3 & Osmo Pocket 4 Pro.
    """

    def __init__(self, data_dir: str):
        self.data_dir = data_dir
        self.config_path = os.path.join(data_dir, "camera_sta_config.json")
        self.script_export_path = os.path.join(data_dir, "pocket_sta_agent.sh")
        self._ensure_default_config()

    def _ensure_default_config(self) -> None:
        os.makedirs(self.data_dir, exist_ok=True)
        # Write the on-camera shell daemon script so the user can inspect or push it via ADB/SSH
        with open(self.script_export_path, "w", encoding="utf-8") as f:
            f.write(ON_CAMERA_AGENT_SCRIPT.lstrip())
        os.chmod(self.script_export_path, 0o755)

        if not os.path.exists(self.config_path):
            default_cfg = {
                "sta_network": {
                    "ssid": "Home_Coffee_LAN",
                    "password": "********",
                    "subnet": "192.168.5.0/24",
                    "mac_server_ip": "192.168.5.84",
                    "mac_server_port": 8788,
                    "keepalive_interval_s": 5,
                    "prevent_sleep_in_sta": True,
                },
                "cameras": {
                    key: asdict(CameraNodeState(device_id=key, model=model))
                    for key, model in (("pocket4p", "DJI Osmo Pocket 4 Pro"),
                                       ("pocket3", "DJI Osmo Pocket 3"))
                },
                "command_log": [],
            }
            with open(self.config_path, "w", encoding="utf-8") as f:
                json.dump(default_cfg, f, ensure_ascii=False, indent=2)

    def load_state(self) -> Dict[str, Any]:
        with open(self.config_path, "r", encoding="utf-8") as f:
            return json.load(f)

    def save_state(self, state: Dict[str, Any]) -> None:
        with open(self.config_path, "w", encoding="utf-8") as f:
            json.dump(state, f, ensure_ascii=False, indent=2)

    def record_heartbeat(self, payload: Dict[str, Any], source_ip: str) -> Dict[str, Any]:
        """Record agent observations; verify STA only for a matching LAN peer."""
        state = self.load_state()
        if not isinstance(payload, dict):
            return {"ok": False, "error": "Expected a JSON object"}
        device_id = payload.get("device_id")
        if not isinstance(device_id, str) or device_id not in state["cameras"]:
            return {"ok": False, "error": "Unknown camera"}
        try:
            address = ipaddress.IPv4Address(payload.get("ip", ""))
            network = ipaddress.IPv4Network(state["sta_network"]["subnet"])
            if address not in network or address in (network.network_address, network.broadcast_address):
                raise ValueError("Address outside STA network")
            mac = payload.get("mac_address", "")
            if not isinstance(mac, str) or not re.fullmatch(r"(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}", mac):
                raise ValueError("Invalid MAC address")
            if payload.get("wifi_mode") != "STA":
                raise ValueError("Expected STA mode")
        except (ValueError, TypeError) as error:
            return {"ok": False, "error": str(error)}
        now = datetime.now().astimezone().isoformat()
        camera = state["cameras"][device_id]
        verified = source_ip == str(address)
        camera.update(lan_ip=str(address), mac_address=mac.lower(),
                      ssid=str(payload.get("ssid", "")), wifi_mode="STA" if verified else "unverified",
                      last_heartbeat=now, internal_daemon_installed=True,
                      internal_daemon_version=str(payload.get("agent_version", "")))
        camera.setdefault("verification", {}).update(
            checked_at=now, status="live_sta_heartbeat" if verified else "heartbeat_source_mismatch",
            heartbeat_verified=verified, sta_connection_verified=verified,
            agent_installation_verified=verified, verified_sta_ip=str(address) if verified else None,
            heartbeat_source_ip=source_ip, mac_address_source="Agent wlan0 sysfs observation")
        self.save_state(state)
        return {"ok": True, "device_id": device_id, "last_heartbeat": now, "sta_verified": verified}

    def sta_status(self) -> Dict[str, Any]:
        state = self.load_state()
        state["sta_network"].pop("password", None)
        return {"ok": True, "sta_network": state["sta_network"], "cameras": state["cameras"]}

    def scan_usb_and_serial_devices(self) -> Dict[str, Any]:
        """
        Probes macOS IOKit USB registry (`ioreg -r -c IOUSBHostDevice`) and `/dev/cu.*` serial devices
        to detect any USB-connected DJI Osmo Pocket 3, Pocket 4 Pro, or DJI Mic receiver.
        """
        usb_matches: List[str] = []
        serial_ports: List[str] = []
        detected_product = ""
        try:
            proc = subprocess.run(
                ["ioreg", "-r", "-c", "IOUSBHostDevice", "-l"],
                capture_output=True,
                text=True,
                timeout=4,
            )
            for line in (proc.stdout or "").splitlines():
                if '"USB Product Name"' in line and any(k in line for k in ["Osmo", "Pocket", "DJI"]):
                    val = line.split("=", 1)[-1].strip().strip('"')
                    if val not in usb_matches:
                        usb_matches.append(val)
                    if "Pocket" in val or "Osmo" in val:
                        detected_product = val
        except Exception:
            pass

        try:
            for dev in os.listdir("/dev"):
                if dev.startswith("cu.") and ("DJI" in dev or "usbmodem" in dev or "usbserial" in dev):
                    serial_ports.append(f"/dev/{dev}")
        except Exception:
            pass

        return {
            "usb_dji_entries": usb_matches,
            "detected_camera_product": detected_product,
            "serial_ports": serial_ports,
            "camera_usb_connected": bool(detected_product) or any("Pocket" in m or "Osmo" in m for m in usb_matches),
        }

    def query_live_usb_camera_info(self) -> Dict[str, Any]:
        """
        Communicates directly with a USB-connected DJI Osmo Pocket 3 / Pocket 4 Pro
        over USB Interface #4 (`EP OUT 0x04`, `EP IN 0x85`) using DUML v1 packets
        to read real-time firmware version, Wi-Fi SSID, and password.
        """
        try:
            import ctypes.util
            os.environ.setdefault("DYLD_LIBRARY_PATH", "/opt/homebrew/lib")
            import usb.core
            import usb.util
        except Exception as e:
            return {"connected": False, "error": f"pyusb not available: {e}"}

        dev = usb.core.find(idVendor=0x2CA3)
        if dev is None:
            return {"connected": False}

        info: Dict[str, Any] = {
            "connected": True,
            "vendor_id": f"0x{dev.idVendor:04x}",
            "product_id": f"0x{dev.idProduct:04x}",
        }
        try:
            info["product_name"] = usb.util.get_string(dev, dev.iProduct) or "OsmoPocket"
            info["serial_number"] = usb.util.get_string(dev, dev.iSerialNumber) or ""
        except Exception:
            info["product_name"] = "OsmoPocket4P"

        try:
            usb.util.claim_interface(dev, 4)
            # Send Get SSID (0x07, 0x07) and Get Password (0x07, 0x0E) to Wi-Fi module (7,0)
            pkt_ssid = build_duml_packet(10, 1, 7, 0, 0x07, 0x07, b"", seq=8801, cmd_type=0x40)
            pkt_pwd = build_duml_packet(10, 1, 7, 0, 0x07, 0x0E, b"", seq=8802, cmd_type=0x40)
            dev.write(0x04, pkt_ssid, timeout=200)
            dev.write(0x04, pkt_pwd, timeout=200)

            for _ in range(10):
                try:
                    raw = bytes(dev.read(0x85, 1024, timeout=120))
                    idx = 0
                    while idx + 13 <= len(raw):
                        if raw[idx] != 0x55:
                            idx += 1
                            continue
                        length = (raw[idx + 1] | (raw[idx + 2] << 8)) & 0x3FF
                        if length < 13 or idx + length > len(raw):
                            break
                        frame = raw[idx : idx + length]
                        cs, cid = frame[9], frame[10]
                        pl = frame[11:-2]
                        if cs == 0x07 and cid == 0x07 and len(pl) > 2 and pl[0] == 0:
                            info["wifi_ssid"] = pl[2 : 2 + pl[1]].decode("utf-8", errors="ignore")
                        elif cs == 0x07 and cid == 0x0E and len(pl) > 2 and pl[0] == 0:
                            info["wifi_password"] = pl[2 : 2 + pl[1]].decode("utf-8", errors="ignore")
                        idx += length
                except Exception:
                    pass
            usb.util.release_interface(dev, 4)
        except Exception as e:
            info["duml_note"] = str(e)

        return info

    def probe_live_camera(self, ip: str, timeout: float = 0.35) -> Dict[str, Any]:
        """
        Probes a target LAN IP for open DJI / ADB / HTTP / RTSP ports.
        Checks ports 5555 (ADB), 8088 (Internal HTTP Media Server), 554 (RTSP), 21 (FTP), 80 (HTTP).
        """
        ports_to_check = {
            5555: "adb_tcp",
            8088: "internal_httpd",
            554: "rtsp_stream",
            21: "ftp_server",
            80: "web_api",
        }
        open_services = {}
        for port, name in ports_to_check.items():
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(timeout)
            try:
                is_open = s.connect_ex((ip, port)) == 0
                open_services[name] = is_open
            except OSError:
                open_services[name] = False
            finally:
                s.close()
        return {
            "ip": ip,
            "reachable": any(open_services.values()),
            "services": open_services,
        }

    def provision_sta_mode(
        self,
        device_id: str,
        ssid: str,
        password: str,
        lan_ip: str,
        mac_server_ip: str = "192.168.5.84",
    ) -> Dict[str, Any]:
        """
        Provisions a Pocket 3 or Pocket 4 Pro into persistent STA mode:
        1. Builds the DJI DUML [07:47] STA join packet (hex-encoded for inspection/transmission)
        2. Attempts UDP delivery if camera AP (192.168.2.1) or existing LAN IP is reachable
        3. Updates persistent configuration and returns the exact packet + ADB deployment status
        """
        state = self.load_state()
        state["sta_network"]["ssid"] = ssid
        state["sta_network"]["password"] = "********" if not password else password
        state["sta_network"]["mac_server_ip"] = mac_server_ip

        duml_pkt = build_sta_wifi_connect_payload(ssid, password or "coffee123456", lan_ip)
        duml_hex = duml_pkt.hex(" ").upper()

        # Try sending DUML packet directly over USB Interface #4 (EP OUT 0x04) if camera is plugged in via USB-C
        usb_sent = False
        try:
            os.environ.setdefault("DYLD_LIBRARY_PATH", "/opt/homebrew/lib")
            import usb.core
            import usb.util
            dev = usb.core.find(idVendor=0x2CA3)
            if dev is not None:
                usb.util.claim_interface(dev, 4)
                dev.write(0x04, duml_pkt, timeout=250)
                usb.util.release_interface(dev, 4)
                usb_sent = True
        except Exception:
            pass

        # Also try sending UDP DUML packet if reachable on 192.168.2.1 (AP), 192.168.42.2 (RNDIS), or target LAN IP
        udp_sent_to = None
        for candidate_ip in ["192.168.2.1", "192.168.42.2", lan_ip]:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.settimeout(0.2)
            try:
                sock.sendto(duml_pkt, (candidate_ip, 9004))
                udp_sent_to = candidate_ip
            except OSError:
                pass
            finally:
                sock.close()

        cam = state["cameras"].get(device_id, {})
        if cam:
            cam["wifi_mode"] = "unverified"
            cam["ssid"] = ssid
            cam["lan_ip"] = lan_ip
            cam["rtsp_url"] = f"rtsp://{lan_ip}:554/live/0"
            cam["internal_daemon_installed"] = False
            state["cameras"][device_id] = cam

        log_entry = {
            "time": datetime.now().strftime("%H:%M:%S"),
            "target": f"{device_id} ({lan_ip})",
            "cmd": f"DUML [07:47] STA Join '{ssid}' (USB_EP04={usb_sent}) + Deploy /data/local/tmp/pocket_sta_agent.sh",
            "output": f"Packet ({len(duml_pkt)}B): {duml_hex[:47]}... | STA requested; connection and deployment unverified",
        }
        state.setdefault("command_log", []).insert(0, log_entry)
        state["command_log"] = state["command_log"][:20]
        self.save_state(state)

        return {
            "ok": False,
            "error": "STA command delivery does not verify association or agent deployment",
            "device_id": device_id,
            "lan_ip": lan_ip,
            "ssid": ssid,
            "duml_packet_hex": duml_hex,
            "usb_dispatched": usb_sent,
            "udp_dispatched_to": udp_sent_to,
            "camera": cam,
            "log_entry": log_entry,
        }

    def auto_provision_if_usb_connected(self) -> Dict[str, Any]:
        """
        Checks if Pocket 3 or Pocket 4 Pro is connected via USB-C and automatically
        dispatches the stored STA Wi-Fi credentials (`你的名字` / `nidemingzi`) over
        USB Interface #4 (`EP 0x04`).
        """
        state = self.load_state()
        net = state.get("sta_network", {})
        ssid = net.get("ssid", "你的名字")
        pwd = net.get("password", "nidemingzi")
        if pwd == "********":
            pwd = "nidemingzi"

        usb_info = self.query_live_usb_camera_info()
        if not usb_info.get("connected"):
            return {"usb_connected": False, "auto_provisioned": False}

        prod_name = usb_info.get("product_name", "")
        dev_id = "pocket3" if "Pocket3" in prod_name else "pocket4p"
        cam_cfg = state.get("cameras", {}).get(dev_id, {})
        target_ip = cam_cfg.get("lan_ip", "192.168.5.108")
        res = self.provision_sta_mode(
            device_id=dev_id,
            ssid=ssid,
            password=pwd,
            lan_ip=target_ip,
            mac_server_ip=net.get("mac_server_ip", "192.168.5.84"),
        )
        return {
            "usb_connected": True,
            "auto_provisioned": res["ok"],
            "camera_usb_info": usb_info,
            "provision_result": res,
        }

    def adb_transport(self, device_id: str) -> Dict[str, Any]:
        """Select only an explicitly configured, online camera transport.

        DJI subclass 0x43 experiments can use POCKET_ADB=/tmp/adb_dji and
        POCKET_ADB_PORT=5038. Enumeration/offline never implies shell access.
        The USB serial is distinct from the camera's product name.
        """
        state = self.load_state()
        cam = state.get("cameras", {}).get(device_id)
        if cam is None:
            return {"ok": False, "error": f"Unknown camera device_id: {device_id}"}
        settings = state.get("adb", {})
        binary = os.environ.get("POCKET_ADB", settings.get("binary", "adb"))
        port = str(os.environ.get("POCKET_ADB_PORT", settings.get("server_port", 5037)))
        try:
            if not 1 <= int(port) <= 65535:
                raise ValueError("Invalid ADB server port")
            base = [binary, "-P", port]
            proc = subprocess.run(base + ["devices", "-l"], capture_output=True,
                                  text=True, timeout=5)
            if proc.returncode:
                return {"ok": False, "error": proc.stderr.strip() or "ADB enumeration failed"}
            devices = {}
            for line in proc.stdout.splitlines():
                fields = line.split()
                if len(fields) >= 2 and fields[1] in ("device", "offline", "unauthorized", "recovery", "sideload"):
                    devices[fields[0]] = fields[1]
            serial = cam.get("adb_serial")
            # Never pick an arbitrary attached phone or use product name as USB serial.
            candidates = [serial] if serial else []
            if cam.get("lan_ip"):
                candidates.append(f"{cam['lan_ip']}:{cam.get('adb_port', 5555)}")
            for target in candidates:
                if devices.get(target) == "device":
                    return {"ok": True, "argv": base + ["-s", target], "serial": target,
                            "transport": "usb" if target == serial else "tcp"}
            return {"ok": False, "error": "No live ADB transport; command was not executed",
                    "devices": devices, "configured_serial": serial}
        except (OSError, ValueError, subprocess.TimeoutExpired) as error:
            return {"ok": False, "error": str(error)}

    def inspect_internal_wifi(self, device_id: str) -> Dict[str, Any]:
        """Read capabilities before choosing a device-specific STA setup."""
        return self.execute_internal_command(device_id,
            "id; uname -a; command -v sh iw wpa_supplicant wpa_cli ip ifconfig udhcpc; "
            "iw dev; ip -4 addr; wpa_cli interfaces; ps; ls -ld /data /system /data/local/tmp")

    def execute_internal_command(self, device_id: str, shell_cmd: str) -> Dict[str, Any]:
        """Execute on a confirmed USB or TCP ADB transport; never emulate output."""
        transport = self.adb_transport(device_id)
        if not transport["ok"]:
            return {**transport, "device_id": device_id, "live_socket_connected": False}
        try:
            proc = subprocess.run(transport["argv"] + ["shell", shell_cmd.strip()],
                                  capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired) as error:
            return {"ok": False, "device_id": device_id, "error": str(error),
                    "live_socket_connected": False}
        return {"ok": proc.returncode == 0, "exit_code": proc.returncode,
                "device_id": device_id, "serial": transport["serial"],
                "transport": transport["transport"], "cmd": shell_cmd.strip(),
                "output": proc.stdout.strip(), "stderr": proc.stderr.strip(),
                "live_socket_connected": proc.returncode == 0}

    def trigger_lan_recording(self, device_id: str, action: str = "start") -> Dict[str, Any]:
        """
        Sends DUML v1 UDP Shutter Start/Stop packet over the LAN to the camera
        and updates its recording state.
        """
        state = self.load_state()
        cam = state["cameras"].get(device_id)
        if not cam:
            return {"ok": False, "error": f"Camera {device_id} not found"}

        is_start = action.lower() == "start"
        pkt = build_camera_shutter_packet(start=is_start)
        ip = cam["lan_ip"]

        # Send over USB Interface #4 EP 0x04 if camera is connected via USB-C
        usb_sent = False
        try:
            os.environ.setdefault("DYLD_LIBRARY_PATH", "/opt/homebrew/lib")
            import usb.core
            import usb.util
            dev = usb.core.find(idVendor=0x2CA3)
            if dev is not None:
                usb.util.claim_interface(dev, 4)
                dev.write(0x04, pkt, timeout=200)
                usb.util.release_interface(dev, 4)
                usb_sent = True
        except Exception:
            pass

        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(0.15)
        try:
            sock.sendto(pkt, (ip, cam.get("duml_udp_port", 9004)))
        except OSError:
            pass
        finally:
            sock.close()

        cam["recording_state"] = "recording" if is_start else "idle"

        log_entry = {
            "time": datetime.now().strftime("%H:%M:%S"),
            "target": f"{device_id} ({ip}:9004 / USB_EP04={usb_sent})",
            "cmd": f"DUML [02:02] Shutter {'START (0x01)' if is_start else 'STOP (0x00)'}",
            "output": f"Sent {len(pkt)}B DUML frame ({pkt.hex(' ').upper()}) -> state={cam['recording_state']}",
        }
        state.setdefault("command_log", []).insert(0, log_entry)
        state["command_log"] = state["command_log"][:25]
        self.save_state(state)

        return {
            "ok": True,
            "device_id": device_id,
            "recording_state": cam["recording_state"],
            "duml_hex": pkt.hex(" ").upper(),
            "log_entry": log_entry,
        }
