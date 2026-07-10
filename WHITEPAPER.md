<img src="logo.png" alt="Sensmos" height="72">

# Sensmos — Whitepaper

**A decentralized sensor network that measures the real world, hands the data back to the people who produce it, and rewards real physical contribution with the GALU token.**

> Version 1.0 · GALU on Polygon · Contract [`0x9d797D0E642D9EADdbDbD34ACFCFd07bf0043c6C`](https://polygonscan.com/token/0x9d797D0E642D9EADdbDbD34ACFCFd07bf0043c6C)
> This document is descriptive, not financial advice. Parameters quoted are the deployed values and may be tuned by the operator (see §6, §10).

---

## Abstract

Big companies measure highways and city centres. Almost nobody measures *your* street — its power quality, its connectivity, its air. Sensmos turns a cheap ESP32 into a sensor node that measures the real world locally, publishes it to a shared live map, can trade data peer-to-peer, and earns **GALU** for genuine, attested contribution. The same nodes also form a measurement mesh: they probe each other and public services across countries (ICMP, TCP, DNS, HTTP), producing a live picture of internet health as seen **from real homes, not datacenters** — a second, network-intelligence plane of the same fabric. There is no cloud dependency for the device, identity is generated on-chip, and the reward economy is *physically backed* on-chain: every unit of reward is covered by tokens actually held in the contract — there is no virtual reserve. This paper describes the network, its architecture, its anti-sybil model, and the GALU emission economy exactly as deployed.

---

## 1. The problem

Environmental, grid and connectivity data is concentrated in the hands of a few institutions, collected where it is commercially convenient, and rarely returned to the people it describes. Meanwhile a hobbyist with a €5 microcontroller can measure their immediate surroundings better than any satellite — but has no shared fabric to publish into, no incentive to keep a node alive, and no way to prove the reading is real rather than spoofed.

Sensmos addresses three gaps at once:

1. **A fabric** — a live, public map where every node's public readings become a shared picture of an area.
2. **An incentive** — a token that rewards uptime and *scarcity of coverage* (measuring where nobody else does), not speculation.
3. **Proof of physicality** — a device-attestation ceremony so that one reward identity equals one real node, not a simulator farm.

---

## 2. The network

### Nodes and entities
A node publishes readings as **entities**, grouped by an `entity_id` prefix:

| Prefix | Meaning | On the map? | Rewarded? |
|--------|---------|-------------|-----------|
| `pub.*` | native measurements from a network whitelist (power, climate, signal…) | yes | yes |
| `own.*` | your custom / integration-fed values | shown as the node's own data, no history | no |
| `sub.* · get.* · msg.*` | subscriptions, web fetches, peer messages | local buffer | no |
| `tmp.*` | scratch buffer for on-device scripts | no | no |

### The live map
Every public reading feeds a live map, an events feed and a value heatmap. Each node is rendered with a **coverage** area whose radius is purely density-driven: a node claims a tighter radius only if enough real neighbours surround it (the neighbour target grows as the radius shrinks), so a lone node in an unserved region covers a wide area while a dense cluster collapses to tight circles.

### The network plane (checknet)
Besides sensing, every node participates in a **measurement mesh**: it pings peer nodes in other countries and a set of public/anycast targets (ICMP), and runs lightweight **TCP connect**, **DNS resolve + integrity** and **HTTP status/TTFB** probes. The flagship measurement is the **home-to-home punch**: the backend only introduces a pair of nodes (UDP hole punching), then the probe exchange runs **directly between the two homes** — real RTT, jitter and loss with no server in the measurement path. Results are physically validated (an RTT faster than light-in-fiber over the claimed distance is rejected; silent paths are traced with reverse-DNS geo-validation of the last hop) and aggregated into country↔country latency bands rendered live on the map, plus per-node network scores. Because probes originate from real household connections rather than datacenters, the resulting picture of latency, reachability and DNS integrity reflects the internet **as people actually experience it** — a vantage point commercial monitoring networks cannot buy. Directed monitoring (watching *your own* endpoint from many countries at once) is built on this same plane — see roadmap (§9).

### Peer-to-peer data market
A node can **subscribe** to another node's readings (`sub.*`), billed daily in GALU, with a private prefix the backend never learns. This is the demand side of the economy: data that has value to someone flows directly between devices.

---

## 3. Architecture

```
ESP32 node ──signed batch──▶ Backend ──▶ PostgreSQL
   ▲  │ (local HTTP API,                    │
   │  │  BLE provisioning)        ┌─────────┴─────────┐
   │  ▼                           ▼                   ▼
 Home Assistant            Live map / API        Polygon
 / ESPHome                 (browser, app)      (GALU contract)
```

- **Firmware (Arduino-ESP32).** Reads sensors, runs an **edge script engine** — up to four-step rules (`if → action`: webhook, push, web-fetch, ping/monitor, message to another node) that execute locally with no cloud. Exposes a local HTTP API on the LAN.
- **Backend (Node.js · PostgreSQL · ethers v6).** Ingests signed batches over WebSocket, runs the daily *epoch* (scoring + reward pool + Merkle), serves the map/leaderboard/stats, and submits roots on-chain.
- **Mobile app (Flutter).** Self-custody wallet, BLE node onboarding, the live map, claim/deposit.
- **Home Assistant integration (HACS).** Brings node data into HA and feeds HA data back to the node — fully local, no broker.

---

## 4. Identity, trust & anti-sybil

- **On-device identity.** Each node generates a `secp256k1` keypair locally and **signs every data batch**. The private key never ships in the firmware image and never leaves the chip.
- **App-proof geolocation.** A node's position is set only from the companion app's phone GPS captured **inside the attestation ceremony** (the proof anchor), optionally fuzzed 200–800 m for privacy; the human-readable city is computed server-side. The claimed position is additionally **cross-checked against the node's network egress** (geo-IP country and distance) — a GPS reading inconsistent with where the node actually connects from is rejected. Position cannot be typed in by hand.
- **Device attestation.** A timed Bluetooth ceremony with a dual signature proves `1 device_id = 1 physical node`, defeating simulator farms. **Only attested ("trusted") nodes count toward emission.**
- **Signed control plane.** Backend→node commands (reboot, delete, update) are signed with the network key over a single-use nonce, and firmware updates are delivered over signed OTA: the node verifies the SHA-256 and signature before flashing, and a failed update rolls back to the previous image automatically.
- **Shared-uplink cap.** Reward weight includes a factor keyed to the node's **public egress IP**: two nodes behind one uplink keep ~0.95 each, and the factor decays gently as more nodes share the same IP. Crucially it keys on hard network facts, **not on the wallet** — registering new wallets does not reset it. Combined with geographic scarcity (§5) this makes co-located node farming unprofitable while leaving genuine multi-node homes essentially untouched.

Together these make spoofing expensive: to fake rewards you would need real hardware, a real key, a real phone at a real location, passing a real-time challenge — and each additional co-located device earns visibly less.

---

## 5. The GALU economy

### Core principle
**An address's lifetime entitlement can only grow by as much as the pool has physical coverage in GALU.** Solvency is enforced on-chain twice: a claim requires `balanceOf(pool) ≥ payout`, and minting requires `balanceOf(pool) ≥ totalEntitlement − totalClaimed` after the mint. There is no virtual reserve — the pool *is* the GALU held in the contract.

### The epoch (once per ~24 h)
For every trusted, active node with at least `MIN_PINGS` pings:

```
weight     = scarcity × categories × uptime × activity × uplink
per_node   = BASE                       if trusted ≤ THRESHOLD
           = BASE × THRESHOLD / trusted  if trusted > THRESHOLD   (decay)
fresh_mint = min(trusted × per_node, MAX_EPOCH_MINT, cap_left)    ← always full to the cap
reserve    = recycled + external                                 ← physical GALU pot
release    = RELEASE_RATE × reserve                              ← a drip, max 5%/epoch
burn       = BURN_RATE × release                                 ← deflation
pool       = fresh_mint + (release − burn)
team       = TEAM_FEE × pool                                     ← Model B (in the Merkle tree)
reward_i   = (pool − team) × weight_i / Σweights                 ← a share; may exceed BASE
```

A node's reward is a **share of the pool by weight** — a better-placed, higher-uptime node takes a bigger slice at the expense of weaker ones, not by printing new tokens.

The weight factors, exactly as deployed:

- **scarcity** is *geographic* and derives directly from the coverage-radius ladder. The radius algorithm walks down from 200 km, counting live neighbours at each rung (the allowed count grows as the radius shrinks: ≤2 at 200 km, ≤3 at 150 km, …) and stops at the widest rung that fits; the multiplier then follows the rung: **200 km → 1.5×, 150 → 1.4×, 100 → 1.3×, 50 → 1.2×, 20 → 1.1×, 10 → 1.0×, 5 → 0.9×, 2/1 km → 0.8× (floor)**. Density is thus priced exactly once — neighbours shrink the radius, and the radius sets the multiplier. Note it drops *below* 1.0 — redundant coverage is actively penalized, not merely un-bonused. Being where nobody else measures is the single strongest lever.
- **categories** — +10% per real sensing category (power / environment / home), capped at 1.3×. Built-in network telemetry does not count.
- **uptime** — the fraction of expected pings delivered.
- **activity** — +2% per live entity, capped at 1.1×.
- **uplink** — the shared-IP factor (§4): 1.0 for a sole node on its connection, gently decaying when several nodes share one egress IP.

Maximum ≈ 2.14× (full uptime, sole node on its uplink); a node stacked in a crowded spot on a shared link can fall well below 1×.

### Three inflows, one outflow
| Source | What it is | Inflationary? |
|--------|-----------|---------------|
| **mint** | fresh emission up to the hard cap (bootstrap) | yes |
| **recycle** | in-network spending (queries, subscriptions, messages) re-allocated back to the pool | no |
| **external** (`fundPool`) | revenue (e.g. data sales) used to buy GALU on the market and fund the pool | **no** |

Recycle and external land in one **reserve**; only ~5% of it drips into rewards each epoch, smoothing spikes. The single outflow is **claim**.

### Cumulative claims
Rewards are distributed as a **cumulative Merkle drop**: the root encodes each address's *lifetime* entitlement; the contract tracks how much was already claimed and pays the difference. One transaction collects the whole backlog, double-claims are impossible by construction, and a skipped on-chain submit self-heals on the next epoch.

### Lifecycle & "real yield"
| Phase | Condition | Reward source |
|-------|-----------|---------------|
| Ramp | < THRESHOLD nodes | mostly fresh mint |
| Decay | > THRESHOLD nodes | mint (capped) + drip |
| Post-cap | hard cap minted | recycle + **revenue (fundPool)** |

After the cap there is no inflation. An active, revenue-generating network keeps paying rewards out of recycled spending and bought-back tokens — *real yield* backed by real value, creating buy pressure rather than dilution. A dead network with no revenue simply dries up to zero.

---

## 6. Tokenomics (deployed values)

| Parameter | Value | Where enforced |
|-----------|-------|----------------|
| Token | GALU, ERC-20 on Polygon | contract |
| Hard cap (`MAX_SUPPLY`) | **40,000,000** | contract constant, immutable |
| Per-epoch mint ceiling (`MAX_EPOCH_MINT`) | **40,000** | contract constant |
| Base reward | 10 GALU / node / epoch | backend config |
| Decay threshold | 4,000 nodes | backend config |
| Reserve drip (`RELEASE_RATE`) | 5% / epoch | backend config |
| Burn (`BURN_RATE`) | 10% of the drip | backend config |
| Team fee | 5% of the pool — *Model B*, claimed like any address | backend config |
| Data-provider share | 30% of a data spend | backend config |
| Min / max pings | 16 / 96 per epoch (≈4 h online to qualify) | backend config |
| Counted nodes | trusted (attested) only | anti-sybil |

Backend-config values are tunable live and can taper over time (the nominal amount matters less than value — emission can be reduced as the network and token price grow). The two contract constants (cap, per-epoch mint) are immutable.

**Team (Model B).** The 5% team share is *part of the pool*, sits in the Merkle tree as an ordinary address, and is claimed like a node — there is no separate mint on top.

---

## 7. Security & governance

**On-chain invariants (mandatory tests):**
- Solvency: after mint and burn, `balanceOf(pool) ≥ totalEntitlement − totalClaimed`; a claim requires `balanceOf ≥ payout`.
- Inflation breaker: per-epoch mint `≤ MAX_EPOCH_MINT × span`; `ERC20Capped` enforces the 40M cap.
- Rate limits: a minimum interval between epoch mints and a bounded epoch-number jump cap how fast a compromised minter key could act.
- Anti double-spend: spendable balance subtracts already-claimed amounts (fed by the on-chain `Claimed` event).
- Precision: leaf amounts and the entitlement total are computed identically, so the sum of leaves equals `totalEntitlement` to the wei.

**Roles.** The *minter* (a hot operational key the backend signs with) is separate from the *owner* (a cold key that can pause and rotate the minter, moving to a multisig + timelock).

**Honest trust model.** Like every Merkle-reward / airdrop system, the contract cannot itself verify that a published root is "fair" — it enforces solvency and rate limits, but the root content is trusted to the minter. This is the standard posture at launch. The hardening path: owner → multisig + timelock, public reward data for community verification, off-chain monitoring with a pause circuit-breaker, segregation of user deposits, and ultimately optimistic (challengeable) or zero-knowledge proofs of the reward computation as value grows.

---

## 8. Use cases

- **Power quality** — grid voltage and stability; catch sags, spikes and outages on your street.
- **Coverage & signal** — a real map of WiFi/radio strength where people actually live.
- **Climate & environment** — temperature, humidity, pressure, air quality from any sensor.
- **Internet health** — the node mesh measures cross-country latency, DNS integrity and service reachability from real household connections; the same plane doubles as a home uptime monitor for your own servers.
- **Edge automation** — local `if → action` rules, webhooks, push, and a first-class Home Assistant / ESPHome bridge.
- **Peer data** — subscribe to a neighbour's readings, or sell yours into the network.

---

## 9. Roadmap

1. **Live (now).** Contract deployed and verified on Polygon; daily epochs minting and publishing cumulative roots; firmware, app, HA integration and protocol docs open-source. The ambient network mesh (node↔node ICMP + TCP/DNS/HTTP probes) runs fleet-wide and feeds the live map.
2. **Growth.** Onboard real nodes, harden the demand side (data marketplace / external revenue → `fundPool`), polish the consumer experience.
3. **Network intelligence (in development — "Sensmos Watch").** Turn the measurement mesh into a product: **directed monitoring** — watch *your own* endpoint from many countries at once (uptime, TTFB, DNS answers, alerting via push/webhook/e-mail, public status pages). The directed-monitoring engine (region-targeted assignments, redundancy quorum, per-country rollups, alerts) already runs in production; the product wrapper is being built. Client revenue funds the pool through the `fundPool` buyback path (§5) and is distributed to **all** nodes through the standard epoch weights — vantage rarity is already priced by the scarcity ladder, so there are no per-probe payouts to game. Opening this to outside customers is hard-gated behind two safeguards: cryptographically **signed probe jobs** (nodes only execute what the backend signed) and **target-ownership verification** — the network will only ever probe what a customer proves they control.
4. **Trust hardening.** Owner → multisig + timelock, external audit, public reward datasets + monitoring.
5. **Verifiability.** Move the reward oracle from "trusted" toward "challengeable / provable" as total value justifies the engineering.

---

## 10. Risk factors & disclaimer

GALU is an in-network reward token, not an investment instrument; nothing here is a promise of value or return. The economy is early and parameters may change. Key risks: the trusted-minter model until hardening completes (§7); on-chain key compromise; smart-contract risk pending audit; regulatory uncertainty around tokens; and dependence on continued operation of the backend during the centralized phase. The firmware and Home Assistant integration work fully locally and require none of the token layer.

---

*Part of the Sensmos project — see [README](README.md), [EMISSION_MODEL.md](EMISSION_MODEL.md), [HOW_IT_WORKS.md](HOW_IT_WORKS.md). Website: https://sensmos.com · Discord: https://discord.gg/ukea386Kqx*
