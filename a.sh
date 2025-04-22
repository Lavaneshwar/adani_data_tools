#!/bin/bash

# ============================
# Stream Pipeline with Full-Screen Detection (640x640)
# Optimized with Shared Inference Model Instance
# ============================

# Default values
MODEL_DIR="/home/dlstreamer/models/warehouse3"
MODEL_NAME="cementbag_v7"
SINK_IP="192.168.0.138"
SINK_PORT="5000"

# Check if temporary file is provided
if [ $# -ne 1 ] || [ ! -f "$1" ]; then
    echo "Error: No valid RTSP stream file provided."
    exit 1
fi

# Read RTSP streams from the temporary file
mapfile -t RTSP_STREAMS < "$1"
if [ ${#RTSP_STREAMS[@]} -eq 0 ]; then
    echo "Error: No RTSP streams found in file."
    exit 1
fi
echo "Using RTSP streams: ${RTSP_STREAMS[@]}"

MODEL_XML="$MODEL_DIR/${MODEL_NAME}.xml"
MODEL_BIN="$MODEL_DIR/${MODEL_NAME}.bin"

# Verify model files exist
if [ ! -f "$MODEL_XML" ] || [ ! -f "$MODEL_BIN" ]; then
    echo "Error: Model files not found at $MODEL_XML or $MODEL_BIN"
    exit 1
fi

NUM_STREAMS=${#RTSP_STREAMS[@]}

# Fixed Processing & Display Resolution (640x640)
PROCESS_WIDTH=640
PROCESS_HEIGHT=640
DISPLAY_WIDTH=640
DISPLAY_HEIGHT=640

# Set up compositor positions for horizontal layout
COMPOSITOR_POS=""
for i in "${!RTSP_STREAMS[@]}"; do
    xpos=$((i * DISPLAY_WIDTH))  # Increment x-position for each stream
    ypos=0                       # Keep y-position the same for all streams
    COMPOSITOR_POS+=" sink_$i::xpos=$xpos sink_$i::ypos=$ypos"
done

# Build the pipeline string
pipeline="gst-launch-1.0 -e \
    compositor name=mix background=black $COMPOSITOR_POS ! \
    videoconvert ! \
    videoscale ! video/x-raw,width=$((DISPLAY_WIDTH * NUM_STREAMS)),height=$DISPLAY_HEIGHT,format=NV12 ! \
    vaapipostproc ! \
    vaapih264enc rate-control=cbr bitrate=15000 keyframe-period=30 ! \
    h264parse ! \
    rtph264pay pt=96 ! \
    fakesink sync=false"

# Add stream pipelines
stream_pipelines=""
for i in "${!RTSP_STREAMS[@]}"; do
    stream_pipelines+=" rtspsrc location=${RTSP_STREAMS[$i]} latency=100 protocols=tcp timeout=30000000 retry=20 user-id=admin user-pw=password ! \
        rtph264depay ! h264parse ! vaapih264dec ! \
        queue max-size-buffers=0 max-size-time=100000000 leaky=downstream ! \
        videoconvert ! videoscale ! video/x-raw,width=$PROCESS_WIDTH,height=$PROCESS_HEIGHT,format=NV12 ! \
        gvadetect model=$MODEL_XML device=CPU threshold=0.7 nireq=4 batch-size=3 model-instance-id=inf$i pre-process-backend=ie ! \
        gvatrack tracking-type=zero-term-imageless ! \
        gvapython module=f class=WebSocketDetector ! \
        gvawatermark ! gvafpscounter ! tee name=t$i ! \
        queue ! \
        vaapipostproc ! videoscale ! video/x-raw,format=NV12,width=$DISPLAY_WIDTH,height=$DISPLAY_HEIGHT ! \
        mix.sink_$i"
done
pipeline="$pipeline $stream_pipelines"

# Debug: Print the generated pipeline
echo "Generated pipeline: $pipeline"

# Function to launch pipeline
launch_pipeline() {
    echo "Launching GStreamer pipeline with $NUM_STREAMS streams..."
    # Increase debug level and show all errors/warnings in terminal
    GST_DEBUG=3 eval "$pipeline" 2>&1 | tee /tmp/gstreamer.log | while read -r line; do
        # Check for pipeline start
        if echo "$line" | grep -q "Pipeline is live" && [ -z "$pipeline_started" ]; then
            echo "running....."
            pipeline_started=true
            last_fps_time=$(date +%s)
        fi
        # Extract and display FPS every 5 seconds
        if echo "$line" | grep -q "FpsCounter" && [ -n "$pipeline_started" ]; then
            current_time=$(date +%s)
            if [ $((current_time - last_fps_time)) -ge 5 ]; then
                fps=$(echo "$line" | grep -o "total=[0-9]*\.[0-9]*" | cut -d= -f2)
                if [ -n "$fps" ]; then
                    echo "fps: $fps"
                    last_fps_time=$current_time
                fi
            fi
        fi
        # Display all errors and warnings in terminal
        if echo "$line" | grep -E "error|warning|Connection refused"; then
            echo "$line"
        fi
        # Trigger retry on connection refused
        if echo "$line" | grep -q "Connection refused"; then
            return 1
        fi
    done
    return $?
}

# Loop to restart pipeline on failure
max_attempts=10
attempt=1
while [ $attempt -le $max_attempts ]; do
    unset pipeline_started last_fps_time
    launch_pipeline
    exit_code=$?
    if [ $exit_code -eq 0 ]; then
        echo "Pipeline completed successfully"
        break
    elif [ $exit_code -ne 0 ] && [ $attempt -lt $max_attempts ]; then
        echo "Pipeline failed (attempt $attempt/$max_attempts), retrying in 5 seconds..."
        sleep 5
        ((attempt++))
    else
        echo "Error: GStreamer pipeline failed after $max_attempts attempts"
        # Display last log for debugging
        echo "Last GStreamer log (terminal summary):"
        tail -n 50 /tmp/gstreamer.log
        exit 1
    fi
done
