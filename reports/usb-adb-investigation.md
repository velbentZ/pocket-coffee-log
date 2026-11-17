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
