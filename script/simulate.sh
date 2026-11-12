#!/usr/bin/env bash
# Simulates, in eth_calls on a live node, claims of a real stake's rewards through its recipient's clone, and checks
# them against the same claim sent by Aero's own route. Nothing is sent. It covers what Foundry's fork cannot run:
# tokens that live in the node, such as Base's native tokens and Arc's USDC, and the node's own gas rules.
#
# usage: script/simulate.sh <rpc-url> <token-id> [max-gauges] [entry-gas] [entries-per-call]
# Off Base, where any address can be the recipient, RECIPIENT chooses it.
set -euo pipefail
cd "$(dirname "$0")/.."

USAGE='usage: script/simulate.sh <rpc-url> <token-id> [max-gauges] [entry-gas] [entries-per-call]'
RPC=${1:?$USAGE}
ID=${2:?$USAGE}
LIMIT=${3:-0}
ENTRY_GAS=${4:-1000000}
CHUNK=${5:-12}
# How many gauges the gas rules are tried on, and the gas that is too little for any entry.
FEW=2
STARVED=10000

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

# What Aero's own route pays for the stake's first gauges, all of them if the number is 0.
direct() {
  call 'direct(address,uint256,address,uint256)(uint256[])' "$LEAF" "$ID" "$RECIPIENT" "$1" \
    --override-state-diff "$(as_operator "$SIM")" --json | jq -c '.[0]' | tr -d '"'
}

echo "chain $CHAIN, block $BLOCK, stake $ID, recipient $RECIPIENT, clone $operator"
expected=$(direct "$LIMIT")
echo "Aero's own route pays: $expected"
result=$(call "claim($DEP_TYPE,uint256,address,uint256,uint256,uint256,uint256[])(uint256,uint256,uint256,uint256,uint256[])" \
  "$DEP" "$ID" "$RECIPIENT" "$LIMIT" "$ENTRY_GAS" "$CHUNK" "$expected" \
  --override-state-diff "$(as_operator "$operator")" --json)
echo "the clone paid the same, less the fee, and kept nothing: $(jq -j '.[0]' <<<"$result") entries in" \
  "$(jq -j '.[1]' <<<"$result") calls of up to $CHUNK, the heaviest using $(jq -j '.[2]' <<<"$result") gas"
unread=$(jq -j '.[3]' <<<"$result")
[ "$unread" = 0 ] || echo "warning: $unread incentive programs were too old to read or could not be estimated"

# The node's gas rules, on the first gauges: an entry without enough gas fails alone, and the claim either reverts or
# pays in full, whatever gas it is sent with.
few=$(direct "$FEW")
attempt() {
  call "attempt($DEP_TYPE,uint256,address,uint256,uint256,uint256,uint256[])(uint8)" \
    "$DEP" "$ID" "$RECIPIENT" "$FEW" "$1" "$2" "$few" --override-state-diff "$(as_operator "$operator")"
}
[ "$(attempt "$STARVED" 5000000)" = 3 ] || { echo "entries given too little gas did not all fail alone" >&2; exit 1; }
low=0
high=$ENTRY_GAS
while outcome=$(attempt "$ENTRY_GAS" "$high"); [ "$outcome" = 0 ]; do
  low=$high
  high=$((high * 2))
  [ "$high" -le 64000000 ] || { echo "the claim reverts even with $low gas" >&2; exit 1; }
done
while [ "$outcome" = 1 ] && [ $((high - low)) -gt 1000 ]; do
  middle=$(((low + high) / 2))
  outcome=$(attempt "$ENTRY_GAS" "$middle")
  if [ "$outcome" = 0 ]; then
    low=$middle
    outcome=1
  else
    high=$middle
  fi
done
[ "$outcome" = 1 ] || { echo "with $high gas the claim went through without paying in full" >&2; exit 1; }
echo "gas rules: entries given $STARVED gas fail alone; a claim of $FEW gauges reverts below about $high gas and" \
  "pays in full from there"
