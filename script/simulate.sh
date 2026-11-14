#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

USAGE='usage: [RECIPIENT=<address off Base>] script/simulate.sh <rpc-url> <token-id> [max-gauges] [entry-gas] [entries-per-call]'
export ETH_RPC_URL=${1:?$USAGE}
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
forge build > /dev/null
record() {
  jq -j "$1" "$HASHES"
}
fail() {
  echo "$1" >&2
  exit 1
}
LEAF_VOTER=$(record .deployment.leafVoter)
ESCROW=$(record .deployment.escrow)
BASE_CHAIN_ID=$(record .deployment.baseChainId)
TREASURY=$(record .deployment.treasury)
FACTORY=$(record .deployment.factory)
IMPLEMENTATION=$(record .deployment.implementation)
SIMULATION=0x0000000000000000000000000000000000515151
LEAF_VOTER_TOKEN_STATES_SLOT=10

BLOCK=$(cast block-number)
CHAIN_ID=$(cast chain-id)
if [ "$CHAIN_ID" = "$BASE_CHAIN_ID" ]; then
  RECIPIENT=$(cast call "$ESCROW" 'ownerOf(uint256)(address)' "$ID" --block "$BLOCK")
else
  RECIPIENT=${RECIPIENT:-0x00000000000000000000000000000000000A11cE}
fi

code_overrides="$SIMULATION:$(jq -j .deployedBytecode.object out/Simulation.sol/Simulation.json)"
treasury_code=$(cast code "$TREASURY" --block "$BLOCK")
if [ "$treasury_code" = 0x ]; then
  echo "the treasury is not on chain $CHAIN_ID: a contract that only accepts payments stands in for it"
  accepts_payments=0x00
  code_overrides="$code_overrides,$TREASURY:$accepts_payments"
fi
call() {
  cast call "$@" --block "$BLOCK" --override-code "$code_overrides"
}
simulate() {
  call "$SIMULATION" "$@"
}

salt_and_init_code=$(cast concat-hex "$(record .salt)" \
  "$(jq -j .bytecode.object out/ImmutableClaimOperatorFactory.sol/ImmutableClaimOperatorFactory.json)" \
  "$(record .deployment.constructorArgs)")
built=$(simulate 'build(address,bytes,address,address)(bytes,bytes)' "$(record .create2Deployer)" \
  "$salt_and_init_code" "$FACTORY" "$IMPLEMENTATION" --json)
factory_code=$(jq -j '.[0]' <<<"$built")
implementation_code=$(jq -j '.[1]' <<<"$built")
[ "$(cast keccak "$factory_code")" = "$(record .deployment.factoryRuntimeKeccak)" ] &&
  [ "$(cast keccak "$implementation_code")" = "$(record .deployment.implementationRuntimeKeccak)" ] ||
  fail "a deployment on chain $CHAIN_ID would differ from $HASHES"
code_overrides="$code_overrides,$FACTORY:$factory_code,$IMPLEMENTATION:$implementation_code"

operator_slot=$(cast index uint256 "$ID" "$LEAF_VOTER_TOKEN_STATES_SLOT")
operator_word=$(cast storage "$LEAF_VOTER" "$operator_slot" --block "$BLOCK")
with_operator() {
  local fields_above_the_operator=${operator_word:0:26}
  echo "$LEAF_VOTER:$operator_slot:$fields_above_the_operator${1#0x}"
}

clone=$(call "$FACTORY" 'operatorOf(address)(address)' "$RECIPIENT")
operator_read_back=$(call "$LEAF_VOTER" 'operator(uint256)(address)' "$ID" --override-state-diff "$(with_operator "$clone")")
[ "$operator_read_back" = "$clone" ] || fail "LeafVoter does not keep operators in slot $LEAF_VOTER_TOKEN_STATES_SLOT"

prepare() {
  local max_gauges=$1 fees_only=$2
  simulate 'prepare(address,address,uint256,address,uint256,bool)(bytes)' \
    "$FACTORY" "$LEAF_VOTER" "$ID" "$RECIPIENT" "$max_gauges" "$fees_only"
}
paid_by_aero() {
  local prepared=$1
  simulate 'claimAsOperator(address,uint256,address,bytes)(uint256[])' "$LEAF_VOTER" "$ID" "$RECIPIENT" "$prepared" \
    --override-state-diff "$(with_operator "$SIMULATION")" --json | jq -c '.[0]' | tr -d '"'
}
claim_through_clone() {
  local entry_gas=$1 entries_per_call=$2 gas_per_call=$3 paid_by_aero=$4 prepared=$5
  simulate 'claimThroughClone(uint256,address,uint256,uint256,uint256,uint256[],bytes)(uint8,uint256,uint256,uint256,uint256,uint256)' \
    "$ID" "$RECIPIENT" "$entry_gas" "$entries_per_call" "$gas_per_call" "$paid_by_aero" "$prepared" \
    --override-state-diff "$(with_operator "$clone")" --json
}

echo "chain $CHAIN_ID, block $BLOCK, stake $ID, recipient $RECIPIENT, clone $clone"
nothing_in() {
  [ -z "$(tr -d '[],0' <<<"$1")" ]
}
every_entry=$(prepare "$MAX_GAUGES" "$EVERY_ENTRY")
paid=$(paid_by_aero "$every_entry")
echo "Aero's own route pays: $paid"
nothing_in "$paid" && fail "the stake has nothing to claim"
result=$(claim_through_clone "$ENTRY_GAS" "$ENTRIES_PER_CALL" "$MAX_TRANSACTION_GAS" "$paid" "$every_entry")
[ "$(jq -j '.[0]' <<<"$result")" = "$OUTCOME_PAID_IN_FULL" ] || fail "the clone did not pay the same: $result"
[ "$(jq -j '.[5]' <<<"$result")" = "$BLOCK" ] || fail "the clone did not record block $BLOCK as its last claim: $result"
echo "the clone paid the same, less the fee, and kept nothing: $(jq -j '.[1]' <<<"$result") entries in" \
  "$(jq -j '.[2]' <<<"$result") calls of up to $ENTRIES_PER_CALL, the heaviest using $(jq -j '.[3]' <<<"$result") gas"
unread_programs=$(jq -j '.[4]' <<<"$result")
[ "$unread_programs" = 0 ] ||
  echo "warning: $unread_programs incentive programs were too old to read or could not be estimated"

passes_on_all_but_one_64th=$(simulate 'passesOnAllButOne64thOfItsGas()(bool)')
[ "$passes_on_all_but_one_64th" = true ] || fail "a call on this chain does not pass on all but one 64th of its gas"
one_fee_entry=$(prepare "$GAS_RULE_GAUGES" "$FEES_ONLY")
fees_of_one_gauge=$(paid_by_aero "$one_fee_entry")
nothing_in "$fees_of_one_gauge" && fail "the first gauge owes no fees: the gas rules are not checked"
outcome_with() {
  local entry_gas=$1 gas=$2
  claim_through_clone "$entry_gas" "$ALL_ENTRIES_IN_ONE_CALL" "$gas" "$fees_of_one_gauge" "$one_fee_entry" |
    jq -j '.[0]'
}
outcome=$(outcome_with "$STARVING_ENTRY_GAS" "$AMPLE_GAS")
[ "$outcome" = "$OUTCOME_PAID_NOTHING" ] || fail "a starved entry did not fail alone"
outcome=$(outcome_with "$ENTRY_GAS" "$AMPLE_GAS")
[ "$outcome" = "$OUTCOME_PAID_IN_FULL" ] || fail "the first gauge's fee entry needs more than $ENTRY_GAS gas"

too_little_entry_gas=$STARVING_ENTRY_GAS
least_entry_gas=$ENTRY_GAS
while [ $((least_entry_gas - too_little_entry_gas)) -gt 1 ]; do
  halfway=$(((too_little_entry_gas + least_entry_gas) / 2))
  outcome=$(outcome_with "$halfway" "$AMPLE_GAS")
  if [ "$outcome" = "$OUTCOME_PAID_IN_FULL" ]; then
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
    fail "with $halfway gas the claim went through without paying in full"
  fi
done
echo "gas rules: a call passes on all but one 64th of its gas; a fee entry given $STARVING_ENTRY_GAS gas fails" \
  "alone; given the $least_entry_gas it needs, a first claim reverts below $least_gas gas, intrinsic gas aside," \
  "and pays in full from there"
