#!/bin/bash
set -e

SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/../framework.sh"

# Define logging helpers
log_info() { echo -e "\033[36m[INFO]\033[0m $*"; }
log_pass() { echo -e "\033[32m[PASS]\033[0m $*"; }
log_warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
log_fail() { echo -e "\033[31m[FAIL]\033[0m $*"; exit 1; }


TEST_NAME="Rootfs Caching"
IMAGE="alpine:latest"

log_info "Starting $TEST_NAME test..."

# Ensure we have the image
docker pull $IMAGE >/dev/null

# Clean previous cache (optional, but good for reliable cold boot test)
# Since we can't easily access the VM's cache dir from here without privilege or a mount,
# we'll rely on a unique image or just accept the first run might allow warm boot if already cached.
# But for now, let's assume it might be cold or warm.
# We can try to clear cache via a privileged container if needed.
# docker run --runtime=runcvm --privileged --rm -v /var/lib/runcvm:/var/lib/runcvm alpine rm -rf /var/lib/runcvm/cache/*

log_info "1. First Boot (Potential Cold Start)..."
START_TIME=$(date +%s%N)
docker run --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker --rm $IMAGE echo "First Boot"
END_TIME=$(date +%s%N)
DURATION_1=$(( ($END_TIME - $START_TIME) / 1000000 ))
log_info "Duration: ${DURATION_1}ms"

log_info "2. Second Boot (Warm Start)..."
START_TIME=$(date +%s%N)
docker run --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker --rm $IMAGE echo "Second Boot"
END_TIME=$(date +%s%N)
DURATION_2=$(( ($END_TIME - $START_TIME) / 1000000 ))
log_info "Duration: ${DURATION_2}ms"

# Verification
if [ "$DURATION_2" -lt "$DURATION_1" ]; then
  log_pass "Warm boot ($DURATION_2 ms) is faster than First boot ($DURATION_1 ms)"
else
  log_warn "Warm boot ($DURATION_2 ms) was NOT faster than First boot ($DURATION_1 ms)"
  # It might not be strictly faster if first boot was already cached or noise.
  # But typically cold is ~5s, warm < 500ms.
fi

# Check strict threshold for warm boot
if [ "$DURATION_2" -lt 2000 ]; then
   log_pass "Warm boot is under 2000ms"
else
   log_fail "Warm boot is too slow ($DURATION_2 ms)"
fi

log_info "$TEST_NAME complete"
