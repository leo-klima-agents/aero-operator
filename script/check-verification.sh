#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

HASHES=verification/bytecode-hashes.json
CONTRACTS=(ImmutableClaimOperatorFactory ImmutableClaimOperator)
[ -f "$HASHES" ] || { echo "::error::$HASHES missing; run script/refresh-verification.sh" >&2; exit 1; }
for name in "${CONTRACTS[@]}"; do
  [ -f "out/$name.sol/$name.json" ] || { echo "::error::out/$name.sol/$name.json missing; run forge build" >&2; exit 1; }
  [ -f "verification/$name.standard-input.json" ] || { echo "::error::verification/$name.standard-input.json missing; run script/refresh-verification.sh" >&2; exit 1; }
done
status=0

expect() {
  local recorded
  recorded=$(jq -j "$1 // \"\"" "$HASHES")
  if [ "$recorded" != "$2" ]; then
    echo "::error::$1: recorded '$recorded', built '$2'" >&2
    status=1
  else
    echo "$1 ok"
  fi
}

creation=$(jq -j '.bytecode.object' out/ImmutableClaimOperatorFactory.sol/ImmutableClaimOperatorFactory.json)
expect .factoryCreationCodeKeccak "$(cast keccak "$creation")"
expect .implementationCreationCodeKeccak "$(cast keccak "$(jq -j '.bytecode.object' out/ImmutableClaimOperator.sol/ImmutableClaimOperator.json)")"
expect .solc "$(jq -j '.metadata.compiler.version' out/ImmutableClaimOperatorFactory.sol/ImmutableClaimOperatorFactory.json)"
expect .salt "$(cast keccak "$(jq -j .saltPreimage "$HASHES")")"

args=$(cast abi-encode 'constructor(address,address,uint256,address)' \
  "$(jq -j .deployment.leafVoter "$HASHES")" "$(jq -j .deployment.escrow "$HASHES")" \
  "$(jq -j .deployment.baseChainId "$HASHES")" "$(jq -j .deployment.feeRecipient "$HASHES")")
expect .deployment.constructorArgs "$args"
factory=$(cast create2 --deployer "$(jq -j .create2Deployer "$HASHES")" --salt "$(jq -j .salt "$HASHES")" --init-code "${creation}${args#0x}" | grep -oE '0x[0-9a-fA-F]{40}' | head -n1)
expect .deployment.factory "$factory"
expect .deployment.implementation "$(cast compute-address "$factory" --nonce 1 | grep -oE '0x[0-9a-fA-F]{40}' | head -n1)"

projection='del(.settings.outputSelection)'
for name in "${CONTRACTS[@]}"; do
  input="verification/$name.standard-input.json"
  current=$(forge verify-contract --show-standard-json-input 0x0000000000000000000000000000000000000001 "src/$name.sol:$name" | jq -S "$projection")
  if [ "$current" != "$(jq -S "$projection" "$input")" ]; then
    echo "::error::$input is stale" >&2
    status=1
  else
    echo "$input ok"
  fi
done

for key in factory implementation; do
  address=$(jq -j ".deployment.$key" "$HASHES")
  if grep -qF "\`$address\`" README.md; then
    echo "README.md $key address ok"
  else
    echo "::error::README.md does not show $address" >&2
    status=1
  fi
done

exit $status
