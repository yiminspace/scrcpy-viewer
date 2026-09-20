#!/bin/bash
# Standalone installer. This script is also distributed beside Scrcpy Viewer.app.
# Upstream: https://github.com/Genymobile/scrcpy/releases/tag/v3.3.3
set -euo pipefail

server_version='3.3.3'
server_sha256='7e70323ba7f259649dd4acce97ac4fefbae8102b2c6d91e2e7be613fd5354be0'
server_url="https://github.com/Genymobile/scrcpy/releases/download/v${server_version}/scrcpy-server-v${server_version}"
dependency_directory="${HOME}/Library/Application Support/Scrcpy Viewer/Dependencies"

usage() {
    cat <<'USAGE'
Usage: setup-dependencies.sh [--directory DIR] [--help]

Install the pinned official scrcpy-server 3.3.3 after verifying its SHA-256.
No desktop scrcpy is downloaded, no Homebrew package is changed, and no phone is accessed.

Default: ~/Library/Application Support/Scrcpy Viewer/Dependencies/scrcpy/3.3.3/scrcpy-server
--directory DIR  Use DIR as the Dependencies root (for an isolated install).
                 For a custom location, set SCRCPY_SERVER_PATH to the installed file.
--help           Show this help without installing anything.

ADB is separate. If it is missing, install it with:
  brew install android-platform-tools
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --directory)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                printf '%s\n' 'Error: --directory requires a nonempty path.' >&2
                exit 2
            fi
            dependency_directory=$2
            shift 2
            ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

install_directory="${dependency_directory}/scrcpy/${server_version}"
server_path="${install_directory}/scrcpy-server"
temporary_file=''
trap 'if [ -n "$temporary_file" ]; then rm -f -- "$temporary_file"; fi' EXIT

# BSD mv treats an existing directory (including a symlink to one) as a container,
# which would otherwise report success without installing the expected file.
if [ -d "$server_path" ]; then
    printf 'Error: server destination is a directory: %s\n' "$server_path" >&2
    exit 1
fi

checksum() {
    local output
    output=$(/usr/bin/shasum -a 256 "$1")
    printf '%s' "${output%% *}"
}

if [ -f "$server_path" ] && [ "$(checksum "$server_path")" = "$server_sha256" ]; then
    printf 'Verified scrcpy-server %s is already installed.\n' "$server_version"
else
    mkdir -p -- "$install_directory"
    temporary_file=$(mktemp "${install_directory}/.scrcpy-server-download.XXXXXX")
    printf 'Downloading official scrcpy-server %s…\n' "$server_version"
    /usr/bin/curl --fail --location --retry 3 --connect-timeout 15 --max-time 120 \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --output "$temporary_file" "$server_url"
    actual_sha256=$(checksum "$temporary_file")
    if [ "$actual_sha256" != "$server_sha256" ]; then
        printf 'Checksum mismatch. Expected %s, received %s. Nothing installed.\n' "$server_sha256" "$actual_sha256" >&2
        exit 1
    fi
    chmod 644 "$temporary_file"
    mv -f -- "$temporary_file" "$server_path"
    temporary_file=''
    if [ ! -f "$server_path" ] || [ ! -r "$server_path" ] || [ "$(checksum "$server_path")" != "$server_sha256" ]; then
        printf 'Error: installed server could not be verified: %s\n' "$server_path" >&2
        exit 1
    fi
    printf 'Installed and SHA-256 verified scrcpy-server %s.\n' "$server_version"
fi

printf 'Server: %s\n' "$server_path"
if ! command -v adb >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/adb ] && [ ! -x /usr/local/bin/adb ]; then
    printf '\nADB is missing. Run:\n  brew install android-platform-tools\n'
fi
printf '\nSetup complete. Open Scrcpy Viewer and choose Refresh.\n'
