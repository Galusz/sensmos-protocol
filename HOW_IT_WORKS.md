<img src="logo.png" alt="Sensmos" height="64">

# How the GALU economy works

> The path of GALU: from a sensor reading, through the epoch and the split, to a wallet withdrawal.
> Full policy: [EMISSION_MODEL.md](EMISSION_MODEL.md).

## TL;DR

Nodes collect data and ping → once a day the epoch weighs every trusted node (with minimum uptime) →
**mint always tops up the full rate, and in-network turnover (recycle + data sales) adds a bonus** →
the pool is split: 95% nodes (by weight) + 5% team → the backend mints (with a mint breaker and a
solvency guard) and publishes a cumulative Merkle root → users claim whenever they want.

## 1. The node collects data and pings

An ESP32 sends a signed batch (pv_power, pm25, grid_v…) roughly every 30 s. The backend counts pings —
max **96/day**. pings/96 = **uptime**. A node needs **≥ 24 pings** to count toward an epoch.

## 2. The epoch weighs each node (once a day)

Only **trusted** nodes (after the BLE attestation — anti-sybil) with ≥ 24 pings.
```
weight = scarcity × categories × uptime × activity × uplink   (max ≈ 2.14×)
```
- **scarcity** — geographic, linear **1.5 → 0.8**: alone in the region = 1.5, dense area = below 1.0 (penalty).
- **uplink** — shared-IP factor: 2 nodes on one connection ≈ 0.95 each, decaying gently with more; keyed to the egress IP, not the wallet.

## 3. The pool forms — mint (always) + bonus (5% of the reserve)

```
per_node   = 10 (BASE)            if trusted ≤ 4000
           = 10 × 4000 / trusted  if trusted > 4000   (decay)
fresh_mint = min(trusted × per_node, 40k, cap_left)    ← full mint, ALWAYS
reserve    = recycled + external                       ← shared pot (turnover + data sales)
release    = 5% × reserve                              ← gross bonus, max 5%/epoch
burn       = 10% × release                             ← burned (deflation)
pool       = fresh_mint + (release − burn)             ← net bonus
```
Mint is the foundation; recycle and data sales add a bonus. Early nodes get mint + a sizeable bonus.

## 4. The split — 95% nodes, 5% team

```
team      = pool × 5%             (Model B — from the pool, in the Merkle tree like a normal address)
node_pool = pool − team
reward_i  = node_pool × (weight_i / Σweights)   # a share; MAY exceed BASE (turnover premium)
```
Rounding dust stays in the pool.

## 5. Where the GALU in the pool comes from — three sources

- **mint** — fresh, up to 40M, always full until the cap is reached (bootstrap).
- **recycle** — node spending (query/sub/msg) returns to the reserve → 5% drip.
- **external (`fundPool`)** — revenue (data sales) → GALU bought on the market → reserve → 5% drip.
  Note: external is GALU that already exists (previously minted, bought on the market) — not a new mint.

## 6. On-chain mint (catch-up + mint breaker)

`mintEpoch(epoch, mintToPool, burnAmount, totalEntitlement, root)`:
- `mintToPool = minted_target − totalSupply(on-chain)` (catch-up — a skipped submit self-heals),
- **mint breaker:** `mintToPool ≤ 40k × span` (caps inflation if the backend key is compromised),
- **guard:** `balanceOf ≥ totalEntitlement − totalClaimed` after mint and burn (protects solvency),
- only then mints, burns and sets the root.

## 7. Withdrawal (claim) — cumulative

`claim(lifetime_total, proof)`:
- verifies the proof against the **current** root,
- pays the **difference** `lifetime_total − claimedTotal[addr]`,
- checks `balanceOf(pool) ≥ payout`.

One transaction collects the whole backlog. Proofs are served only from an epoch **confirmed on-chain**.

## 8. Spending and deposit

- `available` (spendable) = `earned + deposited − spent − claimed`. Subtracts withdrawals (anti double-spend).
- **No credit** — `available` never drops below 0.
- `deposit(amount)` — move GALU from your wallet (after `approve`) into the pool to spend in the network.

## 9. Lifecycle phases

| Phase | Condition | fresh_mint | Pool / reward |
|-------|-----------|-----------|---------------|
| Ramp | < 4000 nodes | trusted × 10 | mint + bonus → reward ≥ 10 |
| Decay | > 4000 nodes | 40k (ceiling) | per-node mint shrinks (40k/nodes) + bonus |
| Post-cap | 40M minted | **0** | bonus only (recycle + revenue) |

After the cap, an active + revenue-generating network keeps paying rewards; a dead one with no revenue dries up to zero. Team gets 5% in every phase.

## 10. Parameters

```
BASE_REWARD  = 10 GALU/node/epoch
THRESHOLD    = 4000 nodes (decay threshold)
MAX_EMISSION = 40,000 GALU/epoch (mint ceiling + breaker — contract constant)
MAX_SUPPLY   = 40,000,000 GALU (hard cap — immutable)
RELEASE_RATE = 5% of reserve/epoch (recycle + external drip)
BURN_RATE    = 10% of the drip (deflation)
TEAM_FEE     = 5% of the pool (Model B)
PROVIDER     = 30% of a data spend → provider; the rest → recycle
MIN_PINGS    = 24 pings/day (minimum uptime)
counted nodes = trusted only (anti-sybil)
```

## 11. Security / solvency

- **on-chain mint:** guard `balanceOf ≥ entitlement − claimed` + mint breaker `mint ≤ 40k×span`.
- **on-chain claim:** `balanceOf ≥ payout`; `ERC20Capped` enforces the 40M cap.
- **anti double-spend:** `available` subtracts `claimed` (from the `Claimed` event listener); no credit.
- **anti-sybil:** trusted nodes only + a minimum of 24 pings.
- **anti-desync:** catch-up mint from `totalSupply`; proofs only from a confirmed epoch.
- **precision:** leaf = `floor(lifetime × 1e6) × 1e12`; `Σleaves == totalEntitlement` to the wei.
- **cumulative:** `claimedTotal` is monotonic → no double-claim.
