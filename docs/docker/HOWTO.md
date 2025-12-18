# RunCVM Firecracker: HOWTO Guide

This guide provides comprehensive instructions for running various workloads with RunCVM's Firecracker runtime. It covers standard usage, advanced configurations like Docker-in-Docker (DinD) and Systemd, as well as Storage and Networking features.

## Prerequisites

Ensure you have `runcvm` installed and configured as a Docker runtime.

## 1. Installation

RunCVM allows standard Docker containers to run as lightweight Firecracker MicroVMs.

### ARM64 (Apple Silicon, AWS Graviton)
For ARM64 architecture, you can install runcvm using our packaged Docker image installer. This script will install the binaries to `/opt/runcvm`, configure `daemon.json`, and set up necessary kernel networking parameters (`rp_filter`).

```bash
docker run --rm --privileged -v /:/host rrukmantiyo/runcvm:arm64 /install
# OR via manual script (if you want to inspect what it does):
curl -sSL https://raw.githubusercontent.com/reski-rukmantiyo/runcvm-arm64/main/runcvm-scripts/runcvm-install-runtime.sh | sudo REPO=rrukmantiyo/runcvm:arm64 sh
```

### AMD64 (x86_64)
Pre-built installer images for AMD64 are currently not available. You must build and install from the source.
Please visit the repository for build instructions:
[https://github.com/reski-rukmantiyo/runcvm-arm64](https://github.com/reski-rukmantiyo/runcvm-arm64)

---

## 2. Standard Usage

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

## 3. Docker-in-Docker (DinD)

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

## 4. Systemd Support

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
*(Note: For simple Nginx usage without systemd, see the [Network](#6-network) section).*

---

## 5. Storage

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

## 6. Network

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

---

## 7. Resource Management

RunCVM allows precise control over the resources allocated to the Firecracker microVM, including CPU pinning, memory limits, and ballooning.

### CPU Configuration

#### vCPU Allocation
By default, RunCVM matches the container's CPU quota/period to the number of Firecracker vCPUs. You can control this using Docker's standard `--cpus` flag.

- **Formula**: `ceil(quota / period)` = vCPUs.
- **Minimum**: 1 vCPU.

**Example**: Allocate 2 vCPUs to the VM.
```bash
docker run --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker --cpus=2 ubuntu
```

#### CPU Pinning
To pin the entire Firecracker process (and thus its vCPUs) to specific host cores, use Docker's `--cpuset-cpus` flag. This is critical for high-performance workloads to avoid context switching and noisy neighbors.

**Example**: Pin the VM to physical cores 0 and 1.
```bash
docker run --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker --cpus=2 --cpuset-cpus="0,1" ubuntu
```

### Memory Configuration

#### RAM Allocation
Use Docker's `-m` / `--memory` flag to set the amount of RAM available to the Guest VM.

> [!NOTE]
> RunCVM automatically adds a 256MB overhead to the container's *cgroup limit* to account for the Firecracker process, virtiofsd, and networking overhead. This ensures the VM gets the full amount of RAM you requested without being OOM-killed by the host.

**Example**: Give the VM 1GB of RAM.
```bash
# VM sees 1024MB RAM. Container cgroup limit is set to ~1280MB.
docker run --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker -m 1024M ubuntu
```

#### Memory Ballooning
RunCVM supports virtio-balloon to dynamically reclaim memory from the guest.

**Configuration**:
- `RUNCVM_ENABLE_BALLOON=true`: Enables the balloon device.
- `RUNCVM_BALLOON_SIZE_MIB`: (Optional) Initial size of the balloon in MiB (default: 0).

**Example**: Enable ballooning.
```bash
docker run --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -e RUNCVM_ENABLE_BALLOON=true \
  ubuntu
```


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

---

## 6. Resource Management

RunCVM allows precise control over the resources allocated to the Firecracker microVM, including CPU pinning, memory limits, and ballooning.

### CPU Configuration

#### vCPU Allocation
By default, RunCVM matches the container's CPU quota/period to the number of Firecracker vCPUs. You can control this using Docker's standard `--cpus` flag.

- **Formula**: `ceil(quota / period)` = vCPUs.
- **Minimum**: 1 vCPU.

**Example**: Allocate 2 vCPUs to the VM.
```bash
docker run --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker --cpus=2 ubuntu
```

#### CPU Pinning
To pin the entire Firecracker process (and thus its vCPUs) to specific host cores, use Docker's `--cpuset-cpus` flag. This is critical for high-performance workloads to avoid context switching and noisy neighbors.

**Example**: Pin the VM to physical cores 0 and 1.
```bash
docker run --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker --cpus=2 --cpuset-cpus="0,1" ubuntu
```

### Memory Configuration

#### RAM Allocation
Use Docker's `-m` / `--memory` flag to set the amount of RAM available to the Guest VM.

> [!NOTE]
> RunCVM automatically adds a 256MB overhead to the container's *cgroup limit* to account for the Firecracker process, virtiofsd, and networking overhead. This ensures the VM gets the full amount of RAM you requested without being OOM-killed by the host.

**Example**: Give the VM 1GB of RAM.
```bash
# VM sees 1024MB RAM. Container cgroup limit is set to ~1280MB.
docker run --runtime=runcvm -e RUNCVM_HYPERVISOR=firecracker -m 1024M ubuntu
```

#### Memory Ballooning
RunCVM supports virtio-balloon to dynamically reclaim memory from the guest.

**Configuration**:
- `RUNCVM_ENABLE_BALLOON=true`: Enables the balloon device.
- `RUNCVM_BALLOON_SIZE_MIB`: (Optional) Initial size of the balloon in MiB (default: 0).

**Example**: Enable ballooning.
```bash
docker run --runtime=runcvm \
  -e RUNCVM_HYPERVISOR=firecracker \
  -e RUNCVM_ENABLE_BALLOON=true \
  ubuntu
```

### Dynamic Resource Updates (`docker update`)
RunCVM supports dynamically updating the resource limits of a running container using `docker update`.

#### Memory Updates
RunCVM uses **Memory Ballooning** to dynamically adjust the memory available to the guest VM.

*   **Mechanism**: A "balloon" device inside the VM is inflated to consume memory, making it unavailable to other processes. This effectively reduces the usable memory.
*   **Limitations**:
    *   You can only **reduce** memory below the initial boot size (specified by `-m` at startup).
    *   You **cannot increase** memory beyond the initial boot size (because physical RAM slots are fixed at boot).
    *   If you attempt to set memory > boot memory, the balloon will fully deflate, returning the VM to its maximum original size.

**Example**:
```bash
# Start with 1GB
docker run -d --name myvs --runtime=runcvm -m 1024m nginx

# Reduce to 512MB
docker update --memory 512m myvm

# Restore to 1GB
docker update --memory 1024m myvm
```

#### CPU Updates
CPU updates behave identically to standard Docker.

*   `docker update --cpus <N>` updates the host Cgroups for the Firecracker VMM process.
*   This effectively throttles the entire VM's CPU usage to the specified quota.
*   **Note**: This does not hot-plug/unplug vCPUs inside the guest; it limits the computing power available to them.

---

## 8. Advanced Configuration

This section details advanced environment variables for fine-tuning RunCVM behavior.

### Storage & Filesystem

#### `RUNCVM_ROOTFS_SIZE`
Overrides the default size of the root filesystem created for the guest VM.
- **Default**: `256M`
- **Example**: `docker run -e RUNCVM_ROOTFS_SIZE=1G ...`
- **Use Case**: When your container workload writes significant data to the root overlay (not in a volume) and exceeds 256MB.

#### `ROOTFS_CACHE_ACTIVE`
Controls the rootfs caching mechanism.
- **Values**: `1` (or `true`) to enable; `0` (or `false`) to disable.
- **Default**: `1`
- **Use Case**: Disable caching during development if you suspect potential cache coherency issues, though this will significantly slow down boot times.

### Kernel Configuration

#### `RUNCVM_KERNEL_ARGS`
Appends additional parameters to the Firecracker kernel command line.
- **Example**: `docker run -e RUNCVM_KERNEL_ARGS="console=ttyS0 reboot=k panic=1 systemd.unified_cgroup_hierarchy=0" ...`
- **Use Case**: Necessary for specific kernel tuning or enabling legacy cgroup v1 support for older Docker-in-Docker workloads.

### Summary of Other Variables
These variables are documented in earlier sections:
- **`RUNCVM_SYSTEMD`**: Enable Systemd PID 1 (See [Section 4](#4-systemd-support)).
- **`RUNCVM_NETWORK_MODE`**: Enable Host Networking (See [Section 6](#6-network)).
- **`RUNCVM_ENABLE_BALLOON`**: Enable Memory Ballooning (See [Section 7](#7-resource-management)).
- **`RUNCVM_BALLOON_SIZE_MIB`**: Set Balloon Size (See [Section 7](#7-resource-management)).
