# Pocket 4 Pro cable-free cold-boot auto-start — 2026-11-18

Target: DJI Osmo Pocket 4 Pro (`eagle4_hg224`), USB ADB serial `123456789ABCDEF`,
on-camera agent `/data/pocket-coffee/pocket_sta_agent.sh` (`v7-hg224-camera-mic`).
Goal: bring the STA + microphone voice agent back after a USB-free cold boot
without touching the read-only `/system` or `/vendor` partitions.

## Conclusion

There is no safe executable boot hook under `/data` on this firmware, so the
agent cannot be made to auto-start from the camera side alone. The working
cable-free path is the Mac auto-recovery watcher (`recover_camera_once`):
USB ADB → existing LAN ADB listener → BLE STA provisioning. This run made that
path functional and durable:

- Installed the BLE recovery dependencies (`bleak` + PyObjC) into the server's
  Python 3.9 interpreter; a live BLE scan finds `OsmoPocket4P-4FB5`.
- Verified the camera's TCP ADB listener on `5555` accepts a valid ADB CNXN
  (no authentication required) and that LAN agent recovery succeeds.
- Persisted `persist.adb.tcp.port=5555` in `/data/property` so the TCP ADB
  listener survives cold boot independently of USB trigger timing.
- Added durable `auto_recovery` fallbacks (`ble_name`, `lan_ip`, `lan_macs`).

A true USB-free cold boot was performed and the agent recovered: `adb reboot`
with the USB cable unplugged, uptime reset to ~2 min, adbd started ~5 s into boot
(`ro.boottime.adbd`), BLE pairing returned `00 01` (persisted across the reboot,
no re-approval), BLE switched the camera to STA and it joined the home LAN, and
the agent restarted with a fresh PID and verified heartbeats. The only manual
step was driving BLE from an interactive Python session because the launchd
server lacks macOS Bluetooth permission; granting Bluetooth to Python makes the
watcher fully autonomous.

A recovery bug was also fixed: a non-clean BLE join ACK (`01ff`) or join timeout
previously raised `ble_sta_join_rejected`/`ble_sta_join_timeout` and stopped
recovery even though the camera had joined. `recover_camera_once` now retries LAN
ADB after those join-stage errors, since a verified heartbeat — not the BLE ACK —
is the recovery criterion.

## Boot-hook investigation (read-only, no firmware changed)

Boot chain: `/init.rc` → `init.eagle4.rc` service `start_dji_system` →
`/system/bin/start_dji_system.sh` → `dji_eagle4_platform_config.sh` +
`product_config.sh` (+ `sec_func_ctrl.sh`), running `boot_config fs/module/
service/misc/debug`.

Candidates inspected and rejected:

- `product_debug_late_config` runs `/system/bin/debug.sh` — file is empty.
- `init.rc` service `auto_sd_ota` runs `/system/bin/auto_sd_ota.sh` — empty.
- `/data/dji/amt/state` → `aging_test.sh` only for `aging_test*`/`link` states;
  factory aging test (LED/codec/storage stress), unsafe for normal use.
- `/data/dji/cfg/clean_log_en` → `clr_factory_dat.sh` deletes files from a JSON
  list; destructive, not a launcher.
- `start_upgrade_test.sh -r` (run at boot) only calls `upgrade_test load_cmd`;
  the `/data/upgrade_test_param` exec path needs `-e`, which boot does not pass.
- No `on property:persist.*` trigger executes a script; `load_persist_props`
  only loads property values.
- `pulseaudio` runs with `XDG_CONFIG_HOME=/data/pulse`, but its startup script
  is fixed to `/system/etc/pulse/default.pa`; injecting audio config risks the
  microphone path the agent depends on. Not used.
- `dji_bluetooth_service` and `dji_network` are read-only binaries started at
  boot; no `/data` script injection point.

`/system` (`sdc19`) and `/vendor` (`sdc21`) are read-only ext4,
`ro.boot.veritymode=enforcing`, `/sys/class/block/sdc19/ro=1`. Writable
persistent partitions confirmed: `/data` (`sdc23`), `/blackbox` (`sdc24`),
`/cali` (`sdc4`). No block flags, mounts, init files, or firmware were changed.

## Cold-boot TCP ADB listener

`usb.init=1` is set unconditionally during boot (`init.product.rc`
`on start_dji_sys_action` and `platform_misc_config`), independent of the USB
cable. `on property:usb.init=1` triggers `init_usb2`, which sets
`service.adb.tcp.port 5555`; adbd then listens on TCP `:::5555`. Live evidence:
`getprop usb.init=1`, `coldboot_state=done`, `service.adb.tcp.port=5555`,
`netstat` shows `17103/adbd` on `:::5555`.

A valid ADB CNXN (correct `magic = cmd ^ 0xffffffff` and data checksum) sent to
`192.168.5.93:5555` returns `CNXN device::ro.product.name=eagle4_hg224…` with no
AUTH challenge. (Earlier zero-magic probes were malformed and adbd correctly
closed them; that was a probe bug, not a camera fault.)

Hardening applied: `setprop persist.adb.tcp.port 5555`, confirmed present in
`/data/property/persistent_properties`. `load_persist_props` restores it on boot,
so the TCP listener no longer depends solely on `init_usb2` timing.

Note: a stale Mac `adb` server reported `No route to host` for `adb connect`
while raw TCP connected fine; `adb kill-server && adb start-server` cleared it
and both USB and LAN transports then enumerated as `device`. This is a Mac-side
transient, not a camera cold-boot behavior.

## Cold-boot adbd is cable-independent (setup_usb.sh)

`init_usb2` starts `service setup_usb /system/bin/setup_usb.sh 1 1 1 1`. That
script chooses `sys.usb.config` from `/proc/cmdline` flags, **not** from USB
cable presence:

- `mp_state=production` → `mpstate=0`.
- `androidboot.secure_debug=1` → `sec_state!=0` and `sec_exist=0`.
- The disable condition `mpstate==0 && (sec_state==0 || sec_exist!=0)` is
  therefore false, so the script takes the **adb-enabled** branch and runs
  `setprop sys.usb.config rndis,empty_storage,bulk,adb`.

The matching `on property:sys.usb.config=rndis,empty_storage,bulk,adb` trigger
runs `start adbd` *before* it binds the gadget to the UDC, so adbd starts and
listens on TCP `5555` (via `service.adb.tcp.port` / `persist.adb.tcp.port`)
even when no USB cable is attached. Live cmdline confirmed
`mp_state=production` and `androidboot.secure_debug=1`.

Important distinction: unplugging USB at *runtime* sets `sys.usb.config=none`,
whose trigger runs `stop adbd` (this is why TCP 5555 refused connections after
an unplug while the camera kept running). A *cold boot* re-runs `setup_usb.sh`,
which re-selects the adb config and starts adbd again. The runtime-unplug
observation does not imply a USB-free cold boot lacks adbd. A physical cold
boot is still needed to confirm this end to end.

## Live BLE test (USB unplugged, camera still running; no reboot yet)

The camera had only been unplugged, not power-cycled (uptime 9h32m, agent PID
unchanged), so this exercises BLE recovery on a running camera, not a cold boot:

- First `provision_over_ble`: pairing approved on screen, STA mode `07:48`
  acknowledged, `07:47` join ACK timed out but the camera functionally re-joined
  the home LAN (new DHCP IP `.94`, agent heartbeats resumed).
- Second pairing probe returned `07:45 = 00 01` (already paired, no re-prompt),
  so pairing persists within a boot session. Cross-reboot persistence is still
  to be confirmed by a real cold boot.
- The launchd server's own watcher returned `ble_permission_denied`: the
  LoginAgent `com.velbentz.pocket-coffee-log` runs the venv Python
  (`com.apple.python3`) whose macOS Bluetooth TCC permission is not granted.
  Interactive Python (responsible process = the editor app) has Bluetooth
  access and can drive BLE; the detached server cannot until Bluetooth is
  granted to Python in System Settings → Privacy & Security → Bluetooth.

Remaining for full autonomous cable-free cold boot: grant Bluetooth to Python
(`com.apple.python3`) and restart the LoginAgent, then unplug USB and
power-cycle the camera and observe BLE → STA → LAN ADB → agent heartbeat.

## STA association on cold boot

The agent's `wpa_supplicant` uses `/data/misc/wifi/pocket_sta.conf` (home SSID
`你的名字`, hex `e4bda0e79a84e5908de5ad97`), but the agent is not running at boot,
so that supplicant is not started by the camera. `dji_network` boots into its own
AP (`user_config.conf` `ssid=OsmoPocket4P-4FB5`, `mode=1`, `user_wifi_state=0`);
`savedap.conf` holds the home AP but is not auto-joined without a trigger.
Expected cold-boot state: camera in AP mode, not on the home LAN, TCP ADB
listening on 5555 but unreachable over Wi-Fi until STA is established. The
Mac watcher therefore needs BLE to switch the camera to STA and join the home AP
before LAN ADB can start the agent. (To be confirmed during the physical cold
boot.)

## Mac auto-recovery path

`recover_camera_once` checks a fresh verified heartbeat (≤20 s) first; otherwise
USB ADB → LAN ADB (MAC-matched, never enables TCP ADB) → BLE. BLE
(`provision_over_ble`) pairs (`07:45`), switches STA (`07:48 01`), waits 10 s,
joins with credentials (`07:47`); only a new verified heartbeat counts as
recovery. The exact BLE name selector `OsmoPocket4P-4FB5` avoids a second nearby
Osmo device (`OsmoPocket4P-9C02`) seen in the scan.

Verified this run (USB still connected):

- `bleak` imports in the server interpreter; 6 s BLE scan finds the camera.
- `ensure_sta_agent_over_lan` → `already_running` (MAC `88:22:33:77:33:99`
  matches the live wlan0 address).
- Live watcher `watcher_running=true`, `status=healthy`, heartbeat age ~2 s.
- Repo `data/pocket_sta_agent.sh`, embedded `ON_CAMERA_AGENT_SCRIPT`, and the
  deployed camera script are byte-identical (13846 bytes, SHA-256
  `1b5af8470ddfb3378226320f71803eda0ea54f0fbdca8742e9c0047cd5aa855e`).
- `make test`: 79 tests, OK (1 skipped).

## Pending physical verification (needs user)

1. Live BLE pairing: trigger pairing, approve `07:45` on the camera screen,
   confirm `07:48 01` + `07:47` join, then a verified heartbeat. Re-run pairing
   to learn whether it returns `00 01` (already paired) or `00 02` (needs
   approval) — i.e. whether pairing persists across cold boot.
2. USB-free cold boot: unplug USB, power-cycle the camera, and observe the Mac
   watcher recover the agent (BLE → STA → LAN ADB → heartbeat) without cable.

Storage evidence for BLE persistence: `/data/misc/bluetooth/9C:5A:8A:97:4F:B6/`
holds a bonded peer (`64:31:35:1F:11:9D`) and a `cache` directory on the writable
`/data` partition, so link-layer BLE bonds survive reboot. Whether the DJI
app-level pairing (`07:45` identifier/pin) also persists without re-approval is
not established by storage alone and must be confirmed by the live re-pair test.

## Verified USB-free cold boot (2026-11-18 ~23:50 CST)

Procedure: `adb -s 123456789ABCDEF reboot`, USB cable unplugged as the camera
powered down, camera booted with no cable. BLE driven manually from interactive
Python (server Bluetooth permission not granted).

Evidence:

- Uptime reset to ~2 min (was 9h36m); agent PID changed 12032 → 2893, so the
  agent was freshly started after boot, not a survivor.
- `ro.boottime.adbd = 5014049477` ns (~5.0 s into boot): adbd started early via
  the `setup_usb.sh` boot trigger while USB was unplugged.
- `persist.adb.tcp.port=5555` survived the reboot; `adb connect 192.168.5.94:5555`
  succeeded over Wi-Fi (TCP `connect_ex = 0`).
- BLE pairing after the reboot returned `07:45 = 00 01` (already paired) — the
  bond in `/data/misc/bluetooth` persists across cold boot, no screen re-approval.
- `07:48 = 00 00` STA mode acknowledged; `07:47` join ACK was `01ff` (first
  attempt timed out) but the camera functionally joined the home LAN at `.94`
  (wlan0 MAC `9c:5a:8a:97:4f:b5`).
- Agent heartbeats resumed from `.94` (`v7-hg224-camera-mic`, verified source IP).

Remaining for full autonomy: grant Bluetooth to Python (`com.apple.python3`) in
System Settings → Privacy & Security → Bluetooth and restart the LoginAgent
`com.velbentz.pocket-coffee-log`; the watcher then drives BLE itself. The join-ACK
LAN-retry fix removes the other autonomous-recovery blocker.

## Changes made

- Camera: `persist.adb.tcp.port=5555` (persistent property, `/data/property`).
- Mac: installed `daemon/requirements-ble.txt` into Python 3.9 user site.
- Config: `auto_recovery = {ble_name, lan_ip, lan_macs}` in runtime + repo.
- `core/camera_sta_bridge.py`: `recover_camera_once` retries LAN ADB after a
  non-clean BLE join ACK / join timeout (plus a regression test). The agent
  script is unchanged; `pocket_sta_agent.sh` and `ON_CAMERA_AGENT_SCRIPT` remain
  byte-identical (SHA-256 `1b5af847…`). `make test`: 80 tests OK (1 skipped).
