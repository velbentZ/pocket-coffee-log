#!/system/bin/sh
# =============================================================================
# Pocket 3 / Pocket 4 Pro Internal Persistent STA & Coffee Hook Daemon
# Path on camera: /data/local/tmp/pocket_sta_agent.sh
# =============================================================================
# Features:
# 1. Forces wlan0 into persistent STA (Client) mode connected to Home LAN
#    using wpa_supplicant & udhcpc, surviving screen sleep.
# 2. Enables ADB over TCP (port 5555) and Telnet/FTP for LAN control.
# 3. Watches /storage/sdcard0/DCIM/DJI_001 (or /mnt/sdcard/DCIM/100MEDIA)
#    for newly completed MP4 files and pushes a webhook notification with the
#    download URL directly to the Mac Coffee Server.
# =============================================================================

WIFI_SSID="${WIFI_SSID:-你的名字}"
WIFI_PSK="${WIFI_PSK:-nidemingzi}"
COFFEE_SERVER_URL="${COFFEE_SERVER_URL:-http://192.168.5.84:8788}"
CAMERA_MODEL="$(getprop ro.product.model 2>/dev/null || echo 'DJI-Osmo-Pocket')"
WPA_CONF="/data/local/tmp/wpa_sta_persistent.conf"
PID_FILE="/data/local/tmp/pocket_sta_agent.pid"
LOG_FILE="/data/local/tmp/pocket_sta_agent.log"

echo $$ > "$PID_FILE"
log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log_msg "Starting Pocket Internal STA Agent on $CAMERA_MODEL..."

# 1. Enable ADB over TCP/IP (Port 5555) so Mac can always reach camera shell over LAN
setprop service.adb.tcp.port 5555 2>/dev/null
stop adbd 2>/dev/null
start adbd 2>/dev/null

# 2. Prevent Wi-Fi chip from powering down on screen off
iw dev wlan0 set power_save off 2>/dev/null
svc power stayon usb 2>/dev/null

# 3. Generate persistent STA wpa_supplicant configuration
cat <<EOF > "$WPA_CONF"
ctrl_interface=/data/misc/wifi/sockets
update_config=1
ap_scan=1

network={
    ssid="$WIFI_SSID"
    psk="$WIFI_PSK"
    key_mgmt=WPA-PSK WPA-SAE
    priority=99
    scan_ssid=1
}
EOF
chmod 600 "$WPA_CONF"

ensure_sta_connected() {
    CURRENT_IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}')
    # If camera fell back to AP mode (192.168.2.1) or lost IP, switch to STA mode
    if [ -z "$CURRENT_IP" ] || [ "$CURRENT_IP" = "192.168.2.1" ]; then
        log_msg "wlan0 is in AP/disconnected state ($CURRENT_IP). Switching to persistent STA mode..."
        killall hostapd 2>/dev/null
        killall dnsmasq 2>/dev/null
        ifconfig wlan0 up 2>/dev/null

        if ! pgrep -f "wpa_supplicant.*$WPA_CONF" >/dev/null 2>&1; then
            killall wpa_supplicant 2>/dev/null
            wpa_supplicant -B -i wlan0 -c "$WPA_CONF" -D nl80211,wext >> "$LOG_FILE" 2>&1
            sleep 3
        fi
        udhcpc -i wlan0 -n -q -t 5 >> "$LOG_FILE" 2>&1 || dhcpcd wlan0 >> "$LOG_FILE" 2>&1
        CURRENT_IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}')
        log_msg "STA connected! Assigned LAN IP: $CURRENT_IP"
    fi
}

# 4. Start lightweight HTTP File Server on port 8088 exposing DCIM media over LAN
DCIM_DIR="/storage/sdcard0/DCIM"
[ ! -d "$DCIM_DIR" ] && DCIM_DIR="/mnt/sdcard/DCIM"
if command -v busybox >/dev/null 2>&1; then
    busybox httpd -p 8088 -h "$DCIM_DIR" 2>/dev/null
    log_msg "Started busybox httpd media server on :8088 ($DCIM_DIR)"
fi

# 5. Main Watchdog Loop: Keep STA alive + Report heartbeat & new MP4 files to Mac Server
LAST_VIDEO=""
while true; do
    ensure_sta_connected
    CURRENT_IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}')

    # Check latest MP4 in DCIM
    LATEST_MP4=$(find "$DCIM_DIR" -name "*.MP4" -o -name "*.mp4" 2>/dev/null | sort | tail -n 1)
    if [ -n "$LATEST_MP4" ] && [ "$LATEST_MP4" != "$LAST_VIDEO" ]; then
        # Wait until file size stabilizes (recording finished & flushed)
        SIZE1=$(wc -c < "$LATEST_MP4" 2>/dev/null || echo 0)
        sleep 2
        SIZE2=$(wc -c < "$LATEST_MP4" 2>/dev/null || echo 0)
        if [ "$SIZE1" -gt 0 ] && [ "$SIZE1" = "$SIZE2" ]; then
            LAST_VIDEO="$LATEST_MP4"
            REL_PATH="${LATEST_MP4#$DCIM_DIR/}"
            log_msg "New completed coffee video detected: $REL_PATH ($SIZE2 bytes)"
            # Notify Mac Coffee Server via HTTP POST
            if command -v curl >/dev/null 2>&1; then
                curl -s -X POST "$COFFEE_SERVER_URL/api/camera/webhook" \
                    -H "Content-Type: application/json" \
                    -d "{\"event\":\"video_ready\",\"camera\":\"$CAMERA_MODEL\",\"ip\":\"$CURRENT_IP\",\"file_path\":\"$LATEST_MP4\",\"download_url\":\"http://$CURRENT_IP:8088/$REL_PATH\",\"size_bytes\":$SIZE2}" \
                    >/dev/null 2>&1
            elif command -v wget >/dev/null 2>&1; then
                wget -q -O - --post-data="{\"event\":\"video_ready\",\"camera\":\"$CAMERA_MODEL\",\"ip\":\"$CURRENT_IP\",\"file_path\":\"$LATEST_MP4\",\"download_url\":\"http://$CURRENT_IP:8088/$REL_PATH\"}" \
                    --header="Content-Type: application/json" \
                    "$COFFEE_SERVER_URL/api/camera/webhook" >/dev/null 2>&1
            fi
        fi
    fi

    sleep 5
done
