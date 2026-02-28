#!/usr/bin/env bash
# Test 02: Transient crash — kill gateway, watchclaw restarts it
# Covers: simple restart → PROBATION → HEALTHY
source "$(dirname "$0")/helpers.sh"

trap 'cleanup_test; exit 130' INT TERM
echo "═══ Test 02: Transient Crash Recovery ═══"
reset_sheep

# Step 1: Bootstrap known-good + start monitoring
ensure_known_good || { summary; exit 1; }
start_sheep
wait_for_sheep 30 || { fail "Sheep didn't start"; summary; exit 1; }
> "$TEST_LOG"
start_watchdog
wait_for_log "Known-good anchor exists" 15 || { fail "Watchdog didn't find known-good"; summary; exit 1; }
wait_for_log "Gateway healthy" 15
info "Watchdog monitoring"

# Step 2: Kill sheep (simulates transient crash)
info "Killing sheep to simulate transient crash..."
stop_sheep
sleep 2

# Step 3: Watchdog should detect unhealthy and restart
if wait_for_log "Gateway unhealthy" 30; then
  pass "Detected unhealthy"
else
  fail "Didn't detect unhealthy"
fi

if wait_for_log "Recovered with simple restart" 60; then
  pass "Recovered via simple restart"
else
  # Might say "Retry succeeded"
  if log_contains "Retry succeeded"; then
    pass "Recovered via retry"
  else
    fail "Didn't recover"
  fi
fi

# Step 4: Should enter probation
if wait_for_log "PROBATION" 10; then
  pass "Entered PROBATION"
else
  fail "Didn't enter PROBATION"
fi

# Step 5: After probation (20s in test config), should promote
if wait_for_log "Probation passed" 40; then
  pass "Probation passed → HEALTHY"
else
  fail "Probation didn't complete"
fi

# Step 6: Verify sheep is actually healthy
if sheep_healthy; then
  pass "Sheep is healthy"
else
  fail "Sheep not healthy after recovery"
fi

cleanup_test
summary
