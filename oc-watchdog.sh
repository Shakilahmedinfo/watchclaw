#!/usr/bin/env bash
# oc-watchdog.sh — OpenClaw Gateway Watchdog (Option C)
# Monitors gateway health, auto-reverts config on config errors,
# restarts on transient crashes, alerts via iMessage as fallback.
set -uo pipefail
# Note: NOT using set -e; we handle errors explicitly

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="${1:-${SCRIPT_DIR}/oc-watchdog.conf}"

# --- Load config ---
if [[ -f "$CONF_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONF_FILE"
else
  echo "ERROR: Config file not found: $CONF_FILE" >&2
  exit 1
fi

# --- State ---
crash_count=0
last_crash_time=0
last_restart_time=0
last_config_mtime=""
running=true

# --- Logging ---
log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] [$level] $msg" | tee -a "$LOG_FILE"
}

# --- Alert ---
send_alert() {
  local msg="$1"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "ALERT" "[DRY-RUN] Would send iMessage: $msg"
    return
  fi
  if [[ -n "${ALERT_PHONE:-}" ]]; then
    if command -v imsg &>/dev/null; then
      imsg send "$ALERT_PHONE" "$msg" 2>/dev/null || log "WARN" "Failed to send iMessage alert"
    else
      log "WARN" "imsg not found, cannot send alert"
    fi
  fi
  log "ALERT" "$msg"
}

# --- Health check ---
check_health() {
  # Probe gateway via HTTP — OpenClaw serves dashboard UI on /
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$HEALTH_TIMEOUT" "http://127.0.0.1:${GATEWAY_PORT}/" 2>/dev/null) || return 1
  [[ "$http_code" == "200" ]]
}

# --- Process check ---
GATEWAY_PID_FILE="${CONFIG_DIR}/.gateway.pid"

gateway_pid() {
  if [[ -f "$GATEWAY_PID_FILE" ]]; then
    local pid
    pid=$(cat "$GATEWAY_PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      echo "$pid"
      return
    fi
  fi
  echo ""
}

is_gateway_running() {
  [[ -n "$(gateway_pid)" ]]
}

# --- Config mtime ---
get_config_mtime() {
  stat -f "%m" "$CONFIG_DIR/openclaw.json" 2>/dev/null || echo ""
}

# --- Gateway control ---
start_gateway() {
  log "INFO" "Starting gateway on port $GATEWAY_PORT..."
  cd "$CONFIG_DIR"
  OPENCLAW_STATE_DIR="$CONFIG_DIR" \
  OPENCLAW_CONFIG_PATH="$CONFIG_DIR/openclaw.json" \
    nohup node /opt/homebrew/lib/node_modules/openclaw/dist/index.js gateway --port "$GATEWAY_PORT" \
    >> "$GATEWAY_LOG" 2>&1 &
  local pid=$!
  echo "$pid" > "$GATEWAY_PID_FILE"
  last_restart_time=$(date +%s)
  log "INFO" "Gateway started (PID $pid)"
}

stop_gateway() {
  local pid
  pid=$(gateway_pid)
  if [[ -n "$pid" ]]; then
    log "INFO" "Stopping gateway (PID $pid)..."
    kill "$pid" 2>/dev/null || true
    sleep 2
    # Force kill if still alive
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$GATEWAY_PID_FILE"
}

restart_gateway() {
  stop_gateway
  sleep 1
  start_gateway
}

# --- Config error detection ---
check_config_error() {
  # Check last 50 lines of gateway log for config error patterns
  if [[ -f "$GATEWAY_LOG" ]]; then
    tail -50 "$GATEWAY_LOG" | grep -qiE "$CONFIG_ERROR_PATTERNS"
    return $?
  fi
  return 1
}

# --- Git operations ---
get_current_hash() {
  cd "$CONFIG_DIR" && git rev-parse HEAD 2>/dev/null
}

get_last_good_hash() {
  if [[ -f "$LAST_GOOD_FILE" ]]; then
    cat "$LAST_GOOD_FILE"
  fi
}

promote_to_last_good() {
  local hash
  hash=$(get_current_hash)
  echo "$hash" > "$LAST_GOOD_FILE"
  # Move the known-good tag to current commit
  cd "$CONFIG_DIR"
  git tag -f "known-good" "$hash" 2>/dev/null || true
  log "INFO" "Promoted $hash to last known good"
}

revert_config() {
  local target_hash current_hash
  cd "$CONFIG_DIR"

  current_hash=$(get_current_hash)
  target_hash=$(get_last_good_hash)

  # Stash uncommitted changes if working tree is dirty
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    git stash push -m "watchdog-autostash-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    log "INFO" "Stashed uncommitted changes before revert"
  fi

  # Only tag as broken if HEAD differs from last known good
  if [[ -n "$target_hash" && "$current_hash" != "$target_hash" ]]; then
    git tag "broken-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    log "INFO" "Tagged $current_hash as broken"
  fi

  if [[ -n "$target_hash" ]]; then
    log "WARN" "Reverting config to last known good: $target_hash"
    git checkout "$target_hash" -- openclaw.json
  else
    log "WARN" "No last_good_hash found, reverting to HEAD~1"
    git checkout HEAD~1 -- openclaw.json 2>/dev/null || {
      log "ERROR" "Cannot revert — no previous commit available"
      return 1
    }
  fi

  git add openclaw.json
  git commit -m "watchdog: auto-revert to known good config" 2>/dev/null || true
  log "INFO" "Config reverted successfully"
}

# --- Probation management ---
start_probation() {
  echo "$(date +%s)" > "$PROBATION_FILE"
  log "INFO" "Config change detected — probation started"
}

check_probation() {
  if [[ ! -f "$PROBATION_FILE" ]]; then
    return 1  # no probation active
  fi
  local start_time elapsed
  start_time=$(cat "$PROBATION_FILE")
  elapsed=$(( $(date +%s) - start_time ))
  if (( elapsed >= PROBATION_DURATION )); then
    return 0  # probation passed
  fi
  return 1  # still in probation
}

clear_probation() {
  rm -f "$PROBATION_FILE"
}

# --- Grace period check ---
in_grace_period() {
  local now elapsed
  now=$(date +%s)
  elapsed=$(( now - last_restart_time ))
  (( elapsed < GRACE_PERIOD ))
}

# --- Crash loop tracking ---
record_crash() {
  local now
  now=$(date +%s)
  if (( now - last_crash_time < CRASH_WINDOW )); then
    (( crash_count++ ))
  else
    crash_count=1
  fi
  last_crash_time=$now
}

is_crash_loop() {
  (( crash_count >= CRASH_THRESHOLD ))
}

# --- Signal handling ---
cleanup() {
  running=false
  log "INFO" "Watchdog shutting down"
  exit 0
}
trap cleanup SIGTERM SIGINT

# --- Main loop ---
main() {
  log "INFO" "=== Watchdog starting ==="
  log "INFO" "Config: $CONF_FILE"
  log "INFO" "Monitoring gateway at $HEALTH_URL"
  log "INFO" "Config dir: $CONFIG_DIR"
  log "INFO" "Dry-run: $DRY_RUN"

  # Initialize config mtime tracking
  last_config_mtime=$(get_config_mtime)

  # If gateway is already healthy, record initial last_good only if not already set
  if check_health; then
    if [[ ! -f "$LAST_GOOD_FILE" ]]; then
      log "INFO" "Gateway already healthy — recording initial last_good_hash"
      promote_to_last_good
    else
      log "INFO" "Gateway healthy, last_good_hash already set: $(cat "$LAST_GOOD_FILE")"
    fi
    # If no PID file exists but gateway is responding, try to find the PID
    if [[ ! -f "$GATEWAY_PID_FILE" ]]; then
      local existing_pid
      existing_pid=$(pgrep -f "openclaw-gateway" 2>/dev/null | while read p; do
        if kill -0 "$p" 2>/dev/null; then echo "$p"; break; fi
      done)
      if [[ -n "$existing_pid" ]]; then
        echo "$existing_pid" > "$GATEWAY_PID_FILE"
        log "INFO" "Found existing gateway PID: $existing_pid"
      fi
    fi
  fi

  while $running; do
    sleep "$POLL_INTERVAL"

    # --- Detect config file changes ---
    current_mtime=$(get_config_mtime)
    if [[ "$current_mtime" != "$last_config_mtime" && -n "$last_config_mtime" ]]; then
      start_probation
      last_config_mtime="$current_mtime"
    fi

    # --- Health check ---
    if check_health; then
      # Gateway is healthy
      crash_count=0

      # Check if probation period has passed
      if check_probation; then
        promote_to_last_good
        clear_probation
      fi
    else
      # Gateway is unhealthy
      if in_grace_period; then
        log "DEBUG" "In grace period after restart, skipping..."
        continue
      fi

      log "WARN" "Gateway unhealthy!"

      if is_gateway_running; then
        # Process exists but not responding — might be starting up
        log "WARN" "Process running but not responding, waiting one more cycle..."
        sleep "$POLL_INTERVAL"
        if check_health; then
          continue
        fi
      fi

      # Gateway is down — check why
      if check_config_error; then
        # Config error detected!
        log "ERROR" "Config error detected in gateway logs!"
        revert_config
        restart_gateway
        send_alert "⚠️ [Watchdog] Gateway crashed (config error). Auto-reverted to last known good config."
      else
        # Non-config crash
        record_crash
        if is_crash_loop; then
          log "ERROR" "Crash loop detected ($crash_count crashes in ${CRASH_WINDOW}s)"
          send_alert "🔴 [Watchdog] Gateway crash loop detected (not config-related). Manual check needed. Last log: $(tail -3 "$GATEWAY_LOG" 2>/dev/null)"
          crash_count=0
          # Don't restart in crash loop — wait for manual intervention
          sleep 60
        else
          log "WARN" "Transient crash — restarting gateway (crash $crash_count/$CRASH_THRESHOLD)"
          restart_gateway
        fi
      fi
    fi
  done
}

main
