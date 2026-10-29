// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title StardustToken (TESTNET ONLY)
 * @notice Stand-in for the real STARDUST token while testing on Robinhood Chain Testnet.
 *         On mainnet STARDUST is launched on the launchpad and its address is passed to StardustStaking instead;
 *         this contract is never deployed there.
 * @dev Fixed supply, minted once in the constructor. No mint function, no owner: the supply can never grow.
 */
contract StardustToken is ERC20, ERC20Permit {
    uint256 public constant SUPPLY = 1_000_000_000 ether; // same total supply as the launchpad token

    constructor(address recipient) ERC20("Stardust", "STARDUST") ERC20Permit("Stardust") {
        _mint(recipient, SUPPLY);
    }
}
