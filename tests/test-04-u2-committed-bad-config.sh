#!/usr/bin/env bash
# Test 04: U2 — Clean tree, committed bad config, known-good exists
# Covers: detect config error → tag broken → revert to known-good → restart
source "$(dirname "$0")/helpers.sh"

trap 'cleanup_test; exit 130' INT TERM

echo "═══ Test 04: U2 — Committed Bad Config ═══"
reset_sheep

# Step 1: Bootstrap (reuse existing known-good if present)
start_sheep
wait_for_sheep 30 || { fail "Sheep didn't start"; summary; exit 1; }
ensure_known_good

GOOD_HASH=$(git -C "$SHEEP_DIR" rev-parse known-good)
info "Known-good: $GOOD_HASH"

# Step 2: Stop everything, commit bad config
stop_watchdog
stop_sheep
sleep 1

break_config  # commits bad JSON

# Verify clean tree with different HEAD
cd "$SHEEP_DIR"
NEW_HASH=$(git rev-parse HEAD)
if git diff --quiet && [[ "$NEW_HASH" != "$GOOD_HASH" ]]; then
  pass "Clean tree, HEAD ($NEW_HASH) ≠ known-good ($GOOD_HASH)"
else
  fail "Setup wrong: dirty=$(! git diff --quiet && echo yes || echo no) same_hash=$([[ "$NEW_HASH" == "$GOOD_HASH" ]] && echo yes || echo no)"
fi

# Step 3: Start watchclaw
info "Starting watchclaw with committed broken config..."
start_watchdog

# Step 4: Should detect unhealthy + config error + U2 revert
if wait_for_log "Gateway unhealthy" 30; then
  pass "Detected unhealthy"
else
  fail "Didn't detect unhealthy"
fi

if wait_for_log "U2: Tagged.*as broken" 90; then
  pass "U2: Tagged broken commit"
else
  if log_contains "Recovered with simple restart"; then
    fail "Recovered without revert — bad config somehow worked?"
  else
    fail "Didn't tag broken commit (check log)"
  fi
fi

# Step 5: Should revert and recover
if wait_for_log "Retry succeeded" 90; then
  pass "Gateway recovered after revert"
elif log_contains "Recovered"; then
  pass "Gateway recovered after revert"
else
  fail "Gateway didn't recover"
fi

# Step 6: Verify broken tag exists
cd "$SHEEP_DIR"
BROKEN_TAGS=$(git tag -l "broken-*" | wc -l | tr -d ' ')
if (( BROKEN_TAGS > 0 )); then
  pass "Broken tag(s) exist: $(git tag -l 'broken-*' | tr '\n' ' ')"
else
  fail "No broken tags"
fi

# Step 7: Config should now be valid JSON
if node -e "JSON.parse(require('fs').readFileSync('$SHEEP_DIR/openclaw.json','utf8'))" 2>/dev/null; then
  pass "Config is valid JSON after revert"
else
  fail "Config still broken after revert"
fi

# Step 8: Sheep healthy
if wait_for_sheep 10; then
  pass "Sheep is healthy"
else
  fail "Sheep not healthy"
fi

cleanup_test
summary
