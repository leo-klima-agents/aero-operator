# aero-operator

`ImmutableClaimOperator` claims an Aero stake's rewards for its owner, on every chain Aero serves, and nobody
controls it. The owner names a clone of it as the stake's operator on a chain. After that, anyone can claim the
stake's rewards on that chain through the clone, which pays them to one fixed recipient and sends a 1% fee to a fixed
Safe.

There are two contracts, both without an owner, settings or an upgrade path:

- [`ImmutableClaimOperator`](src/ImmutableClaimOperator.sol) holds the code. Each recipient has a clone of it: a
  65-byte [ERC-1167](https://eips.ethereum.org/EIPS/eip-1167) proxy that ends with the recipient's address.
- [`ImmutableClaimOperatorFactory`](src/ImmutableClaimOperatorFactory.sol) deploys the clones and gives their
  addresses.

They are not deployed yet. On every chain where Aero's LeafVoter is at `0x382409fad8503FbCdbB27A4211551fa03e884078`
and the fee Safe exists, the factory will be at `0x2F6A94E2426456d2de4Bd8Eb9868163Db9972E29` and the
`ImmutableClaimOperator` that the clones run at `0xFD9F00473F5fb903E4F7056230E3E6546f239bD4`. A recipient's clone has
the same address on all of them.

## How it works

### Operators

Each stake can name one operator for each chain. The owner sets it on Base, with
`setOperator(tokenId, chainId, operator, gasLimit, refundTo)` on Aero's Voter, and the Voter passes it on to the
chain's LeafVoter. An operator can claim the stake's rewards on that chain to any address. It can't transfer or
withdraw the stake.

A clone only ever calls the LeafVoter's `claimRewards`, with itself as the recipient. It then sends everything it
received to the recipient written in its own code and to the fee Safe, in the same call.

### Clones

`operatorOf(recipient)` on the factory gives a recipient's clone. The address is computed from the factory's address
and the clone's code, which holds the recipient, so it is known before the clone exists:

    initCode = 0x6100413d81600a3d39f3363d3d373d3d3d363d73 ++ implementation ++ 0x5af43d82803e903d91602b57fd5bf3 ++ recipient
    operator = last 20 bytes of keccak256(0xff ++ factory ++ bytes32(0) ++ keccak256(initCode))

Nobody deploys clones in advance. The owner sets the address as the operator, and the factory deploys the clone with
the first claim.

Only a clone can claim. `recipient` and `claim` revert with `NotClone` unless they run in code of exactly a clone's 65
bytes. So the `ImmutableClaimOperator` itself, or another proxy to it without a recipient, pays nobody if it is set as
an operator by mistake.

### Claiming

`claim(recipient, tokenId, feeClaims, incentiveClaims, entryGas)` on the factory deploys the recipient's clone if it
has no code yet, then calls the clone's `claim(tokenId, feeClaims, incentiveClaims, entryGas)`. Once a clone exists,
its own `claim` can be called directly. Anyone can call either, and the fee is the same whoever calls.

`feeClaims` and `incentiveClaims` are the lists the LeafVoter's `claimRewards` takes: rewards managers to claim fees
from, and incentive programs to claim. The clone makes each entry its own claim:

1. It checks that the rewards manager is registered in the LeafVoter's `FACTORY_REGISTRY`.
2. It claims the entry through the LeafVoter, to itself.
3. It asks the manager which tokens the entry pays: `token0` and `token1` for fees, the program's token for an
   incentive. For each, it sends 1% of its whole balance, rounded down, to the fee Safe and the rest to the recipient.
   A manager pays its `wrappedNative` token in native tokens, so on Base WETH fees arrive as ETH, and the clone
   forwards its native balance instead.

If any step of an entry fails, the whole entry is undone: its rewards stay in the rewards manager, the clone emits
`ClaimFailed(tokenId, votingRewardsManager, fees, programId)`, with `fees` true and `programId` 0 for a fee claim,
and carries on with the next entry. So a token that can't be sent to the recipient or the fee Safe doesn't block the others, and the clone holds
nothing once `claim` returns.

`entryGas` is the gas each entry may use, the clone's own call included. Before an entry, `claim` reverts with
`InsufficientGas` unless it can pass `entryGas` on: a call can pass on 63/64 of the gas left, and `claim` first sets
20,000 aside to handle the entry's failure. So an entry never fails because the transaction was sent with too little
gas: either every entry was given `entryGas`, or nothing happened. An entry that uses up its gas, whatever the reason,
fails alone like any other.

For every token it forwards, the clone emits `Claimed(tokenId, token, amount, fee)`. `token` is the manager's token,
so a payment in native tokens shows the wrapped native token's address.

### Sales

Only Base knows who owns a stake. There, a clone claims only while its recipient is the stake's owner in the escrow,
and `claim` reverts with `NotOwner` otherwise. Selling the stake therefore stops the seller's clone on Base. The
operator itself stays set, though: if it is the buyer's own clone, set by the seller or by an address the seller
approved, that clone works on Base as soon as the buyer owns the stake.

The other chains can't tell. A LeafVoter keeps a stake's operator when the stake changes hands, so on those chains the
seller's clone goes on paying the seller until the buyer sets the operators again.

## For stake owners

To opt in on a chain, call `setOperator(tokenId, chainId, operator, gasLimit, refundTo)` on Aero's Voter on Base,
`0x49d7d4f17Ec56Ef8fA04E464AF5D1A4942CC31e6`, with your clone's address as `operator`. To opt out, call it with the
zero address.

- For Base itself, `gasLimit` is 0 and there is no fee. The operator changes in the same transaction.
- For another chain, `gasLimit` must not be 0, and the call carries a message fee. The Voter refunds what the
  message didn't cost to `refundTo`. The message expires after 2 hours.

On Base the recipient must be the stake's owner. On the other chains it can be any address: choose one that can
receive that chain's tokens. A Safe or another smart wallet on Base may not exist at the same address elsewhere.

While a clone is your stake's operator on a chain:

- anyone can claim your rewards there at any time, and you pay 1% of each claim;
- you can still claim through Aero's Voter, to any address and without the fee, whatever nobody has claimed yet;
- the stake has no other operator on that chain. If Aero turns on local allocating, which is off today, only a
  chain's operator can use it, and a clone never does.

If you buy a stake, set its operator on every chain it has rewards on, Base included: to your own clone, or to the
zero address.

## For claimers

`allocatedGauges(tokenId)` on a chain's LeafVoter lists the gauges a stake is allocated to, and `gaugeToRewards(gauge)`
on its `FACTORY_REGISTRY` gives each gauge's rewards manager. A gauge the stake has left is no longer listed but can
still owe it rewards: on the manager of every gauge the stake has been allocated to,
`userRewardCheckpointIndex(tokenId)` is not 0. On a manager, `earnedFees(tokenId, maxCheckpoints)` and
`earnedIncentives(tokenId, programId, maxCheckpoints)` estimate what a claim would pay. `maxCheckpoints` must not be 0.

Choose `entryGas` well above what the heaviest entry uses. The first claim of a stake's fees from a manager is the
heaviest: in the fork tests such an entry used up to about 680,000 gas on Base, and between 600,000 and 700,000 on
Ethereum, while an incentive entry used about 300,000. The Base and Ethereum fork tests check that no entry fails
with 700,000 and that some do with 500,000, and both run with 1,000,000. An entry that needs more
than `entryGas` fails and can be claimed again with more.

`ClaimFailed` doesn't say why an entry failed. To find out, simulate the clone's
`claimEntry(tokenId, votingRewardsManager, fees, programId, maxCheckpoints)` in an `eth_call` from the clone's own
address: it reverts with the reason, such as `NotRegistered(votingRewardsManager)`, `TransferFailed(token)` or the
LeafVoter's `NotAuthorized()` when the clone is not the stake's operator.

The gas limit has to cover `entryGas` once more than the claim uses: before its last entry, the clone needs
`entryGas × 64 / 63 + 20,000` left, and through the factory 64/63 of that. With less, the whole claim reverts with
`InsufficientGas` and pays nothing, so add a margin: entries can use more by the time the claim is included than they
did in a simulation.

Each entry costs about 60,000 gas more than in a claim sent through Aero's Voter, and the fork tests fail above
90,000. There, 10 entries cost 4.02M gas against 3.28M on Ethereum, and 56 entries 17.5M against 14.2M on Base. Base
and Ethereum accept at most 16,777,216 gas per transaction, so split a long list.

## Trust and limitations

- Nobody can change the factory, the `ImmutableClaimOperator` or a clone. A new fee, fee Safe or recipient means a new
  address, and setting the operators again.
- The clones are only as safe as Aero's contracts. The LeafVoter has no proxy, but Aero's governance holds roles on it,
  and a clone claims from whatever rewards managers Aero's `FACTORY_REGISTRY` lists.
- The gas check relies on a call passing on 63/64 of the gas left and on 20,000 gas covering what follows a failed
  entry. `script/simulate.sh` checks both on each chain's own node.
- Whoever calls `claim` chooses the gas each entry gets. On Base, nothing between a rewards manager's fee claim and
  the pool catches a failure, in either kind of gauge or any of the three kinds of pool, so an entry given too little
  fails whole. A gauge or pool that did catch one could be made to skip that step.
- Whoever the escrow authorizes for a stake, its owner or an address the owner approved, can set its operators.
- A clone can't tell a sale on any chain but Base: see [Sales](#sales).
- A recipient that can't receive a token, such as USDC at a blocklisted address or native tokens at a contract that
  refuses them, makes every entry paying that token fail. The same goes for the fee Safe. A fee entry pays a pool's
  two tokens together, so the other token's fees from that manager can't be claimed through the clone either.
- A token that charges a fee on transfers is charged twice on its way through a clone. A token whose balances move
  by themselves, or round, can leave a few of its smallest units in a clone until the next claim that pays it.
- The fee is rounded down, so a payment of fewer than 100 of a token's smallest units pays none.
- Tokens sent to a clone by mistake, native tokens included, go to its recipient, less the fee, with the next claim
  that pays the same token. Wrapped native tokens are the exception where managers pay them in native tokens: those
  stay in the clone. Tokens sent to the factory or to the `ImmutableClaimOperator` itself are stuck there.
- Anyone can pass any registered rewards manager to `claim`, for any stake. Readers should expect `ClaimFailed` events
  and `Claimed` events for dust, and should value a `Claimed` amount by its token: it is the balance the token itself
  reported.
- The fee Safe, `0x450c72de8c0079B49AcedF294a13011bd09D125B`, must exist on a chain before the factory can: the
  constructor reverts with `NoCode` where it has no code. So nobody can deploy the factory at its address on a chain
  the Safe is not on. On a chain without Aero's LeafVoter, the factory can exist but nothing can be claimed.

## Deployment

Not deployed yet. The table shows what each chain in `Voter.chains()` had on 2026-11-11.

| Chain | Id | LeafVoter | CREATE2 deployer | Fee Safe | Safe 1.5.0 singleton |
|---|---|---|---|---|---|
| Base | 8453 | yes | yes | yes, a 2-of-3 Safe | yes |
| OP Mainnet | 10 | yes | yes | no | yes |
| Ethereum | 1 | yes | yes | no | yes |
| Arbitrum One | 42161 | yes | yes | no | yes |
| Ink | 57073 | yes | yes | no | yes |
| Robinhood Chain | 4663 | yes | yes | no | yes |
| Arc | 5042 | yes | yes | no | yes |
| Elysium | 99901 | yes | yes | no | no |

The LeafVoter is at the same address on all eight, so one set of constructor arguments serves them all. Its
`FACTORY_REGISTRY` differs from chain to chain, which is why the clones read it at each claim. The fee Safe on Base
is a proxy to the Safe 1.5.0 singleton at `0xEdd160fEBBD92E350D4D398fb636302fccd67C7e`, which Elysium doesn't have
yet.

| | |
|---|---|
| Factory | `0x2F6A94E2426456d2de4Bd8Eb9868163Db9972E29` |
| `ImmutableClaimOperator` | `0xFD9F00473F5fb903E4F7056230E3E6546f239bD4`, created by the factory's constructor |
| LeafVoter | `0x382409fad8503FbCdbB27A4211551fa03e884078` |
| Escrow | `0xBF7977E1521e9a3032bf7243Ee4712f311f13915`, read on Base only |
| Base's chain id | 8453 |
| Fee Safe | `0x450c72de8c0079B49AcedF294a13011bd09D125B` |
| Fee | 1% (`FEE_BPS = 100`), fixed in the source |
| Method | CREATE2 through `0x4e59b44847b379578588920cA78FbF26c0B4956C`, salt `keccak256("metadex.cafe/ImmutableClaimOperatorFactory/v1")` |

The factory's address commits to its code and its constructor arguments, and a clone's address to the factory, the
`ImmutableClaimOperator` and the recipient. So an operator can safely point at an address where nothing is deployed
yet: only this code, with these arguments, can ever be there. A chain where Aero's addresses differ needs other
arguments, and gets a factory and clones at other addresses.

Deployment steps, for each chain:

1. Install Foundry v1.9.0, the version CI uses, with `foundryup --install v1.9.0`. Another version can compile
   different bytecode.
2. Run `forge test` with `BASE_RPC_URL` and `ETHEREUM_RPC_URL` set, then `script/check-verification.sh`.
3. Make sure the fee Safe exists on the chain, at the address above.
4. Run `script/simulate.sh $RPC_URL <token-id>` for a stake with rewards on the chain.
5. Do a dry run with `forge script script/Deploy.s.sol --rpc-url $RPC_URL`, and check that it logs the addresses in
   the table above.
6. Deploy, then verify both contracts on the chain's explorer and on Sourcify:

```
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --ledger
ARGS=$(jq -j .deployment.constructorArgs verification/bytecode-hashes.json)
forge verify-contract 0x2F6A94E2426456d2de4Bd8Eb9868163Db9972E29 src/ImmutableClaimOperatorFactory.sol:ImmutableClaimOperatorFactory \
  --rpc-url $RPC_URL --constructor-args $ARGS --license-type MIT --watch
forge verify-contract 0xFD9F00473F5fb903E4F7056230E3E6546f239bD4 src/ImmutableClaimOperator.sol:ImmutableClaimOperator \
  --rpc-url $RPC_URL --constructor-args $ARGS --license-type MIT --watch
```

## Verification

To check that the deployed contracts are this repository's code, compare their code hashes with the ones recorded in
`verification/bytecode-hashes.json`, which `script/check-verification.sh` checks against a build of this repository:

```
cast keccak $(cast code 0x2F6A94E2426456d2de4Bd8Eb9868163Db9972E29 --rpc-url $RPC_URL)
jq -j .deployment.factoryRuntimeKeccak verification/bytecode-hashes.json
cast keccak $(cast code 0xFD9F00473F5fb903E4F7056230E3E6546f239bD4 --rpc-url $RPC_URL)
jq -j .deployment.implementationRuntimeKeccak verification/bytecode-hashes.json
```

A clone's code is `0x363d3d373d3d3d363d73`, the `ImmutableClaimOperator`'s address,
`0x5af43d82803e903d91602b57fd5bf3` and the recipient's address, 65 bytes in all.

## Development

You need [Foundry](https://getfoundry.sh). The fork tests also need archive RPCs: Base's in `BASE_RPC_URL` and
Ethereum's in `ETHEREUM_RPC_URL`.

- `forge test` runs the unit tests, and each chain's fork tests when its RPC is set. The fork tests run against the
  blocks and the stake named in [`test/Fork.t.sol`](test/Fork.t.sol). On each chain they deploy the factory with the
  deploy script, set a clone as a real stake's operator, and compare what a claim through it pays, and what its events
  say, with the same claim sent by Aero's own route. On Ethereum, where the fee Safe is not deployed yet, a contract
  that only accepts payments stands in for it.
- A fork can't do everything. Some tokens run in the node itself: Base's native tokens, whose code is `0xef`, and
  Arc's USDC. The Base fork tests leave out the rewards managers that pay them. A fork also runs on Foundry's gas
  rules, not the chain's.
- `script/simulate.sh <rpc-url> <token-id> [max-gauges] [entry-gas] [entries-per-call]` covers both, on the node
  itself. In `eth_call`s with state overrides, and nothing sent, it deploys the factory, makes the recipient's clone
  the stake's operator, and:
  - claims everything the stake is owed by the gauges it is allocated to, in calls of 12 entries that each get the
    16,777,216 gas of a transaction, and checks the total against Aero's own route;
  - gives each entry of the first two gauges 10,000 gas and checks that they all fail alone;
  - searches for the least gas at which a claim of those gauges goes through, and checks that every attempt either
    reverts or pays in full.

  It passes on all eight chains. It needs a node that accepts state overrides, and it says how many incentive
  programs it could not read. Off Base, `RECIPIENT` chooses the recipient. Calls made one after another in one
  `eth_call` share what the first ones touched, so each uses a little less gas than a transaction of its own would.
- `script/check-verification.sh` checks that `verification/` and this file's addresses match the build.
- `script/refresh-verification.sh` regenerates `verification/` after a change to the source or the deploy script.

The contracts compile with solc 0.8.37 for `prague`, via-IR, with 1,000,000 optimizer runs. Builds are reproducible.

## License

MIT. `REUSE.toml` records the copyright and license of every file.
