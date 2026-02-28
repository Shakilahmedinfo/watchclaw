#!/usr/bin/env bash
# Test 05: U3 — Config at known-good but gateway still fails (not a config problem)
# Covers: detect unhealthy → at known-good → can't fix → retry → ALERT
source "$(dirname "$0")/helpers.sh"

trap 'cleanup_test; exit 130' INT TERM
echo "═══ Test 05: U3 — Known-Good Still Fails → ALERT ═══"
reset_sheep

# Step 1: Bootstrap + get known-good
start_sheep
wait_for_sheep 30 || { fail "Sheep didn't start"; summary; exit 1; }
ensure_known_good

GOOD_HASH=$(git -C "$SHEEP_DIR" rev-parse known-good)
info "Known-good: $GOOD_HASH"

# Step 2: Stop everything, block the port (simulate non-config failure)
# Keep known-good tag — only stop processes
stop_watchdog
stop_sheep
sleep 1

# Occupy port 18851 with a dummy listener so gateway can't bind
# This simulates a non-config error (port conflict)
node -e "
const net = require('net');
const s = net.createServer();
s.listen($SHEEP_PORT, '127.0.0.1');
setTimeout(() => {}, 300000);
" &
BLOCKER_PID=$!
sleep 1
info "Port blocker running (PID $BLOCKER_PID)"

# Step 3: Start watchclaw — config is good but gateway can't start (port taken)
start_watchdog

# Step 4: Should detect unhealthy, fail restarts, eventually ALERT
if wait_for_log "Gateway unhealthy" 30; then
  pass "Detected unhealthy"
else
  fail "Didn't detect unhealthy"
fi

# Should NOT do U1 or U2 (config is fine)
sleep 10
if log_contains "U1:" || log_contains "U2:"; then
  fail "Incorrectly tried config recovery (U1/U2) for non-config error"
else
  pass "Correctly skipped config recovery"
fi

# Should eventually enter ALERT after retries
if wait_for_log "ALERT.*Gateway down after" 180; then
  pass "Entered ALERT state after exhausting retries"
elif log_contains "DRY-RUN.*Would send"; then
  pass "Alert triggered (dry-run)"
else
  fail "Didn't reach ALERT state (check log — may need more time)"
fi

# Cleanup blocker
kill "$BLOCKER_PID" 2>/dev/null; wait "$BLOCKER_PID" 2>/dev/null || true

cleanup_test
summary
