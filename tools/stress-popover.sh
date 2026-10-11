#!/bin/zsh
# Opens and closes the real popover N times, then reports settled memory and leaks.
# Usage: tools/stress-popover.sh [cycles] [path/to/Ultstat.app]
set -euo pipefail
N=${1:-60}
APP=${2:-build/DerivedData/Build/Products/Release/Ultstat.app}
pkill -f "$APP/Contents/MacOS/Ultstat" 2>/dev/null || true
sleep 1
open -n "$APP" --args -UltstatStressPopover "$N"
sleep $(( N / 2 + 15 ))
PID=$(pgrep -f "$APP/Contents/MacOS/Ultstat")
sleep 10
echo "cycles: $N"
footprint "$PID" | grep -m1 Footprint
leaks "$PID" 2>/dev/null | grep -E "leaks for" || true
heap "$PID" 2>/dev/null | grep -E "non-object" || true
