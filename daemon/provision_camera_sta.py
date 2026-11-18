#!/usr/bin/env python3
"""Verify HG224 STA and recover /data/pocket-coffee/pocket_sta_agent.sh over USB ADB."""

import argparse
from datetime import datetime, timezone
import json
import os
import sys
import time

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from core.camera_sta_bridge import CameraInternalBridge


def _wait_for_heartbeat(bridge, device_id, ip, since, timeout=20):
    deadline = time.monotonic() + timeout
    while True:
        try:
            camera = bridge.load_state()["cameras"][device_id]
            verification = camera.get("verification", {})
            observed = datetime.fromisoformat(camera.get("last_heartbeat", ""))
            if (observed.tzinfo is not None and since <= observed <= datetime.now(timezone.utc)
                    and camera.get("wifi_mode") == "STA" and camera.get("lan_ip") == ip
                    and verification.get("heartbeat_verified") is True
                    and verification.get("heartbeat_source_ip") == ip):
                return camera
        except (KeyError, ValueError, TypeError):
            # The receiver may be writing the shared config, or no heartbeat has arrived yet.
            pass
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        time.sleep(min(0.5, remaining))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Verify Pocket camera STA via USB ADB and a fresh LAN heartbeat")
    parser.add_argument("--device", default="pocket4p", choices=["pocket4p", "pocket3"], help="Camera device ID")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--status", action="store_true", help="Verify the live agent and STA heartbeat (default)")
    mode.add_argument("--legacy-duml", action="store_true", help="Explicitly send an unverified legacy STA join request")
    parser.add_argument("--ssid", help="Wi-Fi SSID for --legacy-duml (defaults to sta_network.ssid)")
    parser.add_argument("--password", help="Wi-Fi password for --legacy-duml (defaults to sta_network.password)")
    parser.add_argument("--lan-ip", help="Expected LAN IP (defaults to verified_sta_ip or lan_ip)")
    parser.add_argument("--server-ip", help="Mac server address for --legacy-duml (defaults to sta_network.mac_server_ip)")
    parser.add_argument("--recover-adb", action=argparse.BooleanOptionalAction, default=True,
                        help="Start the installed agent if stopped; --no-recover-adb only checks it")
    parser.add_argument("--pull-latest", action="store_true", help="Download the newest full MP4 after verifying STA")
    parser.add_argument("--exec", dest="shell_cmd", default="", help="Optional root shell command to run inside camera")
    args = parser.parse_args(argv)

    try:
        bridge = CameraInternalBridge(os.path.join(PROJECT_ROOT, "data"))
        state = bridge.load_state()
    except (OSError, json.JSONDecodeError) as exc:
        print(f"Could not read camera configuration: {exc}", file=sys.stderr)
        return 1
    network = state["sta_network"]
    camera = state["cameras"][args.device]
    lan_ip = (args.lan_ip or camera.get("verification", {}).get("verified_sta_ip")
              or camera.get("verified_sta_ip") or camera.get("lan_ip"))
    if not lan_ip:
        parser.error("No LAN IP configured for this camera; pass --lan-ip")

    if args.legacy_duml:
        ssid = args.ssid if args.ssid is not None else network.get("ssid")
        password = args.password if args.password is not None else network.get("password")
        server_ip = args.server_ip or network.get("mac_server_ip")
        if not ssid or not password or password == "********" or not server_ip:
            parser.error("A Wi-Fi SSID, password and server IP are required for --legacy-duml")
        result = bridge.provision_sta_mode(device_id=args.device, ssid=ssid, password=password,
                                           lan_ip=lan_ip, mac_server_ip=server_ip)
        print(result.get("error", "Legacy STA join requested"), file=sys.stderr)
        return 0 if result.get("ok") else 1
    if any(value is not None for value in (args.ssid, args.password, args.server_ip)):
        parser.error("--ssid, --password and --server-ip require --legacy-duml; USB recovery uses the installed camera profile")

    since = datetime.now(timezone.utc)
    agent = bridge.ensure_sta_agent_over_usb(args.device, restart_if_stopped=args.recover_adb)
    if not agent["ok"]:
        print(f"{args.device}: USB ADB/agent check failed: {agent['status']}"
              f" ({agent.get('error') or agent.get('serial') or args.device})", file=sys.stderr)
        return 1
    print(f"{args.device}: USB ADB {agent['serial']} device; STA agent {agent['status']}", flush=True)
    live = _wait_for_heartbeat(bridge, args.device, lan_ip, since)
    if live is None:
        print(f"{args.device}: no fresh verified STA heartbeat from {lan_ip}; check the receiver on port 8788",
              file=sys.stderr)
        return 1
    print(f"{args.device}: verified STA heartbeat from {lan_ip} at {live['last_heartbeat']}")
    print(f"Latest MP4 URL: {live.get('latest_media_url') or 'not reported'}")

    if args.pull_latest:
        result = bridge.pull_latest_media(args.device)
        if not result["ok"]:
            print(f"MP4 download failed: {result['error']}", file=sys.stderr)
            return 1
        print(f"Downloaded {result['local_path']} ({result['size_bytes']} bytes)")

    if args.shell_cmd:
        cmd_res = bridge.execute_internal_command(args.device, args.shell_cmd)
        if not cmd_res["ok"]:
            print(cmd_res.get("error") or cmd_res.get("stderr") or "Camera shell command failed", file=sys.stderr)
            return 1
        print(cmd_res.get("output", ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
