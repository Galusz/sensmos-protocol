<img src="logo.png" alt="Sensmos" height="64">

# GALU Emission Policy

> Reference document — the implementation MUST match it; in case of conflict, this document wins.
> **The single source of truth for the pool is the GALU physically held in the `SensmosRewardPool` contract.** There is no virtual reserve.

Contract: [`SensmosRewardPool.sol`](SensmosRewardPool.sol) · deployed on **Polygon** at `0x9d797D0E642D9EADdbDbD34ACFCFd07bf0043c6C`.

---

## 1. Core principle

**An address's entitlement can only grow by as much as the pool has PHYSICAL coverage in GALU.** Solvency by design — a double safeguard:

- `claim` requires `balanceOf(pool) ≥ payout`,
- `mintEpoch` requires `balanceOf(pool) ≥ totalEntitlement − totalClaimed` (measured after mint and burn).

## 2. Three pool inflows (and two outflows)

| Source | What | Inflationary? | Role |
|--------|------|---------------|------|
| **mint** (`mintEpoch`) | fresh GALU, up to `MAX_SUPPLY` | yes (bootstrap) | **foundation — always minted up to the cap** |
| **recycle** | in-network spending (query / subscription / message) | no | into the reserve → 5% drip |
| **external** (`fundPool`) | revenue (e.g. data sales) → GALU bought on the market | **no** | into the reserve → 5% drip |

Outflows: **claim** (reward withdrawal) and **deposit** (a user adds their own GALU to spend in the network).

> recycle and external land in one **reserve**. The drip is 5% of that reserve per epoch — this smooths spikes: a large one-off data sale isn't paid out in a single epoch, it trickles at ~5%/epoch. recycle is a re-allocation (GALU spent by a node never leaves the contract); external is a real inflow via `fundPool`.

## 3. Parameters

| Parameter | Value | Type |
|-----------|-------|------|
| `BASE_REWARD` | 10 GALU/node/epoch | backend config |
| `THRESHOLD_NODES` | 4000 | backend config |
| `MAX_EPOCH_MINT` | 40,000 GALU | **contract constant** (per-epoch mint ceiling + breaker) |
| `MAX_SUPPLY` | 40,000,000 | **contract constant, immutable** |
| `RELEASE_RATE` | **5%** of reserve/epoch | backend config (recycle + external drip) |
| `BURN_RATE` | **10%** of the drip | backend config (burned, deflation) |
| `MAX_SPAN` | **7** | **contract constant** (max epoch-number jump) |
| `MIN_EPOCH_INTERVAL` | **10h** | **contract constant** (anti call-spam) |
| `TEAM_FEE` | 5% of the **pool** (Model B, in the tree) | backend config |
| `PROVIDER_SHARE` | 30% of a data spend → data provider | backend config |
| `MIN_PINGS` | 24 pings/epoch | backend config (minimum uptime) |
| counted nodes | **trusted** only | anti-sybil |
| MIN_REWARD / per-node cap / credit | none | — |

## 4. Epoch mechanics

```
trusted   = trusted, active nodes with ping_count ≥ MIN_PINGS
per_node  = BASE                       if trusted ≤ THRESHOLD
          = BASE × THRESHOLD / trusted  if trusted > THRESHOLD       (decay)

# MINT — always full, up to the cap
fresh_mint = min(trusted × per_node, MAX_EPOCH_MINT, MAX_SUPPLY − minted_target)
minted_target += fresh_mint

# DRIP — 5% of the shared reserve (recycle + external)
reserve  = recycled_pending + external_pending      # physical GALU already in the pool
release  = floor(RELEASE_RATE × reserve)            # max 5%/epoch (gross)
burn     = floor(BURN_RATE × release)               # 10% of the drip → _burn (deflation)
pool     = fresh_mint + (release − burn)            # mint + net bonus

# the reserve is drawn by `release` (recycle first, then external)
recycled_used = min(release, recycled_pending)
external_used = release − recycled_used

# split — Model B: team gets 5% of the POOL, nodes share the rest by weight
team      = floor(pool × TEAM_FEE)
node_pool = pool − team
reward_i  = floor(node_pool × weight_i / Σweights)  # may exceed BASE (bonus)
dust      = node_pool − Σreward_i                   # stays physically in the pool

entitlement_i (lifetime) += reward_i;  team += its 5%
totalEntitlement = Σ all lifetimes                  # → guard in the contract
```

Weight: `scarcity × categories × uptime × activity × uplink` (max ≈ 2.14× at full uptime).
Scarcity is geographic and follows the coverage-radius ladder: neighbours shrink the radius (200 km rung allows ≤2, each tighter rung allows one more), and the multiplier derives from the rung — **200 km → 1.5×, 150 → 1.4×, … 10 → 1.0×, … 1 km → 0.8× (floor)**. Density is priced exactly once; redundant coverage still lands below 1.0 (penalized, not just un-bonused). Uplink is a shared-IP factor: ~0.95 each for 2 nodes behind one egress IP, gently decaying with more — keyed to hard network facts, not the wallet, so new wallets don't reset it.

## 5. On-chain mint — catch-up + mint breaker

`pool_state` tracks `minted_target` (intent) and `minted_confirmed` (on-chain mirror).
Submit computes `mintToPool = minted_target − totalSupply(on-chain)`, clamped to `[0, MAX_EPOCH_MINT × span]`.

`mintEpoch(epoch, mintToPool, burnAmount, newTotalEntitlement, root)` enforces, in order:
- `epoch > currentEpoch`, `span = epoch − currentEpoch ≤ MAX_SPAN`,
- `block.timestamp ≥ lastEpochTime + MIN_EPOCH_INTERVAL` (anti call-spam),
- **mint breaker:** `mintToPool ≤ MAX_EPOCH_MINT × span`,
- mints, then burns `burnAmount`,
- **solvency guard:** `balanceOf(pool) ≥ newTotalEntitlement − totalClaimed`.

A skipped submit self-heals in the next epoch (limits scale with `span`).

## 6. Cumulative claim

- Leaf: `keccak256(address, lifetimeWei)`, where `lifetimeWei = floor(lifetime × 1e6) × 1e12`.
- `lifetime = total_earned + total_deposited − total_spent` (GROSS; the contract subtracts what was already claimed).
- `claim(cumulativeAmount, proof)` pays `cumulativeAmount − claimedTotal[addr]`.
- One active root; a new root replaces the old one. Proofs are served ONLY from an epoch confirmed on-chain.

## 7. Anti double-spend

`available` (spendable) = `earned + deposited − spent − claimed`. `claimed` is fed by the on-chain `Claimed` event listener. There is no credit, so `available` never goes below 0. The Merkle leaf stays GROSS.

## 8. Invariants (mandatory tests)

```
on-chain mint:   balanceOf ≥ totalEntitlement − totalClaimed         # GUARD (after mint+burn)
on-chain mint:   mintToPool ≤ MAX_EPOCH_MINT × span  (span ≤ MAX_SPAN)# BREAKER (inflation)
on-chain mint:   block.timestamp ≥ lastEpochTime + MIN_EPOCH_INTERVAL # anti call-spam
on-chain claim:  balanceOf ≥ payout                                  # safeguard
consistency:     Σ(leaf_i) == totalEntitlement (to the wei)          # precision
mass:            balanceOf ≥ Σ(leaf_i − claimedTotal_i)              # coverage
```

## 9. Phases

| Phase | Condition | fresh_mint | Pool / reward |
|-------|-----------|-----------|---------------|
| Ramp | trusted < 4000 | trusted × BASE | mint + drip (reward ≥ BASE) |
| Decay | trusted > 4000 | 40k (ceiling) | mint + drip (per-node shrinks: 40k/nodes + bonus) |
| Post-cap | minted = 40M | **0** | drip only (recycle + external) |

After the cap, the network lives on recycle and `fundPool` revenue — "real yield": rewards backed by real value, buy pressure on GALU, zero inflation. A dead network with no revenue → rewards → 0.

## 10. Anti-sybil

Only **trusted** nodes (BLE attestation ceremony) with `≥ MIN_PINGS` count toward emission. Attestation MUST be enabled in production.

## 11. Audit plan

- **Now (testnet/launch):** OpenZeppelin-based contract, tests (double-claim, cap, solvency guard, mint breaker, catch-up, `Σleaves == totalEntitlement` precision, minimum uptime, access control), attestation on.
- **Before mainnet value:** owner → multisig (Gnosis Safe) + timelock, audit, Polygonscan verification.
- **What an auditor attacks:** solvency (guard + balanceOf), inflation (mint breaker + cap), root trust (public leaves + guard), sybil (trusted + minimum uptime), double-spend (`available − claimed`, no credit).
