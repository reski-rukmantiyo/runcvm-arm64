#!/bin/bash
set -e

# Test Docker-in-Docker support in RunCVM
# 1. Build test image with Docker installed
# 2. Run with RUNCVM_SYSTEMD=true
# 3. Check if dockerd starts and can run containers

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

echo "Building runcvm-dind test image..."
# Temporarily modify Dockerfile to install docker.io
sed -i.bak 's/openssh-server/openssh-server docker.io/' "$SCRIPT_DIR/Dockerfile.systemd"

docker build -t runcvm-dind -f "$SCRIPT_DIR/Dockerfile.systemd" "$REPO_ROOT"

# Restore Dockerfile
mv "$SCRIPT_DIR/Dockerfile.systemd.bak" "$SCRIPT_DIR/Dockerfile.systemd"

echo "Running DinD test..."
OUTPUT=$(docker run --runtime=runcvm --privileged \
  -e RUNCVM_HYPERVISOR=firecracker \
  -e RUNCVM_SYSTEMD=true \
  runcvm-dind sh -c "systemctl start docker && docker run hello-world" 2>&1 || true)

echo "Container Output:"
echo "$OUTPUT"

if echo "$OUTPUT" | grep -q "Hello from Docker!"; then
  echo "✅ PASS: DinD is working!"
else
  echo "❌ FAIL: DinD failed"
  exit 1
fi
