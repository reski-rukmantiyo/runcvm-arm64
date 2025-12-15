#!/bin/bash
set -e

# Setup cleanup on exit
cleanup() {
  echo "Cleaning up..."
  docker rm -f runcvm-ssh-test >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Starting RunCVM Systemd container with port mapping..."
# Note: User requested insert mapped port to port 22
CID=$(docker run -d --rm --name runcvm-ssh-test \
  --runtime=runcvm --privileged \
  -e RUNCVM_HYPERVISOR=firecracker \
  -e RUNCVM_SYSTEMD=true \
  -p 2222:22 \
  runcvm-systemd)

echo "Container started: $CID"
echo "Waiting for SSH (port 2222) to become available..."

# Wait loop
for i in $(seq 1 30); do
  if nc -z localhost 2222 2>/dev/null; then
    echo "Port 2222 is open!"
    break
  fi
  echo "Waiting ($i/30)..."
  sleep 2
done

# Try SSH connection
# Note: We need a key or password. The image likely has root password 'root' or similar?
# Or empty?
# The Dockerfile installs openssh-server. It doesn't configure keys explicitly?
# Wait. `runcvm-systemd` uses the key generated at build time?
# No, `cloud-init` usually sets keys.
# But for this test, if I can just connect and get "Permission denied" (password prompt), that proves connectivity!
# That validates "Mapped Port" works.
# If I want to login, I'd need to inject a key via volume or env.
# But connectivity check is sufficient to prove "Port Mapping" is working.

echo "Testing SSH connectivity (expecting banner)..."
nc -v -w 5 localhost 2222
