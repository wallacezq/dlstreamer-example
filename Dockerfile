# Intel DL Streamer Pipeline
# Based on intel/dlstreamer image with OpenVINO + GStreamer + DL Streamer plugins
FROM intel/dlstreamer:2026.0.0-ubuntu24

USER root

# Install additional utilities and GStreamer
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-pip \
    wget \
    gstreamer1.0-tools \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    && rm -rf /var/lib/apt/lists/*

# Remove system numpy to avoid pip conflict
RUN apt-get update && apt-get remove -y python3-numpy && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY requirements.txt /app/
RUN pip3 install --no-cache-dir --break-system-packages -r /app/requirements.txt

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

# Find gst-launch-1.0 and DL Streamer paths, persist in env file
RUN echo '#!/bin/bash' > /app/setup_env.sh && \
    GST_BIN=$(find / -name "gst-launch-1.0" -type f 2>/dev/null | head -1) && \
    if [ -n "$GST_BIN" ]; then \
        echo "export PATH=$(dirname $GST_BIN):\$PATH" >> /app/setup_env.sh; \
    fi && \
    for sv in $(find / -name "setupvars.sh" -path "*dlstreamer*" 2>/dev/null); do \
        echo "source $sv" >> /app/setup_env.sh; \
    done && \
    chmod +x /app/setup_env.sh

ENTRYPOINT ["/bin/bash", "-c", "source /app/setup_env.sh && /app/run_pipeline.sh"]
