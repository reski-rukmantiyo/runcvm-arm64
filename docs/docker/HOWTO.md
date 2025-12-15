# RunCVM Firecracker: HOWTO Guide

This guide provides comprehensive instructions for running various workloads with RunCVM's Firecracker runtime. It covers standard usage, advanced configurations like Docker-in-Docker (DinD) and Systemd, as well as Storage and Networking features.

## Prerequisites

Ensure you have `runcvm` installed and configured as a Docker runtime.

## 1. Standard Usage

RunCVM allows you to run standard Docker containers inside Firecracker microVMs. The core requirement is specifying the runtime and the hypervisor environment variable.

### Basic Syntax
```bash
docker run --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker [IMAGE] [COMMAND]
```

### Examples

#### Alpine Linux (Simple Shell)
A lightweight example to verify the runtime.
```bash
docker run --rm -it --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  alpine /bin/sh
```

#### Ubuntu (distribution benchmark)
Running a standard distribution image.
```bash
docker run --rm -it --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  ubuntu:latest bash
```

---

## 2. Docker-in-Docker (DinD)

RunCVM supports running Docker inside a Firecracker microVM. This requires privileged mode and systemd support to manage the inner Docker daemon.

### Requirements
- `--privileged`: Required for DinD operations.
- `RUNCVM_SYSTEMD=true`: Required to manage services.
- `RUNCVM_KERNEL_ARGS="systemd.unified_cgroup_hierarchy=0"`: (Optional) May be needed for cgroup v1 compatibility if strictly required by inner workloads, though modern DinD supports v2.

### Example
Running a DinD container and executing a command inside the inner Docker:

```bash
docker run --privileged --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -e RUNCVM_SYSTEMD=true \
  docker:dind dockerd & 
  
# Or using a custom image with systemd and docker pre-installed:
docker run --rm --privileged --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -e RUNCVM_SYSTEMD=true \
  runcvm-dind
```

---

## 3. Systemd Support

RunCVM can run containers with systemd as PID 1, allowing you to run full OS environments and manage services like `sshd`, `cron`, or web servers.

### Requirements
- **Recommended**: `--privileged`
  - Ensures the runtime has permission to set up all VM components (networking, storage).
  - Ensures the VM kernel has full capability to support systemd's cgroup and mount requirements.
- **Alternative**: `--cap-add=SYS_ADMIN --cap-add=NET_ADMIN --device=/dev/kvm --device=/dev/net/tun`
  - If you need to avoid full privileges, you must grant:
    - `SYS_ADMIN`: For systemd namespace/cgroup management.
    - `NET_ADMIN`: For network interface creation.
    - Device access to `/dev/kvm` and `/dev/net/tun`.
- `RUNCVM_SYSTEMD=true`: Activates the PID namespace isolation and init logic for systemd.

### Examples

#### Ubuntu with Systemd
```bash
docker run -d --privileged --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -e RUNCVM_SYSTEMD=true \
  ubuntu-systemd
```

#### Nginx (Managed by Systemd)
If you want to run Nginx as a systemd service inside a full VM environment.
```bash
# Assuming an image 'nginx-systemd' that enables nginx.service
docker run -d --privileged --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -e RUNCVM_SYSTEMD=true \
  -p 8080:80 \
  nginx-systemd
```
*(Note: For simple Nginx usage without systemd, see the [Network](#5-network) section).*

---

## 4. Storage

RunCVM supports standard Docker storage options, utilizing NFS for high-performance file sharing between host and guest.

### Features
- **Bind Mounts**: `-v /host/path:/container/path`
- **Named Volumes**: `-v volume_name:/data`
- **Read-Only**: `:ro` suffix supported.

### Example: MySQL with Persistence
Running a MySQL database with a named volume for data persistence.

```bash
# 1. Create volume
docker volume create mysql-data

# 2. Run MySQL
docker run -d \
  --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -v mysql-data:/var/lib/mysql \
  -e MYSQL_ROOT_PASSWORD=my-secret-pw \
  -p 3306:3306 \
  mysql:latest
```

---

## 5. Network

RunCVM supports Bridge (default) and Host networking modes, covering most use cases.

### Host Networking
To share the host's network stack (simulated via NAT/TAP in Firecracker), you must explicitly enable host mode in RunCVM.

**Requirements:**
- `--net=host`
- `RUNCVM_NETWORK_MODE=host`
- `--privileged`: Required to configure host networking rules.

#### Example: Nginx on Host Network
Running Nginx directly on the host's network interface.

```bash
docker run -d --privileged --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -e RUNCVM_NETWORK_MODE=host \
  --net=host \
  nginx:latest
```

### Multi-NIC Support
RunCVM automatically detects and configures multiple network interfaces.

```bash
docker network create net1
docker network create net2

docker run --rm --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  --net net1 \
  --net net2 \
  alpine ip addr show
```
