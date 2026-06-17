# 🛡️ Guardian Angel Pro 🪬 🧿

## Enterprise-Grade Asset Rescue Protocol for Solidity

[![GitHub](https://img.shields.io/badge/GitHub-Repository-blue?logo=github)](https://github.com/Alarm2024/Gaurdian_Angel_Protocol)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://github.com/Alarm2024/Gaurdian_Angel_Protocol/blob/main/LICENSE)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.20-informational)](https://soliditylang.org/)
[![Build](https://img.shields.io/badge/Build-Passing-brightgreen)]()
[![Audit](https://img.shields.io/badge/Audit-Pending-orange)]()

---

## Table of Contents

- [Overview](#overview)
- [Core Architecture](#core-architecture)
- [Role Capabilities](#role-capabilities)
- [Threat Mitigations](#threat-mitigations)
- [Quick Start](#quick-start)
- [CI/CD Integration](#cicd-integration)
- [Project Structure](#project-structure)
- [Development Notes](#development-notes)
- [License & Contributing](#license--contributing)

---

## Overview

**Guardian Angel Pro** is a production‑grade, decentralised asset rescue and recovery framework for Solidity smart contracts, developed and maintained by **ELGHALY COMPANY**. It provides protected, auditable paths for recovering **ETH**, **ERC20**, **ERC721**, and **ERC1155** assets from contracts during security incidents, key compromise scenarios, or operational emergencies.

The protocol employs a **defence‑in‑depth** strategy through:
- Role‑based access control with strict privilege separation
- Timelocked governance for critical parameter changes
- Modular architecture for auditability and extensibility
- EIP‑712 typed signatures for cross‑chain replay protection
- Real‑time execution limits to cap exposure

All components are **self‑contained** with zero external dependencies, making the full trust surface auditable in a single codebase.

**Key Philosophy:** The protocol is designed to be **self‑sovereign** — the Owner retains ultimate control while being protected against their own potential mistakes or compromise.

---

## Core Architecture

Guardian Angel Pro follows a **modular, hook‑based design** that separates concerns into three distinct layers, each with a single responsibility. This separation improves security by reducing audit complexity, enabling reusable and consistent rescue behaviour, and making authorisation policies explicit.

### Component Breakdown

| Module | Responsibility | Key Features |
|--------|----------------|--------------|
| **`GuardianAngel.sol`** | Deployment policy & privileged roles | Owner/Guardian handoff, 24h timelocked rotation, pause/unpause, Chainlink Automation hooks, withdrawal paths, asset rescue entry points |
| **`RescueExecutor.sol`** | Asset transfer execution | Native ETH, ERC20 (standard + permit), ERC721, ERC1155 (single + batch) transfers |
| **`DailyLimitGuard.sol`** | Rate‑limit accounting | UTC day‑bucket accounting (no timestamp underflow), automatic reset, zero = unlimited |

#### Module Details

**GuardianAngel** is the feature‑complete production contract. It owns the operational policy:
- Owner and pending‑owner handoff
- Guardian‑controlled emergency withdrawals
- Guardian rotation with a 24‑hour timelock
- Pause and unpause controls
- Chainlink Automation‑compatible hooks (`checkUpkeep` / `performUpkeep`)
- ETH withdrawal with daily rate limiting
- ERC20, ERC721, ERC1155 rescue paths
- EIP‑2612 permit‑assisted ERC20 rescue

**DailyLimitGuard** uses UTC day buckets (`block.timestamp / 1 days`) instead of reset timestamps. This avoids underflow‑prone elapsed‑time math and removes the need for a privileged reset call. The first transaction in a new bucket updates the bucket and spend in one write.

**RescueExecutor** centralises rescue entry points and low‑level transfer helpers, delegating policy decisions to hooks (`_authorizeRescue`, `_enforceDailyLimit`) instead of hard‑coding authorisation. This makes transfer logic reusable across deployments with different owner, guardian, multisig, or automation requirements.

### Execution Flow (Checks‑Effects‑Interactions)


Policy and accounting happen **before** any external transfer, keeping the checks‑effects‑interactions pattern easy to audit and preventing failed attempts from counting against daily limits.

---

## Role Capabilities

Guardian Angel Pro implements a **four‑role authorisation model**:

| Role | Capabilities | Trust Assumption |
|------|--------------|------------------|
| **Owner** | Day‑to‑day operations: withdrawals, limit management, whitelist control, rotation initiation, unpause | Hot wallet or multisig; more exposed but with safeguards |
| **Guardian** | "Break glass" role: rescues, pause/emergency sweeps, veto power over rotations, cancel withdrawals | Independent key held by trusted party or institution |
| **Cold Signer** | Offline key: solely authorises `withdrawSecure()` via EIP‑712 signatures | Hardware wallet or air‑gapped device; minimal exposure |
| **Recovery Address** | Destination address: receives all rescued and swept assets | Secure cold storage or insurance fund |

### Function Access Matrix

| Operation | Owner | Guardian | Cold Signer | Recovery |
|-----------|:-----:|:--------:|:-----------:|:--------:|
| `withdrawSecure()` | ✅ Executes | ❌ | ✅ Signs | ❌ |
| `initiateWithdrawal()` | ✅ | ❌ | ❌ | ❌ |
| `executeWithdrawal()` | ✅ | ❌ | ❌ | ❌ |
| `cancelWithdrawal()` | ✅ | ✅ | ❌ | ❌ |
| `emergencyWithdraw()` | ❌ | ✅ | ❌ | ❌ |
| `rescueERC20()`, `rescueERC721()`, `rescueERC1155()` | ❌ | ✅ | ❌ | ❌ |
| `rescueERC20WithPermit()` | ❌ | ✅ | ❌ | ❌ |
| `pause()` | ✅ | ✅ | ❌ | ❌ |
| `unpause()` | ✅ | ❌ | ❌ | ❌ |
| `initiate*Rotation()`, `finalize*Rotation()` | ✅ | ❌ | ❌ | ❌ |
| `cancel*Rotation()` | ✅ | ✅ | ❌ | ❌ |
| `setDailyLimit()`, `setWhitelist()` | ✅ | ❌ | ❌ | ❌ |

---

## Threat Mitigations

| Threat Vector | Mitigation |
|---------------|------------|
| **Owner Key Compromise** | Guardian can pause and sweep; cold signer independent; daily limit caps losses; rotations cancellable |
| **Guardian Key Compromise** | Cannot withdraw ETH alone; cannot change recovery address without Owner; cannot remove Owner's veto |
| **Cold Signer Compromise** | Requires Owner transaction; daily limit applies; rotatable with Guardian veto |
| **Cross‑Chain Replay** | EIP‑712 domain includes `chainId` and contract address |
| **Signature Replay** | Nonce consumption; deadline bounds |
| **Reentrancy Attacks** | `nonReentrant` modifier; state updates before external calls |
| **Malicious Tokens** | Safe transfer wrappers validate contract existence and return values |
| **DoS Attacks** | No unbounded loops; all operations O(1) or bounded |

---

## Quick Start

### Prerequisites
- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Node.js 16+ (optional)

### Clone & Install

```bash
git clone https://github.com/Alarm2024/Gaurdian_Angel_Protocol.git
cd Gaurdian_Angel_Protocol
forge install
forge build
forge test          # run all tests
forge test -vv      # verbose output
forge coverage      # test coverage

forge script script/DeployGuardianAngel.s.sol \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY

Formatting → Build → Sharded Tests → Deep Checks (scheduled)
  → Deploy (Sepolia) → Dry Run (simulation)
  → Approval Gate (manual) → Broadcast (mainnet)

Gaurdian_Angel_Protocol/
├── contracts/
│   ├── GuardianAngel.sol          # Full deployment contract
│   ├── limits/
│   │   └── DailyLimitGuard.sol    # Reusable daily-limit accounting
│   └── rescue/
│       └── RescueExecutor.sol     # Reusable asset transfer logic
├── test/
│   ├── DailyLimitGuard.t.sol      # Day-bucket accounting tests
│   └── GuardianAngelDailyLimit.t.sol # Withdrawal limit integration tests
├── script/
│   └── DeployGuardianAngel.s.sol  # Deployment script
├── docs/
│   └── AZURE.md                   # Azure CI/CD documentation
├── foundry.toml                   # Foundry configuration
└── azure-pipelines.yml            # Azure DevOps pipeline definition


Here’s the complete professional README in a plain‑text code block. Tap and hold anywhere inside the block, select Select All, then Copy — it’s iPhone‑friendly.

---

```markdown
# 🛡️ Guardian Angel Pro

## Enterprise-Grade Asset Rescue Protocol for Solidity

[![GitHub](https://img.shields.io/badge/GitHub-Repository-blue?logo=github)](https://github.com/Alarm2024/Gaurdian_Angel_Protocol)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://github.com/Alarm2024/Gaurdian_Angel_Protocol/blob/main/LICENSE)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.20-informational)](https://soliditylang.org/)
[![Build](https://img.shields.io/badge/Build-Passing-brightgreen)]()
[![Audit](https://img.shields.io/badge/Audit-Pending-orange)]()

---

## Table of Contents

- [Overview](#overview)
- [Core Architecture](#core-architecture)
- [Role Capabilities](#role-capabilities)
- [Threat Mitigations](#threat-mitigations)
- [Quick Start](#quick-start)
- [CI/CD Integration](#cicd-integration)
- [Project Structure](#project-structure)
- [Development Notes](#development-notes)
- [License & Contributing](#license--contributing)

---

## Overview

**Guardian Angel Pro** is a production‑grade, decentralised asset rescue and recovery framework for Solidity smart contracts, developed and maintained by **ELGHALY COMPANY**. It provides protected, auditable paths for recovering **ETH**, **ERC20**, **ERC721**, and **ERC1155** assets from contracts during security incidents, key compromise scenarios, or operational emergencies.

The protocol employs a **defence‑in‑depth** strategy through:
- Role‑based access control with strict privilege separation
- Timelocked governance for critical parameter changes
- Modular architecture for auditability and extensibility
- EIP‑712 typed signatures for cross‑chain replay protection
- Real‑time execution limits to cap exposure

All components are **self‑contained** with zero external dependencies, making the full trust surface auditable in a single codebase.

**Key Philosophy:** The protocol is designed to be **self‑sovereign** — the Owner retains ultimate control while being protected against their own potential mistakes or compromise.

---

## Core Architecture

Guardian Angel Pro follows a **modular, hook‑based design** that separates concerns into three distinct layers, each with a single responsibility. This separation improves security by reducing audit complexity, enabling reusable and consistent rescue behaviour, and making authorisation policies explicit.

### Component Breakdown

| Module | Responsibility | Key Features |
|--------|----------------|--------------|
| **`GuardianAngel.sol`** | Deployment policy & privileged roles | Owner/Guardian handoff, 24h timelocked rotation, pause/unpause, Chainlink Automation hooks, withdrawal paths, asset rescue entry points |
| **`RescueExecutor.sol`** | Asset transfer execution | Native ETH, ERC20 (standard + permit), ERC721, ERC1155 (single + batch) transfers |
| **`DailyLimitGuard.sol`** | Rate‑limit accounting | UTC day‑bucket accounting (no timestamp underflow), automatic reset, zero = unlimited |

#### Module Details

**GuardianAngel** is the feature‑complete production contract. It owns the operational policy:
- Owner and pending‑owner handoff
- Guardian‑controlled emergency withdrawals
- Guardian rotation with a 24‑hour timelock
- Pause and unpause controls
- Chainlink Automation‑compatible hooks (`checkUpkeep` / `performUpkeep`)
- ETH withdrawal with daily rate limiting
- ERC20, ERC721, ERC1155 rescue paths
- EIP‑2612 permit‑assisted ERC20 rescue

**DailyLimitGuard** uses UTC day buckets (`block.timestamp / 1 days`) instead of reset timestamps. This avoids underflow‑prone elapsed‑time math and removes the need for a privileged reset call. The first transaction in a new bucket updates the bucket and spend in one write.

**RescueExecutor** centralises rescue entry points and low‑level transfer helpers, delegating policy decisions to hooks (`_authorizeRescue`, `_enforceDailyLimit`) instead of hard‑coding authorisation. This makes transfer logic reusable across deployments with different owner, guardian, multisig, or automation requirements.

### Execution Flow (Checks‑Effects‑Interactions)

```

Caller → RescueExecutor.rescueERC20()
→ _authorizeRescue()        ← policy check
→ _enforceDailyLimit()      ← accounting (DailyLimitGuard)
→ _safeTransfer()           ← external transfer (ETH/token)

```

Policy and accounting happen **before** any external transfer, keeping the checks‑effects‑interactions pattern easy to audit and preventing failed attempts from counting against daily limits.

---

## Role Capabilities

Guardian Angel Pro implements a **four‑role authorisation model**:

| Role | Capabilities | Trust Assumption |
|------|--------------|------------------|
| **Owner** | Day‑to‑day operations: withdrawals, limit management, whitelist control, rotation initiation, unpause | Hot wallet or multisig; more exposed but with safeguards |
| **Guardian** | "Break glass" role: rescues, pause/emergency sweeps, veto power over rotations, cancel withdrawals | Independent key held by trusted party or institution |
| **Cold Signer** | Offline key: solely authorises `withdrawSecure()` via EIP‑712 signatures | Hardware wallet or air‑gapped device; minimal exposure |
| **Recovery Address** | Destination address: receives all rescued and swept assets | Secure cold storage or insurance fund |

### Function Access Matrix

| Operation | Owner | Guardian | Cold Signer | Recovery |
|-----------|:-----:|:--------:|:-----------:|:--------:|
| `withdrawSecure()` | ✅ Executes | ❌ | ✅ Signs | ❌ |
| `initiateWithdrawal()` | ✅ | ❌ | ❌ | ❌ |
| `executeWithdrawal()` | ✅ | ❌ | ❌ | ❌ |
| `cancelWithdrawal()` | ✅ | ✅ | ❌ | ❌ |
| `emergencyWithdraw()` | ❌ | ✅ | ❌ | ❌ |
| `rescueERC20()`, `rescueERC721()`, `rescueERC1155()` | ❌ | ✅ | ❌ | ❌ |
| `rescueERC20WithPermit()` | ❌ | ✅ | ❌ | ❌ |
| `pause()` | ✅ | ✅ | ❌ | ❌ |
| `unpause()` | ✅ | ❌ | ❌ | ❌ |
| `initiate*Rotation()`, `finalize*Rotation()` | ✅ | ❌ | ❌ | ❌ |
| `cancel*Rotation()` | ✅ | ✅ | ❌ | ❌ |
| `setDailyLimit()`, `setWhitelist()` | ✅ | ❌ | ❌ | ❌ |

---

## Threat Mitigations

| Threat Vector | Mitigation |
|---------------|------------|
| **Owner Key Compromise** | Guardian can pause and sweep; cold signer independent; daily limit caps losses; rotations cancellable |
| **Guardian Key Compromise** | Cannot withdraw ETH alone; cannot change recovery address without Owner; cannot remove Owner's veto |
| **Cold Signer Compromise** | Requires Owner transaction; daily limit applies; rotatable with Guardian veto |
| **Cross‑Chain Replay** | EIP‑712 domain includes `chainId` and contract address |
| **Signature Replay** | Nonce consumption; deadline bounds |
| **Reentrancy Attacks** | `nonReentrant` modifier; state updates before external calls |
| **Malicious Tokens** | Safe transfer wrappers validate contract existence and return values |
| **DoS Attacks** | No unbounded loops; all operations O(1) or bounded |

---

## Quick Start

### Prerequisites
- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Node.js 16+ (optional)

### Clone & Install

```bash
git clone https://github.com/Alarm2024/Gaurdian_Angel_Protocol.git
cd Gaurdian_Angel_Protocol
forge install
forge build
forge test          # run all tests
forge test -vv      # verbose output
forge coverage      # test coverage
```

Deployment

```bash
forge script script/DeployGuardianAngel.s.sol \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY
```

Environment variables required:

· RPC_URL — JSON‑RPC endpoint (e.g., Infura, Alchemy)
· PRIVATE_KEY — Deployer wallet private key
· ETHERSCAN_API_KEY — For contract verification (optional)

---

CI/CD Integration

Guardian Angel Pro ships with an enterprise‑grade Azure DevOps pipeline topology:

Pipeline Stages

```
Formatting → Build → Sharded Tests → Deep Checks (scheduled)
  → Deploy (Sepolia) → Dry Run (simulation)
  → Approval Gate (manual) → Broadcast (mainnet)
```

Key Features

· forge fmt --check — automated formatting validation
· Sharded test execution — parallel runs for speed
· Scheduled deep checks — weekly security and fuzzing scans
· Approval‑gated releases — manual approval required for mainnet broadcasts
· Azure Key Vault — secure management of deployment secrets

See docs/AZURE.md for full Azure topology, Key Vault secret model, and production safeguards.

---

Project Structure

```
Gaurdian_Angel_Protocol/
├── contracts/
│   ├── GuardianAngel.sol          # Full deployment contract
│   ├── limits/
│   │   └── DailyLimitGuard.sol    # Reusable daily-limit accounting
│   └── rescue/
│       └── RescueExecutor.sol     # Reusable asset transfer logic
├── test/
│   ├── DailyLimitGuard.t.sol      # Day-bucket accounting tests
│   └── GuardianAngelDailyLimit.t.sol # Withdrawal limit integration tests
├── script/
│   └── DeployGuardianAngel.s.sol  # Deployment script
├── docs/
│   └── AZURE.md                   # Azure CI/CD documentation
├── foundry.toml                   # Foundry configuration
└── azure-pipelines.yml            # Azure DevOps pipeline definition
```

---

Development Notes

· Use GuardianAngel when you want the full production feature set in one deployment.
· Use RescueExecutor and DailyLimitGuard when building a smaller custom deployment or composing these behaviours into an existing protocol contract.
· Always place authorisation and accounting hooks before external calls.
· A daily limit of 0 in the reusable guard is intentionally treated as unlimited for compatibility.
· The modular design:
  · Reduces audit surfaces (one responsibility per module)
  · Ensures consistent rescue behaviour (centralised transfer logic)
  · Makes authorisation explicit (hooks)
  · Enforces limits before transfers (prevents counting failures)
  · Uses day‑bucket accounting (avoids reset edge cases and underflow)
  · Allows easy extension without rewriting core logic

---

License & Contributing

This project is licensed under the MIT License — see the LICENSE file for details.

We welcome contributions! Please review our Contributing Guidelines and Code of Conduct before submitting pull requests.

Reporting Security Issues:
Please do not file public issues for security vulnerabilities. Follow our Security Policy for responsible disclosure.

---

Resources

· GitHub Repository: https://github.com/Alarm2024/Gaurdian_Angel_Protocol
· Documentation: docs.guardianangel.io
· Security Policy: SECURITY.md

---

Built by ELGHALY COMPANY with ❤️ for the DeFi community

Next‑gen automated safety layer for Solidity. Hardened asset recovery, modular policy enforcement, and real‑time execution limits. Secure your protocol before the exploit happens.
