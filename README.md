# Automated Raspberry Pi Time-Lapse & Remote Video Renderer

An automated Bash pipeline for Raspberry Pi that captures time-lapse photographs at scheduled intervals organized by date (YYYY-MM-DD/HH/) and compiles an .mp4 video using FFmpeg. It supports local compilation as well as remote rendering via SSH to offload heavy processing to a more powerful server/NAS, followed by an optional final storage deployment phase.

## Repository Structure
- timelapse.sh: Executable Bash script that manages the execution lifecycle (capture, render, and storage phases).

- timelapse.conf: Centralized configuration file.

## Prerequisites
- Raspberry Pi: With rpicam-apps (or libcamera) installed.

- FFmpeg & Tar: Installed locally (and on the remote machine if using remote rendering).

- SSH Key Pair (Optional for Remote Mode): If rendering or storing files on a remote host, configure passwordless RSA SSH keys:
```bash
ssh-keygen -t rsa -b 4096 -C "pi-timelapse-key"
ssh-copy-id -i ~/.ssh/id_rsa.pub remote_user@SERVER_IP
```
## Quick Start
1. Clone the repository:
```bash
git clone https://github.com/rbustos567/bash-timelapse-cam.git
cd your-repo
```
2. Grant execution permissions:
```bash
chmod +x timelapse.sh
```
3. Configure parameters:
Edit timelapse.conf to match your environment:

- END_TIME: End timestamp (YYYY-MM-DD HH:MM).

- INTERVAL_SECONDS: Interval between snapshot captures.

- RENDER_VIDEO: Set to true to build the video after capture completes.

- REMOTE_RENDER: true to process FFmpeg on a remote server via SSH, false to render locally on the Pi.

- STORAGE_REMOTE: true to transfer the finished .mp4 to a remote storage server/NAS via SCP.

4. Run the script:
```bash
./timelapse.sh
```
## Execution Pipeline
1. Initialization Phase: Validates configuration paths, timestamp formatting, and directory structures.

2. Capture Phase: Takes snapshots continuously at defined intervals, organizing files into $OUTPUT_DIR/YYYY-MM-DD/HH/frame_TIMESTAMP.jpg.

3. Render Phase:

- Local: Generates a sorted concat_list.txt manifest and compiles the .mp4 video directly on the Pi.

- Remote: Streams captured images over an SSH pipe via tar to the remote machine, executes FFmpeg using the server's CPU/GPU, and downloads the compiled .mp4 file back to the Pi.

4. Storage Phase: Relocates the final video to a designated local archive directory or deploys it to a remote storage server via SCP.
