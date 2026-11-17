#!/system/bin/sh
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
