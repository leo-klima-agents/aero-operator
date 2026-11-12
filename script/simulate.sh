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
GAS_RULE_GAUGES=1
EVERY_ENTRY=false
FEES_ONLY=true
STARVING_ENTRY_GAS=10000
ALL_ENTRIES_IN_ONE_CALL=1000000
AMPLE_GAS=30000000
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
  local max_gauges=$1 fees_only=$2
  simulate 'claimAsOperator(address,uint256,address,uint256,bool)(uint256[])' \
    "$LEAF_VOTER" "$ID" "$RECIPIENT" "$max_gauges" "$fees_only" \
    --override-state-diff "$(with_operator "$SIMULATION")" --json | jq -c '.[0]' | tr -d '"'
}
claim_through_clone() {
  local max_gauges=$1 fees_only=$2 entry_gas=$3 entries_per_call=$4 gas_per_call=$5 paid_by_aero=$6
  simulate "claimThroughClone($DEPLOYMENT_TYPE,uint256,address,uint256,bool,uint256,uint256,uint256,uint256[])(uint8,uint256,uint256,uint256,uint256)" \
    "$DEPLOYMENT" "$ID" "$RECIPIENT" "$max_gauges" "$fees_only" "$entry_gas" "$entries_per_call" "$gas_per_call" \
    "$paid_by_aero" \
    --override-state-diff "$(with_operator "$clone")" --json
}

echo "chain $CHAIN_ID, block $BLOCK, stake $ID, recipient $RECIPIENT, clone $clone"
nothing_in() {
  [ -z "$(tr -d '[],0' <<<"$1")" ]
}
paid=$(paid_by_aero "$MAX_GAUGES" "$EVERY_ENTRY")
echo "Aero's own route pays: $paid"
if nothing_in "$paid"; then
  echo "the stake has nothing to claim" >&2
  exit 1
fi
result=$(claim_through_clone "$MAX_GAUGES" "$EVERY_ENTRY" "$ENTRY_GAS" "$ENTRIES_PER_CALL" "$MAX_TRANSACTION_GAS" \
  "$paid")
[ "$(jq -j '.[0]' <<<"$result")" = "$OUTCOME_PAID_IN_FULL" ] || {
  echo "the clone did not pay the same: $result" >&2
  exit 1
}
echo "the clone paid the same, less the fee, and kept nothing: $(jq -j '.[1]' <<<"$result") entries in" \
  "$(jq -j '.[2]' <<<"$result") calls of up to $ENTRIES_PER_CALL, the heaviest using $(jq -j '.[3]' <<<"$result") gas"
unread_programs=$(jq -j '.[4]' <<<"$result")
[ "$unread_programs" = 0 ] ||
  echo "warning: $unread_programs incentive programs were too old to read or could not be estimated"

[ "$(simulate 'passesOnAllButOne64thOfItsGas()(bool)')" = true ] || {
  echo "a call on this chain does not pass on all but one 64th of its gas" >&2
  exit 1
}
fees_of_one_gauge=$(paid_by_aero "$GAS_RULE_GAUGES" "$FEES_ONLY")
if nothing_in "$fees_of_one_gauge"; then
  echo "the first gauge owes no fees: the gas rules are not checked" >&2
  exit 1
fi
outcome_with() {
  local entry_gas=$1 gas=$2
  claim_through_clone "$GAS_RULE_GAUGES" "$FEES_ONLY" "$entry_gas" "$ALL_ENTRIES_IN_ONE_CALL" "$gas" \
    "$fees_of_one_gauge" | jq -j '.[0]'
}
[ "$(outcome_with "$STARVING_ENTRY_GAS" "$AMPLE_GAS")" = "$OUTCOME_PAID_NOTHING" ] || {
  echo "a starved entry did not fail alone" >&2
  exit 1
}
[ "$(outcome_with "$ENTRY_GAS" "$AMPLE_GAS")" = "$OUTCOME_PAID_IN_FULL" ] || {
  echo "the first gauge's fee entry needs more than $ENTRY_GAS gas" >&2
  exit 1
}

too_little_entry_gas=$STARVING_ENTRY_GAS
least_entry_gas=$ENTRY_GAS
while [ $((least_entry_gas - too_little_entry_gas)) -gt 1 ]; do
  halfway=$(((too_little_entry_gas + least_entry_gas) / 2))
  if [ "$(outcome_with "$halfway" "$AMPLE_GAS")" = "$OUTCOME_PAID_IN_FULL" ]; then
    least_entry_gas=$halfway
  else
    too_little_entry_gas=$halfway
  fi
done

reverts_with=0
least_gas=$AMPLE_GAS
while [ $((least_gas - reverts_with)) -gt 1 ]; do
  halfway=$(((reverts_with + least_gas) / 2))
  outcome=$(outcome_with "$least_entry_gas" "$halfway")
  if [ "$outcome" = "$OUTCOME_REVERTED" ]; then
    reverts_with=$halfway
  elif [ "$outcome" = "$OUTCOME_PAID_IN_FULL" ]; then
    least_gas=$halfway
  else
    echo "with $halfway gas the claim went through without paying in full" >&2
    exit 1
  fi
done
echo "gas rules: a call passes on all but one 64th of its gas; a fee entry given $STARVING_ENTRY_GAS gas fails" \
  "alone; given the $least_entry_gas it needs, its claim reverts below $least_gas gas and pays in full from there"
