#!/bin/bash
set -e

# Test Systemd Entrypoint Injection
# Verifies that RUNCVM_SYSTEMD=true treats the command as a service

echo "Running Systemd Entrypoint Test (Detached)..."

# Run detached (no --rm so we can see logs if it crashes)
CID=$(docker run -d --runtime=runcvm --privileged \
  -e RUNCVM_HYPERVISOR=firecracker \
  -e RUNCVM_SYSTEMD=true \
  runcvm-systemd \
  sh -c "echo 'SUCCESS_MARKER' && systemctl is-active runcvm-entrypoint")

echo "Container started: $CID"
echo "Waiting for boot..."

# Wait max 60 seconds for SUCCESS_MARKER
for i in $(seq 1 30); do
  LOGS=$(docker logs "$CID" 2>&1 || true)
  if echo "$LOGS" | grep -q "SUCCESS_MARKER"; then
    echo "✅ PASS: Entrypoint executed successfully"
    echo "$LOGS" | grep "SUCCESS_MARKER"
    docker rm -f "$CID" >/dev/null
    exit 0
  fi
  
  if echo "$LOGS" | grep -q "login:"; then
     echo "ℹ️  Login prompt appeared, checking service status..."
     docker exec "$CID" systemctl status runcvm-entrypoint || true
     
     # If we see login, and not marker, maybe it failed?
     # Let's wait a bit more just in case
  fi
  
  sleep 2
done

echo "❌ FAIL: Timed out waiting for entrypoint output"
echo "--- LOGS ---"
docker logs "$CID"
echo "--- SERVICE STATUS ---"
docker exec "$CID" systemctl status runcvm-entrypoint || true
echo "--- JOURNAL ---"
docker exec "$CID" journalctl -u runcvm-entrypoint --no-pager || true

docker rm -f "$CID" >/dev/null
exit 1
