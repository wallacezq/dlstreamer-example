# DL Streamer Pipeline

An Intel DL Streamer-based video analytics pipeline that performs real-time object detection, tracking, and classification on an RTSP input stream using YOLOv8 models converted to OpenVINO IR format.

## Pipeline Overview

```
RTSP Input → Decode → YOLOv8n Detection → Tracker → YOLOv8n Classification → Encode → UDP Output
```

- **Detection**: YOLOv8n (OpenVINO) for object detection
- **Tracking**: GStreamer VA tracker (short-term-imageless by default)
- **Classification**: YOLOv8n-cls (OpenVINO) for object classification
- **Output**: H.264 RTP stream over UDP (multicast)

## Requirements

- Docker and Docker Compose
- (Optional) Intel GPU or NPU for hardware-accelerated inference

## Quick Start

```bash
# Build and run the pipeline
docker compose up --build

# Or run with a test RTSP source (generates a synthetic stream)
docker compose --profile test up --build
```

## Configuration

Configuration is done via environment variables (set in `.env` or passed to `docker compose`):

| Variable | Default | Description |
|----------|---------|-------------|
| `RTSP_INPUT` | `rtsp://localhost:8554/stream` | Input RTSP stream URL |
| `OUTPUT_HOST` | `224.1.1.1` | UDP output host (multicast address) |
| `OUTPUT_PORT` | `5000` | UDP output port |
| `DEVICE` | `CPU` | Inference device: `CPU`, `GPU`, or `NPU` |
| `TRACKER_TYPE` | `short-term-imageless` | Tracker type: `short-term`, `short-term-imageless`, `zero-term`, `zero-term-imageless` |

Example:

```bash
RTSP_INPUT=rtsp://192.168.1.100:554/cam1 DEVICE=GPU docker compose up
```

## Project Structure

| File | Purpose |
|------|---------|
| `Dockerfile` | Builds the pipeline image from `intel/dlstreamer:2026.0.0-ubuntu24` with YOLOv8 models |
| `docker-compose.yml` | Service definitions for the pipeline and optional test RTSP source |
| `download_models.sh` | Downloads and converts YOLOv8n models to OpenVINO IR format |
| `run_pipeline.sh` | Constructs and launches the GStreamer pipeline |

## Receiving the Output Stream

The pipeline outputs an RTP/H.264 stream via UDP. To view it with `ffplay`:

```bash
ffplay -protocol_whitelist file,udp,rtp -i <(echo -e "v=0\nm=video 5000 RTP/AVP 96\nc=IN IP4 224.1.1.1\na=rtpmap:96 H264/90000")
```

Or with GStreamer:

```bash
gst-launch-1.0 udpsrc address=224.1.1.1 port=5000 ! application/x-rtp,encoding-name=H264 ! rtph264depay ! decodebin ! autovideosink
```

## Running Without Docker

### Install Intel DL Streamer

```bash
# Add Intel APT repository
wget -qO - https://repositories.intel.com/gpu/intel-graphics.key | sudo gpg --dearmor -o /usr/share/keyrings/intel-graphics.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/intel-graphics.gpg] https://repositories.intel.com/gpu/ubuntu jammy unified" | sudo tee /etc/apt/sources.list.d/intel-gpu.list

# Install DL Streamer and dependencies
sudo apt-get update
sudo apt-get install -y intel-dlstreamer opencv-python3-openvino

# Set up the environment (add to ~/.bashrc for persistence)
source /opt/intel/dlstreamer/setupvars.sh
```

### Install Python Dependencies

```bash
pip3 install ultralytics openvino-dev nncf
```

### Download Models and Run

```bash
./download_models.sh
./run_pipeline.sh
```

For full installation details, see the [Intel DL Streamer documentation](https://dlstreamer.github.io/get_started/install/install_guide_ubuntu.html).

## Hardware Acceleration

- **CPU** (default): Software decode/encode, OpenVINO CPU inference
- **GPU**: VA-API decode/encode, OpenVINO GPU inference (requires `/dev/dri` access)
- **NPU**: Software decode/encode, OpenVINO NPU inference (requires `/dev/accel` access)
