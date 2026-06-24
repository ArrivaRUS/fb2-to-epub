#!/bin/bash
# Stable FDA "responsible target" for the fb2-to-epub LaunchAgent.
#
# WHY THIS EXISTS:
#   macOS TCC attributes file-access permission (incl. Full Disk Access) to the
#   *executable named in ProgramArguments*, not to the script it runs. If the
#   agent pointed ProgramArguments at /bin/bash, the user would have to grant FDA
#   to /bin/bash itself (broad, and the grant is keyed to that binary). By giving
#   the agent its own stable runner at a fixed App Support path, Full Disk Access
#   can be granted to THIS file specifically, and the grant survives reinstalls
#   as long as the path and bytes are stable.
#
#   => Grant Full Disk Access to:
#      ~/Library/Application Support/fb2-to-epub/bin/fb2-to-epub-runner.sh
#
# It is intentionally minimal: it locates the watcher next to itself and execs it,
# inheriting WATCH_DIR / PATH / EBOOK_CONVERT / PYTHON3 from the LaunchAgent's
# EnvironmentVariables. Keep this file stable (avoid churn) so the TCC grant holds.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER="$HERE/fb2-to-epub-watcher.sh"

if [[ ! -x "$WATCHER" ]]; then
  echo "fb2-to-epub: watcher not found at $WATCHER" >&2
  exit 1
fi

exec /bin/bash "$WATCHER"
