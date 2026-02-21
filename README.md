# Vesting Settlement Vault

Unified BTX settlement contract for linear vesting and staking distributions on BNB Chain.

This contract manages:
- Linear vesting staking (principal + reward combined into a single vesting stream)
- Merkle-based vesting distributions for non-staking pools
- Gas-bounded batch claiming via per-user cursor

---

## Network

- Chain: BNB Smart Chain (Mainnet)
- Contract Name: `VestingSettlementVault`
- Deployed Address:  
  `0x46ea706c9462A78D0921eE822cc7c48de649b922`

---

## Core Design

### 1. Linear Vesting Model
Each staking or allocation entry creates an independent vesting position.

Total Vesting Amount: baseAmount * multiplier / 10000

Example:
- Multiplier: `10980`
- Result: `1.098x` total vesting amount
- Equivalent to 9.8% over 365 days

Vesting releases linearly per second.

---

### 2. Pool Architecture

- Staking Pools  
  Users stake BTX. Principal and reward are released together over the vesting duration.

- Non-Staking Pools  
  Users start vesting via Merkle proof validation.  
  One-time join per `(user, pool, round)`.

Each staking round update increments `currentRoundId`.

---

### 3. Claiming Mechanism

- Batch-limited scanning (`claimBatchLimit`, default 200)
- Round-robin cursor per user per pool
- Prevents unbounded gas growth for users with many vesting entries
- Completed entries are removed using swap-pop

---

### 4. Administrative Controls

- Owner-controlled pool creation and round registration
- Round-level pause
- Global pause
- Owner-funded settlement pool
- Admin token recovery (including BTX), disabled while paused by policy

Ownership is intended to be transferred to a multisig after deployment.

---

## Security Model

- Solidity ^0.8.20
- OpenZeppelin (Ownable2Step, ReentrancyGuard, Pausable, SafeERC20, MerkleProof)
- No minting logic
- No external price feeds
- No upgradeability proxy
- Deterministic linear vesting calculation
