// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title TestUSDG (TESTNET ONLY)
 * @notice Stand-in for Global Dollar (USDG, 6 decimals) on Robinhood Chain Testnet. Mainnet uses the real USDG
 *         0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; this contract is never deployed there.
 *         Anyone can take FAUCET_AMOUNT once per FAUCET_COOLDOWN from `faucet()` to test buying Energy.
 */
contract TestUSDG is ERC20 {
    uint256 public constant FAUCET_AMOUNT = 1_000e6; // 1,000 USDG
    uint256 public constant FAUCET_COOLDOWN = 1 days;

    mapping(address => uint256) public lastFaucet;

    error FaucetCooldown(uint256 availableAt);

    constructor(address recipient, uint256 initialSupply) ERC20("Global Dollar (Test)", "USDG") {
        _mint(recipient, initialSupply);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function faucet() external {
        uint256 next = lastFaucet[msg.sender] + FAUCET_COOLDOWN;
        if (lastFaucet[msg.sender] != 0 && block.timestamp < next) revert FaucetCooldown(next);
        lastFaucet[msg.sender] = block.timestamp;
        _mint(msg.sender, FAUCET_AMOUNT);
    }
}
