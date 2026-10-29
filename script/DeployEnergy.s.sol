// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {EnergyToken} from "../src/EnergyToken.sol";
import {StardustStaking} from "../src/StardustStaking.sol";
import {EnergyStore} from "../src/EnergyStore.sol";
import {EnergyLiquidityPool} from "../src/EnergyLiquidityPool.sol";
import {StardustToken} from "../src/StardustToken.sol";
import {TestUSDG} from "../src/TestUSDG.sol";

/**
 * Deploys the Energy system in one go: ENERGY token + StardustStaking (claim mints ENERGY) + EnergyLiquidityPool +
 * EnergyStore (USDG buys take LP ENERGY first, mint the rest), and gives staking and store MINTER_ROLE.
 *
 *   Robinhood mainnet (4663): TREASURY is required; USDG is the real Global Dollar. Without STARDUST_TOKEN (the launchpad
 *   token is not live yet) StardustStaking is skipped: deploy it later with DeployStaking.s.sol.
 *   Testnet (46630) / anvil:  STARDUST_TOKEN / USDG_TOKEN reuse existing tokens, otherwise test tokens are deployed.
 *
 * Env (optional unless noted): STARDUST_TOKEN, USDG_TOKEN, TREASURY, OWNER, TEST_WALLET, DAILY_POOL (whole Energy/day,
 * default 100000), MIN_STAKE (whole STARDUST, default 1). With OWNER != deployer the token admin role is handed over with
 * the 1 day delay (OWNER calls acceptDefaultAdminTransfer afterwards). DEV_MINT (whole ENERGY, default 100000, 0 = none)
 * is minted once into the deployer's (dev) wallet at the token's first minting; nothing is staked: the liquidity pool
 * starts empty. LP_FEE_BPS (100–1000) sets the liquidity stakers' share right away when the deployer is the owner.
 * Writes deployments/<chainId>-energy.json.
 */
contract DeployEnergy is Script {
    uint256 internal constant ROBINHOOD_MAINNET = 4_663;
    uint256 internal constant ROBINHOOD_TESTNET = 46_630;
    uint256 internal constant ANVIL = 31_337;
    address internal constant MAINNET_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    struct Deployed {
        address stardust;
        address usdg;
        EnergyToken energy;
        StardustStaking staking;
        EnergyLiquidityPool pool;
        EnergyStore store;
        address owner;
        address treasury;
    }

    function run() external returns (Deployed memory d) {
        bool mainnet = block.chainid == ROBINHOOD_MAINNET;
        require(mainnet || block.chainid == ROBINHOOD_TESTNET || block.chainid == ANVIL, "unknown chain");
        d.stardust = vm.envOr("STARDUST_TOKEN", address(0));
        d.usdg = mainnet ? MAINNET_USDG : vm.envOr("USDG_TOKEN", address(0));
        bool withStaking = !mainnet || d.stardust != address(0);
        if (mainnet) require(vm.envOr("TREASURY", address(0)) != address(0), "TREASURY is required on mainnet");
        uint256 dailyPool = vm.envOr("DAILY_POOL", uint256(100_000)) * 1 ether;
        uint256 minStake = vm.envOr("MIN_STAKE", uint256(1)) * 1 ether;
        uint256 devMint = vm.envOr("DEV_MINT", uint256(100_000)) * 1 ether;

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        d.owner = vm.envOr("OWNER", deployer);
        d.treasury = vm.envOr("TREASURY", deployer);
        address testWallet = vm.envOr("TEST_WALLET", deployer);

        // test tokens only off mainnet: on mainnet STARDUST is the launchpad token and is never deployed here
        if (d.stardust == address(0) && !mainnet) {
            StardustToken t = new StardustToken(deployer);
            if (testWallet != deployer) require(t.transfer(testWallet, 2_500_000 ether), "transfer");
            d.stardust = address(t);
        }
        if (d.usdg == address(0)) d.usdg = address(new TestUSDG(testWallet, 10_000_000e6));

        d.energy = new EnergyToken(deployer);
        if (withStaking) {
            d.staking = new StardustStaking(IERC20(d.stardust), d.energy, d.owner, dailyPool, minStake);
            d.energy.grantRole(d.energy.MINTER_ROLE(), address(d.staking));
        }
        d.pool = new EnergyLiquidityPool(d.energy, IERC20(d.usdg));
        d.store = new EnergyStore(IERC20Metadata(d.usdg), d.energy, d.pool, d.owner, d.treasury);
        d.energy.grantRole(d.energy.MINTER_ROLE(), address(d.store));
        uint256 lpFee = vm.envOr("LP_FEE_BPS", uint256(0));
        if (lpFee != 0 && d.owner == deployer) d.store.setLpFee(lpFee);
        _devMint(d.energy, deployer, devMint);
        if (d.owner != deployer) d.energy.beginDefaultAdminTransfer(d.owner);
        vm.stopBroadcast();

        console2.log("chainId         ", block.chainid);
        console2.log("ENERGY          ", address(d.energy));
        console2.log("StardustStaking ", address(d.staking));
        console2.log("EnergyStore     ", address(d.store));
        console2.log("LiquidityPool   ", address(d.pool));
        console2.log("STARDUST        ", d.stardust);
        console2.log("USDG            ", d.usdg);
        console2.log("owner           ", d.owner);
        console2.log("treasury        ", d.treasury);

        string memory json = "energy";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "energyToken", address(d.energy));
        vm.serializeAddress(json, "staking", address(d.staking));
        vm.serializeAddress(json, "energyStore", address(d.store));
        vm.serializeAddress(json, "liquidityPool", address(d.pool));
        vm.serializeAddress(json, "stardust", d.stardust);
        vm.serializeAddress(json, "usdg", d.usdg);
        vm.serializeAddress(json, "owner", d.owner);
        vm.serializeAddress(json, "treasury", d.treasury);
        vm.serializeUint(json, "dailyPool", dailyPool);
        vm.serializeUint(json, "devMint", devMint);
        string memory out = vm.serializeUint(json, "block", block.number);
        vm.writeJson(out, string.concat("deployments/", vm.toString(block.chainid), "-energy.json"));
    }

    /// @dev The dev wallet's ENERGY at the first minting: the deployer (ENERGY admin) mints `amount` into its own wallet
    ///      once with a temporary MINTER_ROLE and gives the role up again in the same broadcast (visible on-chain).
    function _devMint(EnergyToken energy, address deployer, uint256 amount) internal {
        if (amount == 0) return;
        bytes32 minter = energy.MINTER_ROLE();
        energy.grantRole(minter, deployer);
        energy.mint(deployer, amount);
        energy.revokeRole(minter, deployer);
    }
}
