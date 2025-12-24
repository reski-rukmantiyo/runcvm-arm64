# RunCVM Kubernetes Troubleshooting Guide

This guide provides solutions for common issues encountered when running Firecracker microVMs inside Kubernetes Pods using RunCVM.

---

## 1. Entrypoint Not Executing
**Symptoms:**
- Pod is `Running` but nothing happens.
- `kubectl logs` shows `cat: /data/test.txt: No such file or directory` or similar "missing file" errors for things that should be there.
- Logs show `[VM-START] No entrypoint found, sleeping`.

**Possible Causes:**
1.  **Path Mismatch:** The entrypoint script is looking for the command in the wrong location.
2.  **Mount Failure:** If the command depends on shared storage (NFS), it may have failed to mount (see Section 3).
3.  **Shell Incompatibility:** The entrypoint command uses shell features (e.g. `&&` or `||`) that aren't available in the guest's minimal shell.

**Solutions:**
- **Consolidate Paths**: Ensure both host and guest scripts use `/.runcvm/entrypoint` for command injection.
- **Check Logging**: Set `RUNCVM_LOG_LEVEL=DEBUG` in the Pod environment to see the exact path being loaded by `runcvm-vm-start`.
- **Use Sequential Commands**: Avoid using `&&` in the Pod `command` if the first command might fail; use `;` instead to keep the container alive for debugging:
  ```yaml
  command: ["sh", "-c", "cat /data/test.txt; sleep 3600"]
  ```

---

## 2. No Internet Access (Default Gateway)
**Symptoms:**
- `ping 8.8.8.8` returns `Network unreachable`.
- `TX` packet counter on guest `eth0` remains at `0`.

**Cause: MAC Address Filtering**
Most cloud environments and CNIs drop packets if the source MAC address doesn't match the one assigned to the Pod.

**Solution: MAC Swapping**
RunCVM implements "MAC Swapping" automatically. It assigns the Pod's **Real MAC** to the VM and moves a **Dummy MAC** to the host-side bridge.
- Verify that `runcvm-ctr-firecracker-k8s` is performing the swap by checking `kubectl logs`.
- Ensure the Host-side bridge (`br-eth0`) does **NOT** have an IP that conflicts with the gateway.

**Cause: Interface Initialization Race**
Hypervisors (like Firecracker) may take a few hundred milliseconds to fully initialize the virtio-net device. If the guest `init` script checks too early, it will report "No ethernet interfaces found".

**Solution: Wait Loop**
RunCVM includes a 10-second wait loop in `firecracker-init.sh` to poll for the interface:
```bash
# Look for eth0 in /sys/class/net
for i in $(seq 1 100); do
  ls /sys/class/net/eth* >/dev/null 2>&1 && break
  sleep 0.1
done
```
Verify this in guest logs: `[RunCVM-FC-Init] [INFO]   Waiting for eth* interface...`

---

## 3. Storage & NFS Mount Failures
**Symptoms:**
- `kubectl logs` shows `✗ Failed to mount /data via NFS`.
- General network instability inside the VM.

**Cause: IP Conflicts (The "169.254.x.x" Problem)**
- **Historical Conflict**: Previously, the host bridge used `169.254.1.1`, which is often the Link-Local Gateway in AWS/Cloud. This caused packets to be swallowed by the bridge itself.
- **MicroVM Conflict**: If the Guest VM and Host Bridge share an IP, ARP resolution fails and the NFS connection is refused.

**Solution:**
1.  **Dedicated Host IP**: RunCVM now uses `169.254.1.254` as the dedicated "Identity IP" for the host bridge.
2.  **Guest Logic**: The guest init script (`firecracker-init.sh`) is configured to prioritize `169.254.1.254` as the target for NFS exports.
3.  **Routing**: The guest must have a specific route to this IP:
    ```bash
    ip route add 169.254.1.254 dev eth0
    ```

**Cause: PVC Identification & Redirection**
In some environments, PVCs mounted to `/var/lib/kubelet` might not be correctly identified by the runtime, leading to mounting failures or host-path conflicts.

**Solution: Unique Volume Redirection**
RunCVM redirects "True PVCs" (network volumes) to isolated host-side directories (`/.runcvm/vols/<id>`) before they are exported via NFS.
- Look for `[RunCVM-Runtime] FIRECRACKER: PVC Redirect: /data -> /.runcvm/vols/<id>` in the host-side debug logs.
- Verify that the guest mount matches: `169.254.1.254:/.runcvm/vols/<id> on /data type nfs`.

---

## 4. Log Visibility
**Symptoms:**
- `kubectl logs` is empty or very sparse.

**Solution:**
1.  **TTY Redirection**: Ensure the guest init script redirects output to `/dev/ttyS0` (the Firecracker console).
2.  **Debug Mode**: Set `RUNCVM_LOG_LEVEL=DEBUG` in your Pod YAML:
    ```yaml
    env:
    - name: RUNCVM_LOG_LEVEL
      value: "DEBUG"
    ```
3.  **Check Terminal**: Firecracker logs directly to the container's stdout. If you are using a custom entrypoint, ensure it doesn't background the launcher or close stdout.

---

## 5. Debugging Tools

### Inspecting RootFS without Booting
If you suspect files (like the entrypoint) aren't in the VM, inspect the image on the node:
```bash
# Inside the Kubernetes Node (e.g. Colima)
debugfs -R "ls -l /.runcvm" /rootfs.ext4
```

### Checking Network State
From inside the container (host side):
```bash
ip addr show br-eth0
ip link show tap-eth0
```
- `br-eth0` should have IP `169.254.1.254/32`.
- `br-eth0` should **NOT** have the Pod's real IP (that's for the Guest).
- Both the physical `eth0` and the VM `tap-eth0` should be members of `br-eth0`.

---

## 6. Boot Loop and Guest Tooling Failures
**Symptoms:**
- VM cycles through "Ready" and "Terminated" (CrashLoopBackOff).
- Logs show `mke2fs` success but VM fails shortly after.
- Errors like `mount: not found` or `socat: relocation error` in logs.
- MySQL fails with `error: stat /proc/self/exe: no such file or directory`.

**Cause 1: Rootfs Corruption (Truncation)**
If the container content (e.g. MySQL ~2.4GB) is larger than the default rootfs size (256MB), the image might be truncated and corrupted during creation.

**Cause 2: Incomplete PATH or Missing Tools**
The minimal guest environment may not have `mount`, `ip`, or libraries in the expected `PATH`, preventing essential services (like `/proc` mounting) or networking from starting.

**Solutions:**
1. **Enable Content-Aware Resizing**: Ensure your `runcvm` version includes the `resize_rootfs_if_needed` fix which prevents shrinking rootfs below its content size.
2. **Check Guest Tool Path**: Verify that `/.runcvm/guest/bin` and other guest tool directories are at the front of the `PATH` in `firecracker-init.sh`.
3. **Proc Mount Check**: Many tools (including MySQL and `ps`) require `/proc`. Ensure the init script successfully mounts it:
   ```bash
   # Verify inside the VM
   mount | grep proc
   ```
4. **Library Dependencies**: If you see `relocation error`, check that required libraries (like OpenSSL for `socat`) are bundled in `/.runcvm/guest/lib`.

---

## 7. Binary Mismatches (Host vs. Guest)
**Symptoms:**
- Logs show `required file not found` when executing `jq` or `kubectl`.
- `docker exec` returns `Exit before auth`.

**Cause: ELF Interpreter Conflict**
RunCVM involves two distinct environments:
1.  **Host (Node)**: Where `runcvm-runtime` executes (usually Ubuntu/Debian/glibc).
2.  **Guest (VM)**: Where the container executes (usually Alpine/musl).

If a script on the host tries to use a binary bundled for the guest, it will fail because the host cannot find the `musl` dynamic linker at the guest-specific path.

**Solution:**
- **Host-side**: Always use system binaries (`/usr/bin/jq`, `/usr/local/bin/k3s`) instead of bundled versions.
- **Guest-side**: Use bundled binaries with the absolute path to the linker (`/.runcvm/guest/lib/ld`).
- **json.sh Wrapper**: The `jq` function in `common/json.sh` is designed to intelligently switch between native execution (on host) and linker-prepended execution (on guest):
  ```bash
  # Logic inside json.sh
  if [[ "$RUNCVM_JQ" == "$RUNCVM"* ]]; then
    $RUNCVM_LD "$RUNCVM_JQ" "$@"
  else
    "$RUNCVM_JQ" "$@"
  fi
  ```

---

## 8. Logging Permissions & Conflicts
**Symptoms:**
- `Permission denied` when writing to `/tmp/runcvm-runtime.log`.

**Cause:**
Multiple containers in a Kubernetes pod (e.g. `pause` and `mysql`) execute as different users but may attempt to write to the same global log file.

**Solution: Per-Container Logs**
RunCVM uses isolated debug logs for each container ID to prevent resource contention and permission issues:
- Logs are stored at `/tmp/runcvm-<id>.debug`.
- Use `sudo ls -l /tmp/runcvm*.debug` on the host to find the relevant log for your container.
- These logs capture detailed runtime initialization and Kubernetes metadata discovery.

---

## 9. K3s RuntimeClass Configuration Issues
**Symptoms:**
- `kubectl describe pod` shows `Warning FailedCreatePodSandBox ... no runtime for "runcvm" is configured`.
- k3s logs show `Unknown runtime handler "runcvm"`.

**Possible Causes:**
1.  **Missing RuntimeClass**: The Kubernetes `RuntimeClass` resource named `runcvm` has not been applied.
2.  **Template Syntax Error**: The TOML in `config-v3.toml.tmpl` is invalid or uses an incorrect plugin path.
3.  **Incorrect runtime_type**: The `runtime_type` is set to `runcvm` instead of `io.containerd.runc.v2`.

**Solutions:**
- **Verify RuntimeClass**: `kubectl get runtimeclass runcvm`
- **Verify Template**: Ensure the section name is `[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runcvm]` (note the quotes).
- **Restart K3s**: Changes to the template require a full restart: `sudo systemctl restart k3s`.

---

## 10. Firecracker KVM Errors
**Symptoms:**
- Pod logs show `Error: RunWithoutApiError(BuildMicroVMFromJson(StartMicroVM(Kvm(Kvm(Error(19))))))`.

**Cause: Virtualization Disabled**
Hardware virtualization (KVM) is not available or enabled on the node.

**Solutions:**
- **Check Device**: Run `ls -l /dev/kvm`. If it missing, KVM is not enabled in the BIOS/Firmware.
- **Nested Virtualization**: If your Node is a VM (e.g. running on Apple Silicon via Colima or UTM), you must explicitly enable nested virtualization in the hypervisor settings.
- **Permissions**: Ensure the k3s process has read/write access to `/dev/kvm`.
