#!/usr/bin/env bash
# Run all watchclaw tests sequentially
set -uo pipefail
cd "$(dirname "$0")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
TOTAL=0; PASSED=0; FAILED=0

for test in test-*.sh; do
  echo ""
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${YELLOW}Running: $test${NC}"
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  TOTAL=$((TOTAL + 1))
  if bash "$test"; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    echo -e "${RED}^^^ FAILED ^^^${NC}"
    echo ""
    echo "Continue? (y/n)"
    read -r answer
    [[ "$answer" != "y" ]] && break
  fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "Results: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}, $TOTAL total"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
