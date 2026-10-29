// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";

/// @notice What StardustStaking and EnergyStore need from the token.
interface IEnergyMinter {
    function mint(address to, uint256 amount) external;
}

/**
 * @title EnergyToken (ENERGY)
 * @notice Energy as a real ERC-20: visible in any wallet, transferable, 18 decimals.
 *
 * Flow
 *   1. Earn it: StardustStaking mints ENERGY on `claim()`, EnergyStore mints ENERGY when you pay USDG.
 *   2. Use it: `topUp(amount)` burns your ENERGY and emits `EnergyToppedUp(account, amount)`; the Stardust backend credits
 *      that amount to your account balance (used to pay for paid models) after verifying the log.
 *
 * Supply
 *   No maximum: new ENERGY only comes from the minters (MINTER_ROLE), each with its own limit (the staking pool per day,
 *   USDG paid to the store). Every top-up burns, so circulating supply = minted - topped up.
 *
 * Admin: OpenZeppelin AccessControlDefaultAdminRules, admin transfer needs a 1 day delay; the admin grants/revokes
 * MINTER_ROLE and cannot mint or move anyone's tokens itself.
 */
contract EnergyToken is ERC20, ERC20Permit, AccessControlDefaultAdminRules, IEnergyMinter {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// all ENERGY ever burned through topUp (the backend reconciles its credits against this)
    uint256 public totalToppedUp;

    event EnergyToppedUp(address indexed account, uint256 amount);

    error ZeroAmount();

    constructor(address admin)
        ERC20("Stardust Energy", "ENERGY")
        ERC20Permit("Stardust Energy")
        AccessControlDefaultAdminRules(1 days, admin)
    {}

    /// @notice Only StardustStaking / EnergyStore (MINTER_ROLE).
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @notice Burn `amount` of your ENERGY to add it to your Stardust account balance.
    function topUp(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _burn(msg.sender, amount);
        totalToppedUp += amount;
        emit EnergyToppedUp(msg.sender, amount);
    }
}
