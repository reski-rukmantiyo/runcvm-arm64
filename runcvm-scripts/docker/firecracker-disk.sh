# ============================================================
# FIRECRACKER DISK & NFS OPERATIONS
# 
# Handles:
# - NFS volume setup (setup_nfs_volumes)
# - Rootfs creation (create_rootfs_from_dir)
# - Cache maintenance
# ============================================================

setup_nfs_volumes() {
  # NFS volume sync using HOST-SIDE unfsd
  # Architecture:
  #   Host: runcvm-runtime starts unfsd daemon and sets RUNCVM_NFS_VOLUMES env var
  #   Container: reads env var and writes NFS config for guest VM
  #   Guest: mounts via NFS client (kernel built-in)
  #
  # RUNCVM_NFS_VOLUMES format: src:dst:port|src2:dst2:port2|...
  
  local nfs_config="$NFS_CONFIG"
  
  # DEBUG: Show what we have (only if log level is DEBUG)
  if [ "$RUNCVM_LOG_LEVEL" = "DEBUG" ]; then
    echo "[DEBUG] setup_nfs_volumes checking env var" >&2
    echo "[DEBUG] RUNCVM_NFS_VOLUMES=${RUNCVM_NFS_VOLUMES:-<not set>}" >&2
  fi
  
  # Read from environment variable (set by runcvm-runtime)
  if [ -n "$RUNCVM_NFS_VOLUMES" ]; then
    > "$nfs_config"
    
    log INFO "Setting up NFS volumes from RUNCVM_NFS_VOLUMES env"
    
    # Parse pipe-separated entries
    echo "$RUNCVM_NFS_VOLUMES" | tr '|' '\n' | while IFS=: read -r src dst port; do
      if [ -z "$src" ]; then continue; fi
      if [ -z "$port" ]; then port="2049"; fi
      
      log INFO "  Volume: $src -> $dst (port $port)"
      if [ "$RUNCVM_LOG_LEVEL" = "DEBUG" ]; then
         echo "[DEBUG] NFS config line: $src:$dst:$port" >&2
      fi
      
      # Write config for guest (format: src:dst:port)
      echo "$src:$dst:$port" >> "$nfs_config"
    done
    
    log INFO "  NFS config written to $nfs_config"
    if [ "$RUNCVM_LOG_LEVEL" = "DEBUG" ]; then
      echo "[DEBUG] Final nfs_config: $(busybox cat $nfs_config)" >&2
    fi
    
  else
    log INFO "RUNCVM_NFS_VOLUMES not set, skipping NFS volume setup"
  fi
}

cleanup_nfs_volumes() {
  # NFS cleanup is handled by runcvm-runtime on container stop
  # Nothing to do here
  :
}

# Create rootfs image from a source directory
create_rootfs_from_dir() {
  local source_dir="$1"
  local image_path="$2"
  local size_mb="$3"
  
  log "Creating ext4 rootfs: $image_path (${size_mb}MB) from $source_dir"
  
  # Create sparse file
  if ! busybox truncate -s "${size_mb}M" "$image_path"; then
    error "Failed to create sparse file"
  fi
  
  # Create ext4 filesystem populated with source directory contents
  if [ "$RUNCVM_LOG_LEVEL" = "DEBUG" ]; then
    # Show mke2fs output in debug mode
    if ! mke2fs -F -t ext4 -E root_owner=0:0 -d "$source_dir" "$image_path" 2>&1; then
      log "mke2fs failed"
      busybox rm -f "$image_path"
      return 1
    fi
  else
    # Silent mode - redirect to /dev/null
    if ! mke2fs -F -t ext4 -E root_owner=0:0 -d "$source_dir" "$image_path" >/dev/null 2>&1; then
      log_error "mke2fs failed"
      busybox rm -f "$image_path"
      return 1
    fi
  fi
  log "Rootfs created successfully"
  return 0
}

# Safely resize rootfs if target size is larger than current size
resize_rootfs_if_needed() {
  local image_path="$1"
  local target_size_str="$2"
  
  # Default to 256M if not specified
  [ -z "$target_size_str" ] && target_size_str="256M"
  
  # Convert target size to bytes for comparison
  # Handle M and G suffixes (case insensitive)
  local target_val=$(echo "$target_size_str" | busybox sed 's/[GgMm]//g')
  local target_bytes=0
  
  case "$target_size_str" in
    *[Gg]) target_bytes=$((target_val * 1024 * 1024 * 1024)) ;;
    *[Mm]) target_bytes=$((target_val * 1024 * 1024)) ;;
    *)     target_bytes="$target_val" ;;
  esac
  
  # Get current size in bytes
  local current_bytes=$(busybox ls -l "$image_path" 2>/dev/null | busybox awk '{print $5}')
  [ -z "$current_bytes" ] && current_bytes=0
  
  log "Checking rootfs size: Current=${current_bytes}B, Target=${target_bytes}B ($target_size_str)"
  
  if [ "$current_bytes" -ge "$target_bytes" ]; then
    log "Rootfs already large enough ($((current_bytes / 1024 / 1024))MB), skipping resize."
    return 0
  fi
  
  log "Resizing rootfs from $((current_bytes / 1024 / 1024))MB to $target_size_str..."
  
  if command -v truncate >/dev/null 2>&1; then
     truncate -s "$target_size_str" "$image_path"
  else
     # Fallback to dd (use bytes for precision)
     busybox dd of="$image_path" bs=1 count=0 seek="$target_bytes" 2>/dev/null || true
  fi
  
  if command -v resize2fs >/dev/null 2>&1; then
     if ! resize2fs "$image_path" >/dev/null 2>&1; then
        log "WARNING: resize2fs failed!"
     fi
  else
     log "WARNING: resize2fs not found, rootfs will be small!"
  fi
}
