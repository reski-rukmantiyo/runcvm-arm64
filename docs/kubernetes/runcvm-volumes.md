# RunCVM Volumes: NFS Host Volume Mounting

This document combines the technical findings, implementation details, and verification results for supporting host volume mounts via NFSv3 in Firecracker microVMs within the RunCVM environment.

---

## Technical Lessons Learned

### Technical Insights

#### 1. Network Namespace Alignment
> [!IMPORTANT]
> **Discovery**: The NFS server (`unfsd`) MUST run in the same network namespace as the microVM's TAP interface.
> - **Why**: If they are in different namespaces, the guest VM (communicating over the internal bridge) cannot reach the server's port, resulting in "Connection refused".
> - **Solution**: Start the NFS daemon from the container process (`runcvm-ctr-firecracker-k8s`) rather than the runtime. This ensures zero-config namespace alignment.

#### 2. Export Path Resolution
- `unfsd` running inside a container sees paths relative to THAT container.
- If the runtime mounts host `/tmp/foo` to `/vm/test-mount`, the NFS server must be told to export `/vm/test-mount`, NOT `/tmp/foo`.

#### 3. NFS Client Dependencies (Guest side)
An NFS mount requires more than just the `mount` command:
- **`mount.nfs`**: The helper binary.
- **`libtirpc`**: The RPC library used by modern NFS tools.
- **`/etc/netconfig`**: Required by `libtirpc` to resolve transport protocols (tcp, udp).
- **`/etc/services`**: Maps service names (nfs, sunrpc) to ports.
- **Kernel Support**: `CONFIG_NFS_FS` and `CONFIG_NFS_V3` must be enabled.

### Documentation & Prerequisites

#### Prerequisites Checklist
- [ ] **Host Packages**: `unfs3` must be available in the container image.
- [ ] **Guest Image**: Must contain `nfs-utils`, `/etc/netconfig`, and `/etc/services`.
- [ ] **Networking**: A bridge `alias_ip` must be configured to act as the server gateway.

#### Volume Configuration
- Only bind mounts targeted inside the `RUNCVM_VM_MOUNTPOINT` (default `/vm`) are automatically exported via NFS.
- System volumes like `/dev/shm` or `/run` should be excluded to avoid export conflicts.

#### Security Note
- Current implementation uses `all_squash` with `anonuid=0` (root). 
- **Recommendation**: For production, we should map anonymous users to the container's UID/GID if specified in the OCI config.

---

## Final Walkthrough

This section summarizes the changes and verification results.

### Changes Made

#### 1. Architectural Shift - In-Namespace `unfsd` Startup
- Moved the `unfsd` startup logic from `runcvm-runtime` (which runs in the host root namespace) to `runcvm-ctr-firecracker-k8s` (which runs inside the container/pod network namespace).
- This ensures that `unfsd` is automatically aligned with the pod's network bridge and can bind to the `alias_ip` without complex `nsenter` calls.

#### 2. Path Resolution for NFS Exports
- Updated `runcvm-runtime` to use container-relative paths (e.g., `/vm/test-mount`) for exports instead of absolute host paths.
- This allows `unfsd` (running inside the container) to correctly locate and export the directories mounted into the container at `/vm`.

#### 3. Guest-Side NFS Infrastructure
- Injected critical configuration files (`/etc/netconfig`, `/etc/services`) into the guest rootfs.
- Bundled `nfs-utils` (specifically `mount.nfs`) into the `runcvm` runtime.
- Modified the guest `init` script to use the host's bridge `alias_ip` as the NFS gateway.

### Verification Results

#### `unfsd` Startup (Container Log)
The logs confirm that `unfsd` now starts successfully within the correct namespace with the right export paths:
```text
[2025-12-20 08:41:31] [RunCVM-FC] [132] [INFO]     Starting HOST unfsd for NFS volumes (inside namespace)...
      [2025-12-20 08:41:31] [runcvm-nfsd] Starting unfsd for container 982659eaa9...
      [2025-12-20 08:41:31] [runcvm-nfsd]   Volumes: /vm/test-mount
      [2025-12-20 08:41:31] [runcvm-nfsd]   Port: 1028 (mount: 1029)
      [2025-12-20 08:41:31] [runcvm-nfsd]     /vm/test-mount (rw,all_squash,anonuid=0,anongid=0)
      [2025-12-20 08:41:32] [runcvm-nfsd]   unfsd started successfully (PID: 934)
```

#### Guest Mount Confirmation
The guest VM successfully performs the mount:
```text
[pod/runcvm-test/nginx] ✓ Successfully mounted /test-mount (NFS)
```

### Final State
Host volumes are now reliably accessible within the Firecracker microVM using NFSv3, resolving the previous "Connection refused" and "Bad option" errors.
