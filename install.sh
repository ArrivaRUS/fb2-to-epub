#!/bin/bash
# Advanced CLI install path. Thin wrapper around packaging/installer.sh so the
# command line and the .app share one source of truth for install logic.
#
# Usage:
#   ./install.sh ["/path/to/watch folder"]      (default ~/Desktop/fb2-to-epub)
#   WATCH_DIR="/path/to/folder" ./install.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec /bin/bash "$REPO_DIR/packaging/installer.sh" "$@"
