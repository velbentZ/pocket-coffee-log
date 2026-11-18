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
OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
case "$OLD_PID" in
    ''|*[!0-9]*) ;;
    *) if [ -r "/proc/$OLD_PID/cmdline" ] &&
           "$BB" tr '\000' '\n' < "/proc/$OLD_PID/cmdline" | "$BB" grep -Fxq "$0"; then exit 0; fi ;;
esac
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

json_escape() { printf '%s' "$1" | "$BB" sed 's/\\/\\\\/g; s/"/\\"/g'; }
newest_mp4() { "$BB" ls -1t "$DCIM_DIR"/DJI_001/*.MP4 2>/dev/null | "$BB" head -n 1; }
battery_capacity() {
    for SUPPLY in "${POWER_SUPPLY_DIR:-/sys/class/power_supply}"/*; do
        [ -r "$SUPPLY/type" ] && [ -r "$SUPPLY/capacity" ] || continue
        [ "$(cat "$SUPPLY/type")" = Battery ] || continue
        CAPACITY=$("$BB" awk 'NR == 1 && /^[0-9]+$/ && $0 <= 100 {printf "%d", $0}' "$SUPPLY/capacity" 2>/dev/null)
        if [ -n "$CAPACITY" ]; then printf '%s' "$CAPACITY"; return; fi
    done
    printf 'null'
}
post_json() {
    POST_PATH="$1"
    POST_BODY="$2"
    RESPONSE=$({ printf 'POST %s HTTP/1.0\r\nHost: %s:%s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "$POST_PATH" "$SERVER_IP" "$SERVER_PORT" "${#POST_BODY}" "$POST_BODY"; } | "$BB" nc -w 5 "$SERVER_IP" "$SERVER_PORT")
    printf '%s\n' "$RESPONSE" | "$BB" head -n 1 | "$BB" grep -q ' 2[0-9][0-9] '
}

heartbeat() {
    MAC=$(cat /sys/class/net/wlan0/address)
    BATTERY_PERCENT=$(battery_capacity)
    SD_FREE_GB=$("$BB" df -k /mnt/media_rw/emulated 2>/dev/null | "$BB" awk '/%/ && $(NF-2) ~ /^[0-9]+$/ {printf "%.3f", $(NF-2)/1048576; exit}')
    SD_FREE_GB="${SD_FREE_GB:-null}"
    LATEST_MP4=$(newest_mp4)
    LATEST_MEDIA_FILE="${LATEST_MP4##*/}"
    LATEST_MEDIA_URL=""
    [ -n "$LATEST_MEDIA_FILE" ] && LATEST_MEDIA_URL="http://$CURRENT_IP:8088/DJI_001/$LATEST_MEDIA_FILE"
    BODY="{\"device_id\":\"$(json_escape "$DEVICE_ID")\",\"ip\":\"$CURRENT_IP\",\"mac_address\":\"$MAC\",\"ssid\":\"$(json_escape "$WIFI_SSID")\",\"wifi_mode\":\"STA\",\"agent_version\":\"v5-hg224-telemetry\",\"battery_percent\":$BATTERY_PERCENT,\"sd_free_gb\":$SD_FREE_GB,\"latest_media_file\":\"$(json_escape "$LATEST_MEDIA_FILE")\",\"latest_media_url\":\"$(json_escape "$LATEST_MEDIA_URL")\"}"
    if post_json /api/camera/heartbeat "$BODY"; then
        log "heartbeat accepted ip=$CURRENT_IP battery_percent=$BATTERY_PERCENT sd_free_gb=$SD_FREE_GB latest_media_file=$LATEST_MEDIA_FILE"
    else
        log "heartbeat failed: $RESPONSE"
    fi
}

watch_mp4() {
    NEW_MP4=$(newest_mp4)
    [ -n "$NEW_MP4" ] || return
    NEW_MP4_BASENAME="${NEW_MP4##*/}"
    LAST_MP4=$(cat "$BASE_DIR/last_mp4.txt" 2>/dev/null)
    [ "$NEW_MP4_BASENAME" != "$LAST_MP4" ] || return
    NEW_SIZE=$("$BB" stat -c %s "$NEW_MP4" 2>/dev/null)
    [ -n "$NEW_SIZE" ] && [ "$NEW_SIZE" -gt 0 ] || return
    if [ "$PENDING_MP4" = "$NEW_MP4" ] && [ "$PENDING_SIZE" = "$NEW_SIZE" ]; then
        BODY="{\"device_id\":\"$(json_escape "$DEVICE_ID")\",\"camera\":\"DJI Osmo Pocket 4 Pro\",\"ip\":\"$CURRENT_IP\",\"file_path\":\"$(json_escape "$NEW_MP4")\",\"media_url\":\"http://$CURRENT_IP:8088/DJI_001/$(json_escape "$NEW_MP4_BASENAME")\"}"
        if post_json /api/camera/webhook "$BODY"; then
            printf '%s\n' "$NEW_MP4_BASENAME" > "$BASE_DIR/last_mp4.txt"
            log "media webhook accepted file=$NEW_MP4_BASENAME size=$NEW_SIZE"
        else
            log "media webhook failed file=$NEW_MP4_BASENAME: $RESPONSE"
        fi
    fi
    PENDING_MP4="$NEW_MP4"
    PENDING_SIZE="$NEW_SIZE"
}

log 'Starting STA agent; boot auto-start is not installed by this script'
# Keep USB ADB untouched; this agent never restarts or reconfigures adbd.
INITIAL_MP4=$(newest_mp4)
printf '%s\n' "${INITIAL_MP4##*/}" > "$BASE_DIR/last_mp4.txt"
PENDING_MP4=""
PENDING_SIZE=""
# The media server is optional; it only exposes the verified DCIM directory.
if [ -d "$DCIM_DIR" ]; then
    "$BB" httpd -p 8088 -h "$DCIM_DIR" 2>> "$BASE_DIR/agent.log"
fi
while true; do
    if ensure_sta; then heartbeat; watch_mp4; fi
    [ "${RUN_ONCE:-0}" = 1 ] && break
    sleep 5
done
