// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IEnergyMinter} from "./EnergyToken.sol";
import {IEnergyLiquidityPool} from "./EnergyLiquidityPool.sol";

/**
 * @title EnergyStore
 * @notice Buy Energy with USDG. The Energy is minted as ENERGY (EnergyToken) into the buyer's wallet.
 *
 * USDG split (per purchase, all in the same transaction)
 *   - LPs: `lpFeeBps` (default 2%, owner can set 1%-10%) -> the liquidity pool, shared by everyone who stakes ENERGY
 *     there. Their staked ENERGY is never sold: they only earn. With nobody staked, the LP part goes to the treasury.
 *   - Platform: everything else -> `treasury` (the deployer wallet). The store keeps nothing: its USDG balance is the
 *     same before and after every purchase, and `lpUsdg + treasuryUsdg == received` exactly.
 *
 * Price
 *   energy = amount x energyPerUsdg (+ the bonus of the highest pack threshold reached), with 18 decimals like staking.
 *   Default: 1 USDG = 1,000 Energy, minimum 5 USDG, +10% from 50 USDG, +20% from 200 USDG.
 *   All math is exact (no rounding) for whole-number rates and basis-point bonuses: no dust.
 *
 * Safety
 *   - USDG is measured as it arrives (a fee-on-transfer token can never buy more Energy than what arrived) and is
 *     forwarded in full in the same call; the treasury can never be the pool.
 *   - `minEnergy` protects the buyer if the owner changes the price while the transaction is pending.
 *   - Per-purchase maximum against mistakes; pause stops new purchases only.
 *   - Owner limits: rate <= MAX_RATE, bonus <= 50%, at most MAX_BONUS_TIERS tiers. Two-step ownership, no renounce.
 *
 * Mainnet: USDG (Global Dollar) 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, 6 decimals. Testnet: TestUSDG.
 */
contract EnergyStore is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ errors
    error ZeroAddress();
    error BelowMinimum(uint256 amount, uint256 minimum);
    error AboveMaximum(uint256 amount, uint256 maximum);
    error NothingReceived();
    error Slippage(uint256 energy, uint256 minEnergy);
    error InvalidRate();
    error InvalidLimits();
    error InvalidBonusTiers();
    error RenounceDisabled();
    error InvalidLpFee();
    error InvalidTreasury();

    // ------------------------------------------------------------------ events
    event EnergyPurchased(address indexed buyer, uint256 usdgAmount, uint256 energy, uint256 bonusEnergy);
    /// Where the USDG of a purchase went: to the LPs (pool) / to the treasury.
    event PurchaseSplit(address indexed buyer, uint256 lpUsdg, uint256 treasuryUsdg);
    event LpFeeUpdated(uint256 oldBps, uint256 newBps);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event RateUpdated(uint256 oldRate, uint256 newRate);
    event LimitsUpdated(uint256 minPurchase, uint256 maxPurchase);
    event BonusTiersUpdated(BonusTier[] tiers);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // ------------------------------------------------------------------ types
    struct BonusTier {
        uint128 minUsdg; // in USDG units (e.g. 50e6)
        uint16 bonusBps; // 1000 = +10%
    }

    // ------------------------------------------------------------------ constants
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_BONUS_BPS = 5_000; // +50%
    uint256 public constant MAX_BONUS_TIERS = 5;
    uint256 public constant MAX_RATE = 1_000_000; // Energy per 1 USDG
    uint256 public constant MIN_LP_FEE_BPS = 100; // 1%
    uint256 public constant MAX_LP_FEE_BPS = 1_000; // 10%
    uint256 private constant ENERGY_UNIT = 1e18;

    // ------------------------------------------------------------------ state
    IERC20 public immutable usdg;
    /// ENERGY token: every purchase mints the Energy bought into the buyer's wallet
    IEnergyMinter public immutable energyToken;
    /// ENERGY staking pool that earns the LP part of every payment
    IEnergyLiquidityPool public immutable pool;
    /// 10 ** usdg.decimals()
    uint256 public immutable usdgUnit;

    address public treasury;
    uint256 public energyPerUsdg;
    uint256 public minPurchase; // USDG units
    uint256 public maxPurchase; // USDG units
    BonusTier[] private _bonusTiers;
    uint256 public lpFeeBps; // share of every payment that goes to the LPs

    uint256 public totalUsdg; // USDG paid through this contract (= totalLpUsdg + totalTreasuryUsdg)
    uint256 public totalLpUsdg; // USDG sent to the pool for the LPs
    uint256 public totalTreasuryUsdg; // USDG sent to the treasury
    uint256 public totalEnergy; // Energy sold (18 decimals), base + bonus
    uint256 public purchaseCount;

    constructor(
        IERC20Metadata usdg_,
        IEnergyMinter energy_,
        IEnergyLiquidityPool pool_,
        address owner_,
        address treasury_
    ) Ownable(owner_) {
        if (
            address(usdg_) == address(0) || address(energy_) == address(0) || address(pool_) == address(0)
                || treasury_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (treasury_ == address(pool_)) revert InvalidTreasury();
        energyToken = energy_;
        pool = pool_;
        usdg = IERC20(address(usdg_));
        usdgUnit = 10 ** usdg_.decimals();
        treasury = treasury_;
        emit TreasuryUpdated(address(0), treasury_);

        _setRate(1_000);
        _setLimits(5 * usdgUnit, 100_000 * usdgUnit);
        BonusTier[] memory tiers = new BonusTier[](2);
        tiers[0] = BonusTier({minUsdg: SafeCast.toUint128(50 * usdgUnit), bonusBps: 1_000});
        tiers[1] = BonusTier({minUsdg: SafeCast.toUint128(200 * usdgUnit), bonusBps: 2_000});
        _setBonusTiers(tiers);
        _setLpFee(200);
    }

    // ================================================================== buy

    /// @notice Pay `amount` USDG (needs an allowance) and get at least `minEnergy` Energy (18 decimals).
    function buy(uint256 amount, uint256 minEnergy) external nonReentrant whenNotPaused returns (uint256 energy) {
        if (amount < minPurchase) revert BelowMinimum(amount, minPurchase);
        if (amount > maxPurchase) revert AboveMaximum(amount, maxPurchase);

        uint256 before = usdg.balanceOf(address(this));
        usdg.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = usdg.balanceOf(address(this)) - before;
        if (received == 0) revert NothingReceived();

        (uint256 base, uint256 bonus) = quote(received);
        energy = base + bonus;
        if (energy < minEnergy) revert Slippage(energy, minEnergy);

        (uint256 lpUsdg, uint256 treasuryUsdg) = _split(received);

        totalUsdg += received;
        totalLpUsdg += lpUsdg;
        totalTreasuryUsdg += treasuryUsdg;
        totalEnergy += energy;
        purchaseCount++;
        emit EnergyPurchased(msg.sender, received, energy, bonus);
        emit PurchaseSplit(msg.sender, lpUsdg, treasuryUsdg);

        usdg.safeTransfer(treasury, treasuryUsdg);
        if (lpUsdg > 0) {
            usdg.safeTransfer(address(pool), lpUsdg);
            pool.distribute(); // the fee goes to the LPs staked right now
        }
        energyToken.mint(msg.sender, energy);
    }

    /// @notice What paying `amount` USDG gives right now: Energy, and the USDG split (LPs / treasury).
    function previewSplit(uint256 amount) external view returns (uint256 energy, uint256 lpUsdg, uint256 treasuryUsdg) {
        (uint256 base, uint256 bonus) = quote(amount);
        energy = base + bonus;
        (lpUsdg, treasuryUsdg) = _split(amount);
    }

    /// @notice Energy for `amount` USDG at the current price: (base, bonus), both with 18 decimals.
    function quote(uint256 amount) public view returns (uint256 base, uint256 bonus) {
        base = (amount * energyPerUsdg * ENERGY_UNIT) / usdgUnit;
        bonus = (base * bonusBpsFor(amount)) / BPS;
    }

    /// @notice Bonus of the highest pack threshold `amount` reaches (tiers are sorted ascending).
    function bonusBpsFor(uint256 amount) public view returns (uint256 bps) {
        for (uint256 i; i < _bonusTiers.length; ++i) {
            if (amount >= _bonusTiers[i].minUsdg) bps = _bonusTiers[i].bonusBps;
        }
    }

    function bonusTiers() external view returns (BonusTier[] memory) {
        return _bonusTiers;
    }

    // ================================================================== owner

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        if (newTreasury == address(pool)) revert InvalidTreasury();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    function setRate(uint256 newRate) external onlyOwner {
        _setRate(newRate);
    }

    function setLimits(uint256 newMin, uint256 newMax) external onlyOwner {
        _setLimits(newMin, newMax);
    }

    /// @notice LP share of every payment, 100 (1%) to 1,000 (10%) basis points.
    function setLpFee(uint256 newBps) external onlyOwner {
        _setLpFee(newBps);
    }

    /// @notice Replace the pack bonuses. Thresholds strictly ascending, bonuses <= MAX_BONUS_BPS. Empty = no bonus.
    function setBonusTiers(BonusTier[] calldata tiers) external onlyOwner {
        _setBonusTiers(tiers);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice The contract never holds funds by design; this returns anything sent here by mistake.
    function rescueToken(IERC20 token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
        emit TokenRescued(address(token), to, amount);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ================================================================== internals

    /// @dev lpFeeBps to the LPs while anyone is staked, the rest to the treasury; lp + treasury == usdgIn.
    function _split(uint256 usdgIn) internal view returns (uint256 lpUsdg, uint256 treasuryUsdg) {
        lpUsdg = pool.totalStaked() == 0 ? 0 : (usdgIn * lpFeeBps) / BPS;
        treasuryUsdg = usdgIn - lpUsdg;
    }

    function _setLpFee(uint256 newBps) internal {
        if (newBps < MIN_LP_FEE_BPS || newBps > MAX_LP_FEE_BPS) revert InvalidLpFee();
        emit LpFeeUpdated(lpFeeBps, newBps);
        lpFeeBps = newBps;
    }

    function _setRate(uint256 newRate) internal {
        if (newRate == 0 || newRate > MAX_RATE) revert InvalidRate();
        emit RateUpdated(energyPerUsdg, newRate);
        energyPerUsdg = newRate;
    }

    function _setLimits(uint256 newMin, uint256 newMax) internal {
        if (newMin == 0 || newMax < newMin) revert InvalidLimits();
        minPurchase = newMin;
        maxPurchase = newMax;
        emit LimitsUpdated(newMin, newMax);
    }

    function _setBonusTiers(BonusTier[] memory tiers) internal {
        if (tiers.length > MAX_BONUS_TIERS) revert InvalidBonusTiers();
        delete _bonusTiers;
        for (uint256 i; i < tiers.length; ++i) {
            if (tiers[i].bonusBps > MAX_BONUS_BPS || tiers[i].minUsdg == 0) revert InvalidBonusTiers();
            if (i > 0 && tiers[i].minUsdg <= tiers[i - 1].minUsdg) revert InvalidBonusTiers();
            _bonusTiers.push(tiers[i]);
        }
        emit BonusTiersUpdated(tiers);
    }
}
