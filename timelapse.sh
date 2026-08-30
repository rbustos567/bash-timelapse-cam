#!/usr/bin/env bash

set -uo pipefail

# Script directory and config resolution
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/timelapse.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[ERROR] Configuration file not found at: ${CONFIG_FILE}" >&2
    exit 1
fi

# Load settings
# shellcheck source=./timelapse.conf
source "$CONFIG_FILE"

# Log helper
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Validate END_TIME format (YYYY-MM-DD HH:MM)
if [[ ! "$END_TIME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]; then
    log "[ERROR] Invalid END_TIME format: '${END_TIME}'. Must be 'YYYY-MM-DD HH:MM'."
    exit 1
fi

# Convert END_TIME to UNIX timestamp for accurate cross-day comparison
if ! END_TIMESTAMP=$(date -d "$END_TIME" +%s 2>/dev/null); then
    log "[ERROR] Failed to parse END_TIME date string: '${END_TIME}'."
    exit 1
fi

CURRENT_TIMESTAMP=$(date +%s)
if [[ "$CURRENT_TIMESTAMP" -ge "$END_TIMESTAMP" ]]; then
    log "[ERROR] END_TIME ('${END_TIME}') is already in the past."
    exit 1
fi

# Create root output directory if needed
mkdir -p "$OUTPUT_DIR"

log "Starting multi-day structured timelapse session."
log "Interval: ${INTERVAL_SECONDS}s | End Date/Time: ${END_TIME} | Root Output: ${OUTPUT_DIR}"

SNAPSHOT_COUNT=0

while true; do
    CURRENT_TIMESTAMP=$(date +%s)
    
    # Check stop condition
    if [[ "$CURRENT_TIMESTAMP" -ge "$END_TIMESTAMP" ]]; then
        log "Reached scheduled end date and time (${END_TIME}). Session complete."
        log "Total snapshots captured: ${SNAPSHOT_COUNT}"
        break
    fi

    # Extract date and time parts for nested directory tree
    DAY_DIR=$(date '+%Y-%m-%d')
    HOUR_DIR=$(date '+%H')
    TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

    # Target path structure: OUTPUT_DIR/YYYY-MM-DD/HH/
    TARGET_DIR="${OUTPUT_DIR}/${DAY_DIR}/${HOUR_DIR}"
    mkdir -p "$TARGET_DIR"

    # Export FILENAME so it is accessible in the subshell executed by bash -c
    export FILENAME="${TARGET_DIR}/frame_${TIMESTAMP}.jpg"

    log "Capturing frame: ${FILENAME}"
    
    EXPANDED_CMD=$(eval echo "$CAPTURE_CMD")
    log "Executing command: ${EXPANDED_CMD}"

    # Capture both stdout and stderr from the command
    CMD_OUTPUT=$(bash -c "$CAPTURE_CMD" 2>&1)
    EXIT_CODE=$?

    # Evaluate return code
    if [[ $EXIT_CODE -eq 0 ]]; then
        ((SNAPSHOT_COUNT++))
    else
        log "[WARNING] Capture command failed (exit code ${EXIT_CODE})"
        # Log the actual stderr/stdout output from rpicam-still
        if [[ -n "$CMD_OUTPUT" ]]; then
            log "[CAMERA LOG] ${CMD_OUTPUT}"
        fi
    fi

    sleep "$INTERVAL_SECONDS"
done
