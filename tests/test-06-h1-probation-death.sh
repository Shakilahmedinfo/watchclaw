#!/usr/bin/env bash
# Test 06: H1 — Gateway dies during probation
# Covers: healthy → probation → dies → re-enter RESTARTING → retry
source "$(dirname "$0")/helpers.sh"

trap 'cleanup_test; exit 130' INT TERM
echo "═══ Test 06: H1 — Dies During Probation ═══"
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

# Step 2: Kill sheep, let watchclaw recover it (enters PROBATION)
stop_sheep
sleep 2

if wait_for_log "PROBATION\|Recovered with simple restart\|Retry succeeded" 60; then
  pass "Watchdog recovered sheep and entered PROBATION"
else
  fail "Didn't enter PROBATION after restart"
  stop_watchdog; summary; exit 1
fi

# Step 3: Kill sheep AGAIN during probation (before 20s passes)
info "Killing sheep during probation..."
sleep 3  # well within 20s probation
stop_sheep
sleep 2

# Step 4: Should detect H1
if wait_for_log "H1: Gateway died during probation" 30; then
  pass "Detected H1: died during probation"
else
  fail "Didn't detect H1"
fi

# Step 5: Should retry and eventually recover
if wait_for_log "Probation passed\|HEALTHY" 90; then
  pass "Eventually recovered to HEALTHY"
elif wait_for_sheep 30; then
  pass "Sheep is back up"
else
  fail "Didn't recover after probation death"
fi

cleanup_test
summary
