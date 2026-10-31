#!/bin/bash
# Run the Base Studio self-test under an independent memory cap.
# Samples the app's memory every 1 s to a CSV and kills it (keeping logs) if it
# exceeds CAP_MB. Usage:
#   scripts/selftest-guarded.sh <out-dir> [CAP_MB] -- <self-test args...>
# e.g. scripts/selftest-guarded.sh ~/Movies/BaseStudio/kept/run1 3000 -- \
#        --selftest-record --selftest-no-webcam --selftest-rounds 1 --selftest-seconds 60 --selftest-export-each
set -u
# Footprint in MB from the `footprint` header line, e.g.
#   "Google Chrome [635]: 64-bit    Footprint: 724 MB (16384 bytes per page)"
# Prints nothing if it can't be read.
footprint_mb() {
  footprint -p "$1" 2>/dev/null | awk 'match($0,/Footprint: [0-9.]+ [KMG]B/){split(substr($0,RSTART+11,RLENGTH-11),a," "); v=a[1]; if(a[2]=="GB")v*=1024; if(a[2]=="KB")v/=1024; print int(v); exit}'
}
[ "${1:-}" = "--probe" ] && { footprint_mb "$2"; exit 0; }
monitor() {  # monitor <pid> <cap_mb> <csv>; sets STATUS
  local PID=$1 CAP_MB=$2 MEM=$3
  STATUS=finished
  while kill -0 "$PID" 2>/dev/null; do
    RSS=$(ps -o rss= -p "$PID" | awk '{print int($1/1024)}')
    FP=$(footprint_mb "$PID")
    LOCK=$(ioreg -n Root -d1 | grep -o 'IOConsoleLocked" = [A-Za-z]*' | awk '{print $3}')
    echo "$(date -u +%H:%M:%S),${FP:-},${RSS:-},$LOCK" >> "$MEM"
    # No silent fallback to RSS: footprint is what grew to 40 GB last time.
    if [ -z "$FP" ]; then
      STATUS="stopped: could not read footprint"; kill -9 "$PID"; break
    fi
    if [ "$FP" -gt "$CAP_MB" ]; then
      STATUS="killed: footprint ${FP} MB > ${CAP_MB} MB cap"
      kill -9 "$PID"; break
    fi
    [ "$LOCK" = "Yes" ] && [ -z "${NO_LOCK_STOP:-}" ] && { STATUS="stopped: screen locked"; kill "$PID"; sleep 3; kill -9 "$PID" 2>/dev/null; break; }
    sleep 1
  done
}
# Validate the cap logic on any process: --watch <pid> <cap_mb> <csv>
[ "${1:-}" = "--watch" ] && { echo "utc,phys_footprint_mb,rss_mb,locked" > "$4"; monitor "$2" "$3" "$4"; echo "$STATUS"; exit 0; }
OUT="$1"; CAP_MB="${2:-3000}"; shift 2; [ "${1:-}" = "--" ] && shift
APP="$(cd "$(dirname "$0")/.." && pwd)/build/Base Studio.app"
mkdir -p "$OUT"
REPORT="$OUT/report.json"; MEM="$OUT/memory.csv"
echo "utc,phys_footprint_mb,rss_mb,locked" > "$MEM"
# Never touch a Base Studio the user may be using, and never start on a locked screen.
if pgrep -f "Base Studio.app/Contents/MacOS/BaseStudio" >/dev/null; then
  echo "Base Studio is already running — quit it first; not starting the test." | tee "$OUT/summary.txt"; exit 3
fi
if [ "$(ioreg -n Root -d1 | grep -o 'IOConsoleLocked" = [A-Za-z]*' | awk '{print $3}')" != "No" ]; then
  echo "Screen is locked — not starting the test." | tee "$OUT/summary.txt"; exit 4
fi
caffeinate -d -u -t 2400 >/dev/null 2>&1 & CAF=$!
open -n --stdout "$OUT/stdout.log" --stderr "$OUT/stderr.log" ${BS_ENV:+--env "$BS_ENV"} "$APP" --args "$@" --selftest-out "$REPORT"
sleep 5
PID=$(pgrep -f "Base Studio.app/Contents/MacOS/BaseStudio" | head -1)
[ -z "$PID" ] && { echo "app did not start"; kill $CAF; exit 2; }
monitor "$PID" "$CAP_MB" "$MEM"
kill $CAF 2>/dev/null
cp ~/Library/Logs/BaseStudio/base-studio-$(date -u +%Y%m%d).log "$OUT/app.log" 2>/dev/null
PEAK=$(awk -F, 'NR>1{if($2>m)m=$2} END{print m+0}' "$MEM")
echo "$STATUS; peak ${PEAK} MB; report: $([ -s "$REPORT" ] && echo yes || echo no)" | tee "$OUT/summary.txt"
