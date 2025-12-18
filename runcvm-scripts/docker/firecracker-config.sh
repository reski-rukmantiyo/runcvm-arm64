# ============================================================
# FIRECRACKER CONFIG OPERATIONS
# 
# Handles:
# - Generation of Firecracker JSON configuration
# ============================================================

generate_firecracker_config() {
  local kernel_path="$1"
  local boot_args="$2"
  local rootfs_path="$3"
  local vcpu_count="$4"
  local mem_mb="$5"
  local network_config="$6"
  local vsock_config="$7"
  local balloon_config="$8"
  local config_file="$9"

  cat > "$config_file" << CFGEOF
{
  "boot-source": {
    "kernel_image_path": "$kernel_path",
    "boot_args": "$boot_args"
  },
  "logger": {
    "log_path": "/dev/null",
    "level": "Error",
    "show_level": false,
    "show_log_origin": false
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "$rootfs_path",
      "is_root_device": true,
      "is_read_only": false
    }
  ],
    "machine-config": {
      "vcpu_count": $vcpu_count,
      "mem_size_mib": $mem_mb
    }${network_config}${vsock_config}${balloon_config}
}
CFGEOF
}
