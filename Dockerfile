# Intel DL Streamer Pipeline
# Based on intel/dlstreamer image with OpenVINO + GStreamer + DL Streamer plugins
FROM intel/dlstreamer:2026.0.0-ubuntu24

USER root

# Install additional utilities
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-pip \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies for model conversion
RUN pip3 install --no-cache-dir ultralytics openvino-dev nncf

# Create working directory
WORKDIR /app

# Copy scripts
COPY download_models.sh /app/
COPY run_pipeline.sh /app/
RUN chmod +x /app/download_models.sh /app/run_pipeline.sh

# Download and convert models at build time
RUN /app/download_models.sh

# Default environment variables
ENV RTSP_INPUT=rtsp://host.docker.internal:8554/stream
ENV OUTPUT_HOST=224.1.1.1
ENV OUTPUT_PORT=5000
ENV DEVICE=CPU
ENV TRACKER_TYPE=short-term-imageless
ENV DETECT_MODEL=/app/models/yolov8n/yolov8n.xml
ENV CLASSIFY_MODEL=/app/models/yolov8n-cls/yolov8n-cls.xml
ENV DETECT_MODEL_PROC=/app/models/yolov8n/yolov8n.json
ENV CLASSIFY_MODEL_PROC=/app/models/yolov8n-cls/yolov8n-cls.json

ENTRYPOINT ["/app/run_pipeline.sh"]
