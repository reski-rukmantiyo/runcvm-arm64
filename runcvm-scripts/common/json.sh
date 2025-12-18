# ============================================================
# JSON HELPERS
# Wrappers for jq to handle config.json manipulation
# ============================================================

jq() {
  $RUNCVM_LD $RUNCVM_JQ "$@"
}

jq_set() {
  local file="$1"
  shift
  
  local tmp="/tmp/config.json.$$"

  if jq "$@" $file >$tmp; then
    mv $tmp $file
  else
    echo "Failed to update $(basename $file); aborting!" 2>&1
    exit 1
  fi
}

jq_get() {
  local file="$1"
  shift
  
  jq -r "$@" $file
}

get_process_env() {
  local file="$1"
  local var="$2"
  local default="$3"
  local value
  
  value=$(jq_get "$file" --arg env "$var" '.env[] | select(match("^" + $env + "=")) | match("^" + $env + "=(.*)") | .captures[] | .string')
  
  [ -n "$value" ] && echo -n "$value" || echo -n "$default"
}

get_process_env_boolean() {
  local file="$1"
  local var="$2"
  local value
  
  value=$(jq_get "$file" --arg env "$var" '.env[] | select(match("^" + $env + "=")) | match("^" + $env + "=(.*)") | .captures[] | .string')
  
  [ -n "$value" ] && echo "1" || echo "0"
}

get_config_env() {
  local var="$1"
  local default="$2"
  local value

  value=$(jq_get "$CFG" --arg env "$var" '.process.env[] | select(match("^" + $env + "=")) | match("^" + $env + "=(.*)") | .captures[] | .string')
  
  [ -n "$value" ] && echo -n "$value" || echo -n "$default"
}

set_config_env() {
  local var="$1"
  local value="$2"
  
  jq_set "$CFG" --arg env "$var=$value" '.process.env |= (.+ [$env] | unique)'
}

load_env_from_file() {
  local file="$1"
  local var="$2"

  # Return gracefully if no $file exists
  if ! [ -f "$file" ]; then
    return 0
  fi

  while read LINE
  do
    local name="${LINE%%=*}"
    local value="${LINE#*=}"
    
    if [ "$name" != "$LINE" ] && [ "$value" != "$LINE" ] && [ "$name" = "$var" ]; then
      # We found variable $name: return it, removing any leading/trailing double quotes
      echo "$value" | sed 's/^"//;s/"$//'
      return 0
    fi
  done <"$file"
  
  return 1
}
