# DJI USB ADB follow-up — 2026-11-17

## Observed result

ADB shell is **not connected**. STA association, a 192.168.5.x DHCP address,
and deployment of `/data/local/tmp/pocket_sta_agent.sh` remain unverified and
were not performed. No claim is made that the camera lacks an enabled adbd;
its current USB bulk channels did not complete an ADB handshake.

The device product is `OsmoPocket4P-ANHXP5J0022DTW`, VID/PID `2ca3:0020`.
Its actual USB serial descriptor is `123456789ABCDEF` (not the product name).
Interfaces 3–7 are all FF/43/01. Their OUT/IN endpoint pairs are respectively
03/84, 04/85, 07/88, 08/89, 09/8a. All have 512-byte maximum packets.

The prior `investigate_usb.py` recorded subclass values but never tested ADB:
it only sent DUML on interface 4 and made TCP probes. It did not have an ADB
matcher or a CNXN implementation. Describing that as a failed ADB probe was
incorrect; raw CNXN attempts elsewhere are separate observations.

## ADB binary experiment

Installed platform-tools: 37.0.1-15733141. SHA256:
`1811e253b21b12cbfda7201ebaf86c10e7ddcb5c606a7a81f7c82b4c429c2d3b`.

REA's Rizin provider was unavailable (`ENOENT`), so native `nm`/`otool` were
used. ARM64 symbol `is_adb_interface(int,int,int)` starts at `0x1000ccec4`.
It checks protocol 1, class FF, subclass 42; it also accepts DC/02/01.
Unlike the suggested signature, this build's function has three arguments,
not VID/PID arguments. Both libusb and native macOS paths call it.

Extracted the ARM64 slice and changed exactly `cmp w1,#0x42` at file offset
`0xcced4`, instruction `0x7101083f`, to `cmp w1,#0x43` (`0x71010c3f`).
Ad-hoc signed `/tmp/adb_dji`; the original adb was not modified.
`daemon/patch_dji_adb.py` reproduces this for the exact source hash only.
It refuses unknown builds and existing output paths.

Both the default backend and explicit `ADB_LIBUSB=1` enumerate
`123456789ABCDEF offline` on separate server port 5038. Trace shows libusb
selects interface 3, claims 03/84, queues CNXN, and does not complete its header
write before shutdown. NO_DEVICE errors at shutdown are not evidence of an
independent device disconnect. The test server was stopped afterward.

## Raw USB experiment

See `usb-adb-probe.json`. All five interfaces could be claimed. GET_STATUS
returned zero for every endpoint. Explicit clear_halt succeeded and left zero.
No change in behavior followed. A device reset returned errno 19; rediscovery
and another probe succeeded but produced the same outcomes.

CNXN was sent as a separate 24-byte header and payload, with correct magic,
payload length and checksum. Tried version 01000000/max4096/banner host::NUL,
and version 01000001/max1048576 with shell_v2,cmd,stat_v2 features.

- Interfaces 3, 5, 6, 7: passive reads time out; **header writes** time out,
  before payload is sent. Changing the payload or its checksum cannot explain
  a transfer that has not delivered the header.
- Interface 4: header and payload writes complete; reads contain CRC-validated
  DUML frames, also present before sending CNXN. These are not CNXN/AUTH or
  correlated acknowledgments. This establishes a DUML channel.
- No shell banner or HDC handshake was observed. Silent vendor channels cannot
  be classified as shell/HDC from descriptors alone; no guessed HDC or shell
  command sequences were sent.

The Python server PID 51970 had libusb loaded, but IOKit did not show an owning
user client on interfaces 3–7 and all claims succeeded. Chrome 1236 and ChatGPT
1239 were running; lsof did not establish USB ownership. This rules out an
exclusive claim at probe time, not every possible transient interaction. No
applications were killed, kernel drivers detached, or storage interfaces claimed.

## Implementation and remaining work

`CameraInternalBridge` now supports an explicit ADB executable/server port,
USB serial and existing TCP transports. It selects only state `device`, never
an arbitrary phone or an offline/unauthorized camera. `inspect_internal_wifi`
provides the requested read-only capability inspection once ADB is online.
The observed serial is saved for pocket4p. Shell exit errors are propagated.
The existing speculative DUML STA provisioning is not validated by this work;
a working ADB STA provisioning method still requires a live camera shell and
inspection of its actual wireless interface/control service. The existing
exported agent is not evidence of installation.

Reproduction (stop any experimental 5038 server before raw probing):

```sh
python3 daemon/investigate_usb.py --adb --clear-halt
# Choose a fresh output filename if /tmp/adb_dji already exists:
python3 daemon/patch_dji_adb.py --output /tmp/adb_dji_new
/tmp/adb_dji_new -P 5038 devices -l
# Bridge environment, with cameras.pocket4p.adb_serial configured:
POCKET_ADB=/tmp/adb_dji_new POCKET_ADB_PORT=5038 python3 -c \
  'from core.camera_sta_bridge import CameraInternalBridge; print(CameraInternalBridge("data").inspect_internal_wifi("pocket4p"))'
/tmp/adb_dji_new -P 5038 kill-server
```

Upstream reference: [AOSP libusb transport](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/client/usb_libusb.cpp).
Local evidence, rather than current upstream source, establishes this installed
binary's exact instructions and device behavior.

Validation: `make test` passes 13 tests, including offline/wrong-device rejection,
explicit USB command routing, nonzero shell exits, and DUML/ADB frame distinction.

## Post File Transfer cancellation — 2026-11-17

Live probe after unplug/replug and dismissal of “已完成”:

- Requested invocation with `--rndis` exits 2: this checkout does not implement
  that option. Re-ran with `--adb --clear-halt`; interfaces 3/5/6/7 still time
  out writing CNXN headers, with endpoint status zero before/after clearing.
  Interface 4 accepts CNXN bytes but returns CRC-valid DUML, not ADB.
- Existing `/tmp/adb_dji -P 5038 devices -l` reports serial
  `123456789ABCDEF offline`. Experimental server stopped before further probes.
- Full descriptors and correlated DUML responses are saved in
  `usb-post-cancel-probe.json`. Interface 0 is E0/01/03, interface 1 is
  0A/00/00 (IN 81 / OUT 01); 3–7 retain FF/43/01 and previous endpoint pairs.
  Storage interfaces were not claimed.
- DUML 00:01 version queries to (8,0), (8,2), (1,0), (7,0) all return
  matching-sequence/source, CRC-valid responses. (8,2) includes `HG224 AC Ver.13`,
  (1,0) includes `PP-041`. Wi-Fi 07:07 returns payload `e0` from the first
  three targets; (7,0) returns AP SSID `OsmoPocket4P-4FB5`.
  These probes do not identify an ADB/USB mode setter or validate STA support.
  No undocumented mode-setting sweep was performed.
- User-space RNDIS INITIALIZE and SET current packet filter (15) both return
  status zero. ARP for 192.168.42.2 succeeds, MAC 56:d6:c1:16:5f:ed.
  ARP for 192.168.2.1 receives no response within three seconds.
- Raw Ethernet/IP/TCP SYN probes to 192.168.42.2 receive SYN+ACK on port 21;
  ports 22, 23, 80, 443, 554, 5555, 7878, 9004, 22345 return RST+ACK.
  Retransmissions from port 21 can appear in later capture windows; decode
  source ports rather than attributing every frame to the current probe.
  FTP authentication/content access and UDP services remain untested.
- `data/pocket_sta_config.json` is absent from both workspace and mirror.
  No online ADB shell or verified DUML STA connection was obtained, so no
  persistent hook was deployed and no LAN association/IP is claimed.

This establishes accessible RNDIS TCP port 21 after cancellation, but there is
no pre-cancellation RNDIS baseline proving that dismissal enabled it.
Follow-up remains necessary for FTP access, UDP services, and documented mode
commands. `make test`: 13 tests passed. Probe script archived alongside JSON;
its short response windows and limited command/port list are not exhaustive.
