"""Synthetic shell integration checks; no adb, device logs, or network access."""
import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("android-wireless-debugging-boot.sh")


class WirelessBootTests(unittest.TestCase):
    def run_scenario(self, event="network", address_returns=True, port_ready=True):
        source = SCRIPT.read_text().split("# service.d must be allowed to finish.")[0]
        harness = r'''
wireless_log() { printf '%s\n' "$1" >> "$fixture_dir/events"; }
getprop() {
    case "$1" in
        sys.boot_completed) echo 1 ;;
        wifi.interface) echo wlan0 ;;
        service.adb.tls.port) [ "$port_ready" = yes ] && echo 40401 ;;
    esac
}
settings() {
    if [ "$1" = put ]; then
        echo "$4" > "$fixture_dir/setting"
        echo enable >> "$fixture_dir/events"
    else
        cat "$fixture_dir/setting"
    fi
}
setprop() { :; }
wireless_has_address() {
    [ ! -f "$fixture_dir/disconnected" ] || [ "$address_returns" = yes ]
}
sleep() {
    # End the outer watcher after its first finite synthetic log stream.
    [ "$1" != 5 ] || exit 0
}
logcat() {
    echo 0 > "$fixture_dir/setting"
    touch "$fixture_dir/disconnected"
    case "$event" in
        network) printf '%s 1000 1000 I AdbDebuggingManager: Network disconnected. Disabling adbwifi.\n' "$(date +%s).100" ;;
        stale) echo '1.000 1000 1000 I AdbDebuggingManager: Network disconnected. Disabling adbwifi.' ;;
        manual) echo '1.000 1000 1000 I AdbDebuggingManager: Other event' ;;
    esac
}
wireless_main
'''
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory)
            env = {"fixture_dir": directory, "event": event,
                   "address_returns": "yes" if address_returns else "no",
                   "port_ready": "yes" if port_ready else "no"}
            result = subprocess.run(["sh", "-c", source + harness], env=env,
                                    capture_output=True, text=True, timeout=5)
            events = (path / "events").read_text()
            return result, events

    def test_network_recovery_enables_once_after_boot(self):
        result, events = self.run_scenario()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events.splitlines().count("enable"), 2)
        self.assertIn("Wi-Fi address restored", events)

    def test_manual_disable_is_not_reversed(self):
        _, events = self.run_scenario(event="manual")
        self.assertEqual(events.splitlines().count("enable"), 1)

    def test_old_events_do_not_reverse_later_manual_disable(self):
        _, events = self.run_scenario(event="stale")
        self.assertEqual(events.splitlines().count("enable"), 1)

    def test_no_address_expires_without_enabling(self):
        _, events = self.run_scenario(address_returns=False)
        self.assertEqual(events.splitlines().count("enable"), 1)
        self.assertIn("Network recovery wait timed out", events)

    def test_missing_boot_listener_does_not_start_watcher(self):
        result, events = self.run_scenario(port_ready=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Watching for", events)
        self.assertIn("listener did not become ready", events)


if __name__ == "__main__":
    unittest.main()
