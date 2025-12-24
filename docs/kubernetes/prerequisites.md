# Kubernetes Prerequisites for RunCVM

To successfully run `runcvm` (Firecracker microVMs) in a Kubernetes cluster, the underlying Node (Host) must meet specific requirements. Since `runcvm` relies on hardware virtualization and specialized networking, these prerequisites are critical.

## 1. Kernel Modules & Devices

The Kubernetes Node (the Linux host where the Pod runs) must have the following kernel modules loaded and devices available.

### Virtualization (KVM)
*   **Requirement:** Access to `/dev/kvm`.
*   **Modules:** `kvm`, `kvm_intel` (Intel), `kvm_amd` (AMD), or built-in KVM support (ARM64).
*   **Verification:**
    ```bash
    ls -l /dev/kvm
    # Should be owned by root:kvm or similar, and writable by the container user (or use privileged mode).
    ```

### VSOCK (Virtual Socket)
*   **Requirement:** Access to `/dev/vhost-vsock`.
*   **Purpose:** Critical for `kubectl exec` and `logs` functionality, which uses VSOCK to bypass the guest network for stable management connectivity.
*   **Modules:** `vhost_vsock`.
*   **Loading:**
    ```bash
    modprobe vhost_vsock
    ```
*   **Verification:**
    ```bash
    ls -l /dev/vhost-vsock
    ```

### TUN/TAP Networking
*   **Requirement:** Access to `/dev/net/tun`.
*   **Purpose:** Required for creating the TAP interfaces used by Firecracker to connect to the host bridge.
*   **Verification:**
    ```bash
    ls -l /dev/net/tun
    ```

## 2. Required Host Binaries

The `runcvm` container (Host Container) relies on certain tools being available, either baked into the image or available on the host if mounting paths. **Ideally, these should be in the container image**, but if you are relying on host tools:

*   **`socat`**: **CRITICAL**. Used for proxying `kubectl exec` traffic between the API server (TCP) and the Firecracker VSOCK or local listener.
*   **`ip` (iproute2)**: Required for bridge creation, interface management, and routing.
*   **`iptables`**: Required for setting up NAT/Masquerade rules if using standard bridging modes.

## 3. Pod Security Context

Firecracker requires low-level system access (`/dev/kvm`, `/dev/net/tun`, etc.).

*   **RuntimeClass Automation:** If you use `runtimeClassName: runcvm`, the container runtime (configured on the node) typically injects the necessary capabilities (`CAP_SYS_ADMIN`, `CAP_NET_ADMIN`) and device mounts automatically. You usually **do not** need to manually add `privileged: true` to your Pod YAML.
*   **Manual Debugging:** If you are running a container manually (e.g., `docker run`) without the runtime class, you **MUST** use `--privileged` or explicitly add the capabilities and devices.
    ```yaml
    # Only if NOT using runtimeClassName: runcvm
    securityContext:
      privileged: true
    ```

## 4. Hardware Resources
*   **Nested Virtualization (Cloud/VMs):** If your Kubernetes Nodes are themselves VMs (e.g., AWS EC2, GCP), you must enable **Nested Virtualization**. Check your cloud provider's documentation for instance types that support "Bare Metal" or nested virtualization (e.g., AWS `.metal` instances or specific config on GCP).

## 5. Network Configuration (CNI)
*   **Promiscuous Mode (Optional/Recommended):** Some CNI plugins (like Calico/Flannel) filter traffic based on MAC address. Since Firecracker VMs have their own MACs:
    *   `runcvm` handles MAC swapping to mitigate this.
    *   However, ensuring the CNI allows "unknown" MACs or promiscuous mode on the veth interface can prevent issues.

## 6. K3s Specific Configuration

To use `runcvm` with K3s, you must configure Containerd to recognize the custom runtime using the template system.

### Configure Containerd Template
On **every node** where you want to run Firecracker workloads, create or edit:
`/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl`

Append the `runcvm` runtime plugin configuration. Note that for modern K3s, the plugin path uses `io.containerd.cri.v1.runtime`.

```toml
{{ template "base" . }}

# --- RUNCVM CONFIGURATION ---
[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runcvm]
  runtime_type = "io.containerd.runc.v2"    # MUST be io.containerd.runc.v2
  [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runcvm.options]
    BinaryName = "/opt/runcvm/scripts/runcvm-runtime" # Path to the wrapper script
    SystemdCgroup = true
# -----------------------------
```

### Restart K3s
Force k3s to regenerate `config.toml` by restarting the service:
```bash
sudo systemctl restart k3s
```

### Define the RuntimeClass
Apply the following YAML to your cluster. **This is required** for Kubernetes to know which handler to use when a Pod specifies `runtimeClassName: runcvm`.

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: runcvm
handler: runcvm
```