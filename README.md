# aero-operator

`ImmutableClaimOperator` claims an Aero stake's rewards for one fixed recipient. A stake's owner names the recipient's
clone as the stake's operator on a chain. Anyone can then claim the stake's rewards there through the clone, which pays
them to the recipient and 1% to a fee Safe.

Neither contract has an owner, settings or an upgrade path:

- [`ImmutableClaimOperator`](src/ImmutableClaimOperator.sol) holds the code. A recipient's clone is a 65-byte ERC-1167
  proxy to it that ends with the recipient's address.
- [`ImmutableClaimOperatorFactory`](src/ImmutableClaimOperatorFactory.sol) deploys the clones and gives their
  addresses.

## Behaviour

- `operatorOf(recipient)` on the factory gives a recipient's clone, whether or not it exists yet:

      initCode = 0x6100413d81600a3d39f3363d3d373d3d3d363d73 ++ implementation ++ 0x5af43d82803e903d91602b57fd5bf3 ++ recipient
      operator = last 20 bytes of keccak256(0xff ++ factory ++ bytes32(0) ++ keccak256(initCode))

- `claim(recipient, tokenId, feeClaims, incentiveClaims, entryGas)` on the factory deploys the clone if it has no code,
  then calls the clone's `claim(tokenId, feeClaims, incentiveClaims, entryGas)`. Anyone can call either. The two lists
  are those of the LeafVoter's `claimRewards`.
- The clone claims each entry on its own, to itself, from a rewards manager that the LeafVoter's `FACTORY_REGISTRY`
  lists. It then sends 1% of its balance of each token the entry pays, rounded down, to the fee Safe, and the rest to
  the recipient. A manager pays its `wrappedNative` token in native tokens, and the clone forwards those.
- An entry that fails is undone: its rewards stay in the rewards manager, the clone emits
  `ClaimFailed(tokenId, votingRewardsManager, fees, programId)` and goes on. For each token it forwards, it emits
  `Claimed(tokenId, token, amount, fee)`.
- Each entry gets `entryGas`. `claim` reverts with `InsufficientGas` unless it can pass that much on and keep 20,000
  to go on. So a claim never succeeds with an entry that failed for lack of gas in the transaction.
- On Base, `claim` reverts with `NotOwner` unless the recipient owns the stake. Other chains can't tell, and a stake
  keeps its operators when it changes hands.
- `recipient` and `claim` revert with `NotClone` in code that is not 65 bytes long.

## Claiming

- **Entries.** `allocatedGauges(tokenId)` on the LeafVoter lists a stake's gauges, and `gaugeToRewards(gauge)` on its
  `FACTORY_REGISTRY` gives a gauge's rewards manager. A gauge the stake has left can still owe it rewards: its manager's
  `userRewardCheckpointIndex(tokenId)` is not 0. `earnedFees` and `earnedIncentives` on a manager estimate a claim.
- **Entry gas.** A stake's first fee claim from a manager is the heaviest. In the fork tests none fails with 700,000
  and some do with 500,000. An entry that needs more than `entryGas` fails and can be claimed again.
- **Gas limit.** Before its last entry the clone needs `entryGas × 64 / 63 + 20,000`, and through the factory 64/63 of
  that. With less the whole claim reverts, so add a margin.
- **Cost.** An entry costs about 60,000 gas more than through Aero's Voter. Base and Ethereum allow a transaction
  16,777,216 gas, so split long lists.
- **Failures.** To learn why an entry fails, call the clone's
  `claimEntry(tokenId, votingRewardsManager, fees, programId, maxCheckpoints)` in an `eth_call` from the clone's own
  address. It reverts with the reason.

## Limits

- The clones are only as safe as Aero's LeafVoter, registry and rewards managers.
- Whoever calls `claim` chooses each entry's gas. On Base nothing on Aero's fee path catches a failure, so an entry
  given too little fails whole. Other chains' basic-pool gauges were not read.
- A token the recipient or the fee Safe can't receive fails every entry that pays it. A fee entry pays a pool's two
  tokens together.
- Tokens sent to a clone go to its recipient, less the fee, with the next claim that pays them. Wrapped native tokens
  stay where managers pay them in native tokens. Tokens sent to the factory or to `ImmutableClaimOperator` are stuck.
- A token that charges a fee on transfers is charged twice. A payment under 100 of a token's smallest units pays no
  fee.
- An operator set before a sale stays set. On Base, a buyer's own clone set by the seller works once the buyer owns
  the stake.

## Deployment

Not deployed. The factory needs the fee Safe on the chain: its constructor reverts with `NoCode` otherwise. On
2026-11-11 the Safe was only on Base.

| Chain | Id | LeafVoter | CREATE2 deployer | Fee Safe | Safe 1.5.0 singleton |
|---|---|---|---|---|---|
| Base | 8453 | yes | yes | yes | yes |
| OP Mainnet | 10 | yes | yes | no | yes |
| Ethereum | 1 | yes | yes | no | yes |
| Arbitrum One | 42161 | yes | yes | no | yes |
| Ink | 57073 | yes | yes | no | yes |
| Robinhood Chain | 4663 | yes | yes | no | yes |
| Arc | 5042 | yes | yes | no | yes |
| Elysium | 99901 | yes | yes | no | no |

The addresses are the same on every chain:

| | |
|---|---|
| Factory | `0x094a9b48B486bF2b2e98bc8d087B3A2C321Bb24b` |
| `ImmutableClaimOperator` | `0xd8F04Fb430abB3a02fCe87652C47292FAaE1E290` |
| LeafVoter | `0x382409fad8503FbCdbB27A4211551fa03e884078` |
| Escrow | `0xBF7977E1521e9a3032bf7243Ee4712f311f13915`, read on Base only |
| Base's chain id | 8453 |
| Fee Safe | `0x450c72de8c0079B49AcedF294a13011bd09D125B`, a proxy to the Safe 1.5.0 singleton |
| Fee | 1%, fixed in the source |
| Method | CREATE2 through `0x4e59b44847b379578588920cA78FbF26c0B4956C`, salt `keccak256("aero-operator/ImmutableClaimOperatorFactory/v1")` |

For each chain:

1. Install Foundry v1.9.0 with `foundryup --install v1.9.0`. Another version can compile different bytecode.
2. Run `forge test` with `BASE_RPC_URL` and `ETHEREUM_RPC_URL` set, then `script/check-verification.sh`.
3. Run `script/simulate.sh $RPC_URL <token-id>` for a stake with rewards on the chain.
4. Run `forge script script/Deploy.s.sol --rpc-url $RPC_URL` and check the addresses it logs.
5. Deploy and verify:

```
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --ledger
ARGS=$(jq -j .deployment.constructorArgs verification/bytecode-hashes.json)
forge verify-contract 0x094a9b48B486bF2b2e98bc8d087B3A2C321Bb24b src/ImmutableClaimOperatorFactory.sol:ImmutableClaimOperatorFactory \
  --rpc-url $RPC_URL --constructor-args $ARGS --license-type MIT --watch
forge verify-contract 0xd8F04Fb430abB3a02fCe87652C47292FAaE1E290 src/ImmutableClaimOperator.sol:ImmutableClaimOperator \
  --rpc-url $RPC_URL --constructor-args $ARGS --license-type MIT --watch
```

## Verification

Compare the deployed code hashes with `verification/bytecode-hashes.json`:

```
cast keccak $(cast code 0x094a9b48B486bF2b2e98bc8d087B3A2C321Bb24b --rpc-url $RPC_URL)
jq -j .deployment.factoryRuntimeKeccak verification/bytecode-hashes.json
cast keccak $(cast code 0xd8F04Fb430abB3a02fCe87652C47292FAaE1E290 --rpc-url $RPC_URL)
jq -j .deployment.implementationRuntimeKeccak verification/bytecode-hashes.json
```

A clone's code is `0x363d3d373d3d3d363d73`, the `ImmutableClaimOperator`'s address,
`0x5af43d82803e903d91602b57fd5bf3` and the recipient's address.

## Development

- `forge test` runs the unit tests, and the fork tests of Base and Ethereum when `BASE_RPC_URL` and
  `ETHEREUM_RPC_URL` point to archive nodes. The fork tests compare a claim through a clone with the same claim by
  Aero's own route, for a real stake.
- `script/simulate.sh <rpc-url> <token-id> [max-gauges] [entry-gas] [entries-per-call]` makes the same comparison on
  a live node, in `eth_call`s with state overrides, and checks the node's gas rules. It covers what a fork can't run:
  Base's native tokens, Arc's USDC and each chain's own gas rules. It passes on all eight chains.
- `script/check-verification.sh` checks `verification/` and this file's addresses against the build.
  `script/refresh-verification.sh` regenerates `verification/`.

The contracts compile with solc 0.8.37 for `prague`, via-IR, with 1,000,000 optimizer runs.

## License

MIT. `REUSE.toml` records the copyright and license of every file.
