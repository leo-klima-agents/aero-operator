#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

RPC=${1:?usage: script/fee-safe.sh <rpc-url>}
SAFE=$(jq -j .deployment.feeRecipient verification/bytecode-hashes.json)
OWNERS='[0x38F74e78B755668D13189C207851745B2fc04A62,0x2CbbBa3f77c0dFBfBc5C7Af0f3056A086B6a7807,0xA53b1a6F17189d7061f22f8E749Fe494C9E7dAE1]'
THRESHOLD=2
VERSION=1.5.0
PROXY_FACTORY=0x14F2982D601c9458F93bd70B218933A6f8165e7b
SINGLETON=0xFf51A5898e281Db6DfC7855790607438dF2ca44b
SINGLETON_OFF_ETHEREUM=0xEdd160fEBBD92E350D4D398fb636302fccd67C7e
TO_L2_SETUP=0x900C7589200010D6C6eCaaE5B06EBe653bc2D82a
FALLBACK_HANDLER=0x3EfCBb83A4A7AfcB4F68D501E2c2203a38be77f4
PAYMENT_RECEIVER=0x5afe7A11E7000000000000000000000000000000
SALT_NONCE=0
ETHEREUM_CHAIN_ID=1
NO_ADDRESS=0x0000000000000000000000000000000000000000
FIRST_MODULE=0x0000000000000000000000000000000000000001
MAX_MODULES=10
GUARD_SLOT=$(cast keccak guard_manager.guard.address)
MODULE_GUARD_SLOT=$(cast keccak module_manager.module_guard.address)
FALLBACK_HANDLER_SLOT=$(cast keccak fallback_manager.handler.address)
CREATE='createProxyWithNonce(address,bytes,uint256)'

if [ "$(cast code "$SAFE" --rpc-url "$RPC")" = 0x ]; then
  for needed in "$PROXY_FACTORY" "$SINGLETON" "$SINGLETON_OFF_ETHEREUM" "$TO_L2_SETUP" "$FALLBACK_HANDLER"; do
    [ "$(cast code "$needed" --rpc-url "$RPC")" != 0x ] || {
      echo "the fee Safe is not on this chain and can't be created: Safe $VERSION's $needed is missing" >&2
      exit 1
    }
  done
  setup=$(cast calldata 'setup(address[],uint256,address,bytes,address,address,uint256,address)' \
    "$OWNERS" "$THRESHOLD" "$TO_L2_SETUP" "$(cast calldata 'setupToL2(address)' "$SINGLETON_OFF_ETHEREUM")" \
    "$FALLBACK_HANDLER" "$NO_ADDRESS" 0 "$PAYMENT_RECEIVER")
  created=$(cast call "$PROXY_FACTORY" "$CREATE(address)" "$SINGLETON" "$setup" "$SALT_NONCE" --rpc-url "$RPC")
  [ "$created" = "$SAFE" ] || {
    echo "creating the fee Safe on this chain would give $created, not $SAFE" >&2
    exit 1
  }
  echo "the fee Safe is not on this chain. Anyone can create it at $SAFE, with the same owners, by sending:" >&2
  echo "cast send $PROXY_FACTORY '$CREATE' $SINGLETON $setup $SALT_NONCE --rpc-url <rpc-url>" >&2
  exit 1
fi

status=0
expect() {
  local what=$1 found expected
  found=$(tr '[:upper:]' '[:lower:]' <<<"$2" | tr -d ' "')
  expected=$(tr '[:upper:]' '[:lower:]' <<<"$3")
  if [ "$found" = "$expected" ]; then
    echo "$what ok"
  else
    echo "$what is $found, not $expected" >&2
    status=1
  fi
}
read_safe() {
  cast call "$SAFE" "$@" --rpc-url "$RPC"
}
slot() {
  cast storage "$SAFE" "$1" --rpc-url "$RPC"
}
in_a_slot() {
  cast to-uint256 "$1"
}

singleton=$SINGLETON_OFF_ETHEREUM
[ "$(cast chain-id --rpc-url "$RPC")" != "$ETHEREUM_CHAIN_ID" ] || singleton=$SINGLETON
expect singleton "$(read_safe 'masterCopy()(address)')" "$singleton"
expect version "$(read_safe 'VERSION()(string)')" "$VERSION"
expect owners "$(read_safe 'getOwners()(address[])')" "$OWNERS"
expect threshold "$(read_safe 'getThreshold()(uint256)')" "$THRESHOLD"
expect guard "$(slot "$GUARD_SLOT")" "$(in_a_slot "$NO_ADDRESS")"
expect 'module guard' "$(slot "$MODULE_GUARD_SLOT")" "$(in_a_slot "$NO_ADDRESS")"
expect 'fallback handler' "$(slot "$FALLBACK_HANDLER_SLOT")" "$(in_a_slot "$FALLBACK_HANDLER")"
modules=$(read_safe 'getModulesPaginated(address,uint256)(address[])' "$FIRST_MODULE" "$MAX_MODULES")
[ "$modules" = '[]' ] || echo "modules, which can move the Safe's funds without its owners: $modules"
exit $status
