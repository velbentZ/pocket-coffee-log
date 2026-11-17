# Hardware investigation — 2026-11-17

Confirmed 2ca3:0020 product OsmoPocket4P-ANHXP5J0022DTW. Vendor interfaces remain subclass 0x43; no standard USB ADB interface observed.

Both mass-storage interfaces (2 and 8) refused claims with libusb access denied. No camera disk appeared in diskutil external inventory; SCSI contents remain uninspected. Vendor interfaces were claimable. No processes were killed or kernel drivers detached.

Interface 4 accepted requests targeting Wi-Fi (7,0), system (8,0)/(8,2), and camera (1,0). Captured raw reads include asynchronous frames and are NOT correlated acknowledgments. No USB mode switch or STA association was verified. Unknown setters were not brute-forced. Cmd 07:47 remains an unverified hypothesis, not an established provisioning protocol.

TCP checks on 192.168.42.2 and 192.168.2.1 ports 21,23,80,5555,9004,8088,554 all timed out in this run. UDP service availability and RNDIS routing were not established. Previously reported FTP availability was not reproduced.

Raw observations: usb-investigation.json. Reproduction: run python3 daemon/investigate_usb.py from project root. This is a bounded preliminary probe, not a complete protocol investigation. Further work requires correlated DUML framing and an authoritative HG224 command reference or Mimo traffic capture. ADB enablement and target Wi-Fi joining remain unresolved.

Tests now mock USB/network provisioning and explicitly verify honest unconfirmed results and failure without ADB; no emulated shell is presented as live evidence.
