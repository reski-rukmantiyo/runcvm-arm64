# Docker-in-Docker (DinD) Support in RunCVM

RunCVM now supports running Docker-in-Docker (DinD), allowing you to run nested Docker containers within a RunCVM Firecracker microVM. This capability is particularly useful for CI/CD pipelines, development environments, and specialized workloads requiring isolation.

## 🚀 Overview

- **Status**: ✅ Supported (Experimental)
- **Requires**: `RUNCVM_SYSTEMD=true` (recommended), Privileged mode logic (handled via security options)
- **Performance**: Near-native for nested containers thanks to `cgroupfs` driver
- **Isolation**: Each outer container is a separate VM; inner containers share that VM's kernel.

## 📋 Prerequisites

To run DinD efficiently in RunCVM, the following configurations are required or highly recommended:

1.  **SystemD Mode**: The outer container should run SystemD as PID 1 to properly manage the inner specific Docker daemon services.
2.  **Kernel Arguments**: We force Cgroup v1 hierarchy because the Firecracker kernel has partial support for Cgroup v2 features required by `runc`.
3.  **Storage Driver**: The inner Docker daemon uses `overlay2` over the existing filesystem (if supported) or `vfs`.
4.  **Cgroup Driver**: The inner Docker daemon **MUST** be configured to use `cgroupfs` driver, as `systemd` cgroup driver is not fully compatible with the nested environment's cgroup structure.

## 🛠 Usage Guide

### 1. Preparing the Image

Your Docker image for the *outer* container needs to be set up to run SystemD and include the Docker engine.

**Example `Dockerfile`**:
```dockerfile
FROM ubuntu:24.04

# Install systemd, docker, and dependencies
RUN apt-get update && apt-get install -y \
    systemd \
    docker.io \
    iptables \
    ca-certificates \
    && apt-get clean

# Important: Use legacy iptables for Firecracker kernel compatibility
RUN update-alternatives --set iptables /usr/sbin/iptables-legacy && \
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

# Configure Docker Daemon for DinD in RunCVM
RUN mkdir -p /etc/docker && \
    echo '{ \
    "exec-opts": ["native.cgroupdriver=cgroupfs"], \
    "cgroup-parent": "", \
    "default-runtime": "custom-runc", \
    "runtimes": { \
        "custom-runc": { \
            "path": "runc", \
            "runtimeArgs": ["--systemd-cgroup=false"] \
        } \
    } \
    }' > /etc/docker/daemon.json

# Enable Docker service
RUN systemctl enable docker

# Set init as entrypoint
CMD ["/sbin/init"]
```

### 2. Running the Container

You need to pass specific environment variables to enable the necessary features in RunCVM.

**Command**:
```bash
docker run -d --name runcvm-dind --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -e RUNCVM_SYSTEMD=true \
  -e RUNCVM_KERNEL_ARGS="systemd.unified_cgroup_hierarchy=0" \
  my-dind-image
```

*   `RUNCVM_SYSTEMD=true`: Enables SystemD support (PID namespace isolation).
*   `RUNCVM_KERNEL_ARGS="systemd.unified_cgroup_hierarchy=0"`: **CRITICAL**. Forces the kernel to use Cgroup v1, which avoids complex incompatibility issues with nested `runc` and BPF cgroup device controllers missing in the minimal kernel.

### 3. Running Inner Containers

Once inside the outer container, you can run Docker commands as usual.
**Note**: You may need to relax security profiles for inner containers if you encounter permission errors.

```bash
# Exec into the outer container
docker exec -it runcvm-dind bash

# Run a nested container
docker run --rm \
  --security-opt seccomp=unconfined \
  --security-opt apparmor=unconfined \
  alpine echo "Hello from inside Firecracker!"
```

## 🔍 Troubleshooting

| Issue | Cause | Solution |
| :--- | :--- | :--- |
| **Docker daemon fails to start** | `nftables` missing in kernel | Ensure `iptables-legacy` is selected via `update-alternatives`. |
| **Inner container fails: `bpf_prog_query ... failed`** | `systemd` cgroup driver requires BPF | Configure `/etc/docker/daemon.json` to use `"native.cgroupdriver=cgroupfs"` and disable systemd cgroups for runc. |
| **Permission denied (cgroup mounts)** | standard `runc` cgroup management | Use `RUNCVM_KERNEL_ARGS="systemd.unified_cgroup_hierarchy=0"` to simplify cgroup structure. |

## ⚙️ Architecture details for Contributors

The implementation relies on:
1.  **Modified `runcvm-ctr-firecracker`**: Extracts `RUNCVM_KERNEL_ARGS` and appends them to the kernel boot command line.
2.  **Kernel Config**: Uses the existing Firecracker-compatible kernel but requires runtime parameter tuning (cgroup v1 enforcement).
3.  **User-space Workarounds**: Configuring the inner Docker daemon to avoid dependencies on features not present in the guest kernel (like advanced BPF cgroup controllers).
