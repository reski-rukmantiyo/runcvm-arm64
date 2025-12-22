generate_init_script() {
  local init_script="$1"
  
  cat > "$init_script" << INITEOF
#!${RUNCVM_GUEST}/bin/sh
echo "RUNCVM_INIT_MARKER: STARTING GENERATED INIT"
export RUNCVM_LOG_LEVEL="${RUNCVM_LOG_LEVEL:-DEBUG}"
echo "RUNCVM_INIT_MARKER: LOG_LEVEL IS $RUNCVM_LOG_LEVEL"
INITEOF
  cat >> "$init_script" << 'INITEOF'
# Firecracker minimal init for RunCVM
# This runs as PID 1 inside the Firecracker VM

# Mount essential filesystems at the very beginning
/.runcvm/guest/bin/busybox mount -t proc proc /proc 2>/dev/null || true
/.runcvm/guest/bin/busybox mount -t sysfs sys /sys 2>/dev/null || true
/.runcvm/guest/bin/busybox mount -t devtmpfs dev /dev 2>/dev/null || true

# Double check /proc is mounted (critical for many tools and MySQL entrypoint)
if [ ! -f /proc/uptime ]; then
  echo "CRITICAL: /proc not mounted, retrying..."
  # Try to use busybox directly if mount is not in path yet
  /.runcvm/guest/bin/busybox mount -t proc proc /proc 2>/dev/null || true
fi

# ============================================================
# LOGGING & PROFILING SYSTEM (sh-compatible)
# ============================================================

# Set PATH to include bundled guest tools FIRST
export PATH=/.runcvm/guest/usr/sbin:/.runcvm/guest/usr/bin:/.runcvm/guest/sbin:/.runcvm/guest/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Boot timing profiler
_T() { 
  local t=$(cat /proc/uptime | cut -d' ' -f1)
  echo "$t $1" >> /.runcvm/timing.log
}
_T "vm-init-start"

# Try to load RUNCVM_LOG_LEVEL from config if it exists


# Default to OFF if not set (matches host default for silent operation)
# NOTE: DSR terminal issue is fixed by having log output during boot; 
# users who want silent logs can set RUNCVM_LOG_LEVEL=OFF
RUNCVM_LOG_LEVEL="${RUNCVM_LOG_LEVEL:-OFF}"

log() {
  local severity="$1"
  shift
  echo "[RunCVM-FC-Init] [$severity] $*"
}

# Helper function to redirect output based on log level
# Usage: some_command $(output_redirect)
output_redirect() {
  if [ "$RUNCVM_LOG_LEVEL" = "DEBUG" ]; then
    echo ""  # No redirection
  else
    echo ">/dev/null 2>&1"
  fi
}

# Simpler helper - returns 0 if debug
is_debug() {
  [ "$RUNCVM_LOG_LEVEL" = "DEBUG" ]
}


# Try to load RUNCVM_LOG_LEVEL from config if it exists
if [ -f /.runcvm/config ]; then
  # Load config by stripping 'declare -x' which is bash-specific
  # This makes it compatible with busybox sh
  while read -r line || [ -n "$line" ]; do
    # Strip 'declare -x ' prefix if present
    line="${line#declare -x }"
    # Evaluate the export line
    if [ -n "$line" ]; then
      export "$line"
    fi
  done < /.runcvm/config
fi

log INFO "Starting... (Log Level: '$RUNCVM_LOG_LEVEL')"
echo "RUNCVM_INIT_MARKER: REACHED LOG INFO 111"
_T "starting-init"

# Remount / as rw (Firecracker may start as ro)
mount -o remount,rw / 2>/dev/null || true
_T "remount-rw"

export PATH=/.runcvm/guest/usr/sbin:/.runcvm/guest/usr/bin:/.runcvm/guest/sbin:/.runcvm/guest/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# DEBUG: Check environment
if is_debug; then
  log DEBUG "Environment check:"
  log DEBUG "  PATH: $PATH"
  log DEBUG "  busybox: $(which busybox 2>/dev/null || echo 'not found')"
  if [ -x /bin/busybox ]; then
     log DEBUG "  /bin/busybox exists"
     log DEBUG "  cttyhack in busybox: $(/bin/busybox --list | grep cttyhack || echo 'no')"
  else
     log DEBUG "  /bin/busybox missing"
  fi
fi

# Install mount.nfs wrapper so that mount(8) can find it
if [ -f "/.runcvm/guest/sbin/mount.nfs" ]; then
  log INFO "  Installing mount.nfs wrapper in /sbin/mount.nfs"
  cat > /sbin/mount.nfs << 'MOUNTNFSEOF'
#!/bin/sh
# Wrapper for mount.nfs (uses BUNDELF dynamic linker)
exec /.runcvm/guest/lib/ld /.runcvm/guest/sbin/mount.nfs "$@"
MOUNTNFSEOF
  chmod +x /sbin/mount.nfs
fi

# Essential device nodes creation if devtmpfs failed
# (Moved down after basic mounts)
if [ ! -c /dev/null ]; then
  mknod -m 666 /dev/null c 1 3
  mknod -m 666 /dev/zero c 1 5
  mknod -m 666 /dev/random c 1 8
  mknod -m 666 /dev/urandom c 1 9
  mknod -m 666 /dev/tty c 5 0
  mknod -m 620 /dev/console c 5 1
  mknod -m 666 /dev/ptmx c 5 2
fi

# Mount pts for proper terminal support
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts 2>/dev/null || true
mount -t tmpfs tmpfs /dev/shm 2>/dev/null || true

# Create tmpfs for /run and /tmp
mkdir -p /run /tmp
mount -t tmpfs tmpfs /run 2>/dev/null || true
# Create tmpfs for /run and /tmp
mkdir -p /run /tmp
mount -t tmpfs tmpfs /run -o mode=0755,nosuid,nodev 2>/dev/null || true
mount -t tmpfs tmpfs /tmp -o mode=1777,strictatime,nosuid,nodev 2>/dev/null || true
mkdir -p /run/lock

# Mount cgroup v2 (Systemd requirement)
# mkdir -p /sys/fs/cgroup
# mount -t cgroup2 cgroup2 /sys/fs/cgroup 2>/dev/null || true
_T "mounting-cgroups"
# Ported Advanced Cgroup handling from K8s init
if [ -f "$RUNCVM_GUEST/scripts/functions/cgroupfs" ]; then
    . "$RUNCVM_GUEST/scripts/functions/cgroupfs"
    # Detect if systemd (needed for cgroup choice)
    ARGS_INIT=""
    [ -f /.runcvm/entrypoint ] && read -r ARGS_INIT < /.runcvm/entrypoint
    
    case "$ARGS_INIT" in
      */systemd) cgroupfs_mount "${RUNCVM_CGROUPFS:-none}" ;;
      *) cgroupfs_mount "${RUNCVM_CGROUPFS:-hybrid}" ;;
    esac
else
    # Fallback to simple cgroup v2 mount
    mkdir -p /sys/fs/cgroup
    mount -t cgroup2 cgroup2 /sys/fs/cgroup 2>/dev/null || true
fi
_T "cgroups-ready"

# FSTAB Support (Ported from K8s init)
if [ -f /.runcvm/fstab ]; then
  log INFO "Mounting filesystems from /.runcvm/fstab..."
  busybox modprobe ext4 2>/dev/null || true
  mount -a --fstab /.runcvm/fstab -o X-mount.mkdir 2>/dev/null || true
  # Now mount our fstab over /etc/fstab for future use
  mount --bind /.runcvm/fstab /etc/fstab 2>/dev/null || true
  _T "fstab-mounted"
fi

# Create symlinks
# Create symlinks
ln -sf /proc/self/fd /dev/fd 2>/dev/null || true
ln -sf /proc/self/fd/0 /dev/stdin 2>/dev/null || true
ln -sf /proc/self/fd/1 /dev/stdout 2>/dev/null || true
ln -sf /proc/self/fd/2 /dev/stderr 2>/dev/null || true

# Force all output to serial console (Firecracker default)
# This ensures logs are captured by the host-side launcher
exec >/dev/ttyS0 2>&1
echo "RUNCVM_INIT_MARKER: REDIRECTED TO ttyS0"

# Setup hostname
[ -f /etc/hostname ] && hostname -F /etc/hostname 2>/dev/null || true

# === EARLY VSOCK LISTENER START ===
# Start VSOCK backdoor immediately to allow debugging even if init fails later
# We forward VSOCK port 22 to the local SSH port 22222
(
  log INFO "Starting EARLY VSOCK listener on port 22..."
  
  SOCAT=""
  # Prioritize the bundled socat-static if it exists
  if [ -x "/.runcvm/guest/bin/socat-static" ]; then SOCAT="/.runcvm/guest/bin/socat-static"
  elif command -v socat >/dev/null 2>&1; then SOCAT=socat
  elif [ -x "/.runcvm/guest/bin/socat" ]; then SOCAT="/.runcvm/guest/bin/socat"
  elif [ -x "/.runcvm/guest/usr/bin/socat" ]; then SOCAT="/.runcvm/guest/usr/bin/socat"
  fi

  if [ -n "$SOCAT" ]; then
     # Wait for dropbear (it will start shortly)
     $SOCAT VSOCK-LISTEN:22,fork TCP:127.0.0.1:22222,retry=20,interval=0.5 >> /dev/console 2>&1 &
     log INFO "EARLY VSOCK listener started (PID $!)"
  else
     log INFO "WARNING: socat not found for EARLY VSOCK"
  fi
) &
# ==================================

# Setup networking
log INFO "========== NETWORK SETUP START =========="

# Setup RunCVM tools if available
# These tools use BundELF and need the dynamic linker from the same directory
# IMPORTANT: Path must match the original /.runcvm/guest/ because of relative RPATH
RUNCVM_GUEST="/.runcvm/guest"
if [ -d "$RUNCVM_GUEST/lib" ]; then
  # The dynamic linker is at /.runcvm/guest/lib/ld
  RUNCVM_LD="$RUNCVM_GUEST/lib/ld"
  if [ -x "$RUNCVM_LD" ]; then
    log INFO "Found RunCVM tools at $RUNCVM_GUEST"
    log INFO "Checking tools structure:"
    log DEBUG "lib/ld: $(ls -la $RUNCVM_GUEST/lib/ld 2>&1)"
    log DEBUG "bin contents: $(ls -la $RUNCVM_GUEST/bin/ 2>&1 | head -10)"
    log DEBUG "bin/ip: $(ls -la $RUNCVM_GUEST/bin/ip 2>&1)"
    log DEBUG "bin/busybox: $(ls -la $RUNCVM_GUEST/bin/busybox 2>&1)"
    
    # Test the dynamic linker directly
    log DEBUG "Testing dynamic linker..."
    log DEBUG "Test 1 - ld exists: $(test -x $RUNCVM_LD && echo yes || echo no)"
    log DEBUG "Test 2 - busybox via ld: $($RUNCVM_LD $RUNCVM_GUEST/bin/busybox echo 'works' 2>&1)"
    
    # ip is likely a symlink to busybox, so we need to call busybox ip
    # Create wrapper functions that use the dynamic linker with busybox
    runcvm_ip() { "$RUNCVM_LD" "$RUNCVM_GUEST/bin/busybox" ip "$@"; }
    runcvm_busybox() { "$RUNCVM_LD" "$RUNCVM_GUEST/bin/busybox" "$@"; }
    HAVE_RUNCVM_TOOLS=1
  else
    log INFO "Dynamic linker not found at $RUNCVM_LD"
    # Fallback: check if tools work anyway (e.g. static busybox)
    # Copy EPKA (Authorized Keys) removed

    if "$RUNCVM_GUEST/bin/busybox" true 2>/dev/null; then
       log INFO "Busybox works without explicit LD check"
       runcvm_ip() { "$RUNCVM_GUEST/bin/busybox" ip "$@"; }
       runcvm_busybox() { "$RUNCVM_GUEST/bin/busybox" "$@"; }
       HAVE_RUNCVM_TOOLS=1
    fi
  fi
else
  log INFO "RunCVM tools not found at $RUNCVM_GUEST"
fi

# Bring up loopback unconditionally (using system tools if available)
ip link set lo up 2>/dev/null || ifconfig lo up 2>/dev/null || true

# Bring up loopback using RunCVM tools if available
if [ "$HAVE_RUNCVM_TOOLS" = "1" ]; then
  runcvm_ip link set lo up 2>/dev/null  # Ensure loopback is up via runcvm_ip too
  
  # Configure eth0 with static IP
  # Cloud-init usually handles this, but for non-cloud-init images (or early boot connectivity)
  # we set it up.
  # CRITICAL: We also add a route to 169.254.1.1 (the bridge IP in the container namespace)
  # This allows 'docker exec' (runcvm-ctr-exec) to receive return traffic from the VM.
  # Otherwise, VM replies to default GW (172.17.0.1) which drops 169.254.x.x traffic.
  
  # Wait for interface
  log DEBUG "Waiting for eth0..."
  for i in $(seq 1 50); do
    if ip link show eth0 >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  
  # Set IP if variables passed
  # The variables RUNCVM_IP etc are injected by runcvm-ctr-firecracker into init script
  # We should ensure they are written to the init script.
  # Currently runcvm-ctr-firecracker does NOT write specific IP vars to init script directly,
  # it relies on cloud-init or network config files.
  # BUT we can add the route using 'ip' command if 'ip' is available.
  
  if command -v ip >/dev/null 2>&1; then
     ip link set eth0 up 2>/dev/null || true
     ip link set eth0 up 2>/dev/null || true
  fi
  
  # Flush any potential firewall rules that might block SSH
  if command -v iptables >/dev/null 2>&1; then
     iptables -F 2>/dev/null || true
     iptables -P INPUT ACCEPT 2>/dev/null || true
  fi
fi

# First, check what kernel modules are loaded for networking
log DEBUG "Checking for virtio_net module..."
if is_debug && [ -f /proc/modules ]; then
  grep -i virtio /proc/modules 2>/dev/null || echo "  No virtio modules loaded"
fi

# Check /sys/class/net to see what the kernel sees
log DEBUG "Kernel network interfaces in /sys/class/net:"
if is_debug; then
  ls -la /sys/class/net/ 2>/dev/null || echo "  Cannot list /sys/class/net"
fi

# Check dmesg for network-related messages
log DEBUG "Recent dmesg network messages:"
if is_debug; then
  dmesg 2>/dev/null | grep -iE "(eth|net|virtio)" | tail -10 || echo "  Cannot read dmesg"
fi

# Configure all network interfaces from config files or DHCP
log INFO "Configuring network..."

# Wait for at least one ethernet interface to appear in /sys/class/net
log DEBUG "Waiting for eth* interface to appear in /sys/class/net..."
for i in $(seq 1 100); do
  if ls /sys/class/net/eth* >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

# We need to find all eth* interfaces
# Since we might not have 'ls' or 'find' behaving standardly, we look at sysfs
if is_debug; then
  ls -la /sys/class/net/
fi

# Iterate over eth interfaces found in sysfs
found_ifaces=0
for iface_path in /sys/class/net/eth*; do
  # Check if glob expansion failed
  [ -e "$iface_path" ] || continue
  
  IFACE=$(basename "$iface_path")
  found_ifaces=1
  log INFO "Configuring interface $IFACE..."

  # Look for config file
  CONFIG_FILE="/.runcvm-network-${IFACE}"
  
  # Backward compat: check legacy file for eth0 if new one missing
  if [ "$IFACE" = "eth0" ] && [ ! -f "$CONFIG_FILE" ] && [ -f "/.runcvm-network" ]; then
     CONFIG_FILE="/.runcvm-network"
  fi
  
  if [ -f "$CONFIG_FILE" ]; then
    log INFO "  Loading config from $CONFIG_FILE"
    if is_debug; then cat "$CONFIG_FILE"; fi
    
    # unset previous vars to be safe
    unset FC_IP FC_PREFIX FC_GW FC_MTU FC_MAC
    . "$CONFIG_FILE"
    
    if [ -n "$FC_IP" ] && [ -n "$FC_PREFIX" ]; then
       log INFO "  Setting IP $FC_IP/$FC_PREFIX (MTU: ${FC_MTU:-1500})"
       
       # Determine tool to use
       if [ "$HAVE_RUNCVM_TOOLS" = "1" ]; then
         IP_CMD="runcvm_ip"
       elif command -v ip >/dev/null 2>&1; then
         IP_CMD="ip"
       elif command -v ifconfig >/dev/null 2>&1; then
         IP_CMD=""
         USE_IFCONFIG=1
       else
         IP_CMD=""
       fi
       
       if [ -n "$IP_CMD" ]; then
          $IP_CMD link set "$IFACE" up 2>/dev/null || true
          [ -n "$FC_MTU" ] && $IP_CMD link set "$IFACE" mtu "$FC_MTU" 2>/dev/null || true
          $IP_CMD addr add "$FC_IP/$FC_PREFIX" dev "$IFACE"
          
          if [ -n "$FC_GW" ] && [ "$FC_GW" != "-" ]; then
             log INFO "  Adding default gateway $FC_GW"
             $IP_CMD route add default via "$FC_GW" dev "$IFACE" onlink
                          # If this is the default GW interface, add the bridge route for 9P/NFS too
              # (This is mostly relevant for the primary interface)
              $IP_CMD route add 169.254.1.1/32 dev "$IFACE" 2>/dev/null || true
              $IP_CMD route add 169.254.1.254/32 dev "$IFACE" 2>/dev/null || true
           fi
          
       elif [ "$USE_IFCONFIG" = "1" ]; then
          # Basic ifconfig support
          case "$FC_PREFIX" in
            8)  FC_NETMASK="255.0.0.0" ;;
            16) FC_NETMASK="255.255.0.0" ;;
            24) FC_NETMASK="255.255.255.0" ;;
            *)  FC_NETMASK="255.255.255.0" ;;
          esac
          ifconfig "$IFACE" "$FC_IP" netmask "$FC_NETMASK" up
          if [ -n "$FC_GW" ] && [ "$FC_GW" != "-" ]; then
             route add default gw "$FC_GW" 2>/dev/null || true
          fi
       fi
    else
       log ERROR "  Config file found but missing IP/Prefix!"
    fi
  else
    # Fallback to DHCP if no config
    log INFO "  No config file, trying DHCP..."
    ip link set "$IFACE" up 2>/dev/null || ifconfig "$IFACE" up 2>/dev/null || true
    if command -v udhcpc >/dev/null 2>&1; then
      udhcpc -i "$IFACE" -n -q 2>/dev/null || true
    fi
  fi
done

if [ "$found_ifaces" = "0" ]; then
  log INFO "No ethernet interfaces found!"
fi

log INFO "========== NETWORK SETUP END =========="

# Setup DNS
if [ -f /.runcvm-resolv.conf ]; then
  cp /.runcvm-resolv.conf /etc/resolv.conf 2>/dev/null || true
fi

if [ -f /.runcvm/entrypoint ] && [ -s /.runcvm/entrypoint ]; then
  # Read entrypoint line by line into an array-like structure
  set --
  while IFS= read -r line || [ -n "$line" ]; do
    set -- "$@" "$line"
  done < /.runcvm/entrypoint
fi

# ========== DROPBEAR SSH (VM SIDE) ==========
# Start dropbear inside the VM for docker exec support
log INFO "Starting Dropbear SSH server..."

# Ensure /root/.ssh exists (should be created by staging)
mkdir -p /root/.ssh
chmod 700 /root/.ssh

# Start dropbear using RunCVM tools
# We use the bundled dynamic linker and binary
if [ -x "/.runcvm/guest/usr/sbin/dropbear" ] && [ -x "/.runcvm/guest/lib/ld" ]; then
  # -R: Create hostkeys if missing
  # -E: Log to stderr
  # -s: Disable password auth (key only)
  # -g: Disable password for root
  # -p: Port 22222
  # CRITICAL: Set HOME=/root so Dropbear finds /root/.ssh/authorized_keys
  export HOME=/root
  
  # DEBUG: Check keys and permissions
  log DEBUG "Checking /root permissions:"
  ls -ld /root /root/.ssh /root/.ssh/authorized_keys 2>&1 | while read line; do log DEBUG "$line"; done
  log DEBUG "authorized_keys content:"
  cat /root/.ssh/authorized_keys 2>&1 | while read line; do log DEBUG "$line"; done

  # Start Dropbear (removed -v flag - unsupported by this version)
  /.runcvm/guest/lib/ld /.runcvm/guest/usr/sbin/dropbear -R -E -s -g -p 22222 2>&1 &
  log INFO "  Dropbear started on port 22222"
else
  log ERROR "  Dropbear binary or linker not found at /.runcvm/guest/usr/sbin/dropbear"
fi




# Setup DNS
if [ -f /.runcvm-resolv.conf ]; then
  cp /.runcvm-resolv.conf /etc/resolv.conf 2>/dev/null || true
fi



# ==========================================================================
# NFS VOLUME MOUNTS - Mount NFS shares from host unfsd
# ==========================================================================
mount_nfs_volumes() {
  local nfs_config="/.runcvm/nfs-mounts"
  
  # Get gateway IP from network config (this is the HOST from VM's perspective)
  # Get gateway IP from network config (this is the HOST from VM's perspective)
  local host_ip=""
  
  # Scan all network configs for a gateway
  # We prioritize eth0 if it exists
  if [ -f "/.runcvm-network-eth0" ]; then
     unset FC_GW
     . "/.runcvm-network-eth0"
      if [ -n "$FC_GW" ] && [ "$FC_GW" != "-" ]; then
        # Default to gateway, but we will check for the dedicated host IP later
        host_ip="$FC_GW"
      fi
  fi
  
  # If not found in eth0, try others
  if [ -z "$host_ip" ]; then
    for cfg in /.runcvm-network-*; do
      [ -f "$cfg" ] || continue
      unset FC_GW
      . "$cfg"
      if [ -n "$FC_GW" ] && [ "$FC_GW" != "-" ]; then
        host_ip="$FC_GW"
        break
      fi
    done
  fi
  
  # Fallback to default Docker gateway if still nothing
  if [ -z "$host_ip" ] || [ "$host_ip" = "-" ]; then
    log INFO "Warning: No gateway found in network configs, defaulting to 172.17.0.1"
    host_ip="172.17.0.1"
  fi
  
  # Use the dedicated host IP (169.254.1.254) if it responds to ARP/ping, or fallback to gateway
  # This dedicated IP is used in K8s mode to avoid gateway conflicts.
  if /.runcvm/guest/sbin/ip route get 169.254.1.254 >/dev/null 2>&1; then
       log INFO "  Detected dedicated host IP 169.254.1.254, using for NFS"
       host_ip="169.254.1.254"
  fi

  log INFO "Checking for NFS volumes..."
  log INFO "  Host IP (for NFS): $host_ip"
  
  if [ ! -f "$nfs_config" ]; then
    log INFO "No nfs-mounts config found - volumes are static copies"
    return 0
  fi
  
  log INFO "NFS Transport: TCP over $host_ip"
  log INFO "Mount type: NFS (live, bidirectional)"
  
  # Config format: src:dst:port
  # Mount each volume via NFS
  while IFS=: read -r src_path dst nfs_port; do
    [ -z "$src_path" ] && continue
    [ -z "$dst" ] && continue
    
    log INFO "  Mounting $src_path -> $dst (port $nfs_port)..."
    /.runcvm/guest/bin/busybox mkdir -p "$dst"
    
    # Mount via NFS v3 with nolock (no separate lockd needed)
    /.runcvm/guest/lib/ld /.runcvm/guest/bin/mount -t nfs -o vers=3,nolock,tcp,port="$nfs_port",mountport="$((nfs_port + 1))" \
      "$host_ip:$src_path" "$dst" 2>&1 | /.runcvm/guest/bin/busybox sed 's/^/    /'
    
    if /.runcvm/guest/lib/ld /.runcvm/guest/bin/mount | /.runcvm/guest/bin/busybox grep -q "$dst"; then
      log INFO "  ✓ Successfully mounted $dst (NFS)"
    else
      log ERROR "  ✗ Failed to mount $dst via NFS"
      log INFO "    Falling back to static copy mode"
    fi
  done < "$nfs_config"
  
  log INFO "  NFS mounts complete"
}

log INFO "========== NFS VOLUME MOUNTS =========="
mount_nfs_volumes
log INFO "========== NFS VOLUME MOUNTS END =========="

# ========== DROPBEAR SSH SERVER FOR DOCKER EXEC ==========
# docker exec uses SSH to connect to the VM, so we need dropbear running
log INFO "========== DROPBEAR SSH SETUP =========="

SSHD_PORT=22222
DROPBEAR_DIR="/.runcvm/dropbear"

if [ "$HAVE_RUNCVM_TOOLS" = "1" ]; then
  mkdir -p "$DROPBEAR_DIR"

  # 1. Ensure Host Key Exists
  if [ ! -f "$DROPBEAR_DIR/key" ]; then
    log INFO "Generating dropbear SSH keys..."
    "$RUNCVM_LD" "$RUNCVM_GUEST/usr/bin/dropbearkey" -t ed25519 -f "$DROPBEAR_DIR/key" >/dev/null 2>&1
  else
    log INFO "Using pre-generated SSH keys"
  fi

  # 2. Extract Public Key (Unconditionally)
  KEY_PUBLIC=$("$RUNCVM_LD" "$RUNCVM_GUEST/usr/bin/dropbearkey" -y -f "$DROPBEAR_DIR/key" 2>/dev/null | grep ^ssh)

  # 3. Setup authorized_keys (Unconditionally)
  mkdir -p /root/.ssh
  if [ -n "$KEY_PUBLIC" ]; then
    echo "$KEY_PUBLIC" > /root/.ssh/authorized_keys
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/authorized_keys
    log INFO "Configured /root/.ssh/authorized_keys"
  else
    log ERROR "Failed to extract public key from $DROPBEAR_DIR/key"
    # Fallback? If we can't get key, auth will fail.
  fi
  
  # Start dropbear SSH server
  # MOVED TO VM SIDE (init script)
  # We no longer run Dropbear on the container side to avoid confusion and port conflicts.
  # The socat proxy will forward traffic to the VM's IP on port 22222.
  log INFO "Dropbear execution moved to VM side (skipping host start)"

else
  log INFO "RunCVM tools not available, skipping dropbear"
  log INFO "docker exec will not work"
fi

log INFO "========== DROPBEAR SETUP END =========="

# Note: Static watch binary (from procps) is copied to /usr/bin/watch during rootfs staging
# This provides proper Ctrl-C handling unlike busybox watch

# ========== TTY AND SIGNAL SETUP ==========
# This is critical for proper signal handling (Ctrl-C, Ctrl-Z, etc.)
# Without this, interactive commands like 'watch' won't respond to signals.
#
# IMPORTANT: We cannot use setsid with exec because:
# - setsid forks, parent exits immediately -> kernel panic (PID 1 cannot exit)
#
# Instead, we:
# 1. Redirect I/O to serial console for proper terminal
# 2. Run entrypoint as a child process (not exec)
# 3. Set up trap to forward signals to child
# 4. Wait for child to finish
# 5. Trigger proper shutdown (reboot -f) - PID 1 must never exit normally

# Setup signal handler for graceful shutdown
# This is triggered when the host sends SIGTERM to guest PID 1
poweroff_handler() {
  log INFO "Received SIGTERM, shutting down VM..."
  sync
  runcvm_busybox poweroff -f || poweroff -f || /sbin/reboot -f
}
trap poweroff_handler SIGTERM

# Determine what to run
# Priority:
# 1. /.runcvm-entrypoint (saved by RunCVM)
# 2. /docker-entrypoint.sh (nginx and many others)
# 3. Direct nginx execution
# 4. /bin/sh fallback

# TTY Handling Strategy:
# 1. cttyhack (Busybox) - Best, designed for this exactly
# 2. setsid (util-linux/Busybox) - Good, creates new session. 
#    Need to explicitly open /dev/console to make it the controlling terminal.

CTTYHACK=""
if command -v cttyhack >/dev/null 2>&1; then
  CTTYHACK="cttyhack"
elif command -v busybox >/dev/null 2>&1 && busybox --list | grep -q cttyhack; then
  CTTYHACK="busybox cttyhack"
elif [ -x "/bin/busybox" ] && /bin/busybox --list | grep -q cttyhack; then
  CTTYHACK="/bin/busybox cttyhack"
elif [ -x "/.runcvm/guest/bin/busybox" ] && /.runcvm/guest/bin/busybox --list | grep -q cttyhack; then
  if [ -x "/.runcvm/guest/lib/ld" ]; then
    CTTYHACK="/.runcvm/guest/lib/ld /.runcvm/guest/bin/busybox cttyhack"
  else
    CTTYHACK="/.runcvm/guest/bin/busybox cttyhack"
  fi
fi

  if [ -n "$CTTYHACK" ]; then
  # Option 1: cttyhack found
  log DEBUG "TTY enabled ($CTTYHACK)"
  
  run_with_tty() {
    # Run as child so we can reboot after
    $CTTYHACK "$@"
    return $?
  }
elif command -v setsid >/dev/null 2>&1; then
  # Option 2: setsid found
  log DEBUG "TTY enabled (setsid fallback)"
  
  # Wrapper to run in new session and acquire controlling terminal
  # We exec a shell that opens console (becoming ctty) and then execs the target
  # We do NOT exec the setid command itself, so PID 1 stays alive to reboot
  # Note: setsid -c sets the controlling terminal to stdin (which we redirect/open properly)
  run_with_tty() {
    setsid -c sh -c 'exec "$@" <> /dev/ttyS0 >&0 2>&1' -- "$@"
    return $?
  }
else
  # Option 3: No TTY tools
  log INFO "WARNING - No TTY tools found (cttyhack/setsid)"
  log INFO "Interactive shells may not work correctly"
  
  run_with_tty() {
    "$@"
    return $?
  }
fi

# Check for Systemd
SYSTEMD_BIN=""
if [ -x /usr/lib/systemd/systemd ]; then
  SYSTEMD_BIN="/usr/lib/systemd/systemd"
elif [ -x /lib/systemd/systemd ]; then
  SYSTEMD_BIN="/lib/systemd/systemd"
elif [ -x /sbin/init ] && [ "$(/sbin/init --version 2>/dev/null | grep -c systemd)" -gt 0 ]; then
  SYSTEMD_BIN="/sbin/init"
fi

# Detect if we should run systemd
# Priority:
# 1. RUNCVM_SYSTEMD=1 env var
# 2. image has systemd installed (and we decide to auto-enable? No, safer to require flag for now or just check if entrypoint is empty/default)

if is_debug; then
  log DEBUG "Checking for Systemd..."
  log DEBUG "  Detailed check:"
  ls -la /usr/lib/systemd/systemd 2>/dev/null || log DEBUG "  /usr/lib/systemd/systemd not found"
  ls -la /lib/systemd/systemd 2>/dev/null || log DEBUG "  /lib/systemd/systemd not found"
  ls -la /sbin/init 2>/dev/null || log DEBUG "  /sbin/init not found"
  log DEBUG "  PATH=$PATH"
  log DEBUG "  SYSTEMD_BIN='$SYSTEMD_BIN'"
  log DEBUG "  RUNCVM_SYSTEMD='$RUNCVM_SYSTEMD'"
fi

SHOULD_RUN_SYSTEMD=0
if [ "$RUNCVM_SYSTEMD" = "1" ] || [ "$RUNCVM_SYSTEMD" = "true" ]; then
  SHOULD_RUN_SYSTEMD=1
elif [ -n "$SYSTEMD_BIN" ] && [ ! -f /.runcvm-entrypoint ]; then
  # If no custom entrypoint and systemd exists, maybe?
  # Let's stick to explicit flag for now to avoid breaking existing generic containers
  :
fi
if is_debug; then
  log DEBUG "  SHOULD_RUN_SYSTEMD='$SHOULD_RUN_SYSTEMD'"
fi

if [ "$SHOULD_RUN_SYSTEMD" = "1" ] && [ -n "$SYSTEMD_BIN" ]; then
   log INFO "Booting with Systemd ($SYSTEMD_BIN)..."
   
   # Systemd requirements:
   # 1. PID 1 (we are)
   # 2. cgroup2 mounted (we did)
   # 3. /run mounted (we did)
   # 4. signal handling (systemd handles this)
   
   # Set container environment type
   export container=docker

   # Run systemd in a separate PID namespace so we (the init script) remain PID 1
   # This allows for better process management and "escaping"
   
   UNSHARE_BIN=""
   if command -v unshare >/dev/null 2>&1; then
      UNSHARE_BIN="unshare"
   elif command -v busybox >/dev/null 2>&1; then
      UNSHARE_BIN="busybox unshare"
   elif [ -x /bin/busybox ]; then
      UNSHARE_BIN="/bin/busybox unshare"
   fi
   
   if [ -n "$UNSHARE_BIN" ]; then
       log INFO "Starting Systemd in new PID namespace (using $UNSHARE_BIN)..."
       
       # Determine TTY handler for new namespace
       TTY_CMD=""
       if command -v setsid >/dev/null 2>&1; then
           TTY_CMD="setsid"
       elif command -v cttyhack >/dev/null 2>&1; then
           TTY_CMD="cttyhack" 
       fi

       # -f: Fork
       # -p: Unshare PID namespace
       # --mount-proc: Mount /proc for the new namespace
       # Use setsid if available to ensure systemd is session leader
       $UNSHARE_BIN -f -p --mount-proc $TTY_CMD "$SYSTEMD_BIN" --unit=multi-user.target
       
       RET=$?
       log INFO "Systemd exited with code $RET"
       runcvm_busybox poweroff -f || /sbin/reboot -f || poweroff -f
   else
       log INFO "'unshare' not found, falling back to exec (PID 1)"
       # Execute systemd - this REPLACES the init process
       exec "$SYSTEMD_BIN" --unit=multi-user.target
   fi
fi

if [ -f /.runcvm/entrypoint ] && [ -s /.runcvm/entrypoint ]; then
  # Read entrypoint line by line into an array-like structure
  set --
  while IFS= read -r line || [ -n "$line" ]; do
    set -- "$@" "$line"
  done < /.runcvm/entrypoint
  
  log INFO "Running saved entrypoint: $@"
  run_with_tty "$@"
  
elif [ -x /docker-entrypoint.sh ]; then
  log INFO "Running /docker-entrypoint.sh"
  if [ -f /etc/nginx/nginx.conf ]; then
    run_with_tty /docker-entrypoint.sh nginx -g "daemon off;"
  else
    run_with_tty /docker-entrypoint.sh
  fi
  
elif [ -f /etc/nginx/nginx.conf ] && command -v nginx >/dev/null 2>&1; then
  log INFO "Running nginx directly"
  run_with_tty nginx -g "daemon off;"
  
else
  log INFO "No entrypoint found, starting shell"
  run_with_tty /bin/sh
fi

# We should only get here if run_with_tty failed to exec (e.g. command not found)
# OR if run_with_tty was not an exec (which it is currently)
RET=$?
log INFO "Entrypoint exited with code $RET"
runcvm_busybox poweroff -f || /sbin/reboot -f || poweroff -f
INITEOF

  busybox chmod +x "$init_script"
}
