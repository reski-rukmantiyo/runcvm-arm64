# Roadmap Evaluation: Missing & Partial Implementations

**Last Updated**: December 14, 2025
**Scope**: Evaluation of items marked Partial (🟡) or Missing (❌) in `ROADMAP.md`.
**Ranking Scale**: 1 (Easy) to 5 (Hardest).

---

## Rank 5: Significant Architectural Challenges (Hardest)

### 1. Network Hotplug (`docker network connect`)
*   **Status**: ❌ Missing
*   **Difficulty**: 5/5
*   **Analysis**:
    *   **Challenge**: Connecting a network to a *running* container requires hotplugging a network interface into the Firecracker microVM.
    *   **Gap**: Currently, networking is static and configured only at boot in `runcvm-ctr-firecracker`.
    *   **Requirements**:
        *   Firecracker MMIO/API interaction to add a network device at runtime.
        *   Guest kernel hotplug support.
        *   Guest agent/script to configure the new interface (IP, routes) dynamically inside the VM.

### 2. Docker-in-Docker (DinD)
*   **Status**: 🟡 Partial / Untested
*   **Difficulty**: 5/5
*   **Analysis**:
    *   **Challenge**: Running Docker inside Firecracker requires nested virtualization-like characteristics (bridge capability, cgroups management, overlayfs inside overlayfs).
    *   **Gap**: Privileged mode is passed, but `dockerd` inside the VM needs valid cgroup mounts (v1 vs v2 hybrid issues), `mount` propagation, and likely a larger memory footprint than currently allocated.
    *   **Requirements**:
        *   Extensive kernel config validation (checking if Firecracker kernel supports all Docker check-config requirements).
        *   Cgroup hierarchy passthrough or emulation.
        *   Graph driver compatibility (vfs vs overlay2 inside the VM).

---

## Rank 4: Complex Implementation

### 3. Rootfs Caching
*   **Status**: ❌ Missing (Marked In Progress)
*   **Difficulty**: 4/5
*   **Analysis**:
    *   **Challenge**: Currently, `runcvm-ctr-firecracker` rebuilds the ext4 rootfs image from scratch on *every* boot (copying files from container directory to `/dev/shm`). This is the main bottleneck for boot time (~5-10s for large images).
    *   **Gap**: No caching mechanism exists. `create_rootfs_from_dir` is always called.
    *   **Requirements**:
        *   Mechanism to hash the container image layers/content to create a cache key.
        *   Persistent cache storage (host folder).
        *   Logic to create a "base" immutable rootfs and use a CoW (Copy-on-Write) overlay (snapshot) for the active VM instance, so the base image isn't modified. Firecracker supports this via `is_read_only` drive + snapshot, but `runcvm` logic needs to support it.

### 4. Systemd Containers
*   **Status**: ✅ Complete (Rank 4 Solved!)
*   **Difficulty**: 4/5
*   **Analysis**:
    *   **Challenge**: Systemd requires being PID 1, Cgroups mounted in a specific way, and signal handling.
    *   **Solution**: Implemented PID namespace isolation using `unshare -p`. This allows the container entrypoint to fork a `systemd` process that believes it is PID 1 in its own namespace (`/sbin/init`), while the outer runtime manages the lifecycle.
    *   **Result**: Validated with `verify-systemd.sh`. SSH, Cron, and Systemd services start correctly.

### 5. Volume Drivers
*   **Status**: ❌ Missing
*   **Difficulty**: 4/5
*   **Analysis**:
    *   **Challenge**: Docker plugins for volumes (e.g., NetApp, RexRay) expect to mount storage on the host and bind-mount it.
    *   **Gap**: `runcvm` uses NFS for host mounts. External volume drivers might mount to a path the unfsd daemon doesn't see or can't export properly, or requires `virtiofs` (which Firecracker lacks).
    *   **Requirements**:
        *   Integration with external storage backends potentially passing block devices to Firecracker (virtio-blk) instead of NFS, if the driver provides a block device.

---

## Rank 3: Moderate Complexity

### 6. Docker Attach
*   **Status**: 🟡 Partial
*   **Difficulty**: 3/5
*   **Analysis**:
    *   **Challenge**: Connecting to the stdio of a running process.
    *   **Gap**: `runcvm` handles interactive mode (`-it`) via TTY passing, but `docker attach` to a *detached* container is different. It requires tapping into the console stream or existing socket.
    *   **Requirements**:
        *   Ensuring the Firecracker console stream (`/dev/ttyS0` or log pipe) is accessible and can be multiplexed.
        *   Handling input forwarding to an already running process.

### 7. Docker CP
*   **Status**: ❌ Missing
*   **Difficulty**: 3/5
*   **Analysis**:
    *   **Challenge**: Copying files in/out of a running (or stopped) container.
    *   **Gap**: `docker cp` usually assumes it can access the container rootfs on the host. For `runcvm`, the rootfs is inside an ext4 image (file) or running VM.
    *   **Requirements**:
        *   Stopped container: Ability to mount the ext4 image on host to copy files (requires `sudo mount -o loop`, which might be privileged/unsafe).
        *   Running container: `docker cp` falls back to `docker exec tar ...` which should work if `exec` works, but needs verification of stream handling (binary data integrity).

---

## Rank 2: Low Complexity / Extension

### 8. Tmpfs Mounts
*   **Status**: 🟡 Partial
*   **Difficulty**: 2/5
*   **Analysis**:
    *   **Gap**: `runcvm-runtime` extracts `tmpfs` mounts from config and saves them to `RUNCVM_TMPFS` env var. However, **`runcvm-ctr-firecracker` does not use this variable**.
    *   **Solution**:
        *   Add a loop in `runcvm-ctr-firecracker` (inside `setup_nfs_volumes` or similar init stage) to parse `RUNCVM_TMPFS` and execute `mount -t tmpfs -o options ...`.
        *   Straightforward bash scripting.

### 9. Restart Policies
*   **Status**: 🟡 Untested
*   **Difficulty**: 2/5
*   **Analysis**:
    *   **Challenge**: Ensuring Docker restarts the container when it exits/fails.
    *   **Gap**: Untested.
    *   **Solution**:
        *   Verify that `runcvm` processes exit with the same code as the internal VM process (or 1 on runtime error).
        *   If exit codes are propagated correctly, Docker handles the restart logic automatically.
        *   Task is primarily verification and fixing exit code propagation if broken.

---

## Summary Implementation Plan

1.  **Quick Wins (Rank 2)**:
    *   Implement **Tmpfs** mounting (High impact, low effort).
    *   Verify **Restart Policies** (Validation only).

2.  **Core Priorities (Rank 3-4)**:
    *   **Rootfs Caching** (Rank 4): Critical for performance goals (<500ms boot).
    *   **Docker CP** (Rank 3): Important utility.

3.  **Long Term (Rank 5)**:
    *   **DinD / Systemd**: Enable for advanced users later.
    *   **Network Connect**: Low priority, rarely used in immutable infra.
