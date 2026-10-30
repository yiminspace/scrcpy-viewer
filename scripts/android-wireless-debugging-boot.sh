#!/system/bin/sh
# Optional root helper. Install as a root-only executable in service.d.
# Keep native adbd TLS/mDNS and trusted-network authorization. Never send input.
# React only to the framework's network-triggered disable event; an ordinary
# manual disable while connected does not request recovery.

wireless_log() { /system/bin/log -t ScrcpyWireless "$1"; }
wireless_has_address() {
    /system/bin/ip -4 addr show dev "$wireless_interface" 2>/dev/null |
        /system/bin/toybox grep -q 'inet '
}

wireless_enable() {
    setprop ctl.start mdnsd
    settings put global adb_wifi_enabled 1 || {
        wireless_log 'Wireless debugging setting failed'; return 1;
    }
    wireless_attempt=0
    while [ "$wireless_attempt" -lt 15 ]; do
        wireless_port=$(getprop service.adb.tls.port)
        case "$wireless_port" in
            ''|0|*[!0-9]*) ;;
            *) wireless_log 'Native wireless debugging listener ready'; return 0 ;;
        esac
        sleep 2
        wireless_attempt=$((wireless_attempt + 1))
    done
    wireless_log 'Native wireless debugging listener did not become ready'
    return 1
}

wireless_main() {
    wireless_attempt=0
    while [ "$(getprop sys.boot_completed)" != "1" ]; do
        [ "$wireless_attempt" -lt 90 ] || { wireless_log 'System boot wait timed out'; return 1; }
        sleep 2
        wireless_attempt=$((wireless_attempt + 1))
    done

    wireless_interface=$(getprop wifi.interface)
    [ -n "$wireless_interface" ] || wireless_interface=wlan0
    wireless_attempt=0
    while ! wireless_has_address; do
        [ "$wireless_attempt" -lt 90 ] || { wireless_log 'Wi-Fi address wait timed out'; return 1; }
        sleep 2
        wireless_attempt=$((wireless_attempt + 1))
    done
    wireless_enable || return 1
    wireless_log 'Watching for network-triggered wireless debugging shutdown'

    # Stream only the framework tag, in memory. Epoch timestamps let us discard
    # old/queued disconnects instead of overriding a later manual switch change.
    # -T starts at the current time, avoiding replay of a previous boot event.
    while :; do
        wireless_start=$(date '+%m-%d %H:%M:%S.000')
        logcat -b system -v epoch -T "$wireless_start" -s 'AdbDebuggingManager:I' '*:S' |
        # Android pads epoch timestamps with spaces. Default IFS trims that
        # padding before extracting the timestamp and remaining message.
        while read -r wireless_event wireless_line; do
            case "$wireless_line" in
                *'Network disconnected. Disabling adbwifi.') ;;
                *) continue ;;
            esac
            wireless_event=${wireless_event%%.*}
            case "$wireless_event" in ''|*[!0-9]*) continue ;; esac
            wireless_now=$(date +%s)
            [ "$((wireless_now - wireless_event))" -le 5 ] || continue
            wireless_log 'Network disconnected; waiting to restore wireless debugging'
            # Allow the framework to finish clearing the old IP and setting.
            sleep 3
            wireless_wait=0
            while ! wireless_has_address; do
                [ "$wireless_wait" -lt 90 ] || break
                sleep 2
                wireless_wait=$((wireless_wait + 1))
            done
            if wireless_has_address; then
                # A pending recovery expires after three minutes. Do not enforce
                # the setting continuously, or retry a failed authorization.
                if [ "$(settings get global adb_wifi_enabled)" != "1" ]; then
                    wireless_log 'Wi-Fi address restored; enabling native wireless debugging'
                    wireless_enable || :
                fi
            else
                wireless_log 'Network recovery wait timed out; leaving wireless debugging unchanged'
            fi
        done
        wireless_log 'Framework log stream ended; restarting watcher'
        sleep 5
    done
}

# service.d must be allowed to finish. The child stays alive without holding the
# root manager's output pipes open. Stop/remove this helper to disable recovery.
if [ "$1" = '--monitor' ]; then
    wireless_main
else
    "$0" --monitor </dev/null >/dev/null 2>&1 &
fi
