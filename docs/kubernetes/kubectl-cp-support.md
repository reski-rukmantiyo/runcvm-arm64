# Kubectl CP Support

This document describes the implementation and usage of `kubectl cp` within the RunCVM environment.

## Overview

In `runcvm`, `kubectl cp` is supported through a bundled `tar` binary provided in the guest VM tools. This ensures that file copying functionality is available regardless of whether the container image itself includes `tar`.

## Implementation Details

### Bundled Guest Tools
`tar` is included in the guest tools distribution via the following mechanism:
- **Binary**: `tar` is provided by the bundled `busybox` binary in `/opt/runcvm/bin`.
- **Symlink**: A symlink from `/opt/runcvm/bin/tar` to `busybox` is created during the build process.
- **Dynamic Linker**: The `tar` command is registered in `runcvm-ctr-defaults`, ensuring it is always executed using the bundled dynamic linker (`/.runcvm/guest/lib/ld`) with the correct environment variables.

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
Copying files from the local host to a pod is currently supported but may experience timeouts on larger files or complex streams.
```bash
kubectl cp /path/to/local/file <pod-name>:/path/to/remote/destination
```
> [!NOTE]
> **Performance Note**: While copying to the pod works, it currently has a known issue where the command may timeout after completion (`context deadline exceeded`). This is due to EOF propagation behavior in the SSH transport layer and does not necessarily indicate a failure of the file transfer itself.

## Troubleshooting

If `kubectl cp` fails with "required file not found", ensure:
1. The pod has been started with the latest `runcvm` guest tools.
2. The `tar` binary is present in `/.runcvm/guest/bin/tar` inside the VM.
3. Check the [Kubernetes Troubleshooting Guide](file:///Users/reski/Documents/GitHub/runcvm-arm64/docs/kubernetes/TROUBLESHOOTING.md) for more information on binary mismatches.
