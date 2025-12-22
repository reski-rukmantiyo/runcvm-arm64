# ============================================================
# LOGGING SYSTEM
# Severity levels: DEBUG, INFO, ERROR, OFF
# Control via: RUNCVM_LOG_LEVEL environment variable
# ============================================================

# Default log level (can be overridden by environment)
RUNCVM_LOG_LEVEL="${RUNCVM_LOG_LEVEL:-OFF}"

# Log severity levels (numeric for comparison)
get_log_level_num() {
  case "$1" in
    DEBUG) echo 0 ;;
    INFO|LOG) echo 1 ;;
    ERROR) echo 2 ;;
    OFF) echo 999 ;;
    *) echo 999 ;;
  esac
}

# Get numeric level for current log level (default to OFF=999)
CURRENT_LOG_LEVEL=$(get_log_level_num "${RUNCVM_LOG_LEVEL:-OFF}")

# Core logging function
_log() {
  local severity="$1"
  shift
  local message="$*"
  local severity_level=$(get_log_level_num "$severity")
  
  # Only log if severity meets threshold
  local current_log_level=$(get_log_level_num "${RUNCVM_LOG_LEVEL:-OFF}")
  if [ "$severity_level" -ge "$current_log_level" ]; then
    
    # Determine timestamp command
    local timestamp=""
    if command -v date >/dev/null 2>&1; then
       timestamp=$(date '+%Y-%m-%d %H:%M:%S.%6N')
    elif command -v busybox >/dev/null 2>&1; then
       timestamp=$(busybox date '+%Y-%m-%d %H:%M:%S')
    else
       timestamp="0000-00-00 00:00:00"
    fi
    
    local component="${RUNCVM_COMPONENT_NAME:-RunCVM}"
    local log_entry="[$timestamp] [$component] [$$] [$severity] $message"
    
    # Check if we should log to file
    if [ -n "$RUNCVM_LOG_FILE" ] && [ "$RUNCVM_LOG_FILE" != "/dev/stderr" ]; then
       # Append to log file only if writable to avoid "Permission denied" errors
       if [ -w "$RUNCVM_LOG_FILE" ] || { [ ! -e "$RUNCVM_LOG_FILE" ] && [ -w "$(dirname "$RUNCVM_LOG_FILE" 2>/dev/null || echo ".")" ]; }; then
          echo "$log_entry" >> "$RUNCVM_LOG_FILE" 2>/dev/null || true
       fi
    fi
    
    # Output to stderr if configured OR if ERROR
    # Default for Firecracker script should be to stderr (captured by Docker)
    if [ "${RUNCVM_LOG_STDERR:-0}" = "1" ] || [ "$severity" = "ERROR" ] || [ -z "$RUNCVM_LOG_FILE" ]; then
       echo "$log_entry" >&2
    fi
  fi
}

# Convenience functions for different severity levels
log_debug() {
  _log DEBUG "$@"
}

log_info() {
  _log INFO "$@"
}

log() {
  # Default log function - maps to INFO for backward compatibility
  _log INFO "$@"
}

log_error() {
  _log ERROR "$@"
}

error() {
  # Skip past any docker error ending in CR
  (echo; echo) >&2
  
  # Dump message to stderr
  echo "RunCVM: Error: $1" >&2
  
  # Log error with severity
  log_error "$1"
  exit 1
}
