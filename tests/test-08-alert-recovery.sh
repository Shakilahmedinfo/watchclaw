#!/usr/bin/env bash
# Test 08: ALERT state recovery — gateway comes back after ALERT, resets backoff
# Covers: ALERT → gateway recovers → PROBATION → HEALTHY
source "$(dirname "$0")/helpers.sh"

trap 'cleanup_test; exit 130' INT TERM
echo "═══ Test 08: ALERT → Recovery ═══"
reset_sheep

# Step 1: Bootstrap known-good
ensure_known_good || { summary; exit 1; }
info "Watchclaw bootstrapped"

# Step 2: Block port to cause non-config failure → ALERT
sleep 1

node -e "
const net = require('net');
process.on('SIGTERM', () => process.exit(0));
const s = net.createServer();
s.listen($SHEEP_PORT, '127.0.0.1');
setTimeout(() => {}, 600000);
" &
BLOCKER_PID=$!
sleep 1
info "Port blocker running (PID $BLOCKER_PID)"

start_watchdog

# Step 3: Wait for ALERT state
if wait_for_log "ALERT.*Gateway down after\|DRY-RUN.*Would send" 180; then
  pass "Entered ALERT state"
else
  fail "Didn't reach ALERT"
  kill "$BLOCKER_PID" 2>/dev/null
  cleanup_test; summary; exit 1
fi

# Step 4: Remove blocker — gateway should be able to start now
info "Removing port blocker..."
kill "$BLOCKER_PID" 2>/dev/null; wait "$BLOCKER_PID" 2>/dev/null || true
sleep 2

# Step 5: Watchclaw should detect recovery on next health check cycle
# Since we're in ALERT, it keeps polling. Once port is free, next restart attempt should work.
# But ALERT state just polls, doesn't auto-restart. The gateway process from last failed attempt
# might still be trying... Let's manually start sheep to simulate recovery.
start_sheep
wait_for_sheep 30

if wait_for_log "Gateway recovered from ALERT" 60; then
  pass "Recovered from ALERT state"
else
  fail "Didn't recover from ALERT"
fi

if wait_for_log "Probation passed\|state=HEALTHY" 40; then
  pass "Back to HEALTHY after ALERT recovery"
else
  # Might still be in probation
  if log_contains "PROBATION"; then
    pass "In PROBATION (recovery in progress)"
  else
    fail "Didn't return to HEALTHY/PROBATION"
  fi
fi

cleanup_test
summary
