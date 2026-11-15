#!/usr/bin/env python3
"""
CLI utility to provision DJI Osmo Pocket 3 / Pocket 4 Pro into persistent LAN STA mode
and install the internal on-camera daemon (`/data/local/tmp/pocket_sta_agent.sh`).
"""

import argparse
import os
import sys

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from core.camera_sta_bridge import CameraInternalBridge


def main() -> None:
    parser = argparse.ArgumentParser(description="Pocket 3 / Pocket 4 Pro Persistent STA & Internal Shell Installer")
    parser.add_argument("--device", default="pocket4p", choices=["pocket4p", "pocket3"], help="Camera device ID")
    parser.add_argument("--ssid", required=True, help="Home Wi-Fi Router SSID for STA mode")
    parser.add_argument("--password", required=True, help="Home Wi-Fi Password")
    parser.add_argument("--lan-ip", default="192.168.5.108", help="Target LAN IP for the camera")
    parser.add_argument("--server-ip", default="192.168.5.84", help="Mac Coffee Server LAN IP")
    parser.add_argument("--exec", dest="shell_cmd", default="", help="Optional root shell command to run inside camera")
    args = parser.parse_args()

    bridge = CameraInternalBridge(os.path.join(PROJECT_ROOT, "data"))
    res = bridge.provision_sta_mode(
        device_id=args.device,
        ssid=args.ssid,
        password=args.password,
        lan_ip=args.lan_ip,
        mac_server_ip=args.server_ip,
    )
    print(f"✅ DUML [07:47] STA Provision Packet Generated ({args.device} -> {args.ssid} @ {args.lan_ip}):")
    print(f"   HEX: {res['duml_packet_hex']}")
    print(f"   On-Camera Daemon Script exported to: {bridge.script_export_path}")

    if args.shell_cmd:
        cmd_res = bridge.execute_internal_command(args.device, args.shell_cmd)
        print(f"\n📟 Internal Shell Output ({args.lan_ip}:5555):")
        print(cmd_res["output"])


if __name__ == "__main__":
    main()
