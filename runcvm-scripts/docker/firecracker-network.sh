# ============================================================
# FIRECRACKER NETWORK OPERATIONS
# 
# Handles:
# - Network config generation for VM injection
# ============================================================

generate_network_configs() {
  local staging_dir="$1"
  # Save network configuration for all VMs
  if [ -d "/.runcvm/network/devices" ]; then
    for net_dev_file in $(busybox ls /.runcvm/network/devices/* | busybox sort); do
      local ifname=$(busybox basename "$net_dev_file")
      [ "$ifname" = "default" ] && continue
      
      read DOCKER_IF DOCKER_IF_MAC DOCKER_IF_MTU DOCKER_IF_IP DOCKER_IF_IP_NETPREFIX DOCKER_IF_IP_GW < "$net_dev_file"
      
      # Firecracker MAC
      local fc_mac=$(echo "$DOCKER_IF_MAC" | busybox sed 's/^..:..:../AA:FC:00/')
      
      log "  Saving network config for $ifname: IP=$DOCKER_IF_IP/$DOCKER_IF_IP_NETPREFIX GW=$DOCKER_IF_IP_GW"
      
      cat > "${staging_dir}/.runcvm-network-${ifname}" << NETEOF
FC_IP="$DOCKER_IF_IP"
FC_PREFIX="$DOCKER_IF_IP_NETPREFIX"
FC_GW="$DOCKER_IF_IP_GW"
FC_MTU="$DOCKER_IF_MTU"
FC_MAC="$fc_mac"
NETEOF
    done
  fi
}
