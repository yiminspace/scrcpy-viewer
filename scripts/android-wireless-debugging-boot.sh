#!/system/bin/sh
# Optional root boot helper for devices that reset native wireless debugging at boot.
# Install manually in the root manager's service.d directory. This uses the system
# setting and native adbd TLS/mDNS implementation; it does not replace either daemon.
# Runs once per boot and does not turn debugging back on after a later manual disable.

wireless_log() { /system/bin/log -t ScrcpyWireless "$1"; }

wireless_attempt=0
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    [ "$wireless_attempt" -lt 90 ] || { wireless_log 'System boot wait timed out'; exit 1; }
    sleep 2
    wireless_attempt=$((wireless_attempt + 1))
done

wireless_interface=$(getprop wifi.interface)
[ -n "$wireless_interface" ] || wireless_interface=wlan0
wireless_attempt=0
while ! /system/bin/ip -4 addr show dev "$wireless_interface" 2>/dev/null | /system/bin/toybox grep -q 'inet '; do
    [ "$wireless_attempt" -lt 90 ] || { wireless_log 'Wi-Fi address wait timed out'; exit 1; }
    sleep 2
    wireless_attempt=$((wireless_attempt + 1))
done

setprop ctl.start mdnsd
settings put global adb_wifi_enabled 1 || { wireless_log 'Wireless debugging setting failed'; exit 1; }
wireless_attempt=0
while [ "$wireless_attempt" -lt 15 ]; do
    wireless_port=$(getprop service.adb.tls.port)
    case "$wireless_port" in
        ''|0|*[!0-9]*) ;;
        *) wireless_log 'Native wireless debugging listener ready'; exit 0 ;;
    esac
    sleep 2
    wireless_attempt=$((wireless_attempt + 1))
done
wireless_log 'Native wireless debugging listener did not become ready'
exit 1
