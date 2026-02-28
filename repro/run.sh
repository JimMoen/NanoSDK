#!/bin/bash
#
# Reproduce NanoSDK TCP concurrent write byte interleaving bug.
#
# Prerequisites:
#   - Docker
#   - EMQX container running: docker run -d --name emqx-test emqx/emqx-enterprise:5.10.3
#   - neuron source at ../../ (relative to this script) or set NEURON_DIR
#
# What this does:
#   1. Builds a Docker image with neuron + mock NanoSDK
#   2. Starts neuron-repro container with tc netem 100ms delay
#   3. Starts modbus simulator inside the container
#   4. Configures neuron: 10 groups x 200 tags, QoS 2 MQTT to EMQX
#   5. Waits and checks for frame_error in EMQX logs
#
# Mock behavior:
#   Every 50th PUBLISH, sendmsg() is truncated to only send the MQTT
#   fixed header (2-3 bytes). The PUBLISH body is resubmitted later,
#   but by then a PUBREL may have been written in between, causing
#   byte interleaving → EMQX frame_error: invalid_topic, parsed_length=25090
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NANOSDK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NEURON_DIR="${NEURON_DIR:-$(cd "$SCRIPT_DIR/../../neuron" 2>/dev/null && pwd)}"

if [ -z "$NEURON_DIR" ] || [ ! -f "$NEURON_DIR/CMakeLists.txt" ]; then
    echo "ERROR: neuron source not found."
    echo "Set NEURON_DIR or place neuron repo at $(cd "$SCRIPT_DIR/../.." && pwd)/neuron"
    exit 1
fi

EMQX_CONTAINER="${EMQX_CONTAINER:-emqx-test}"
IMAGE_NAME="neuron-repro"
CONTAINER_NAME="neuron-repro"

echo "=== Configuration ==="
echo "  NanoSDK:  $NANOSDK_DIR"
echo "  neuron:   $NEURON_DIR"
echo "  EMQX:     $EMQX_CONTAINER"
echo ""

# Check EMQX is running
if ! docker inspect "$EMQX_CONTAINER" >/dev/null 2>&1; then
    echo "Starting EMQX container..."
    docker run -d --name "$EMQX_CONTAINER" emqx/emqx-enterprise:5.10.3
    echo "Waiting for EMQX to start..."
    sleep 15
fi
EMQX_IP=$(docker inspect "$EMQX_CONTAINER" -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
echo "  EMQX IP:  $EMQX_IP"
echo ""

# Build Docker image
echo "=== Building Docker image ==="
BUILD_CTX=$(mktemp -d)
trap "rm -rf $BUILD_CTX" EXIT

cp "$SCRIPT_DIR/Dockerfile" "$BUILD_CTX/"
cp "$SCRIPT_DIR/setup_neuron.py" "$BUILD_CTX/"

# Copy NanoSDK (without .git and build artifacts)
rsync -a --exclude='.git' --exclude='build' --exclude='install' \
    "$NANOSDK_DIR/" "$BUILD_CTX/NanoSDK/"

# Copy neuron (without .git and build artifacts)
rsync -a --exclude='.git' --exclude='build' --exclude='NanoSDK' \
    "$NEURON_DIR/" "$BUILD_CTX/neuron/"

docker build -t "$IMAGE_NAME" "$BUILD_CTX"
echo ""

# Start container
echo "=== Starting container ==="
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
docker run -d --name "$CONTAINER_NAME" --cap-add NET_ADMIN \
    --sysctl net.ipv4.tcp_wmem="4096 8192 16384" \
    "$IMAGE_NAME"

# Add network delay (100ms on eth0, does not affect localhost)
docker exec "$CONTAINER_NAME" tc qdisc add dev eth0 root netem delay 100ms

# Start modbus simulator
docker exec -d "$CONTAINER_NAME" \
    /opt/neuron/build/simulator/modbus_simulator tcp 60502 ip_v4
sleep 2

# Configure neuron
echo "=== Configuring neuron ==="
docker exec "$CONTAINER_NAME" python3 /opt/setup_neuron.py "$EMQX_IP"
echo ""

# Monitor
echo "=== Monitoring (30 seconds) ==="
echo "Waiting for mock triggers and frame_error..."
sleep 30

echo ""
echo "=== Results ==="
echo "--- MOCK triggers ---"
docker logs "$CONTAINER_NAME" 2>&1 | grep -c "\[MOCK\] Forcing" || echo "0"
docker logs "$CONTAINER_NAME" 2>&1 | grep "\[MOCK\]" | head -3

echo ""
echo "--- PROBE partial writes ---"
docker logs "$CONTAINER_NAME" 2>&1 | grep -c "txaio PARTIAL" || echo "0"

echo ""
echo "--- Concurrent writes (busy=1) ---"
docker logs "$CONTAINER_NAME" 2>&1 | grep -c "busy=1" || echo "0"

echo ""
echo "--- EMQX frame_error ---"
docker logs "$EMQX_CONTAINER" 2>&1 | grep "invalid_topic" | tail -3
FRAME_ERRORS=$(docker logs "$EMQX_CONTAINER" 2>&1 | grep -c "invalid_topic" || echo "0")
echo "Total: $FRAME_ERRORS"

echo ""
echo "--- Connection stability ---"
docker logs "$CONTAINER_NAME" 2>&1 | grep -E "connected|disconnected" | tail -6

echo ""
if [ "$FRAME_ERRORS" -gt 0 ]; then
    echo "=== REPRODUCTION SUCCESSFUL ==="
    echo "EMQX detected $FRAME_ERRORS frame_error(s) caused by byte interleaving."
else
    echo "=== No frame_error detected yet ==="
    echo "Try waiting longer or check logs manually:"
    echo "  docker logs $CONTAINER_NAME 2>&1 | grep MOCK"
    echo "  docker logs $EMQX_CONTAINER 2>&1 | grep invalid_topic"
fi
