#!/usr/bin/env bash
# watchclaw.sh — OpenClaw Gateway Watchdog (core FSM)
# See README.md for FSM spec. Use the `watchclaw` CLI to manage lifecycle.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="${1:-}"

# Config search order: arg → $WATCHCLAW_CONF → ./watchclaw.conf → ~/.config/watchclaw/watchclaw.conf
if [[ -z "$CONF_FILE" ]]; then
  if [[ -n "${WATCHCLAW_CONF:-}" && -f "$WATCHCLAW_CONF" ]]; then
    CONF_FILE="$WATCHCLAW_CONF"
  elif [[ -f "$SCRIPT_DIR/watchclaw.conf" ]]; then
    CONF_FILE="$SCRIPT_DIR/watchclaw.conf"
  elif [[ -f "$HOME/.config/watchclaw/watchclaw.conf" ]]; then
    CONF_FILE="$HOME/.config/watchclaw/watchclaw.conf"
  fi
fi

if [[ -z "$CONF_FILE" || ! -f "$CONF_FILE" ]]; then
  echo "ERROR: Config not found. Searched: \$WATCHCLAW_CONF, ./watchclaw.conf, ~/.config/watchclaw/watchclaw.conf" >&2
  echo "  Create one from watchclaw.conf.example or pass --config PATH" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONF_FILE"

# ── Single instance lock (per port) ─────────────────────────────────
LOCK_FILE="/tmp/watchclaw-${GATEWAY_PORT}.pid"
GATEWAY_PID_FILE="$(dirname "$LOG_FILE")/.gateway-${GATEWAY_PORT}.pid"
if [[ -f "$LOCK_FILE" ]]; then
  existing_pid=$(cat "$LOCK_FILE" 2>/dev/null)
  if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
    echo "ERROR: Another watchclaw instance (PID $existing_pid) is already running for port $GATEWAY_PORT" >&2
    exit 1
  fi
fi
echo $$ > "$LOCK_FILE"

# ── State machine ────────────────────────────────────────────────────
STATE="IDLE"          # IDLE | HEALTHY | PROBATION | RESTARTING | ALERT
retry_count=0
backoff=$BACKOFF_INITIAL_SEC
next_alert_time=0
probation_start=0
recovering=false    # true when recovering from a failure (for recovery alert)
running=true

# ── Logging ──────────────────────────────────────────────────────────
LOG_MAX_BYTES="${LOG_MAX_BYTES:-1048576}"  # default 1MB
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$GATEWAY_LOG")"

rotate_if_needed() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local size
  size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)
  if (( size > LOG_MAX_BYTES )); then
    mv "$file" "${file}.1"
  fi
}

log() {
  local line
  line=$(printf '[%s] [%s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2")
  rotate_if_needed "$LOG_FILE"
  echo "$line" >> "$LOG_FILE"
  # In foreground mode (stdin is a tty), also print errors/alerts to stderr
  if [[ "$1" == "ERROR" || "$1" == "ALERT" ]] && [[ -t 2 || "${WATCHCLAW_FOREGROUND:-0}" == "1" ]]; then
    echo "$line" >&2
  fi
}

# ── Alert Hook ────────────────────────────────────────────────────────
ALERT_HOOK="${ALERT_HOOK:-none}"

# Backward compat: ALERT_PHONE → ALERT_IMSG_TO
if [[ -n "${ALERT_PHONE:-}" && -z "${ALERT_IMSG_TO:-}" ]]; then
  ALERT_IMSG_TO="$ALERT_PHONE"
  ALERT_HOOK="${ALERT_HOOK:-imsg}"
  [[ "$ALERT_HOOK" == "none" ]] && ALERT_HOOK="imsg"
fi

_alert_imsg() {
  if [[ -z "${ALERT_IMSG_TO:-}" ]]; then
    log "WARN" "ALERT_IMSG_TO not set — cannot send iMessage alert"
    return 1
  fi
  command -v imsg &>/dev/null || { log "WARN" "imsg not found"; return 1; }
  imsg send --to "$ALERT_IMSG_TO" --text "$1" 2>/dev/null || { log "WARN" "iMessage send failed"; return 1; }
}

_alert_webhook() {
  if [[ -z "${ALERT_WEBHOOK_URL:-}" ]]; then
    log "WARN" "ALERT_WEBHOOK_URL not set"
    return 1
  fi
  curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"text\":$(printf '%s' "$1" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "\"$1\"")}" \
    "$ALERT_WEBHOOK_URL" >/dev/null 2>&1 || { log "WARN" "Webhook alert failed"; return 1; }
}

_alert_command() {
  if [[ -z "${ALERT_COMMAND:-}" ]]; then
    log "WARN" "ALERT_COMMAND not set"
    return 1
  fi
  eval "$ALERT_COMMAND" "$1" 2>/dev/null || { log "WARN" "Alert command failed"; return 1; }
}

send_alert() {
  local target="${WATCHCLAW_TARGET:-port $GATEWAY_PORT}"
  local ts
  ts="$(date '+%b %d %H:%M')"
  local msg="[$ts] [$target] ${1#\[Watchclaw\] }"
  log "ALERT" "$msg"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "ALERT" "[DRY-RUN] Would send: $msg"
    return
  fi
  case "${ALERT_HOOK}" in
    imsg)    _alert_imsg "$msg" ;;
    webhook) _alert_webhook "$msg" ;;
    command) _alert_command "$msg" ;;
    none)    ;; # log-only
    *)       log "WARN" "Unknown alert hook: $ALERT_HOOK" ;;
  esac
}

# ── Health check ─────────────────────────────────────────────────────
check_health() {
  local scheme="http"
  [[ "${GATEWAY_TLS:-0}" == "1" ]] && scheme="https"
  local code
  code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time "$HEALTH_TIMEOUT_SEC" \
    "${scheme}://127.0.0.1:${GATEWAY_PORT}/" 2>/dev/null) || return 1
  [[ "$code" == "200" ]]
}

# ── Gateway control ──────────────────────────────────────────────────
RESTART_MODE="${RESTART_MODE:-native}"
DOCKER_CONTAINER="${DOCKER_CONTAINER:-}"

stop_gateway() {
  if [[ "$RESTART_MODE" == "docker" ]]; then
    log "INFO" "Stopping container '$DOCKER_CONTAINER'"
    docker stop "$DOCKER_CONTAINER" 2>/dev/null || true
    return
  fi
  if [[ -f "${GATEWAY_PID_FILE}" ]]; then
    local pid
    pid=$(cat "${GATEWAY_PID_FILE}")
    if kill -0 "$pid" 2>/dev/null; then
      log "INFO" "Stopping gateway (PID $pid)"
      kill "$pid" 2>/dev/null; sleep 2
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "${GATEWAY_PID_FILE}"
  fi
}

start_gateway() {
  if [[ "$RESTART_MODE" == "docker" ]]; then
    if [[ -z "$DOCKER_CONTAINER" ]]; then
      log "ERROR" "DOCKER_CONTAINER not set. Required when RESTART_MODE=docker."
      return 1
    fi
    log "INFO" "Starting container '$DOCKER_CONTAINER'"
    docker start "$DOCKER_CONTAINER" >> "${GATEWAY_LOG:-/dev/null}" 2>&1
    log "INFO" "Container '$DOCKER_CONTAINER' started"
    return
  fi

  cd "$GATEWAY_CONFIG_DIR"
  rotate_if_needed "$GATEWAY_LOG"
  > "$GATEWAY_LOG"  # truncate log for clean detection

  # Resolve OpenClaw entry point
  local oc_bin="${OPENCLAW_BIN:-}"
  if [[ -z "$oc_bin" ]]; then
    oc_bin=$(command -v openclaw 2>/dev/null || true)
  fi
  if [[ -z "$oc_bin" ]]; then
    log "ERROR" "Cannot find openclaw binary. Set OPENCLAW_BIN in config."
    return 1
  fi

  # shellcheck disable=SC2086
  OPENCLAW_STATE_DIR="$GATEWAY_CONFIG_DIR" \
  OPENCLAW_CONFIG_PATH="$GATEWAY_CONFIG_DIR/openclaw.json" \
    "$oc_bin" ${OPENCLAW_ARGS:-} gateway start \
    --port "$GATEWAY_PORT" >> "$GATEWAY_LOG" 2>&1 &
  local pid=$!
  disown "$pid" 2>/dev/null
  echo "$pid" > "${GATEWAY_PID_FILE}"
  log "INFO" "Gateway started (PID $pid)"
}

# Start gateway, wait GRACE_PERIOD_SEC, return 0 if healthy
try_restart() {
  if [[ "$RESTART_MODE" == "docker" ]]; then
    log "INFO" "Restarting container '$DOCKER_CONTAINER'"
    docker restart "$DOCKER_CONTAINER" >> "${GATEWAY_LOG:-/dev/null}" 2>&1
  else
    stop_gateway
    sleep 1
    start_gateway
  fi
  log "INFO" "Waiting ${GRACE_PERIOD_SEC}s grace period..."
  sleep "$GRACE_PERIOD_SEC"
  check_health
}

# ── Git helpers ──────────────────────────────────────────────────────
git_c() { git -C "$GATEWAY_CONFIG_DIR" "$@"; }

current_hash() { git_c rev-parse HEAD 2>/dev/null; }

last_good_hash() {
  git_c rev-parse "known-good" 2>/dev/null
}

is_dirty() {
  # Only check openclaw.json — other files (auth-profiles, state) change at runtime
  ! git_c diff --quiet -- openclaw.json 2>/dev/null || \
  ! git_c diff --cached --quiet -- openclaw.json 2>/dev/null
}

promote_known_good() {
  local h
  h=$(current_hash)
  git_c tag -f "known-good" "$h" 2>/dev/null || true
  log "INFO" "Promoted $h to known-good"
}

CONFIG_ERROR_PATTERNS="Invalid config|Config invalid|SyntaxError|JSON|parse error|schema|ENOENT|TypeError|Cannot read|validation|Unrecognized key"

has_config_error() {
  # Check recent gateway log for config error patterns
  if tail -30 "$GATEWAY_LOG" 2>/dev/null | grep -qiE "$CONFIG_ERROR_PATTERNS"; then
    return 0
  fi
  # In docker mode, also check container logs (errors may not reach GATEWAY_LOG)
  if [[ "$RESTART_MODE" == "docker" && -n "$DOCKER_CONTAINER" ]]; then
    if docker logs --tail 30 "$DOCKER_CONTAINER" 2>&1 | grep -qiE "$CONFIG_ERROR_PATTERNS"; then
      return 0
    fi
  fi
  return 1
}

# ── Recovery actions (U1, U2, U3) ───────────────────────────────────

# U1: dirty working tree → stash
do_stash() {
  local name="watchclaw-$(date +%Y%m%d-%H%M%S)"
  # Only stash openclaw.json — leave runtime files (auth-profiles, etc.) alone
  git_c stash push -m "$name" -- openclaw.json 2>/dev/null
  log "WARN" "U1: Stashed dirty openclaw.json as '$name'"
}

# U2: clean tree, current ≠ known-good → tag broken, revert
do_revert_to_known_good() {
  local cur kg
  cur=$(current_hash)
  kg=$(last_good_hash)
  git_c tag "broken-${cur:0:7}" "$cur" 2>/dev/null || true
  log "WARN" "U2: Tagged $cur as broken, reverting openclaw.json to $kg"
  # Restore openclaw.json from known-good and commit
  git_c checkout "$kg" -- openclaw.json 2>/dev/null
  git_c commit -m "watchclaw: auto-revert openclaw.json to known-good ($kg)" 2>/dev/null || true
}

# ── Retry logic ──────────────────────────────────────────────────────
enter_retry() {
  retry_count=0
  recovering=true
  do_retry_loop
}

do_retry_loop() {
  while (( retry_count < MAX_RETRIES )); do
    (( retry_count++ ))
    log "INFO" "Retry $retry_count/$MAX_RETRIES"
    if try_restart; then
      log "INFO" "Retry succeeded — entering PROBATION (${PROBATION_DURATION_SEC}s)"
      STATE="PROBATION"
      probation_start=$(date +%s)
      retry_count=0
      backoff=$BACKOFF_INITIAL_SEC
      return
    fi
  done
  # Exhausted retries → ALERT
  STATE="ALERT"
  send_alert "Gateway down after $MAX_RETRIES retries. Manual intervention needed."
  next_alert_time=$(( $(date +%s) + backoff ))
  backoff=$(( backoff * 2 ))
  (( backoff > BACKOFF_MAX_SEC )) && backoff=$BACKOFF_MAX_SEC
}

# ── Handle unhealthy ─────────────────────────────────────────────────
handle_unhealthy() {
  log "WARN" "Gateway unhealthy — diagnosing..."

  # First: try a plain restart (could be transient)
  if try_restart; then
    # Even if healthy, check for config errors in log (some gateways start
    # with "best-effort" config despite parse errors — still needs revert)
    if has_config_error; then
      log "WARN" "Gateway started but config errors detected — proceeding with diagnosis"
    else
      log "INFO" "Recovered with simple restart — entering PROBATION (${PROBATION_DURATION_SEC}s)"
      STATE="PROBATION"
      probation_start=$(date +%s)
      retry_count=0
      recovering=true
      return
    fi
  fi

  # Restart failed — check if config error
  if ! has_config_error; then
    # U3-like: not a config problem, just enter retry
    log "WARN" "Not a config error — entering retry logic"
    enter_retry
    return
  fi

  # Config error confirmed — classify
  log "ERROR" "Config error detected in gateway log"
  send_alert "Gateway down — config error detected. Attempting auto-recovery."
  local cur kg

  cur=$(current_hash)
  kg=$(last_good_hash)
  if is_dirty; then
    # U1: dirty tree
    do_stash
  elif [[ -n "$kg" && "$cur" != "$kg" ]]; then
    # U2: clean tree, current ≠ known-good
    do_revert_to_known_good
  else
    # U3: clean tree, current = known-good (or no known-good)
    log "WARN" "U3: Config is at known-good (or none exists) but still failing — not a recoverable config issue"
    enter_retry
    return
  fi

  # After U1/U2 recovery action, enter retry loop
  enter_retry
}

# ── Signal handling ──────────────────────────────────────────────────
cleanup() { running=false; rm -f "$LOCK_FILE"; log "INFO" "Watchclaw shutting down"; exit 0; }
trap cleanup SIGINT SIGTERM
trap '' SIGHUP

# ── Main loop ────────────────────────────────────────────────────────
main() {
  log "INFO" "=== Watchclaw starting ==="
  log "INFO" "Port: $GATEWAY_PORT | Config: $GATEWAY_CONFIG_DIR | Dry-run: $DRY_RUN"

  # ── Known-good anchoring ──────────────────────────────────────────
  # Before monitoring, ensure a known-good anchor exists or can be established.
  if git_c rev-parse "known-good" &>/dev/null; then
    log "INFO" "Known-good anchor exists: $(last_good_hash)"
  else
    log "WARN" "No known-good anchor — attempting to establish one"

    # Pre-check: must be a git repo with a clean tree and at least one commit
    if ! git_c rev-parse HEAD &>/dev/null; then
      log "ERROR" "Not a git repo or no commits — cannot anchor known-good. Exiting."
      exit 1
    fi
    if is_dirty; then
      log "ERROR" "Dirty working tree — cannot anchor known-good. Clean the tree first. Exiting."
      exit 1
    fi

    # Config must be valid JSON
    if ! python3 -c "import json; json.load(open('${GATEWAY_CONFIG_DIR}/openclaw.json'))" 2>/dev/null && \
       ! node -e "JSON.parse(require('fs').readFileSync('${GATEWAY_CONFIG_DIR}/openclaw.json','utf8'))" 2>/dev/null; then
      log "ERROR" "Config is not valid JSON — cannot anchor known-good. Fix config first. Exiting."
      exit 1
    fi

    # Gateway must be healthy
    if ! check_health; then
      log "ERROR" "Gateway not healthy and no known-good exists — cannot anchor. Start gateway first. Exiting."
      exit 1
    fi

    # All preconditions met — enter probation to validate before anchoring
    log "INFO" "Gateway healthy, clean tree, valid config — entering probation (${PROBATION_DURATION_SEC}s) to anchor known-good"
    STATE="PROBATION"
    probation_start=$(date +%s)
    retry_count=0
  fi

  # Normal startup (known-good exists)
  if [[ "$STATE" != "PROBATION" ]]; then
    if check_health; then
      STATE="HEALTHY"
      log "INFO" "Gateway healthy (state=HEALTHY)"
    else
      log "WARN" "Gateway not healthy at start — will attempt recovery"
      handle_unhealthy
    fi
  fi

  while $running; do
    sleep "$POLL_INTERVAL_SEC"

    case "$STATE" in
      HEALTHY)
        if check_health; then
          # H3: detect config changes while healthy (HEAD drifted from known-good)
          local cur_hash kg_hash
          cur_hash=$(current_hash)
          kg_hash=$(last_good_hash)
          if [[ -n "$kg_hash" && "$cur_hash" != "$kg_hash" ]]; then
            log "INFO" "Config changed while healthy ($kg_hash → $cur_hash) — entering PROBATION (${PROBATION_DURATION_SEC}s)"
            STATE="PROBATION"
            probation_start=$(date +%s)
          fi
        else
          handle_unhealthy
        fi
        ;;

      PROBATION)
        if check_health; then
          local elapsed=$(( $(date +%s) - probation_start ))
          if (( elapsed >= PROBATION_DURATION_SEC )); then
            # H2/H3: probation passed → promote
            promote_known_good
            STATE="HEALTHY"
            log "INFO" "Probation passed — state=HEALTHY"
            if [[ "$recovering" == "true" ]]; then
              send_alert "Gateway recovered and stable. New known-good promoted."
              recovering=false
            fi
          fi
        else
          # H1: died during probation → counts as retry
          log "WARN" "H1: Gateway died during probation"
          (( retry_count++ ))
          if (( retry_count > MAX_RETRIES )); then
            STATE="ALERT"
            send_alert "Gateway keeps dying during probation. Manual check needed."
            next_alert_time=$(( $(date +%s) + backoff ))
            backoff=$(( backoff * 2 ))
            (( backoff > BACKOFF_MAX_SEC )) && backoff=$BACKOFF_MAX_SEC
          else
            log "INFO" "Probation failure — retry $retry_count/$MAX_RETRIES"
            if try_restart; then
              STATE="PROBATION"
              probation_start=$(date +%s)
            else
              do_retry_loop
            fi
          fi
        fi
        ;;

      ALERT)
        if check_health; then
          # Recovered!
          log "INFO" "Gateway recovered from ALERT state"
          send_alert "Gateway is back up! Entering probation."
          STATE="PROBATION"
          probation_start=$(date +%s)
          retry_count=0
          recovering=true
          backoff=$BACKOFF_INITIAL_SEC
        else
          local now
          now=$(date +%s)
          if (( now >= next_alert_time )); then
            send_alert "Gateway still down. Next alert in ${backoff}s."
            next_alert_time=$(( now + backoff ))
            backoff=$(( backoff * 2 ))
            (( backoff > BACKOFF_MAX_SEC )) && backoff=$BACKOFF_MAX_SEC
          fi
        fi
        ;;

      RESTARTING)
        # Shouldn't stay here — handle_unhealthy transitions out
        handle_unhealthy
        ;;
    esac
  done
}

main
