#!/usr/bin/env bash
# One disposable live run: clone the golden VM, install a build, run it in the VM's GUI session,
# save the result under ~/.local/state/disk-monitor/vm/<run>/, then stop and delete the clone.
# Nothing runs on the host desktop. The golden VM is never started or modified here.
# Usage: vm-run.sh <path/to/Disk Monitor.app> <result-file-name> <app args...>
set -euo pipefail
APP="$1"; RESULT="$2"; shift 2
TART="${TART:-$HOME/.local/bin/tart}"; HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="run-$(date -u +%Y%m%d%H%M%S)"; VM="disk-monitor-$RUN"
OUT="$HOME/.local/state/disk-monitor/vm/$RUN"; mkdir -p "$OUT"
cleanup() {
    [ -n "${PID:-}" ] && "$TART" stop "$VM" >/dev/null 2>&1 || true
    "$TART" delete "$VM" >/dev/null 2>&1 || true
    "$TART" list | grep -q " $VM " && echo "WARNING: $VM not deleted" >&2 || true
}
trap cleanup EXIT INT TERM
"$TART" clone disk-monitor-golden "$VM"
"$TART" run "$VM" --no-graphics --no-clipboard --no-audio >"$OUT/vm.log" 2>&1 & PID=$!
"$TART" ip "$VM" --wait 180 >/dev/null
for _ in $(seq 60); do "$TART" exec "$VM" true 2>/dev/null && break; sleep 2; done
"$TART" exec "$VM" /bin/sh -c 'echo "context: $(/bin/launchctl managername) $(sw_vers -productVersion) $(defaults read -g AppleLocale)"' >"$OUT/context.txt"
shasum -a 256 "$APP/Contents/MacOS/DiskMonitor" >"$OUT/host-binary.sha256"
bash "$HERE/install-app.sh" "$VM" "$APP" >"$OUT/install.log" 2>&1
bash "$HERE/run-app.sh" "$VM" "$RESULT" "$@" >"$OUT/$RESULT"
cat "$OUT/context.txt" "$OUT/$RESULT"
echo "saved: $OUT"
