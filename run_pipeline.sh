#!/bin/bash
# Intel DL Streamer Pipeline - RTSP Object Detection + Classification + Re-stream
# Equivalent to DeepStream: rtsp -> nvinfer(yolov8 detect) -> nvtracker -> nvinfer(yolov8 classify) -> encode -> udpsink

set -e

# Source DL Streamer environment (sets PATH, GST_PLUGIN_PATH, etc.)
if [ -f /opt/intel/dlstreamer/setupvars.sh ]; then
    source /opt/intel/dlstreamer/setupvars.sh
fi

# --- Configuration ---
RTSP_INPUT="${RTSP_INPUT:-rtsp://localhost:8554/stream}"
OUTPUT_HOST="${OUTPUT_HOST:-224.1.1.1}"
OUTPUT_PORT="${OUTPUT_PORT:-5000}"

# Model paths (OpenVINO IR format)
DETECT_MODEL="${DETECT_MODEL:-./models/yolov8n/yolov8n.xml}"
CLASSIFY_MODEL="${CLASSIFY_MODEL:-./models/yolov8n-cls/yolov8n-cls.xml}"

# Model proc files (label mappings and preprocessing config)
DETECT_MODEL_PROC="${DETECT_MODEL_PROC:-./models/yolov8n/yolov8n.json}"
CLASSIFY_MODEL_PROC="${CLASSIFY_MODEL_PROC:-./models/yolov8n-cls/yolov8n-cls.json}"

# Inference device: CPU, GPU, or NPU
DEVICE="${DEVICE:-CPU}"

# Tracker type: short-term, short-term-imageless, zero-term, zero-term-imageless
TRACKER_TYPE="${TRACKER_TYPE:-short-term-imageless}"

# Encoding quality (1-51, lower=better quality)
ENCODE_QUALITY="${ENCODE_QUALITY:-20}"

# --- Validate models exist ---
if [ ! -f "$DETECT_MODEL" ]; then
    echo "ERROR: Detection model not found at: $DETECT_MODEL"
    echo "Run ./download_models.sh to download and convert models."
    exit 1
fi

if [ ! -f "$CLASSIFY_MODEL" ]; then
    echo "ERROR: Classification model not found at: $CLASSIFY_MODEL"
    echo "Run ./download_models.sh to download and convert models."
    exit 1
fi

echo "=== Intel DL Streamer Pipeline ==="
echo "Input:       $RTSP_INPUT"
echo "Output:      udp://$OUTPUT_HOST:$OUTPUT_PORT"
echo "Device:      $DEVICE"
echo "Detector:    $DETECT_MODEL"
echo "Classifier:  $CLASSIFY_MODEL"
echo "Tracker:     $TRACKER_TYPE"
echo "=================================="

# --- Build pipeline based on device ---
if [ "$DEVICE" = "GPU" ]; then
    # GPU-accelerated pipeline using VA-API
    DECODE="vaapih264dec ! vaapipostproc ! video/x-raw,format=BGRx"
    ENCODE="vaapipostproc ! video/x-raw,format=NV12 ! vaapih264enc rate-control=cbr bitrate=4000"
elif [ "$DEVICE" = "NPU" ]; then
    # NPU inference with software decode/encode (NPU handles inference only)
    DECODE="avdec_h264 ! videoconvert ! video/x-raw,format=BGRx"
    ENCODE="videoconvert ! video/x-raw,format=NV12 ! x264enc tune=zerolatency bitrate=4000 speed-preset=ultrafast"
else
    # CPU pipeline using software decode/encode
    DECODE="avdec_h264 ! videoconvert ! video/x-raw,format=BGRx"
    ENCODE="videoconvert ! video/x-raw,format=NV12 ! x264enc tune=zerolatency bitrate=4000 speed-preset=ultrafast"
fi

# --- Detection element ---
DETECT="gvadetect model=$DETECT_MODEL device=$DEVICE"
if [ "$DEVICE" = "NPU" ]; then
    DETECT="$DETECT nireq=4 batch-size=1"
fi
if [ -f "$DETECT_MODEL_PROC" ]; then
    DETECT="$DETECT model-proc=$DETECT_MODEL_PROC"
fi
DETECT="$DETECT threshold=0.5"

# --- Classification element ---
CLASSIFY="gvaclassify model=$CLASSIFY_MODEL device=$DEVICE"
if [ "$DEVICE" = "NPU" ]; then
    CLASSIFY="$CLASSIFY nireq=4 batch-size=1"
fi
if [ -f "$CLASSIFY_MODEL_PROC" ]; then
    CLASSIFY="$CLASSIFY model-proc=$CLASSIFY_MODEL_PROC"
fi

# --- Tracker element ---
TRACK="gvatrack tracking-type=$TRACKER_TYPE"

# --- Run the pipeline ---
gst-launch-1.0 -v \
    rtspsrc location="$RTSP_INPUT" latency=100 ! \
    rtph264depay ! \
    h264parse ! \
    $DECODE ! \
    $DETECT ! \
    $TRACK ! \
    $CLASSIFY ! \
    $ENCODE ! \
    queue max-size-buffers=1 leaky=downstream ! \
    h264parse ! \
    rtph264pay config-interval=1 pt=96 ! \
    udpsink host="$OUTPUT_HOST" port="$OUTPUT_PORT" sync=false
