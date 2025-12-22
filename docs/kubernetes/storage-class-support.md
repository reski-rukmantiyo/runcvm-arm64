# RunCVM Volume Redirection & Redirection

This document describes how RunCVM handles Kubernetes volumes (PersistentVolumes, PVCs, ConfigMaps, Secrets, and Projected volumes) to ensure clean isolation and reliable NFS export to the guest VM.

## Architecture

Kubernetes volumes are mounted by the Kubelet on the worker node. For RunCVM (running as a CRI runtime), these volumes appear as bind mounts in the OCI `config.json`.

To provide high-performance, bidirectional access to these volumes from within the Firecracker microVM, RunCVM uses a **Redirection & Isolation** strategy.

### 1. Detection

RunCVM-Runtime identifies Kubernetes volumes by matching their source path on the host against standard Kubelet patterns:

```bash
/var/lib/kubelet/pods/*/volumes/kubernetes.io~*/*
```

This "fast-path" detection covers:
- **NFS / PV / PVC**: `kubernetes.io~nfs`, `kubernetes.io~local-volume`, etc.
- **Secrets**: `kubernetes.io~secret`
- **ConfigMaps**: `kubernetes.io~configmap`
- **Projected**: `kubernetes.io~projected`

### 2. Redirection

Once identified, the volume is redirected from its original path to a unique, isolated directory within the container:

```bash
[Host Source] -> /.runcvm/vols/<vol-id>
```

The `<vol-id>` is a stable hash derived from the volume's destination path inside the container. This redirection provides:
- **Clean Isolation**: Volumes are separated from the container's root filesystem.
- **Stable NFS Export**: The isolated path provides a reliable mount point for the `unfsd` daemon.

### 3. Guest Mounting

Inside the guest VM, the volume is mounted via NFSv3 from the host-side `unfsd` daemon.

```bash
# Example mount inside Guest VM
169.254.1.254:/.runcvm/vols/30de4000 on /var/lib/mysql type nfs (rw,vers=3,nolock,tcp,port=1045)
```

## Benefits

- **No kubectl Dependencies**: Standard K8s volumes are identified instantly via path patterns, removing the need for slow external API calls.
- **Full K8s Support**: Automatically handles all standard K8s volume types.
- **Bidirectional Persistence**: Changes made inside the guest VM are immediately reflected on the host-side PV/PVC.
- **Isolation**: Prevents accidental exposure of host-side paths to the guest VM environment.

## Verification

You can verify redirection by checking the `runcvm-runtime` logs:

```text
[INFO] K8S: Identified K8s volume via path pattern: .../volumes/kubernetes.io~local-volume/...
[INFO] FIRECRACKER:   PVC Redirect: /var/lib/mysql -> /.runcvm/vols/30de4000
```

