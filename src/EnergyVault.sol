// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice The part of EnergyToken the vault uses to burn what was spent.
interface IEnergyBurn {
    function topUp(uint256 amount) external;
}

/**
 * @title EnergyVault
 * @notice The on-chain Energy account behind the Stardust API.
 *
 *   deposit ENERGY ──▶ vault balance (public, per wallet) ──▶ API requests use it ──▶ settlement: charge() burns what was used
 *
 * - Deposits: `deposit` / `depositFor` move ENERGY into the vault. The balance is what the API can spend.
 * - Usage: requests are metered by the backend off-chain (instant), and settled here in batches (e.g. hourly) by the
 *   SETTLER_ROLE: `charge(batchId, users, amounts)` lowers balances and burns the total. Batches are numbered
 *   (`nextBatchId`), so the same batch can never be charged twice; a charge never takes more than a wallet's balance, and
 *   never more than `maxChargePerUser` in one batch (limits the damage of a leaked settler key).
 * - Withdrawals: `requestWithdraw` then `withdraw` after `withdrawDelay` (default 2 hours, longer than a settlement
 *   period), so usage made before the request is always settled first. The amount paid out is capped at the balance
 *   left after those charges. `cancelWithdraw` is always possible.
 * - The backend can only lower balances (by real usage, capped); it can never raise one or move anyone's ENERGY elsewhere.
 * - Admin (AccessControlDefaultAdminRules, 1 day hand-over delay): settler role, withdraw delay, charge cap, pause
 *   (new deposits only; withdrawals always work).
 */
contract EnergyVault is AccessControlDefaultAdminRules, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant SETTLER_ROLE = keccak256("SETTLER_ROLE");
    uint256 public constant MIN_WITHDRAW_DELAY = 1 hours;
    uint256 public constant MAX_WITHDRAW_DELAY = 7 days;
    uint256 public constant MAX_BATCH = 2_000;

    struct Account {
        uint256 balance; // ENERGY the API can spend (includes a pending withdrawal until it is paid out)
        uint256 pendingWithdraw;
        uint64 withdrawReadyAt;
    }

    IERC20 public immutable energy;

    uint256 public withdrawDelay = 2 hours;
    uint256 public maxChargePerUser = 1_000_000 ether; // per batch
    uint256 public nextBatchId;

    uint256 public totalDeposited;
    uint256 public totalWithdrawn;
    uint256 public totalCharged;

    mapping(address => Account) private _accounts;

    event Deposited(address indexed user, address indexed from, uint256 amount);
    event WithdrawRequested(address indexed user, uint256 amount, uint64 readyAt);
    event WithdrawCancelled(address indexed user);
    event Withdrawn(address indexed user, uint256 amount);
    event Charged(uint256 indexed batchId, address indexed user, uint256 amount);
    event BatchSettled(uint256 indexed batchId, uint256 users, uint256 total);
    event WithdrawDelayUpdated(uint256 delay);
    event MaxChargeUpdated(uint256 maxChargePerUser);

    error ZeroAddress();
    error ZeroAmount();
    error NothingReceived();
    error InsufficientBalance(uint256 balance, uint256 amount);
    error NoWithdrawRequest();
    error WithdrawNotReady(uint64 readyAt);
    error WrongBatch(uint256 expected, uint256 got);
    error BadBatch();
    error ChargeTooLarge(address user, uint256 amount);
    error InvalidDelay();

    constructor(IERC20 energy_, address admin) AccessControlDefaultAdminRules(1 days, admin) {
        if (address(energy_) == address(0)) revert ZeroAddress();
        energy = energy_;
    }

    // ================================================================== users

    function deposit(uint256 amount) external {
        depositFor(msg.sender, amount);
    }

    /// @notice Deposit `amount` of the caller's ENERGY into `user`'s vault balance (needs an allowance).
    function depositFor(address user, uint256 amount) public nonReentrant whenNotPaused {
        if (user == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 before = energy.balanceOf(address(this));
        energy.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = energy.balanceOf(address(this)) - before;
        if (received == 0) revert NothingReceived();
        _accounts[user].balance += received;
        totalDeposited += received;
        emit Deposited(user, msg.sender, received);
    }

    /// @notice Start a withdrawal (replaces an earlier request). Paid out by `withdraw()` after `withdrawDelay`.
    function requestWithdraw(uint256 amount) external {
        Account storage a = _accounts[msg.sender];
        if (amount == 0) revert ZeroAmount();
        if (amount > a.balance) revert InsufficientBalance(a.balance, amount);
        uint64 readyAt = SafeCast.toUint64(block.timestamp + withdrawDelay);
        a.pendingWithdraw = amount;
        a.withdrawReadyAt = readyAt;
        emit WithdrawRequested(msg.sender, amount, readyAt);
    }

    function cancelWithdraw() external {
        Account storage a = _accounts[msg.sender];
        if (a.pendingWithdraw == 0) revert NoWithdrawRequest();
        a.pendingWithdraw = 0;
        a.withdrawReadyAt = 0;
        emit WithdrawCancelled(msg.sender);
    }

    /// @notice Pay out the pending withdrawal (capped at what is left after settled usage).
    function withdraw() external nonReentrant returns (uint256 amount) {
        Account storage a = _accounts[msg.sender];
        if (a.pendingWithdraw == 0) revert NoWithdrawRequest();
        if (block.timestamp < a.withdrawReadyAt) revert WithdrawNotReady(a.withdrawReadyAt);
        amount = a.pendingWithdraw < a.balance ? a.pendingWithdraw : a.balance;
        a.balance -= amount;
        a.pendingWithdraw = 0;
        a.withdrawReadyAt = 0;
        totalWithdrawn += amount;
        energy.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ================================================================== settlement

    /**
     * @notice Settle metered usage: lower each balance by its amount (at most the balance) and burn the total.
     * @param batchId must equal `nextBatchId` (a batch can never be applied twice).
     */
    function charge(uint256 batchId, address[] calldata users, uint256[] calldata amounts)
        external
        onlyRole(SETTLER_ROLE)
        nonReentrant
        returns (uint256 total)
    {
        if (batchId != nextBatchId) revert WrongBatch(nextBatchId, batchId);
        if (users.length != amounts.length || users.length == 0 || users.length > MAX_BATCH) revert BadBatch();
        uint256 cap = maxChargePerUser;
        for (uint256 i; i < users.length; ++i) {
            uint256 amount = amounts[i];
            if (amount > cap) revert ChargeTooLarge(users[i], amount);
            Account storage a = _accounts[users[i]];
            if (amount > a.balance) amount = a.balance;
            a.balance -= amount;
            if (a.pendingWithdraw > a.balance) a.pendingWithdraw = a.balance;
            total += amount;
            emit Charged(batchId, users[i], amount);
        }
        nextBatchId = batchId + 1;
        totalCharged += total;
        if (total > 0) IEnergyBurn(address(energy)).topUp(total); // burn what was used
        emit BatchSettled(batchId, users.length, total);
    }

    // ================================================================== admin

    function setWithdrawDelay(uint256 delay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (delay < MIN_WITHDRAW_DELAY || delay > MAX_WITHDRAW_DELAY) revert InvalidDelay();
        withdrawDelay = delay;
        emit WithdrawDelayUpdated(delay);
    }

    function setMaxChargePerUser(uint256 cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (cap == 0) revert ZeroAmount();
        maxChargePerUser = cap;
        emit MaxChargeUpdated(cap);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ================================================================== views

    function accountOf(address user)
        external
        view
        returns (uint256 balance, uint256 pendingWithdraw, uint64 withdrawReadyAt)
    {
        Account storage a = _accounts[user];
        return (a.balance, a.pendingWithdraw, a.withdrawReadyAt);
    }

    /// @notice What the API may still spend: balance minus a pending withdrawal.
    function spendable(address user) external view returns (uint256) {
        Account storage a = _accounts[user];
        return a.balance - a.pendingWithdraw;
    }
}
