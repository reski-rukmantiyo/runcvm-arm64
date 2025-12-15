# Networking in Firecracker Mode

RunCVM Firecracker Edition supports robust networking capabilities, matching standard Docker behavior while maintaining microVM isolation.

## Supported Network Modes

| Docker Network Mode | RunCVM Support | Implementation Details |
|---------------------|----------------|------------------------|
| **Bridge (Default)** | ✅ Full | Uses bridge devices, standard Docker IPAM. |
| **Custom Networks** | ✅ Full | Supports multiple networks/NICs per container. |
| **Host (`--net=host`)** | ✅ Full* | Uses NAT/TAP with IP Masquerading. |
| **None (`--net=none`)** | ✅ Full | No network interfaces created. |

---

## Multiple Network Interfaces (Multi-NIC)

RunCVM automatically detects when a container is attached to multiple Docker networks and creates corresponding network interfaces inside the Firecracker microVM.

### Usage
Simply use the standard Docker syntax:
```bash
docker run --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  --net runcvm-net1 \
  --net runcvm-net2 \
  alpine ip a
```

**Result inside VM:**
- `eth0`: Connected to `runcvm-net1`
- `eth1`: Connected to `runcvm-net2`
- Separate gateways and routes are configured automatically.

---

## Host Networking (`--net=host`)

> [!IMPORTANT]
> **Requirement**: Host networking REQUIRES the `--privileged` flag to configure NAT tables and IP forwarding.

In standard Docker, `--net=host` removes network isolation, sharing the host's network namespace. In Firecracker, we cannot share the host's physical interface directly without breaking host connectivity. Instead, RunCVM uses a **NAT/TAP** approach.

### How it Works
1. RunCVM creates a `tap0` device connected to the VM.
2. The VM is assigned a private Link-Local IP (`169.254.100.2`).
3. RunCVM configures IP Masquerading (NAT) on the host's default gateway.
4. Outbound traffic from the VM appears to come from the host's IP.

### Usage
You must specify **both** `--net=host` and the explicit `RUNCVM_NETWORK_MODE=host` environment variable:

```bash
docker run --rm --privileged --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -e RUNCVM_NETWORK_MODE=host \
  --net=host \
  alpine ip a
  --net=host \
  alpine ip a
```

---

## Dynamic IP Allocation (Internal)

To ensure robust internal routing between the container namespace and the microVM, RunCVM implements a **Dynamic IP Alias** system.

*   **Problem**: Standard Docker containers and Firecracker VMs coexist in separate network scopes but share the same IP. This confuses the kernel, leading to routing loops for local traffic (e.g., `docker exec`).
*   **Solution**: RunCVM automatically calculates a **Network Alias IP** (derived from the subnet broadcast address, e.g., `172.17.255.254` for a `/16` network) and assigns it to the internal bridge `br-eth0`. It also removes the conflicting container IP from the bridge, forcing L2 routing to the VM.
*   **Benefit**: This is fully transparent to the user but enables reliable connectivity for `docker exec` and direct VM access.

---

## Best Practices: Interactive Access

While `docker exec -it <container> /bin/sh` is supported (via a Dropbear SSH sidecar), it involves complex routing layers. For the most robust interactive experience (especially for development), we recommend using **Standard SSH**.

### Recommended Pattern
Map the Firecracker VM's SSH port (22) to a host port:

```bash
docker run -d -p 2222:22 --runtime=runcvm ... my-image
ssh -p 2222 root@localhost
```

This gives you a full, standard OpenSSH session directly to the VM, bypassing the limitations of `docker exec`.

> [!WARNING]
> **Systemd Required**: Standard SSH (Port 22) availability depends on the container running an SSH server daemon (like `openssh-server`). To ensure services start correctly, you must run the container with systemd enabled:
> `-e RUNCVM_SYSTEMD=true`


---

## Troubleshooting

### "Read-only file system" / "iptables not found"
If you see errors related to `ip_forward` or `iptables` when using Host Mode, start the container with `--privileged`. This is required to modify network stack rules on the host runner.

```bash
docker run --privileged ...
```
