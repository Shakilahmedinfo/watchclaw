#!/usr/bin/env bash
# Test 03: U1 — Dirty working tree with broken config
# Covers: detect unhealthy → dirty tree → stash → restart → recover
# Also tests: alert on config error detection + alert on recovery
source "$(dirname "$0")/helpers.sh"

trap 'cleanup_test; exit 130' INT TERM
echo "═══ Test 03: U1 — Dirty Tree Config Error ═══"
reset_sheep

# Step 1: Bootstrap known-good
ensure_known_good || { summary; exit 1; }
GOOD_HASH=$(git -C "$SHEEP_DIR" rev-parse known-good)
info "Known-good: $GOOD_HASH"

# Step 2: Break config (dirty), start watchclaw
sleep 1

# Break config WITHOUT committing (dirty tree)
break_config_dirty

# Verify it's dirty
cd "$SHEEP_DIR"
if ! git diff --quiet; then
  pass "Working tree is dirty"
else
  fail "Working tree should be dirty"
fi

# Step 3: Set up alert capture via temp config with command hook
ALERT_LOG="/tmp/watchclaw-test-alerts.log"
> "$ALERT_LOG"
ALERT_CONF="/tmp/watchclaw-test-alert.conf"
# Source base config then override alert settings
{
  cat "$TEST_CONF"
  echo ""
  echo "ALERT_HOOK=\"command\""
  echo "DRY_RUN=0"
  echo "ALERT_COMMAND=\"echo \\\"\\\$1\\\" >> $ALERT_LOG\""
} > "$ALERT_CONF"

# Step 4: Start watchclaw with alert-enabled config
info "Starting watchclaw with broken dirty config..."
rm -f "/tmp/watchclaw-${SHEEP_PORT}.pid"
> "$TEST_LOG"
bash "$WATCHCLAW" "$ALERT_CONF" &
WATCHDOG_PID=$!
info "Watchclaw started (PID $WATCHDOG_PID)"

# Step 5: Should detect unhealthy
if wait_for_log "Gateway unhealthy" 30; then
  pass "Detected unhealthy"
else
  fail "Didn't detect unhealthy"
fi

# Step 6: First restart will fail (bad config), then should detect config error + stash
if wait_for_log "U1: Stashed dirty tree" 90; then
  pass "U1: Stashed dirty changes"
else
  if log_contains "Recovered with simple restart"; then
    fail "Recovered without stash — config wasn't actually broken?"
  else
    fail "Didn't stash dirty tree (check watchclaw-test.log)"
  fi
fi

# Step 7: Check alert was sent for config error detection
sleep 2
if grep -q "config error detected" "$ALERT_LOG" 2>/dev/null; then
  pass "Alert sent: config error detected"
else
  fail "No alert for config error detection"
fi

# Step 8: After stash, config should be good again, gateway should recover
if wait_for_log "Retry succeeded" 90; then
  pass "Gateway recovered after stash"
elif log_contains "Recovered with simple restart"; then
  pass "Gateway recovered after stash (simple restart)"
else
  fail "Gateway didn't recover after stash"
fi

# Step 9: Wait for probation to pass and check recovery alert
if wait_for_log "Probation passed" 60; then
  pass "Probation passed"
else
  fail "Probation didn't pass"
fi

sleep 2
if grep -q "recovered and stable" "$ALERT_LOG" 2>/dev/null; then
  pass "Alert sent: gateway recovered"
else
  fail "No alert for gateway recovery"
fi

# Step 10: Verify git stash exists
cd "$SHEEP_DIR"
STASH_COUNT=$(git stash list | grep -c "watchclaw-" || echo 0)
if (( STASH_COUNT > 0 )); then
  pass "Git stash exists ($STASH_COUNT watchclaw stashes)"
else
  fail "No watchclaw stash found"
fi

# Step 11: Verify sheep is healthy
if wait_for_sheep 10; then
  pass "Sheep is healthy"
else
  fail "Sheep not healthy"
fi

# Show captured alerts
info "Captured alerts:"
cat "$ALERT_LOG" 2>/dev/null | while read -r line; do info "  → $line"; done
rm -f "$ALERT_LOG" "$ALERT_CONF"

cleanup_test
summary
