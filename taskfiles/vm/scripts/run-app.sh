#!/usr/bin/env bash
# Launch the installed Disk Monitor inside the VM's admin GUI (Aqua) session with open -n, so
# the app is its own responsible process for TCC; wait for it to exit; print its result file.
# Usage: run-app.sh <vm> <result-file-name> <app args...>
#   e.g. run-app.sh disk-monitor-run DiskMonitor-exclusion-results.log --spotlight-exclusion-test --run-scenarios
set -euo pipefail
VM="$1"; RESULT="$2"; shift 2; TART="${TART:-$HOME/.local/bin/tart}"
x() { "$TART" exec "$VM" "$@"; }
UIDA=$(x /usr/bin/id -u admin | tr -d '\r')
TMP=$(x /usr/bin/sudo -u admin /usr/bin/getconf DARWIN_USER_TEMP_DIR | tr -d '\r')
x /bin/rm -f "$TMP$RESULT"
x /usr/bin/sudo /bin/launchctl asuser "$UIDA" /usr/bin/sudo -u admin /usr/bin/open -n "/Users/admin/Applications/Disk Monitor.app" --args "$@"
for _ in $(seq 300); do
    sleep 1
    x /bin/test -s "$TMP$RESULT" && ! x /usr/bin/pgrep -f 'Disk Monitor.app/Contents/MacOS/DiskMonitor' >/dev/null && break
done
x /bin/cat "$TMP$RESULT"
