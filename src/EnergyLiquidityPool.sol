// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice What EnergyStore needs from the pool.
interface IEnergyLiquidityPool {
    function totalStaked() external view returns (uint256);
    function distribute() external returns (uint256);
}

/**
 * @title EnergyLiquidityPool
 * @notice Liquidity providers (LPs) stake ENERGY here and earn USDG from every Energy purchase (EnergyStore sends
 *         `lpFeeBps` of each payment, default 2%). The staked ENERGY is never sold or spent: an LP always gets back
 *         exactly what they put in.
 *
 * - USDG is shared by stake: each purchase's LP part is split between everyone staked at that moment, pro rata.
 *   `earned(lp)` shows it; `claim()` (and deposit/withdraw) pays it out.
 * - `withdraw(amount)` returns the ENERGY 1 day after the LP's last deposit, so nobody can stake right before a big purchase
 *   and leave right after with its fee.
 * - USDG arriving while nobody is staked waits for the next LPs (the store sends nothing in that case).
 * - No admin: nobody can move the staked ENERGY or the LPs' USDG anywhere else.
 */
contract EnergyLiquidityPool is IEnergyLiquidityPool, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant LOCK = 1 days;
    uint256 private constant PRECISION = 1e30;

    IERC20 public immutable energy;
    IERC20 public immutable usdg;

    uint256 public totalStaked;
    uint256 public accPerShare; // USDG per staked ENERGY wei, x PRECISION
    uint256 public accounted; // USDG booked for LPs and not claimed yet (>= what they can claim)
    uint256 public totalDistributed;
    uint256 public totalClaimed;

    mapping(address => uint256) public stakeOf;
    mapping(address => uint256) public unlockAt;
    mapping(address => uint256) private _paid;
    mapping(address => uint256) private _owed;

    event Deposited(address indexed lp, uint256 amount, uint256 unlockAt);
    event Withdrawn(address indexed lp, uint256 amount);
    event Distributed(uint256 usdg, uint256 totalStaked);
    event Claimed(address indexed lp, uint256 usdg);

    error ZeroAddress();
    error ZeroAmount();
    error NothingReceived();
    error Locked(uint256 unlockAt);
    error InsufficientStake(uint256 staked, uint256 amount);

    constructor(IERC20 energy_, IERC20 usdg_) {
        if (address(energy_) == address(0) || address(usdg_) == address(0)) revert ZeroAddress();
        energy = energy_;
        usdg = usdg_;
    }

    // ================================================================== LPs

    function deposit(uint256 amount) external nonReentrant returns (uint256 received) {
        if (amount == 0) revert ZeroAmount();
        _distribute();
        _settle(msg.sender);
        uint256 before = energy.balanceOf(address(this));
        energy.safeTransferFrom(msg.sender, address(this), amount);
        received = energy.balanceOf(address(this)) - before;
        if (received == 0) revert NothingReceived();
        stakeOf[msg.sender] += received;
        totalStaked += received;
        uint256 until = block.timestamp + LOCK;
        unlockAt[msg.sender] = until;
        emit Deposited(msg.sender, received, until);
        _payOut(msg.sender);
    }

    /// @notice Take back `amount` of your staked ENERGY (+ any USDG earned).
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp < unlockAt[msg.sender]) revert Locked(unlockAt[msg.sender]);
        uint256 staked = stakeOf[msg.sender];
        if (amount > staked) revert InsufficientStake(staked, amount);
        _distribute();
        _settle(msg.sender);
        stakeOf[msg.sender] = staked - amount;
        totalStaked -= amount;
        energy.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
        _payOut(msg.sender);
    }

    /// @notice Collect your USDG earnings.
    function claim() external nonReentrant returns (uint256 amount) {
        _distribute();
        _settle(msg.sender);
        amount = _payOut(msg.sender);
    }

    /// @notice Share the USDG that arrived since the last call between current LPs (anyone; the store calls it).
    function distribute() external nonReentrant returns (uint256) {
        return _distribute();
    }

    // ================================================================== views

    /// @notice USDG `lp` can claim right now (including USDG that arrived but is not distributed yet).
    function earned(address lp) external view returns (uint256) {
        uint256 acc = accPerShare;
        uint256 fresh = usdg.balanceOf(address(this)) - accounted;
        if (fresh > 0 && totalStaked > 0) acc += Math.mulDiv(fresh, PRECISION, totalStaked);
        return _owed[lp] + Math.mulDiv(stakeOf[lp], acc - _paid[lp], PRECISION);
    }

    // ================================================================== internals

    function _distribute() internal returns (uint256 shared) {
        uint256 staked = totalStaked;
        if (staked == 0) return 0; // waits for the next LPs
        uint256 fresh = usdg.balanceOf(address(this)) - accounted;
        if (fresh == 0) return 0;
        uint256 perShare = Math.mulDiv(fresh, PRECISION, staked);
        if (perShare == 0) return 0; // too small to share yet
        // All of it is booked: LP payouts (each rounded down) never exceed perShare x staked <= fresh, so the pool can
        // always pay everyone; the rounding remainder (< 1 USDG unit per 1e30 staked wei) stays in the pool.
        shared = fresh;
        accPerShare += perShare;
        accounted += shared;
        totalDistributed += shared;
        emit Distributed(shared, staked);
    }

    function _settle(address lp) internal {
        uint256 acc = accPerShare;
        uint256 staked = stakeOf[lp];
        if (staked > 0) _owed[lp] += Math.mulDiv(staked, acc - _paid[lp], PRECISION);
        _paid[lp] = acc;
    }

    function _payOut(address lp) internal returns (uint256 amount) {
        amount = _owed[lp];
        if (amount == 0) return 0;
        _owed[lp] = 0;
        accounted -= amount;
        totalClaimed += amount;
        usdg.safeTransfer(lp, amount);
        emit Claimed(lp, amount);
    }
}
