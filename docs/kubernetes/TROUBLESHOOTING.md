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
