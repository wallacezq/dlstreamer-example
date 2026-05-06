# Intel DL Streamer Pipeline
# Based on intel/dlstreamer image with OpenVINO + GStreamer + DL Streamer plugins
FROM intel/dlstreamer:2026.0.0-ubuntu24

USER root

# Install additional utilities and GStreamer
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-pip \
    wget \
    #gstreamer1.0-tools \
    #gstreamer1.0-plugins-base \
    #gstreamer1.0-plugins-good \
    #gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    #gstreamer1.0-libav \
    && rm -rf /var/lib/apt/lists/*

# Force-remove system numpy files without triggering apt dependency removal
# (apt-get remove would cascade and uninstall dlstreamer packages)
RUN rm -rf /usr/lib/python3/dist-packages/numpy* \
           /usr/lib/python3/dist-packages/NumPy*

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

# Set DL Streamer environment paths
ENV DLSTREAMER_DIR=/opt/intel/dlstreamer
ENV PATH=${DLSTREAMER_DIR}/gstreamer/bin:${PATH}
ENV LD_LIBRARY_PATH=${DLSTREAMER_DIR}/gstreamer/lib:${DLSTREAMER_DIR}/lib:${LD_LIBRARY_PATH}
ENV GST_PLUGIN_PATH=${DLSTREAMER_DIR}/gstreamer/lib/gstreamer-1.0:/usr/lib/x86_64-linux-gnu/gstreamer-1.0:${GST_PLUGIN_PATH}

# Debug: list GVA plugins available
RUN gst-inspect-1.0 gvadetect || \
    (echo "gvadetect not found, scanning for GVA plugins..." && \
     find /opt/intel/dlstreamer -name "*gva*" -type f 2>/dev/null && \
     find /opt/intel/dlstreamer -name "*.so" -path "*/gstreamer*" 2>/dev/null | head -20)

ENTRYPOINT ["/app/run_pipeline.sh"]
