// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnergyToken} from "../src/EnergyToken.sol";
import {StardustStaking} from "../src/StardustStaking.sol";

/**
 * Adds StardustStaking to an ENERGY token that is already live (mainnet: once the STARDUST launchpad token exists) and
 * gives it MINTER_ROLE. The broadcaster must hold ENERGY's DEFAULT_ADMIN_ROLE.
 * Env: STARDUST_TOKEN, ENERGY_TOKEN (required), OWNER (default deployer), DAILY_POOL (whole Energy/day, default 100000),
 * MIN_STAKE (whole STARDUST, default 1). Writes deployments/<chainId>-staking.json.
 */
contract DeployStaking is Script {
    function run() external returns (StardustStaking staking) {
        address stardust = vm.envAddress("STARDUST_TOKEN");
        EnergyToken energy = EnergyToken(vm.envAddress("ENERGY_TOKEN"));
        uint256 dailyPool = vm.envOr("DAILY_POOL", uint256(100_000)) * 1 ether;
        uint256 minStake = vm.envOr("MIN_STAKE", uint256(1)) * 1 ether;
        require(stardust.code.length > 0, "STARDUST_TOKEN is not a contract");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address owner = vm.envOr("OWNER", deployer);
        staking = new StardustStaking(IERC20(stardust), energy, owner, dailyPool, minStake);
        energy.grantRole(energy.MINTER_ROLE(), address(staking));
        vm.stopBroadcast();

        console2.log("StardustStaking", address(staking));
        console2.log("STARDUST       ", stardust);
        console2.log("ENERGY         ", address(energy));
        string memory json = "staking";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "stardust", stardust);
        vm.serializeAddress(json, "energyToken", address(energy));
        vm.serializeAddress(json, "owner", owner);
        vm.serializeUint(json, "dailyPool", dailyPool);
        vm.serializeUint(json, "block", block.number);
        string memory out = vm.serializeAddress(json, "staking", address(staking));
        vm.writeJson(out, string.concat("deployments/", vm.toString(block.chainid), "-staking.json"));
    }
}
