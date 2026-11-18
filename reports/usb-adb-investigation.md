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

## Authorized command discovery — 2026-11-17

Executed 1,792 empty-payload requests: all 256 command IDs in Wi-Fi set 07
at (7,0), (8,0), (8,2), and sets 00/08 at (8,0), (8,2).
`command-discovery.jsonl` records correlated CRC-valid response payloads,
sequence, target and request length; AP credential response 07:0e is redacted.
`command-discovery-summary.json` lists every non-e0 response. Empty response
payloads are recorded separately from timeouts; a non-e0 response alone does
not establish success or command meaning. Response window is 250 ms.

Only 07:46 on (7,0) returned e4 on empty payload. All zero-filled lengths
1–160 timed out; none produced an accepted-length response. Postflight empty
07:46 still returned e4, version and SSID queries succeeded. Thus the transport
remained available, but no STA request structure was discovered. The claim
that e4 necessarily proves a simple fixed-size structure remains unverified
for this particular handler. No credential-bearing STA request was sent.
07:ae returned 000000 and 07:44 returned 000001 after probing; neither is
an identified STA IPv4 address. ARP snapshot is archived; without a known
STA MAC/IP, it cannot prove association. No USB/ADB setter was identified.
The requested STA connection remains incomplete; no persistent provisioning
implementation is warranted by these observations.

The scripts are explicitly invasive live experiments, not passive discovery:
unknown empty commands or zero buffers can alter settings. Do not rerun them
without authorization. They leave storage interfaces unclaimed.

Validation: `make test` passed all 13 tests. No production code changed.

RNDIS SYN scan: 2,096 ports probed using the current ARP-resolved camera MAC
(ea:9c:36:fe:5b:fd). Port 21 returned SYN+ACK, 173 ports returned RST,
and 1,922 had no observed response. No additional open TCP service was found,
but unresponsive ports are inconclusive. The initial scan used the old MAC
and was invalid; the archived raw results replace that run with the corrected
scan. Raw frames and decoded summaries are in port-discovery*.json.
Responses are attributed by source port, not capture window. The 40 ms
per-port window, single attempt, and possible rate limiting can miss responses.
This is not an exhaustive 65,535-port scan. Coverage includes 1–1024,
5555–5585, 8000–9010 and selected common services listed in the script.
Both 192.168.42.2 and 192.168.2.1 answered raw RNDIS ARP in this run.


## Targeted live Wi-Fi probe, 2026-11-17

Reconfirmed hardware MAC `9c:5a:8a:97:4f:b5` from live `07:0c`. Previous lines 1793–1952 were USB Errno 19, not valid length tests; line 1158 records the preceding (8,2) 00:85 request, but the log alone cannot prove reboot causality.

No 07:08, 07:0d, 07:0f or (8,2) commands were sent. First run stopped after 07:10 returned 00 and subsequent MAC health check timed out. Reopened handle, resumed at 07:11; missing responses triggered bounded health checks before continuing.

Empty-payload results (duplicate attempts included):

| Command | Responses |
|---|---|
| 07:10 | 00 |
| 07:11 | e0 |
| 07:12 | e0 |
| 07:13 | e0 |
| 07:14 | e0 |
| 07:15 | 00 |
| 07:16 | e0 |
| 07:17 | e0 |
| 07:18 | 01 |
| 07:19 | 00ff434e00 |
| 07:1a | 0000 |
| 07:1b | e0 |
| 07:1c | e3 |
| 07:1d | e3 |
| 07:1e | e0 |
| 07:1f | 00 |
| 07:20 | 0000 |
| 07:21 | timeout (health checked) |
| 07:22 | e0 |
| 07:23 | e0 |
| 07:24 | e0 |
| 07:25 | e0 |
| 07:26 | e0 |
| 07:27 | e0 |
| 07:28 | e0 |
| 07:29 | e4 |
| 07:2a | e0 |
| 07:2b | 00 |
| 07:2c | 00a1 |
| 07:2d | e0 |
| 07:2e | e0 |
| 07:2f | e0 |
| 07:30 | 01 |
| 07:31 | 00 |
| 07:32 | e0 |
| 07:33 | e0 |
| 07:34 | 01 |
| 07:35 | e0 |
| 07:36 | e0 |
| 07:37 | e0 |

Raw lengths 1–160 and 21 string-pattern candidates tested for 07:46, 07:1c, 07:1d, 07:29, 07:b2 and 07:b6. Correction: 07:1d rejected raw 19 zero bytes (seq=41432, e3). Only the structured 19-byte credential candidates with prefix [1,0] and [1,1] succeeded (seq=41581 and 41589). Seq=41586 and MAC health seq=41587 timed out; this is consistent with reconfiguration but does not prove association. 07:29 accepted one zero byte; its empty and 2–160-byte requests returned e4, supporting a command-specific length/format check. No working STA configuration sequence was confirmed; target credentials and join triggers were therefore not sent, and core/camera_sta_bridge.py was not changed. Pattern coverage is finite, not proof that no valid format exists.

Final status polls:
- 07:48: []
- 07:4a: [{'payload': '0000054661696c00', 'first_byte': 0}]
- 07:4b: [{'payload': '00ff00054661696c00', 'first_byte': 0}]
- 07:4d: [{'payload': '0000000000', 'first_byte': 0}]
- 07:44: [{'payload': '000101', 'first_byte': 0}]
- 07:ae: [{'payload': '000000', 'first_byte': 0}]

07:4d remains 0.0.0.0. LAN ARP snapshot saved separately; no successful association established. No RNDIS ARP or subnet ping sweep performed. Evidence: targeted-sta-discovery.jsonl and targeted-sta-discovery.py. `make test` passed.


## Dynamic credential follow-up (2026-11-17)

Live USB MAC baseline again returned `009c5a8a974fb5`. Credentials were loaded
from `data/camera_sta_config.json`, without logging request contents.
`07:1d` accepted **26-byte** `[1, flag, ssid_len, ssid, psk_len, psk]`
requests for both flag 0 and flag 1 (12-byte UTF-8 SSID, 10-byte password),
returning `00` for each. This disproves the fixed-19-byte interpretation and
supports a variable-length credential format. The precise meanings of mode
and flag and the complete parser validation rules remain unproven.

After each request, polling for 12 seconds covered 07:07, 18, 30, 44, 48, 4a,
4b, 4d, ae. SSID getter remained the camera AP name; 4a returned
`0000054661696c00` and 4b `00ff00054661696c00` (both contain `Fail`);
4d remained `0000000000`. No successful STA association was established.
LAN ARP snapshots contain no camera hardware MAC. RNDIS initialization and
packet-filter setup succeeded; ARP replies were received for 192.168.42.2
and 192.168.2.1. These USB-side addresses do not establish a LAN DHCP lease.
No fresh LAN subnet sweep was performed, so cache absence is not conclusive.

07:46 zero payload lengths 161–500: 339 returned e4; length 499 timed out
both initially and on retry, while MAC health responded. Length 499 produces
a 512-byte DUML frame, so a transport packet-boundary issue is an alternative
to command-level rejection. It must not be counted as an e4 response.
The same 26-byte flag-0 credential pattern returned: 07:46 e4; 07:43 ff;
07:47 no response (health check succeeded); 07:4a 00; 07:4b 0000.
The last two ACKs alone do not establish setter semantics or connection.

Evidence: `dynamic-sta-verification.py`, `dynamic-sta-verification.jsonl`,
`dynamic-sta-arp.txt`, `dynamic-sta-rndis.py`, `dynamic-sta-rndis.json`.
No production STA command change was made because association was not verified.
`make test`: all 13 tests passed.

## Bounded getter and destination-IP verification (2026-11-17)

Queried (7,0), command set 07, without resending credentials. Sequences
52001–52012 in `bounded-sta-getters.jsonl` correspond to baseline empty
4a/4b/4d, then 4a inputs 00/01/ff, 4b inputs 00/01/ff, then empty
4a/4b/4d again. Baseline and final empty replies were identical:
4a `0000054661696c00`, 4b `00ff00054661696c00`, 4d `0000000000`.
For 4a, both one-byte 00 and 01 returned `00`; ff returned the full
baseline reply. For 4b, both 00 and 01 returned `0000`; ff returned the
full baseline reply. This supports an indexed-getter interpretation of the
previous 26-byte requests: their first byte 01 alone reproduces the replies.
There is no observed status/IP change or association. These observations do
not prove trailing-byte parsing rules or exclude hidden setter side effects;
the original experiment did not capture immediate post-request status.

RNDIS Interfaces 0/1 initialization and filter setup succeeded. ARP for
192.168.2.1 returned MAC `ea:9c:36:fe:5b:fd`. Sent one TCP SYN per port
21, 22, 23, 80, 443, 554, 5037, 5555, 7878, 8080, 8088, 9004, 22345,
using that destination MAC, destination IP 192.168.2.1, source IP
192.168.2.2 and source port 40000. Each had a 300 ms receive window:
no packets were received (neither SYN-ACK nor RST). No open service was
established; silence cannot distinguish filtering, routing, or closed ports.

Sent all 254 ARP requests for 192.168.5.1–192.168.5.254 using source
192.168.2.2, with 20 ms receive windows and a final two-second drain.
No replies were received. A subsequent ARP control for 192.168.2.1 again
returned the same MAC, establishing that USB ARP remained operational.
Under the stated weak-host ARP behavior this supports absence of an
ARP-visible 192.168.5.x address; it is not direct kernel address enumeration
and cannot exclude different ARP policy, packet loss, or transient state.

Reproducible scripts and raw evidence: `bounded-sta-getters.py`,
`bounded-sta-getters.jsonl`, `bounded-sta-rndis.py`, `bounded-sta-rndis.json`.
The saved RNDIS run uses the valid control source 192.168.2.2; an earlier
exploratory sweep using network address 192.168.5.0 was superseded.
No production changes. `make test`: all 13 tests passed.


## User-enabled ADB follow-up — 2026-11-17, observed from 23:52 CST

Outcome: **blocked before shell access; STA, installation, persistence and
camera-origin heartbeat remain unverified.** The user confirmed that the
camera screen is on and the USB connection is in charge-only mode.
This does not establish that the device-side ADB service is accepting CNXN.

Live identity: USB product `OsmoPocket4P-ANHXP5J0022DTW`, vendor/product
`2ca3:0020`, USB serial `123456789ABCDEF`. Product suffix and USB serial are
not interchangeable. Standard `adb devices -l` and the default macOS backend
of `/tmp/adb_dji` list no device. With a fresh experimental server and
`ADB_LIBUSB=1 /tmp/adb_dji -P 5038 devices -l`, the camera is enumerated as
`123456789ABCDEF offline`; the explicitly selected shell attempt returns
`adb_dji: device offline`. Rechecked after the user's charge-only confirmation
with the same result. Experimental server 5038 was stopped after testing.
No online ADB transport or shell output was obtained.

`python3 daemon/investigate_usb.py --adb` was run after stopping the
experimental server. This checkout has no `--usb` flag. The saved raw results
are in `adb-enabled-live-probe.json`: all five candidate interfaces can be
claimed, endpoint statuses are zero, and interfaces 3/5/6/7 time out at the
24-byte CNXN **header write** for both offered versions. Interface 4 accepts
header and payload but returns CRC-valid DUML, not CNXN/AUTH. No USB reset,
storage-interface claim, undocumented mode setter, or Wi-Fi reconfiguration
was performed. This confirms failure to establish ADB in this attempt; it
does not identify why the device is not servicing the candidate endpoints.

Consequently `uname`, `id`, `/proc/cpuinfo`, `df`, `mount`, interface/routes,
processes and persistent directories cannot be read. Real driver commands,
SD-card paths, persistent storage and boot hooks cannot be selected from
this evidence. `core/camera_sta_bridge.py` and `data/pocket_sta_agent.sh` were
reviewed but not changed or deployed: their Android paths and startup/restart
assumptions remain unverified on this camera. No reboot or sleep/wake
persistence test occurred. ADB TCP was not enabled. No camera IP, bidirectional
LAN ping, or camera-origin HTTP request was verified.

Mac `en0` is `192.168.5.84`; Python PID 51970 already listens on `*:8788`, so
no duplicate server was started. The actual entry point is `server/app.py`
(`make server`), not a root `server.py`. A **Mac-origin** POST with `{}` to
`http://192.168.5.84:8788/api/camera/heartbeat` returns HTTP 404 and
`Unknown endpoint /api/camera/heartbeat`. This is a server-route probe only,
not a camera heartbeat. Source inspection confirms this route is absent;
the exported agent currently posts video webhooks rather than heartbeats.
Implementing and validating this receiver remains necessary before the
requested end-to-end heartbeat can pass. These findings are separately saved
in `adb-enabled-live-status.json` with command arguments, exit codes and
outputs, including the libusb recheck.

Configuration integrity: `sta_network.mac_server_port` now matches the
observed listener (8788). Pocket4p's previous example LAN IP, heartbeat,
capabilities, battery/storage values and installed-agent claims were cleared
or marked unknown. `verification` explicitly records the ADB blocker and
null verified STA IP. Existing pocket4p command-log entries are retained but
marked `legacy_unverified`; they must not be treated as hardware evidence.
The MAC value is attributed to the prior archived DUML getter, not a fresh
shell read. Pocket3 was not tested in this attempt.

Resume prerequisite: an actual `device` transport and successful `shell id`.
Then inspect the requested kernel/filesystem/network details before choosing
STA commands or writing persistent hooks. Keep USB ADB available while
verifying association, DHCP, both ping directions, HTTP heartbeat reception
and restart behavior. Do not interpret an offline transport, a sent DUML
packet or a host-origin POST as success.

Validation: `make test` passed all 13 tests. These tests exercise repository
behavior; they do not prove live STA connectivity or installation.

## 2026-11-18: working root ADB and first verified STA association

This supersedes the previous offline blocker **for the successful portion of
this session**. `/opt/homebrew/bin/adb devices -l` directly returned serial
`123456789ABCDEF device`, product/device `eagle4_hg224`, model
`Android_NATIVE_on_e4_hg224`. The user's ADB server was not killed or replaced.
`adb shell id` returned uid/gid 0 and context `u:r:su:s0`.
`uname -a` returned Linux 5.4.123-rt59-g817cddd0ea60-dirty-ab36000,
aarch64, PREEMPT_RT, build date Aug 25 2026. Android properties, Bionic linker
messages and Android init services were observed. SELinux remains Enforcing.
Camera wall clock was Jan 3 2000, so receiver timestamps must use the Mac clock.

Filesystem inspection (`df -h`, `mount`, directory listings): `/system` is
read-only ext4 (`sdc19`, 951M); `/data` is writable ext4 (`sdc23`, 108M);
`/blackbox` is writable ext4 (`sdc24`, 4.3G). Actual media volume is
`/mnt/media_rw/emulated` (exFAT, sdc27, 104G), containing `DCIM/DJI_001`.
`/amt` and `/etc/wifi` are absent. The system uses `/system/bin/sh`.

Initially only lo, tunnels and RNDIS `192.168.42.2/24` were present. DJI
`dji_network` was running; no active hostapd or supplicant was found.
Kernel logs showed DJI unloaded the PCIe Wi-Fi device about six seconds after
boot. The Wi-Fi module `aic8800m80x2p_fdrv` remained loaded. The old
`start_wifi.sh` hardcodes another product's nonexistent PCIe path and starts
an AP; it was inspected, not executed. The actual writable device control is:

```sh
echo load > /sys/devices/platform/soc/c080000.apb/c448000.pcie/status
```

This restored wlan0 and wlan1 without disturbing USB ADB. Live wlan0 MAC was
`88:22:33:77:33:99`, different from the prior DUML MAC `9c:5a:8a:97:4f:b5`.
This report records the observed active interface MAC, not an assumed factory
identity. The driver appears to use a default MAC on this manual load; factory
MAC initialization was not reproduced or changed.

The actual working station commands were:

```sh
ip link set wlan0 up
# Config: hex UTF-8 SSID, PBKDF2-derived WPA2 PSK, country=CN, scan_ssid=1
# ctrl_interface=/data/misc/wifi/sockets
chown wifi:wifi /data/misc/wifi/pocket_sta.conf
chmod 600 /data/misc/wifi/pocket_sta.conf
restorecon /data/misc/wifi/pocket_sta.conf
wpa_supplicant -B -i wlan0 -c /data/misc/wifi/pocket_sta.conf -D nl80211
wpa_cli -p /data/misc/wifi/sockets -i wlan0 scan
busybox udhcpc -i wlan0 -s /system/bin/udhcpc.conf.sh -n -q -t 5
```

Supplicant is v2.11-9 and drops to uid wifi. A root-owned mode-0600 config
fails with Permission denied even under `/data/misc/wifi`; wifi ownership
resolved this without weakening SELinux. `-f` is unsupported; supplicant logs
go to Android logcat. The BusyBox executable is `/sbin/busybox` v1.26.2;
`udhcpc`, `nc`, `httpd`, `nohup` and `wget` are applets, not standalone binaries.
This wget lacks POST support, so the agent sends HTTP POST through BusyBox nc.

Live `wpa_cli status` confirmed `mode=station`, `wpa_state=COMPLETED`,
SSID `你的名字`, BSSID `b4:72:d4:65:ee:14`, 5220 MHz, WPA2-PSK/CCMP.
DHCP returned **192.168.5.93/24**, lease 86400 seconds; `ip addr show wlan0`
confirmed it. Vendor DHCP hook emits `ifconfig: bad address '+'`, missing
`route`, and unsupported resolver-default warnings, but the address was set.
Camera `ping -c 3 192.168.5.84`: 3/3 replies, 0% loss. Mac
`ping -c 3 192.168.5.93`: 3/3 replies, 0% loss, 5.250–7.301 ms.
This proves LAN traffic during this interval, not ongoing availability.

Agent script and `agent.env` were pushed to writable persistent
`/data/pocket-coffee/`; supplicant credentials are stored separately under
`/data/misc/wifi/pocket_sta.conf` with mode 0600. `adb tcpip 5555` was attempted
but did not yield a confirmed successful restart; USB and LAN subsequently
disappeared. No causal relationship between TCP request and disconnect was
established. No wireless ADB success is claimed at this stage. The device
needs to return online for agent execution and end-to-end heartbeat checks.

Persistence boundary: `/data` survives process restarts as a disk-backed
filesystem; reboot survival has not been tested. The inspected boot path is
`start_dji_system.sh` -> product/platform config functions. Product debug
startup invokes `/system/bin/debug.sh`, but that file does not exist and
`/system` is read-only. No writable automatic boot hook was established, no
system remount or init/firmware modification was made, and no automatic
cold-boot or sleep/wake guarantee is claimed. The agent retries interface
loading, association and DHCP while its process is alive. Restart manually:

```sh
adb -s 123456789ABCDEF shell 'busybox nohup /system/bin/sh /data/pocket-coffee/pocket_sta_agent.sh </dev/null >/data/pocket-coffee/console.log 2>&1 &'
```

Server routes now accept POST `/api/camera/heartbeat` and GET
`/api/camera/sta`. Receiver validates device, IPv4 subnet, MAC, and STA mode;
only a matching LAN source verifies the reported STA address. The server
supplies the heartbeat time, never accepts a client-provided timestamp as
proof, and never infers boot persistence from a heartbeat. Status omits Wi-Fi
password. A host-origin unit-test POST is explicitly not live hardware proof.
Default camera telemetry and synthetic command logs were removed; Pocket3
has not been tested and its prior example state is now marked unobserved.
Media HTTP, shutter control, RTSP and video completion webhooks are not yet
verified by this session.

Repository validation after implementation: `make test` passed all **17**
tests, including HTTP ingestion, invalid payload rejection, LAN-source
verification boundaries and unobserved-camera defaults. `sh -n` on the
exported agent and `git diff --check` passed. Server restarted on port 8788;
GET `/api/camera/sta` returned HTTP 200. The final revised agent has not been
pushed or executed after the camera disconnected; the earlier pushed copy
must be replaced on reconnection. Its media server startup and DHCP lease
renewal remain implementation behavior awaiting live validation.


## 2026-11-18 reconnect attempt: transport unavailable

The user confirmed the camera was powered on. This attempt could not establish
any camera shell; powered-on status alone did not establish a USB data connection.
Raw, timestamped command results and the receiver response are recorded in
`reports/sta-reconnect-20261118.json`.

- `adb devices -l` returned an empty list. `ioreg -p IOUSB -l` had no
  Osmo/2ca3/eagle4 match; the full USB tree showed only the AU05 device beneath
  the host controllers, with no camera.
- Both requested `adb connect 192.168.5.93:5555` and
  `adb connect 192.168.42.2:5555` initially completed with `Operation timed out`.
  Independent socket probes found LAN ports 5555/8088/23 unreachable and all
  three RNDIS ports timed out. A bounded repeat after host server restart is
  included in the raw evidence (six-second client timeout).
- Restarting only the Mac ADB server (`adb kill-server`, `adb start-server`)
  succeeded, but `adb devices -l` remained empty. No `adb tcpip`, camera-side
  service restart, USB mode change, reboot, remount or firmware write was run.
  A wedged host ADB server therefore does not explain the continuing absence;
  the cause of the earlier camera disconnect remains unknown.
- The Mac still has `192.168.5.84` on en0. Its ARP table contained the earlier
  `192.168.5.93` / `88:22:33:77:33:99` association, but three pings received
  zero replies. A cached ARP entry is not live camera proof.
- No RNDIS interface is active on the Mac. `route -n get 192.168.42.2` resolves
  through gateway `192.168.5.1` on en0, so this is not a working direct RNDIS
  path. The failed TCP probe does not establish camera-side listener state.
- `curl --noproxy '*' --connect-timeout 3 --max-time 5 -I
  http://192.168.5.93:8088/DJI_001/` failed with curl exit 28 after roughly
  three seconds; the recorded repeat failed with curl exit 7 (connection failed).
  Media HTTP was **not verified**; these results cannot distinguish
  an unavailable camera from an unavailable httpd process.
- The existing receiver process listens on `*:8788`; local GET
  `/api/camera/sta` returns HTTP 200. It still reports an empty
  `last_heartbeat`. No synthetic POST was sent. There is **no live camera-to-Mac
  heartbeat proof**, and no `online` state is claimed.

Because no shell was available, the latest agent could not be pushed, chmodded
or started; wlan0, supplicant, DHCP, init files and mounts could not be inspected
again. Prior-session filesystem and boot-hook observations above remain
historical evidence. Automatic boot persistence is neither configured nor tested.
The config now marks transport verification blocked, clears current
`verified_sta_ip`, and retains `last_observed_sta_ip: 192.168.5.93` as historical
context. A cable reseat and awake camera were requested; live deployment remains
pending a restored data transport.

Validation in this attempt: `make test` passed all 17 tests; exported-agent
`sh -n` and `git diff --check` returned success. These checks validate repository
behavior only and do not substitute for live hardware verification.


## 2026-11-18 USB restored: live STA deployment verified

This section supersedes the earlier blocked transport observation for this run.
Raw host-timestamped commands and complete output: `reports/sta-live-usb-restored-20261118.json`.
No host ADB server restart, adbd restart, TCP ADB activation, USB configuration
change, reboot, remount, firmware write or init modification was performed.

USB serial `123456789ABCDEF` remained `device`; `adb shell id` returned
`uid=0(root)` with `u:r:su:s0`. Pushed latest `data/pocket_sta_agent.sh` to
`/data/pocket-coffee/pocket_sta_agent.sh`, chmod 755, and started with:

```sh
adb shell 'busybox nohup /system/bin/sh /data/pocket-coffee/pocket_sta_agent.sh </dev/null >/data/pocket-coffee/console.log 2>&1 &'
```

Local and camera SHA256 matched: `1de38c6d19fc0710cf46f7d523af08874939fa00ff2bec745cc9b16923c30b87`.
Agent PID 5206, httpd PID 5214; DHCP and supplicant were observed running.
A named kernel wake lock `pocket_coffee_verification` was acquired and read
back alongside `SysMode`; it is left active for the live session. This is
not proof against application-level auto-power-off or sleep/wake recovery.

`wlan0` already existed on entry, so the script did not need its PCIe `load`
branch this run. The configured PCIe status node is write-only (`--w-------`);
reading it returned Permission denied. No claim of a new PCIe load is made.
The agent brought up association with `wpa_state=COMPLETED`, `mode=station`,
SSID `你的名字` (escaped UTF-8 in wpa_cli), BSSID `b4:72:d4:65:ee:14`,
5220 MHz, WPA2-PSK/CCMP, MAC `88:22:33:77:33:99`, IPv4 `192.168.5.93/24`.
DHCP obtained a fresh 86400-second lease. The vendor hook still emits
`ifconfig: bad address '+'`, `route: not found` and resolver warnings, but
LAN heartbeat and media traffic succeeded. No vendor script was changed.

### Actual heartbeat evidence

The background agent log shows repeated `heartbeat accepted` entries.
For the full response below, an additional POST using the same HTTP/nc
protocol and observed device fields was executed **inside the camera shell**,
connecting over Wi-Fi to `192.168.5.84:8788`. No Mac-origin synthetic POST
was used. Server response verified the matching source IP.
Camera wall clock is January 2000; receiver timestamps below are host supplied.

```http
HTTP/1.0 200 OK
Server: SimpleHTTP/0.6 Python/3.9.6
Date: Tue, 17 Nov 2026 16:27:01 GMT
Content-Type: application/json; charset=utf-8
Content-Length: 113
Access-Control-Allow-Origin: *
Access-Control-Allow-Methods: GET, POST, OPTIONS
Access-Control-Allow-Headers: Content-Type

{"ok": true, "device_id": "pocket4p", "last_heartbeat": "2026-11-18T00:27:01.173066+08:00", "sta_verified": true}
```

Agent/status/log evidence (includes historical earlier failed log entries):

```text
bssid=b4:72:d4:65:ee:14
freq=5220
ssid=\xe4\xbd\xa0\xe7\x9a\x84\xe5\x90\x8d\xe5\xad\x97
id=0
mode=station
wifi_generation=6
pairwise_cipher=CCMP
group_cipher=CCMP
key_mgmt=WPA2-PSK
wpa_state=COMPLETED
ip_address=192.168.5.93
p2p_device_address=88:22:33:77:33:9b
address=88:22:33:77:33:99
uuid=1c625e2a-4f8e-506a-9cfe-9f2e21787677
ieee80211ac=1
bss_max_idle_period=300
10: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP group default qlen 1000
    inet 192.168.5.93/24 brd 192.168.5.255 scope global wlan0
       valid_lft forever preferred_lft forever
-rwxr-xr-x 1 root root 3589 2026-11-18 00:20 /data/pocket-coffee/pocket_sta_agent.sh
1de38c6d19fc0710cf46f7d523af08874939fa00ff2bec745cc9b16923c30b87  /data/pocket-coffee/pocket_sta_agent.sh
5206
SysMode pocket_coffee_verification
WARNING: linker: Warning: "/system/lib64/libclang_rt.ubsan_standalone-aarch64-android.so" unused DT entry: unknown processor-specific (type 0x70000001 arg 0x0) (ignoring)
WARNING: linker: Warning: "/system/lib64/libclang_rt.ubsan_standalone-aarch64-android.so" unused DT entry: unknown processor-specific (type 0x70000001 arg 0x0) (ignoring)
WARNING: linker: Warning: "/system/lib64/libclang_rt.ubsan_standalone-aarch64-android.so" unused DT entry: unknown processor-specific (type 0x70000001 arg 0x0) (ignoring)
WARNING: linker: Warning: "/system/lib64/libclang_rt.ubsan_standalone-aarch64-android.so" unused DT entry: unknown processor-specific (type 0x70000001 arg 0x0) (ignoring)
udhcpc: started, v1.26.2
start script
udhcpc: sending discover
udhcpc: sending select for 192.168.5.93
udhcpc: lease of 192.168.5.93 obtained, lease time 86400
start script
start script
ifconfig: bad address '+' : No address associated with hostname
deleting routers
/system/bin/udhcpc.conf.sh[37]: route: not found
interface:wlan0
domain:domain
dns:192.168.5.1
200 0 Resolver command succeeded
500 0 Resolver unknown command
Mon Jan  3 22:16:14 CST 2000 heartbeat accepted ip=192.168.5.93 mac=88:22:33:77:33:99
Mon Jan  3 22:16:19 CST 2000 heartbeat accepted ip=192.168.5.93 mac=88:22:33:77:33:99
Mon Jan  3 22:16:24 CST 2000 heartbeat accepted ip=192.168.5.93 mac=88:22:33:77:33:99
Mon Jan  3 22:16:30 CST 2000 heartbeat accepted ip=192.168.5.93 mac=88:22:33:77:33:99
Mon Jan  3 22:16:35 CST 2000 heartbeat accepted ip=192.168.5.93 mac=88:22:33:77:33:99
Mon Jan  3 22:16:40 CST 2000 heartbeat accepted ip=192.168.5.93 mac=88:22:33:77:33:99
Mon Jan  3 22:16:45 CST 2000 heartbeat accepted ip=192.168.5.93 mac=88:22:33:77:33:99
Mon Jan  3 22:16:51 CST 2000 heartbeat accepted ip=192.168.5.93 mac=88:22:33:77:33:99
Mon Jan  3 22:16:56 CST 2000 heartbeat accepted ip=192.168.5.93 mac=88:22:33:77:33:99
Mon Jan  3 22:17:01 CST 2000 heartbeat accepted ip=192.168.5.93 mac=88:22:33:77:33:99
Mon Jan  3 22:17:06 CST 2000 heartbeat accepted ip=192.168.5.93 mac=88:22:33:77:33:99
Mon Jan  3 22:17:12 CST 2000 heartbeat accepted ip=192.168.5.93 mac=88:22:33:77:33:99
Mon Jan  3 22:17:17 CST 2000 heartbeat accepted ip=192.168.5.93 mac=88:22:33:77:33:99
Mon Jan  3 22:17:22 CST 2000 heartbeat accepted ip=192.168.5.93 mac=88:22:33:77:33:99
Mon Jan  3 22:17:27 CST 2000 heartbeat accepted ip=192.168.5.93 mac=88:22:33:77:33:99
Mon Jan  3 22:17:33 CST 2000 heartbeat accepted ip=192.168.5.93 mac=88:22:33:77:33:99

```

GET `http://127.0.0.1:8788/api/camera/sta` after metadata update:

```json
{
  "ok": true,
  "sta_network": {
    "ssid": "你的名字",
    "subnet": "192.168.5.0/24",
    "mac_server_ip": "192.168.5.84",
    "mac_server_port": 8788,
    "keepalive_interval_s": 5,
    "prevent_sleep_in_sta": true
  },
  "cameras": {
    "pocket4p": {
      "device_id": "pocket4p",
      "model": "DJI Osmo Pocket 4 Pro",
      "wifi_mode": "STA",
      "lan_ip": "192.168.5.93",
      "ssid": "你的名字",
      "mac_address": "88:22:33:77:33:99",
      "adb_port": 5555,
      "http_media_port": 8088,
      "duml_udp_port": 9004,
      "rtsp_url": "",
      "internal_daemon_installed": true,
      "internal_daemon_version": "v3-hg224",
      "recording_state": "unknown",
      "battery_percent": null,
      "sd_free_gb": null,
      "last_heartbeat": "2026-11-18T00:28:08.184639+08:00",
      "capabilities": [],
      "adb_serial": "123456789ABCDEF",
      "verification": {
        "checked_at": "2026-11-18T00:28:08.184639+08:00",
        "status": "live_sta_heartbeat",
        "usb_product": "OsmoPocket4P-ANHXP5J0022DTW",
        "adb_serial": "123456789ABCDEF",
        "adb_state": "device",
        "sta_connection_verified": true,
        "agent_installation_verified": true,
        "persistence_verified": false,
        "heartbeat_verified": true,
        "verified_sta_ip": "192.168.5.93",
        "mac_address_source": "Agent wlan0 sysfs observation",
        "evidence": [
          "reports/usb-adb-investigation.md",
          "reports/sta-live-usb-restored-20261118.json"
        ],
        "note": "USB ADB restored. Latest agent deployed and SHA256 matched; live agent heartbeats accepted from 192.168.5.93. Mac HTTP HEAD and full media GET succeeded (server ignored the requested Range header). Online is a live observation, not a boot or sleep/wake guarantee. No verified writable boot hook found in inspected init/platform/product scripts; automatic startup not installed; no reboot tested.",
        "last_observed_sta_ip": "192.168.5.93",
        "heartbeat_source_ip": "192.168.5.93",
        "persistence_status": "not_installed_no_verified_writable_boot_hook",
        "media_http_verified": true,
        "media_http_url": "http://192.168.5.93:8088/DJI_001/DJI_20000103215101_0036_D.MP4",
        "wake_lock": "pocket_coffee_verification",
        "persistence_details": {
          "system_mount": "read-only ext4",
          "vendor_mount": "read-only ext4",
          "data_mount": "read-write ext4",
          "blackbox_mount": "read-write ext4",
          "boot_chain": "/init.rc -> /system/etc/init/init.eagle4.rc service start_dji_system -> /system/bin/start_dji_system.sh -> dji_eagle4_platform_config.sh + product_config.sh (+ sec_func_ctrl.sh)",
          "candidate_hook": "product_debug_late_config executes /system/bin/debug.sh, but file absent and /system read-only",
          "writable_boot_hook_found": false,
          "automatic_startup_installed": false,
          "reboot_tested": false,
          "inspection_scope": "/init*.rc, /system/etc/init/*.rc, platform/product/sec_func_ctrl scripts, /system/bin/*.sh path-reference search; /vendor rc/sh search maxdepth 4; /data and /blackbox sh inventory maxdepth 3"
        }
      },
      "status": "online",
      "status_observed_at": "2026-11-18T00:28:08.184639+08:00"
    },
    "pocket3": {
      "device_id": "pocket3",
      "model": "DJI Osmo Pocket 3",
      "wifi_mode": "unknown",
      "lan_ip": "",
      "ssid": "你的名字",
      "mac_address": "",
      "adb_port": 5555,
      "http_media_port": 8088,
      "duml_udp_port": 9004,
      "rtsp_url": "",
      "internal_daemon_installed": false,
      "internal_daemon_version": "",
      "recording_state": "unknown",
      "battery_percent": null,
      "sd_free_gb": null,
      "last_heartbeat": "",
      "capabilities": [],
      "verification": {
        "status": "not_tested",
        "sta_connection_verified": false,
        "heartbeat_verified": false,
        "persistence_verified": false
      }
    }
  }
}
```

`status: online` and `status_observed_at` record this successful live check;
`verification.status: live_sta_heartbeat` is maintained by the receiver.
`last_heartbeat`, matching `heartbeat_source_ip`, and `verified_sta_ip` come
from actual receipt. These observations do not promise future availability.
Pocket3 remains untested.

### Media HTTP over Wi-Fi

BusyBox httpd runs with `-p 8088 -h /mnt/media_rw/emulated/DCIM`.
HEAD `/DJI_001/` returns 404 (directory index absent); that response proves
HTTP reachability but does not alone prove media reads. HEAD on the existing
`/DJI_001/DJI_20000103215101_0036_D.MP4` returned:

```http
HTTP/1.0 200 OK
Content-type: application/octet-stream
Date: Mon, 03 Jan 2000 14:17:34 GMT
Connection: close
Accept-Ranges: bytes
Last-Modified: Mon, 03 Jan 2000 13:51:03 GMT
Content-length: 3449916


```

A Mac GET requesting `Range: bytes=0-31` succeeded, but this server ignored
the Range header and returned the full 3449916-byte file;
first bytes (hex): `0000001c6674797069736f6d0000020069736f6d69736f326d70343100000008`.
No media files were changed. No optional telnet server was needed or started.

### Persistence: inspected, not installed or reboot verified

Read-only inspection found `/init.rc` starts `start_dji_system`; its service
definition is `/system/etc/init/init.eagle4.rc:48`, invoking
`/system/bin/start_dji_system.sh`. That script sources platform and product
configuration; product also sources `sec_func_ctrl.sh`. Boot functions run
fs/module/service/misc/debug setup. `product_debug_late_config` invokes
`/system/bin/debug.sh &`, but that file is absent. `/system` and `/vendor`
are read-only ext4, while `/data` and `/blackbox` are writable ext4.
The observed `/data` and `/blackbox` paths in inspected boot scripts are
configuration flags, log paths and data files, not a verified writable shell
autostart hook. The bounded script inventory found only our agent under
those writable locations. Vendor rc/sh search was bounded to depth 4,
/data and /blackbox shell inventory to depth 3; native binary behavior and
uninspected deeper paths are not ruled out. One initially guessed service
filename was absent; the actual definition was then located as above.

No safe writable boot entry was verified or installed. `persistence_verified`
remains false; `automatic_startup_installed` and `reboot_tested` remain false.
Disk-backed storage and retries while the process runs do not establish boot
autostart. Restart manually using the command above after process loss.

Validation for this live run: `make test` passed all 17 tests;
`sh -n data/pocket_sta_agent.sh` and `git diff --check` succeeded.
No implementation behavior was changed; configuration and evidence were updated.
The running receiver continues updating the runtime heartbeat config after this snapshot.

## 2026-11-18 Live telemetry and automatic MP4 watcher

Implemented and deployed `v4-hg224-media` within the implementation agent's
assigned files. USB ADB serial `123456789ABCDEF` remained `device` before and
after deployment. No adbd restart, TCP ADB enablement, USB configuration change,
reboot, or firmware modification was performed. No recording command was sent
during this verification.

The exported script and Python `ON_CAMERA_AGENT_SCRIPT` are identical. Local
and camera SHA256:
`69844a2ec24f5082ae384b088f9940d056c74167557ed3749ecd76123fd0c9ea`.
Pushed to `/data/pocket-coffee/pocket_sta_agent.sh`, validated with the camera's
`/system/bin/sh -n`, and set mode 755. Read old PID 5206 from `agent.pid`, checked
its `/proc/5206/cmdline`, sent TERM, and waited for its exit. Started the updated
script using `/sbin/busybox nohup /system/bin/sh`; new PID was 7949. The existing
httpd remained available on port 8088; the agent's additional httpd launch logged
`Address already in use`, with no effect on the existing media service.
The watcher initialized `last_mp4.txt` to `DJI_20260813111516_0034_D.MP4`, so old
files were not emitted as new webhook events.

The camera's `busybox df -k /mnt/media_rw/emulated` wraps its device-name line:

```text
Filesystem           1K-blocks      Used Available Use% Mounted on
/dev/block/by-name/media
                     109242368   3108352 106134016   3% /mnt/media_rw/emulated
```

The agent reads Available relative to the trailing columns, obtaining
106134016 KiB / 1048576 = **101.217 GiB** (the API field is named `sd_free_gb`).
Agent logs showed repeated accepted real heartbeats with this value and the
latest filename. The existing receiver had imported the old bridge class;
restarted only the Mac Python receiver (old PID 78800, new PID 84574) to load the
updated telemetry handler, without editing `server/app.py`. No synthetic
heartbeat POST was used. A GET to `http://192.168.5.84:8788/api/camera/sta`
returned this camera-origin observation:

```json
{
  "internal_daemon_version": "v4-hg224-media",
  "sd_free_gb": 101.217,
  "latest_media_file": "DJI_20260813111516_0034_D.MP4",
  "latest_media_url": "http://192.168.5.93:8088/DJI_001/DJI_20260813111516_0034_D.MP4",
  "last_heartbeat": "2026-11-18T00:37:24.983917+08:00",
  "heartbeat_source_ip": "192.168.5.93",
  "heartbeat_verified": true
}
```

The final two fields above are projected from `verification`. The camera's
clock is incorrect (agent log dates are January 2000); receiver timestamps are
host observations. "Latest" uses file modification ordering, so the newest
observed file is the August 2026 file, rather than the `_0036` file dated 2000
used in earlier HTTP tests.

`list_remote_media("pocket4p")` was tested against the live configuration and
camera. Since this BusyBox HTTP server has no directory index, listing fell
back to confirmed USB ADB and `busybox ls -lnt .../DJI_001/*.MP4`. It returned
17 real MP4 files, newest first. First entry:

```json
{
  "name": "DJI_20260813111516_0034_D.MP4",
  "size_bytes": 3181520,
  "url": "http://192.168.5.93:8088/DJI_001/DJI_20260813111516_0034_D.MP4"
}
```

`pull_latest_media("pocket4p", dest_dir=<temporary directory>, max_bytes=4096)`
then downloaded and verified exactly 4096 bytes over Wi-Fi from that URL,
returning `ok: true`, `partial: true`, and an existing local
`DJI_20260813111516_0034_D.preview-4096.MP4`. Temporary verification files were
cleaned up. A bounded preview uses a separate filename and stops reading at the
limit even when the camera ignores Range. Full downloads are checked against
the listed size and atomically installed in `data/media_cache/` by default.

The agent now posts `/api/camera/webhook` only after a changed newest MP4 has
positive size and identical size across two checks; it retries unsuccessful
POSTs and updates `last_mp4.txt` only after an HTTP 2xx response. Its payload
contains device ID, camera model, STA IP, full file path and Wi-Fi media URL.
A shell behavior test exercised a growing file (100, 200, 300 bytes), stable
size, and repeated checks: exactly one notification was emitted after stability.
This test uses controlled shell inputs, not a new live recording; live creation
and end-to-end webhook processing remain unverified in this run.

Shutter requests now preserve real ADB enumeration status separately from DUML
transport dispatch, and leave `recording_state` unknown pending camera evidence.
An online USB transport alone does not prove the camera is recording.

Validation: `python3 -m unittest tests/test_camera_sta_bridge.py -v` passed all
9 tests; full discovery passed all 26 tests. Exported script `sh -n` and
`git diff --check` passed. No git commit was created. Boot persistence remains
uninstalled and unverified, as documented above.

## 2026-11-18 Morning USB recovery and gimbal presets

At about 11:00 CST, `adb devices -l` showed USB serial `123456789ABCDEF`
as `device` (`eagle4_hg224`). The Mac STA endpoint reported a last heartbeat
at 01:22:58 CST. The installed agent's PID file still contained `7949`, but
`/proc/7949` and the agent process were absent. The camera retained
`192.168.5.93` on `wlan0`, which was down with no carrier.

Started the existing agent over the explicitly selected USB transport:

```sh
adb -s 123456789ABCDEF shell 'busybox nohup /system/bin/sh /data/pocket-coffee/pocket_sta_agent.sh </dev/null >/data/pocket-coffee/console.log 2>&1 &'
```

PID `21603` ran the installed `v4-hg224-media` script. The supplicant reached
`COMPLETED`, DHCP obtained `192.168.5.93`, and the receiver recorded a fresh
heartbeat at 11:00:28 CST. At 11:04:26 CST the receiver still reported verified
heartbeats from that IP, and USB ADB still enumerated as `device`.

The Mac bridge now checks Pocket 4 Pro USB ADB before attempting legacy STA
provisioning. When invoked, it starts an installed agent if the PID file does
not point to the expected script, and checks for that process after launch.
With the live agent running, this path returned `already_running` and left
PID `21603` in place. The launch branch and stale or reused PID handling were
also exercised with local shell fixtures. The existing USB probe invokes this
method; it does not itself monitor reconnects or install on-camera boot
persistence. No reboot or USB configuration change was made.

`/sys/class/power_supply/` was empty, and `dumpsys battery` reported
`Can't find service: battery`. No recording state source was verified. The
live endpoint reported `battery_percent: null` and
`recording_state: "unknown"`. The checked-in `v5-hg224-telemetry` script
reads a valid sysfs Battery capacity if available and sends JSON `null`
otherwise. The receiver accepts a battery reading or optional recording
observation from a matching STA peer. The new script passed shell syntax
checks locally and on the camera; the live camera still runs the existing
`v4-hg224-media` script.

The five brewing presets use DUML `04:14`, including the zero-angle center
preset. The bridge tries USB interface 4 / endpoint `0x04` and UDP port
`9004` independently, and logs completed USB writes and local UDP sends
separately from camera movement. Packet encoding and dispatch were verified
in unit tests. No live gimbal or recording command was sent.

Validation: `python3 -m unittest tests/test_camera_sta_bridge.py -v` passed
all 17 tests. The checked-in and embedded scripts match, and
`git diff --check` passed. No git commit was created.
