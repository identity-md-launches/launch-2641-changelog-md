# Changelog.md (CMD)

A fixed-supply ERC-20 token for Ethereum. All 1,000,000,000 CMD are allocated
once to the immediate deployer in the constructor. No further minting or burning
is exposed. The project has no downloaded dependencies and builds entirely from
the Solidity sources in this repository once the pinned compiler is installed.

## Deployment parameters

| Parameter | Value |
| --- | --- |
| Solidity contract | `ChangelogToken` |
| Source | `src/ChangelogToken.sol` |
| Token name | `Changelog.md` |
| Symbol | `CMD` |
| Decimals | `18` |
| Whole-token supply | `1,000,000,000` |
| Supply in base units | `1000000000000000000000000000` (`10^27`) |
| Constructor arguments | None (`[]`) |
| Deployment value | `0` ETH |
| Initial recipient | Constructor `msg.sender` |
| Intended launch chain | Ethereum, chain ID `1` |
| Solidity compiler | `0.8.26` |
| EVM target | `cancun` |
| Optimization | Enabled, `200` runs |
| Bytecode metadata hash | `none` |
| Linked libraries / application contracts | None |

Build the creation bytecode for `src/ChangelogToken.sol:ChangelogToken`. There
are no constructor arguments to append and no initialization call to make.
Direct deployment allocates all tokens to the deploying wallet. Deployment by
the launch factory allocates all tokens to that factory, regardless of who
originated the transaction. The constructor does not call outside contracts.

The factory performs the launch distribution after construction: 10% to the
launch distributor, 80% for pool seeding, and the remaining 10% to the requester
according to the supplied launch economics. The token neither routes nor
reserves these balances itself. Pool setup, launch addresses, pricing, and the
separate launch manifest belong to the launch system; none is a token setting.

## Behavior and assumptions

- `transfer`, `approve`, and `transferFrom` return `true` on success and revert
  with typed ERC-6093 errors on failure. Transfers move exactly the specified
  base units, with no tax, fee, rebase, or address exemptions.
- Zero-value transfers between nonzero addresses succeed and emit `Transfer`.
  Self-transfers succeed when the sender has sufficient balance, preserving it.
- Transfers reject the zero sender and zero recipient, including zero-value
  transfers. Approvals reject the zero approver and zero spender.
- `approve` replaces the caller's allowance. Zero revokes it. An allowance of
  `type(uint256).max` is unlimited and is not reduced by `transferFrom`.
- `transferFrom` always uses the caller's allowance, even when the caller is
  also the holder. A delegated self-transfer consumes a finite allowance while
  leaving the holder's balance unchanged. Failed transfers revert all changes,
  including any allowance deduction.
- The constructor emits `Transfer(address(0), deployer, totalSupply)`.
  `approve` emits `Approval`; spending an allowance emits only `Transfer`.
  Integrations should query `allowance` for its current value rather than
  reconstructing it solely from approval events.
- This is a plain ERC-20: there is no permit, callback, owner, pause, blacklist,
  seizure, public burn, additional mint, rescue, initializer, or upgrade path.
  Functions make no external calls and invoke no recipient callbacks.
- The supply is a compile-time constant. Only the constructor assigns the
  initial balance; later balance changes are paired debits and credits. The
  checked balance and allowance comparisons guard the unchecked subtractions.
- No payable function or fallback accepts ordinary ETH transfers. Tokens sent
  to this token's own address or another contract with no withdrawal mechanism
  cannot be recovered by an administrator; such balances still count in supply.

## Build and test

Prerequisites: Foundry and Solidity **0.8.26** installed in its compiler cache.
The verifier supplies that compiler offline. No package download, submodule,
RPC, wallet, environment file, FFI, or filesystem cheatcode is needed.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x84dd68143da1cb96bd0688e837813d4a63101d5d10f939af5fa81096c794f148 forge test
forge fmt --check
```

`foundry.toml` selects 512 cases for each fuzz test without overriding the seed.
Tests use only local EVM state and a small Foundry cheatcode interface in
`test/support/TestBase.sol`; they neither read nor modify environment variables.
They have no order dependencies and require no outside services.

- `test/ChangelogToken.t.sol`: metadata, constructor allocation and mint event,
  wallet and contract deployers, exact distribution/claim amounts, transfer and
  approval events, zero/full/self-transfers, allowance replacement/revocation,
  unlimited approvals, authorization failures, insufficient balances, invalid
  addresses, rollback, unavailable privileged entry points, and ETH rejection.
- `test/ChangelogToken.fuzz.t.sol`: arbitrary recipients and approvals, supply
  conservation, delegated accounting, and failed-call atomicity at boundary
  values including `uint256.max`.
- `test/ChangelogToken.model.t.sol`: 48-operation sequences against an
  independent four-holder balance/allowance ledger. Every step checks balances,
  all allowances, fixed total supply, and absence of tokens at the zero address,
  including successful and reverting operations and self-transfers.

The local factory test checks ERC-20 launch flows. It is not a Uniswap deployment
or swap simulation. The provided protected launch harness requires additional
launch infrastructure and resolved manifest data supplied by the verifier.

## After launch

There are no owner-settable parameters or administrative responsibilities in
the token. The launch operator is responsible for deploying the reviewed
artifact through the intended factory, checking the constructor allocation and
metadata, completing distribution and liquidity setup, and verifying the source
on the explorer. This assignment does not broadcast transactions.

Holders control their own balances and approvals. Spenders can move only what
holders authorize. Holders should review spenders and revoke allowances they
no longer need. Replacing a nonzero approval has the usual ERC-20 transaction
ordering risk: a spender may use the old allowance before the replacement is
confirmed. Setting it to zero and waiting for confirmation before granting a
new amount helps make that change observable. Unlimited approvals remain valid
until explicitly replaced or revoked.

No administrator can reverse mistakes, recover inaccessible tokens, freeze
transfers, or patch deployed code. The launch process remains responsible for
independent adversarial review before release; local tests are not an audit.
See `VALIDATION.md` for the checks actually performed in this workspace.
