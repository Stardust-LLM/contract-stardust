// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnergyVault} from "../src/EnergyVault.sol";

/**
 * Deploys EnergyVault for an existing ENERGY token and gives the backend's settler wallet SETTLER_ROLE.
 * Env: ENERGY_TOKEN (required), SETTLER (required: the backend's settlement wallet address), ADMIN (default deployer).
 * Writes deployments/<chainId>-vault.json.
 */
contract DeployVault is Script {
    function run() external returns (EnergyVault vault) {
        address energy = vm.envAddress("ENERGY_TOKEN");
        address settler = vm.envAddress("SETTLER");
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address admin = vm.envOr("ADMIN", deployer);
        vault = new EnergyVault(IERC20(energy), deployer);
        vault.grantRole(vault.SETTLER_ROLE(), settler);
        if (admin != deployer) vault.beginDefaultAdminTransfer(admin);
        vm.stopBroadcast();

        console2.log("EnergyVault", address(vault));
        console2.log("ENERGY     ", energy);
        console2.log("settler    ", settler);
        string memory json = "vault";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "energyToken", energy);
        vm.serializeAddress(json, "settler", settler);
        vm.serializeUint(json, "block", block.number);
        string memory out = vm.serializeAddress(json, "vault", address(vault));
        vm.writeJson(out, string.concat("deployments/", vm.toString(block.chainid), "-vault.json"));
    }
}
