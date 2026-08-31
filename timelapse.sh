#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/timelapse.conf"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# --- Global Variables ---
TOTAL_CAPTURED=0
END_TIMESTAMP=0

# --- Functions ---

init_phase() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "[ERROR] Configuration file not found at: ${CONFIG_FILE}" >&2
        exit 1
    fi

    source "$CONFIG_FILE"

    # Validate END_TIME format
    if [[ ! "$END_TIME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]; then
        log "[ERROR] Invalid END_TIME format: '${END_TIME}'."
        exit 1
    fi

    if ! END_TIMESTAMP=$(date -d "$END_TIME" +%s 2>/dev/null); then
        log "[ERROR] Failed to parse END_TIME date string: '${END_TIME}'."
        exit 1
    fi

    local current_timestamp
    current_timestamp=$(date +%s)
    if [[ "$current_timestamp" -ge "$END_TIMESTAMP" ]]; then
        log "[ERROR] END_TIME ('${END_TIME}') is already in the past."
        exit 1
    fi

    mkdir -p "$OUTPUT_DIR"
}

capture_phase() {
    log "Starting capture phase."
    log "Interval: ${INTERVAL_SECONDS}s | End Date/Time: ${END_TIME} | Root Output: ${OUTPUT_DIR}"

    TOTAL_CAPTURED=0

    while true; do
        local current_timestamp
        current_timestamp=$(date +%s)

        if [[ "$current_timestamp" -ge "$END_TIMESTAMP" ]]; then
            log "Reached scheduled end date and time (${END_TIME}). Capture session complete."
            log "Total snapshots captured: ${TOTAL_CAPTURED}"
            break
        fi

        local day_dir hour_dir timestamp target_dir
        day_dir=$(date '+%Y-%m-%d')
        hour_dir=$(date '+%H')
        timestamp=$(date '+%Y%m%d_%H%M%S')

        target_dir="${OUTPUT_DIR}/${day_dir}/${hour_dir}"
        mkdir -p "$target_dir"

        export FILENAME="${target_dir}/frame_${timestamp}.jpg"

        local expanded_cmd cmd_output exit_code
        expanded_cmd=$(eval echo "$CAPTURE_CMD")
        log "Executing capture: ${expanded_cmd}"

        cmd_output=$(bash -c "$CAPTURE_CMD" 2>&1)
        exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            ((TOTAL_CAPTURED++))
        else
            log "[WARNING] Capture command failed with exit code ${exit_code}"
            if [[ -n "$cmd_output" ]]; then
                log "[CAMERA LOG] ${cmd_output}"
            fi
        fi

        sleep "$INTERVAL_SECONDS"
    done
}

render_phase() {
    if [[ "${RENDER_VIDEO:-false}" != "true" ]]; then
        log "Video rendering is disabled in config. Skipping."
        return 0
    fi

    if [[ "$TOTAL_CAPTURED" -eq 0 ]]; then
        log "[WARNING] No snapshots were captured. Skipping video rendering."
        return 0
    fi

    export CONCAT_LIST="${OUTPUT_DIR}/concat_list.txt"
    export VIDEO_OUTPUT
    export OUTPUT_DIR

    # Log the exact find/sed command used to build the manifest
    local manifest_cmd="find \"$OUTPUT_DIR\" -type f -name \"*.jpg\" | sort | sed \"s/^/file '/;s/$/'/\" > \"$CONCAT_LIST\""
    log "Generating sorted image manifest file..."
    log "Executing manifest command: ${manifest_cmd}"

    find "$OUTPUT_DIR" -type f -name "*.jpg" | sort | sed "s/^/file '/;s/$/'/" > "$CONCAT_LIST"

    if [[ ! -s "$CONCAT_LIST" ]]; then
        log "[ERROR] Image list file is empty. Skipping video rendering."
        rm -f "$CONCAT_LIST"
        return 1
    fi

    # Expand variables inside RENDER_CMD for logging
    local expanded_render_cmd
    expanded_render_cmd=$(eval echo "$RENDER_CMD")
    log "Starting video rendering phase..."
    log "Executing render command: ${expanded_render_cmd}"

    local render_log render_exit_code
    render_log=$(bash -c "$RENDER_CMD" 2>&1)
    render_exit_code=$?

    # Clean up temporary manifest file
    rm -f "$CONCAT_LIST"

    if [[ $render_exit_code -eq 0 ]]; then
        log "[SUCCESS] Video compiled successfully: ${VIDEO_OUTPUT}"
    else
        log "[ERROR] Video rendering failed with exit code ${render_exit_code}"
        if [[ -n "$render_log" ]]; then
            log "[FFMPEG LOG] ${render_log}"
        fi
    fi
}

# --- Main Flow ---

init_phase
capture_phase
render_phase
