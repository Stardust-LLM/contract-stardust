// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {EnergyToken} from "../src/EnergyToken.sol";
import {EnergyStore} from "../src/EnergyStore.sol";
import {EnergyLiquidityPool} from "../src/EnergyLiquidityPool.sol";

/**
 * Upgrades an existing Energy system to the LP pool: deploys EnergyLiquidityPool (stake ENERGY, earn USDG) + a new
 * EnergyStore that sends 2% of every payment to the pool's stakers and the rest to TREASURY, gives the new store
 * MINTER_ROLE and, with OLD_STORE, revokes the old store's role and pauses it. The broadcaster must be the ENERGY admin (and the old store's owner).
 * Env: ENERGY_TOKEN, USDG_TOKEN (required), TREASURY, OWNER (default deployer), OLD_STORE (optional), LP_FEE_BPS
 * (100–1000, default the store's 200). Mints nothing and stakes nothing: the new pool starts empty.
 * Writes deployments/<chainId>-pool.json.
 */
contract DeployPool is Script {
    function run() external returns (EnergyLiquidityPool pool, EnergyStore store) {
        EnergyToken energy = EnergyToken(vm.envAddress("ENERGY_TOKEN"));
        address usdg = vm.envAddress("USDG_TOKEN");
        address oldStore = vm.envOr("OLD_STORE", address(0));
        uint256 lpFeeBps = vm.envOr("LP_FEE_BPS", uint256(0));
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address owner = vm.envOr("OWNER", deployer);
        address treasury = vm.envOr("TREASURY", deployer);
        pool = new EnergyLiquidityPool(energy, IERC20(usdg));
        store = new EnergyStore(IERC20Metadata(usdg), energy, pool, owner, treasury);
        energy.grantRole(energy.MINTER_ROLE(), address(store));
        if (lpFeeBps != 0) store.setLpFee(lpFeeBps); // only when the broadcaster is the store owner
        if (oldStore != address(0)) {
            energy.revokeRole(energy.MINTER_ROLE(), oldStore);
            EnergyStore(oldStore).pause();
        }
        vm.stopBroadcast();

        console2.log("LiquidityPool", address(pool));
        console2.log("EnergyStore  ", address(store));
        console2.log("treasury     ", treasury);
        string memory json = "pool";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "energyToken", address(energy));
        vm.serializeAddress(json, "usdg", usdg);
        vm.serializeAddress(json, "treasury", treasury);
        vm.serializeAddress(json, "energyStore", address(store));
        vm.serializeUint(json, "block", block.number);
        string memory out = vm.serializeAddress(json, "liquidityPool", address(pool));
        vm.writeJson(out, string.concat("deployments/", vm.toString(block.chainid), "-pool.json"));
    }
}
