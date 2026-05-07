#!/bin/bash
# Intel DL Streamer Pipeline - RTSP Object Detection + Classification + FPS Display
# Pipeline: rtsp -> decode -> gvadetect(yolov8) -> gvatrack -> gvaclassify(yolov8-cls) -> fpsdisplaysink

set -e

# Source DL Streamer environment (sets PATH, GST_PLUGIN_PATH, etc.)
if [ -f /opt/intel/dlstreamer/setupvars.sh ]; then
    source /opt/intel/dlstreamer/setupvars.sh
fi

# --- Configuration ---
RTSP_INPUT="${RTSP_INPUT:-rtsp://localhost:8554/stream}"

# Model paths (OpenVINO IR format)
DETECT_MODEL="${DETECT_MODEL:-./models/yolov8n/yolov8n.xml}"
CLASSIFY_MODEL="${CLASSIFY_MODEL:-./models/yolov8n-cls/yolov8n-cls.xml}"

# INT8 quantized model paths (used when PRECISION=INT8)
DETECT_MODEL_INT8="${DETECT_MODEL_INT8:-./models/yolov8n/yolov8n_int8.xml}"
CLASSIFY_MODEL_INT8="${CLASSIFY_MODEL_INT8:-./models/yolov8n-cls/yolov8n-cls_int8.xml}"

# FP16 model paths (used when PRECISION=FP16)
DETECT_MODEL_FP16="${DETECT_MODEL_FP16:-./models/yolov8n/yolov8n_fp16.xml}"
CLASSIFY_MODEL_FP16="${CLASSIFY_MODEL_FP16:-./models/yolov8n-cls/yolov8n-cls_fp16.xml}"

# Inference device: CPU, GPU, or NPU
DEVICE="${DEVICE:-CPU}"

# Inference precision: FP32, FP16, or INT8
PRECISION="${PRECISION:-FP32}"

# Tracker type: short-term, short-term-imageless, zero-term, zero-term-imageless
TRACKER_TYPE="${TRACKER_TYPE:-short-term-imageless}"

# Draw bounding boxes and labels on output: true or false
WATERMARK="${WATERMARK:-true}"

# --- Select models based on precision ---
if [ "$PRECISION" = "INT8" ]; then
    DETECT_MODEL="$DETECT_MODEL_INT8"
    CLASSIFY_MODEL="$CLASSIFY_MODEL_INT8"
elif [ "$PRECISION" = "FP16" ]; then
    DETECT_MODEL="$DETECT_MODEL_FP16"
    CLASSIFY_MODEL="$CLASSIFY_MODEL_FP16"
fi

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

echo "=== Intel DL Streamer Pipeline (Display) ==="
echo "Input:       $RTSP_INPUT"
echo "Output:      fpsdisplaysink"
echo "Device:      $DEVICE"
echo "Precision:   $PRECISION"
echo "Detector:    $DETECT_MODEL"
echo "Classifier:  $CLASSIFY_MODEL"
echo "Tracker:     $TRACKER_TYPE"
echo "============================================="

# --- Build pipeline based on device ---
if [ "$DEVICE" = "GPU" ]; then
    DECODE="decodebin3 ! vapostproc ! video/x-raw(memory:VAMemory)"
    PRE_PROCESS_BACKEND="va-surface-sharing"
    DETECT_OPTIONS="ie-config=GPU_THROUGHPUT_STREAMS=2 nireq=2"
    MODEL_INSTANCE_ID="detect_shared_gpu0"
elif [ "$DEVICE" = "NPU" ]; then
    DECODE="decodebin3"
    PRE_PROCESS_BACKEND="ie"
    DETECT_OPTIONS=""
    MODEL_INSTANCE_ID="detect_shared_npu0"
else
    DECODE="decodebin3"
    PRE_PROCESS_BACKEND="opencv"
    DETECT_OPTIONS="ie-config=CPU_THROUGHPUT_STREAMS=2 nireq=2"
    MODEL_INSTANCE_ID="detect_shared_cpu0"
fi

# --- Detection element ---
DETECT="gvadetect model=$DETECT_MODEL device=$DEVICE pre-process-backend=$PRE_PROCESS_BACKEND model-instance-id=$MODEL_INSTANCE_ID"
if [ -n "$DETECT_OPTIONS" ]; then
    DETECT="$DETECT $DETECT_OPTIONS"
fi
DETECT="$DETECT threshold=0.5 inference-interval=3 scale-method=fast"

# --- Classification element ---
CLASSIFY="gvaclassify model=$CLASSIFY_MODEL device=$DEVICE pre-process-backend=$PRE_PROCESS_BACKEND"
if [ -n "$DETECT_OPTIONS" ]; then
    CLASSIFY="$CLASSIFY $DETECT_OPTIONS"
fi

# --- Tracker element ---
TRACK="gvatrack tracking-type=$TRACKER_TYPE"

# --- Watermark element (bounding boxes + labels) ---
if [ "$WATERMARK" = "true" ]; then
    WATERMARK_ELEMENT="gvawatermark"
else
    WATERMARK_ELEMENT=""
fi

# --- Run the pipeline ---
gst-launch-1.0 -v \
    rtspsrc location="$RTSP_INPUT" latency=100 protocols=tcp ! \
    rtph264depay ! \
    $DECODE ! \
    $DETECT ! \
    $TRACK ! \
    $CLASSIFY ! \
    ${WATERMARK_ELEMENT:+$WATERMARK_ELEMENT !} \
    vapostproc ! \
    fpsdisplaysink video-sink=autovideosink signal-fps-measurements=true text-overlay=true sync=false
