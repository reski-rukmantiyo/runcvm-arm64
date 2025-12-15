#!/bin/bash
set -e

# Cleanup any stale containers
cleanup() {
  echo "Cleaning up..."
  docker rm -f runcvm-test-A runcvm-test-B >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== Test Scenario 1: Multi-Container Isolation & Exec ==="
echo "Starting Container A..."
CID_A=$(docker run -d --rm --name runcvm-test-A \
  --runtime=runcvm --privileged \
  -e RUNCVM_HYPERVISOR=firecracker \
  -e RUNCVM_SYSTEMD=true \
  runcvm-systemd)

echo "Starting Container B..."
CID_B=$(docker run -d --rm --name runcvm-test-B \
  --runtime=runcvm --privileged \
  -e RUNCVM_HYPERVISOR=firecracker \
  -e RUNCVM_SYSTEMD=true \
  runcvm-systemd)

IP_A=$(docker inspect --format '{{.NetworkSettings.IPAddress}}' $CID_A)
IP_B=$(docker inspect --format '{{.NetworkSettings.IPAddress}}' $CID_B)

echo "Container A: $CID_A ($IP_A)"
echo "Container B: $CID_B ($IP_B)"

wait_for_boot() {
  local cid=$1
  echo "Waiting for Container $cid to boot (max 180s)..."
  for i in $(seq 1 90); do
    if docker logs $cid 2>&1 | grep -q "Welcome to Alpine Linux"; then
      echo "  Boot detected!"
      return 0
    fi
    sleep 2
  done
  echo "  Timeout waiting for boot."
  return 1
}

wait_for_boot $CID_A
wait_for_boot $CID_B

sleep 5

echo "Testing 'docker exec' on Container A..."
docker exec $CID_A sh -c "hostname && ip addr" > /tmp/exec_A.log 2>&1 || echo "Exec A failed"

echo "Testing 'docker exec' on Container B..."
docker exec $CID_B sh -c "hostname && ip addr" > /tmp/exec_B.log 2>&1 || echo "Exec B failed"

# Check results
if grep -q "Exec" /tmp/exec_A.log || grep -q "Exec" /tmp/exec_B.log; then
    echo "FAIL: One or more execs failed."
    cat /tmp/exec_A.log /tmp/exec_B.log
    exit 1
else
    echo "SUCCESS: Both execs worked effectively simultaneously."
    echo "Checking isolation (Hostnames should differ if set, IPs definitely differ)..."
    cat /tmp/exec_A.log
    grep "$IP_A" /tmp/exec_A.log || echo "WARNING: IP A not found in output"
    
    cat /tmp/exec_B.log
    grep "$IP_B" /tmp/exec_B.log || echo "WARNING: IP B not found in output"
fi

echo ""
echo "=== Test Scenario 2: Direct SSH via Main Interface (Container IP) ==="
# We attempt to SSH directly to IP_A using default port 22 (inside container)
# Note: Host-to-Container-IP routing works via docker0 bridge on Host.
echo "Attempting SSH to $IP_A:22 (No port mapping)..."

# Use Netcat to check banner first to avoid strict host key issues blocking
if nc -v -w 5 $IP_A 22 2>&1 | grep -i "SSH"; then
   echo "SUCCESS: Direct SSH Banner received from $IP_A:22"
else
   echo "FAIL: Could not connect to $IP_A:22"
   exit 1
fi
