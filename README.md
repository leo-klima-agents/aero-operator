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

They are not deployed yet. On every chain where Aero's LeafVoter is at
`0x382409fad8503FbCdbB27A4211551fa03e884078`, the factory will be at `0xeD962988E3a16A4De4352D971E1D2DC0937b3E1c` and
the `ImmutableClaimOperator` that the clones run at `0xE966A13044dCf4Cf3Fb1773655c0Bc232Ce5bf5D`. A recipient's clone
has the same address on all of them.

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

### Claiming

`claim(recipient, tokenId, feeClaims, incentiveClaims)` on the factory deploys the recipient's clone if it has no code
yet, then calls the clone's `claim(tokenId, feeClaims, incentiveClaims)`. Once a clone exists, its own `claim` can be
called directly. Anyone can call either, and the fee is the same whoever calls.

`feeClaims` and `incentiveClaims` are the lists the LeafVoter's `claimRewards` takes: rewards managers to claim fees
from, and incentive programs to claim. The clone makes each entry its own claim:

1. It checks that the rewards manager is registered in the LeafVoter's `FACTORY_REGISTRY`.
2. It claims the entry through the LeafVoter, to itself.
3. It asks the manager which tokens the entry pays: `token0` and `token1` for fees, the program's token for an
   incentive. For each, it sends 1% of its whole balance, rounded down, to the fee Safe and the rest to the recipient.
   A manager pays its `wrappedNative` token in native tokens, so on Base WETH fees arrive as ETH, and the clone
   forwards its native balance instead.

If any step of an entry reverts, the whole entry is undone: its rewards stay in the rewards manager, the clone emits
`ClaimFailed(tokenId, votingRewardsManager, programId)`, with `programId` 0 for fees, and carries on with the next
entry. So a token that can't be sent to the recipient or the fee Safe doesn't block the others, and the clone holds
nothing once `claim` returns.

For every token it forwards, the clone emits `Claimed(tokenId, token, amount, fee)`. `token` is the manager's token,
so a payment in native tokens shows the wrapped native token's address.

### Sales

Only Base knows who owns a stake. There, a clone claims only while its recipient is the stake's owner in the escrow,
and `claim` reverts with `NotOwner` otherwise. Selling the stake therefore stops the seller's clone on Base.

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

If you buy a stake, set its operator on every chain it has rewards on: to your own clone, or to the zero address.

## For claimers

`allocatedGauges(tokenId)` on a chain's LeafVoter lists the gauges a stake is allocated to, and `gaugeToRewards(gauge)`
on its `FACTORY_REGISTRY` gives each gauge's rewards manager. On a manager, `earnedFees(tokenId, maxCheckpoints)` and
`earnedIncentives(tokenId, programId, maxCheckpoints)` estimate what a claim would pay. `maxCheckpoints` must not be 0.

Each entry costs about 60,000 gas more than in a claim sent through Aero's Voter. In the fork tests, 10 entries cost
3.97M gas against 3.28M on Ethereum, and 56 entries 17.4M against 14.2M on Base. Base and Ethereum accept at most
16,777,216 gas per transaction, so split a long list.

An entry that fails by reverting costs little. One that uses up all the gas it is given leaves a 64th of it for the
entries after it, which can then fail too: leave such an entry out.

## Trust and limitations

- Nobody can change the factory, the `ImmutableClaimOperator` or a clone. A new fee, fee Safe or recipient means a new
  address, and setting the operators again.
- The clones are only as safe as Aero's contracts. The LeafVoter has no proxy, but Aero's governance holds roles on it,
  and a clone claims from whatever rewards managers Aero's `FACTORY_REGISTRY` lists.
- Whoever the escrow authorizes for a stake, its owner or an address the owner approved, can set its operators.
- A clone can't tell a sale on any chain but Base: see [Sales](#sales).
- A recipient that can't receive a token, such as USDC at a blocklisted address or native tokens at a contract that
  refuses them, makes every entry paying that token fail. The same goes for the fee Safe.
- A token that charges a fee on transfers is charged twice on its way through a clone.
- Tokens sent to a clone by mistake go to its recipient, less the fee, with the next claim that pays the same token.
  Wrapped native tokens are the exception where managers pay them in native tokens: those stay in the clone. Tokens
  sent to the factory or to the `ImmutableClaimOperator` itself are stuck there.
- Anyone can pass any registered rewards manager to `claim`, for any stake. Readers should expect `ClaimFailed` events
  and `Claimed` events for dust.
- The fee Safe, `0x450c72de8c0079B49AcedF294a13011bd09D125B`, must exist on a chain before the factory is deployed
  there. The deploy script refuses otherwise.

## Deployment

Not deployed yet. The table shows what each chain in `Voter.chains()` had on 2026-11-11.

| Chain | Id | LeafVoter | CREATE2 deployer | Fee Safe |
|---|---|---|---|---|
| Base | 8453 | yes | yes | yes, a 2-of-3 Safe |
| OP Mainnet | 10 | yes | yes | no |
| Ethereum | 1 | yes | yes | no |
| Arbitrum One | 42161 | yes | yes | no |
| Ink | 57073 | yes | yes | no |
| Robinhood Chain | 4663 | yes | yes | no |
| Arc | 5042 | yes | yes | no |
| Elysium | 99901 | yes | yes | no |

The LeafVoter is at the same address on all eight, so one set of constructor arguments serves them all. Its
`FACTORY_REGISTRY` differs from chain to chain, which is why the clones read it at each claim.

| | |
|---|---|
| Factory | `0xeD962988E3a16A4De4352D971E1D2DC0937b3E1c` |
| `ImmutableClaimOperator` | `0xE966A13044dCf4Cf3Fb1773655c0Bc232Ce5bf5D`, created by the factory's constructor |
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
4. Do a dry run with `forge script script/Deploy.s.sol --rpc-url $RPC_URL`, and check that it logs the addresses in
   the table above.
5. Deploy, then verify both contracts on the chain's explorer and on Sourcify:

```
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --ledger
ARGS=$(jq -j .deployment.constructorArgs verification/bytecode-hashes.json)
forge verify-contract 0xeD962988E3a16A4De4352D971E1D2DC0937b3E1c src/ImmutableClaimOperatorFactory.sol:ImmutableClaimOperatorFactory \
  --rpc-url $RPC_URL --constructor-args $ARGS --license-type MIT --watch
forge verify-contract 0xE966A13044dCf4Cf3Fb1773655c0Bc232Ce5bf5D src/ImmutableClaimOperator.sol:ImmutableClaimOperator \
  --rpc-url $RPC_URL --constructor-args $ARGS --license-type MIT --watch
```

## Verification

To check that the deployed contracts are this repository's code, compare their code hashes with the ones recorded in
`verification/bytecode-hashes.json`, which `script/check-verification.sh` checks against a build of this repository:

```
cast keccak $(cast code 0xeD962988E3a16A4De4352D971E1D2DC0937b3E1c --rpc-url $RPC_URL)
jq -j .deployment.factoryRuntimeKeccak verification/bytecode-hashes.json
cast keccak $(cast code 0xE966A13044dCf4Cf3Fb1773655c0Bc232Ce5bf5D --rpc-url $RPC_URL)
jq -j .deployment.implementationRuntimeKeccak verification/bytecode-hashes.json
```

A clone's code is `0x363d3d373d3d3d363d73`, the `ImmutableClaimOperator`'s address,
`0x5af43d82803e903d91602b57fd5bf3` and the recipient's address, 65 bytes in all.

## Development

You need [Foundry](https://getfoundry.sh). The fork tests also need archive RPCs: Base's in `BASE_RPC_URL` and
Ethereum's in `ETHEREUM_RPC_URL`.

- `forge test` runs the unit tests, and each chain's fork tests when its RPC is set. The fork tests run against the
  blocks and the stake named in [`test/Fork.t.sol`](test/Fork.t.sol). On each chain they deploy the factory with the
  deploy script, set a clone as a real stake's operator, and compare what a claim through it pays with the same claim
  sent by Aero's own route.
- Some of Base's tokens have the code `0xef` and run in the node itself, which Foundry's fork can't do. The fork tests
  leave out the rewards managers that pay them.
- `script/check-verification.sh` checks that `verification/` and this file's addresses match the build.
- `script/refresh-verification.sh` regenerates `verification/` after a change to the source or the deploy script.

The contracts compile with solc 0.8.37 for `prague`, via-IR, with 1,000,000 optimizer runs. Builds are reproducible.

## License

MIT. `REUSE.toml` records the copyright and license of every file.
