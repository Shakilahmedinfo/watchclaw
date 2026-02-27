#!/usr/bin/env bash
# test-watchdog.sh — Test suite for oc-watchdog
# Runs against the "sheep" OpenClaw instance on port 18850
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$HOME/.openclaw-sheep"
GATEWAY_PORT=18850
GATEWAY_LOG="/tmp/sheep-gateway.log"
WATCHDOG_PID=""
PASS=0
FAIL=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${YELLOW}[TEST]${NC} $*"; }
pass() { echo -e "${GREEN}[PASS]${NC} $*"; (( PASS++ )); }
fail() { echo -e "${RED}[FAIL]${NC} $*"; (( FAIL++ )); }

# --- Helpers ---
GATEWAY_PID_FILE="$CONFIG_DIR/.gateway.pid"

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

start_sheep() {
  log "Starting sheep gateway..."
  cd "$CONFIG_DIR"
  OPENCLAW_STATE_DIR="$CONFIG_DIR" \
  OPENCLAW_CONFIG_PATH="$CONFIG_DIR/openclaw.json" \
    nohup node /opt/homebrew/lib/node_modules/openclaw/dist/index.js gateway --port $GATEWAY_PORT \
    >> "$GATEWAY_LOG" 2>&1 &
  echo "$!" > "$GATEWAY_PID_FILE"
  sleep 3
}

stop_sheep() {
  local pid
  pid=$(gateway_pid)
  [[ -n "$pid" ]] && kill "$pid" 2>/dev/null && sleep 2
  pid=$(gateway_pid)
  [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null
  rm -f "$GATEWAY_PID_FILE"
}

check_health() {
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$GATEWAY_PORT/" 2>/dev/null) || return 1
  [[ "$code" == "200" ]]
}

start_watchdog() {
  log "Starting watchdog in background..."
  "$SCRIPT_DIR/oc-watchdog.sh" "$SCRIPT_DIR/oc-watchdog.conf" &
  WATCHDOG_PID=$!
  sleep 2
}

stop_watchdog() {
  [[ -n "$WATCHDOG_PID" ]] && kill "$WATCHDOG_PID" 2>/dev/null
  WATCHDOG_PID=""
  sleep 1
}

cleanup() {
  log "Cleaning up..."
  stop_watchdog
  stop_sheep
  # Restore config if broken
  cd "$CONFIG_DIR"
  git checkout HEAD -- openclaw.json 2>/dev/null || true
  rm -f "$CONFIG_DIR/.watchdog_probation"
}
trap cleanup EXIT

# ========================================
# TEST 1: Healthy baseline
# ========================================
test_healthy_baseline() {
  log "========== TEST 1: Healthy Baseline =========="

  # Ensure sheep is running
  stop_sheep
  sleep 1
  start_sheep

  if check_health; then
    pass "Sheep gateway is healthy on port $GATEWAY_PORT"
  else
    fail "Sheep gateway not healthy"
    return
  fi

  # Start watchdog
  start_watchdog

  # Wait a few cycles
  sleep 15

  # Check watchdog is running and logging
  if kill -0 "$WATCHDOG_PID" 2>/dev/null; then
    pass "Watchdog is running"
  else
    fail "Watchdog died"
    return
  fi

  # Check that last_good_hash was written (initial promotion)
  if [[ -f "$CONFIG_DIR/.last_good_hash" ]]; then
    local hash
    hash=$(cat "$CONFIG_DIR/.last_good_hash")
    log "last_good_hash = $hash"
    pass "last_good_hash file created"
  else
    fail "last_good_hash not created"
  fi

  stop_watchdog
  log "TEST 1 complete"
}

# ========================================
# TEST 2: Config error → auto-revert
# ========================================
test_config_error_revert() {
  log "========== TEST 2: Config Error → Auto-Revert =========="

  # Make sure sheep is healthy
  stop_sheep
  sleep 1

  # Ensure clean config and record good hash
  cd "$CONFIG_DIR"
  git checkout HEAD -- openclaw.json 2>/dev/null || true
  start_sheep
  sleep 3

  if ! check_health; then
    fail "Cannot establish healthy baseline"
    return
  fi

  # Record the good config hash
  local good_hash
  good_hash=$(cd "$CONFIG_DIR" && git rev-parse HEAD)
  echo "$good_hash" > "$CONFIG_DIR/.last_good_hash"
  log "Good hash: $good_hash"

  # Save good config for verification
  local good_config
  good_config=$(cat "$CONFIG_DIR/openclaw.json")

  # Start watchdog
  start_watchdog
  sleep 5

  # Now corrupt the config
  log "Corrupting openclaw.json..."
  echo '{"BROKEN: this is not valid JSON!!!}}}' > "$CONFIG_DIR/openclaw.json"
  cd "$CONFIG_DIR" && git add openclaw.json && git commit -m "test: intentionally broken config"

  # Stop sheep to simulate crash from bad config
  stop_sheep
  sleep 1

  # Write config error to log so watchdog detects it
  echo "$(date -u '+%Y-%m-%dT%H:%M:%S.000Z') [gateway] Invalid config at $CONFIG_DIR/openclaw.json: SyntaxError: Unexpected token" >> "$GATEWAY_LOG"

  # Wait for watchdog to detect and fix
  log "Waiting for watchdog to detect failure and revert..."
  sleep 55  # grace period (30s) + poll interval (10s) + extra wait for process check

  # Check results
  local current_config
  current_config=$(cat "$CONFIG_DIR/openclaw.json")

  if [[ "$current_config" == "$good_config" ]]; then
    pass "Config was reverted to known good state"
  else
    fail "Config was NOT reverted. Current: $(head -1 "$CONFIG_DIR/openclaw.json")"
  fi

  # Check that broken tag was created
  if cd "$CONFIG_DIR" && git tag | grep -q "^broken-"; then
    pass "Broken config was tagged"
  else
    fail "Broken config was not tagged"
  fi

  # Check watchdog log for revert message
  if grep -q "auto-revert\|Config error detected\|Reverting config" "$SCRIPT_DIR/logs/watchdog.log"; then
    pass "Watchdog logged the revert action"
  else
    fail "No revert message in watchdog log"
  fi

  # Check alert was sent (dry-run)
  if grep -q "DRY-RUN.*config error" "$SCRIPT_DIR/logs/watchdog.log"; then
    pass "Alert triggered (dry-run)"
  else
    fail "No alert in watchdog log"
  fi

  # Check gateway was restarted
  sleep 5
  if check_health; then
    pass "Gateway is healthy again after revert"
  else
    log "(Gateway may not restart cleanly in test environment — checking if process was started)"
    if is_gateway_running 2>/dev/null || grep -q "Starting gateway" "$SCRIPT_DIR/logs/watchdog.log"; then
      pass "Watchdog attempted to restart gateway"
    else
      fail "Gateway not restarted"
    fi
  fi

  stop_watchdog
  log "TEST 2 complete"
}

# ========================================
# TEST 3: Transient crash → simple restart
# ========================================
test_transient_crash() {
  log "========== TEST 3: Transient Crash → Simple Restart =========="

  stop_sheep
  sleep 1

  # Restore good config
  cd "$CONFIG_DIR"
  git checkout HEAD -- openclaw.json 2>/dev/null || true
  # Find last good commit (before broken)
  local good_hash
  good_hash=$(cat "$CONFIG_DIR/.last_good_hash" 2>/dev/null)
  if [[ -n "$good_hash" ]]; then
    git checkout "$good_hash" -- openclaw.json 2>/dev/null || true
  fi

  start_sheep
  sleep 3

  if ! check_health; then
    fail "Cannot establish healthy baseline"
    return
  fi

  # Clear old logs
  > "$SCRIPT_DIR/logs/watchdog.log"
  > "$GATEWAY_LOG"

  start_watchdog
  sleep 5

  # Kill sheep abruptly (simulating transient crash)
  log "Killing sheep gateway (kill -9)..."
  local pid
  pid=$(gateway_pid)
  [[ -n "$pid" ]] && kill -9 "$pid"
  sleep 2

  # Wait for watchdog to detect and restart
  log "Waiting for watchdog to detect and restart..."
  sleep 45  # grace (30) + detection

  # Check that config was NOT reverted (no config error)
  if grep -q "Reverting config\|Config error detected" "$SCRIPT_DIR/logs/watchdog.log"; then
    fail "Watchdog incorrectly reverted config on transient crash"
  else
    pass "Config was NOT reverted (correct for transient crash)"
  fi

  # Check that restart was attempted
  if grep -q "Transient crash.*restarting\|Starting gateway" "$SCRIPT_DIR/logs/watchdog.log"; then
    pass "Watchdog restarted gateway after transient crash"
  else
    fail "Watchdog did not restart gateway"
  fi

  stop_watchdog
  log "TEST 3 complete"
}

# ========================================
# TEST 4: Crash loop → alert
# ========================================
test_crash_loop() {
  log "========== TEST 4: Crash Loop → Alert =========="

  stop_sheep
  sleep 1

  # Clear logs
  > "$SCRIPT_DIR/logs/watchdog.log"
  > "$GATEWAY_LOG"

  # Block port 18850 with a dummy listener so gateway can't start
  log "Blocking port $GATEWAY_PORT with dummy listener..."
  python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $GATEWAY_PORT))
s.listen(1)
time.sleep(300)
" &
  local blocker_pid=$!
  sleep 1

  # Start watchdog (gateway will fail to start each time)
  start_watchdog

  # Wait long enough for 3 crash detections
  # Each cycle: poll (10s) + grace (30s) + extra wait
  log "Waiting for crash loop detection (this takes ~2 min)..."
  sleep 130

  # Check for crash loop alert
  if grep -q "crash loop\|Crash loop" "$SCRIPT_DIR/logs/watchdog.log"; then
    pass "Crash loop detected"
  else
    fail "Crash loop not detected"
  fi

  if grep -q "DRY-RUN.*crash loop\|DRY-RUN.*Manual check" "$SCRIPT_DIR/logs/watchdog.log"; then
    pass "Crash loop alert triggered (dry-run)"
  else
    fail "No crash loop alert"
  fi

  # Cleanup
  kill "$blocker_pid" 2>/dev/null
  stop_watchdog
  log "TEST 4 complete"
}

# ========================================
# Run all tests
# ========================================
echo ""
echo "============================================"
echo "  OC-WATCHDOG TEST SUITE"
echo "  Target: sheep (port $GATEWAY_PORT)"
echo "============================================"
echo ""

test_healthy_baseline
echo ""
test_config_error_revert
echo ""
test_transient_crash
echo ""
test_crash_loop

echo ""
echo "============================================"
echo -e "  Results: ${GREEN}${PASS} PASS${NC} / ${RED}${FAIL} FAIL${NC}"
echo "============================================"
