#!/bin/bash
# Download and convert YOLOv8 models to OpenVINO IR format for DL Streamer
# Exports FP32, FP16, and INT8 (NNCF quantized) variants
set -e

MODELS_DIR="./models"
mkdir -p "$MODELS_DIR"

# --- YOLOv8n Detection Model ---
echo ""
echo "=== Exporting YOLOv8n detection model to OpenVINO ==="
DETECT_DIR="$MODELS_DIR/yolov8n"
mkdir -p "$DETECT_DIR"

# FP32 export
python3 -c "
from ultralytics import YOLO
model = YOLO('yolov8n.pt')
model.export(format='openvino', imgsz=640, half=False)
"
mv yolov8n_openvino_model/* "$DETECT_DIR/" 2>/dev/null || true
rm -rf yolov8n_openvino_model

# FP16 export
echo "=== Exporting YOLOv8n detection model (FP16) ==="
python3 -c "
from ultralytics import YOLO
model = YOLO('yolov8n.pt')
model.export(format='openvino', imgsz=640, half=True)
"
# Rename FP16 outputs to avoid overwriting FP32
for f in yolov8n_openvino_model/*; do
    base=\$(basename "\$f")
    name="\${base%.*}"
    ext="\${base##*.}"
    mv "\$f" "$DETECT_DIR/\${name}_fp16.\${ext}"
done
rm -rf yolov8n_openvino_model

# INT8 quantization via NNCF
echo "=== Quantizing YOLOv8n detection model (INT8) ==="
python3 << 'PYEOF'
import openvino as ov
import nncf
import numpy as np

core = ov.Core()
model = core.read_model("./models/yolov8n/yolov8n.xml")

def transform_fn(data_item):
    return {list(model.inputs[0].names)[0]: data_item}

# Synthetic calibration dataset (random images for quantization)
calibration_data = [np.random.rand(1, 3, 640, 640).astype(np.float32) for _ in range(50)]
calibration_dataset = nncf.Dataset(calibration_data, transform_fn)

quantized_model = nncf.quantize(model, calibration_dataset)
ov.save_model(quantized_model, "./models/yolov8n/yolov8n_int8.xml")
print("INT8 detection model saved to: ./models/yolov8n/yolov8n_int8.xml")
PYEOF

rm -f yolov8n.pt

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

# FP32 export
python3 -c "
from ultralytics import YOLO
model = YOLO('yolov8n-cls.pt')
model.export(format='openvino', imgsz=224, half=False)
"
mv yolov8n-cls_openvino_model/* "$CLASSIFY_DIR/" 2>/dev/null || true
rm -rf yolov8n-cls_openvino_model

# FP16 export
echo "=== Exporting YOLOv8n-cls classification model (FP16) ==="
python3 -c "
from ultralytics import YOLO
model = YOLO('yolov8n-cls.pt')
model.export(format='openvino', imgsz=224, half=True)
"
for f in yolov8n-cls_openvino_model/*; do
    base=\$(basename "\$f")
    name="\${base%.*}"
    ext="\${base##*.}"
    mv "\$f" "$CLASSIFY_DIR/\${name}_fp16.\${ext}"
done
rm -rf yolov8n-cls_openvino_model

# INT8 quantization via NNCF
echo "=== Quantizing YOLOv8n-cls classification model (INT8) ==="
python3 << 'PYEOF'
import openvino as ov
import nncf
import numpy as np

core = ov.Core()
model = core.read_model("./models/yolov8n-cls/yolov8n-cls.xml")

def transform_fn(data_item):
    return {list(model.inputs[0].names)[0]: data_item}

# Synthetic calibration dataset (random images for quantization)
calibration_data = [np.random.rand(1, 3, 224, 224).astype(np.float32) for _ in range(50)]
calibration_dataset = nncf.Dataset(calibration_data, transform_fn)

quantized_model = nncf.quantize(model, calibration_dataset)
ov.save_model(quantized_model, "./models/yolov8n-cls/yolov8n-cls_int8.xml")
print("INT8 classification model saved to: ./models/yolov8n-cls/yolov8n-cls_int8.xml")
PYEOF

rm -f yolov8n-cls.pt

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
echo "Detection model (FP32):      $DETECT_DIR/yolov8n.xml"
echo "Detection model (FP16):      $DETECT_DIR/yolov8n_fp16.xml"
echo "Detection model (INT8):      $DETECT_DIR/yolov8n_int8.xml"
echo "Classification model (FP32): $CLASSIFY_DIR/yolov8n-cls.xml"
echo "Classification model (FP16): $CLASSIFY_DIR/yolov8n-cls_fp16.xml"
echo "Classification model (INT8): $CLASSIFY_DIR/yolov8n-cls_int8.xml"
