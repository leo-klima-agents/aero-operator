#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ARTIFACT=out/ImmutableClaimOperatorFactory.sol/ImmutableClaimOperatorFactory.json
HASHES=verification/bytecode-hashes.json
INPUT=verification/ImmutableClaimOperatorFactory.standard-input.json
[ -f "$ARTIFACT" ] || { echo "::error::$ARTIFACT missing; run forge build" >&2; exit 1; }
[ -f "$HASHES" ] || { echo "::error::$HASHES missing; run script/refresh-verification.sh" >&2; exit 1; }
[ -f "$INPUT" ] || { echo "::error::$INPUT missing; run script/refresh-verification.sh" >&2; exit 1; }
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

creation=$(jq -j '.bytecode.object' "$ARTIFACT")
expect .creationCodeKeccak "$(cast keccak "$creation")"
expect .solc "$(jq -j '.metadata.compiler.version' "$ARTIFACT")"
expect .salt "$(cast keccak "$(jq -j .saltPreimage "$HASHES")")"

args=$(cast abi-encode 'constructor(address,address,uint256)' \
  "$(jq -j .deployment.leafVoter "$HASHES")" "$(jq -j .deployment.escrow "$HASHES")" \
  "$(jq -j .deployment.baseChainId "$HASHES")")
expect .deployment.constructorArgs "$args"
factory=$(cast compute-address "$(jq -j .create2Deployer "$HASHES")" --salt "$(jq -j .salt "$HASHES")" --init-code "${creation}${args#0x}")
expect .deployment.factory "$factory"
expect .deployment.implementation "$(cast compute-address "$factory" --nonce 1)"

projection='del(.settings.outputSelection)'
current=$(forge verify-contract --show-standard-json-input 0x0000000000000000000000000000000000000001 src/ImmutableClaimOperatorFactory.sol:ImmutableClaimOperatorFactory | jq -S "$projection")
if [ "$current" != "$(jq -S "$projection" "$INPUT")" ]; then
  echo "::error::$INPUT is stale" >&2
  status=1
else
  echo "$INPUT ok"
fi

for key in .deployment.factory .deployment.implementation .deployment.leafVoter .deployment.escrow \
  .deployment.treasury .create2Deployer .saltPreimage; do
  value=$(jq -j "$key" "$HASHES")
  if grep -qF "$value" README.md; then
    echo "README.md $key ok"
  else
    echo "::error::README.md does not show $value" >&2
    status=1
  fi
done

exit $status
