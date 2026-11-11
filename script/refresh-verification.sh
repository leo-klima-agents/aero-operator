#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

forge build
forge script script/Hashes.s.sol --sig 'record()'
for name in ImmutableClaimOperatorFactory ImmutableClaimOperator; do
  forge verify-contract --show-standard-json-input 0x0000000000000000000000000000000000000001 \
    "src/$name.sol:$name" > "verification/$name.standard-input.json"
done
./script/check-verification.sh
