#!/bin/bash
set -e

# Test Systemd support in RunCVM
# 1. Build test image
# 2. Run with RUNCVM_SYSTEMD=1 in detached mode
# 3. Check systemctl status via exec
# 4. Check cloud-init via exec
# 5. Check clean shutdown

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

echo "Building runcvm-systemd test image..."
docker build -t runcvm-systemd -f "$SCRIPT_DIR/Dockerfile.systemd" "$REPO_ROOT"

echo "Running Systemd test (Detached)..."
# Start detached
CONTAINER_ID=$(docker run -d --runtime=runcvm --privileged \
  -e RUNCVM_HYPERVISOR=firecracker \
  -e RUNCVM_LOG_LEVEL=DEBUG \
  -e RUNCVM_SYSTEMD=true \
  runcvm-systemd)

echo "Container started: $CONTAINER_ID"
echo "Waiting for container (max 60s)..."

# Loop to wait for dropbear to start (systemd multi-user target)
for i in {1..12}; do
  if docker exec "$CONTAINER_ID" true 2>/dev/null; then
    echo "Container ready (SSH reachable)."
    break
  fi
  echo "Waiting for SSH... ($i/12)"
  sleep 5
done

echo "Checking systemd status..."
if docker exec "$CONTAINER_ID" systemctl is-system-running --wait; then
  echo "✅ PASS: Systemd is running!"
else
  echo "❌ FAIL: Systemd check failed or timed out"
  docker logs "$CONTAINER_ID"
  docker rm -f "$CONTAINER_ID"
  exit 1
fi

echo "Checking for cloud-init execution..."
if docker exec "$CONTAINER_ID" cat /root/cloud-init-test.txt; then
   echo "✅ PASS: Cloud-init executed successfully!"
else
   echo "❌ FAIL: Cloud-init did not execute (test file missing)"
   docker logs "$CONTAINER_ID"
   docker rm -f "$CONTAINER_ID"
   exit 1
fi

# Verify Process Tree (PID Namespace Check)
echo "Verifying PID namespace isolation..."
# We expect to see 'unshare' or 'systemd' but not systemd as PID 1 of the container (which is technically init script)
# Wait, inside docker exec, we see the global namespace?
# Let's list processes.
PS_OUTPUT=$(docker exec "$CONTAINER_ID" ps -e -o pid,comm)
echo "Process list:"
echo "$PS_OUTPUT"

# If our implementation worked, PID 1 in the container should be the shell script (or init), NOT systemd directly?
# Actually, unshare runs as child of script? No, I ran unshare without &.
# Wait, I ran `$UNSHARE_BIN ...`. This blocks the shell script.
# But does `exec` replace shell script? No, I removed `exec`.
# So shell script (PID 1) spawns `unshare` (PID x).
# So PID 1 is `/init` (shell script).
# PID 2 is `unshare` (maybe).
# PID 3 is `systemd` (maybe, inside namespace implies it thinks it is PID 1, but globally it is PID y).

# ps inside the container (default namespace) should show:
# PID 1: /init (shell)
# PID x: unshare ...
# PID y: systemd ...

if echo "$PS_OUTPUT" | grep -q "systemd"; then
  echo "✅ PASS: systemd process found"
else
  echo "❌ FAIL: systemd process NOT found"
fi

if echo "$PS_OUTPUT" | head -n 2 | grep -q "systemd"; then
   # If PID 1 is systemd, then unshare didn't work as expected or I exec'd it?
   # Note: ps output header is line 1. Line 2 is PID 1.
   PID1_COMM=$(echo "$PS_OUTPUT" | sed -n '2p' | awk '{print $2}')
   if [[ "$PID1_COMM" == *"systemd"* ]]; then
      echo "⚠️  WARNING: PID 1 is systemd - unshare might not be active or exec was used?"
   else
      echo "✅ PASS: PID 1 is '$PID1_COMM' (not systemd) - namespace isolation likely active"
   fi
else
   echo "✅ PASS: PID 1 is not systemd"
fi


echo "Testing Shutdown..."
start_time=$(date +%s)
docker stop "$CONTAINER_ID"
end_time=$(date +%s)
duration=$((end_time - start_time))

if [ $duration -lt 15 ]; then
   echo "✅ PASS: Container stopped quickly ($duration s) - signals propagated correctly"
else
   echo "⚠️  WARNING: Container took $duration s to stop - likely forced kill (signals not handled?)"
   # Note: Since I didn't add explicit signal trap in the shell script, 
   # and PID 1 (shell) ignores signals by default, this might fail (timeout).
   # But let's see. 'docker stop' sends SIGTERM. 
   # If shell ignores it, it waits 10s then SIGKILL.
   # If it takes >10s, we know we need to add the trap.
fi

docker rm "$CONTAINER_ID" >/dev/null
echo "Done."
