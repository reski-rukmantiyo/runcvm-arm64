# Kubernetes Command Execution Debug Summary

**Date:** 2025-12-21
**Context:** Resolving issues where Kubernetes `command` and `args` (from Pod Spec) were not being executed inside `runcvm` Firecracker MicroVMs.

## Overview
This document summarizes the troubleshooting steps and architectural alignment required to ensure that Kubernetes container entrypoints are correctly captured, injected, and executed within a microVM environment.

---

## 1. Problem: Command Not Executing
**Symptoms:** 
- The Pod starts and remains in `Running` status.
- `kubectl logs` is empty or only shows kernel/init boot messages.
- The intended container process (e.g., `echo`, `nginx`) never starts.
- Logs show fallback to shell: `[VM-START] No entrypoint found, starting shell`.

### Cause: Path Inconsistency
The root cause was a mismatch between the **Host-side Staging** and the **Guest-side Init Script**:
*   **Launcher (`runcvm-ctr-firecracker-k8s`):** Staged the captured entrypoint at `/.runcvm/entrypoint` in the Guest RootFS.
*   **Generated Init (`firecracker-init.sh`):** Looked for the entrypoint at `/.runcvm-entrypoint`.

Because of this mismatch, the `init` script failed to find the entrypoint file and defaulted to starting a shell, which kept the VM alive but didn't run the user's workload.

### Solution
1.  **Aligned Paths:** Updated `firecracker-init.sh` to look for the entrypoint at `/.runcvm/entrypoint`, matching the staging logic.
2.  **Consistently Updated Launchers:** Updated both `runcvm-ctr-firecracker` and `runcvm-ctr-firecracker-k8s` to use the same consolidated path.
3.  **Refined Staging:** Ensured `debugfs` injection points match the finalized path.

---

## 2. Problem: Stale Entrypoints (Caching)
**Symptoms:** 
- Updating the `command` in a Pod Spec didn't take effect if the image was already cached.
- The VM would run the command from the *previous* version of the Pod.

### Cause: RootFS Caching Logic
When `use_cache=1` was active, the launcher used a pre-built `.ext4` image. While it attempted to inject the *current* entrypoint using `debugfs`, it was also using the mismatched path (`/.runcvm-entrypoint`). Furthermore, caching sometimes prevented a completely fresh staging of the environment.

### Solution
*   **Mandatory Injection:** Reinforced the logic to always overwrite `/.runcvm/entrypoint` in the cached image before boot.
*   **User Instruction:** For critical debugging and verification of command execution, **DISABLE** rootfs caching by setting `ROOTFS_CACHE_ACTIVE=0` or `RUNCVM_CACHE_KEY` to a unique value.

---

## 3. Architecture of Command Flow

```mermaid
graph TD
    A[Kubernetes Pod Spec] -->|command/args| B[RunCVM Shim]
    B --> C[runcvm-ctr-entrypoint-k8s]
    C -->|captures args| D[/.runcvm/entrypoint (Host)]
    D --> E[runcvm-ctr-firecracker-k8s]
    E -->|stages file| F[RootFS Staging]
    F -->|mke2fs| G[rootfs.ext4]
    G --> H[Firecracker VM Boot]
    H --> I[Guest /init script]
    I -->|reads /.runcvm/entrypoint| J[runcvm-vm-start]
    J -->|exec $@| K[Container Process]
```

## Verification Checklist

1.  **Check Staging:** If commands fail, verify the file exists in the image before boot:
    ```bash
    debugfs -R "cat /.runcvm/entrypoint" ./rootfs.ext4
    ```
2.  **Verbose Logs:** Run with `RUNCVM_LOG_LEVEL=DEBUG` and check for:
    - `Injected /.runcvm/entrypoint` (Host side)
    - `Running saved entrypoint: ...` (Guest side)
3.  **Manual Build:** Always run `./build.sh` after modifying scripts in `runcvm-scripts` to update the local runtime files on the Kubernetes node.
