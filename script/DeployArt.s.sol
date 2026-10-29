// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {StardustArt, IPriceFeed} from "../src/StardustArt.sol";
import {TestEthUsdFeed} from "../src/TestEthUsdFeed.sol";

/**
 * Deploys StardustArt ("Attacker × Defender", ERC-721): public mint at $0.20 in ETH (Chainlink ETH/USD), ETH straight
 * to TREASURY (default: the deployer = dev wallet), 50/week + 100/30 days, max 100,000, airdrops closed.
 * Metadata base is fixed at deploy (no setter): BASE_URI, default https://stardustllm.xyz/api/art/
 * (tokenURI = base + id, contractURI = base + "collection").
 *
 *   Robinhood mainnet (4663): Chainlink ETH/USD 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9.
 *   Testnet (46630) / anvil:  no Chainlink feeds there, a TestEthUsdFeed is deployed (TEST_ETH_USD, default 3000).
 * On-chain name / ticker: "Stardust Genesis" / "SGEN" (testnet: "Stardust Genesis (testnet)" / "tSGEN").
 * Env (optional): ART_NAME / ART_SYMBOL to override them, OWNER, TREASURY, PRICE_FEED,
 * START (unix time, default now), TEST_ETH_USD.
 * Writes deployments/<chainId>-art.json.
 */
contract DeployArt is Script {
    uint256 internal constant ROBINHOOD_MAINNET = 4_663;
    address internal constant MAINNET_ETH_USD = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    string internal constant DEFAULT_BASE_URI = "https://stardustllm.xyz/api/art/";

    function run() external returns (StardustArt art, address feed) {
        bool mainnet = block.chainid == ROBINHOOD_MAINNET;
        feed = mainnet ? MAINNET_ETH_USD : vm.envOr("PRICE_FEED", address(0));
        uint64 start = uint64(vm.envOr("START", block.timestamp));
        string memory name = vm.envOr("ART_NAME", string(mainnet ? "Stardust Genesis" : "Stardust Genesis (testnet)"));
        string memory symbol = vm.envOr("ART_SYMBOL", string(mainnet ? "SGEN" : "tSGEN"));
        string memory baseUri = vm.envOr("BASE_URI", string(DEFAULT_BASE_URI));

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address owner = vm.envOr("OWNER", deployer);
        address payable treasury = payable(vm.envOr("TREASURY", deployer));
        if (feed == address(0)) {
            int256 price = int256(vm.envOr("TEST_ETH_USD", uint256(3_000))) * 1e8;
            feed = address(new TestEthUsdFeed(deployer, price));
        }
        art = new StardustArt(name, symbol, owner, treasury, IPriceFeed(feed), start, baseUri);
        vm.stopBroadcast();

        console2.log("StardustArt ", address(art));
        console2.log("ETH/USD feed", feed);
        console2.log("treasury    ", treasury);
        string memory json = "art";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "priceFeed", feed);
        vm.serializeAddress(json, "treasury", treasury);
        vm.serializeUint(json, "startTime", start);
        vm.serializeString(json, "baseURI", baseUri);
        vm.serializeUint(json, "block", block.number);
        string memory out = vm.serializeAddress(json, "art", address(art));
        vm.writeJson(out, string.concat("deployments/", vm.toString(block.chainid), "-art.json"));
    }
}
