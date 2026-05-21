#!/bin/bash
# Download and convert YOLO models to OpenVINO IR format for DL Streamer
# Supports: yolov8, yolo26
# Exports FP32, FP16, and INT8 (NNCF quantized) variants
set -e

# MODEL selects which model family to download: yolov8 (default) or yolo26
MODEL="${MODEL:-yolov8}"

MODELS_DIR="./models"
mkdir -p "$MODELS_DIR"

# --- Model name mappings ---
case "$MODEL" in
    yolov8)
        DETECT_NAME="yolov8n"
        CLASSIFY_NAME="yolov8n-cls"
        DETECT_PT="yolov8n.pt"
        CLASSIFY_PT="yolov8n-cls.pt"
        DETECT_IMGSZ=640
        CLASSIFY_IMGSZ=224
        MODEL_TYPE="yolo_v8"
        ;;
    yolo26)
        DETECT_NAME="yolo26n"
        CLASSIFY_NAME="yolo26n-cls"
        DETECT_PT="yolo26n.pt"
        CLASSIFY_PT="yolo26n-cls.pt"
        DETECT_IMGSZ=640
        CLASSIFY_IMGSZ=224
        MODEL_TYPE="yolo_v8"
        ;;
    *)
        echo "ERROR: Unsupported MODEL=$MODEL. Supported: yolov8, yolo26"
        exit 1
        ;;
esac

# --- Detection Model ---
echo ""
echo "=== Exporting $DETECT_NAME detection model to OpenVINO ==="
DETECT_DIR="$MODELS_DIR/$DETECT_NAME"
mkdir -p "$DETECT_DIR"

# FP32 export
python3 -c "
from ultralytics import YOLO
model = YOLO('$DETECT_PT')
model.export(format='openvino', imgsz=$DETECT_IMGSZ, half=False)
"
mv ${DETECT_NAME}_openvino_model/* "$DETECT_DIR/" 2>/dev/null || true
rm -rf ${DETECT_NAME}_openvino_model

# FP16 export
echo "=== Exporting $DETECT_NAME detection model (FP16) ==="
python3 -c "
from ultralytics import YOLO
model = YOLO('$DETECT_PT')
model.export(format='openvino', imgsz=$DETECT_IMGSZ, half=True)
"
# Rename FP16 outputs to avoid overwriting FP32
for f in ${DETECT_NAME}_openvino_model/*; do
    base=$(basename "$f")
    name="${base%.*}"
    ext="${base##*.}"
    mv "$f" "$DETECT_DIR/${name}_fp16.${ext}"
done
rm -rf ${DETECT_NAME}_openvino_model

# INT8 quantization via NNCF
echo "=== Quantizing $DETECT_NAME detection model (INT8) ==="
python3 << PYEOF
import openvino as ov
import nncf
import numpy as np

core = ov.Core()
model = core.read_model("./models/$DETECT_NAME/$DETECT_NAME.xml")

def transform_fn(data_item):
    return {list(model.inputs[0].names)[0]: data_item}

# Synthetic calibration dataset (random images for quantization)
calibration_data = [np.random.rand(1, 3, $DETECT_IMGSZ, $DETECT_IMGSZ).astype(np.float32) for _ in range(50)]
calibration_dataset = nncf.Dataset(calibration_data, transform_fn)

quantized_model = nncf.quantize(model, calibration_dataset)
ov.save_model(quantized_model, "./models/$DETECT_NAME/${DETECT_NAME}_int8.xml")
print("INT8 detection model saved to: ./models/$DETECT_NAME/${DETECT_NAME}_int8.xml")
PYEOF

rm -f "$DETECT_PT"

echo "Detection model saved to: $DETECT_DIR"

# --- Classification Model ---
echo ""
echo "=== Exporting $CLASSIFY_NAME classification model to OpenVINO ==="
CLASSIFY_DIR="$MODELS_DIR/$CLASSIFY_NAME"
mkdir -p "$CLASSIFY_DIR"

# FP32 export
python3 -c "
from ultralytics import YOLO
model = YOLO('$CLASSIFY_PT')
model.export(format='openvino', imgsz=$CLASSIFY_IMGSZ, half=False)
"
mv ${CLASSIFY_NAME}_openvino_model/* "$CLASSIFY_DIR/" 2>/dev/null || true
rm -rf ${CLASSIFY_NAME}_openvino_model

# FP16 export
echo "=== Exporting $CLASSIFY_NAME classification model (FP16) ==="
python3 -c "
from ultralytics import YOLO
model = YOLO('$CLASSIFY_PT')
model.export(format='openvino', imgsz=$CLASSIFY_IMGSZ, half=True)
"
for f in ${CLASSIFY_NAME}_openvino_model/*; do
    base=$(basename "$f")
    name="${base%.*}"
    ext="${base##*.}"
    mv "$f" "$CLASSIFY_DIR/${name}_fp16.${ext}"
done
rm -rf ${CLASSIFY_NAME}_openvino_model

# INT8 quantization via NNCF
echo "=== Quantizing $CLASSIFY_NAME classification model (INT8) ==="
python3 << PYEOF
import openvino as ov
import nncf
import numpy as np

core = ov.Core()
model = core.read_model("./models/$CLASSIFY_NAME/$CLASSIFY_NAME.xml")

def transform_fn(data_item):
    return {list(model.inputs[0].names)[0]: data_item}

# Synthetic calibration dataset (random images for quantization)
calibration_data = [np.random.rand(1, 3, $CLASSIFY_IMGSZ, $CLASSIFY_IMGSZ).astype(np.float32) for _ in range(50)]
calibration_dataset = nncf.Dataset(calibration_data, transform_fn)

quantized_model = nncf.quantize(model, calibration_dataset)
ov.save_model(quantized_model, "./models/$CLASSIFY_NAME/${CLASSIFY_NAME}_int8.xml")
print("INT8 classification model saved to: ./models/$CLASSIFY_NAME/${CLASSIFY_NAME}_int8.xml")
PYEOF

rm -f "$CLASSIFY_PT"

echo "Classification model saved to: $CLASSIFY_DIR"

# --- Inject model_info into OpenVINO IR XML files (replaces legacy model-proc) ---
# DL Streamer reads <model_info> from <rt_info> in the XML when model-proc is not specified.
# See: https://docs.openedgeplatform.intel.com/dev/edge-ai-libraries/dlstreamer/dev_guide/model_info_xml.html
echo ""
echo "=== Injecting model_info into OpenVINO IR XML files ==="
python3 << PYEOF
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

    # Clean up Ultralytics-specific framework metadata that may confuse DL Streamer
    for tag in ['framework', 'conversion_parameters']:
        elem = rt_info.find(tag)
        if elem is not None:
            rt_info.remove(elem)

    model_info = ET.SubElement(rt_info, 'model_info')
    for key, value in fields.items():
        elem = ET.SubElement(model_info, key)
        elem.set('value', str(value))

    tree.write(xml_path, xml_declaration=True, encoding='utf-8')
    print(f"  Injected model_info into: {xml_path}")

# Detection model config
detect_fields = {
    "model_type": "$MODEL_TYPE",
    "labels": COCO_LABELS,
    "iou_threshold": "0.5",
    "confidence_threshold": "0.5",
    "pad_value": "114",
    "resize_type": "fit_to_window_letterbox",
    "reverse_input_channels": "True",
    "scale_values": "255",
}

# Classification model config
classify_fields = {
    "model_type": "label",
    "resize_type": "standard",
    "reverse_input_channels": "True",
    "scale_values": "255",
}

for xml_name in ["$DETECT_NAME.xml", "${DETECT_NAME}_fp16.xml", "${DETECT_NAME}_int8.xml"]:
    xml_path = os.path.join("./models/$DETECT_NAME", xml_name)
    if os.path.exists(xml_path):
        inject_model_info(xml_path, detect_fields)

for xml_name in ["$CLASSIFY_NAME.xml", "${CLASSIFY_NAME}_fp16.xml", "${CLASSIFY_NAME}_int8.xml"]:
    xml_path = os.path.join("./models/$CLASSIFY_NAME", xml_name)
    if os.path.exists(xml_path):
        inject_model_info(xml_path, classify_fields)

print("model_info injection complete.")
PYEOF

echo ""
echo "=== All models downloaded and converted ==="
echo "Detection model (FP32):      $DETECT_DIR/$DETECT_NAME.xml"
echo "Detection model (FP16):      $DETECT_DIR/${DETECT_NAME}_fp16.xml"
echo "Detection model (INT8):      $DETECT_DIR/${DETECT_NAME}_int8.xml"
echo "Classification model (FP32): $CLASSIFY_DIR/$CLASSIFY_NAME.xml"
echo "Classification model (FP16): $CLASSIFY_DIR/${CLASSIFY_NAME}_fp16.xml"
echo "Classification model (INT8): $CLASSIFY_DIR/${CLASSIFY_NAME}_int8.xml"

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
    # Ultralytics embeds model_type, task, etc. that confuse DL Streamer
    existing = rt_info.find('model_info')
    if existing is not None:
        rt_info.remove(existing)

    # Also clean up any Ultralytics-specific framework metadata under rt_info
    # that may reference YOLO/classify and cause DL Streamer to misidentify the model
    for tag in ['framework', 'conversion_parameters']:
        elem = rt_info.find(tag)
        if elem is not None:
            rt_info.remove(elem)

    model_info = ET.SubElement(rt_info, 'model_info')
    for key, value in fields.items():
        elem = ET.SubElement(model_info, key)
        elem.set('value', str(value))

    tree.write(xml_path, xml_declaration=True, encoding='utf-8')
    print(f"  Injected model_info into: {xml_path}")

# YOLOv8/YOLO26 detection model config
detect_fields = {
    "model_type": "$MODEL_TYPE",
    "labels": COCO_LABELS,
    "iou_threshold": "0.5",
    "confidence_threshold": "0.5",
    "pad_value": "114",
    "resize_type": "fit_to_window_letterbox",
    "reverse_input_channels": "True",
    "scale_values": "255",
}

# YOLOv8/YOLO26 classification model config
classify_fields = {
    "model_type": "label",
    "resize_type": "standard",
    "reverse_input_channels": "True",
    "scale_values": "255",
}

for xml_name in ["$DETECT_NAME.xml", "${DETECT_NAME}_fp16.xml", "${DETECT_NAME}_int8.xml"]:
    xml_path = os.path.join("./models/$DETECT_NAME", xml_name)
    if os.path.exists(xml_path):
        inject_model_info(xml_path, detect_fields)

for xml_name in ["$CLASSIFY_NAME.xml", "${CLASSIFY_NAME}_fp16.xml", "${CLASSIFY_NAME}_int8.xml"]:
    xml_path = os.path.join("./models/$CLASSIFY_NAME", xml_name)
    if os.path.exists(xml_path):
        inject_model_info(xml_path, classify_fields)

print("model_info injection complete.")
PYEOF

echo ""
echo "=== All models downloaded and converted ==="
echo "Model family:                $MODEL"
echo "Detection model (FP32):      $DETECT_DIR/$DETECT_NAME.xml"
echo "Detection model (FP16):      $DETECT_DIR/${DETECT_NAME}_fp16.xml"
echo "Detection model (INT8):      $DETECT_DIR/${DETECT_NAME}_int8.xml"
echo "Classification model (FP32): $CLASSIFY_DIR/$CLASSIFY_NAME.xml"
echo "Classification model (FP16): $CLASSIFY_DIR/${CLASSIFY_NAME}_fp16.xml"
echo "Classification model (INT8): $CLASSIFY_DIR/${CLASSIFY_NAME}_int8.xml"
