# Automated Raspberry Pi Time-Lapse & Remote Video Renderer
```text
An automated Bash pipeline for Raspberry Pi that captures time-lapse photographs at scheduled intervals organized by date (YYYY-MM-DD/HH/) and compiles an .mp4 video using FFmpeg. It supports local compilation as well as remote rendering via SSH to offload heavy processing to a more powerful server/NAS, followed by an optional final storage deployment phase.
```
## Installation
```bash
git clone https://github.com/rbustos567/webpage-to-eink.git
cd webpage-to-eink
chmod +x install.sh
sudo ./install.sh
```
## Command Execution Examples
### Save processed snapshot to disk
```bash
python3 web_to_eink.py https://www.bbc.com --width 800 --height 480 --output /tmp/newspaper.png
```
### Render directly to attached Waveshare 7.5" V2 panel
```bash
python3 web_to_eink.py https://www.bbc.com --width 800 --height 480 --model epd7in5_V2 --display
```
