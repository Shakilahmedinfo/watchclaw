#!/usr/bin/env bash
# Shared helpers for watchclaw tests
set -uo pipefail

SHEEP_DIR="$HOME/.openclaw-sheep"
SHEEP_PORT=18851
SHEEP_LOG="/tmp/sheep-gateway.log"
WATCHCLAW="$(cd "$(dirname "$0")/.." && pwd)/watchclaw.sh"
TEST_CONF="$(cd "$(dirname "$0")" && pwd)/test.conf"
TEST_LOG="/tmp/watchclaw-test.log"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

pass() { echo -e "${GREEN}✅ PASS${NC}: $1"; }
fail() { echo -e "${RED}❌ FAIL${NC}: $1"; FAILURES=$((FAILURES + 1)); }
info() { echo -e "${YELLOW}ℹ️${NC}  $1"; }
FAILURES=0

# Resolve OpenClaw binary
_resolve_openclaw() {
  if [[ -n "${OPENCLAW_BIN:-}" ]]; then
    echo "$OPENCLAW_BIN"
  else
    command -v openclaw 2>/dev/null || echo ""
  fi
}

# Start sheep gateway directly (no watchdog)
start_sheep() {
  stop_sheep
  local oc_bin
  oc_bin=$(_resolve_openclaw)
  if [[ -z "$oc_bin" ]]; then
    fail "Cannot find openclaw binary. Set OPENCLAW_BIN."
    return 1
  fi
  cd "$SHEEP_DIR"
  > "$SHEEP_LOG"
  OPENCLAW_STATE_DIR="$SHEEP_DIR" \
  OPENCLAW_CONFIG_PATH="$SHEEP_DIR/openclaw.json" \
    "$oc_bin" gateway start \
    --port "$SHEEP_PORT" >> "$SHEEP_LOG" 2>&1 &
  local pid=$!
  disown "$pid" 2>/dev/null
  echo "$pid" > "$SHEEP_DIR/.gateway.pid"
  info "Sheep started (PID $pid)"
}

stop_sheep() {
  if [[ -f "$SHEEP_DIR/.gateway.pid" ]]; then
    local pid=$(cat "$SHEEP_DIR/.gateway.pid")
    kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null || true
    rm -f "$SHEEP_DIR/.gateway.pid"
  fi
  # Also kill anything on the port
  lsof -ti :$SHEEP_PORT 2>/dev/null | xargs kill -9 2>/dev/null || true
}

sheep_healthy() {
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:${SHEEP_PORT}/" 2>/dev/null) || return 1
  [[ "$code" == "200" ]]
}

wait_for_sheep() {
  local timeout=${1:-30}
  local elapsed=0
  while (( elapsed < timeout )); do
    sheep_healthy && return 0
    sleep 2; elapsed=$((elapsed + 2))
  done
  return 1
}

# Start watchdog in background
start_watchdog() {
  # Clean stale lock to avoid "another instance" rejection
  rm -f "/tmp/watchclaw-${SHEEP_PORT}.pid"
  > "$TEST_LOG"
  set -m  # enable job control for process groups
  bash "$WATCHCLAW" "$TEST_CONF" &
  WATCHDOG_PID=$!
  set +m
  info "Watchclaw started (PID $WATCHDOG_PID)"
}

stop_watchdog() {
  if [[ -n "${WATCHDOG_PID:-}" ]]; then
    # Kill the process group to catch all children
    kill -- -"$WATCHDOG_PID" 2>/dev/null || kill "$WATCHDOG_PID" 2>/dev/null || true
    sleep 1
    kill -9 -- -"$WATCHDOG_PID" 2>/dev/null || kill -9 "$WATCHDOG_PID" 2>/dev/null || true
  fi
  # Kill any remaining watchclaw processes on the test port
  pgrep -f "watchclaw.sh.*test.conf" | xargs kill -9 2>/dev/null || true
  rm -f "/tmp/watchclaw-${SHEEP_PORT}.pid"
}

# Check watchdog log for a pattern
log_contains() {
  grep -q "$1" "$TEST_LOG" 2>/dev/null
}

# Wait until watchdog log contains a pattern
wait_for_log() {
  local pattern="$1" timeout=${2:-60} elapsed=0
  while (( elapsed < timeout )); do
    log_contains "$pattern" && return 0
    sleep 2; elapsed=$((elapsed + 2))
  done
  return 1
}

# Break sheep config (inject invalid JSON)
break_config() {
  cd "$SHEEP_DIR"
  echo '{"BROKEN invalid json !!!' > openclaw.json
  git add openclaw.json
  git commit -m "test: break config intentionally" --quiet
  info "Config broken (committed bad JSON)"
}

# Break config without committing (dirty tree)
break_config_dirty() {
  cd "$SHEEP_DIR"
  echo '{"BROKEN invalid json !!!' > openclaw.json
  info "Config broken (dirty, uncommitted)"
}

# Restore config from known-good
restore_config_manual() {
  cd "$SHEEP_DIR"
  local kg
  kg=$(git rev-parse known-good 2>/dev/null) || { info "No known-good to restore from"; return 1; }
  git checkout "$kg" -- . 2>/dev/null
  git commit -m "test: restore config manually" --quiet 2>/dev/null || true
  info "Config restored manually"
}

# Save the current commit as baseline (call once at test start)
BASELINE_COMMIT=""
save_baseline() {
  cd "$SHEEP_DIR"
  BASELINE_COMMIT=$(git rev-parse HEAD)
  info "Baseline commit: $BASELINE_COMMIT"
}

# Reset sheep to clean state for next test
reset_sheep() {
  stop_watchdog
  stop_sheep
  cd "$SHEEP_DIR"

  # Save baseline before any changes
  if [[ -z "$BASELINE_COMMIT" ]]; then
    BASELINE_COMMIT=$(git rev-parse HEAD)
  fi

  # Clean state files (preserve known-good tag for speed)
  rm -f .watchdog_probation .gateway.pid
  git stash clear 2>/dev/null || true
  git reset --hard "${BASELINE_COMMIT:-HEAD}" --quiet 2>/dev/null || true
  git tag -l "broken-*" | xargs -I{} git tag -d {} 2>/dev/null || true
  > "$TEST_LOG"
  > "$SHEEP_LOG"
  info "Sheep reset to clean state"
}

# Light cleanup: stop processes, reset git, but KEEP known-good tag
cleanup_test() {
  stop_watchdog
  stop_sheep
  cd "$SHEEP_DIR"
  if [[ -n "$BASELINE_COMMIT" ]]; then
    git reset --hard "$BASELINE_COMMIT" --quiet 2>/dev/null
    git stash clear 2>/dev/null || true
    git tag -l "broken-*" | xargs -I{} git tag -d {} 2>/dev/null || true
    rm -f .watchdog_probation .gateway.pid
    info "Cleaned up — repo back to $BASELINE_COMMIT (known-good preserved)"
  fi
}

# Full cleanup: also remove known-good tag (for anchoring tests)
cleanup_test_full() {
  cleanup_test
  cd "$SHEEP_DIR"
  git tag -d known-good 2>/dev/null || true
  info "Removed known-good tag"
}

# Ensure known-good tag exists (bootstrap if needed)
ensure_known_good() {
  cd "$SHEEP_DIR"
  if git rev-parse "known-good" &>/dev/null; then
    info "Known-good already exists: $(git rev-parse known-good)"
    return 0
  fi
  # Bootstrap: start sheep + watchdog, wait for promotion
  start_sheep
  wait_for_sheep 30 || { fail "Sheep didn't start for bootstrap"; return 1; }
  start_watchdog
  wait_for_log "Promoted.*to known-good" 45 || { fail "Bootstrap failed — no known-good promoted"; return 1; }
  stop_watchdog
  stop_sheep
  info "Bootstrapped known-good: $(git rev-parse known-good)"
}

# Print summary
summary() {
  echo ""
  if (( FAILURES == 0 )); then
    echo -e "${GREEN}All tests passed!${NC}"
  else
    echo -e "${RED}${FAILURES} test(s) failed${NC}"
  fi
  return $FAILURES
}
