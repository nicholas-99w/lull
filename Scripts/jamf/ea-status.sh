#!/bin/bash
# Jamf Pro Extension Attribute: "Lull Status" (Data type: String).
# Reads /var/db/lull/status.json (world-readable, no secrets) with built-in tools.
#
# Result starts with OK, WARN or ERROR so a Smart Group can use
# "Lull Status" "does not match regex" "^OK" to find unhealthy Macs.
#   OK: phase=normal config=managed
#   WARN: config invalid, enforcing last valid (Schedules[0].Start: ...)
#   ERROR: lulld not running
STATUS=/var/db/lull/status.json
STALE_AFTER=120   # lulld rewrites the file at least every 30s

result() { echo "<result>$1</result>"; exit 0; }
get() { /usr/bin/plutil -extract "$1" raw -o - "$STATUS" 2>/dev/null; }

[[ -d "/Library/Application Support/Lull" ]] || result "ERROR: not installed"
/usr/bin/pgrep -x lulld >/dev/null || result "ERROR: lulld not running"
[[ -f "$STATUS" ]] || result "ERROR: no status file (lulld starting?)"
age=$(( $(/bin/date +%s) - $(/usr/bin/stat -f %m "$STATUS") ))
(( age > STALE_AFTER )) && result "ERROR: status is ${age}s old (lulld hung?)"

phase=$(get phase)
version=$(get version)
source=$(get config.source)
debug=$(get debugBuild)
problems=()
[[ "$debug" == "true" ]] && problems+=("DEBUG build installed")
if [[ "$(get config.hasActiveConfig)" != "true" ]]; then
    result "ERROR: no valid configuration ever received ($(get config.errors.0))"
fi
if [[ "$(get config.currentValid)" != "true" ]]; then
    problems+=("config invalid, enforcing last valid ($(get config.errors.0))")
fi
[[ "$(get time.status)" == "awaitingSync" ]] && problems+=("awaiting time sync")
# Parent portal (only when the profile has a Portal URL). Enforcement doesn't
# depend on it, so this is a warning, never an error.
if [[ -n "$(get portal.url)" ]]; then
    perr=$(get portal.lastError)
    [[ -n "$perr" ]] && problems+=("portal: $perr")
    serr=$(get portal.settingsError)
    [[ -n "$serr" ]] && problems+=("portal settings refused: $serr")
fi
# During warning/locked every non-exempt GUI session must have a connected agent.
if [[ "$phase" == "warning" || "$phase" == "locked" ]]; then
    n=$(get agents)
    for ((i = 0; i < ${n:-0}; i++)); do
        if [[ "$(get agents.$i.connected)" != "true" && "$(get agents.$i.exempt)" != "true" ]]; then
            problems+=("no agent for $(get agents.$i.username)")
        fi
    done
fi

if (( ${#problems[@]} > 0 )); then
    joined=$(printf '%s; ' "${problems[@]}")
    result "WARN: ${joined%; } | phase=$phase v$version"
fi
result "OK: phase=$phase config=$source v$version"
