// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20}           from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable}   from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Capped}     from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable}        from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof}     from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title  Sensmos GALU — Token + Reward Pool
 * @notice ERC-20 GALU combined with a reward pool that uses cumulative Merkle claims.
 *         All "in-network" GALU (unclaimed rewards, deposits, revenue funding) physically
 *         lives in this contract. Claims are cumulative: the Merkle root encodes each
 *         address's LIFETIME entitlement; the contract tracks how much was already claimed
 *         and pays out the difference.
 *
 * @dev    Solvency by design: claim requires balanceOf(this) >= payout. The pool is the GALU
 *         physically held here — there is no virtual reserve.
 *
 *         Three inflows into the pool:
 *           1. mintEpoch — fresh reward emission, up to MAX_SUPPLY (bootstrap inflation).
 *           2. deposit   — a user adds their own GALU to spend inside the network.
 *           3. fundPool  — external funding: GALU bought from revenue and added to the pool.
 *         One outflow: claim (reward withdrawal to a wallet).
 *
 *         Safety rails:
 *           - Hard supply cap (ERC20Capped, immutable) — applies to minting only.
 *           - Per-epoch mint ceiling (MAX_EPOCH_MINT, constant) — the minter cannot exceed it.
 *           - MIN_EPOCH_INTERVAL — minimum spacing between mints; throttles a stolen minter key.
 *           - MAX_SPAN — caps how far the epoch number may jump in a single call.
 *           - Cumulative claim (claimedTotal is monotonic → no double-claim).
 *           - The team share is part of the pool (it sits in the Merkle tree as a normal address
 *             and claims like any node), so there is no separate mint on top.
 */
contract SensmosRewardPool is
    ERC20, ERC20Burnable, ERC20Capped, Ownable2Step, Pausable, ReentrancyGuard
{
    /// @notice Hard cap on total supply — immutable (net supply may be lower after burns).
    uint256 public constant MAX_SUPPLY = 40_000_000 ether;

    /// @notice Max fresh mint per epoch = THRESHOLD(4000) × BASE(10). Constant mint breaker.
    uint256 public constant MAX_EPOCH_MINT = 40_000 ether;

    /// @notice Max epoch-number jump (epoch − currentEpoch). Tolerates ~a week of failed
    ///         submits without locking up; also bounds the per-call mint (cap × span).
    uint256 public constant MAX_SPAN = 7;

    /// @notice Minimum spacing between epoch mints. Throttles spam from a stolen minter key.
    uint256 public constant MIN_EPOCH_INTERVAL = 10 hours;

    /// @notice Address allowed to mint epochs (backend operational key → multisig long term).
    address public minter;

    /// @notice Active cumulative Merkle root. Leaf: keccak256(abi.encodePacked(addr, lifetimeWei)).
    bytes32 public merkleRoot;

    /// @notice Last settled epoch number (monotonic). Starts at 0; first epoch = 1.
    uint256 public currentEpoch;

    /// @notice Timestamp of the last epoch mint (for MIN_EPOCH_INTERVAL). 0 = the first one passes.
    uint256 public lastEpochTime;

    /// @notice Sum of ALL lifetime entitlements in the active root (used by the solvency guard).
    uint256 public totalEntitlement;

    /// @notice Total amount each address has already claimed (lifetime, wei).
    mapping(address => uint256) public claimedTotal;

    /// @notice Stats.
    uint256 public totalClaimed;
    uint256 public totalRecycled;
    uint256 public totalDeposited;
    uint256 public totalBurned;     // total burned from the pool (deflation)

    event MinterSet(address indexed minter);
    event EpochMinted(uint256 indexed epoch, uint256 mintedToPool, uint256 burned, uint256 totalEntitlement, bytes32 root);
    event Claimed(address indexed user, uint256 amount, uint256 newCumulative);
    event PoolFunded(address indexed from, uint256 amount);
    event Deposited(address indexed user, uint256 amount);

    constructor(address initialOwner)
        ERC20("Sensmos", "GALU")
        ERC20Capped(MAX_SUPPLY)
        Ownable(initialOwner)
    {}

    modifier onlyMinter() {
        require(minter != address(0), "RP: minter not set");
        require(msg.sender == minter, "RP: not minter");
        _;
    }

    function _update(address from, address to, uint256 value)
        internal override(ERC20, ERC20Capped)
    {
        super._update(from, to, value);
    }

    // ── Epoch mint ────────────────────────────────────────────
    /**
     * @notice Mints fresh GALU into the pool, burns burnAmount from the pool, sets the new root.
     * @dev    Order: mint → burn → solvency guard (balanceOf measured AFTER the burn). The reward
     *         pool = mintToPool + reserve top-up (already in balanceOf) − burnAmount.
     * @param  epoch               epoch number; must increase, span ≤ MAX_SPAN
     * @param  mintToPool          fresh mint (catch-up amount needed to cover the claims)
     * @param  burnAmount          amount to burn from the pool; 0 allowed
     * @param  newTotalEntitlement sum of ALL lifetime entitlements in the new root
     * @param  root                new cumulative Merkle root
     */
    function mintEpoch(
        uint256 epoch,
        uint256 mintToPool,
        uint256 burnAmount,
        uint256 newTotalEntitlement,
        bytes32 root
    ) external onlyMinter whenNotPaused {
        require(epoch > currentEpoch, "RP: epoch not increasing");
        require(root != bytes32(0), "RP: zero root");
        require(block.timestamp >= lastEpochTime + MIN_EPOCH_INTERVAL, "RP: too soon");

        uint256 span = epoch - currentEpoch;
        require(span <= MAX_SPAN, "RP: span too large");
        require(mintToPool <= MAX_EPOCH_MINT * span, "RP: exceeds epoch mint cap");
        // Note: total entitlement MAY shrink (spending lowers lifetime = earned+deposited−spent,
        // while recycle returns only a fraction per epoch). Solvency is enforced by the
        // balanceOf >= unclaimed guard, and per-user claimedTotal <= leaf always holds (no
        // over-claim). A monotonic "must not shrink" check would falsely freeze minting after
        // any net-spend epoch, so it is intentionally absent.

        if (mintToPool > 0) _mint(address(this), mintToPool); // ERC20Capped enforces MAX_SUPPLY

        // Burn from the pool (this GALU is nobody's entitlement). Deflationary.
        if (burnAmount > 0) {
            require(balanceOf(address(this)) >= burnAmount, "RP: burn exceeds pool");
            _burn(address(this), burnAmount);
            totalBurned += burnAmount;
        }

        // SOLVENCY GUARD — after mint and burn: the pool covers every unclaimed entitlement.
        uint256 unclaimed = newTotalEntitlement - totalClaimed;
        require(balanceOf(address(this)) >= unclaimed, "RP: would be insolvent");

        currentEpoch     = epoch;
        lastEpochTime    = block.timestamp;
        merkleRoot       = root;
        totalEntitlement = newTotalEntitlement;

        emit EpochMinted(epoch, mintToPool, burnAmount, newTotalEntitlement, root);
    }

    // ── External funding (revenue → pool) ─────────────────────
    function fundPool(uint256 amount) external {
        require(amount > 0, "RP: zero");
        _transfer(msg.sender, address(this), amount);
        totalRecycled += amount;
        emit PoolFunded(msg.sender, amount);
    }

    // ── Deposit — user adds GALU to spend inside the network ──
    function deposit(uint256 amount) external whenNotPaused {
        require(amount > 0, "RP: zero");
        _spendAllowance(msg.sender, address(this), amount); // requires approve
        _transfer(msg.sender, address(this), amount);
        totalDeposited += amount;
        emit Deposited(msg.sender, amount);
    }

    // ── Claim (cumulative) ────────────────────────────────────
    function claim(uint256 cumulativeAmount, bytes32[] calldata proof)
        external nonReentrant whenNotPaused
    {
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, cumulativeAmount));
        require(MerkleProof.verify(proof, merkleRoot, leaf), "RP: invalid proof");

        uint256 already = claimedTotal[msg.sender];
        require(cumulativeAmount > already, "RP: nothing to claim");

        uint256 payout = cumulativeAmount - already;
        require(balanceOf(address(this)) >= payout, "RP: pool underfunded");

        claimedTotal[msg.sender] = cumulativeAmount;
        totalClaimed += payout;

        _transfer(address(this), msg.sender, payout);
        emit Claimed(msg.sender, payout, cumulativeAmount);
    }

    // ── Views ─────────────────────────────────────────────────
    function claimable(address user, uint256 cumulativeAmount, bytes32[] calldata proof)
        external view returns (uint256)
    {
        bytes32 leaf = keccak256(abi.encodePacked(user, cumulativeAmount));
        if (!MerkleProof.verify(proof, merkleRoot, leaf)) return 0;
        uint256 already = claimedTotal[user];
        return cumulativeAmount > already ? cumulativeAmount - already : 0;
    }

    function poolBalance() external view returns (uint256) { return balanceOf(address(this)); }
    function outstandingClaims() external view returns (uint256) { return totalEntitlement - totalClaimed; }

    // ── Admin ─────────────────────────────────────────────────
    function setMinter(address _minter) external onlyOwner {
        require(_minter != address(0), "RP: zero minter");
        minter = _minter;
        emit MinterSet(_minter);
    }
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
