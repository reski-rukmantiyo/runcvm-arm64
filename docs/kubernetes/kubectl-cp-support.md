# Kubectl CP Support

This document describes the implementation and usage of `kubectl cp` within the RunCVM environment.

## Overview

In `runcvm`, `kubectl cp` is fully supported through a combination of bundled `tar` binary in the guest VM tools and a robust Python-based VSOCK transport layer. This ensures reliable file copying functionality in both directions (pod-to-local and local-to-pod).

## Implementation Details

### Bundled Guest Tools
`tar` is included in the guest tools distribution via the following mechanism:
- **Binary**: `tar` is provided by the bundled `busybox` binary in `/opt/runcvm/bin`.
- **Symlink**: A symlink from `/opt/runcvm/bin/tar` to `busybox` is created during the build process.
- **Dynamic Linker**: The `tar` command is registered in `runcvm-ctr-defaults`, ensuring it is always executed using the bundled dynamic linker (`/.runcvm/guest/lib/ld`) with the correct environment variables.

### VSOCK Transport Layer
The transport layer between the container and the guest VM uses a Python-based script (`runcvm-vsock-connect`) to handle the Firecracker VSOCK handshake and bidirectional data forwarding:

- **Python 3 Dependency**: The container image includes `python3` (added to the Dockerfile) to support the transport script.
- **Unbuffered Forwarding**: The Python script uses unbuffered socket I/O with threading to ensure robust, low-latency bidirectional data flow.
- **Handshake**: The script sends a `CONNECT <port>` message to the Firecracker Unix domain socket and reads the `OK` response before forwarding data.

**Key Files:**
- [runcvm-vsock-connect](file:///Users/reski/Documents/GitHub/runcvm-arm64/runcvm-scripts/runcvm-vsock-connect): Python-based VSOCK transport script.
- [Dockerfile](file:///Users/reski/Documents/GitHub/runcvm-arm64/Dockerfile): Includes `python3` in the runtime image.

### Configuration
The `tar` binary is registered in the `create_aliases` function in `runcvm-ctr-defaults`:
```bash
# runcvm-ctr-defaults
create_aliases() {
  for cmd in ... tar ...; do
    # Alias logic to wrap with LD_LIBRARY_PATH and ld
  done
}
```

## Usage

### Copying FROM a Pod
Copying files from a pod's Persistent Volume (PV) to the local host works successfully.
```bash
kubectl cp <pod-name>:/path/to/remote/file /path/to/local/destination
```

### Copying TO a Pod
Copying files from the local host to a pod is fully supported and verified with large files (10MB+).
```bash
kubectl cp /path/to/local/file <pod-name>:/path/to/remote/destination
```

> [!WARNING]  
> **Known Regression**: The global proxy configuration (port 22222) currently causes conflicts with `kubectl exec` commands. A fix is planned to use dynamic port allocation for the VSOCK proxy to isolate exec and cp operations.

## Troubleshooting

If `kubectl cp` fails with "required file not found", ensure:
1. The pod has been started with the latest `runcvm` guest tools.
2. The `tar` binary is present in `/.runcvm/guest/bin/tar` inside the VM.
3. Check the [Kubernetes Troubleshooting Guide](file:///Users/reski/Documents/GitHub/runcvm-arm64/docs/kubernetes/TROUBLESHOOTING.md) for more information on binary mismatches.

If `kubectl exec` fails with "Remote closed the connection" after a recent build:
1. This is a known regression from the `kubectl cp` fix.
2. A fix is in progress to use dynamic port allocation for the VSOCK proxy.
3. As a temporary workaround, revert to an earlier build or contact the maintainers.
