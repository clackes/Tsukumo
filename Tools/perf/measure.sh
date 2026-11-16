#!/bin/sh
# SPDX-FileCopyrightText: 2026 Tsukumo contributors
# SPDX-License-Identifier: GPL-3.0-only
#
# Sudo-free measurement of a scenario (Docs/PERF.md): average and peak CPU,
# wakeups/s, threads and footprint of Tsukumo and its children (adapter's perl,
# Converter.xpc), plus WindowServer's CPU as a hint of out-of-process costs.
# GPU and power require powermetrics (sudo): see Docs/PERF.md.
#
# Usage: Tools/perf/measure.sh <label> <seconds> [comma-separated modules | keep | none]
#   keep  measures the app as it is; none  all modules off.
#   With a module list the app is quit, reconfigured and relaunched, then
#   it waits 40 s before sampling.
set -eu

LABEL="${1:?etichetta}"
SECONDS_TOTAL="${2:?secondi}"
MODULES="${3:-keep}"
APP="${APP:-/Applications/Tsukumo.app}"
BUNDLE=dev.local.tsukumo
INTERVAL=5

if [ "$MODULES" != "keep" ]; then
  osascript -e "tell application id \"$BUNDLE\" to quit" >/dev/null 2>&1 || true
  i=0
  while pgrep -x Tsukumo >/dev/null && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
  if [ "$MODULES" = "none" ]; then
    defaults write "$BUNDLE" enabledModules -array
  else
    # shellcheck disable=SC2086
    defaults write "$BUNDLE" enabledModules -array $(printf '%s' "$MODULES" | tr ',' ' ')
  fi
  open -g "$APP"
  sleep 40
fi

app_pid="$(pgrep -x Tsukumo | head -1)"
[ -n "$app_pid" ] || { echo "Tsukumo is not running" >&2; exit 1; }
ws_pid="$(pgrep -x WindowServer | head -1)"
perl_pid="$(pgrep -f 'Tsukumo.app/Contents/Resources/run.pl' | head -1 || true)"
xpc_pid="$(pgrep -f 'Converter.xpc' | head -1 || true)"

pids="-pid $app_pid -pid $ws_pid"
[ -n "$perl_pid" ] && pids="$pids -pid $perl_pid"
[ -n "$xpc_pid" ] && pids="$pids -pid $xpc_pid"
samples=$((SECONDS_TOTAL / INTERVAL + 1))

# shellcheck disable=SC2086
top -l "$samples" -s "$INTERVAL" $pids -stats pid,command,cpu,idlew,th 2>/dev/null |
  awk -v label="$LABEL" -v app="$app_pid" -v ws="$ws_pid" -v perl="${perl_pid:-x}" -v xpc="${xpc_pid:-x}" -v dt="$INTERVAL" '
    /^PID/ { block++; next }
    block > 0 && $1 ~ /^[0-9]+$/ {
      pid = $1; cpu = $3 + 0; w = $4; gsub(/[^0-9]/, "", w); w += 0; th = $5; sub(/\/.*/, "", th); gsub(/[^0-9]/, "", th)
      name = (pid == app) ? "Tsukumo" : (pid == ws) ? "WindowServer" : (pid == perl) ? "perl" : (pid == xpc) ? "Converter" : pid
      if (block > 1) {   # the first top block has no valid interval CPU
        n[name]++; sum[name] += cpu; if (cpu > peak[name]) peak[name] = cpu
        if (name in lastw) wk[name] += w - lastw[name]
      }
      lastw[name] = w; thr[name] = th
    }
    END {
      for (name in n) {
        printf "%s\t%s\tcpu_avg=%.2f\tcpu_peak=%.1f\twakeups_s=%.2f\tthreads=%s\n",
          label, name, sum[name] / n[name], peak[name], wk[name] / (n[name] * dt), thr[name]
      }
    }'

for pid in $app_pid ${perl_pid:-} ${xpc_pid:-}; do
  fp="$(footprint -p "$pid" 2>/dev/null | sed -n "s/.*Footprint: \([0-9.]* [KMG]B\).*/\1/p" | head -1)"
  printf '%s\tfootprint pid %s\t%s\n' "$LABEL" "$pid" "$fp"
done
