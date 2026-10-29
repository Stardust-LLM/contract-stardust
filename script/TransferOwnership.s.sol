// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {EnergyToken} from "../src/EnergyToken.sol";
import {EnergyStore} from "../src/EnergyStore.sol";
import {EnergyVault} from "../src/EnergyVault.sol";
import {StardustArt} from "../src/StardustArt.sol";
import {StardustStaking} from "../src/StardustStaking.sol";

/**
 * Hands every Stardust contract over to a new wallet. Run it with the CURRENT owner's key; nothing moves until the new
 * wallet accepts, so a typo in NEW_OWNER can still be undone by the old owner:
 *
 *   EnergyStore, StardustArt, StardustStaking (Ownable2Step): transferOwnership -> NEW_OWNER calls acceptOwnership().
 *   ENERGY, EnergyVault (AccessControlDefaultAdminRules, 1 day delay): beginDefaultAdminTransfer -> after 1 day NEW_OWNER
 *   calls acceptDefaultAdminTransfer(). The old admin keeps its rights until then (e.g. to add staking's MINTER_ROLE).
 *   Treasury (where USDG from Energy sales and ETH from NFT mints go) switches to NEW_TREASURY immediately.
 *   EnergyLiquidityPool has no owner: nothing to transfer.
 *
 * Env: NEW_OWNER (required), NEW_TREASURY (default NEW_OWNER), ALLOW_CONTRACT_OWNER=true to allow a multisig / smart
 * wallet. Addresses default to the mainnet deployment; override with ENERGY_TOKEN, ENERGY_STORE, ENERGY_VAULT,
 * STARDUST_ART, STAKING (default none). ADMIN_ROLES=false skips ENERGY / EnergyVault (e.g. before staking is added).
 */
contract TransferOwnership is Script {
    uint256 internal constant ROBINHOOD_MAINNET = 4_663;

    function run() external {
        address newOwner = vm.envAddress("NEW_OWNER");
        address payable newTreasury = payable(vm.envOr("NEW_TREASURY", newOwner));
        bool mainnet = block.chainid == ROBINHOOD_MAINNET;
        EnergyToken energy = EnergyToken(vm.envOr("ENERGY_TOKEN", mainnet ? 0x5a0Fc967F2b3398110AEb010026dBb1A80ca2d6a : address(0)));
        EnergyStore store = EnergyStore(vm.envOr("ENERGY_STORE", mainnet ? 0x55241EDbAd565105B3C4d7C24B7c702Aa0F89c73 : address(0)));
        EnergyVault vault = EnergyVault(vm.envOr("ENERGY_VAULT", mainnet ? 0xE46AFB181728c5d227034e79A89bEC8E191b2A5e : address(0)));
        StardustArt art = StardustArt(payable(vm.envOr("STARDUST_ART", mainnet ? 0x7084541C1eF9eF328535936fedadA34666DA18d0 : address(0))));
        StardustStaking staking = StardustStaking(vm.envOr("STAKING", address(0)));
        bool adminRoles = vm.envOr("ADMIN_ROLES", true);

        // a wrong address here would hand everything to a wallet nobody controls
        require(newOwner != address(0) && newTreasury != address(0), "zero address");
        if (!vm.envOr("ALLOW_CONTRACT_OWNER", false)) {
            require(newOwner.code.length == 0, "NEW_OWNER is a contract: set ALLOW_CONTRACT_OWNER=true for a multisig");
        }
        require(newTreasury != address(store.pool()), "treasury cannot be the liquidity pool");

        vm.startBroadcast();
        (, address current,) = vm.readCallers();
        require(newOwner != current, "NEW_OWNER is already the owner");

        store.setTreasury(newTreasury);
        store.transferOwnership(newOwner);
        art.setTreasury(newTreasury);
        art.transferOwnership(newOwner);
        if (address(staking) != address(0)) staking.transferOwnership(newOwner);
        if (adminRoles) {
            energy.beginDefaultAdminTransfer(newOwner);
            vault.beginDefaultAdminTransfer(newOwner);
        }
        vm.stopBroadcast();

        console2.log("current owner         ", current);
        console2.log("new owner (to accept) ", newOwner);
        console2.log("new treasury (now)    ", newTreasury);
        console2.log("EnergyStore  pending  ", store.pendingOwner());
        console2.log("StardustArt  pending  ", art.pendingOwner());
        if (address(staking) != address(0)) console2.log("Staking      pending  ", staking.pendingOwner());
        if (adminRoles) {
            (address e, uint48 eAt) = energy.pendingDefaultAdmin();
            (address v, uint48 vAt) = vault.pendingDefaultAdmin();
            console2.log("ENERGY admin pending  ", e, "accept after", eAt);
            console2.log("Vault admin  pending  ", v, "accept after", vAt);
        }
    }
}
