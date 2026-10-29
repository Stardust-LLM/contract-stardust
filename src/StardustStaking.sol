// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IEnergyMinter} from "./EnergyToken.sol";

/**
 * @title StardustStaking
 * @notice Lock STARDUST for a tier (1, 7 or 30 days by default) and earn Energy.
 *
 * Energy is a token (ENERGY, EnergyToken.sol)
 *   `claim()` mints the Energy earned as ENERGY into the claimer's wallet (and emits `EnergyClaimed`). Holders burn it with
 *   `EnergyToken.topUp()` to add it to their Stardust account. Staking never changes the STARDUST supply.
 *
 * Bounded issuance
 *   Every second, `dailyPool / 1 days` Energy is shared between all EARNING positions by weight (amount x tier multiplier).
 *   Total Energy ever issued <= the integral of dailyPool over time, however much is staked and however many users there are.
 *   Time in which nobody is earning issues nothing (that Energy is simply never created).
 *
 * Exact expiry (no "earning forever" after the lock)
 *   Lock ends are rounded UP to the next full hour (EPOCH). At every epoch boundary the weight of positions ending there
 *   is removed from the pool automatically, and the accumulator value at that boundary is stored. A position therefore
 *   earns exactly until its end, even if its owner never comes back: no keeper bot needed. Boundaries are found through a
 *   bitmap, so a long idle period costs one storage read per 256 hours.
 *
 * No dust
 *   - Minimum stake (`minStake`) and at most MAX_ACTIVE_POSITIONS open positions per wallet: tiny "dust" positions cannot
 *     bloat storage or make claim loops expensive.
 *   - Rounding always goes down and is bounded: the accumulator uses 1e30 precision, so with the whole STARDUST supply
 *     staked the global rounding loss is < 1 wei of Energy per update, and < 1 wei per position settlement.
 *     The Energy unit is 1e18, so this is never visible.
 *   - STARDUST that actually arrives is measured (balance before/after), so a fee-on-transfer token can never make
 *     totalStaked larger than the real balance.
 *
 * Owner powers (and limits)
 *   - `setDailyPool` (<= MAX_DAILY_POOL): from that second on. Energy accrued before keeps the old rate.
 *   - `setTier`: duration / multiplier / enabled for NEW stakes only; existing positions keep their terms.
 *   - `pause`: blocks new stakes only. Unstaking and claiming always work.
 *   - `rescueToken`: returns other tokens, or STARDUST sent here on top of what is staked. Staked STARDUST can never be moved
 *     by the owner. Ownership is two-step and cannot be renounced by accident.
 *
 * Units: Energy amounts have 18 decimals (1 Energy = 1e18). STARDUST amounts are in token wei.
 */
contract StardustStaking is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;
    using SafeCast for uint256;

    // ------------------------------------------------------------------ errors
    error ZeroAddress();
    error BelowMinStake(uint256 amount, uint256 minStake);
    error InvalidTier();
    error InvalidTierConfig();
    error PoolTooLarge();
    error TooManyPositions();
    error UnknownPosition();
    error AlreadyWithdrawn();
    error StillLocked(uint64 end);
    error NothingToClaim();
    error CannotRescueStake();
    error RenounceDisabled();

    // ------------------------------------------------------------------ events
    event Staked(
        address indexed user,
        uint256 indexed positionId,
        uint256 amount,
        uint256 indexed tierId,
        uint256 weight,
        uint64 end
    );
    event Unstaked(address indexed user, uint256 indexed positionId, uint256 amount);
    event EnergyClaimed(address indexed user, uint256 amount);
    event DailyPoolUpdated(uint256 oldPool, uint256 newPool);
    event TierUpdated(uint256 indexed tierId, uint64 duration, uint32 multiplierBps, bool enabled);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // ------------------------------------------------------------------ types
    struct Tier {
        uint64 duration; // seconds
        uint32 multiplierBps; // 10_000 = 1x
        bool enabled;
    }

    struct Position {
        uint128 amount; // STARDUST locked
        uint128 weight; // amount x multiplier
        uint64 start;
        uint64 end; // always a multiple of EPOCH
        uint8 tierId;
        bool earning; // false once its Energy up to `end` has been settled
        bool withdrawn; // true after unstake
        uint256 accPaid; // accumulator value the position has been paid up to
    }

    // ------------------------------------------------------------------ constants
    uint256 public constant EPOCH = 1 hours;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_MULTIPLIER_BPS = 50_000; // 5x
    uint256 public constant MIN_DURATION = 1 hours;
    uint256 public constant MAX_DURATION = 365 days;
    uint256 public constant MAX_TIERS = 10;
    /// claim() settles every open position in one tx: 100 positions stay ~1-2M gas, far below the block gas limit
    uint256 public constant MAX_ACTIVE_POSITIONS = 100;
    /// @notice 1e12 Energy per day: far above any real setting, keeps every product below 2^256.
    uint256 public constant MAX_DAILY_POOL = 1e12 ether;
    uint256 private constant PRECISION = 1e30;
    uint256 private constant NONE = type(uint256).max;

    // ------------------------------------------------------------------ immutables
    IERC20 public immutable stardust;
    /// ENERGY token: `claim()` mints the Energy earned straight into the wallet
    IEnergyMinter public immutable energy;
    uint256 public immutable minStake;

    // ------------------------------------------------------------------ pool state
    uint256 public dailyPool; // Energy (18 decimals) shared per day
    uint256 public accEnergyPerWeight; // Energy per weight unit, scaled by PRECISION
    uint256 public lastUpdate;

    uint256 public totalWeight; // weight of earning positions
    uint256 public totalEarning; // STARDUST in earning positions
    uint256 public totalStaked; // all STARDUST held for stakers (earning or ended, not yet withdrawn)
    uint256 public totalAccrued; // Energy settled to users (claimed + unclaimed)
    uint256 public totalClaimed; // Energy claimed
    uint256 public stakerCount; // wallets with at least one open position

    // epoch index => data of positions ending at that boundary
    mapping(uint256 => uint256) public expiringWeight;
    mapping(uint256 => uint256) public expiringAmount;
    mapping(uint256 => uint256) public accAtEpoch; // accumulator at that boundary (set when it is passed)
    mapping(uint256 => uint256) private _endBitmap; // bit set = some position ends at that epoch, not yet processed

    Tier[] private _tiers;
    mapping(address => Position[]) private _positions;
    mapping(address => EnumerableSet.UintSet) private _open;
    mapping(address => uint256) public unclaimed;

    // ------------------------------------------------------------------ constructor
    constructor(IERC20 stardust_, IEnergyMinter energy_, address owner_, uint256 dailyPool_, uint256 minStake_)
        Ownable(owner_)
    {
        if (address(stardust_) == address(0) || address(energy_) == address(0)) revert ZeroAddress();
        energy = energy_;
        if (dailyPool_ > MAX_DAILY_POOL) revert PoolTooLarge();
        if (minStake_ == 0) revert BelowMinStake(0, 1);
        stardust = stardust_;
        minStake = minStake_;
        dailyPool = dailyPool_;
        lastUpdate = block.timestamp;
        emit DailyPoolUpdated(0, dailyPool_);

        _setTier(0, 1 days, 10_000, true); // Flex
        _setTier(1, 7 days, 12_500, true); // Builder
        _setTier(2, 30 days, 16_000, true); // Core
    }

    // ================================================================== user actions

    /// @notice Lock `amount` STARDUST in tier `tierId`. Needs an allowance. Returns the new position id.
    function stake(uint256 amount, uint256 tierId) external nonReentrant whenNotPaused returns (uint256 positionId) {
        if (tierId >= _tiers.length) revert InvalidTier();
        Tier memory cfg = _tiers[tierId];
        if (!cfg.enabled) revert InvalidTier();
        if (amount < minStake) revert BelowMinStake(amount, minStake);
        if (_open[msg.sender].length() >= MAX_ACTIVE_POSITIONS) revert TooManyPositions();

        _update();

        uint256 before = stardust.balanceOf(address(this));
        stardust.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = stardust.balanceOf(address(this)) - before;
        if (received < minStake) revert BelowMinStake(received, minStake);

        uint256 weight = (received * cfg.multiplierBps) / BPS;
        uint256 end = Math.ceilDiv(block.timestamp + cfg.duration, EPOCH) * EPOCH;
        uint256 idx = end / EPOCH;
        expiringWeight[idx] += weight;
        expiringAmount[idx] += received;
        // forge-lint: disable-next-line(incorrect-shift)
        _endBitmap[idx >> 8] |= 1 << (idx & 255); // set bit `idx`

        positionId = _positions[msg.sender].length;
        _positions[msg.sender].push(
            Position({
                amount: received.toUint128(),
                weight: weight.toUint128(),
                start: block.timestamp.toUint64(),
                end: end.toUint64(),
                tierId: tierId.toUint8(),
                earning: true,
                withdrawn: false,
                accPaid: accEnergyPerWeight
            })
        );
        _open[msg.sender].add(positionId);
        if (_open[msg.sender].length() == 1) stakerCount++;

        totalWeight += weight;
        totalEarning += received;
        totalStaked += received;

        emit Staked(msg.sender, positionId, received, tierId, weight, end.toUint64());
    }

    /// @notice Withdraw a position after its lock has ended. Its Energy is settled to `unclaimed` (claim it any time).
    function unstake(uint256 positionId) external nonReentrant {
        if (positionId >= _positions[msg.sender].length) revert UnknownPosition();
        Position storage p = _positions[msg.sender][positionId];
        if (p.withdrawn) revert AlreadyWithdrawn();
        if (block.timestamp < p.end) revert StillLocked(p.end);

        _update();
        _settle(msg.sender, p);

        uint256 amount = p.amount;
        p.withdrawn = true;
        _open[msg.sender].remove(positionId);
        if (_open[msg.sender].length() == 0) stakerCount--;
        totalStaked -= amount;

        stardust.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, positionId, amount);
    }

    /// @notice Claim all Energy earned by your positions. The backend credits it to your Stardust account.
    function claim() external nonReentrant returns (uint256 amount) {
        _update();
        EnumerableSet.UintSet storage open = _open[msg.sender];
        uint256 n = open.length();
        for (uint256 i; i < n; ++i) {
            _settle(msg.sender, _positions[msg.sender][open.at(i)]);
        }
        amount = unclaimed[msg.sender];
        if (amount == 0) revert NothingToClaim();
        unclaimed[msg.sender] = 0;
        totalClaimed += amount;
        emit EnergyClaimed(msg.sender, amount);
        energy.mint(msg.sender, amount); // last: state is final before the external call
    }

    /// @notice Bring the pool up to date (anyone may call; never needed for correctness).
    function poke() external {
        _update();
    }

    // ================================================================== owner actions

    /// @notice Change the Energy shared per day, from now on.
    function setDailyPool(uint256 newPool) external onlyOwner {
        if (newPool > MAX_DAILY_POOL) revert PoolTooLarge();
        _update(); // the time so far is paid at the old rate
        emit DailyPoolUpdated(dailyPool, newPool);
        dailyPool = newPool;
    }

    /// @notice Update tier `tierId`, or add one with `tierId == tierCount()`. Only affects new stakes.
    function setTier(uint256 tierId, uint64 duration, uint32 multiplierBps, bool enabled) external onlyOwner {
        _setTier(tierId, duration, multiplierBps, enabled);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Return tokens sent here by mistake. Staked STARDUST can never be taken.
    function rescueToken(IERC20 token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (token == stardust && amount > stardust.balanceOf(address(this)) - totalStaked) revert CannotRescueStake();
        token.safeTransfer(to, amount);
        emit TokenRescued(address(token), to, amount);
    }

    /// @dev Renouncing would freeze the pool settings forever; transfer ownership instead.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ================================================================== views

    /// @notice Energy `user` could claim right now (settled + still accruing).
    function pendingEnergy(address user) external view returns (uint256 total) {
        total = unclaimed[user];
        EnumerableSet.UintSet storage open = _open[user];
        uint256 n = open.length();
        uint256 accNow = _previewAcc(block.timestamp);
        for (uint256 i; i < n; ++i) {
            Position storage p = _positions[user][open.at(i)];
            if (!p.earning) continue;
            uint256 accEnd;
            if (p.end > block.timestamp) accEnd = accNow;
            else if (p.end <= lastUpdate) accEnd = accAtEpoch[p.end / EPOCH];
            else accEnd = _previewAcc(p.end);
            total += Math.mulDiv(p.weight, accEnd - p.accPaid, PRECISION);
        }
    }

    function tier(uint256 tierId) external view returns (Tier memory) {
        return _tiers[tierId];
    }

    function tierCount() external view returns (uint256) {
        return _tiers.length;
    }

    function positionCount(address user) external view returns (uint256) {
        return _positions[user].length;
    }

    function position(address user, uint256 positionId) external view returns (Position memory) {
        return _positions[user][positionId];
    }

    /// @notice All positions of `user`, including withdrawn ones (for history).
    function positionsOf(address user) external view returns (Position[] memory) {
        return _positions[user];
    }

    /// @notice Ids of the positions `user` has not withdrawn yet.
    function openPositionIds(address user) external view returns (uint256[] memory) {
        return _open[user].values();
    }

    /// @notice Live network stats for the stake page, in one call (weights/amounts as of now).
    function stats()
        external
        view
        returns (uint256 staked, uint256 earning, uint256 weight, uint256 claimed, uint256 stakers, uint256 pool)
    {
        (weight, earning) = _previewWeights(block.timestamp);
        return (totalStaked, earning, weight, totalClaimed, stakerCount, dailyPool);
    }

    // ================================================================== internals

    /// @dev Bring the accumulator to now, removing the weight of positions whose end has passed at their boundary.
    function _update() internal {
        uint256 t = block.timestamp;
        uint256 last = lastUpdate;
        if (t <= last) return;
        uint256 acc = accEnergyPerWeight;
        uint256 w = totalWeight;
        uint256 earning = totalEarning;
        uint256 lastIdx = t / EPOCH;
        uint256 idx = _nextEnd(last / EPOCH + 1, lastIdx);
        while (idx != NONE) {
            uint256 boundary = idx * EPOCH;
            acc += _accrual(boundary - last, w);
            last = boundary;
            accAtEpoch[idx] = acc;
            w -= expiringWeight[idx];
            earning -= expiringAmount[idx];
            delete expiringWeight[idx];
            delete expiringAmount[idx];
            // forge-lint: disable-next-line(incorrect-shift)
            _endBitmap[idx >> 8] &= ~(1 << (idx & 255)); // clear bit `idx`
            idx = _nextEnd(idx + 1, lastIdx);
        }
        accEnergyPerWeight = acc + _accrual(t - last, w);
        totalWeight = w;
        totalEarning = earning;
        lastUpdate = t;
    }

    /// @dev Same walk as `_update`, read-only: the accumulator at `target` (>= lastUpdate).
    function _previewAcc(uint256 target) internal view returns (uint256 acc) {
        uint256 last = lastUpdate;
        acc = accEnergyPerWeight;
        if (target <= last) return acc;
        uint256 w = totalWeight;
        uint256 lastIdx = target / EPOCH;
        uint256 idx = _nextEnd(last / EPOCH + 1, lastIdx);
        while (idx != NONE) {
            uint256 boundary = idx * EPOCH;
            acc += _accrual(boundary - last, w);
            last = boundary;
            w -= expiringWeight[idx];
            idx = _nextEnd(idx + 1, lastIdx);
        }
        acc += _accrual(target - last, w);
    }

    /// @dev Earning weight and amount at `target` (>= lastUpdate).
    function _previewWeights(uint256 target) internal view returns (uint256 w, uint256 earning) {
        w = totalWeight;
        earning = totalEarning;
        uint256 lastIdx = target / EPOCH;
        uint256 idx = _nextEnd(lastUpdate / EPOCH + 1, lastIdx);
        while (idx != NONE) {
            w -= expiringWeight[idx];
            earning -= expiringAmount[idx];
            idx = _nextEnd(idx + 1, lastIdx);
        }
    }

    function _accrual(uint256 dt, uint256 w) internal view returns (uint256) {
        if (w == 0 || dt == 0) return 0; // nobody earning: nothing is issued
        return Math.mulDiv(dt * dailyPool, PRECISION, 1 days * w);
    }

    /// @dev Pay a position up to now, or up to its end (then it stops earning). Call after `_update`.
    function _settle(address user, Position storage p) internal {
        if (!p.earning) return;
        uint256 accTo;
        if (p.end <= lastUpdate) {
            accTo = accAtEpoch[p.end / EPOCH];
            p.earning = false;
        } else {
            accTo = accEnergyPerWeight;
        }
        uint256 earned = Math.mulDiv(p.weight, accTo - p.accPaid, PRECISION);
        p.accPaid = accTo;
        if (earned != 0) {
            unclaimed[user] += earned;
            totalAccrued += earned;
        }
    }

    /// @dev First epoch index in [from, to] where some position ends, or NONE.
    function _nextEnd(uint256 from, uint256 to) internal view returns (uint256) {
        if (from > to) return NONE;
        uint256 word = from >> 8;
        uint256 lastWord = to >> 8;
        uint256 bits = _endBitmap[word] & (type(uint256).max << (from & 255));
        while (true) {
            if (bits != 0) {
                uint256 idx = (word << 8) | Math.log2(bits & (~bits + 1)); // lowest set bit
                return idx <= to ? idx : NONE;
            }
            if (word == lastWord) return NONE;
            bits = _endBitmap[++word];
        }
        return NONE; // unreachable
    }

    function _setTier(uint256 tierId, uint64 duration, uint32 multiplierBps, bool enabled) internal {
        if (
            duration < MIN_DURATION || duration > MAX_DURATION || multiplierBps < BPS
                || multiplierBps > MAX_MULTIPLIER_BPS
        ) revert InvalidTierConfig();
        Tier memory t = Tier({duration: duration, multiplierBps: multiplierBps, enabled: enabled});
        if (tierId < _tiers.length) {
            _tiers[tierId] = t;
        } else if (tierId == _tiers.length && tierId < MAX_TIERS) {
            _tiers.push(t);
        } else {
            revert InvalidTier();
        }
        emit TierUpdated(tierId, duration, multiplierBps, enabled);
    }
}
