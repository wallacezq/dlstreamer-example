# Intel DL Streamer Pipeline
# Based on intel/dlstreamer image with OpenVINO + GStreamer + DL Streamer plugins
FROM intel/dlstreamer:2026.0.0-ubuntu24

USER root

# Install additional utilities
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-pip \
    wget \
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

# Locate DL Streamer environment setup and persist it
RUN SETUPVARS=$(find /opt/intel -name "setupvars.sh" 2>/dev/null | head -1) && \
    if [ -n "$SETUPVARS" ]; then \
        echo "source $SETUPVARS" > /etc/profile.d/dlstreamer.sh; \
    fi
# Ensure gst-launch-1.0 is on PATH (find its location and add to PATH)
RUN GST_PATH=$(dirname $(find / -name "gst-launch-1.0" -type f 2>/dev/null | head -1) 2>/dev/null) && \
    if [ -n "$GST_PATH" ]; then echo "PATH=$GST_PATH:\$PATH" >> /etc/profile.d/dlstreamer.sh; fi

ENTRYPOINT ["/bin/bash", "-l", "-c", "/app/run_pipeline.sh"]
