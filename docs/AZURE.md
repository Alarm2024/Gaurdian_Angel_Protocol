# Azure testing and deployment guide

This guide describes a practical Azure setup for scaling Guardian Angel Pro testing and deploying the modular contracts safely. It assumes the protocol is composed from `GuardianAngel`, `DailyLimitGuard`, and `RescueExecutor`, with Foundry as the Solidity toolchain.

## Target Azure topology

| Layer | Azure service | How to use it for Guardian Angel Pro |
| --- | --- | --- |
| Source-controlled CI/CD | Azure Pipelines | Run deterministic checks on pull requests, deeper checks on `main`, and gated deployments from release branches or tags. |
| Secret custody | Azure Key Vault | Store RPC URLs, deployer keys, Etherscan keys, guardian/recovery addresses, and per-network daily limits as secrets. |
| Scalable execution | Microsoft-hosted agents first; VM Scale Set agents when needed | Use hosted agents for normal PR checks, then move long fuzz/fork/invariant workloads to VMSS agents with larger CPU/RAM and parallel capacity. |
| Deployment governance | Azure Pipelines environments | Require approvals, branch policies, and deployment history for Sepolia, staging, and mainnet. |
| Artifacts and traceability | Pipeline artifacts | Retain `out/`, `cache/`, `broadcast/`, gas reports, coverage reports, and deployment manifests for every run. |
| Operations | Azure Monitor, Log Analytics, and Action Groups | Alert on failed scheduled tests, failed deployments, or missed operational automation checks. |

## Recommended pipeline stages

### 1. Pull-request validation

Keep pull-request feedback fast and deterministic:

1. Install or restore Foundry.
2. Run `forge fmt --check`.
3. Run `forge build`.
4. Run focused unit tests such as `DailyLimitGuard` and `GuardianAngel` daily-limit tests.
5. Publish ABI/bytecode artifacts from `out/` for reviewer inspection.

### 2. Main-branch quality gate

After merge, run broader checks that may be too expensive for every PR:

- full `forge test -vvv`;
- gas snapshots with `forge snapshot`;
- coverage with `forge coverage` if your chosen runner has the required tooling;
- ABI and bytecode artifact publication.

### 3. Nightly security jobs

Use a scheduled Azure Pipeline for high-signal security testing:

- high-run fuzzing with `FOUNDRY_FUZZ_RUNS=10000` or higher;
- invariant tests for guardian authorization, daily-limit accounting, and rescue paths;
- fork tests against Sepolia or an Ethereum mainnet fork using Key Vault-backed RPC URLs.

### 4. Release deployment

Use an approval-gated environment for every network:

1. Run a dry-run `forge script` without `--broadcast`.
2. Require environment approval.
3. Broadcast the deployment.
4. Verify contracts when `ETHERSCAN_API_KEY` is present.
5. Publish `broadcast/` and a deployment manifest as artifacts.

## Key Vault secret model

Create separate Key Vault secrets for each network. Avoid sharing a deployer key between testnet and production.

| Secret | Example variable | Notes |
| --- | --- | --- |
| RPC endpoint | `SEPOLIA_RPC_URL` | Use per-network RPC credentials with rate limits and usage monitoring. |
| Deployer key | `SEPOLIA_DEPLOYER_PRIVATE_KEY` | Prefer a dedicated, low-balance deployer. Rotate after production deployments. |
| Verification key | `ETHERSCAN_API_KEY` | Scope and rotate according to your explorer provider policy. |
| Guardian address | `SEPOLIA_GUARDIAN_ADDRESS` | Should point to the intended guardian or guardian multisig. |
| Recovery address | `SEPOLIA_RECOVERY_ADDRESS` | Should point to a hardened recovery wallet or multisig. |
| Daily limit | `SEPOLIA_DAILY_LIMIT_WEI` | Store as wei to avoid decimal conversion mistakes in CI. |

In Azure Pipelines, link the Key Vault to a variable group or fetch secrets in an `AzureKeyVault@2` step. Mark all secret variables as secret and never echo them.

## Deployment command

The included deployment script reads `GUARDIAN_ADDRESS`, `RECOVERY_ADDRESS`, and `DAILY_LIMIT_WEI` from the environment:

```bash
forge script script/DeployGuardianAngel.s.sol:DeployGuardianAngel \
  --rpc-url "$RPC_URL" \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --broadcast \
  --verify
```

Run the same command without `--broadcast` in the dry-run stage. Store `broadcast/` after both dry-run and broadcast so reviewers can compare simulated and actual deployment metadata.

## Scaling Foundry tests on Azure

Start with one Microsoft-hosted `ubuntu-latest` job. Scale in this order:

1. **Path sharding**: run independent jobs for `test/DailyLimitGuard.t.sol`, `test/GuardianAngelDailyLimit.t.sol`, and future rescue/invariant suites.
2. **Profile sharding**: use Foundry profiles for `ci`, `nightly`, and `fork` with different fuzz runs and RPC requirements.
3. **VM Scale Set agents**: use larger or autoscaled agents for long fuzzing and fork tests.
4. **Scheduled jobs**: keep expensive tests off the PR critical path, but run them nightly and before releases.

## Production safeguards

- Require branch policies before deployment stages can run.
- Require manual approval by someone other than the author of the deployment commit.
- Dry-run every deployment before broadcast.
- Verify constructor arguments and daily-limit values in the pipeline summary before approval.
- Publish deployment artifacts immutably.
- Keep deployer accounts low-balance and network-specific.
- Prefer guardian and recovery multisigs for production deployments.
- Configure Azure Monitor alerts for failed nightly tests, failed deployments, and stale deployment pipelines.
