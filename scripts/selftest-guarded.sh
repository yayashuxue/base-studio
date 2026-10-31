#!/bin/bash
# Run the Base Studio self-test under an independent memory cap.
# Samples the app's memory every 2 s to a CSV and kills it (keeping logs) if it
# exceeds CAP_MB. Usage:
#   scripts/selftest-guarded.sh <out-dir> [CAP_MB] -- <self-test args...>
# e.g. scripts/selftest-guarded.sh ~/Movies/BaseStudio/kept/run1 3000 -- \
#        --selftest-record --selftest-no-webcam --selftest-rounds 1 --selftest-seconds 60 --selftest-export-each
set -u
OUT="$1"; CAP_MB="${2:-3000}"; shift 2; [ "${1:-}" = "--" ] && shift
APP="$(cd "$(dirname "$0")/.." && pwd)/build/Base Studio.app"
mkdir -p "$OUT"
REPORT="$OUT/report.json"; MEM="$OUT/memory.csv"
echo "utc,phys_footprint_mb,rss_mb,locked" > "$MEM"
pkill -f "Base Studio.app/Contents/MacOS/BaseStudio" 2>/dev/null; sleep 1
caffeinate -d -u -t 2400 >/dev/null 2>&1 & CAF=$!
open -n --stdout "$OUT/stdout.log" --stderr "$OUT/stderr.log" ${BS_ENV:+--env "$BS_ENV"} "$APP" --args "$@" --selftest-out "$REPORT"
sleep 5
PID=$(pgrep -f "Base Studio.app/Contents/MacOS/BaseStudio" | head -1)
[ -z "$PID" ] && { echo "app did not start"; kill $CAF; exit 2; }
STATUS=finished
while kill -0 "$PID" 2>/dev/null; do
  RSS=$(ps -o rss= -p "$PID" | awk '{print int($1/1024)}')
  FP=$(footprint -p "$PID" 2>/dev/null | awk '/phys_footprint:/ {v=$2; u=$3; if (u ~ /GB/) v*=1024; if (u ~ /KB/) v/=1024; print int(v); exit}')
  LOCK=$(ioreg -n Root -d1 | grep -o 'IOConsoleLocked" = [A-Za-z]*' | awk '{print $3}')
  echo "$(date -u +%H:%M:%S),${FP:-},${RSS:-},$LOCK" >> "$MEM"
  USED=${FP:-$RSS}
  if [ -n "$USED" ] && [ "$USED" -gt "$CAP_MB" ]; then
    STATUS="killed: ${USED} MB > ${CAP_MB} MB cap"
    kill -9 "$PID"; break
  fi
  [ "$LOCK" = "Yes" ] && { STATUS="stopped: screen locked"; kill "$PID"; break; }
  sleep 2
done
kill $CAF 2>/dev/null
cp ~/Library/Logs/BaseStudio/base-studio-$(date -u +%Y%m%d).log "$OUT/app.log" 2>/dev/null
PEAK=$(awk -F, 'NR>1{v=($2!=""?$2:$3); if(v>m)m=v} END{print m+0}' "$MEM")
echo "$STATUS; peak ${PEAK} MB; report: $([ -s "$REPORT" ] && echo yes || echo no)" | tee "$OUT/summary.txt"
