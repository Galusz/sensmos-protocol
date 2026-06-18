<img src="logo.png" alt="Sensmos" height="80">

# Sensmos — Protocol

The **GALU** token, the on-chain reward pool, and the economic model behind the **Sensmos** DePIN sensor network.

> Sensmos is a decentralized network of cheap ESP32 sensor nodes that measure the real world, publish to a live map, trade data peer-to-peer, and earn GALU for real contribution. This repository is the public, on-chain part: the token/reward contract and how emission works.

## The contract

`SensmosRewardPool` is GALU (ERC-20) **and** the reward pool in a single contract — all "in-network" GALU (unclaimed rewards, deposits, revenue funding) physically lives there. Rewards are distributed via a **cumulative Merkle drop**, and solvency is enforced on-chain: a claim can never pay out more than the pool holds.

- Source: [`SensmosRewardPool.sol`](SensmosRewardPool.sol)
- Network: **Polygon**
- Address: [`0x9d797D0E642D9EADdbDbD34ACFCFd07bf0043c6C`](https://polygonscan.com/address/0x9d797D0E642D9EADdbDbD34ACFCFd07bf0043c6C)

Key properties: hard cap **40M**, a per-epoch mint ceiling, cumulative claim (no double-claim), a deflationary burn, `Ownable2Step` + `Pausable` + `ReentrancyGuard`, and a minter role (operational, hot) kept separate from the owner (cold/multisig).

## Docs

- **[WHITEPAPER.md](WHITEPAPER.md)** · [polska wersja](WHITEPAPER.pl.md) — the full whitepaper: vision, network, architecture, anti-sybil, economy, tokenomics, security, roadmap.
- **[HOW_IT_WORKS.md](HOW_IT_WORKS.md)** — a plain-language walk-through, from a sensor reading to a wallet withdrawal.
- **[EMISSION_MODEL.md](EMISSION_MODEL.md)** — the formal emission policy (the contract and backend must match it).

In one line: each epoch mints up to the cap, in-network spending and data-sale revenue recycle back as a bonus, the pool splits **95% nodes / 5% team** by weight — and everything is physically backed, with no virtual reserve.

## Part of the Sensmos project

| | |
|---|---|
| 🌐 Website | https://sensmos.com |
| 📱 App | https://github.com/Galusz/sensmos-app |
| 🔌 Firmware | https://github.com/Galusz/sensmos-firmware |
| 🏠 Home Assistant | https://github.com/Galusz/sensmos-homeassistant |
| 💬 Discord | https://discord.gg/ukea386Kqx |

GALU runs on Polygon. © 2026 Sensmos.
