# aero-operator

`ImmutableClaimOperator` claims an Aero stake's rewards for one fixed recipient. A stake's owner names the recipient's
clone as the stake's operator on a chain, with `setOperator(tokenId, chainId, operator, gasLimit, refundTo)` on Aero's
Voter on Base, `0x49d7d4f17Ec56Ef8fA04E464AF5D1A4942CC31e6`. Anyone can then claim the stake's rewards there through
the clone, which pays 1% to a fee Safe and the rest to the recipient. Setting the zero address or another operator
ends it once the message reaches the chain.

Neither contract has an owner, settings or an upgrade path:

- [`ImmutableClaimOperator`](src/ImmutableClaimOperator.sol) holds the code. A recipient's clone is a 65-byte ERC-1167
  proxy to it that ends with the recipient's address.
- [`ImmutableClaimOperatorFactory`](src/ImmutableClaimOperatorFactory.sol) deploys the clones and gives their
  addresses.

## Behaviour

- `operatorOf(recipient)` on the factory gives a recipient's clone, whether or not it exists yet:

      initCode = 0x6100413d81600a3d39f3363d3d373d3d3d363d73 ++ ImmutableClaimOperator ++ 0x5af43d82803e903d91602b57fd5bf3 ++ recipient
      operator = last 20 bytes of keccak256(0xff ++ factory ++ bytes32(0) ++ keccak256(initCode))

- `claim(recipient, tokenId, feeClaims, incentiveClaims, entryGas)` on the factory deploys the clone if it has no code,
  then calls the clone's `claim(tokenId, feeClaims, incentiveClaims, entryGas)`. Anyone can call either. The two lists
  are those of the LeafVoter's `claimRewards`.
- The clone claims each entry on its own, to itself, from a rewards manager that the LeafVoter's `FACTORY_REGISTRY`
  lists. It then sends 1% of what it received in each token, rounded down, to the fee Safe, and the rest to the
  recipient. A manager pays its `wrappedNative` token in native tokens, and the clone forwards those.
- An entry that fails is undone: its rewards stay in the rewards manager, the clone emits
  `ClaimFailed(tokenId, votingRewardsManager, fees, programId)` and goes on. For each token it forwards, it emits
  `Claimed(tokenId, token, amount, fee, previousClaimBlock)`: `token` is the zero address for native tokens, and
  `amount` is what the clone received during the entry, fee included.
- The clone stores one thing: the block of its last payment in a claim, `lastClaimBlock()`. Each `Claimed` carries the
  block stored before it, so a clone's claims can be read newest first, one block of logs at a time: start at
  `lastClaimBlock()` and follow the smallest `previousClaimBlock` below the current block. The block is the chain's
  own, which Arbitrum One, Robinhood Chain and Elysium give through ArbSys.
- Each entry gets `entryGas`. `claim` reverts with `InsufficientGas` unless it can pass that much on and keep 20,000
  to go on. So a claim never succeeds with an entry that failed for lack of gas in the transaction.
- On Base, `claim` reverts with `NotOwner` unless the recipient owns the stake. Other chains can't tell, and a stake
  keeps its operators when it changes hands.
- `sweep(recipient, token)` on the factory deploys the clone if it has no code, then calls the clone's `sweep(token)`.
  Anyone can call either. The clone sends its balance of the token the same way, or its native tokens for the zero
  address, and emits `Swept(token, amount, fee)` if it sent anything. A token can be any contract, so `Swept` proves
  a payment only for a token that is known. A sweep leaves `lastClaimBlock()` as it is.
- `recipient`, `claim` and `sweep` revert with `NotClone` in code that is not 65 bytes long.

## Claiming

- **Entries.** `allocatedGauges(tokenId)` on the LeafVoter lists a stake's gauges, and `gaugeToRewards(gauge)` on its
  `FACTORY_REGISTRY` gives a gauge's rewards manager. A gauge the stake has left can still owe it rewards: its manager's
  `userRewardCheckpointIndex(tokenId)` is not 0. `incentiveCount()` on a manager gives its programs, numbered from 1.
  `earnedFees` and `earnedIncentives` on a manager estimate a claim.
- **Entry gas.** A stake's first fee claim from a manager is the heaviest. `script/simulate.sh` prints what a stake's
  first fee entry needs: up to 884,329, on Arc, on 2026-11-13. An entry that needs more than `entryGas` fails and can
  be claimed again. One that needs less uses less, so a high `entryGas` only raises the gas limit. The tests and the
  simulation use 1,000,000, and 500 for `maxCheckpoints`.
- **Gas limit.** A claim through the factory reverts with less than

      I + F + g(P + g(U + 20,000 + g(entryGas)))        where g(x) = x + ⌊(x − 1) / 63⌋

  and goes through with that much. A call keeps a 64th of the gas, so `g(x)` is what it takes to pass `x` on.

  | | | For one fee entry |
  |---|---|---|
  | `I` | The transaction's intrinsic gas | 21,000 plus 4 per zero byte and 16 per other byte of calldata |
  | `F` | What the factory uses before it calls the clone | 4,406, and 45,079 more when it deploys the clone |
  | `P` | What the clone's proxy uses: `2,624 + 6w + ⌊w² / 512⌋` for `w` 32-byte words of calldata to the clone | 2,678 |
  | `U` | What the clone uses before its last entry, earlier entries included | 3,923, and 9,587 on Base |

  A claim sent to the clone needs `I + P + g(U + 20,000 + g(entryGas))`. The unit tests pin these numbers but Base's,
  and calls bisected on all eight chains matched exactly. Arbitrum One, Robinhood Chain and Elysium also charge the
  limit for posting the transaction's data, so use `eth_estimateGas` there. It finds a limit that goes through.
  Earlier entries can use more by the time the transaction lands, up to `entryGas` each, so add a margin.
- **Cost.** An entry costs about 60,000 gas more than through Aero's Voter. Base, OP Mainnet, Ethereum, Ink and Arc
  allow a transaction 16,777,216 gas, so split long lists.
- **Failures.** To learn why an entry fails, call the clone's
  `claimEntry(tokenId, votingRewardsManager, fees, programId, maxCheckpoints)` in an `eth_call` from the clone's own
  address. It reverts with the reason. Anyone can make a clone emit `ClaimFailed`, with too little `entryGas` or a
  manager the registry does not list.

## Limits

- The clones are only as safe as Aero's LeafVoter, registry and rewards managers.
- Whoever calls `claim` chooses each entry's gas. On Base nothing on Aero's fee path catches a failure, so an entry
  given too little fails whole. Other chains' basic-pool gauges were not checked.
- A token the recipient or the fee Safe can't receive fails every entry that pays it. A fee entry pays a pool's two
  tokens together.
- A claim pays only what its entries received. Anything else a clone holds goes to its recipient, less the fee, with
  `sweep`: tokens sent to it, or a token a rewards manager paid without naming it in `token0`, `token1` or
  `incentive`. Tokens sent to the factory or to `ImmutableClaimOperator` are stuck.
- A token that charges a fee on transfers is charged twice. A payment under 100 of a token's smallest units pays no
  fee.
- An operator set before a sale stays set. On Base, a buyer's own clone set by the seller works once the buyer owns
  the stake.
- A stake has one operator per chain: naming a clone replaces any other.

## Deployment

Not deployed. The factory needs the fee Safe on the chain: its constructor reverts with `NoCode` otherwise. On
2026-11-13 the Safe was only on Base. The constructor only checks for code, so check the Safe's owners and threshold
on each chain.

The LeafVoter and the CREATE2 deployer are on all eight chains:

| Chain | Id | Fee Safe | Safe 1.5.0 singleton |
|---|---|---|---|
| Base | 8453 | yes | yes |
| OP Mainnet | 10 | no | yes |
| Ethereum | 1 | no | yes |
| Arbitrum One | 42161 | no | yes |
| Ink | 57073 | no | yes |
| Robinhood Chain | 4663 | no | yes |
| Arc | 5042 | no | yes |
| Elysium | 99901 | no | no |

The addresses are the same on every chain:

| | |
|---|---|
| Factory | `0x9A48f3E233a0068e7Bb97e1335799eC49cdaA8DB` |
| `ImmutableClaimOperator` | `0xC902bd20AaA3d95d0F92E47E22c7bA8C42919FAF` |
| LeafVoter | `0x382409fad8503FbCdbB27A4211551fa03e884078` |
| Escrow | `0xBF7977E1521e9a3032bf7243Ee4712f311f13915`, read on Base only |
| Base's chain id | 8453 |
| Fee Safe | `0x450c72de8c0079B49AcedF294a13011bd09D125B`, a proxy to the Safe 1.5.0 singleton |
| Fee | 1%, fixed in the source |
| Method | CREATE2 through `0x4e59b44847b379578588920cA78FbF26c0B4956C`, salt `keccak256("metadex.cafe/ImmutableClaimOperatorFactory/v1")` |

Once:

1. Clone with `git clone --recurse-submodules`, and install `jq` and Foundry v1.9.0 with
   `foundryup --install v1.9.0`. Another version can compile different bytecode.
2. Run `forge test` with `BASE_RPC_URL` and `ETHEREUM_RPC_URL` set, then `script/check-verification.sh`.

Then for each chain:

3. Run `script/simulate.sh $RPC_URL <token-id>` for a stake with rewards on the chain. Off Base, `RECIPIENT` sets the
   recipient to simulate.
4. Deploy. The script stops unless the build matches `verification/bytecode-hashes.json`. Then run it again: it must
   send nothing and say that the code at both addresses matches the record.

```
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --ledger
```

5. Verify. With `ETHERSCAN_API_KEY` set, forge submits to Etherscan and then Sourcify, and without it to Sourcify
   only:

```
RECORD=verification/bytecode-hashes.json
ARGS=$(jq -j .deployment.constructorArgs $RECORD)
forge verify-contract $(jq -j .deployment.factory $RECORD) \
  src/ImmutableClaimOperatorFactory.sol:ImmutableClaimOperatorFactory \
  --rpc-url $RPC_URL --constructor-args $ARGS --license-type MIT --watch
forge verify-contract $(jq -j .deployment.implementation $RECORD) \
  src/ImmutableClaimOperator.sol:ImmutableClaimOperator \
  --rpc-url $RPC_URL --constructor-args $ARGS --license-type MIT --watch
```

## Verification

Compare the deployed code hashes with `verification/bytecode-hashes.json`:

```
RECORD=verification/bytecode-hashes.json
cast keccak $(cast code $(jq -j .deployment.factory $RECORD) --rpc-url $RPC_URL)
jq -j .deployment.factoryRuntimeKeccak $RECORD
cast keccak $(cast code $(jq -j .deployment.implementation $RECORD) --rpc-url $RPC_URL)
jq -j .deployment.implementationRuntimeKeccak $RECORD
```

A clone's code is `0x363d3d373d3d3d363d73`, the `ImmutableClaimOperator`'s address,
`0x5af43d82803e903d91602b57fd5bf3` and the recipient's address.

## Development

- `forge test` runs the unit tests, and the fork tests of Base and Ethereum when `BASE_RPC_URL` and
  `ETHEREUM_RPC_URL` point to archive nodes. The fork tests compare a claim through a clone with the same claim by
  Aero's own route, for a real stake.
- `script/simulate.sh <rpc-url> <token-id> [max-gauges] [entry-gas] [entries-per-call]` makes the same comparison on
  a live node that takes state overrides in `eth_call`, with the recorded code deployed the recorded way. It also
  checks the clone's last claim block and the node's gas rules. It covers what a fork can't run: Base's native tokens,
  Arc's USDC and each chain's own gas rules. It passes on all eight chains.
- `script/check-verification.sh` checks `verification/` and this file's addresses against the build, and `forge test`
  checks the runtime hashes. `script/refresh-verification.sh` regenerates `verification/`.

The contracts compile with solc 0.8.38 for `osaka`, which all eight chains run, via-IR, with 1,000,000 optimizer runs.

## License

MIT. `REUSE.toml` records the copyright and license of every file.
