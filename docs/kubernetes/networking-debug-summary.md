# Kubernetes Network Debugging & Architecture Fixes

**Date:** 2025-12-19
**Context:** Getting Firecracker microVMs to run inside Kubernetes Pods (`runcvm`) with full outbound connectivity.

## Overview
This document summarizes the challenges encountered while enabling networking for `runcvm` in a Kubernetes environment (specifically Colima/K3s) and the architectural solutions implemented to resolve them.

---

## 1. Problem: `kubectl exec` Failure ("Connection Refused")
**Symptoms:** `kubectl exec` would fail immediately or hang.
**Cause:**
*   **Race Condition:** The `socat` proxy was starting before the VM's SSH server (`dropbear`) was ready.
*   **Transport Mismatch:** The system was trying to use TCP over the bridge before the bridge was fully functional, while VSOCK was the preferred stable channel.
*   **Arg Parsing:** `dropbear` arguments in the init script were incorrect (`-s 0.0.0.0`), causing it to fail on startup.

**Solution:**
*   **Retry Logic:** Added robust retry loops to `runcvm-ctr-exec` to wait for the VM's presence.
*   **VSOCK Priority:** Prioritized VSOCK transport for `kubectl exec`, bypassing the complex Layer 2 network bridge for control plane operations.
*   **Script Fixes:** Corrected `dropbear` launch arguments in `runcvm-vm-init-k8s`.

---

## 2. Problem: Outbound Packet Loss (0 TX Packets)
**Symptoms:** Routing table looked correct, but `ping 8.8.8.8` failed. Packet counters on the guest interface showed `TX: 0`.
**Cause:** **Layer 2 MAC Filtering**.
*   Cloud providers and some CNI plugins (like Flannel/Calico in strict modes) filter traffic that doesn't match the assigned MAC address of the Pod.
*   The Firecracker VM was generating a *random* MAC address, which the underlying network dropped immediately.

**Solution: MAC Address Swapping / Spoofing**
*   **Guest (VM):** We now assign the **Real Container MAC** (the one Kubernetes expects) to the VM's `eth0`.
*   **Host (Container):** We assign a **Dummy MAC** (e.g., `aa:fc:00:00:00:01`) to the Container's `eth0` (which is now a slave to the bridge).
*   **Result:** The physical network sees packets coming from the "correct" MAC address (originating from the VM), allowing them to pass.

---

## 3. Problem: "Network Unreachable" / Routing Loops
**Symptoms:** `ping 8.8.8.8` failed with "Network unreachable" or "Timeout".
**Cause:** **IP Conflict on the Host Bridge (`br-eth0`).**
*   The `runcvm-ctr-entrypoint-k8s` script was assigning `169.254.1.1` to the host bridge `br-eth0` as a "dummy" IP.
*   **Conflict:** In many setups (including AWS and some CNIs), `169.254.1.1` is the **Link-Local Gateway**.
*   Because the bridge *itself* possessed this IP, the Kernel routed traffic for the Gateway *locally* to the bridge interface instead of sending it out to the wire. The bridge swallowed the packets.

**Solution:**
*   **Remove Bridge IP:** We modified `runcvm-ctr-entrypoint-k8s` to **STOP** assigning `169.254.1.1` (or any conflicting IP) to the bridge. The bridge now operates purely at Layer 2 (switching), transparently passing traffic from the VM to the gateway.

---

## 4. Problem: "File Exists" Errors in Guest Init
**Symptoms:** VM logs showed `RTNETLINK answers: File exists` during startup.
**Cause:** The initialization script `runcvm-vm-init-k8s` was attempting to add IP addresses and routes that might already exist (e.g., if the script re-ran or if the kernel auto-configured something).

**Solution:**
*   **Flush First:** Added `ip addr flush dev eth0` before applying new configurations.
*   **Isempotency:** Used checks (`|| true`) to ensure the script doesn't fail if a route already exists.

---

## Summary of Architecture Changes

### Host Side (`runcvm-ctr-entrypoint-k8s`)
1.  **Bridge Setup:** Creates `br-eth0`.
2.  **MAC Swap:** Moves the Pod's real MAC to the VM config. Sets `eth0` (host side) to a generated MAC.
3.  **No IP:** Does **NOT** assign an IP address to `br-eth0`.
4.  **Wiring:** Attaches host `eth0` and Firecracker's TAP device to `br-eth0`.

### Guest Side (`runcvm-vm-init-k8s`)
1.  **IP Assignment:** Assigns the Pod's real IP and MAC to guest `eth0`.
2.  **Routing:** Adds a simple default route via the Gateway (`onlink` is usually not strictly needed if the subnet is correct, but the gateway must be reachable directly).
3.  **DNS:** Inherits `/etc/resolv.conf` from the host.

## Verification
To verify the fix:
1.  **Recreate Pod:** `kubectl delete pod ...` / `kubectl apply ...`
2.  **Check Bridge IP (Host):** `kubectl exec ... -- ip addr show br-eth0` (Must **NOT** have `169.254.1.1`).
3.  **Ping Test:** `kubectl exec -it ... -- ping 8.8.8.8` (Should work).
