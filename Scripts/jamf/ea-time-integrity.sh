#!/bin/bash
# Jamf Pro Extension Attribute: "Lull Time Integrity" (Data type: String).
# Reports trusted-time health from /var/db/lull/status.json:
#   OK: synced 12m ago via time.apple.com, clock offset +0s
#   WARN: last sync 3d ago (...)                 -> network blocked?
#   WARN: clock tampering detected 2026-10-09T03:12:00Z (delta -28800s)
# The wall-clock offset is the system clock minus Lull's trusted time; a large
# value means someone changed the clock (enforcement ignores it either way).
STATUS=/var/db/lull/status.json
SYNC_WARN_AFTER=$((24 * 3600))
OFFSET_WARN=300

result() { echo "<result>$1</result>"; exit 0; }
get() { /usr/bin/plutil -extract "$1" raw -o - "$STATUS" 2>/dev/null; }
[[ -f "$STATUS" ]] || result "ERROR: no status file"

status=$(get time.status)
server=$(get time.lastSyncServer)
offset=$(get time.wallClockOffsetSeconds)
offset=${offset%.*}
tamper=$(get time.lastTamper.observedWall)
delta=$(get time.lastTamper.delta)
last=$(get time.lastSync)
problems=()

if [[ -n "$last" ]]; then
    last_epoch=$(/bin/date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$last" +%s 2>/dev/null)
    ago=$(( $(/bin/date +%s) - ${last_epoch:-0} ))
    (( ago < 0 )) && ago=0
    if (( ago >= 86400 )); then pretty="$((ago / 86400))d"; elif (( ago >= 3600 )); then pretty="$((ago / 3600))h"; else pretty="$((ago / 60))m"; fi
    (( ago > SYNC_WARN_AFTER )) && problems+=("last sync ${pretty} ago")
    summary="synced ${pretty} ago via ${server:-?}"
else
    summary="never synced this boot (status=$status)"
    problems+=("no time sync ($(get time.lastSyncError))")
fi
[[ -n "$tamper" ]] && problems+=("clock tampering detected $tamper (delta ${delta%.*}s)")
[[ -n "$offset" ]] && (( ${offset#-} > OFFSET_WARN )) && problems+=("system clock off by ${offset}s")

if (( ${#problems[@]} > 0 )); then
    joined=$(printf '%s; ' "${problems[@]}")
    result "WARN: ${joined%; } | $summary"
fi
result "OK: $summary, clock offset ${offset:-0}s"
