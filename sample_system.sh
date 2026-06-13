#!/usr/bin/env bash

PID="${1:-}"
OUTPUT_CSV="${2:-}"
INTERVAL="${3:-1}"

if [ -z "$PID" ] || [ -z "$OUTPUT_CSV" ]; then
    echo "Usage: $0 <PID> <output_csv> [interval_seconds]" >&2
    exit 1
fi

PAGE_SIZE=$(pagesize)

pages_to_mb() {
    awk -v p="${1:-0}" -v s="$PAGE_SIZE" 'BEGIN {printf "%.2f", p * s / 1048576}'
}

get_vm_field() {
    printf '%s\n' "$VM" | awk -v k="$1" 'index($0, k) == 1 {gsub(/\.$/, "", $NF); print $NF + 0}'
}

printf 'ts,pid,cpu_percent,rss_mb,vsz_mb,threads,free_mb,active_mb,inactive_mb,wired_mb,compressed_mb,swapins,swapouts\n' > "$OUTPUT_CSV"

while kill -0 "$PID" 2>/dev/null; do
    TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    PS_LINE=$(ps -p "$PID" -o pid=,%cpu=,rss=,vsz= 2>/dev/null) || break
    [ -z "$PS_LINE" ] && break

    read -r _pid CPU_PCT RSS_KB VSZ_KB <<< "$PS_LINE"
    RSS_MB=$(awk -v k="${RSS_KB:-0}" 'BEGIN {printf "%.2f", k / 1024}')
    VSZ_MB=$(awk -v k="${VSZ_KB:-0}" 'BEGIN {printf "%.2f", k / 1024}')
    THREADS=$(ps -p "$PID" -M 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')

    VM=$(vm_stat 2>/dev/null)

    FREE_MB=$(pages_to_mb "$(get_vm_field 'Pages free:')")
    ACTIVE_MB=$(pages_to_mb "$(get_vm_field 'Pages active:')")
    INACTIVE_MB=$(pages_to_mb "$(get_vm_field 'Pages inactive:')")
    WIRED_MB=$(pages_to_mb "$(get_vm_field 'Pages wired down:')")
    COMPRESSED_MB=$(pages_to_mb "$(get_vm_field 'Pages occupied by compressor:')")
    SWAPINS=$(get_vm_field 'Swapins:')
    SWAPOUTS=$(get_vm_field 'Swapouts:')

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$TS" "$PID" "${CPU_PCT:-0}" "$RSS_MB" "$VSZ_MB" "${THREADS:-0}" \
        "$FREE_MB" "$ACTIVE_MB" "$INACTIVE_MB" "$WIRED_MB" "$COMPRESSED_MB" \
        "${SWAPINS:-0}" "${SWAPOUTS:-0}" >> "$OUTPUT_CSV"

    sleep "$INTERVAL"
done
