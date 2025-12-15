#!/bin/bash
set -e

# Test SystemD DinD support in RunCVM
# 1. Build test image
# 2. Run with RUNCVM_SYSTEMD=true
# 3. Check docker info via exec

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

echo "Building runcvm-dind-systemd test image..."
docker build -t runcvm-dind-systemd -f "$SCRIPT_DIR/Dockerfile.dind-systemd" "$REPO_ROOT"

echo "Running SystemD DinD test (Detached)..."
# Start detached
# Note: User requested trying without --privileged.
# We still pass /dev/kvm and /dev/net/tun if possible by default logic or rely on runcvm runtime.
# Typically DinD needs privileges for cgroups/iptables inside.
CONTAINER_ID=$(docker run -d --name runcvm-dind --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -e RUNCVM_LOG_LEVEL=DEBUG \
  -e RUNCVM_SYSTEMD=true \
  -e RUNCVM_KERNEL_ARGS="systemd.unified_cgroup_hierarchy=0" \
  runcvm-dind-systemd)

echo "Container started: $CONTAINER_ID"
echo "Waiting for SSH/Boot (max 180s)..."

wait_for_boot() {
  local cid=$1
  for i in $(seq 1 90); do
    if docker exec "$cid" true 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

if wait_for_boot "$CONTAINER_ID"; then
    echo "Container reachable."
else
    echo "❌ FAIL: Container execution failed or timed out"
    docker logs "$CONTAINER_ID"
    docker rm -f "$CONTAINER_ID"
    exit 1
fi

echo "Checking SystemD status..."
if docker exec "$CONTAINER_ID" systemctl is-system-running --wait; then
  echo "✅ PASS: Systemd is running!"
else
  echo "⚠️  WARNING: Systemd status check returned non-zero (common during boot degradation)"
  docker exec "$CONTAINER_ID" systemctl status || true
fi

echo "Checking Docker Daemon status inside..."
if docker exec "$CONTAINER_ID" systemctl is-active docker; then
    echo "✅ PASS: Docker service is active"
else
    echo "❌ FAIL: Docker service is NOT active"
    docker exec "$CONTAINER_ID" systemctl status docker --full --no-pager || true
    docker exec "$CONTAINER_ID" journalctl -u docker --no-pager -n 50 || true
    docker exec "$CONTAINER_ID" journalctl -xe --no-pager -n 50 || true
    docker logs "$CONTAINER_ID"
    docker rm -f "$CONTAINER_ID"
    exit 1
fi

echo "Running Inner Docker Container..."
if docker exec "$CONTAINER_ID" docker run --rm --security-opt seccomp=unconfined --security-opt apparmor=unconfined alpine echo "DinD Success"; then
    echo "✅ PASS: Inner Docker container ran successfully!"
else
    echo "❌ FAIL: Inner Docker container failed to run"
    docker exec "$CONTAINER_ID" docker info || true
    docker logs "$CONTAINER_ID"
    docker rm -f "$CONTAINER_ID"
    exit 1
fi

echo "Cleaning up..."
docker rm -f "$CONTAINER_ID" >/dev/null
echo "Done."
