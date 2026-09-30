#!/usr/bin/env bash
# Build the golden test VM once: clone the Cirrus macOS 15 base image, create the VM-only
# "Disk Monitor Dev" signing identity, install a test build, grant it Accessibility, stop,
# and save the result as the golden image. Runs headless; nothing on the host desktop.
# Refuses to replace an existing golden image (delete it yourself with `tart delete`).
# Usage: golden.sh --app <path/to/Disk Monitor.app> [--name disk-monitor-golden] [--image <oci ref>]
set -euo pipefail
TART="${TART:-$HOME/.local/bin/tart}"; HERE="$(cd "$(dirname "$0")" && pwd)"
NAME=disk-monitor-golden; IMAGE=ghcr.io/cirruslabs/macos-sequoia-base:latest; APP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        --image) IMAGE="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$APP" ] || { echo "--app is required" >&2; exit 2; }
"$TART" list | awk '{print $2}' | grep -qx "$NAME" && { echo "$NAME already exists; refusing to replace it" >&2; exit 3; }
SETUP="$NAME-setup"; LOG="$HOME/.local/state/disk-monitor/vm"; mkdir -p "$LOG"
"$TART" clone "$IMAGE" "$SETUP"
cleanup() { "$TART" stop "$SETUP" >/dev/null 2>&1 || true; "$TART" list | awk '{print $2}' | grep -qx "$SETUP" && "$TART" delete "$SETUP" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
"$TART" run "$SETUP" --no-graphics --no-clipboard --no-audio >"$LOG/golden-setup.log" 2>&1 &
"$TART" ip "$SETUP" --wait 180 >/dev/null
for _ in $(seq 60); do "$TART" exec "$SETUP" true 2>/dev/null && break; sleep 2; done
"$TART" exec -i "$SETUP" /bin/bash -s < "$HERE/guest-signing-cert.sh"
bash "$HERE/install-app.sh" "$SETUP" "$APP"
"$TART" exec -i "$SETUP" /usr/bin/sudo /bin/bash -s < "$HERE/guest-grant-accessibility.sh"
"$TART" stop "$SETUP"
"$TART" rename "$SETUP" "$NAME"
trap - EXIT INT TERM
echo "golden image ready: $NAME"
