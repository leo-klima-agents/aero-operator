#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

USAGE='usage: [RECIPIENT=<address off Base>] script/simulate.sh <rpc-url> <token-id> [max-gauges] [entry-gas] [entries-per-call]'
RPC=${1:?$USAGE}
ID=${2:?$USAGE}
MAX_GAUGES=${3:-0}
ENTRY_GAS=${4:-1000000}
ENTRIES_PER_CALL=${5:-12}
MAX_TRANSACTION_GAS=16777216
GAS_RULE_GAUGES=2
STARVING_ENTRY_GAS=10000
ALL_ENTRIES_IN_ONE_CALL=1000000
OUTCOME_REVERTED=0
OUTCOME_PAID_IN_FULL=1
OUTCOME_PAID_NOTHING=3

HASHES=verification/bytecode-hashes.json
ARTIFACT=out/Simulation.sol/Simulation.json
forge build > /dev/null
LEAF_VOTER=$(jq -j .deployment.leafVoter "$HASHES")
ESCROW=$(jq -j .deployment.escrow "$HASHES")
BASE_CHAIN_ID=$(jq -j .deployment.baseChainId "$HASHES")
FEE_SAFE=$(jq -j .deployment.feeRecipient "$HASHES")
DEPLOYMENT="($LEAF_VOTER,$ESCROW,$BASE_CHAIN_ID,$FEE_SAFE)"
DEPLOYMENT_TYPE='(address,address,uint256,address)'
SIMULATION=0x0000000000000000000000000000000000515151
LEAF_VOTER_TOKEN_STATES_SLOT=10

BLOCK=$(cast block-number --rpc-url "$RPC")
CHAIN_ID=$(cast chain-id --rpc-url "$RPC")
if [ "$CHAIN_ID" = "$BASE_CHAIN_ID" ]; then
  RECIPIENT=$(cast call "$ESCROW" 'ownerOf(uint256)(address)' "$ID" --rpc-url "$RPC" --block "$BLOCK")
else
  RECIPIENT=${RECIPIENT:-0x00000000000000000000000000000000000A11cE}
fi

code_overrides="$SIMULATION:$(jq -j .deployedBytecode.object "$ARTIFACT")"
if [ "$(cast code "$FEE_SAFE" --rpc-url "$RPC" --block "$BLOCK")" = 0x ]; then
  echo "the fee Safe is not on chain $CHAIN_ID: a contract that only accepts payments stands in for it"
  accepts_payments=0x00
  code_overrides="$code_overrides,$FEE_SAFE:$accepts_payments"
fi
simulate() {
  cast call "$SIMULATION" "$@" --rpc-url "$RPC" --block "$BLOCK" \
    --override-code "$code_overrides" --override-nonce "$SIMULATION:1"
}

operator_slot=$(cast index uint256 "$ID" "$LEAF_VOTER_TOKEN_STATES_SLOT")
operator_word=$(cast storage "$LEAF_VOTER" "$operator_slot" --rpc-url "$RPC" --block "$BLOCK")
with_operator() {
  local operator fields_above_the_operator=${operator_word:0:26}
  operator=$(echo "${1#0x}" | tr '[:upper:]' '[:lower:]')
  echo "$LEAF_VOTER:$operator_slot:$fields_above_the_operator$operator"
}

clone=$(simulate "operatorOf($DEPLOYMENT_TYPE,address)(address)" "$DEPLOYMENT" "$RECIPIENT")
operator_read_back=$(cast call "$LEAF_VOTER" 'operator(uint256)(address)' "$ID" --rpc-url "$RPC" --block "$BLOCK" \
  --override-state-diff "$(with_operator "$clone")")
[ "$operator_read_back" = "$clone" ] || {
  echo "LeafVoter does not keep operators in slot $LEAF_VOTER_TOKEN_STATES_SLOT" >&2
  exit 1
}

paid_by_aero() {
  local max_gauges=$1
  simulate 'claimAsOperator(address,uint256,address,uint256)(uint256[])' \
    "$LEAF_VOTER" "$ID" "$RECIPIENT" "$max_gauges" \
    --override-state-diff "$(with_operator "$SIMULATION")" --json | jq -c '.[0]' | tr -d '"'
}
claim_through_clone() {
  local max_gauges=$1 entry_gas=$2 entries_per_call=$3 gas_per_call=$4 paid_by_aero=$5
  simulate "claimThroughClone($DEPLOYMENT_TYPE,uint256,address,uint256,uint256,uint256,uint256,uint256[])(uint8,uint256,uint256,uint256,uint256)" \
    "$DEPLOYMENT" "$ID" "$RECIPIENT" "$max_gauges" "$entry_gas" "$entries_per_call" "$gas_per_call" "$paid_by_aero" \
    --override-state-diff "$(with_operator "$clone")" --json
}

echo "chain $CHAIN_ID, block $BLOCK, stake $ID, recipient $RECIPIENT, clone $clone"
paid=$(paid_by_aero "$MAX_GAUGES")
echo "Aero's own route pays: $paid"
result=$(claim_through_clone "$MAX_GAUGES" "$ENTRY_GAS" "$ENTRIES_PER_CALL" "$MAX_TRANSACTION_GAS" "$paid")
[ "$(jq -j '.[0]' <<<"$result")" = "$OUTCOME_PAID_IN_FULL" ] || {
  echo "the clone did not pay the same: $result" >&2
  exit 1
}
echo "the clone paid the same, less the fee, and kept nothing: $(jq -j '.[1]' <<<"$result") entries in" \
  "$(jq -j '.[2]' <<<"$result") calls of up to $ENTRIES_PER_CALL, the heaviest using $(jq -j '.[3]' <<<"$result") gas"
unread_programs=$(jq -j '.[4]' <<<"$result")
[ "$unread_programs" = 0 ] ||
  echo "warning: $unread_programs incentive programs were too old to read or could not be estimated"

paid_for_few=$(paid_by_aero "$GAS_RULE_GAUGES")
outcome_with() {
  local entry_gas=$1 gas=$2
  claim_through_clone "$GAS_RULE_GAUGES" "$entry_gas" "$ALL_ENTRIES_IN_ONE_CALL" "$gas" "$paid_for_few" |
    jq -j '.[0]'
}
[ "$(outcome_with "$STARVING_ENTRY_GAS" 5000000)" = "$OUTCOME_PAID_NOTHING" ] || {
  echo "starved entries did not all fail alone" >&2
  exit 1
}
reverts_with=0
goes_through_with=$ENTRY_GAS
while outcome=$(outcome_with "$ENTRY_GAS" "$goes_through_with"); [ "$outcome" = "$OUTCOME_REVERTED" ]; do
  reverts_with=$goes_through_with
  goes_through_with=$((goes_through_with * 2))
  [ "$goes_through_with" -le 64000000 ] || { echo "the claim reverts even with $reverts_with gas" >&2; exit 1; }
done
while [ "$outcome" = "$OUTCOME_PAID_IN_FULL" ] && [ $((goes_through_with - reverts_with)) -gt 1000 ]; do
  halfway=$(((reverts_with + goes_through_with) / 2))
  outcome=$(outcome_with "$ENTRY_GAS" "$halfway")
  if [ "$outcome" = "$OUTCOME_REVERTED" ]; then
    reverts_with=$halfway
    outcome=$OUTCOME_PAID_IN_FULL
  else
    goes_through_with=$halfway
  fi
done
[ "$outcome" = "$OUTCOME_PAID_IN_FULL" ] || {
  echo "with $goes_through_with gas the claim went through without paying in full" >&2
  exit 1
}
echo "gas rules: entries given $STARVING_ENTRY_GAS gas fail alone; a claim of $GAS_RULE_GAUGES gauges reverts below" \
  "about $goes_through_with gas and pays in full from there"
