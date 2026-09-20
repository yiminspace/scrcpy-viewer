#!/usr/bin/env python3
"""Launch the extracted download with a fake empty adb; never access a real phone."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--server", required=True, type=Path,
                        help="Verified official scrcpy 3.3.3 server used only for dependency resolution")
    args = parser.parse_args()
    server = args.server.resolve()
    expected_hash = "7e70323ba7f259649dd4acce97ac4fefbae8102b2c6d91e2e7be613fd5354be0"
    if hashlib.sha256(server.read_bytes()).hexdigest() != expected_hash:
        raise SystemExit("Smoke check requires the pinned official server.")
    with tempfile.TemporaryDirectory(prefix="scrcpy-viewer-release-smoke-") as folder:
        root = Path(folder)
        subprocess.run(["ditto", "-x", "-k", str(args.archive.resolve()), str(root)], check=True)
        adb = root / "fake-adb"
        adb.write_text('#!/bin/sh\n'
                       'if [ "$#" -eq 2 ] && [ "$1" = devices ] && [ "$2" = -l ]; then\n'
                       '  printf "devices\\n" >> "$SCRCPY_VIEWER_SMOKE_ADB_LOG"\n'
                       '  printf "List of devices attached\\n\\n"\n'
                       '  exit 0\n'
                       'fi\n'
                       'printf "UNEXPECTED\\n" >> "$SCRCPY_VIEWER_SMOKE_ADB_LOG"\n'
                       'exit 90\n')
        adb.chmod(0o755)
        diagnostics = root / "diagnostics"
        adb_log = root / "adb-invocations.txt"
        environment = dict(os.environ)
        environment.update(ADB=str(adb), SCRCPY_SERVER_PATH=str(server),
                           SCRCPY_BIN=str(root / "no-desktop-client"),
                           SCRCPY_VIEWER_SMOKE_ADB_LOG=str(adb_log))
        environment.pop("SCRCPY_VIEWER_DIAGNOSTICS_DIR", None)
        executable = root / "Scrcpy Viewer.app/Contents/MacOS/ScrcpyViewer"
        subprocess.run([str(executable), "--diagnostics-dir", str(diagnostics),
                        "--quit-after", "5"], env=environment, check=True, timeout=30)
        state = json.loads((diagnostics / "state.json").read_text())
        if state.get("error") or state["connected"] or state["devices"] or state["displays"]:
            raise SystemExit("Unexpected app state during device-free smoke check.")
        calls = adb_log.read_text().splitlines()
        if not calls or set(calls) != {"devices"}:
            raise SystemExit("Expected only device discovery against the fake adb.")
        events = {json.loads(line)["event"] for line in
                  (diagnostics / "lifecycle.jsonl").read_text().splitlines()}
        if not {"shutdown_ready", "termination_reply"} <= events:
            raise SystemExit("Application did not complete its normal shutdown.")
        print("PASS: extracted app launches without desktop scrcpy, discovers zero fake devices, and shuts down cleanly.")


if __name__ == "__main__":
    main()
