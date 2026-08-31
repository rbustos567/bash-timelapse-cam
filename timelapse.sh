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

render_local() {
    export CONCAT_LIST="${OUTPUT_DIR}/concat_list.txt"
    export VIDEO_OUTPUT
    export OUTPUT_DIR

    local manifest_cmd="find \"$OUTPUT_DIR\" -type f -name \"*.jpg\" | sort | sed \"s/^/file '/;s/$/'/\" > \"$CONCAT_LIST\""
    log "[LOCAL] Generating sorted image manifest file..."
    log "[LOCAL] Executing manifest command: ${manifest_cmd}"

    find "$OUTPUT_DIR" -type f -name "*.jpg" | sort | sed "s/^/file '/;s/$/'/" > "$CONCAT_LIST"

    if [[ ! -s "$CONCAT_LIST" ]]; then
        log "[ERROR] Image list file is empty. Skipping local video rendering."
        rm -f "$CONCAT_LIST"
        return 1
    fi

    local expanded_render_cmd
    expanded_render_cmd=$(eval echo "$RENDER_CMD")
    log "[LOCAL] Starting local video rendering phase..."
    log "[LOCAL] Executing render command: ${expanded_render_cmd}"

    local render_log render_exit_code
    render_log=$(bash -c "$RENDER_CMD" 2>&1)
    render_exit_code=$?

    rm -f "$CONCAT_LIST"

    if [[ $render_exit_code -eq 0 ]]; then
        log "[SUCCESS] Local video compiled successfully: ${VIDEO_OUTPUT}"
    else
        log "[ERROR] Local video rendering failed with exit code ${render_exit_code}"
        if [[ -n "$render_log" ]]; then
            log "[FFMPEG LOG] ${render_log}"
        fi
    fi
}

execute_remote_cmd() {
    local ssh_key="$1"
    local port="$2"
    local user="$3"
    local host="$4"
    local cmd="$5"

    local ssh_opts="-i ${ssh_key} -P ${port} -o StrictHostKeyChecking=accept-new"
    local remote_target="${user}@${host}"

    log "[REMOTE EXEC] Running: ${cmd}"

    local remote_output exit_code
    remote_output=$(ssh $ssh_opts "$remote_target" "$cmd" 2>&1)
    exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log "[ERROR] Remote command failed (exit code ${exit_code})"
        if [[ -n "$remote_output" ]]; then
            log "[REMOTE LOG] ${remote_output}"
        fi
        return "$exit_code"
    fi

    return 0
}

render_remote() {
    local remote_target="${REMOTE_USER}@${REMOTE_HOST}"
    local remote_video_name
    remote_video_name=$(basename "$VIDEO_OUTPUT")

    log "[REMOTE] Initializing granular remote render pipeline on ${remote_target}..."

    # Step 1: Create remote working directory
    log "[REMOTE] Step 1/5: Creating remote working directory..."
    if ! execute_remote_cmd "$REMOTE_SSH_KEY" "$REMOTE_PORT" "$REMOTE_USER" "$REMOTE_HOST" "mkdir -p '${REMOTE_WORK_DIR}/images'"; then
        log "[ERROR] Failed to create remote directory structure."
        return 1
    fi

    # Step 2: Stream images via TAR
    log "[REMOTE] Step 2/5: Streaming image archive via tar..."
    local ssh_opts="-i ${REMOTE_SSH_KEY} -p ${REMOTE_PORT} -o StrictHostKeyChecking=accept-new"
    local tar_pipe_cmd="tar -cf - -C \"$OUTPUT_DIR\" . | ssh $ssh_opts \"$remote_target\" \"tar -xf - -C '${REMOTE_WORK_DIR}/images'\""
    log "[REMOTE EXEC] Running: ${tar_pipe_cmd}"

    local stream_output stream_exit_code
    stream_output=$(tar -cf - -C "$OUTPUT_DIR" . | ssh $ssh_opts "$remote_target" "tar -xf - -C '${REMOTE_WORK_DIR}/images'" 2>&1)
    stream_exit_code=$?

    if [[ $stream_exit_code -ne 0 ]]; then
        log "[ERROR] Failed to stream images to remote server (exit code ${stream_exit_code})"
        if [[ -n "$stream_output" ]]; then
            log "[REMOTE LOG] ${stream_output}"
        fi
        return 1
    fi

    # Step 3: Generate remote manifest
    log "[REMOTE] Step 3/5: Generating remote image manifest..."
    local manifest_cmd="cd '${REMOTE_WORK_DIR}' && find images -type f -name '*.jpg' | sort | sed \"s/^/file '/;s/$/'/\" > concat_list.txt"
    if ! execute_remote_cmd "$REMOTE_SSH_KEY" "$REMOTE_PORT" "$REMOTE_USER" "$REMOTE_HOST" "$manifest_cmd"; then
        log "[ERROR] Failed to generate remote concat list."
        return 1
    fi

    # Step 4: Execute FFmpeg
    log "[REMOTE] Step 4/5: Compiling video with FFmpeg on remote server..."
    local ffmpeg_cmd="cd '${REMOTE_WORK_DIR}' && ffmpeg -y -f concat -safe 0 -i concat_list.txt -c:v libx264 -pix_fmt yuv420p '${remote_video_name}'"
    if ! execute_remote_cmd "$REMOTE_SSH_KEY" "$REMOTE_PORT" "$REMOTE_USER" "$REMOTE_HOST" "$ffmpeg_cmd"; then
        log "[ERROR] Remote FFmpeg video compilation failed."
        return 1
    fi

    # Step 5: Download compiled video passing ONLY destination directory
    log "[REMOTE] Step 5/5: Downloading compiled MP4 video..."
    mkdir -p "$OUTPUT_DIR"

    # Define specific options for scp (-P uppercase for port)
    local scp_opts="-i ${REMOTE_SSH_KEY} -P ${REMOTE_PORT} -o StrictHostKeyChecking=accept-new"
    local scp_cmd="scp $scp_opts \"${remote_target}:${REMOTE_WORK_DIR}/${remote_video_name}\" \"${OUTPUT_DIR}/\""
    log "[REMOTE EXEC] Running: ${scp_cmd}"

    local download_output download_exit_code
    download_output=$(scp $scp_opts "${remote_target}:${REMOTE_WORK_DIR}/${remote_video_name}" "${OUTPUT_DIR}/" 2>&1)
    download_exit_code=$?

    # Cleanup remote workspace
    execute_remote_cmd "$REMOTE_SSH_KEY" "$REMOTE_PORT" "$REMOTE_USER" "$REMOTE_HOST" "rm -rf '${REMOTE_WORK_DIR}'" >/dev/null 2>&1 || true

    if [[ $download_exit_code -eq 0 ]]; then
        log "[SUCCESS] Remote video rendering completed successfully. Saved at: ${OUTPUT_DIR}/${remote_video_name}"
    else
        log "[ERROR] Failed to download video from remote server (exit code ${download_exit_code})"
        if [[ -n "$download_output" ]]; then
            log "[SCP LOG] ${download_output}"
        fi
        return 1
    fi
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

    if [[ "${REMOTE_RENDER:-false}" == "true" ]]; then
        render_remote
    else
        render_local
    fi
}

storage_phase() {
    if [[ "${STORAGE_ENABLE:-false}" != "true" ]]; then
        log "Final video storage relocation is disabled in config. Skipping."
        return 0
    fi

    local video_file_name
    video_file_name=$(basename "$VIDEO_OUTPUT")
    local local_compiled_file="${OUTPUT_DIR}/${video_file_name}"

    if [[ ! -f "$local_compiled_file" ]]; then
        log "[ERROR] Compiled video file not found at '${local_compiled_file}'. Cannot proceed with storage phase."
        return 1
    fi

    log "Starting final video storage phase..."

    if [[ "${STORAGE_REMOTE:-false}" == "true" ]]; then
        log "[STORAGE] Deploying video to remote storage server (${STORAGE_REMOTE_USER}@${STORAGE_REMOTE_HOST})..."

        # Ensure remote storage directory exists
        if ! execute_remote_cmd "$STORAGE_REMOTE_SSH_KEY" "$STORAGE_REMOTE_PORT" "$STORAGE_REMOTE_USER" "$STORAGE_REMOTE_HOST" "mkdir -p '${STORAGE_REMOTE_DIR}'"; then
            log "[ERROR] Failed to create remote storage directory '${STORAGE_REMOTE_DIR}'."
            return 1
        fi

        local scp_opts="-i ${STORAGE_REMOTE_SSH_KEY} -P ${STORAGE_REMOTE_PORT} -o StrictHostKeyChecking=accept-new"
        local storage_target="${STORAGE_REMOTE_USER}@${STORAGE_REMOTE_HOST}"
        local scp_cmd="scp $scp_opts \"${local_compiled_file}\" \"${storage_target}:${STORAGE_REMOTE_DIR}/\""

        log "[STORAGE] Transferring video file to destination..."
        log "[STORAGE EXEC] Running: ${scp_cmd}"

        local transfer_output transfer_exit_code
        transfer_output=$(scp $scp_opts "${local_compiled_file}" "${storage_target}:${STORAGE_REMOTE_DIR}/" 2>&1)
        transfer_exit_code=$?

        if [[ $transfer_exit_code -eq 0 ]]; then
            log "[SUCCESS] Video deployed to remote storage: ${storage_target}:${STORAGE_REMOTE_DIR}/${video_file_name}"
        else
            log "[ERROR] Failed to transfer video to remote storage (exit code ${transfer_exit_code})"
            if [[ -n "$transfer_output" ]]; then
                log "[SCP LOG] ${transfer_output}"
            fi
            return 1
        fi
    else
        log "[STORAGE] Moving video to local archive directory (${STORAGE_LOCAL_DIR})..."
        mkdir -p "$STORAGE_LOCAL_DIR"

        if mv "$local_compiled_file" "${STORAGE_LOCAL_DIR}/${video_file_name}"; then
            log "[SUCCESS] Video moved to local archive: ${STORAGE_LOCAL_DIR}/${video_file_name}"
        else
            log "[ERROR] Failed to move video to local directory '${STORAGE_LOCAL_DIR}'."
            return 1
        fi
    fi
}

# --- Main Flow ---

init_phase
capture_phase
render_phase
storage_phase
