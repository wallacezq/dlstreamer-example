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
    base=$(basename "$f")
    name="${base%.*}"
    ext="${base##*.}"
    mv "$f" "$DETECT_DIR/${name}_fp16.${ext}"
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
    base=$(basename "$f")
    name="${base%.*}"
    ext="${base##*.}"
    mv "$f" "$CLASSIFY_DIR/${name}_fp16.${ext}"
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

echo "Classification model saved to: $CLASSIFY_DIR"

# --- Inject model_info into OpenVINO IR XML files (replaces legacy model-proc) ---
# DL Streamer reads <model_info> from <rt_info> in the XML when model-proc is not specified.
# See: https://docs.openedgeplatform.intel.com/dev/edge-ai-libraries/dlstreamer/dev_guide/model_info_xml.html
echo ""
echo "=== Injecting model_info into OpenVINO IR XML files ==="
python3 << 'PYEOF'
import xml.etree.ElementTree as ET
import os

COCO_LABELS = (
    "person bicycle car motorcycle airplane bus train truck boat "
    "traffic_light fire_hydrant stop_sign parking_meter bench "
    "bird cat dog horse sheep cow elephant bear zebra giraffe "
    "backpack umbrella handbag tie suitcase frisbee skis snowboard "
    "sports_ball kite baseball_bat baseball_glove skateboard surfboard "
    "tennis_racket bottle wine_glass cup fork knife spoon bowl "
    "banana apple sandwich orange broccoli carrot hot_dog pizza donut cake "
    "chair couch potted_plant bed dining_table toilet tv laptop mouse remote "
    "keyboard cell_phone microwave oven toaster sink refrigerator "
    "book clock vase scissors teddy_bear hair_drier toothbrush"
)

def inject_model_info(xml_path, fields):
    """Inject or update <model_info> in OpenVINO IR XML <rt_info> section."""
    tree = ET.parse(xml_path)
    root = tree.getroot()

    rt_info = root.find('rt_info')
    if rt_info is None:
        rt_info = ET.SubElement(root, 'rt_info')

    # Remove existing model_info to avoid conflicts with Ultralytics metadata
    existing = rt_info.find('model_info')
    if existing is not None:
        rt_info.remove(existing)

    model_info = ET.SubElement(rt_info, 'model_info')
    for key, value in fields.items():
        elem = ET.SubElement(model_info, key)
        elem.set('value', str(value))

    tree.write(xml_path, xml_declaration=True, encoding='utf-8')
    print(f"  Injected model_info into: {xml_path}")

# YOLOv8 detection model config
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

# YOLOv8 classification model config
classify_fields = {
    "model_type": "label",
    "resize_type": "standard",
    "reverse_input_channels": "True",
    "scale_values": "255",
}

for xml_name in ["yolov8n.xml", "yolov8n_fp16.xml", "yolov8n_int8.xml"]:
    xml_path = os.path.join("./models/yolov8n", xml_name)
    if os.path.exists(xml_path):
        inject_model_info(xml_path, detect_fields)

for xml_name in ["yolov8n-cls.xml", "yolov8n-cls_fp16.xml", "yolov8n-cls_int8.xml"]:
    xml_path = os.path.join("./models/yolov8n-cls", xml_name)
    if os.path.exists(xml_path):
        inject_model_info(xml_path, classify_fields)

print("model_info injection complete.")
PYEOF

echo ""
echo "=== All models downloaded and converted ==="
echo "Detection model (FP32):      $DETECT_DIR/yolov8n.xml"
echo "Detection model (FP16):      $DETECT_DIR/yolov8n_fp16.xml"
echo "Detection model (INT8):      $DETECT_DIR/yolov8n_int8.xml"
echo "Classification model (FP32): $CLASSIFY_DIR/yolov8n-cls.xml"
echo "Classification model (FP16): $CLASSIFY_DIR/yolov8n-cls_fp16.xml"
echo "Classification model (INT8): $CLASSIFY_DIR/yolov8n-cls_int8.xml"
