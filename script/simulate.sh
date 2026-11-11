#!/usr/bin/env bash
# Simulates, in eth_calls on a live node, a claim of a real stake's rewards through its recipient's clone, and checks
# it against the same claim sent by Aero's own route. Nothing is sent. It covers the tokens that Foundry's fork cannot
# run, such as Base's native tokens and Arc's USDC.
#
# usage: script/simulate.sh <rpc-url> <token-id> [max-gauges] [entry-gas]
# Off Base, where any address can be the recipient, RECIPIENT chooses it.
set -euo pipefail
cd "$(dirname "$0")/.."

RPC=${1:?usage: script/simulate.sh <rpc-url> <token-id> [max-gauges] [entry-gas]}
ID=${2:?usage: script/simulate.sh <rpc-url> <token-id> [max-gauges] [entry-gas]}
LIMIT=${3:-0}
ENTRY_GAS=${4:-3000000}

HASHES=verification/bytecode-hashes.json
ARTIFACT=out/Simulation.sol/Simulation.json
forge build > /dev/null
LEAF=$(jq -j .deployment.leafVoter "$HASHES")
ESCROW=$(jq -j .deployment.escrow "$HASHES")
BASE_ID=$(jq -j .deployment.baseChainId "$HASHES")
FEE=$(jq -j .deployment.feeRecipient "$HASHES")
DEP="($LEAF,$ESCROW,$BASE_ID,$FEE)"
DEP_TYPE='(address,address,uint256,address)'
SIM=0x0000000000000000000000000000000000515151
# The slot of LeafVoter's `tokenStates`, whose first word holds the operator in its low 20 bytes.
TOKEN_STATES_SLOT=10

BLOCK=$(cast block-number --rpc-url "$RPC")
CHAIN=$(cast chain-id --rpc-url "$RPC")
if [ "$CHAIN" = "$BASE_ID" ]; then
  RECIPIENT=$(cast call "$ESCROW" 'ownerOf(uint256)(address)' "$ID" --rpc-url "$RPC" --block "$BLOCK")
else
  RECIPIENT=${RECIPIENT:-0x00000000000000000000000000000000000A11cE}
fi

code="$SIM:$(jq -j .deployedBytecode.object "$ARTIFACT")"
if [ "$(cast code "$FEE" --rpc-url "$RPC" --block "$BLOCK")" = 0x ]; then
  echo "the fee Safe is not on chain $CHAIN: a contract that only accepts payments stands in for it"
  code="$code,$FEE:0x00"
fi
call() {
  cast call "$SIM" "$@" --rpc-url "$RPC" --block "$BLOCK" --override-code "$code" --override-nonce "$SIM:1"
}

slot=$(cast index uint256 "$ID" "$TOKEN_STATES_SLOT")
word=$(cast storage "$LEAF" "$slot" --rpc-url "$RPC" --block "$BLOCK")
as_operator() {
  local account
  account=$(echo "${1#0x}" | tr '[:upper:]' '[:lower:]')
  echo "$LEAF:$slot:${word:0:26}$account"
}

operator=$(call "operatorOf($DEP_TYPE,address)(address)" "$DEP" "$RECIPIENT")
seen=$(cast call "$LEAF" 'operator(uint256)(address)' "$ID" --rpc-url "$RPC" --block "$BLOCK" \
  --override-state-diff "$(as_operator "$operator")")
[ "$seen" = "$operator" ] || { echo "LeafVoter does not keep operators in slot $TOKEN_STATES_SLOT" >&2; exit 1; }

echo "chain $CHAIN, block $BLOCK, stake $ID, recipient $RECIPIENT, clone $operator"
direct=$(call "direct(address,uint256,address,uint256)(uint256[])" "$LEAF" "$ID" "$RECIPIENT" "$LIMIT" \
  --override-state-diff "$(as_operator "$SIM")" --json | jq -c '.[0]' | tr -d '"')
echo "Aero's own route pays: $direct"
call "claim($DEP_TYPE,uint256,address,uint256,uint256,uint256[])(uint256,uint256,address[],uint256[])" \
  "$DEP" "$ID" "$RECIPIENT" "$LIMIT" "$ENTRY_GAS" "$direct" --override-state-diff "$(as_operator "$operator")"
echo "the clone paid the same, less the fee, and kept nothing"
