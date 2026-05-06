#!/bin/bash
# Download and convert YOLOv8 models to OpenVINO IR format for DL Streamer
set -e

MODELS_DIR="./models"
mkdir -p "$MODELS_DIR"

# --- YOLOv8n Detection Model ---
echo ""
echo "=== Exporting YOLOv8n detection model to OpenVINO ==="
DETECT_DIR="$MODELS_DIR/yolov8n"
mkdir -p "$DETECT_DIR"

python3 -c "
from ultralytics import YOLO
model = YOLO('yolov8n.pt')
model.export(format='openvino', imgsz=640, half=False)
"
mv yolov8n_openvino_model/* "$DETECT_DIR/" 2>/dev/null || true
rm -rf yolov8n_openvino_model yolov8n.pt

# Create model-proc file for detection
cat > "$DETECT_DIR/yolov8n.json" << 'EOF'
{
  "json_schema_version": "2.2.0",
  "input_preproc": [
    {
      "layer_name": "images",
      "format": "image",
      "params": {
        "resize": "aspect-ratio",
        "color_format": "BGR"
      }
    }
  ],
  "output_postproc": [
    {
      "converter": "yolo_v8",
      "confidence_threshold": 0.5,
      "iou_threshold": 0.5
    }
  ]
}
EOF

echo "Detection model saved to: $DETECT_DIR"

# --- YOLOv8n Classification Model ---
echo ""
echo "=== Exporting YOLOv8n-cls classification model to OpenVINO ==="
CLASSIFY_DIR="$MODELS_DIR/yolov8n-cls"
mkdir -p "$CLASSIFY_DIR"

python3 -c "
from ultralytics import YOLO
model = YOLO('yolov8n-cls.pt')
model.export(format='openvino', imgsz=224, half=False)
"
mv yolov8n-cls_openvino_model/* "$CLASSIFY_DIR/" 2>/dev/null || true
rm -rf yolov8n-cls_openvino_model yolov8n-cls.pt

# Create model-proc file for classification
cat > "$CLASSIFY_DIR/yolov8n-cls.json" << 'EOF'
{
  "json_schema_version": "2.2.0",
  "input_preproc": [
    {
      "layer_name": "images",
      "format": "image",
      "params": {
        "resize": "aspect-ratio",
        "color_format": "BGR"
      }
    }
  ],
  "output_postproc": [
    {
      "converter": "label",
      "method": "max",
      "attribute_name": "classification"
    }
  ]
}
EOF

echo "Classification model saved to: $CLASSIFY_DIR"

echo ""
echo "=== All models downloaded and converted ==="
echo "Detection model:     $DETECT_DIR/yolov8n.xml"
echo "Classification model: $CLASSIFY_DIR/yolov8n-cls.xml"
