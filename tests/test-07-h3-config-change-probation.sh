#!/usr/bin/env bash
# Test 07: H3 — Config changes while healthy, probation → promote new known-good
# Covers: HEALTHY → config change committed → gateway stays up → promote after probation
source "$(dirname "$0")/helpers.sh"

trap 'cleanup_test; exit 130' INT TERM
echo "═══ Test 07: H3 — Config Change + Probation ═══"
reset_sheep

# Step 1: Bootstrap known-good + start monitoring
ensure_known_good || { summary; exit 1; }

FIRST_GOOD=$(git -C "$SHEEP_DIR" rev-parse known-good)
info "First known-good: $FIRST_GOOD"

start_sheep
wait_for_sheep 30 || { fail "Sheep didn't start"; summary; exit 1; }
> "$TEST_LOG"
start_watchdog
wait_for_log "Known-good anchor exists" 15 || { fail "Watchdog didn't find known-good"; summary; exit 1; }
wait_for_log "Gateway healthy" 15
info "Watchdog monitoring"

# Step 2: Make a valid config change (add a harmless field)
cd "$SHEEP_DIR"
python3 -c "
import json, time
with open('openclaw.json') as f: cfg = json.load(f)
cfg['meta']['lastTouchedVersion'] = 'watchclaw-test-' + str(int(time.time()))
with open('openclaw.json','w') as f: json.dump(cfg, f, indent=2)
"
git add openclaw.json
git commit -m "test: valid config change for H3" --quiet
info "Committed valid config change"

# Step 3: Watchclaw should detect HEAD ≠ known-good and enter probation
if wait_for_log "Config changed while healthy" 30; then
  pass "Detected config change while healthy"
else
  fail "Didn't detect config change"
fi

# Step 4: Wait for probation to complete and promote new known-good
if wait_for_log "Probation passed" 60; then
  pass "Probation passed after config change"
else
  fail "Probation didn't complete"
fi

# Step 5: Check if known-good was updated
NEW_GOOD=$(git -C "$SHEEP_DIR" rev-parse known-good 2>/dev/null)
if [[ -n "$NEW_GOOD" && "$NEW_GOOD" != "$FIRST_GOOD" ]]; then
  pass "Known-good updated: $FIRST_GOOD → $NEW_GOOD"
else
  fail "Known-good not updated (still $FIRST_GOOD)"
fi

cleanup_test
summary
