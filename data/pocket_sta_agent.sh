#!/system/bin/sh
# Verified on eagle4_hg224. Install in /data/pocket-coffee; firmware is read-only.
# Android init kills the adbd cpuacct group when USB disconnects.
echo $$ 2>/dev/null > /acct/cgroup.procs || true
echo $$ 2>/dev/null > /dev/cpuctl/cgroup.procs || true
echo $$ 2>/dev/null > /dev/cg2_bpf/cgroup.procs || true
trap '' HUP
BASE_DIR="${BASE_DIR:-/data/pocket-coffee}"
[ -r "$BASE_DIR/agent.env" ] && . "$BASE_DIR/agent.env"
DEVICE_ID="${DEVICE_ID:-pocket4p}"
SERVER_IP="${SERVER_IP:-192.168.5.84}"
SERVER_PORT="${SERVER_PORT:-8788}"
WPA_CONF="${WPA_CONF:-/data/misc/wifi/pocket_sta.conf}"
CTRL_DIR="${CTRL_DIR:-/data/misc/wifi/sockets}"
DCIM_DIR="${DCIM_DIR:-/mnt/media_rw/emulated/DCIM}"
BB=/sbin/busybox
export PATH="/usr/bin:/bin:/sbin:/system/bin:/vendor/bin:$PATH"
umask 077
mkdir -p "$BASE_DIR"
PID_FILE="$BASE_DIR/agent.pid"
OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
case "$OLD_PID" in
    ''|*[!0-9]*) ;;
    *) if [ -r "/proc/$OLD_PID/cmdline" ] &&
           "$BB" tr '\000' '\n' < "/proc/$OLD_PID/cmdline" | "$BB" grep -Fxq "$0"; then exit 0; fi ;;
esac
echo $$ > "$PID_FILE"
VOICE_WAV_A=/tmp/pocket_coffee_voice_a_$$.wav
VOICE_WAV_B=/tmp/pocket_coffee_voice_b_$$.wav
CAPTURE_PID=
stop_agent() {
    if [ "${RUN_ONCE:-0}" != 1 ]; then
        echo pocket_coffee_sta 2>/dev/null > /sys/power/wake_unlock || true
    fi
    exit 0
}
cleanup_agent() {
    if [ -n "$CAPTURE_PID" ]; then
        kill "$CAPTURE_PID" 2>/dev/null
        wait "$CAPTURE_PID" 2>/dev/null
    fi
    rm -f "$PID_FILE" "$VOICE_WAV_A" "$VOICE_WAV_B"
}
trap stop_agent INT TERM
trap cleanup_agent EXIT
if [ "${RUN_ONCE:-0}" != 1 ]; then
    echo pocket_coffee_sta 2>/dev/null > /sys/power/wake_lock || true
fi
log() { echo "$(date) $*" >> "${AGENT_LOG:-/tmp/pocket_sta_agent.log}"; }

WPA_FAILS=0
ensure_sta() {
    # DJI powers down the PCIe Wi-Fi device while USB remains available.
    if [ ! -d /sys/class/net/wlan0 ]; then
        echo load > /sys/devices/platform/soc/c080000.apb/c448000.pcie/status || return 1
        sleep 2
    fi
    ip link set wlan0 up || return 1
    CURRENT_IP=$(ip -4 addr show wlan0 | "$BB" awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}')
    # An IPv4 lease can outlive the association and even the supplicant.
    LINK=$(ip link show wlan0)
    LINK_READY=0
    case "$LINK " in
        *NO-CARRIER*|*" state DOWN "*) ;;
        *LOWER_UP*) LINK_READY=1;;
    esac
    WPA_DIR=""
    WPA_COMPLETED=0
    WPA_SOCKET=0
    for SOCKET_DIR in /tmp/wpa_supplicant /data/misc/wifi/sockets "$CTRL_DIR"; do
        [ ! -S "$SOCKET_DIR/wlan0" ] || WPA_SOCKET=1
        STATUS=$("$BB" timeout -t 2 wpa_cli -p "$SOCKET_DIR" -i wlan0 status 2>/dev/null)
        case "$STATUS" in
            *wpa_state=COMPLETED*) WPA_DIR="$SOCKET_DIR"; WPA_COMPLETED=1; break;;
            *wpa_state=*) [ -n "$WPA_DIR" ] || WPA_DIR="$SOCKET_DIR";;
        esac
    done
    if [ "$LINK_READY" -eq 1 ]; then
        if [ "$WPA_COMPLETED" -eq 1 ]; then
            case "$CURRENT_IP" in "${STA_PREFIX:-${SERVER_IP%.*}.}"*) WPA_FAILS=0; return 0;; esac
        elif [ -z "$WPA_DIR" ] && [ "$WPA_SOCKET" -eq 0 ]; then
            case "$LINK " in
                *" state UP "*)
                    case "$CURRENT_IP" in "${STA_PREFIX:-${SERVER_IP%.*}.}"*) WPA_FAILS=0; return 0;; esac;;
            esac
        fi
    fi
    if [ "$WPA_COMPLETED" -ne 1 ] || [ "$LINK_READY" -ne 1 ]; then
        if [ -n "$WPA_DIR" ]; then
            NETWORKS=$("$BB" timeout -t 2 wpa_cli -p "$WPA_DIR" -i wlan0 list_networks 2>/dev/null)
            NETWORK_IDS=$(printf '%s\n' "$NETWORKS" | "$BB" awk -F '\t' '$1 ~ /^[0-9]+$/ {print $1}')
            HAS_NETWORK=0
            if [ -n "$WIFI_SSID" ] && printf '%s\n' "$NETWORKS" |
                POCKET_WIFI_SSID="$WIFI_SSID" "$BB" awk -F '\t' '
                    $1 ~ /^[0-9]+$/ && $2 == ENVIRON["POCKET_WIFI_SSID"] {found=1}
                    END {exit !found}
                '; then
                HAS_NETWORK=1
            elif [ -n "$NETWORK_IDS" ]; then
                # HG224 lists non-ASCII SSIDs as escaped bytes; its Pocket config
                # stores the same SSID in hex, as returned by get_network.
                CONF_SSID=$("$BB" awk -F= '/^[[:space:]]*ssid=[0-9a-fA-F]+[[:space:]]*$/ {
                    sub(/[[:space:]]+$/, "", $2); print tolower($2); exit
                }' "$WPA_CONF" 2>/dev/null)
                if [ -n "$CONF_SSID" ]; then
                    for NETWORK_ID in $NETWORK_IDS; do
                        NETWORK_SSID=$("$BB" timeout -t 2 wpa_cli -p "$WPA_DIR" -i wlan0 get_network "$NETWORK_ID" ssid 2>/dev/null)
                        if [ "$NETWORK_SSID" = "$CONF_SSID" ]; then
                            HAS_NETWORK=1
                            break
                        fi
                    done
                fi
            fi
            if [ "$HAS_NETWORK" -eq 1 ]; then
                if [ "$("$BB" timeout -t 2 wpa_cli -p "$WPA_DIR" -i wlan0 reassociate 2>/dev/null)" = OK ]; then
                    WPA_FAILS=0
                else
                    WPA_FAILS=$((WPA_FAILS + 1))
                fi
            else
                WPA_FAILS=2
            fi
        else
            WPA_FAILS=$((WPA_FAILS + 1))
        fi
        if [ "$WPA_FAILS" -ge 2 ]; then
            log "Restarting stale STA supplicant with the Pocket Wi-Fi config"
            "$BB" killall hostapd dnsmasq wpa_supplicant 2>/dev/null
            ip addr flush dev wlan0 2>/dev/null
            rm -rf /tmp/wpa_supplicant /data/misc/wifi/sockets
        elif [ -n "$WPA_DIR" ] || "$BB" pidof wpa_supplicant >/dev/null 2>&1; then
            return 1
        fi
        WPA_FAILS=0
        chown wifi:wifi "$WPA_CONF"
        chmod 600 "$WPA_CONF"
        restorecon "$WPA_CONF" 2>/dev/null
        wpa_supplicant -B -i wlan0 -c "$WPA_CONF" -D nl80211 >> "$BASE_DIR/agent.log" 2>&1
        return 1
    fi
    WPA_FAILS=0
    DHCP_PID="$BASE_DIR/udhcpc.pid"
    if ! [ -r "$DHCP_PID" ] || ! kill -0 "$(cat "$DHCP_PID")" 2>/dev/null; then
        "$BB" udhcpc -b -i wlan0 -p "$DHCP_PID" -s /system/bin/udhcpc.conf.sh -t 5 >> "$BASE_DIR/agent.log" 2>&1
    fi
    CURRENT_IP=$(ip -4 addr show wlan0 | "$BB" awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}')
    [ -n "$CURRENT_IP" ]
}

json_escape() { printf '%s' "$1" | "$BB" tr -d '\r\n' | "$BB" sed 's/\\/\\\\/g; s/"/\\"/g'; }
newest_mp4() {
    "$BB" ls -1t "$DCIM_DIR"/DJI_001/*.MP4 2>/dev/null |
        "$BB" awk '{
            name=$0; sub(/^.*\//, "", name); split(name, part, "_")
            # Some BusyBox awk builds parse leading zeroes as octal.
            seq=(name ~ /^DJI_[0-9]+_[0-9][0-9][0-9][0-9]_D\.MP4$/ ? ("1" part[3])-10000 : -1)
            if (NR == 1 || seq > highest) { highest=seq; newest=$0 }
        } END {if (NR) print newest}'
}
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
    RESPONSE=$({ printf 'POST %s HTTP/1.0\r\nHost: %s:%s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "$POST_PATH" "$SERVER_IP" "$SERVER_PORT" "${#POST_BODY}" "$POST_BODY"; } | "$BB" timeout -t "${3:-10}" "$BB" nc -w 5 "$SERVER_IP" "$SERVER_PORT")
    printf '%s\n' "$RESPONSE" | "$BB" head -n 1 | "$BB" grep -q ' 2[0-9][0-9] '
}

sync_clock() {
    SERVER_EPOCH=$(printf '%s' "$RESPONSE" | "$BB" sed -n 's/.*"server_epoch"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    case "$SERVER_EPOCH" in ''|*[!0-9]*) return;; esac
    NOW=$(date +%s)
    DELTA=$((SERVER_EPOCH - NOW))
    if [ "$DELTA" -gt 5 ] || [ "$DELTA" -lt -5 ]; then
        "$BB" date -s "@$SERVER_EPOCH" >/dev/null 2>&1 ||
            date -u "@$SERVER_EPOCH" >/dev/null 2>&1
    fi
}

ensure_adbd() {
    # Keep active USB ADB untouched; only restart adbd if it was stopped (e.g. after USB unplug sets sys.usb.config=none).
    if ! "$BB" pidof adbd >/dev/null 2>&1; then
        setprop service.adb.tcp.port 5555 2>/dev/null || true
        setprop persist.adb.tcp.port 5555 2>/dev/null || true
        start adbd 2>/dev/null || { /system/bin/adbd >/dev/null 2>&1 & }
        log "restarted stopped adbd on TCP 5555"
    fi
}

apply_pending_shutter() {
    case "$RESPONSE" in
        *'"pending_shutter":"start"'*|*'"pending_shutter": "start"'*)
            if dji_mb_ctrl -S test -R diag -g 1 -t 0 -s 2 -c 0x02 01 >> "$BASE_DIR/agent.log" 2>&1; then
                REC=true
                log "heartbeat pending_shutter: START dispatched"
            fi;;
        *'"pending_shutter":"stop"'*|*'"pending_shutter": "stop"'*)
            if dji_mb_ctrl -S test -R diag -g 1 -t 0 -s 2 -c 0x02 00 >> "$BASE_DIR/agent.log" 2>&1; then
                REC=false
                log "heartbeat pending_shutter: STOP dispatched"
            fi;;
    esac
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
    BODY="{\"device_id\":\"$(json_escape "$DEVICE_ID")\",\"ip\":\"$CURRENT_IP\",\"mac_address\":\"$MAC\",\"ssid\":\"$(json_escape "$WIFI_SSID")\",\"wifi_mode\":\"STA\",\"agent_version\":\"v7-hg224-camera-mic\",\"battery_percent\":$BATTERY_PERCENT,\"sd_free_gb\":$SD_FREE_GB,\"latest_media_file\":\"$(json_escape "$LATEST_MEDIA_FILE")\",\"latest_media_url\":\"$(json_escape "$LATEST_MEDIA_URL")\"}"
    if post_json /api/camera/heartbeat "$BODY"; then
        sync_clock
        apply_pending_shutter
        log "heartbeat accepted ip=$CURRENT_IP battery_percent=$BATTERY_PERCENT sd_free_gb=$SD_FREE_GB latest_media_file=$LATEST_MEDIA_FILE"
    else
        log "heartbeat failed: $RESPONSE"
    fi
}

upload_mp4_webhook() {
    BODY="{\"device_id\":\"$(json_escape "$DEVICE_ID")\",\"camera\":\"DJI Osmo Pocket 4 Pro\",\"ip\":\"$CURRENT_IP\",\"file_path\":\"$(json_escape "$NEW_MP4")\",\"media_url\":\"http://$CURRENT_IP:8088/DJI_001/$(json_escape "$NEW_MP4_BASENAME")\"}"
    if post_json /api/camera/webhook "$BODY" 90; then
        printf '%s\n' "$NEW_MP4_BASENAME" > "$BASE_DIR/last_mp4.txt"
        log "media webhook accepted file=$NEW_MP4_BASENAME size=$NEW_SIZE"
    else
        log "media webhook failed file=$NEW_MP4_BASENAME: $RESPONSE"
    fi
}

watch_mp4() {
    if [ -n "$WEBHOOK_PID" ]; then
        kill -0 "$WEBHOOK_PID" 2>/dev/null && return
        wait "$WEBHOOK_PID"
        WEBHOOK_PID=
    fi
    NEW_MP4=$(newest_mp4)
    [ -n "$NEW_MP4" ] || return
    NEW_MP4_BASENAME="${NEW_MP4##*/}"
    LAST_MP4=$(cat "$BASE_DIR/last_mp4.txt" 2>/dev/null)
    [ "$NEW_MP4_BASENAME" != "$LAST_MP4" ] || return
    NEW_SIZE=$("$BB" stat -c %s "$NEW_MP4" 2>/dev/null)
    [ -n "$NEW_SIZE" ] && [ "$NEW_SIZE" -gt 0 ] || return
    if [ "$PENDING_MP4" = "$NEW_MP4" ] && [ "$PENDING_SIZE" = "$NEW_SIZE" ]; then
        if [ "$REC" = true ]; then
            REC=false
            log "watch_mp4: recording stopped on camera ($NEW_MP4_BASENAME finalized at $NEW_SIZE bytes)"
        fi
        # Report generation can take longer than a capture window.
        if [ "${RUN_ONCE:-0}" = 1 ]; then
            upload_mp4_webhook
        else
            upload_mp4_webhook &
            WEBHOOK_PID=$!
        fi
    fi
    PENDING_MP4="$NEW_MP4"
    PENDING_SIZE="$NEW_SIZE"
}

capture_voice_chunk() {
    rm -f "$1"
    exec "$BB" timeout -t 7 parec -d alsa_input.0.custom-input-multich \
        --rate=16000 --format=s16le --channels=1 --file-format=wav \
        --capture-time=3 "$1" 2>/dev/null
}

poll_voice_chunk() {
    VOICE_WAV="$1"
    [ -s "$VOICE_WAV" ] || return
    # Stock HG224 BusyBox lacks -w; strip line wrapping on that build.
    B64=$("$BB" base64 -w 0 "$VOICE_WAV" 2>/dev/null) ||
        B64=$("$BB" base64 "$VOICE_WAV" | "$BB" tr -d '\r\n')
    rm -f "$VOICE_WAV"
    [ -n "$B64" ] || return
    VOICE_BODY="{\"device_id\":\"$(json_escape "$DEVICE_ID")\",\"recording_active\":$REC,\"wav_b64\":\"$B64\"}"
    if ! post_json /api/camera/voice_chunk "$VOICE_BODY" 70; then
        log "mic voice polling: voice endpoint failed $(printf '%s' "$RESPONSE" | "$BB" head -n 1)"
        return
    fi
    case "$RESPONSE" in
        *'"ACTION:START"'*|*'"command":"start"'*|*'"command": "start"'*)
            if dji_mb_ctrl -S test -R diag -g 1 -t 0 -s 2 -c 0x02 01 >> "$BASE_DIR/agent.log" 2>&1; then
                REC=true
                log "mic voice polling: ACTION:START dispatched"
            fi;;
        *'"ACTION:STOP"'*|*'"command":"stop"'*|*'"command": "stop"'*)
            if dji_mb_ctrl -S test -R diag -g 1 -t 0 -s 2 -c 0x02 00 >> "$BASE_DIR/agent.log" 2>&1; then
                log "mic voice polling: ACTION:STOP dispatched"
                REC=false
            fi;;
        *) log "mic voice polling: ACTION:NONE";;
    esac
}

read_shutter_marker() {
    mv /tmp/pocket_coffee_cmd "$BASE_DIR/shutter.$$" 2>/dev/null || return
    SHUTTER_ACTION=$(cat "$BASE_DIR/shutter.$$")
    rm -f "$BASE_DIR/shutter.$$"
    # The Mac wrote this marker after dispatching the physical ADB command.
    case "$SHUTTER_ACTION" in start) REC=true;; stop) REC=false;; esac
}

log 'Starting STA agent; boot auto-start is not installed by this script'
ensure_adbd
INITIAL_MP4=$(newest_mp4)
[ -e "$BASE_DIR/last_mp4.txt" ] || printf '%s\n' "${INITIAL_MP4##*/}" > "$BASE_DIR/last_mp4.txt"
REC=false
WEBHOOK_PID=
PENDING_MP4=""
PENDING_SIZE=""
# The media server is optional; it only exposes the verified DCIM directory.
if [ -d "$DCIM_DIR" ]; then
    "$BB" httpd -p 8088 -h "$DCIM_DIR" 2>> "$BASE_DIR/agent.log"
fi
if [ "${RUN_ONCE:-0}" = 1 ]; then
    ensure_adbd
    if ensure_sta; then
        heartbeat
        read_shutter_marker
        watch_mp4
        (capture_voice_chunk "$VOICE_WAV_A") && poll_voice_chunk "$VOICE_WAV_A"
    fi
    exit 0
fi

CUR_WAV="$VOICE_WAV_B"
NEXT_WAV="$VOICE_WAV_A"
capture_voice_chunk "$NEXT_WAV" &
CAPTURE_PID=$!
while true; do
    if wait "$CAPTURE_PID" && [ -s "$NEXT_WAV" ]; then
        CAPTURE_OK=1
    else
        CAPTURE_OK=0
    fi
    SWAP_WAV="$CUR_WAV"
    CUR_WAV="$NEXT_WAV"
    NEXT_WAV="$SWAP_WAV"
    # Start capturing before any network or media work touches the finished WAV.
    capture_voice_chunk "$NEXT_WAV" &
    CAPTURE_PID=$!
    [ "$CAPTURE_OK" = 1 ] || log "mic voice polling: capture failed"
    ensure_adbd
    if ensure_sta; then
        read_shutter_marker
        [ "$CAPTURE_OK" = 1 ] && poll_voice_chunk "$CUR_WAV"
        heartbeat &
        watch_mp4
    else
        sleep 3
    fi
done
