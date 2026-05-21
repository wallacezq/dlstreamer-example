# DL Streamer Pipeline

An Intel DL Streamer-based video analytics pipeline that performs real-time object detection, tracking, and classification on an RTSP input stream using YOLO models converted to OpenVINO IR format.

## Pipeline Overview

```
RTSP Input → Decode → YOLO Detection → Tracker → YOLO Classification → Encode → UDP Output
```

- **Detection**: YOLOv8n or YOLO26n (OpenVINO) for object detection
- **Tracking**: GStreamer VA tracker (short-term-imageless by default)
- **Classification**: YOLOv8n-cls or YOLO26n-cls (OpenVINO) for object classification
- **Output**: H.264 RTP stream over UDP (multicast)

## Requirements

- Docker and Docker Compose
- (Optional) Intel GPU or NPU for hardware-accelerated inference

## Quick Start

```bash
# Build and run the pipeline (default: yolov8)
docker compose up --build

# Build with YOLO26 model
MODEL=yolo26 docker compose up --build

# Or run with a test RTSP source (generates a synthetic stream)
docker compose --profile test up --build
```

## Configuration

Configuration is done via environment variables (set in `.env` or passed to `docker compose`):

| Variable | Default | Description |
|----------|---------|-------------|
| `MODEL` | `yolov8` | Model family: `yolov8` or `yolo26` |
| `RTSP_INPUT` | `rtsp://localhost:8554/stream` | Input RTSP stream URL |
| `OUTPUT_HOST` | `224.1.1.1` | UDP output host (multicast address) |
| `OUTPUT_PORT` | `5000` | UDP output port |
| `DEVICE` | `CPU` | Inference device: `CPU`, `GPU`, or `NPU` |
| `PRECISION` | `FP32` | Model precision: `FP32`, `FP16`, or `INT8` |
| `TRACKER_TYPE` | `short-term-imageless` | Tracker type: `short-term`, `short-term-imageless`, `zero-term`, `zero-term-imageless` |

Example:

```bash
# YOLOv8 on GPU
RTSP_INPUT=rtsp://192.168.1.100:554/cam1 DEVICE=GPU docker compose up

# YOLO26 on CPU with FP16 precision
MODEL=yolo26 PRECISION=FP16 docker compose up --build
```

## Project Structure

| File | Purpose |
|------|---------|
| `Dockerfile` | Builds the pipeline image from `intel/dlstreamer:2026.0.0-ubuntu24` with YOLO models |
| `docker-compose.yml` | Service definitions for the pipeline and optional test RTSP source |
| `download_models.sh` | Downloads and converts YOLO models to OpenVINO IR format (supports yolov8, yolo26) |
| `run_pipeline.sh` | Constructs and launches the GStreamer pipeline (UDP output) |
| `run_pipeline_display.sh` | Launches the pipeline with local FPS display sink |

## Running the Display Pipeline

`run_pipeline_display.sh` runs the same detection → tracking → classification pipeline but outputs to a local window with real-time FPS overlay instead of UDP. This is useful for development, debugging, and benchmarking.

```bash
# Basic usage (requires X11 or Wayland display)
./run_pipeline_display.sh

# With custom RTSP source
RTSP_INPUT=rtsp://192.168.1.100:554/cam1 ./run_pipeline_display.sh

# Use YOLO26 model
MODEL=yolo26 ./run_pipeline_display.sh

# GPU-accelerated inference with FP16 precision
DEVICE=GPU PRECISION=FP16 ./run_pipeline_display.sh

# INT8 quantized inference on CPU
PRECISION=INT8 ./run_pipeline_display.sh

# Disable bounding box overlay
WATERMARK=false ./run_pipeline_display.sh
```

The display pipeline supports the same `MODEL`, `DEVICE`, `PRECISION`, `TRACKER_TYPE`, and `WATERMARK` environment variables as `run_pipeline.sh`. It does not use `OUTPUT_HOST`/`OUTPUT_PORT` since it renders locally via `fpsdisplaysink`.

> **Note**: A display server (X11/Wayland) must be available. When running inside Docker, pass through the display with `-e DISPLAY=$DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix`.

## Serving a Local Video as RTSP Stream (MediaMTX)

To test the pipeline with a local video file, use [MediaMTX](https://github.com/bluenviron/mediamtx) as an RTSP server and FFmpeg to push the video.

### 1. Start MediaMTX

```bash
docker run --rm -d --name mediamtx --network host bluenviron/mediamtx:latest
```

### 2. Stream a Local Video File

```bash
# Loop a local video file and publish it as an RTSP stream
ffmpeg -re -stream_loop -1 -i /path/to/your/video.mp4 \
    -c:v libx264 -preset ultrafast -tune zerolatency \
    -f rtsp rtsp://localhost:8554/stream
```

Replace `/path/to/your/video.mp4` with the path to your video file.

### 3. Run the Pipeline

```bash
RTSP_INPUT=rtsp://127.0.0.1:8554/stream ./run_pipeline_display.sh
```

### Generate a Synthetic Test Stream (No Video File Needed)

If you don't have a video file, FFmpeg can generate a test pattern:

```bash
ffmpeg -re -f lavfi -i testsrc=size=1920x1080:rate=30 \
    -c:v libx264 -preset ultrafast -tune zerolatency \
    -f rtsp rtsp://localhost:8554/stream
```

### Stop MediaMTX

```bash
docker stop mediamtx
```

## Receiving the Output Stream

The pipeline outputs an RTP/H.264 stream via UDP. To view it with `ffplay`:

```bash
ffplay -protocol_whitelist file,udp,rtp -i <(echo -e "v=0\nm=video 5000 RTP/AVP 96\nc=IN IP4 127.0.0.1\na=rtpmap:96 H264/90000")
```

Or with GStreamer:

```bash
gst-launch-1.0 udpsrc address=127.0.0.1 port=5000 ! application/x-rtp,encoding-name=H264 ! rtph264depay ! decodebin ! autovideosink
```

## Running Without Docker

### Install Intel DL Streamer

```bash
# Add Intel GPG keys
sudo -E wget -O- https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB | gpg --dearmor | sudo tee /usr/share/keyrings/intel-gpg-archive-keyring.gpg > /dev/null
sudo -E wget -O- https://apt.repos.intel.com/edgeai/dlstreamer/GPG-PUB-KEY-INTEL-DLS.gpg | sudo tee /usr/share/keyrings/dls-archive-keyring.gpg > /dev/null

# Add DL Streamer and OpenVINO APT repositories (Ubuntu 24 shown; replace "ubuntu24" with "ubuntu22" for Ubuntu 22.04)
echo "deb [signed-by=/usr/share/keyrings/dls-archive-keyring.gpg] https://apt.repos.intel.com/edgeai/dlstreamer/ubuntu24 ubuntu24 main" | sudo tee /etc/apt/sources.list.d/intel-dlstreamer.list
sudo bash -c 'echo "deb [signed-by=/usr/share/keyrings/intel-gpg-archive-keyring.gpg] https://apt.repos.intel.com/openvino ubuntu24 main" | sudo tee /etc/apt/sources.list.d/intel-openvino.list'

# Install DL Streamer (also installs OpenVINO and GStreamer as dependencies)
sudo apt-get update
sudo apt-get install -y intel-dlstreamer

# Set up the environment (add to ~/.bashrc for persistence)
source /opt/intel/dlstreamer/scripts/setup_dls_env.sh
```

### Install Python Dependencies

```bash
pip3 install openvino==2026.1.0 ultralytics openvino-dev nncf
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

## Troubleshooting with GST_DEBUG

GStreamer provides a built-in debug logging system controlled by the `GST_DEBUG` environment variable. Set it before running a pipeline to get detailed diagnostic output when something fails.

### Debug Levels

| Level | Name | Description |
|-------|------|-------------|
| 0 | none | No output |
| 1 | ERROR | Logs errors (fatal issues that stop the pipeline) |
| 2 | WARNING | Logs warnings and errors |
| 3 | FIXME | Logs fixme messages, warnings, and errors |
| 4 | INFO | Logs informational messages |
| 5 | DEBUG | Logs full debug output |
| 6 | LOG | Logs everything including very verbose internal details |
| 7 | TRACE | Logs all trace-level messages |

### Usage Examples

```bash
# Enable error + warning output for the entire pipeline
GST_DEBUG=2 ./run_pipeline.sh

# Enable debug output only for DL Streamer inference elements
GST_DEBUG=GVA*:5 ./run_pipeline_display.sh

# Debug specific elements (detection + decoding)
GST_DEBUG=gvadetect:5,decodebin:4 ./run_pipeline.sh

# Combine a base level with element-specific overrides
GST_DEBUG=2,gvadetect:5,gvaclassify:5,gvatrack:4 ./run_pipeline_display.sh

# Log VA-API issues (useful for GPU decode/encode problems)
GST_DEBUG=2,va*:5 DEVICE=GPU ./run_pipeline.sh

# Write debug output to a file instead of stderr
GST_DEBUG=4 GST_DEBUG_FILE=/tmp/gst_debug.log ./run_pipeline.sh
```

### Common Troubleshooting Scenarios

- **Pipeline fails to start**: Use `GST_DEBUG=3` to see negotiation errors (format/caps mismatches between elements).
- **No detections produced**: Use `GST_DEBUG=gvadetect:5` to verify the model loads correctly and produces output tensors.
- **Low FPS / stalls**: Use `GST_DEBUG=GST_PERFORMANCE:5` to identify bottleneck elements.
- **RTSP connection issues**: Use `GST_DEBUG=rtspsrc:5` to trace connection and authentication errors.
- **Model loading errors**: Use `GST_DEBUG=GVA*:4` to see OpenVINO device/model initialization messages.

## Using Custom YOLOv8 Models with Non-COCO Labels

The `download_models.sh` script injects a `<model_info>` section into each OpenVINO IR XML file. DL Streamer reads this metadata at runtime for tensor pre/post-processing, replacing the legacy `model-proc` JSON approach. If you train a custom YOLOv8 model with different classes, you need to update the label list and potentially the model paths in the script.

### Detection Model

Locate the `COCO_LABELS` string and the `detect_fields` dictionary in the model_info injection section of `download_models.sh`:

```python
COCO_LABELS = (
    "person bicycle car motorcycle airplane bus train truck boat "
    "traffic_light fire_hydrant stop_sign parking_meter bench "
    ...
)

detect_fields = {
    "model_type": "yolo_v8",
    "labels": COCO_LABELS,
    "iou_threshold": "0.5",
    "confidence_threshold": "0.5",
    "pad_value": "114",
    "resize_type": "fit_to_window_letterbox",
    "reverse_input_channels": "True",
    "scale_values": "255",
}
```

Replace `COCO_LABELS` with your custom label string. Labels are **space-separated** and must be listed in the same order as your model's class indices:

```python
CUSTOM_LABELS = "hardhat vest gloves boots no_hardhat no_vest"

detect_fields = {
    "model_type": "yolo_v8",
    "labels": CUSTOM_LABELS,
    "iou_threshold": "0.5",
    "confidence_threshold": "0.3",   # adjust to your model's accuracy
    ...
}
```

Also update the model export and file paths if your weights file differs from `yolov8n.pt`:

```python
model = YOLO('my_custom_yolov8.pt')
model.export(format='openvino', imgsz=640, half=False)
```

### Classification Model

Similarly, update `classify_fields` if your classification model uses custom classes. You can add a `labels` field:

```python
classify_fields = {
    "model_type": "label",
    "labels": "class_a class_b class_c",
    "resize_type": "standard",
    "reverse_input_channels": "True",
    "scale_values": "255",
}
```

### Model Info Field Reference

| Field | Type | Description |
|-------|------|-------------|
| `model_type` | string | Output converter: `yolo_v8` for detection, `label` for classification |
| `labels` | string | Space-separated list of class names in class-index order |
| `confidence_threshold` | float | Minimum confidence to report a detection (0.0–1.0) |
| `iou_threshold` | float | NMS IoU threshold (0.0–1.0) |
| `resize_type` | string | Input resize method: `fit_to_window_letterbox`, `standard`, `crop`, `fit_to_window` |
| `pad_value` | int | Padding fill value for letterbox resize (typically `114`) |
| `reverse_input_channels` | bool | Set `True` if model expects RGB input (converts from BGR) |
| `scale_values` | float | Divide pixel values by this number (e.g., `255` to normalize to 0–1) |

For the full specification, see the [DL Streamer Model Info documentation](https://docs.openedgeplatform.intel.com/dev/edge-ai-libraries/dlstreamer/dev_guide/model_info_xml.html).
