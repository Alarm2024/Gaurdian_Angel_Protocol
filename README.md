# Guardian Angel Pro

Guardian Angel Pro is a Solidity rescue and recovery architecture for contracts that need a guarded path to recover ETH, ERC20, ERC721, and ERC1155 assets. The codebase is split into a concrete `GuardianAngel` implementation plus reusable modules that isolate daily-limit accounting and rescue execution concerns.

## Components

### `GuardianAngel`

`contracts/GuardianAngel.sol` is the feature-complete Guardian Angel Pro contract. It owns the operational policy for a deployment:

- owner and pending-owner handoff;
- guardian-controlled emergency withdrawals;
- guardian rotation with a 24-hour timelock;
- pause and unpause controls;
- Chainlink Automation-compatible `checkUpkeep` and `performUpkeep` hooks;
- ETH withdrawal with daily rate limiting;
- ERC20, ERC721, and ERC1155 rescue paths;
- EIP-2612 permit-assisted ERC20 rescue.

In the production contract, `GuardianAngel` is the authority boundary: owner-only actions configure the system, guardian-only actions execute emergency recovery flows, and `nonReentrant` protects external transfer paths.

### `DailyLimitGuard`

`contracts/limits/DailyLimitGuard.sol` is a reusable abstract module for per-asset daily spend accounting. It is designed around UTC day buckets using:

```solidity
block.timestamp / 1 days
```

Instead of storing a reset timestamp and subtracting elapsed time, the guard stores the last used day bucket and the amount spent in that bucket. On a new day, stale spend is overwritten lazily by the first guarded action.

This design has three security and gas benefits:

1. **No timestamp subtraction underflow path** — the module compares day buckets rather than subtracting timestamps.
2. **Bounded timestamp manipulation impact** — validator timestamp drift can only affect transactions close to a day boundary; it cannot create negative elapsed-time behavior.
3. **Cheaper resets** — there is no separate reset transaction and no reset-then-increment sequence. The first action in a new day writes the new bucket and amount directly.

### `RescueExecutor`

`contracts/rescue/RescueExecutor.sol` is a reusable abstract module for asset recovery execution. It centralizes rescue entry points and low-level transfer helpers for:

- native ETH;
- ERC20 transfers;
- ERC20 transfers with EIP-2612 permit approval;
- ERC721 transfers;
- ERC1155 transfers.

The module delegates policy decisions to hooks instead of hard-coding authorization or rate-limit rules. That makes the transfer logic reusable across deployments with different owner, guardian, multisig, timelock, or automation requirements.

## How the modules interact

A modular deployment wires the contracts together with inheritance and hook overrides:

```solidity
contract GuardianAngel is RescueExecutor, DailyLimitGuard {
    function _authorizeRescue(address to) internal view override {
        // owner, guardian, multisig, or timelock policy lives here
    }

    function _enforceDailyLimit(address asset, uint256 amount)
        internal
        override(RescueExecutor, DailyLimitGuard)
    {
        DailyLimitGuard._enforceDailyLimit(asset, amount);
    }
}
```

The interaction is intentionally one-directional:

1. A caller enters a rescue function exposed by `RescueExecutor`.
2. `RescueExecutor` calls `_authorizeRescue(...)` before touching assets.
3. For value-bearing rescue paths, `RescueExecutor` calls `_enforceDailyLimit(asset, amount)`.
4. `DailyLimitGuard` accounts for the current day bucket and reverts if the configured limit would be exceeded.
5. Only after authorization and accounting pass does `RescueExecutor` perform the external transfer.

This keeps checks-before-effects-before-interactions easy to audit: policy and accounting happen before any ETH or token transfer.

## Why the modular design improves security

### Smaller audit surfaces

Each module has one responsibility:

- `GuardianAngel` owns deployment policy and privileged roles.
- `DailyLimitGuard` owns rate-limit accounting.
- `RescueExecutor` owns rescue transfer mechanics.

Separating responsibilities makes it easier to review each risk category independently. Daily-limit bugs can be audited without reading NFT receiver code, and ERC20 transfer behavior can be reviewed without reasoning through guardian rotation.

### Reusable, consistent rescue behavior

Centralizing rescue execution prevents each contract from reimplementing slightly different token-transfer logic. This reduces the chance of inconsistent handling for non-standard ERC20 tokens, missing zero-address checks, or missing events.

### Explicit authorization hooks

`RescueExecutor` does not assume who is allowed to rescue assets. Consumers must implement `_authorizeRescue`, which makes authorization policy explicit at the integration point. This is safer than embedding a single owner-only assumption into reusable transfer code.

### Daily limits run before external calls

The rescue module is designed to enforce limits before external token or ETH transfers. That ordering avoids counting failures as spent and ensures successful transfer attempts have already passed the daily limit gate.

### Day-bucket accounting avoids reset edge cases

`DailyLimitGuard` uses day buckets rather than reset timestamps. This avoids underflow-prone elapsed-time math and removes the need for a privileged reset call. The first transaction in a new bucket updates the bucket and spend in one write.

### Easier extension without rewriting core logic

Future Guardian Angel Pro deployments can add new policy modules, such as multisig authorization, Chainlink-triggered pause rules, allowlisted recovery addresses, or per-token rescue limits, without rewriting low-level rescue transfers.

## Development notes

- Use `GuardianAngel` when you want the full production feature set in one deployment.
- Use `RescueExecutor` and `DailyLimitGuard` when building a smaller custom deployment or when composing these behaviors into an existing protocol contract.
- Keep authorization and accounting hooks before external calls.
- Keep daily limits non-zero when they are meant to be enforced; a zero limit in the reusable guard is intentionally treated as uncapped for compatibility.


## Azure testing and deployment

Use Azure Pipelines for repeatable Foundry checks, Azure Key Vault for deployment secrets, and Azure Pipelines environments for approval-gated releases. This repository includes:

- `foundry.toml` to make Foundry compile contracts from `contracts/` and tests from `test/`;
- `script/DeployGuardianAngel.s.sol`, which deploys `GuardianAngel` from environment-provided guardian, recovery, and daily-limit values;
- `azure-pipelines.yml`, which runs formatting, build, sharded tests, scheduled deep checks, dry-run deployment, and an approval-gated Sepolia broadcast stage;
- `docs/AZURE.md`, which explains the recommended Azure topology, Key Vault secret model, deployment flow, test-scaling strategy, and production safeguards for fuzzing, fork tests, and releases.

## Tests

The test suite includes:

- `test/DailyLimitGuard.t.sol` for direct day-bucket accounting tests;
- `test/GuardianAngelDailyLimit.t.sol` for concrete `GuardianAngel.withdraw()` daily-limit behavior.

Run all tests with:

```bash
forge test
```
