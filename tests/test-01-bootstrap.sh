#!/usr/bin/env bash
# Test 01: Known-Good Anchoring
# Covers: all anchoring pre-check scenarios at watchclaw startup
source "$(dirname "$0")/helpers.sh"

trap 'cleanup_test_full; exit 130' INT TERM
echo "═══ Test 01: Known-Good Anchoring ═══"
reset_sheep

# ── Scenario A: No known-good + healthy gateway + clean tree → probation → promote ──
info "=== Scenario A: Happy path anchoring ==="
start_sheep
wait_for_sheep 30 || { fail "Sheep didn't start"; summary; exit 1; }

start_watchdog

if wait_for_log "No known-good anchor" 15; then
  pass "Detected missing known-good"
else
  fail "Didn't detect missing known-good"
fi

if wait_for_log "entering probation to anchor" 10; then
  pass "Entered probation for anchoring"
else
  fail "Didn't enter probation"
fi

if wait_for_log "Promoted.*to known-good" 45; then
  pass "Promoted to known-good after probation"
else
  fail "Didn't promote known-good"
fi

if git -C "$SHEEP_DIR" rev-parse "known-good" &>/dev/null; then
  pass "Known-good tag exists: $(git -C "$SHEEP_DIR" rev-parse known-good)"
else
  fail "Known-good tag not created"
fi

stop_watchdog
stop_sheep

# ── Scenario B: No known-good + dirty tree → exit with error ──
info "=== Scenario B: Dirty tree → refuse to anchor ==="
cd "$SHEEP_DIR"
git tag -d known-good 2>/dev/null || true
echo "dirty" >> openclaw.json  # dirty the tree without committing

> "$TEST_LOG"
start_watchdog
if wait_for_log "Dirty working tree.*cannot anchor" 15; then
  pass "Refused to anchor with dirty tree"
else
  fail "Didn't refuse dirty tree"
fi
stop_watchdog

# Restore clean tree
cd "$SHEEP_DIR"
git checkout -- openclaw.json

# ── Scenario C: No known-good + unhealthy gateway + clean tree → exit with error ──
info "=== Scenario C: Unhealthy gateway → refuse to anchor ==="
> "$TEST_LOG"
# Don't start sheep — gateway is down
start_watchdog
if wait_for_log "Gateway not healthy.*cannot anchor" 15; then
  pass "Refused to anchor with unhealthy gateway"
else
  fail "Didn't refuse unhealthy gateway"
fi
stop_watchdog

# ── Scenario D: Known-good already exists → skip anchoring ──
info "=== Scenario D: Known-good exists → skip anchoring ==="
cd "$SHEEP_DIR"
git tag known-good HEAD 2>/dev/null || true
start_sheep
wait_for_sheep 30 || { fail "Sheep didn't start"; summary; exit 1; }

> "$TEST_LOG"
start_watchdog
if wait_for_log "Known-good anchor exists" 15; then
  pass "Recognized existing known-good"
else
  fail "Didn't recognize existing known-good"
fi

if wait_for_log "Gateway healthy" 15; then
  pass "Entered HEALTHY state"
else
  fail "Didn't enter HEALTHY state"
fi

cleanup_test_full
summary
